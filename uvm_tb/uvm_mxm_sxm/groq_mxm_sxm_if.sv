// =============================================================================
// File: uvm_tb/uvm_mxm_sxm/groq_mxm_sxm_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface & DUT Wrapper connecting Accellera
//              IEEE 1800.2-2020 UVM environment to groq_mxm_slice and
//              groq_sxm_slice, with +INJECT_DUT_BUG fault qualification.
// =============================================================================
`ifndef GROQ_MXM_SXM_IF_SV
`define GROQ_MXM_SXM_IF_SV

`include "groq_pkg.sv"

interface groq_mxm_sxm_if (
  input logic clk
);
  import groq_pkg::*;

  logic         rst_n              = 1'b0;
  logic         inject_dut_bug     = 1'b0;

  // --- MXM Slice Inputs ---
  logic [3:0]   mxm_op_i           = 4'd0;
  logic [3:0]   prec_mode_i        = 4'd0;
  logic [3:0]   weight_row_idx_i   = 4'd0;
  logic         act_zero_gate_en_i = 1'b0;
  logic         accum_clear_i      = 1'b0;
  logic         accum_preload_en_i = 1'b0;
  logic         bg_wt_load_en_i    = 1'b0;
  logic [3:0]   bg_wt_row_idx_i    = 4'd0;
  logic [127:0] bg_wt_data_i       = '0;
  logic         stream_act_valid_i = 1'b0;
  logic [127:0] stream_act_data_i  = '0;
  logic         stream_wt_valid_i  = 1'b0;
  logic [127:0] stream_wt_data_i   = '0;
  logic [511:0] accum_preload_data_i = '0;

  // --- MXM Slice Outputs ---
  logic         mxm_active_bank_o;
  logic [15:0]  mxm_zero_skip_mask_o;
  logic [4:0]   mxm_zero_skip_count_o;
  logic         mxm_out_valid_o;
  logic [127:0] mxm_stream_out_data_o;
  logic [511:0] mxm_accum_vec_o;

  // --- SXM Slice Inputs ---
  logic [3:0]   sxm_op_i           = 4'd0;
  logic [3:0]   shift_amt_i        = 4'd0;
  logic [3:0]   src_lane_i         = 4'd0;
  logic [3:0]   butterfly_mask_i   = 4'd0;
  logic [3:0]   transpose_idx_i    = 4'd0;
  logic         rope_neg_even_en_i = 1'b0;
  logic         sxm_in_valid_i     = 1'b0;
  logic [127:0] sxm_in_data_i      = '0;

  // --- SXM Slice Outputs ---
  logic         sxm_out_valid_o;
  logic [127:0] sxm_out_data_o;
  logic [127:0] sxm_perm_comb_o;

  // --- Cycle-Accurate UVM Monitor Metadata ---
  logic         sample_en          = 1'b0;
  int unsigned  tx_id              = 0;
  int unsigned  phase_id           = 0;

endinterface : groq_mxm_sxm_if

module groq_mxm_sxm_dut_wrap (
  groq_mxm_sxm_if bus
);
  logic [127:0] raw_mxm_stream_out;
  logic [511:0] raw_mxm_accum_vec;
  logic [127:0] raw_sxm_out_data;

  groq_mxm_slice u_mxm_slice (
    .clk                   (bus.clk),
    .rst_n                 (bus.rst_n),
    .mxm_op_i              (bus.mxm_op_i),
    .prec_mode_i           (bus.prec_mode_i),
    .weight_row_idx_i      (bus.weight_row_idx_i),
    .act_zero_gate_en_i    (bus.act_zero_gate_en_i),
    .accum_clear_i         (bus.accum_clear_i),
    .accum_preload_en_i    (bus.accum_preload_en_i),
    .bg_wt_load_en_i       (bus.bg_wt_load_en_i),
    .bg_wt_row_idx_i       (bus.bg_wt_row_idx_i),
    .bg_wt_data_i          (bus.bg_wt_data_i),
    .stream_act_valid_i    (bus.stream_act_valid_i),
    .stream_act_data_i     (bus.stream_act_data_i),
    .stream_wt_valid_i     (bus.stream_wt_valid_i),
    .stream_wt_data_i      (bus.stream_wt_data_i),
    .accum_preload_data_i  (bus.accum_preload_data_i),
    .active_bank_o         (bus.mxm_active_bank_o),
    .zero_skip_gate_mask_o (bus.mxm_zero_skip_mask_o),
    .zero_skip_count_o     (bus.mxm_zero_skip_count_o),
    .out_valid_o           (bus.mxm_out_valid_o),
    .stream_out_data_o     (raw_mxm_stream_out),
    .accum_vec_o           (raw_mxm_accum_vec)
  );

  groq_sxm_slice u_sxm_slice (
    .clk                   (bus.clk),
    .rst_n                 (bus.rst_n),
    .sxm_op_i              (bus.sxm_op_i),
    .shift_amt_i           (bus.shift_amt_i),
    .src_lane_i            (bus.src_lane_i),
    .butterfly_mask_i      (bus.butterfly_mask_i),
    .transpose_idx_i       (bus.transpose_idx_i),
    .rope_neg_even_en_i    (bus.rope_neg_even_en_i),
    .stream_in_valid_i     (bus.sxm_in_valid_i),
    .stream_in_data_i      (bus.sxm_in_data_i),
    .stream_out_valid_o    (bus.sxm_out_valid_o),
    .stream_out_data_o     (raw_sxm_out_data),
    .perm_comb_data_o      (bus.sxm_perm_comb_o)
  );

  assign bus.mxm_stream_out_data_o = (bus.inject_dut_bug && bus.mxm_out_valid_o) ? (raw_mxm_stream_out ^ 128'h1) : raw_mxm_stream_out;
  assign bus.mxm_accum_vec_o       = (bus.inject_dut_bug && bus.mxm_out_valid_o) ? (raw_mxm_accum_vec ^ 512'h1)  : raw_mxm_accum_vec;
  assign bus.sxm_out_data_o        = (bus.inject_dut_bug && bus.sxm_out_valid_o) ? (raw_sxm_out_data ^ 128'h1)   : raw_sxm_out_data;

endmodule : groq_mxm_sxm_dut_wrap

`endif // GROQ_MXM_SXM_IF_SV
