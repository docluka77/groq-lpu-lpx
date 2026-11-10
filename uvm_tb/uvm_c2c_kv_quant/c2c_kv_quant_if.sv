// =============================================================================
// File: uvm_tb/uvm_c2c_kv_quant/c2c_kv_quant_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface & Closed-Loop DUT Wrapper connecting
//              Accellera IEEE 1800.2-2020 UVM environment to:
//              1) groq_c2c_kv_quant_rx_engine (DUT 1: C2C KV-Cache Quantizer)
//              2) groq_mxfp8_nvfp4_dot_engine (DUT 2: Closed-Loop Dot Engine)
// =============================================================================
`ifndef C2C_KV_QUANT_IF_SV
`define C2C_KV_QUANT_IF_SV

`include "groq_pkg.sv"

interface c2c_kv_quant_if (
  input logic clk
);
  import groq_pkg::*;

  logic        rst_n        = 1'b0;
  logic        inject_fault = 1'b0;
  logic        sample_en    = 1'b0;
  int unsigned tx_id        = 0;
  int unsigned phase_id     = 0;

  // --- 1. groq_c2c_kv_quant_rx_engine Ingress & Egress ---
  logic         quant_valid_i            = 1'b0;
  logic [1:0]   quant_mode_i             = 2'd0;
  logic [127:0] kv_in_lo_i               = '0;
  logic [127:0] kv_in_hi_i               = '0;
  logic [1:0]   target_sram_bank_i       = 2'd0;
  logic [15:0]  target_sram_addr_i       = 16'd0;

  logic         quant_valid_o;
  logic [127:0] quant_vec_o;
  logic [7:0]   scale_e8m0_o;
  logic         sram_wr_en_o;
  logic [1:0]   sram_wr_bank_o;
  logic [15:0]  sram_wr_addr_o;
  logic [4:0]   zero_lanes_cnt_o;
  logic         nan_inf_clamped_o;
  logic [1:0]   compression_ratio_code_o;

  // --- 2. groq_mxfp8_nvfp4_dot_engine Closed-Loop Query Ingress & Egress ---
  logic         dot_valid_i              = 1'b0;
  logic [2:0]   dot_mode_i               = 3'd1;
  logic         dot_zero_skip_en_i       = 1'b1;
  logic         dot_accum_en_i           = 1'b0;
  logic         dot_accum_clear_i        = 1'b0;
  logic [7:0]   dot_wt_scale_i           = 8'd127;
  logic [127:0] dot_wt_stream_i          = '0;

  logic                dot_valid_o;
  logic signed [31:0]  unaccum_dot_o;
  logic signed [31:0]  int32_sum_o;
  logic [31:0]         fp32_sum_o;
  logic [5:0]          zero_skip_cnt_o;
  logic                block_zero_skipped_o;
  logic                nan_inf_flag_o;
endinterface : c2c_kv_quant_if

module c2c_kv_quant_dut_wrap (
  c2c_kv_quant_if bus
);
  logic                raw_quant_valid;
  logic [127:0]        raw_quant_vec;
  logic [7:0]          raw_scale_e8m0;
  logic                raw_sram_wr_en;
  logic [1:0]          raw_sram_wr_bank;
  logic [15:0]         raw_sram_wr_addr;
  logic [4:0]          raw_zero_lanes_cnt;
  logic                raw_nan_inf_clamped;
  logic [1:0]          raw_comp_ratio_code;

  logic                raw_dot_valid;
  logic signed [31:0]  raw_unaccum_dot;
  logic signed [31:0]  raw_int32_sum;
  logic [31:0]         raw_fp32_sum;
  logic [5:0]          raw_zero_skip_cnt;
  logic                raw_block_zero_skipped;
  logic                raw_nan_inf_flag;

  // DUT 1: C2C KV-Cache Disaggregation Receiver & Microscaling Block Quantizer
  groq_c2c_kv_quant_rx_engine #(
    .P_NUM_LANES (16),
    .P_BANK_W    (2),
    .P_ADDR_W    (16)
  ) u_kv_quant (
    .clk                      (bus.clk),
    .rst_n                    (bus.rst_n),
    .valid_i                  (bus.quant_valid_i),
    .quant_mode_i             (bus.quant_mode_i),
    .kv_in_lo_i               (bus.kv_in_lo_i),
    .kv_in_hi_i               (bus.kv_in_hi_i),
    .target_sram_bank_i       (bus.target_sram_bank_i),
    .target_sram_addr_i       (bus.target_sram_addr_i),
    .valid_o                  (raw_quant_valid),
    .quant_vec_o              (raw_quant_vec),
    .scale_e8m0_o             (raw_scale_e8m0),
    .sram_wr_en_o             (raw_sram_wr_en),
    .sram_wr_bank_o           (raw_sram_wr_bank),
    .sram_wr_addr_o           (raw_sram_wr_addr),
    .zero_lanes_cnt_o         (raw_zero_lanes_cnt),
    .nan_inf_clamped_o        (raw_nan_inf_clamped),
    .compression_ratio_code_o (raw_comp_ratio_code)
  );

  // DUT 2: Closed-Loop Microscaling Dot-Product Engine (fed directly by DUT 1)
  groq_mxfp8_nvfp4_dot_engine #(
    .P_LANES (16)
  ) u_dot_engine (
    .clk                  (bus.clk),
    .rst_n                (bus.rst_n),
    .valid_i              (bus.dot_valid_i),
    .mode_i               (bus.dot_mode_i),
    .zero_skip_en_i       (bus.dot_zero_skip_en_i),
    .accum_en_i           (bus.dot_accum_en_i),
    .accum_clear_i        (bus.dot_accum_clear_i),
    .act_scale_e8m0_i     (raw_scale_e8m0),
    .wt_scale_e8m0_i      (bus.dot_wt_scale_i),
    .act_stream_i         (raw_quant_vec),
    .wt_stream_i          (bus.dot_wt_stream_i),
    .valid_o              (raw_dot_valid),
    .unaccum_dot_o        (raw_unaccum_dot),
    .dot_accum_o          (raw_int32_sum),
    .dot_fp32_o           (raw_fp32_sum),
    .zero_skip_lanes_o    (raw_zero_skip_cnt),
    .block_zero_skipped_o (raw_block_zero_skipped),
    .nan_inf_flag_o       (raw_nan_inf_flag)
  );

  assign bus.quant_valid_o            = raw_quant_valid;
  assign bus.quant_vec_o              = bus.inject_fault ? (raw_quant_vec ^ 128'hDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0) : raw_quant_vec;
  assign bus.scale_e8m0_o             = bus.inject_fault ? (raw_scale_e8m0 ^ 8'hA5) : raw_scale_e8m0;
  assign bus.sram_wr_en_o             = raw_sram_wr_en;
  assign bus.sram_wr_bank_o           = raw_sram_wr_bank;
  assign bus.sram_wr_addr_o           = raw_sram_wr_addr;
  assign bus.zero_lanes_cnt_o         = raw_zero_lanes_cnt;
  assign bus.nan_inf_clamped_o        = raw_nan_inf_clamped;
  assign bus.compression_ratio_code_o = raw_comp_ratio_code;

  assign bus.dot_valid_o              = raw_dot_valid;
  assign bus.unaccum_dot_o            = raw_unaccum_dot;
  assign bus.int32_sum_o              = bus.inject_fault ? (raw_int32_sum ^ 32'sd65537) : raw_int32_sum;
  assign bus.fp32_sum_o               = bus.inject_fault ? (raw_fp32_sum ^ 32'h3F80_0001) : raw_fp32_sum;
  assign bus.zero_skip_cnt_o          = raw_zero_skip_cnt;
  assign bus.block_zero_skipped_o     = raw_block_zero_skipped;
  assign bus.nan_inf_flag_o           = raw_nan_inf_flag;
endmodule : c2c_kv_quant_dut_wrap

`endif // C2C_KV_QUANT_IF_SV
