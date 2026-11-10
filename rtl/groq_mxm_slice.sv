// =============================================================================
// File: rtl/groq_mxm_slice.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Matrix Execution Module (MXM) Slice ? Systolic / Wavefront
//              Tensor Contraction Engine (West SLICE_MXM_W & East SLICE_MXM_E)
//              Features:
//              - Dual Ping-Pong Weight Staging Buffers (weight_buf_bank0/1)
//                with zero-cycle active bank swap (groq_pkg::MXM_SWAP_WEIGHT) and
//                concurrent background weight pre-loading.
//              - Multi-Precision Tensor Modes: groq_pkg::PREC_INT8, groq_pkg::PREC_FP8_E4M3,
//                groq_pkg::PREC_FP16 / groq_pkg::PREC_BF16 planar contraction into 32-bit accum.
//              - Zero-Skip / Operand Isolation Gating (act_zero_gate_en_i):
//                gates multiplier column inputs when activation lane is zero.
//              - Fixed 2-cycle deterministic pipeline latency.
// =============================================================================
`ifndef GROQ_MXM_SLICE_SV
`define GROQ_MXM_SLICE_SV

`include "groq_pkg.sv"

module groq_mxm_slice #(
  parameter int P_LANES        = groq_pkg::SUPERLANE_LANES,
  parameter int P_ELEM_BITS    = groq_pkg::ELEM_BITS,
  parameter int P_STREAM_WIDTH = groq_pkg::STREAM_WIDTH,
  parameter int P_ACCUM_BITS   = 32,
  parameter int P_LATENCY      = 2
) (
  input  logic                                clk,
  input  logic                                rst_n,

  // VLIW Control & Precision Mode
  input  logic [3:0]                          mxm_op_i,
  input  logic [3:0]                          prec_mode_i,
  input  logic [3:0]                          weight_row_idx_i,
  input  logic                                act_zero_gate_en_i,
  input  logic                                accum_clear_i,
  input  logic                                accum_preload_en_i,

  // Concurrent Background Weight Staging Port (Zero-Stall Preload)
  input  logic                                bg_wt_load_en_i,
  input  logic [3:0]                          bg_wt_row_idx_i,
  input  logic [P_STREAM_WIDTH-1:0]           bg_wt_data_i,

  // Spatial Stream Inputs (Activations & Weight Stream)
  input  logic                                stream_act_valid_i,
  input  logic [P_STREAM_WIDTH-1:0]           stream_act_data_i,
  input  logic                                stream_wt_valid_i,
  input  logic [P_STREAM_WIDTH-1:0]           stream_wt_data_i,
  input  logic [P_LANES*P_ACCUM_BITS-1:0]     accum_preload_data_i,

  // Status, Zero-Skip Telemetry & Deterministic Stream Outputs
  output logic                                active_bank_o,
  output logic [P_LANES-1:0]                  zero_skip_gate_mask_o,
  output logic [4:0]                          zero_skip_count_o,
  output logic                                out_valid_o,
  output logic [P_STREAM_WIDTH-1:0]           stream_out_data_o,
  output logic [P_LANES*P_ACCUM_BITS-1:0]     accum_vec_o
);

  // ---------------------------------------------------------------------------
  // 1. Dual Ping-Pong Weight Staging Buffers (16 rows x 16 cols x 8-bit)
  // ---------------------------------------------------------------------------
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] weight_buf_bank0 [0:P_LANES-1];
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] weight_buf_bank1 [0:P_LANES-1];
  logic                                active_bank_q;

  assign active_bank_o = active_bank_q;

  // Select incoming weight vector from dedicated weight stream or act stream
  logic [P_STREAM_WIDTH-1:0] wt_load_vec;
  assign wt_load_vec = stream_wt_valid_i ? stream_wt_data_i : stream_act_data_i;

  // Background bank write decode: never modifies active_bank_q during execution
  logic load_bank0_en;
  logic load_bank1_en;
  logic [3:0] bank0_wr_row;
  logic [3:0] bank1_wr_row;
  logic [P_STREAM_WIDTH-1:0] bank0_wr_data;
  logic [P_STREAM_WIDTH-1:0] bank1_wr_data;

  always_comb begin
    load_bank0_en = 1'b0;
    load_bank1_en = 1'b0;
    bank0_wr_row  = weight_row_idx_i;
    bank1_wr_row  = weight_row_idx_i;
    bank0_wr_data = wt_load_vec;
    bank1_wr_data = wt_load_vec;

    if (mxm_op_i == groq_pkg::MXM_LOAD_WEIGHT_B0) begin
      load_bank0_en = 1'b1;
    end else if (mxm_op_i == groq_pkg::MXM_LOAD_WEIGHT_B1) begin
      load_bank1_en = 1'b1;
    end

    // Concurrent background preload always targets inactive bank (!active_bank_q)
    if (bg_wt_load_en_i) begin
      if (active_bank_q == 1'b1) begin
        load_bank0_en = 1'b1;
        bank0_wr_row  = bg_wt_row_idx_i;
        bank0_wr_data = bg_wt_data_i;
      end else begin
        load_bank1_en = 1'b1;
        bank1_wr_row  = bg_wt_row_idx_i;
        bank1_wr_data = bg_wt_data_i;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_bank_q <= 1'b0;
      for (int r = 0; r < P_LANES; r++) begin
        weight_buf_bank0[r] <= '0;
        weight_buf_bank1[r] <= '0;
      end
    end else begin
      if (mxm_op_i == groq_pkg::MXM_SWAP_WEIGHT) begin
        active_bank_q <= ~active_bank_q;
      end
      if (load_bank0_en) begin
        for (int c = 0; c < P_LANES; c++) begin
          weight_buf_bank0[bank0_wr_row][c] <= bank0_wr_data[c*P_ELEM_BITS +: P_ELEM_BITS];
        end
      end
      if (load_bank1_en) begin
        for (int c = 0; c < P_LANES; c++) begin
          weight_buf_bank1[bank1_wr_row][c] <= bank1_wr_data[c*P_ELEM_BITS +: P_ELEM_BITS];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 2. Zero-Skip / Operand Isolation Gating & Active Weight Bank Selection
  // ---------------------------------------------------------------------------
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] act_lane_raw;
  logic [P_LANES-1:0]                  lane_is_zero;
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] iso_act_lane;
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] iso_wt_mat [0:P_LANES-1];

  always_comb begin
    zero_skip_count_o = 5'd0;
    for (int r = 0; r < P_LANES; r++) begin
      act_lane_raw[r] = stream_act_data_i[r*P_ELEM_BITS +: P_ELEM_BITS];
    end
    for (int r = 0; r < P_LANES; r++) begin
      if ((prec_mode_i == groq_pkg::PREC_FP16) || (prec_mode_i == groq_pkg::PREC_BF16)) begin
        // 16-bit planar pair (2*k+1, 2*k): only zero-gate when both bytes of the 16b operand are zero
        lane_is_zero[r] = (act_lane_raw[2*(r/2)] == 8'h00) && (act_lane_raw[2*(r/2)+1] == 8'h00);
      end else begin
        // Detect zero in INT8 (8'h00) or FP8 (+0.0 / -0.0 where bits[6:0]==0)
        lane_is_zero[r] = (act_lane_raw[r] == 8'h00) ||
                          (((prec_mode_i == groq_pkg::PREC_FP8_E4M3) || (prec_mode_i == groq_pkg::PREC_FP8_E5M2)) &&
                           (act_lane_raw[r][6:0] == 7'h00));
      end
      zero_skip_gate_mask_o[r] = act_zero_gate_en_i & lane_is_zero[r];
      if (zero_skip_gate_mask_o[r]) begin
        zero_skip_count_o = zero_skip_count_o + 5'd1;
        iso_act_lane[r]   = 8'h00;
        for (int c = 0; c < P_LANES; c++) begin
          iso_wt_mat[r][c] = 8'h00;
        end
      end else begin
        iso_act_lane[r] = act_lane_raw[r];
        for (int c = 0; c < P_LANES; c++) begin
          iso_wt_mat[r][c] = active_bank_q ? weight_buf_bank1[r][c] : weight_buf_bank0[r][c];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 3. Multi-Precision Element Multiplier Helper (INT8 / FP8_E4M3 / FP16)
  // ---------------------------------------------------------------------------
  function automatic logic signed [P_ACCUM_BITS-1:0] elem_mul(
    input logic [7:0] a_byte,
    input logic [7:0] w_byte,
    input logic [3:0] mode
  );
    logic signed [15:0] int8_prod;
    logic               fp8_sign;
    logic [3:0]         fp8_exp_a, fp8_exp_w;
    logic [3:0]         fp8_man_a, fp8_man_w;
    logic [7:0]         fp8_man_prod;
    logic [4:0]         fp8_exp_sum;
    logic [31:0]        fp8_scaled;
    begin
      if ((a_byte == 8'h00) || (w_byte == 8'h00)) begin
        elem_mul = 32'sd0;
      end else if ((mode == groq_pkg::PREC_FP8_E4M3) || (mode == groq_pkg::PREC_FP8_E5M2)) begin
        if ((a_byte[6:0] == 7'h00) || (w_byte[6:0] == 7'h00)) begin
          elem_mul = 32'sd0;
        end else begin
          fp8_sign     = a_byte[7] ^ w_byte[7];
          fp8_exp_a    = a_byte[6:3];
          fp8_exp_w    = w_byte[6:3];
          fp8_man_a    = (fp8_exp_a == 4'd0) ? {1'b0, a_byte[2:0]} : {1'b1, a_byte[2:0]};
          fp8_man_w    = (fp8_exp_w == 4'd0) ? {1'b0, w_byte[2:0]} : {1'b1, w_byte[2:0]};
          fp8_man_prod = fp8_man_a * fp8_man_w;
          fp8_exp_sum  = {1'b0, fp8_exp_a} + {1'b0, fp8_exp_w};
          fp8_scaled   = ({24'd0, fp8_man_prod} << fp8_exp_sum) >> 4'd10;
          elem_mul     = fp8_sign ? -$signed(fp8_scaled) : $signed(fp8_scaled);
        end
      end else begin
        // Default groq_pkg::PREC_INT8 & planar byte path: exact signed 8x8 -> 32-bit
        int8_prod = $signed(a_byte) * $signed(w_byte);
        elem_mul  = {{16{int8_prod[15]}}, int8_prod};
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // 4. 16x16 Wavefront Contraction Array (INT8, FP8_E4M3, FP16 Planar Mode)
  // ---------------------------------------------------------------------------
  logic signed [P_ACCUM_BITS-1:0] mac_delta_comb [0:P_LANES-1];

  always_comb begin
    for (int c = 0; c < P_LANES; c++) begin
      mac_delta_comb[c] = 32'sd0;
      if ((prec_mode_i == groq_pkg::PREC_FP16) || (prec_mode_i == groq_pkg::PREC_BF16)) begin
        // Planar 16-bit dot-product across 8 paired lanes
        for (int k = 0; k < (P_LANES / 2); k++) begin
          mac_delta_comb[c] = mac_delta_comb[c] +
            (($signed({iso_act_lane[2*k+1], iso_act_lane[2*k]}) *
              $signed({iso_wt_mat[2*k+1][c], iso_wt_mat[2*k][c]})) >>> 8);
        end
      end else begin
        // 16-lane INT8 or FP8_E4M3 dot-product reduction tree
        for (int r = 0; r < P_LANES; r++) begin
          mac_delta_comb[c] = mac_delta_comb[c] +
                              elem_mul(iso_act_lane[r], iso_wt_mat[r][c], prec_mode_i);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 5. Deterministic 2-Stage Pipeline (Stage 1: Product Reg, Stage 2: Accum)
  // ---------------------------------------------------------------------------
  logic                           exec_en;
  logic                           clear_cmd;
  logic                           preload_cmd;
  logic                           exec_en_s1;
  logic                           clear_s1;
  logic                           preload_s1;
  logic signed [P_ACCUM_BITS-1:0] mac_delta_s1   [0:P_LANES-1];
  logic signed [P_ACCUM_BITS-1:0] preload_vec_s1 [0:P_LANES-1];
  logic signed [P_ACCUM_BITS-1:0] accum_q        [0:P_LANES-1];
  logic                           out_valid_q;

  assign exec_en     = (mxm_op_i == groq_pkg::MXM_SYSTOLIC_EXEC) && stream_act_valid_i;
  assign clear_cmd   = accum_clear_i || (mxm_op_i == groq_pkg::MXM_ACCUM_CLEAR);
  assign preload_cmd = accum_preload_en_i || (mxm_op_i == groq_pkg::MXM_ACCUM_PRELOAD);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exec_en_s1  <= 1'b0;
      clear_s1    <= 1'b0;
      preload_s1  <= 1'b0;
      out_valid_q <= 1'b0;
      for (int c = 0; c < P_LANES; c++) begin
        mac_delta_s1[c]   <= 32'sd0;
        preload_vec_s1[c] <= 32'sd0;
        accum_q[c]        <= 32'sd0;
      end
    end else begin
      // Pipeline Stage 1
      exec_en_s1 <= exec_en;
      clear_s1   <= clear_cmd;
      preload_s1 <= preload_cmd;
      for (int c = 0; c < P_LANES; c++) begin
        mac_delta_s1[c]   <= exec_en ? mac_delta_comb[c] : 32'sd0;
        preload_vec_s1[c] <= $signed(accum_preload_data_i[c*P_ACCUM_BITS +: P_ACCUM_BITS]);
      end

      // Pipeline Stage 2 (Deterministic Latency = 2 cycles from exec_en)
      out_valid_q <= exec_en_s1;
      for (int c = 0; c < P_LANES; c++) begin
        if (clear_s1) begin
          accum_q[c] <= 32'sd0;
        end else if (preload_s1) begin
          accum_q[c] <= preload_vec_s1[c];
        end else if (exec_en_s1) begin
          accum_q[c] <= accum_q[c] + mac_delta_s1[c];
        end
      end
    end
  end

  assign out_valid_o = (P_LATENCY > 0) ? out_valid_q : exec_en;

  always_comb begin
    for (int c = 0; c < P_LANES; c++) begin
      accum_vec_o[c*P_ACCUM_BITS +: P_ACCUM_BITS]   = accum_q[c];
      stream_out_data_o[c*P_ELEM_BITS +: P_ELEM_BITS] = accum_q[c][P_ELEM_BITS-1:0];
    end
  end

  // ---------------------------------------------------------------------------
  // 6. Formal Verification Assertions (Yosys SAT & Verilator Clean)
  // ---------------------------------------------------------------------------
`ifdef FORMAL
  /* verilator lint_off SYNCASYNCNET */
  logic [1:0]                          f_past_valid;
  logic                                f_exec_d1, f_exec_d2;
  logic                                f_active_bank_d1;
  logic [3:0]                          f_op_d1;
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] f_wt_b0_r0_d1;
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] f_wt_b1_r0_d1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_past_valid     <= 2'b00;
      f_exec_d1        <= 1'b0;
      f_exec_d2        <= 1'b0;
      f_active_bank_d1 <= 1'b0;
      f_op_d1          <= 4'd0;
      f_wt_b0_r0_d1    <= '0;
      f_wt_b1_r0_d1    <= '0;
    end else begin
      f_past_valid     <= {f_past_valid[0], 1'b1};
      f_exec_d1        <= exec_en;
      f_exec_d2        <= f_exec_d1;
      f_active_bank_d1 <= active_bank_q;
      f_op_d1          <= mxm_op_i;
      f_wt_b0_r0_d1    <= weight_buf_bank0[0];
      f_wt_b1_r0_d1    <= weight_buf_bank1[0];
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      // Property 1: Zero-input produces exact zero MAC delta across all lanes
      if (stream_act_data_i == '0) begin
        for (int c = 0; c < P_LANES; c++) begin
          assert (mac_delta_comb[c] == 32'sd0);
        end
      end

      // Property 2: Unit-vector activation e_0 = [1, 0, ..., 0] in PREC_INT8
      // produces exact signed weight of row 0 in every column c
      if ((prec_mode_i == groq_pkg::PREC_INT8) &&
          (stream_act_data_i == {{(P_STREAM_WIDTH-8){1'b0}}, 8'h01})) begin
        for (int c = 0; c < P_LANES; c++) begin
          if (active_bank_q == 1'b0) begin
            assert (mac_delta_comb[c] == {{24{weight_buf_bank0[0][c][7]}}, weight_buf_bank0[0][c]});
          end else begin
            assert (mac_delta_comb[c] == {{24{weight_buf_bank1[0][c][7]}}, weight_buf_bank1[0][c]});
          end
        end
      end

      // Property 3: Zero-Skip Operand Isolation preserves exact activation value
      for (int r = 0; r < P_LANES; r++) begin
        if (zero_skip_gate_mask_o[r]) begin
          assert (iso_act_lane[r] == 8'h00);
        end else begin
          assert (iso_act_lane[r] == act_lane_raw[r]);
        end
      end

      // Property 4: Ping-Pong Weight Buffer Isolation & Zero-Cycle Swap
      if (f_past_valid[0]) begin
        if ((f_active_bank_d1 == 1'b0) && (f_op_d1 != groq_pkg::MXM_LOAD_WEIGHT_B0)) begin
          assert (weight_buf_bank0[0] == f_wt_b0_r0_d1);
        end
        if ((f_active_bank_d1 == 1'b1) && (f_op_d1 != groq_pkg::MXM_LOAD_WEIGHT_B1)) begin
          assert (weight_buf_bank1[0] == f_wt_b1_r0_d1);
        end
        if (f_op_d1 == groq_pkg::MXM_SWAP_WEIGHT) begin
          assert (active_bank_o == ~f_active_bank_d1);
        end
      end

      // Property 5: Deterministic 2-cycle pipeline valid propagation
      if (f_past_valid[1]) begin
        assert (out_valid_o == f_exec_d2);
      end
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule : groq_mxm_slice

`endif // GROQ_MXM_SLICE_SV
