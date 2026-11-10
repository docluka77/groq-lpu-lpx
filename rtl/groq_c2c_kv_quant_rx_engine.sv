// =============================================================================
// File: rtl/groq_c2c_kv_quant_rx_engine.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 23 NVLink-C2C Prefill-to-Decode KV-Cache Disaggregation
//              Receiver & On-the-Fly BF16/FP16 -> MXFP8/NVFP4 Microscaling
//              Block Quantizer IP:
//              - 16-Lane 16-bit Floating-Point Ingress (BF16 / FP16)
//              - Tree-Based 16-Lane Block Maximum Exponent (E_max) Extractor
//              - Shared E8M0 Block Scale Generator (scale_e8m0_o)
//              - 4 Deterministic Quantization Modes:
//                  2'd0: QUANT_BF16_TO_MXFP8_E4M3 (2x compression)
//                  2'd1: QUANT_FP16_TO_MXFP8_E4M3 (2x compression)
//                  2'd2: QUANT_BF16_TO_NVFP4_E2M1 (4x compression)
//                  2'd3: QUANT_BYPASS_RAW128      (1x raw bypass)
//              - Single-Cycle Registered Pipeline with SRAM Write Forwarding
// =============================================================================
`ifndef GROQ_C2C_KV_QUANT_RX_ENGINE_SV
`define GROQ_C2C_KV_QUANT_RX_ENGINE_SV

module groq_c2c_kv_quant_rx_engine #(
  parameter int P_NUM_LANES = 16,
  parameter int P_BANK_W    = 2,
  parameter int P_ADDR_W    = 16
) (
  input  logic                clk,
  input  logic                rst_n,

  // NVLink-C2C KV-Cache Disaggregation Ingress Stream
  input  logic                valid_i,
  input  logic [1:0]          quant_mode_i,
  input  logic [127:0]        kv_in_lo_i,         // Lanes 0..7  (8x 16-bit BF16/FP16)
  input  logic [127:0]        kv_in_hi_i,         // Lanes 8..15 (8x 16-bit BF16/FP16)
  input  logic [P_BANK_W-1:0] target_sram_bank_i,
  input  logic [P_ADDR_W-1:0] target_sram_addr_i,

  // Quantized Microscaling Block & SRAM Write Egress (1-Cycle Registered)
  output logic                valid_o,
  output logic [127:0]        quant_vec_o,
  output logic [7:0]          scale_e8m0_o,
  output logic                sram_wr_en_o,
  output logic [P_BANK_W-1:0] sram_wr_bank_o,
  output logic [P_ADDR_W-1:0] sram_wr_addr_o,

  // Telemetry & Hardware Compression Status
  output logic [4:0]          zero_lanes_cnt_o,
  output logic                nan_inf_clamped_o,
  output logic [1:0]          compression_ratio_code_o
);

  // Quantization Mode Encodings
  localparam logic [1:0] QUANT_BF16_TO_MXFP8_E4M3 = 2'd0;
  localparam logic [1:0] QUANT_FP16_TO_MXFP8_E4M3 = 2'd1;
  localparam logic [1:0] QUANT_BF16_TO_NVFP4_E2M1 = 2'd2;
  localparam logic [1:0] QUANT_BYPASS_RAW128      = 2'd3;

  // Compression Ratio Telemetry Codes
  localparam logic [1:0] COMP_RATIO_1X_BYPASS = 2'd1;
  localparam logic [1:0] COMP_RATIO_2X_MXFP8  = 2'd2;
  localparam logic [1:0] COMP_RATIO_4X_NVFP4  = 2'd3;

  // ---------------------------------------------------------------------------
  // Step 1: Per-Lane Field Extraction & FP16 -> Effective E8M7 Normalization
  // ---------------------------------------------------------------------------
  logic [255:0] kv_in_full_c;
  assign kv_in_full_c = {kv_in_hi_i, kv_in_lo_i};

  logic [15:0] raw16_c        [0:P_NUM_LANES-1];
  logic        sign_c         [0:P_NUM_LANES-1];
  logic [7:0]  exp8_c         [0:P_NUM_LANES-1];
  logic [6:0]  frac7_c        [0:P_NUM_LANES-1];
  logic [15:0] is_zero_c;
  logic [15:0] is_nan_inf_c;
  logic [15:0] is_finite_nz_c;
  logic [7:0]  finite_exp8_c  [0:P_NUM_LANES-1];

  always_comb begin
    for (int i = 0; i < P_NUM_LANES; i++) begin
      raw16_c[i] = kv_in_full_c[i*16 +: 16];
      sign_c[i]  = raw16_c[i][15];

      if (quant_mode_i == QUANT_FP16_TO_MXFP8_E4M3) begin
        // FP16: [15]=sign, [14:10]=exp5 (bias 15), [9:0]=mant10
        if (raw16_c[i][14:10] == 5'd0) begin
          exp8_c[i] = 8'd0;
        end else if (raw16_c[i][14:10] == 5'd31) begin
          exp8_c[i] = 8'd255;
        end else begin
          exp8_c[i] = {3'd0, raw16_c[i][14:10]} + 8'd112;
        end
        frac7_c[i] = raw16_c[i][9:3];
      end else begin
        // BF16: [15]=sign, [14:7]=exp8 (bias 127), [6:0]=mant7
        exp8_c[i]  = raw16_c[i][14:7];
        frac7_c[i] = raw16_c[i][6:0];
      end

      is_zero_c[i]      = (exp8_c[i] == 8'd0);
      is_nan_inf_c[i]   = (exp8_c[i] == 8'd255);
      is_finite_nz_c[i] = (exp8_c[i] != 8'd0) && (exp8_c[i] != 8'd255);
      finite_exp8_c[i]  = is_finite_nz_c[i] ? exp8_c[i] : 8'd0;
    end
  end

  // ---------------------------------------------------------------------------
  // Step 2: 4-Stage Balanced Binary Reduction Tree for Block E_max & Scale
  // ---------------------------------------------------------------------------
  logic [7:0] max_lvl1 [0:7];
  logic [7:0] max_lvl2 [0:3];
  logic [7:0] max_lvl3 [0:1];
  logic [7:0] max_tree_exp8_c;
  logic [7:0] e_max_c;
  logic [7:0] scale_e8m0_c;
  logic [2:0] max_emax_frac3_c;
  logic [3:0] nvfp4_e4m3_exp4_c;
  logic [7:0] scale_nvfp4_e4m3_c;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0] scale_nvfp4_e4m3_q;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      max_lvl1[i] = (finite_exp8_c[2*i] >= finite_exp8_c[2*i+1]) ?
                     finite_exp8_c[2*i] : finite_exp8_c[2*i+1];
    end
    for (int i = 0; i < 4; i++) begin
      max_lvl2[i] = (max_lvl1[2*i] >= max_lvl1[2*i+1]) ?
                     max_lvl1[2*i] : max_lvl1[2*i+1];
    end
    for (int i = 0; i < 2; i++) begin
      max_lvl3[i] = (max_lvl2[2*i] >= max_lvl2[2*i+1]) ?
                     max_lvl2[2*i] : max_lvl2[2*i+1];
    end
    max_tree_exp8_c = (max_lvl3[0] >= max_lvl3[1]) ? max_lvl3[0] : max_lvl3[1];

    // Default E_max is 8'd127 when all lanes have zero or NaN/Inf exponents
    e_max_c = (|is_finite_nz_c) ? max_tree_exp8_c : 8'd127;

    case (quant_mode_i)
      QUANT_BF16_TO_MXFP8_E4M3,
      QUANT_FP16_TO_MXFP8_E4M3: begin
        scale_e8m0_c = (e_max_c > 8'd7) ? (e_max_c - 8'd7) : 8'd0;
      end
      QUANT_BF16_TO_NVFP4_E2M1: begin
        scale_e8m0_c = (e_max_c > 8'd2) ? (e_max_c - 8'd2) : 8'd0;
      end
      default: begin // QUANT_BYPASS_RAW128
        scale_e8m0_c = 8'd127;
      end
    endcase

    // BUG-LIT-006: Native NVIDIA NVFP4 FP8 E4M3 Fractional Block Scale (S35/S79)
    max_emax_frac3_c = 3'd0;
    for (int i = 0; i < P_NUM_LANES; i++) begin
      if (is_finite_nz_c[i] && (exp8_c[i] == e_max_c)) begin
        if (frac7_c[i][6:4] > max_emax_frac3_c) begin
          max_emax_frac3_c = frac7_c[i][6:4];
        end
      end
    end
    if (scale_e8m0_c <= 8'd120) begin
      nvfp4_e4m3_exp4_c = 4'd1;
    end else if (scale_e8m0_c >= 8'd134) begin
      nvfp4_e4m3_exp4_c = 4'd14;
    end else begin
      nvfp4_e4m3_exp4_c = scale_e8m0_c[3:0] - 4'd8;
    end
    scale_nvfp4_e4m3_c = (|is_finite_nz_c) ? {1'b0, nvfp4_e4m3_exp4_c, max_emax_frac3_c} : 8'd0;
  end

  // ---------------------------------------------------------------------------
  // Step 3: Per-Lane Microscaling Quantization (MXFP8 E4M3 & NVFP4 E2M1)
  // ---------------------------------------------------------------------------
  logic [7:0]   rel_exp_c        [0:P_NUM_LANES-1];
  logic [7:0]   mxfp8_lane_c     [0:P_NUM_LANES-1];
  logic [3:0]   nvfp4_lane_c     [0:P_NUM_LANES-1];
  logic [127:0] mxfp8_pack128_c;
  logic [63:0]  nvfp4_pack64_c;
  logic [127:0] quant_vec_c;
  logic [4:0]   zero_lanes_cnt_c;
  logic         nan_inf_clamped_c;
  logic [1:0]   comp_ratio_c;

  always_comb begin
    zero_lanes_cnt_c = 5'd0;
    for (int i = 0; i < P_NUM_LANES; i++) begin
      zero_lanes_cnt_c = zero_lanes_cnt_c + {4'd0, is_zero_c[i]};
      rel_exp_c[i]     = exp8_c[i] - scale_e8m0_c;

      // MXFP8_E4M3 Quantization: [7]=sign, [6:3]=exp4 (1..14), [2:0]=mant3
      if (is_zero_c[i]) begin
        mxfp8_lane_c[i] = {sign_c[i], 7'd0};
      end else if (is_nan_inf_c[i]) begin
        mxfp8_lane_c[i] = {sign_c[i], 4'd14, 3'd7};
      end else if (exp8_c[i] <= scale_e8m0_c) begin
        mxfp8_lane_c[i] = {sign_c[i], 7'd0};
      end else if (rel_exp_c[i] >= 8'd14) begin
        mxfp8_lane_c[i] = {sign_c[i], 4'd14, 3'd7};
      end else begin
        mxfp8_lane_c[i] = {sign_c[i], rel_exp_c[i][3:0], frac7_c[i][6:4]};
      end

      // NVFP4_E2M1 Quantization: [3]=sign, [2:1]=exp2 (1..3), [0]=mant1
      if (is_zero_c[i]) begin
        nvfp4_lane_c[i] = {sign_c[i], 3'd0};
      end else if (is_nan_inf_c[i]) begin
        nvfp4_lane_c[i] = {sign_c[i], 2'd3, 1'b1};
      end else if (exp8_c[i] <= scale_e8m0_c) begin
        nvfp4_lane_c[i] = {sign_c[i], 3'd0};
      end else if (rel_exp_c[i] >= 8'd3) begin
        nvfp4_lane_c[i] = {sign_c[i], 2'd3, 1'b1};
      end else begin
        nvfp4_lane_c[i] = {sign_c[i], rel_exp_c[i][1:0], frac7_c[i][6]};
      end

      mxfp8_pack128_c[i*8 +: 8] = mxfp8_lane_c[i];
      nvfp4_pack64_c[i*4 +: 4]  = nvfp4_lane_c[i];
    end

    case (quant_mode_i)
      QUANT_BF16_TO_MXFP8_E4M3,
      QUANT_FP16_TO_MXFP8_E4M3: begin
        quant_vec_c       = mxfp8_pack128_c;
        nan_inf_clamped_c = |is_nan_inf_c;
        comp_ratio_c      = COMP_RATIO_2X_MXFP8;
      end
      QUANT_BF16_TO_NVFP4_E2M1: begin
        quant_vec_c       = {nvfp4_pack64_c, nvfp4_pack64_c};
        nan_inf_clamped_c = |is_nan_inf_c;
        comp_ratio_c      = COMP_RATIO_4X_NVFP4;
      end
      QUANT_BYPASS_RAW128: begin
        quant_vec_c       = kv_in_lo_i;
        nan_inf_clamped_c = 1'b0;
        comp_ratio_c      = COMP_RATIO_1X_BYPASS;
      end
      default: begin
        quant_vec_c       = kv_in_lo_i;
        nan_inf_clamped_c = 1'b0;
        comp_ratio_c      = COMP_RATIO_1X_BYPASS;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Step 4: Single-Cycle Registered Output Stage & SRAM Write Forwarding
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_o                  <= 1'b0;
      quant_vec_o              <= 128'd0;
      scale_e8m0_o             <= 8'd0;
      sram_wr_en_o             <= 1'b0;
      sram_wr_bank_o           <= '0;
      sram_wr_addr_o           <= '0;
      zero_lanes_cnt_o         <= 5'd0;
      nan_inf_clamped_o        <= 1'b0;
      compression_ratio_code_o <= COMP_RATIO_1X_BYPASS;
      scale_nvfp4_e4m3_q       <= 8'd0;
    end else begin
      valid_o                  <= valid_i;
      quant_vec_o              <= quant_vec_c;
      scale_e8m0_o             <= scale_e8m0_c;
      sram_wr_en_o             <= valid_i;
      sram_wr_bank_o           <= target_sram_bank_i;
      sram_wr_addr_o           <= target_sram_addr_i;
      zero_lanes_cnt_o         <= zero_lanes_cnt_c;
      nan_inf_clamped_o        <= nan_inf_clamped_c;
      compression_ratio_code_o <= comp_ratio_c;
      scale_nvfp4_e4m3_q       <= scale_nvfp4_e4m3_c;
    end
  end

`ifdef FORMAL
  // Past-valid & delayed input tracking for registered pipeline proofs
  logic        f_past_valid;
  logic [1:0]  f_past_mode;
  logic [15:0] f_past_sign;
  logic [15:0] f_past_is_zero;
  logic [15:0] f_past_is_emax;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_past_valid   <= 1'b0;
      f_past_mode    <= 2'd0;
      f_past_sign    <= 16'd0;
      f_past_is_zero <= 16'd0;
      f_past_is_emax <= 16'd0;
    end else begin
      f_past_valid <= 1'b1;
      f_past_mode  <= quant_mode_i;
      for (int k = 0; k < P_NUM_LANES; k++) begin
        f_past_sign[k]    <= sign_c[k];
        f_past_is_zero[k] <= is_zero_c[k];
        f_past_is_emax[k] <= is_finite_nz_c[k] && (exp8_c[k] == e_max_c);
      end
    end
  end

  // Combinational & Registered Formal Invariants
  always_comb begin
    // Invariant 4a: Combinational zero-lane popcount bound
    assert (zero_lanes_cnt_c <= 5'd16);

    for (int k = 0; k < P_NUM_LANES; k++) begin
      // Invariant 1: Zero-input preservation in MXFP8_E4M3 & NVFP4_E2M1
      if (is_zero_c[k]) begin
        assert (mxfp8_lane_c[k][6:0] == 7'd0);
        assert (nvfp4_lane_c[k][2:0] == 3'd0);
      end
      // Invariant 2: Sign-bit preservation across all quantized lanes
      assert (mxfp8_lane_c[k][7] == sign_c[k]);
      assert (nvfp4_lane_c[k][3] == sign_c[k]);

      // Invariant 3: Maximum finite lane (exp8 == E_max) never overflows or underflows to zero
      if (is_finite_nz_c[k] && (exp8_c[k] == e_max_c)) begin
        if (quant_mode_i == QUANT_BF16_TO_MXFP8_E4M3 || quant_mode_i == QUANT_FP16_TO_MXFP8_E4M3) begin
          assert (mxfp8_lane_c[k][6:3] >= 4'd1 && mxfp8_lane_c[k][6:3] <= 4'd7);
          assert (mxfp8_lane_c[k][5:0] == {rel_exp_c[k][2:0], frac7_c[k][6:4]});
        end
        if (quant_mode_i == QUANT_BF16_TO_NVFP4_E2M1) begin
          assert (nvfp4_lane_c[k][2:1] >= 2'd1 && nvfp4_lane_c[k][2:1] <= 2'd2);
          assert (nvfp4_lane_c[k][0]   == frac7_c[k][6]);
        end
      end
    end
    if (rst_n) begin
      // Invariant 4b: Registered zero_lanes_cnt_o <= 16 and sram_wr_en_o == valid_o
      assert (zero_lanes_cnt_o <= 5'd16);
      assert (sram_wr_en_o == valid_o);
      // Invariant 5 (BUG-LIT-006): Native NVFP4 FP8 E4M3 scale non-negativity & zero-block preservation
      assert (scale_nvfp4_e4m3_q[7] == 1'b0);

      if (f_past_valid) begin
        if (&f_past_is_zero) begin
          assert (scale_nvfp4_e4m3_q == 8'd0);
        end
        for (int k = 0; k < P_NUM_LANES; k++) begin
          if (f_past_mode == QUANT_BF16_TO_MXFP8_E4M3 || f_past_mode == QUANT_FP16_TO_MXFP8_E4M3) begin
            assert (quant_vec_o[k*8 + 7] == f_past_sign[k]);
            if (f_past_is_zero[k]) assert (quant_vec_o[k*8 +: 7] == 7'd0);
            if (f_past_is_emax[k]) assert (quant_vec_o[k*8 + 3 +: 4] >= 4'd1 && quant_vec_o[k*8 + 3 +: 4] <= 4'd7);
          end else if (f_past_mode == QUANT_BF16_TO_NVFP4_E2M1) begin
            assert (quant_vec_o[k*4 + 3] == f_past_sign[k]);
            if (f_past_is_zero[k]) assert (quant_vec_o[k*4 +: 3] == 3'd0);
            if (f_past_is_emax[k]) assert (quant_vec_o[k*4 + 1 +: 2] >= 2'd1 && quant_vec_o[k*4 + 1 +: 2] <= 2'd2);
          end
        end
      end
    end
  end
`endif

endmodule

`endif // GROQ_C2C_KV_QUANT_RX_ENGINE_SV
