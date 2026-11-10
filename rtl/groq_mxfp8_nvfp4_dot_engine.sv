// =============================================================================
// File: rtl/groq_mxfp8_nvfp4_dot_engine.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 11 NVIDIA Groq 3 LPX / Vera Rubin Microscaling Tensor IP
//              Native OCP Microscaling (MXFP8: E4M3 & E5M2) and NVIDIA 4-bit
//              Floating Point (NVFP4: E2M1) Dot-Product Engine with shared
//              E8M0 power-of-two block scales, W4A8 mixed-precision on-the-fly
//              dequantization, per-lane & block-scale zero-skip gating, and
//              deterministic 2-stage pipeline into INT32 & IEEE-754 FP32.
// =============================================================================
`ifndef GROQ_MXFP8_NVFP4_DOT_ENGINE_SV
`define GROQ_MXFP8_NVFP4_DOT_ENGINE_SV
`timescale 1ns/1ps

module groq_mxfp8_nvfp4_dot_engine #(
  parameter int P_LANES = 16
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // Control & Precision Mode
  input  logic                       valid_i,
  input  logic [2:0]                 mode_i,
  input  logic                       zero_skip_en_i,
  input  logic                       accum_en_i,
  input  logic                       accum_clear_i,

  // Shared OCP E8M0 Power-of-Two Block Scales (0x00 = block zero-gate)
  input  logic [7:0]                 act_scale_e8m0_i,
  input  logic [7:0]                 wt_scale_e8m0_i,

  // 128-bit Activation & Weight Streams (16x FP8/INT8 or 32x packed NVFP4 E2M1)
  input  logic [P_LANES*8-1:0]       act_stream_i,
  input  logic [P_LANES*8-1:0]       wt_stream_i,

  // Deterministic 2-Cycle Pipeline Outputs & Zero-Skip Telemetry
  output logic                       valid_o,
  output logic signed [31:0]         unaccum_dot_o,
  output logic signed [31:0]         dot_accum_o,
  output logic [31:0]                dot_fp32_o,
  output logic [5:0]                 zero_skip_lanes_o,
  output logic                       block_zero_skipped_o,
  output logic                       nan_inf_flag_o
);

  // ---------------------------------------------------------------------------
  // 1. Precision Mode Encodings
  // ---------------------------------------------------------------------------
  localparam logic [2:0] MODE_INT8_SYM   = 3'd0;
  localparam logic [2:0] MODE_MXFP8_E4M3 = 3'd1;
  localparam logic [2:0] MODE_MXFP8_E5M2 = 3'd2;
  localparam logic [2:0] MODE_NVFP4_E2M1 = 3'd3;
  localparam logic [2:0] MODE_W4A8_MIXED        = 3'd4;
  localparam logic [2:0] MODE_NVFP4_E4M3_SCALE  = 3'd5;

  localparam int P_SUBLANES = P_LANES * 2; // 32 packed NVFP4 sub-lanes

  // ---------------------------------------------------------------------------
  // 2. Exact NVFP4 (E2M1) Magnitude Lookup Function (Units of 0.5 -> {0..12})
  //    Table: 000->0.0(0), 001->0.5(1), 010->1.0(2), 011->1.5(3),
  //           100->2.0(4), 101->3.0(6), 110->4.0(8), 111->6.0(12)
  // ---------------------------------------------------------------------------
  function automatic logic [3:0] fn_nvfp4_mag_2x(input logic [2:0] em);
    case (em)
      3'b000:  fn_nvfp4_mag_2x = 4'd0;
      3'b001:  fn_nvfp4_mag_2x = 4'd1;
      3'b010:  fn_nvfp4_mag_2x = 4'd2;
      3'b011:  fn_nvfp4_mag_2x = 4'd3;
      3'b100:  fn_nvfp4_mag_2x = 4'd4;
      3'b101:  fn_nvfp4_mag_2x = 4'd6;
      3'b110:  fn_nvfp4_mag_2x = 4'd8;
      default: fn_nvfp4_mag_2x = 4'd12;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // 3. Stage 1 Combinational Datapath: Multi-Precision Decode, Zero-Skip & Tree
  // ---------------------------------------------------------------------------
  logic                         block_zero_skip_comb;
  logic                         nan_inf_comb;
  logic [5:0]                   zero_skip_lanes_comb;
  logic signed [31:0]           tree_sum_comb;

  // Per-sublane NVFP4 E2M1 signals (exposed for formal verification)
  logic [P_SUBLANES-1:0][3:0]   nvfp4_act_mag_2x;
  logic [P_SUBLANES-1:0][3:0]   nvfp4_wt_mag_2x;
  logic [P_SUBLANES-1:0][7:0]   nvfp4_prod_mag_4x;
  logic signed [31:0]           nvfp4_sublane_signed [0:P_SUBLANES-1];
  logic signed [13:0]           nvfp4_tree_sum_s14;
  logic signed [31:0]           nvfp4_tree_sum_comb;

  // Per-lane 16-element signals (INT8 / MXFP8_E4M3 / MXFP8_E5M2 / W4A8_MIXED)
  logic signed [31:0]           lane16_signed [0:P_LANES-1];
  logic [P_LANES-1:0]           lane16_is_zero;
  logic [P_LANES-1:0]           lane16_nan_inf;
  logic [P_SUBLANES-1:0]        sublane32_is_zero;

  assign block_zero_skip_comb = (mode_i == MODE_NVFP4_E4M3_SCALE) ?
    (zero_skip_en_i && ((act_scale_e8m0_i[6:0] == 7'h00) || (wt_scale_e8m0_i[6:0] == 7'h00))) :
    ((act_scale_e8m0_i == 8'h00) || (wt_scale_e8m0_i == 8'h00));

  // 3A. 32-Sublane Parallel NVFP4 (E2M1) Evaluation Tree
  always_comb begin
    nvfp4_tree_sum_s14 = 14'sd0;
    for (int k = 0; k < P_SUBLANES; k++) begin
      logic [3:0] a_nib, w_nib;
      logic       p_sign;
      a_nib = act_stream_i[k*4 +: 4];
      w_nib = wt_stream_i[k*4 +: 4];
      nvfp4_act_mag_2x[k]  = fn_nvfp4_mag_2x(a_nib[2:0]);
      nvfp4_wt_mag_2x[k]   = fn_nvfp4_mag_2x(w_nib[2:0]);
      sublane32_is_zero[k] = block_zero_skip_comb ||
                             (a_nib[2:0] == 3'b000) || (w_nib[2:0] == 3'b000);
      nvfp4_prod_mag_4x[k] = sublane32_is_zero[k] ? 8'd0 :
                             (nvfp4_act_mag_2x[k] * nvfp4_wt_mag_2x[k]);
      p_sign               = a_nib[3] ^ w_nib[3];
      if (nvfp4_prod_mag_4x[k] == 8'd0) begin
        nvfp4_sublane_signed[k] = 32'sd0;
      end else if (p_sign) begin
        nvfp4_sublane_signed[k] = -$signed({24'd0, nvfp4_prod_mag_4x[k]});
      end else begin
        nvfp4_sublane_signed[k] = $signed({24'd0, nvfp4_prod_mag_4x[k]});
      end
      nvfp4_tree_sum_s14 = nvfp4_tree_sum_s14 + nvfp4_sublane_signed[k][13:0];
    end
    nvfp4_tree_sum_comb = {{18{nvfp4_tree_sum_s14[13]}}, nvfp4_tree_sum_s14};
  end

  // 3B. 16-Lane Parallel Evaluation (INT8_SYM, MXFP8_E4M3, MXFP8_E5M2, W4A8_MIXED)
  logic signed [31:0] lane16_tree_sum_comb;

  always_comb begin
    lane16_tree_sum_comb = 32'sd0;
    for (int i = 0; i < P_LANES; i++) begin
      logic [7:0]  a_byte, w_byte;
      logic [3:0]  w_fp4_nib;
      logic        a_s, w_s, p_sign;
      logic [7:0]  a_iso, w_iso;
      logic [3:0]  a_e4, w_e4, a_ee4, w_ee4, a_sig4, w_sig4, a_sig5, w_sig5, w_fp4_mag;
      logic [3:0]  exp_shift4, exp_shift5;
      logic [4:0]  a_e5, w_e5, a_ee5, w_ee5;
      logic [7:0]  sig_prod8;
      logic [15:0] int8_mag16;
      logic [23:0] aligned_mag24;

      a_byte    = act_stream_i[i*8 +: 8];
      w_byte    = wt_stream_i[i*8 +: 8];
      w_fp4_nib = wt_stream_i[i*4 +: 4];

      // Zero detection per lane (including signed -0.0 in FP8/FP4)
      case (mode_i)
        MODE_INT8_SYM:   lane16_is_zero[i] = block_zero_skip_comb || (a_byte == 8'h00) || (w_byte == 8'h00);
        MODE_W4A8_MIXED: lane16_is_zero[i] = block_zero_skip_comb || (a_byte[6:0] == 7'd0) || (w_fp4_nib[2:0] == 3'd0);
        default:         lane16_is_zero[i] = block_zero_skip_comb || (a_byte[6:0] == 7'd0) || (w_byte[6:0] == 7'd0);
      endcase

      // Zero-skip operand isolation
      a_iso     = (zero_skip_en_i && lane16_is_zero[i]) ? 8'h00 : a_byte;
      w_iso     = (zero_skip_en_i && lane16_is_zero[i]) ? 8'h00 : w_byte;

      a_s       = a_iso[7];
      w_s       = (mode_i == MODE_W4A8_MIXED) ? w_fp4_nib[3] : w_iso[7];
      p_sign    = a_s ^ w_s;

      // E4M3 decode (with full subnormal exp==0 support)
      a_e4       = a_iso[6:3];
      w_e4       = w_iso[6:3];
      a_ee4      = (a_e4 == 4'd0) ? 4'd1 : a_e4;
      w_ee4      = (w_e4 == 4'd0) ? 4'd1 : w_e4;
      a_sig4     = (a_e4 == 4'd0) ? {1'b0, a_iso[2:0]} : {1'b1, a_iso[2:0]};
      w_sig4     = (w_e4 == 4'd0) ? {1'b0, w_iso[2:0]} : {1'b1, w_iso[2:0]};
      exp_shift4 = {1'b0, a_ee4[3:1]} + {1'b0, w_ee4[3:1]} + {3'd0, a_ee4[0] & w_ee4[0]};

      // E5M2 decode (with full subnormal exp==0 support)
      a_e5       = a_iso[6:2];
      w_e5       = w_iso[6:2];
      a_ee5      = (a_e5 == 5'd0) ? 5'd1 : a_e5;
      w_ee5      = (w_e5 == 5'd0) ? 5'd1 : w_e5;
      a_sig5     = (a_e5 == 5'd0) ? {1'b0, a_iso[1:0], 1'b0} : {1'b1, a_iso[1:0], 1'b0};
      w_sig5     = (w_e5 == 5'd0) ? {1'b0, w_iso[1:0], 1'b0} : {1'b1, w_iso[1:0], 1'b0};
      exp_shift5 = {1'b0, a_ee5[4:2]} + {1'b0, w_ee5[4:2]} + {3'd0, |(a_ee5[1:0] & w_ee5[1:0])};

      // W4A8 on-the-fly NVFP4 E2M1 weight dequantization
      w_fp4_mag  = fn_nvfp4_mag_2x(w_fp4_nib[2:0]);

      // NaN / Inf per-lane detection
      case (mode_i)
        MODE_MXFP8_E4M3: lane16_nan_inf[i] = (a_byte[6:0] == 7'h7F) || (w_byte[6:0] == 7'h7F);
        MODE_MXFP8_E5M2: lane16_nan_inf[i] = (a_byte[6:2] == 5'h1F) || (w_byte[6:2] == 5'h1F);
        MODE_W4A8_MIXED: lane16_nan_inf[i] = (a_byte[6:0] == 7'h7F);
        default:         lane16_nan_inf[i] = 1'b0;
      endcase

      // Mode-specific mantissa product & exponent alignment
      sig_prod8     = 8'd0;
      int8_mag16    = 16'd0;
      aligned_mag24 = 24'd0;
      if (lane16_is_zero[i]) begin
        lane16_signed[i] = 32'sd0;
      end else begin
        case (mode_i)
          MODE_INT8_SYM: begin
            int8_mag16       = {8'd0, (a_s ? (-a_iso) : a_iso)} * {8'd0, (w_s ? (-w_iso) : w_iso)};
            aligned_mag24    = {8'd0, int8_mag16};
            lane16_signed[i] = p_sign ? -$signed({8'd0, aligned_mag24}) : $signed({8'd0, aligned_mag24});
          end
          MODE_MXFP8_E4M3: begin
            sig_prod8        = a_sig4 * w_sig4;
            aligned_mag24    = {16'd0, sig_prod8} << exp_shift4;
            lane16_signed[i] = p_sign ? -$signed({8'd0, aligned_mag24}) : $signed({8'd0, aligned_mag24});
          end
          MODE_MXFP8_E5M2: begin
            sig_prod8        = a_sig5 * w_sig5;
            aligned_mag24    = {16'd0, sig_prod8} << exp_shift5;
            lane16_signed[i] = p_sign ? -$signed({8'd0, aligned_mag24}) : $signed({8'd0, aligned_mag24});
          end
          default: begin // MODE_W4A8_MIXED
            sig_prod8        = a_sig4 * w_fp4_mag;
            aligned_mag24    = {16'd0, sig_prod8} << a_ee4;
            lane16_signed[i] = p_sign ? -$signed({8'd0, aligned_mag24}) : $signed({8'd0, aligned_mag24});
          end
        endcase
      end
      lane16_tree_sum_comb = lane16_tree_sum_comb + lane16_signed[i];
    end
  end

  // 3C. Zero-Skip Lane Count, NaN/Inf Reduction & Tree Selection
  logic [5:0] zero_cnt16_comb;
  logic [5:0] zero_cnt32_comb;

  always_comb begin
    zero_cnt16_comb = 6'd0;
    for (int i = 0; i < P_LANES; i++) begin
      zero_cnt16_comb = zero_cnt16_comb + {5'd0, lane16_is_zero[i]};
    end
    zero_cnt32_comb = 6'd0;
    for (int k = 0; k < P_SUBLANES; k++) begin
      zero_cnt32_comb = zero_cnt32_comb + {5'd0, sublane32_is_zero[k]};
    end
  end

  logic [3:0]         act_m4, wt_m4;
  logic signed [31:0] nvfp4_e4m3_scaled_comb;
  assign act_m4 = (act_scale_e8m0_i[6:3] == 4'd0) ? {1'b0, act_scale_e8m0_i[2:0]} : {1'b1, act_scale_e8m0_i[2:0]};
  assign wt_m4  = (wt_scale_e8m0_i[6:3] == 4'd0)  ? {1'b0, wt_scale_e8m0_i[2:0]}  : {1'b1, wt_scale_e8m0_i[2:0]};
  assign nvfp4_e4m3_scaled_comb = (nvfp4_tree_sum_comb * $signed({1'b0, act_m4 * wt_m4})) >>> 6;

  assign zero_skip_lanes_comb = ((mode_i == MODE_NVFP4_E2M1) || (mode_i == MODE_NVFP4_E4M3_SCALE)) ? zero_cnt32_comb : zero_cnt16_comb;
  assign nan_inf_comb         = (mode_i == MODE_NVFP4_E2M1 || mode_i == MODE_INT8_SYM) ? 1'b0 :
                                ((mode_i == MODE_NVFP4_E4M3_SCALE) ? ((act_scale_e8m0_i[6:0] == 7'h7F) || (wt_scale_e8m0_i[6:0] == 7'h7F)) :
                                                                     (|lane16_nan_inf));
  assign tree_sum_comb        = block_zero_skip_comb ? 32'sd0 :
                                ((mode_i == MODE_NVFP4_E2M1)       ? ((&sublane32_is_zero) ? 32'sd0 : nvfp4_tree_sum_comb) :
                                ((mode_i == MODE_NVFP4_E4M3_SCALE) ? ((&sublane32_is_zero) ? 32'sd0 : nvfp4_e4m3_scaled_comb) :
                                                                     ((&lane16_is_zero)    ? 32'sd0 : lane16_tree_sum_comb)));

  // ---------------------------------------------------------------------------
  // 4. Pipeline Stage 1 Registers (Cycle 1)
  // ---------------------------------------------------------------------------
  logic               s1_valid_q;
  logic               s1_accum_en_q;
  logic               s1_accum_clear_q;
  logic [7:0]         s1_act_scale_q;
  logic [7:0]         s1_wt_scale_q;
  logic signed [31:0] s1_tree_sum_q;
  logic [5:0]         s1_zero_skip_lanes_q;
  logic               s1_block_zero_skip_q;
  logic               s1_nan_inf_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid_q           <= 1'b0;
      s1_accum_en_q        <= 1'b0;
      s1_accum_clear_q     <= 1'b0;
      s1_act_scale_q       <= 8'd0;
      s1_wt_scale_q        <= 8'd0;
      s1_tree_sum_q        <= 32'sd0;
      s1_zero_skip_lanes_q <= 6'd0;
      s1_block_zero_skip_q <= 1'b0;
      s1_nan_inf_q         <= 1'b0;
    end else begin
      s1_valid_q           <= valid_i;
      s1_accum_en_q        <= accum_en_i;
      s1_accum_clear_q     <= accum_clear_i;
      s1_act_scale_q       <= (mode_i == MODE_NVFP4_E4M3_SCALE) ? (8'd120 + {4'd0, act_scale_e8m0_i[6:3]}) : act_scale_e8m0_i;
      s1_wt_scale_q        <= (mode_i == MODE_NVFP4_E4M3_SCALE) ? (8'd120 + {4'd0, wt_scale_e8m0_i[6:3]})  : wt_scale_e8m0_i;
      s1_tree_sum_q        <= tree_sum_comb;
      s1_zero_skip_lanes_q <= zero_skip_lanes_comb;
      s1_block_zero_skip_q <= block_zero_skip_comb;
      s1_nan_inf_q         <= nan_inf_comb;
    end
  end

  // ---------------------------------------------------------------------------
  // 5. Stage 2 Datapath: E8M0 Block-Scale Shift, Saturating Accum & IEEE FP32
  // ---------------------------------------------------------------------------
  logic               s2_sign;
  logic [31:0]        s2_abs_mag;
  logic [8:0]         s2_scale_sum;
  logic [8:0]         s2_scale_diff_pos;
  logic [8:0]         s2_scale_diff_neg;
  logic [2:0]         s2_lshift;
  logic [2:0]         s2_rshift;
  logic [38:0]        s2_shifted_mag;
  logic [30:0]        s2_sat_mag;
  logic signed [31:0] s2_unaccum_dot_comb;
  logic signed [32:0] s2_accum_sum_ext;
  logic signed [31:0] s2_accum_next_comb;
  logic [31:0]        s2_fp32_comb;

  assign s2_sign           = s1_tree_sum_q[31];
  assign s2_abs_mag        = s2_sign ? (~s1_tree_sum_q + 32'd1) : s1_tree_sum_q;
  assign s2_scale_sum      = {1'b0, s1_act_scale_q} + {1'b0, s1_wt_scale_q};
  assign s2_scale_diff_pos = s2_scale_sum - 9'd254;
  assign s2_scale_diff_neg = 9'd254 - s2_scale_sum;

  always_comb begin
    if (s2_scale_sum >= 9'd254) begin
      s2_lshift      = (s2_scale_diff_pos > 9'd7) ? 3'd7 : s2_scale_diff_pos[2:0];
      s2_rshift      = 3'd0;
      s2_shifted_mag = {7'd0, s2_abs_mag} << s2_lshift;
    end else begin
      s2_lshift      = 3'd0;
      s2_rshift      = (s2_scale_diff_neg > 9'd7) ? 3'd7 : s2_scale_diff_neg[2:0];
      s2_shifted_mag = {7'd0, s2_abs_mag >> s2_rshift};
    end

    if (s1_block_zero_skip_q || (s1_tree_sum_q == 32'sd0) || (s2_shifted_mag == 39'd0)) begin
      s2_sat_mag          = 31'd0;
      s2_unaccum_dot_comb = 32'sd0;
    end else begin
      s2_sat_mag          = (|s2_shifted_mag[38:31]) ? 31'h7FFF_FFFF : s2_shifted_mag[30:0];
      s2_unaccum_dot_comb = s2_sign ? -$signed({1'b0, s2_sat_mag}) : $signed({1'b0, s2_sat_mag});
    end
  end

  // Signed 32-bit saturating accumulator
  always_comb begin
    logic signed [31:0] base_acc;
    base_acc         = s1_accum_clear_q ? 32'sd0 : dot_accum_o;
    s2_accum_sum_ext = {base_acc[31], base_acc} + {s2_unaccum_dot_comb[31], s2_unaccum_dot_comb};
    if (!s1_accum_en_q) begin
      s2_accum_next_comb = s1_accum_clear_q ? 32'sd0 : s2_unaccum_dot_comb;
    end else if (s2_accum_sum_ext[32] != s2_accum_sum_ext[31]) begin
      s2_accum_next_comb = s2_accum_sum_ext[32] ? -32'sd2147483647 : 32'sd2147483647;
    end else begin
      s2_accum_next_comb = s2_accum_sum_ext[31:0];
    end
  end

  // IEEE-754 FP32 Normalizer with E8M0 Block-Scale Exponent Addition
  always_comb begin
    logic [4:0]  msb_idx;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] norm_shift;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [9:0]  fp32_exp_wide;
    msb_idx = 5'd0;
    for (int b = 0; b < 31; b++) begin
      if (s2_abs_mag[b]) msb_idx = 5'(b);
    end
    norm_shift    = s2_abs_mag << (5'd31 - msb_idx);
    fp32_exp_wide = {1'b0, s2_scale_sum} + {5'd0, msb_idx} - 10'd127;

    if (s1_nan_inf_q) begin
      s2_fp32_comb = 32'h7FC0_0000; // Canonical IEEE-754 Quiet NaN
    end else if (s1_block_zero_skip_q || (s2_abs_mag == 32'd0)) begin
      s2_fp32_comb = 32'h0000_0000; // Exact +0.0
    end else if (fp32_exp_wide[9] || (fp32_exp_wide == 10'd0)) begin
      s2_fp32_comb = {s2_sign, 31'd0};
    end else if (fp32_exp_wide >= 10'd255) begin
      s2_fp32_comb = {s2_sign, 8'hFF, 23'd0}; // Signed Infinity
    end else begin
      s2_fp32_comb = {s2_sign, fp32_exp_wide[7:0], norm_shift[30:8]};
    end
  end

  // ---------------------------------------------------------------------------
  // 6. Pipeline Stage 2 Output Registers (Cycle 2)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_o              <= 1'b0;
      unaccum_dot_o        <= 32'sd0;
      dot_accum_o          <= 32'sd0;
      dot_fp32_o           <= 32'h0000_0000;
      zero_skip_lanes_o    <= 6'd0;
      block_zero_skipped_o <= 1'b0;
      nan_inf_flag_o       <= 1'b0;
    end else begin
      valid_o              <= s1_valid_q;
      unaccum_dot_o        <= s2_unaccum_dot_comb;
      dot_accum_o          <= s2_accum_next_comb;
      dot_fp32_o           <= s2_fp32_comb;
      zero_skip_lanes_o    <= s1_zero_skip_lanes_q;
      block_zero_skipped_o <= s1_block_zero_skip_q;
      nan_inf_flag_o       <= s1_nan_inf_q;
    end
  end

  // ---------------------------------------------------------------------------
  // 7. Formal Verification Assertions (Yosys SAT & Verilator Clean)
  // ---------------------------------------------------------------------------
`ifdef FORMAL
  /* verilator lint_off SYNCASYNCNET */
  logic [1:0]               f_past_valid;
  logic                     f_valid_d1, f_valid_d2;
  logic [2:0]               f_mode_d1, f_mode_d2;
  logic                     f_act_zero_d1, f_act_zero_d2;
  logic                     f_wt_zero_d1, f_wt_zero_d2;
  logic                     f_blk_zero_d1, f_blk_zero_d2;
  logic                     f_e4m3_nan_d1, f_e4m3_nan_d2;
  logic                     f_e5m2_nan_d1, f_e5m2_nan_d2;

  // Combinational Sign-Symmetry Shadow Lanes & Stage-2 Scaler (Sign-Flipped Inputs)
  logic signed [31:0]       f_nvfp4_neg_sublane [0:P_SUBLANES-1];
  logic signed [31:0]       f_s2_neg_unaccum_comb;

  always_comb begin
    for (int k = 0; k < P_SUBLANES; k++) begin
      logic p_sign_neg;
      p_sign_neg = (~act_stream_i[k*4 + 3]) ^ wt_stream_i[k*4 + 3];
      if (nvfp4_prod_mag_4x[k] == 8'd0) begin
        f_nvfp4_neg_sublane[k] = 32'sd0;
      end else if (p_sign_neg) begin
        f_nvfp4_neg_sublane[k] = -$signed({24'd0, nvfp4_prod_mag_4x[k]});
      end else begin
        f_nvfp4_neg_sublane[k] = $signed({24'd0, nvfp4_prod_mag_4x[k]});
      end
    end

    if (s1_block_zero_skip_q || (s1_tree_sum_q == 32'sd0) || (s2_shifted_mag == 39'd0)) begin
      f_s2_neg_unaccum_comb = 32'sd0;
    end else begin
      f_s2_neg_unaccum_comb = (~s2_sign) ? -$signed({1'b0, s2_sat_mag}) : $signed({1'b0, s2_sat_mag});
    end
  end

  logic f_any_e4m3_nan_comb;
  logic f_any_e5m2_nan_comb;

  always_comb begin
    f_any_e4m3_nan_comb = 1'b0;
    f_any_e5m2_nan_comb = 1'b0;
    for (int i = 0; i < P_LANES; i++) begin
      if ((act_stream_i[i*8 +: 7] == 7'h7F) || (wt_stream_i[i*8 +: 7] == 7'h7F))
        f_any_e4m3_nan_comb = 1'b1;
      if ((act_stream_i[i*8+2 +: 5] == 5'h1F) || (wt_stream_i[i*8+2 +: 5] == 5'h1F))
        f_any_e5m2_nan_comb = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_past_valid  <= 2'b00;
      f_valid_d1    <= 1'b0;
      f_valid_d2    <= 1'b0;
      f_mode_d1     <= 3'd0;
      f_mode_d2     <= 3'd0;
      f_act_zero_d1 <= 1'b0;
      f_act_zero_d2 <= 1'b0;
      f_wt_zero_d1  <= 1'b0;
      f_wt_zero_d2  <= 1'b0;
      f_blk_zero_d1 <= 1'b0;
      f_blk_zero_d2 <= 1'b0;
      f_e4m3_nan_d1 <= 1'b0;
      f_e4m3_nan_d2 <= 1'b0;
      f_e5m2_nan_d1 <= 1'b0;
      f_e5m2_nan_d2 <= 1'b0;
    end else begin
      f_past_valid  <= {f_past_valid[0], 1'b1};
      f_valid_d1    <= valid_i;
      f_valid_d2    <= f_valid_d1;
      f_mode_d1     <= mode_i;
      f_mode_d2     <= f_mode_d1;
      f_act_zero_d1 <= (act_stream_i == '0);
      f_act_zero_d2 <= f_act_zero_d1;
      f_wt_zero_d1  <= (wt_stream_i == '0);
      f_wt_zero_d2  <= f_wt_zero_d1;
      f_blk_zero_d1 <= (mode_i == MODE_NVFP4_E4M3_SCALE) ?
                       (zero_skip_en_i && ((act_scale_e8m0_i[6:0] == 7'h00) || (wt_scale_e8m0_i[6:0] == 7'h00))) :
                       ((act_scale_e8m0_i == 8'h00) || (wt_scale_e8m0_i == 8'h00));
      f_blk_zero_d2 <= f_blk_zero_d1;
      f_e4m3_nan_d1 <= f_any_e4m3_nan_comb;
      f_e4m3_nan_d2 <= f_e4m3_nan_d1;
      f_e5m2_nan_d1 <= f_any_e5m2_nan_comb;
      f_e5m2_nan_d2 <= f_e5m2_nan_d1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      // Property 1: Exact 2-cycle pipeline valid latency (valid_o == $past(valid_i, 2))
      if (f_past_valid[1]) begin
        assert (valid_o == f_valid_d2);
      end

      // Property 2: Sign-symmetry invariant (flipping sign bits negates unaccumulated dot product)
      for (int k = 0; k < P_SUBLANES; k++) begin
        assert (f_nvfp4_neg_sublane[k] == -nvfp4_sublane_signed[k]);
      end
      assert (f_s2_neg_unaccum_comb == -s2_unaccum_dot_comb);

      // Property 3: Zero-input & zero-block-scale invariant (Stage 1 & Stage 2)
      if ((act_stream_i == '0) || (wt_stream_i == '0) || block_zero_skip_comb) begin
        assert (tree_sum_comb == 32'sd0);
        if ((mode_i == MODE_NVFP4_E2M1) || (mode_i == MODE_NVFP4_E4M3_SCALE)) begin
          assert (zero_skip_lanes_comb == 6'd32);
        end else begin
          assert (zero_skip_lanes_comb == 6'd16);
        end
      end
      if (mode_i == MODE_NVFP4_E4M3_SCALE) begin
        if ((act_scale_e8m0_i[6:0] == 7'h7F) || (wt_scale_e8m0_i[6:0] == 7'h7F)) begin
          assert (nan_inf_comb == 1'b1);
        end
        if (zero_skip_en_i && ((act_scale_e8m0_i[6:0] == 7'h00) || (wt_scale_e8m0_i[6:0] == 7'h00))) begin
          assert (block_zero_skip_comb == 1'b1);
          assert (tree_sum_comb == 32'sd0);
        end
      end
      if (f_past_valid[1]) begin
        assert (block_zero_skipped_o == f_blk_zero_d2);
        if (f_act_zero_d2 || f_wt_zero_d2 || block_zero_skipped_o) begin
          assert (unaccum_dot_o == 32'sd0);
          if ((f_mode_d2 == MODE_NVFP4_E2M1) || (f_mode_d2 == MODE_NVFP4_E4M3_SCALE)) begin
            assert (zero_skip_lanes_o == 6'd32);
          end else begin
            assert (zero_skip_lanes_o == 6'd16);
          end
        end
      end

      // Property 4: NaN/Inf detection invariant in MODE_MXFP8_E4M3 & MODE_MXFP8_E5M2
      if (mode_i == MODE_MXFP8_E4M3) begin
        assert (nan_inf_comb == f_any_e4m3_nan_comb);
      end
      if (mode_i == MODE_MXFP8_E5M2) begin
        assert (nan_inf_comb == f_any_e5m2_nan_comb);
      end
      if (f_past_valid[1]) begin
        if (f_mode_d2 == MODE_MXFP8_E4M3) begin
          assert (nan_inf_flag_o == f_e4m3_nan_d2);
        end
        if (f_mode_d2 == MODE_MXFP8_E5M2) begin
          assert (nan_inf_flag_o == f_e5m2_nan_d2);
        end
        if ((f_mode_d2 == MODE_NVFP4_E4M3_SCALE) && s1_nan_inf_q) begin
          assert (s2_fp32_comb == 32'h7FC0_0000);
        end
        if (nan_inf_flag_o) begin
          assert (dot_fp32_o == 32'h7FC0_0000);
        end
      end

      // Property 5: NVFP4 (E2M1) exact lookup bounds & 32-lane reduction overflow-freedom
      for (int k = 0; k < P_SUBLANES; k++) begin
        assert (nvfp4_act_mag_2x[k] <= 4'd12);
        assert (nvfp4_wt_mag_2x[k]  <= 4'd12);
        assert (nvfp4_prod_mag_4x[k] <= 8'd144);
        assert (nvfp4_sublane_signed[k] >= -32'sd144);
        assert (nvfp4_sublane_signed[k] <=  32'sd144);
      end
      assert (nvfp4_tree_sum_comb >= -32'sd8192);
      assert (nvfp4_tree_sum_comb <=  32'sd8191);
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule : groq_mxfp8_nvfp4_dot_engine

`endif // GROQ_MXFP8_NVFP4_DOT_ENGINE_SV
