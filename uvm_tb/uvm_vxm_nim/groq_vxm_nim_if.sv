// =============================================================================
// File: uvm_tb/uvm_vxm_nim/groq_vxm_nim_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface & DUT Wrapper connecting Accellera
//              IEEE 1800.2-2020 UVM environment to groq_vxm_slice and
//              groq_nim_realsync, with +INJECT_DUT_BUG fault qualification.
// =============================================================================
`ifndef GROQ_VXM_NIM_IF_SV
`define GROQ_VXM_NIM_IF_SV

`include "groq_pkg.sv"

interface groq_vxm_nim_if (
  input logic clk
);
  import groq_pkg::*;

  logic         rst_n                    = 1'b0;
  logic         inject_dut_bug           = 1'b0;

  // --- VXM Slice Inputs ---
  logic         vxm_op_valid_i           = 1'b0;
  logic [3:0]   vxm_op_i                 = 4'd0;
  logic [3:0]   prec_mode_i              = 4'd0;
  logic [2:0]   quant_shift_i            = 3'd0;
  logic         use_accum_32b_i          = 1'b0;
  logic [127:0] stream_a_i               = '0;
  logic [127:0] stream_b_i               = '0;
  logic [127:0] stream_c_i               = '0;
  logic [511:0] accum_32b_in_i           = '0;

  // --- VXM Slice Outputs ---
  logic         vxm_out_valid_o;
  logic [127:0] vxm_out_data_o;
  logic [511:0] vxm_accum_32b_out_o;
  logic [127:0] vxm_comb_data_o;
  logic signed [15:0] vxm_reduce_sum_o;
  logic signed [7:0]  vxm_reduce_max_o;
  logic         vxm_mul_gate_active_o;
  logic         vxm_lut_gate_active_o;

  // --- NIM RealSync Slice Inputs ---
  logic         nim_op_valid_i           = 1'b0;
  logic [3:0]   nim_op_i                 = 4'd0;
  logic [15:0]  realsync_aligned_time_i  = 16'd0;
  logic [15:0]  expected_flight_cycles_i = 16'd0;
  logic [3:0]   local_chip_id_i          = 4'd0;
  logic [3:0]   tx_dst_chip_i            = 4'd0;
  logic         ugal_nonminimal_en_i     = 1'b0;
  logic         link_congested_i         = 1'b0;
  logic         local_stream_in_valid_i  = 1'b0;
  logic [127:0] local_stream_in_data_i   = '0;
  logic         c2c_rx_valid_i           = 1'b0;
  logic [127:0] c2c_rx_data_i            = '0;
  logic [15:0]  c2c_rx_tx_timestamp_i    = 16'd0;
  logic [3:0]   c2c_rx_dst_chip_i        = 4'd0;
  logic [7:0]   c2c_rx_crc8_i            = 8'd0;

  // --- NIM RealSync Slice Outputs ---
  logic         nim_local_out_valid_o;
  logic [127:0] nim_local_out_data_o;
  logic         c2c_tx_valid_o;
  logic [127:0] c2c_tx_data_o;
  logic [15:0]  c2c_tx_timestamp_o;
  logic [3:0]   c2c_tx_dst_chip_o;
  logic [7:0]   c2c_tx_crc8_o;
  logic [1:0]   c2c_tx_port_sel_o;
  logic         deskew_release_valid_o;
  logic [15:0]  deskew_released_target_cycle_o;
  logic         realsync_ping_ack_o;
  logic signed [15:0] measured_skew_o;
  logic         crc_err_o;

  // --- Cycle-Accurate UVM Monitor Metadata ---
  logic         sample_en                = 1'b0;
  int unsigned  tx_id                    = 0;
  int unsigned  phase_id                 = 0;

endinterface : groq_vxm_nim_if

module groq_vxm_nim_dut_wrap (
  groq_vxm_nim_if bus
);
  logic [127:0] raw_vxm_out_data;
  logic [511:0] raw_vxm_accum_out;
  logic [127:0] raw_vxm_comb_data;
  logic [127:0] raw_nim_local_out;
  logic [127:0] raw_c2c_tx_data;

  groq_vxm_slice u_vxm_slice (
    .clk                  (bus.clk),
    .rst_n                (bus.rst_n),
    .op_valid_i           (bus.vxm_op_valid_i),
    .vxm_op_i             (bus.vxm_op_i),
    .prec_mode_i          (bus.prec_mode_i),
    .quant_shift_i        (bus.quant_shift_i),
    .use_accum_32b_i      (bus.use_accum_32b_i),
    .stream_a_i           (bus.stream_a_i),
    .stream_b_i           (bus.stream_b_i),
    .stream_c_i           (bus.stream_c_i),
    .accum_32b_in_i       (bus.accum_32b_in_i),
    .stream_out_valid_o   (bus.vxm_out_valid_o),
    .stream_out_data_o    (raw_vxm_out_data),
    .accum_32b_out_o      (raw_vxm_accum_out),
    .vxm_comb_data_o      (raw_vxm_comb_data),
    .reduce_sum_scalar_o  (bus.vxm_reduce_sum_o),
    .reduce_max_scalar_o  (bus.vxm_reduce_max_o),
    .mul_gate_active_o    (bus.vxm_mul_gate_active_o),
    .lut_gate_active_o    (bus.vxm_lut_gate_active_o)
  );

  groq_nim_realsync u_nim_realsync (
    .clk                            (bus.clk),
    .rst_n                          (bus.rst_n),
    .op_valid_i                     (bus.nim_op_valid_i),
    .nim_op_i                       (bus.nim_op_i),
    .realsync_aligned_time_i        (bus.realsync_aligned_time_i),
    .expected_flight_cycles_i       (bus.expected_flight_cycles_i),
    .local_chip_id_i                (bus.local_chip_id_i),
    .tx_dst_chip_i                  (bus.tx_dst_chip_i),
    .ugal_nonminimal_en_i           (bus.ugal_nonminimal_en_i),
    .link_congested_i               (bus.link_congested_i),
    .local_stream_in_valid_i        (bus.local_stream_in_valid_i),
    .local_stream_in_data_i         (bus.local_stream_in_data_i),
    .local_stream_out_valid_o       (bus.nim_local_out_valid_o),
    .local_stream_out_data_o        (raw_nim_local_out),
    .c2c_rx_valid_i                 (bus.c2c_rx_valid_i),
    .c2c_rx_data_i                  (bus.c2c_rx_data_i),
    .c2c_rx_tx_timestamp_i          (bus.c2c_rx_tx_timestamp_i),
    .c2c_rx_dst_chip_i              (bus.c2c_rx_dst_chip_i),
    .c2c_rx_crc8_i                  (bus.c2c_rx_crc8_i),
    .c2c_tx_valid_o                 (bus.c2c_tx_valid_o),
    .c2c_tx_data_o                  (raw_c2c_tx_data),
    .c2c_tx_timestamp_o             (bus.c2c_tx_timestamp_o),
    .c2c_tx_dst_chip_o              (bus.c2c_tx_dst_chip_o),
    .c2c_tx_crc8_o                  (bus.c2c_tx_crc8_o),
    .c2c_tx_port_sel_o              (bus.c2c_tx_port_sel_o),
    .deskew_release_valid_o         (bus.deskew_release_valid_o),
    .deskew_released_target_cycle_o (bus.deskew_released_target_cycle_o),
    .realsync_ping_ack_o            (bus.realsync_ping_ack_o),
    .measured_skew_o                (bus.measured_skew_o),
    .crc_err_o                      (bus.crc_err_o)
  );

  assign bus.vxm_out_data_o       = (bus.inject_dut_bug && bus.vxm_out_valid_o)       ? (raw_vxm_out_data ^ 128'h1)  : raw_vxm_out_data;
  assign bus.vxm_accum_32b_out_o  = (bus.inject_dut_bug && bus.vxm_out_valid_o)       ? (raw_vxm_accum_out ^ 512'h1) : raw_vxm_accum_out;
  assign bus.vxm_comb_data_o      = (bus.inject_dut_bug && bus.vxm_op_valid_i)        ? (raw_vxm_comb_data ^ 128'h1) : raw_vxm_comb_data;
  assign bus.nim_local_out_data_o = (bus.inject_dut_bug && bus.nim_local_out_valid_o) ? (raw_nim_local_out ^ 128'h1) : raw_nim_local_out;
  assign bus.c2c_tx_data_o        = (bus.inject_dut_bug && bus.c2c_tx_valid_o)        ? (raw_c2c_tx_data ^ 128'h1)   : raw_c2c_tx_data;

endmodule : groq_vxm_nim_dut_wrap

`endif // GROQ_VXM_NIM_IF_SV
