// =============================================================================
// File: uvm_tb/uvm_dragonfly_8chip/dragonfly_8chip_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface & DUT Wrapper connecting Accellera
//              IEEE 1800.2-2020 UVM environment to groq_dragonfly_8chip_cluster
//              (8-Chip Dragonfly Group Scale-Out Cluster + PCS + Host DMA).
// =============================================================================
`ifndef DRAGONFLY_8CHIP_IF_SV
`define DRAGONFLY_8CHIP_IF_SV

`include "groq_pkg.sv"

interface dragonfly_8chip_if (
 input logic clk
);
 import groq_pkg::*;

 localparam int P_NUM_CHIPS = 8;

 logic rst_n = 1'b0;
 logic inject_fault = 1'b0;

 // 1. Per-Chip ICU Dispatch & VLIW Program Bundle Interface
 logic [P_NUM_CHIPS-1:0] chip_icu_enable_i = '0;
 logic [P_NUM_CHIPS-1:0][NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] chip_imem_vliw_bundle_i = '0;
 logic [P_NUM_CHIPS-1:0][NUM_SLICES-1:0][15:0] chip_pc_slice_o;
 logic [P_NUM_CHIPS-1:0][NUM_SLICES-1:0] chip_slice_halted_o;

 // 2. Cluster-Level Host NVLink-C2C / PCIe Gen5 DMA Controller Interface
 logic [15:0] global_cycle_i = 16'd0;
 logic [2:0] dma_target_chip_i = 3'd0;
 logic dma_bcast_all_chips_i = 1'b0;
 logic dma_vliw_sram_busy_i = 1'b0;
 logic dma_desc_push_valid_i = 1'b0;
 logic [127:0] dma_desc_push_data_i = '0;
 logic dma_desc_push_ready_o;
 logic dma_payload_valid_i = 1'b0;
 logic [STREAM_WIDTH-1:0] dma_payload_data_i = '0;
 logic [15:0] dma_payload_parity_i = 16'd0;
 logic dma_payload_ready_o;
 logic dma_busy_o;
 logic dma_window_stall_o;
 logic dma_parity_err_o;
 logic dma_done_irq_o;
 logic [7:0] dma_completed_desc_cnt_o;
 logic [15:0] dma_beats_transferred_o;

 // 3. Dragonfly Group Multi-Topology Routing & Collective Control
 logic [1:0] cluster_route_mode_i = 2'b00;
 logic ring_dir_west_i = 1'b0;
 logic [P_NUM_CHIPS-1:0] congestion_mask_i = '0;
 logic [2:0] butterfly_stage_i = 3'd1;

 // 4. PCS Link Training, Plesiochronous Delay & Error Injection Control
 logic pcs_link_enable_i = 1'b0;
 logic pcs_scramble_en_i = 1'b1;
 logic pcs_rx_ts1_seen_i = 1'b0;
 logic pcs_rx_ts2_seen_i = 1'b0;
 logic pcs_deskew_done_i = 1'b0;
 logic pcs_retrain_req_i = 1'b0;
 logic [P_NUM_CHIPS-1:0] link_delay_en_i = '0;
 logic [15:0] expected_flight_cycles_i = 16'd4;
 logic [P_NUM_CHIPS-1:0] pcs_err_inject_en_i = '0;
 logic [15:0] pcs_err_inject_mask_i = 16'h0000;
 logic [P_NUM_CHIPS-1:0] mem_err_inject_en_i = '0;
 logic [143:0] mem_err_inject_mask_i = '0;

  // 5. Cluster-Wide Hardware Sync, Stream Observation & Fault Telemetry
  logic                                     cluster_all_halted_o;
  logic                                     cluster_any_barrier_o;
  logic [P_NUM_CHIPS-1:0]                   cluster_pcs_link_up_o;
  logic [P_NUM_CHIPS-1:0]                   cluster_crc16_err_o;
  logic [P_NUM_CHIPS-1:0]                   cluster_realsync_err_o;
  logic [P_NUM_CHIPS-1:0]                   cluster_ecc_single_err_o;
  logic [P_NUM_CHIPS-1:0]                   cluster_ecc_double_err_o;
  logic [P_NUM_CHIPS-1:0]                   cluster_c2c_tx_valid_o;
  logic [P_NUM_CHIPS-1:0]                   cluster_deskew_release_o;
  logic [P_NUM_CHIPS-1:0][2:0]              cluster_routed_dst_o;
  logic [P_NUM_CHIPS-1:0][STREAM_WIDTH-1:0] cluster_nim_rx_data_o;

  // 6. UVM Transaction & Phase Tracking Metadata
  logic        sample_en      = 1'b0;
  int unsigned tx_id          = 0;
  int unsigned phase_id       = 0;
  logic [1:0]  cov_dma_target = 2'b00;
  logic [1:0]  cov_ecc_kind   = 2'b00; // 0=none, 1=single-bit, 2=double-bit

endinterface : dragonfly_8chip_if

module dragonfly_8chip_dut_wrap (
  dragonfly_8chip_if bus
);
  import groq_pkg::*;
  localparam int P_NUM_CHIPS = 8;

  logic [P_NUM_CHIPS-1:0][2:0]              raw_routed_dst;
  logic [P_NUM_CHIPS-1:0][STREAM_WIDTH-1:0] raw_nim_rx_data;
  logic [7:0]                               raw_dma_desc_cnt;

  groq_dragonfly_8chip_cluster #(
    .P_NUM_CHIPS (P_NUM_CHIPS)
  ) u_dut (
    .clk                      (bus.clk),
    .rst_n                    (bus.rst_n),
    .chip_icu_enable_i        (bus.chip_icu_enable_i),
    .chip_imem_vliw_bundle_i  (bus.chip_imem_vliw_bundle_i),
    .chip_pc_slice_o          (bus.chip_pc_slice_o),
    .chip_slice_halted_o      (bus.chip_slice_halted_o),
    .global_cycle_i           (bus.global_cycle_i),
    .dma_target_chip_i        (bus.dma_target_chip_i),
    .dma_bcast_all_chips_i    (bus.dma_bcast_all_chips_i),
    .dma_vliw_sram_busy_i     (bus.dma_vliw_sram_busy_i),
    .dma_desc_push_valid_i    (bus.dma_desc_push_valid_i),
    .dma_desc_push_data_i     (bus.dma_desc_push_data_i),
    .dma_desc_push_ready_o    (bus.dma_desc_push_ready_o),
    .dma_payload_valid_i      (bus.dma_payload_valid_i),
    .dma_payload_data_i       (bus.dma_payload_data_i),
    .dma_payload_parity_i     (bus.dma_payload_parity_i),
    .dma_payload_ready_o      (bus.dma_payload_ready_o),
    .dma_busy_o               (bus.dma_busy_o),
    .dma_window_stall_o       (bus.dma_window_stall_o),
    .dma_parity_err_o         (bus.dma_parity_err_o),
    .dma_done_irq_o           (bus.dma_done_irq_o),
    .dma_completed_desc_cnt_o (raw_dma_desc_cnt),
    .dma_beats_transferred_o  (bus.dma_beats_transferred_o),
    .cluster_route_mode_i     (bus.cluster_route_mode_i),
    .ring_dir_west_i          (bus.ring_dir_west_i),
    .congestion_mask_i        (bus.congestion_mask_i),
    .butterfly_stage_i        (bus.butterfly_stage_i),
    .pcs_link_enable_i        (bus.pcs_link_enable_i),
    .pcs_scramble_en_i        (bus.pcs_scramble_en_i),
    .pcs_rx_ts1_seen_i        (bus.pcs_rx_ts1_seen_i),
    .pcs_rx_ts2_seen_i        (bus.pcs_rx_ts2_seen_i),
    .pcs_deskew_done_i        (bus.pcs_deskew_done_i),
    .pcs_retrain_req_i        (bus.pcs_retrain_req_i),
    .link_delay_en_i          (bus.link_delay_en_i),
    .expected_flight_cycles_i (bus.expected_flight_cycles_i),
    .pcs_err_inject_en_i      (bus.pcs_err_inject_en_i),
    .pcs_err_inject_mask_i    (bus.pcs_err_inject_mask_i),
    .mem_err_inject_en_i      (bus.mem_err_inject_en_i),
    .mem_err_inject_mask_i    (bus.mem_err_inject_mask_i),
    .cluster_all_halted_o     (bus.cluster_all_halted_o),
    .cluster_any_barrier_o    (bus.cluster_any_barrier_o),
    .cluster_pcs_link_up_o    (bus.cluster_pcs_link_up_o),
    .cluster_crc16_err_o      (bus.cluster_crc16_err_o),
    .cluster_realsync_err_o   (bus.cluster_realsync_err_o),
    .cluster_ecc_single_err_o (bus.cluster_ecc_single_err_o),
    .cluster_ecc_double_err_o (bus.cluster_ecc_double_err_o),
    .cluster_c2c_tx_valid_o   (bus.cluster_c2c_tx_valid_o),
    .cluster_deskew_release_o (bus.cluster_deskew_release_o),
    .cluster_routed_dst_o     (raw_routed_dst),
    .cluster_nim_rx_data_o    (raw_nim_rx_data)
  );

  always_comb begin
    bus.cluster_routed_dst_o     = raw_routed_dst;
    bus.cluster_nim_rx_data_o    = raw_nim_rx_data;
    bus.dma_completed_desc_cnt_o = raw_dma_desc_cnt;
    if (bus.inject_fault) begin
      bus.cluster_routed_dst_o[0]  = raw_routed_dst[0] ^ 3'b101;
      bus.cluster_nim_rx_data_o[0] = raw_nim_rx_data[0] ^ 128'hDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0;
      bus.dma_completed_desc_cnt_o = raw_dma_desc_cnt ^ 8'hFF;
    end
  end

endmodule : dragonfly_8chip_dut_wrap

`endif // DRAGONFLY_8CHIP_IF_SV
