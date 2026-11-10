// =============================================================================
// File: uvm_tb/uvm_lpx_mxfp8_dma/lpx_mxfp8_dma_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface & DUT Wrapper connecting Accellera
//              IEEE 1800.2-2020 UVM environment to groq_mxfp8_nvfp4_dot_engine,
//              groq_c2c_serdes_pcs, and groq_pcie_c2c_dma.
// =============================================================================
`ifndef LPX_MXFP8_DMA_IF_SV
`define LPX_MXFP8_DMA_IF_SV

`include "groq_pkg.sv"

interface lpx_mxfp8_dma_if (
 input logic clk
);
 import groq_pkg::*;

 logic rst_n = 1'b0;
 logic inject_fault = 1'b0;

 // --- 1. groq_mxfp8_nvfp4_dot_engine Signals ---
 logic dot_valid_i = 1'b0;
 logic [2:0] dot_mode_i = 3'd0;
 logic dot_zero_skip_en_i = 1'b0;
 logic dot_accum_en_i = 1'b0;
 logic dot_accum_clear_i = 1'b0;
 logic [7:0] dot_act_scale_i = 8'd0;
 logic [7:0] dot_wt_scale_i = 8'd0;
 logic [127:0] dot_act_stream_i = '0;
 logic [127:0] dot_wt_stream_i = '0;

 logic dot_valid_o;
 logic signed [31:0] dot_unaccum_o;
 logic signed [31:0] dot_accum_o;
 logic [31:0] dot_fp32_o;
 logic [5:0] dot_zero_skip_lanes_o;
 logic dot_block_zero_skipped_o;
 logic dot_nan_inf_flag_o;

 // --- 2. groq_c2c_serdes_pcs Signals ---
 logic pcs_link_enable_i = 1'b0;
 logic pcs_scramble_en_i = 1'b0;
 logic pcs_rx_ts1_seen_i = 1'b0;
 logic pcs_rx_ts2_seen_i = 1'b0;
 logic pcs_deskew_done_i = 1'b0;
 logic pcs_retrain_req_i = 1'b0;
 logic [7:0] pcs_local_realsync_cnt_i = 8'd0;
 logic [7:0] pcs_rx_beacon_ts_i = 8'd0;
 logic pcs_tx_flit_valid_i = 1'b0;
 logic [127:0] pcs_tx_flit_data_i = '0;
 logic [3:0] pcs_tx_dst_chip_i = 4'd0;
 logic [3:0] pcs_tx_hop_cnt_i = 4'd0;
 logic [3:0] pcs_tx_opcode_i = 4'd0;
 logic pcs_nack_req_i = 1'b0;
 logic [1:0] pcs_nack_seq_i = 2'd0;
 logic pcs_phy_rx_valid_i = 1'b0;
 logic [161:0] pcs_phy_rx_frame_i = '0;

 logic pcs_tx_ready_o;
 logic pcs_phy_tx_valid_o;
 logic [161:0] pcs_phy_tx_frame_o;
 logic [1:0] pcs_tx_sync_hdr_o;
 logic [15:0] pcs_tx_crc16_o;
 logic [15:0] pcs_tx_meta_o;
 logic [127:0] pcs_tx_scrambled_payload_o;
 logic pcs_replay_active_o;
 logic [3:0] pcs_tx_seq_num_o;
 logic pcs_rx_flit_valid_o;
 logic [127:0] pcs_rx_flit_data_o;
 logic [3:0] pcs_rx_dst_chip_o;
 logic [3:0] pcs_rx_hop_cnt_o;
 logic [3:0] pcs_rx_opcode_o;
 logic [3:0] pcs_rx_seq_num_o;
 logic pcs_rx_crc16_err_o;
 logic pcs_rx_sync_err_o;
 logic pcs_nack_req_o;
 logic [1:0] pcs_nack_seq_o;
 logic [2:0] pcs_link_state_o;
 logic pcs_link_up_o;
 logic [7:0] pcs_measured_skew_o;

  // --- 3. groq_pcie_c2c_dma Signals ---
  logic [15:0]        dma_global_cycle_i        = 16'd0;
  logic               dma_vliw_active_window_i  = 1'b0;
  logic               dma_vliw_sram_busy_i      = 1'b0;
  logic               dma_vliw_sram_w_busy_i    = 1'b0;
  logic               dma_vliw_sram_e_busy_i    = 1'b0;
  logic               dma_desc_push_valid_i     = 1'b0;
  logic [127:0]       dma_desc_push_data_i      = '0;
  logic               dma_payload_valid_i       = 1'b0;
  logic [127:0]       dma_payload_data_i        = '0;
  logic [15:0]        dma_payload_parity_i      = 16'd0;

  logic               dma_desc_push_ready_o;
  logic               dma_full_o;
  logic               dma_empty_o;
  logic [1:0]         dma_head_ptr_o;
  logic [1:0]         dma_tail_ptr_o;
  logic [2:0]         dma_desc_count_o;
  logic               dma_payload_ready_o;
  logic               dma_imem_wr_en_o;
  logic [2:0]         dma_imem_wr_slice_o;
  logic [15:0]        dma_imem_wr_addr_o;
  logic [143:0]       dma_imem_wr_data_o;
  logic               dma_host_mem_w_wr_en_o;
  logic [1:0]         dma_host_mem_w_bank_o;
  logic [15:0]        dma_host_mem_w_addr_o;
  logic [127:0]       dma_host_mem_w_data_o;
  logic               dma_host_mem_e_wr_en_o;
  logic [1:0]         dma_host_mem_e_bank_o;
  logic [15:0]        dma_host_mem_e_addr_o;
  logic [127:0]       dma_host_mem_e_data_o;
  logic               dma_busy_o;
  logic               dma_window_stall_o;
  logic               dma_payload_parity_err_o;
  logic               dma_done_irq_o;
  logic [7:0]         dma_completed_desc_cnt_o;
  logic [15:0]        dma_beats_transferred_o;

  // --- Cycle-Accurate UVM Monitor Metadata ---
  logic               sample_en                 = 1'b0;
  int unsigned        tx_id                     = 0;
  int unsigned        phase_id                  = 0;

endinterface : lpx_mxfp8_dma_if

module lpx_mxfp8_dma_dut_wrap (
  lpx_mxfp8_dma_if bus
);
  logic signed [31:0] raw_dot_unaccum;
  logic signed [31:0] raw_dot_accum;
  logic [31:0]        raw_dot_fp32;
  logic [161:0]       raw_pcs_phy_tx_frame;
  logic [127:0]       raw_pcs_rx_flit_data;
  logic [143:0]       raw_dma_imem_wr_data;
  logic [127:0]       raw_dma_host_mem_w_data;
  logic [127:0]       raw_dma_host_mem_e_data;

  groq_mxfp8_nvfp4_dot_engine u_dot_engine (
    .clk                  (bus.clk),
    .rst_n                (bus.rst_n),
    .valid_i              (bus.dot_valid_i),
    .mode_i               (bus.dot_mode_i),
    .zero_skip_en_i       (bus.dot_zero_skip_en_i),
    .accum_en_i           (bus.dot_accum_en_i),
    .accum_clear_i        (bus.dot_accum_clear_i),
    .act_scale_e8m0_i     (bus.dot_act_scale_i),
    .wt_scale_e8m0_i      (bus.dot_wt_scale_i),
    .act_stream_i         (bus.dot_act_stream_i),
    .wt_stream_i          (bus.dot_wt_stream_i),
    .valid_o              (bus.dot_valid_o),
    .unaccum_dot_o        (raw_dot_unaccum),
    .dot_accum_o          (raw_dot_accum),
    .dot_fp32_o           (raw_dot_fp32),
    .zero_skip_lanes_o    (bus.dot_zero_skip_lanes_o),
    .block_zero_skipped_o (bus.dot_block_zero_skipped_o),
    .nan_inf_flag_o       (bus.dot_nan_inf_flag_o)
  );

  groq_c2c_serdes_pcs u_serdes_pcs (
    .clk                    (bus.clk),
    .rst_n                  (bus.rst_n),
    .link_enable_i          (bus.pcs_link_enable_i),
    .scramble_en_i          (bus.pcs_scramble_en_i),
    .rx_ts1_seen_i          (bus.pcs_rx_ts1_seen_i),
    .rx_ts2_seen_i          (bus.pcs_rx_ts2_seen_i),
    .deskew_done_i          (bus.pcs_deskew_done_i),
    .retrain_req_i          (bus.pcs_retrain_req_i),
    .local_realsync_cnt_i   (bus.pcs_local_realsync_cnt_i),
    .rx_beacon_ts_i         (bus.pcs_rx_beacon_ts_i),
    .tx_flit_valid_i        (bus.pcs_tx_flit_valid_i),
    .tx_flit_data_i         (bus.pcs_tx_flit_data_i),
    .tx_dst_chip_i          (bus.pcs_tx_dst_chip_i),
    .tx_hop_cnt_i           (bus.pcs_tx_hop_cnt_i),
    .tx_opcode_i            (bus.pcs_tx_opcode_i),
    .tx_ready_o             (bus.pcs_tx_ready_o),
    .nack_req_i             (bus.pcs_nack_req_i),
    .nack_seq_i             (bus.pcs_nack_seq_i),
    .phy_tx_valid_o         (bus.pcs_phy_tx_valid_o),
    .phy_tx_frame_o         (raw_pcs_phy_tx_frame),
    .tx_sync_hdr_o          (bus.pcs_tx_sync_hdr_o),
    .tx_crc16_o             (bus.pcs_tx_crc16_o),
    .tx_meta_o              (bus.pcs_tx_meta_o),
    .tx_scrambled_payload_o (bus.pcs_tx_scrambled_payload_o),
    .replay_active_o        (bus.pcs_replay_active_o),
    .tx_seq_num_o           (bus.pcs_tx_seq_num_o),
    .phy_rx_valid_i         (bus.pcs_phy_rx_valid_i),
    .phy_rx_frame_i         (bus.pcs_phy_rx_frame_i),
    .rx_flit_valid_o        (bus.pcs_rx_flit_valid_o),
    .rx_flit_data_o         (raw_pcs_rx_flit_data),
    .rx_dst_chip_o          (bus.pcs_rx_dst_chip_o),
    .rx_hop_cnt_o           (bus.pcs_rx_hop_cnt_o),
    .rx_opcode_o            (bus.pcs_rx_opcode_o),
    .rx_seq_num_o           (bus.pcs_rx_seq_num_o),
    .rx_crc16_err_o         (bus.pcs_rx_crc16_err_o),
    .rx_sync_err_o          (bus.pcs_rx_sync_err_o),
    .nack_req_o             (bus.pcs_nack_req_o),
    .nack_seq_o             (bus.pcs_nack_seq_o),
    .link_state_o           (bus.pcs_link_state_o),
    .link_up_o              (bus.pcs_link_up_o),
    .measured_skew_o        (bus.pcs_measured_skew_o)
  );

  groq_pcie_c2c_dma u_pcie_dma (
    .clk                    (bus.clk),
    .rst_n                  (bus.rst_n),
    .global_cycle_i         (bus.dma_global_cycle_i),
    .vliw_active_window_i   (bus.dma_vliw_active_window_i),
    .vliw_sram_busy_i       (bus.dma_vliw_sram_busy_i),
    .vliw_sram_w_busy_i     (bus.dma_vliw_sram_w_busy_i),
    .vliw_sram_e_busy_i     (bus.dma_vliw_sram_e_busy_i),
    .desc_push_valid_i      (bus.dma_desc_push_valid_i),
    .desc_push_data_i       (bus.dma_desc_push_data_i),
    .desc_push_ready_o      (bus.dma_desc_push_ready_o),
    .full_o                 (bus.dma_full_o),
    .empty_o                (bus.dma_empty_o),
    .head_ptr_o             (bus.dma_head_ptr_o),
    .tail_ptr_o             (bus.dma_tail_ptr_o),
    .desc_count_o           (bus.dma_desc_count_o),
    .dma_payload_valid_i    (bus.dma_payload_valid_i),
    .dma_payload_data_i     (bus.dma_payload_data_i),
    .dma_payload_parity_i   (bus.dma_payload_parity_i),
    .dma_payload_ready_o    (bus.dma_payload_ready_o),
    .imem_wr_en_o           (bus.dma_imem_wr_en_o),
    .imem_wr_slice_o        (bus.dma_imem_wr_slice_o),
    .imem_wr_addr_o         (bus.dma_imem_wr_addr_o),
    .imem_wr_data_o         (raw_dma_imem_wr_data),
    .host_mem_w_wr_en_o     (bus.dma_host_mem_w_wr_en_o),
    .host_mem_w_bank_o      (bus.dma_host_mem_w_bank_o),
    .host_mem_w_addr_o      (bus.dma_host_mem_w_addr_o),
    .host_mem_w_data_o      (raw_dma_host_mem_w_data),
    .host_mem_e_wr_en_o     (bus.dma_host_mem_e_wr_en_o),
    .host_mem_e_bank_o      (bus.dma_host_mem_e_bank_o),
    .host_mem_e_addr_o      (bus.dma_host_mem_e_addr_o),
    .host_mem_e_data_o      (raw_dma_host_mem_e_data),
    .dma_busy_o             (bus.dma_busy_o),
    .dma_window_stall_o     (bus.dma_window_stall_o),
    .payload_parity_err_o   (bus.dma_payload_parity_err_o),
    .dma_done_irq_o         (bus.dma_done_irq_o),
    .completed_desc_cnt_o   (bus.dma_completed_desc_cnt_o),
    .beats_transferred_o    (bus.dma_beats_transferred_o)
  );

  assign bus.dot_unaccum_o           = (bus.inject_fault && bus.dot_valid_o)            ? (raw_dot_unaccum ^ 32'sh1)            : raw_dot_unaccum;
  assign bus.dot_accum_o             = (bus.inject_fault && bus.dot_valid_o)            ? (raw_dot_accum ^ 32'sh1)              : raw_dot_accum;
  assign bus.dot_fp32_o              = (bus.inject_fault && bus.dot_valid_o)            ? (raw_dot_fp32 ^ 32'h0000_0001)        : raw_dot_fp32;
  assign bus.pcs_phy_tx_frame_o      = (bus.inject_fault && bus.pcs_phy_tx_valid_o)     ? (raw_pcs_phy_tx_frame ^ 162'h1)       : raw_pcs_phy_tx_frame;
  assign bus.pcs_rx_flit_data_o      = (bus.inject_fault && bus.pcs_rx_flit_valid_o)    ? (raw_pcs_rx_flit_data ^ 128'h1)       : raw_pcs_rx_flit_data;
  assign bus.dma_imem_wr_data_o      = (bus.inject_fault && bus.dma_imem_wr_en_o)       ? (raw_dma_imem_wr_data ^ 144'h1)       : raw_dma_imem_wr_data;
  assign bus.dma_host_mem_w_data_o   = (bus.inject_fault && bus.dma_host_mem_w_wr_en_o) ? (raw_dma_host_mem_w_data ^ 128'h1)    : raw_dma_host_mem_w_data;
  assign bus.dma_host_mem_e_data_o   = (bus.inject_fault && bus.dma_host_mem_e_wr_en_o) ? (raw_dma_host_mem_e_data ^ 128'h1)    : raw_dma_host_mem_e_data;

endmodule : lpx_mxfp8_dma_dut_wrap

`endif // LPX_MXFP8_DMA_IF_SV
