// =============================================================================
// File: uvm_tb/uvm_full_chip/groq_full_chip_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface & DUT Wrapper connecting Accellera
//              IEEE 1800.2-2020 UVM environment to groq_lpu_cluster_top
//              (2 x groq_lpu_top chips connected via Dragonfly C2C + RealSync),
//              with +INJECT_FULL_CHIP_BUG fault qualification.
// =============================================================================
`ifndef GROQ_FULL_CHIP_IF_SV
`define GROQ_FULL_CHIP_IF_SV

`include "groq_pkg.sv"

interface groq_full_chip_if (
 input logic clk
);
 import groq_pkg::*;

 logic rst_n = 1'b0;
 logic inject_full_chip_bug = 1'b0;

 // --- 1. Cluster ICU Enable & Per-Chip VLIW Program Dispatch ---
 logic chip0_icu_enable_i = 1'b0;
 logic [NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] chip0_imem_vliw_bundle_i = '0;
 logic [NUM_SLICES-1:0][15:0] chip0_pc_slice_o;
 logic [NUM_SLICES-1:0] chip0_slice_halted_o;

 logic chip1_icu_enable_i = 1'b0;
 logic [NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] chip1_imem_vliw_bundle_i = '0;
 logic [NUM_SLICES-1:0][15:0] chip1_pc_slice_o;
 logic [NUM_SLICES-1:0] chip1_slice_halted_o;

 // --- 2. Host DMA SRAM Preload Interface (Chip 0 & Chip 1 West & East) ---
 logic chip0_host_mem_w_wr_en_i = 1'b0;
 logic [1:0] chip0_host_mem_w_bank_i = '0;
 logic [9:0] chip0_host_mem_w_addr_i = '0;
 logic [STREAM_WIDTH-1:0] chip0_host_mem_w_data_i = '0;

 logic chip1_host_mem_w_wr_en_i = 1'b0;
 logic [1:0] chip1_host_mem_w_bank_i = '0;
 logic [9:0] chip1_host_mem_w_addr_i = '0;
 logic [STREAM_WIDTH-1:0] chip1_host_mem_w_data_i = '0;

 logic chip0_host_mem_e_wr_en_i = 1'b0;
 logic [1:0] chip0_host_mem_e_bank_i = '0;
 logic [9:0] chip0_host_mem_e_addr_i = '0;
 logic [STREAM_WIDTH-1:0] chip0_host_mem_e_data_i = '0;

 logic chip1_host_mem_e_wr_en_i = 1'b0;
 logic [1:0] chip1_host_mem_e_bank_i = '0;
 logic [9:0] chip1_host_mem_e_addr_i = '0;
 logic [STREAM_WIDTH-1:0] chip1_host_mem_e_data_i = '0;

 // --- 3. SECDED ECC Fault Injection ---
 logic chip0_mem_err_inject_en_i = 1'b0;
 logic [143:0] chip0_mem_err_inject_mask_i = '0;
 logic chip1_mem_err_inject_en_i = 1'b0;
 logic [143:0] chip1_mem_err_inject_mask_i = '0;

 // --- 4. Dragonfly C2C Physical Link Delay & RealSync Deskew ---
 logic [1:0] c2c_link_delay_sel_i = 2'd0;
 logic [15:0] expected_flight_cycles_i = 16'd5;
 logic chip1_realsync_adj_en_i = 1'b0;
 logic signed [15:0] chip1_realsync_adj_val_i = 16'sd0;

  // --- 5. Cluster Stream Observation & Multi-Chip Telemetry Outputs ---
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   chip0_stream_valid_east_o;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] chip0_stream_data_east_o;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0]                   chip0_stream_valid_west_o;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0][STREAM_WIDTH-1:0] chip0_stream_data_west_o;

  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   chip1_stream_valid_east_o;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] chip1_stream_data_east_o;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0]                   chip1_stream_valid_west_o;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0][STREAM_WIDTH-1:0] chip1_stream_data_west_o;

  logic                chip0_c2c_tx_valid_o;
  logic                chip1_c2c_tx_valid_o;
  logic                chip0_deskew_release_valid_o;
  logic                chip1_deskew_release_valid_o;
  logic signed [15:0]  chip0_measured_skew_o;
  logic signed [15:0]  chip1_measured_skew_o;
  logic                cluster_collision_fault_o;
  logic                cluster_c2c_crc_err_o;
  logic [15:0]         chip0_gated_hop_count_o;
  logic [15:0]         chip1_gated_hop_count_o;

  logic [1:0]          chip0_ecc_single_err_o;
  logic [1:0]          chip0_ecc_double_err_o;
  logic [1:0]          chip1_ecc_single_err_o;
  logic [1:0]          chip1_ecc_double_err_o;
  logic                chip0_barrier_release_pulse_o;
  logic [15:0]         chip0_barrier_release_cnt_o;
  logic                chip1_barrier_release_pulse_o;
  logic [15:0]         chip1_barrier_release_cnt_o;

  // --- 6. UVM Transaction & Phase Tracking Metadata ---
  logic                sample_en        = 1'b0;
  int unsigned         cycle_id         = 0;
  int unsigned         phase_id         = 0;
  logic [3:0]          cov_sxm_op       = 4'd0;
  logic [3:0]          cov_vxm_op       = 4'd0;
  logic [3:0]          cov_mxm_op       = 4'd0;
  logic [3:0]          cov_nim_op       = 4'd0;
  logic [3:0]          cov_icu_op       = 4'd0;
  logic [3:0]          cov_mem_op       = 4'd0;

endinterface : groq_full_chip_if

module groq_full_chip_dut_wrap (
  groq_full_chip_if bus
);
  import groq_pkg::*;

  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] raw_c0_east_data;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] raw_c1_east_data;

  groq_lpu_cluster_top u_cluster (
    .clk                          (bus.clk),
    .rst_n                        (bus.rst_n),
    .chip0_icu_enable_i           (bus.chip0_icu_enable_i),
    .chip0_imem_vliw_bundle_i     (bus.chip0_imem_vliw_bundle_i),
    .chip0_pc_slice_o             (bus.chip0_pc_slice_o),
    .chip0_slice_halted_o         (bus.chip0_slice_halted_o),
    .chip1_icu_enable_i           (bus.chip1_icu_enable_i),
    .chip1_imem_vliw_bundle_i     (bus.chip1_imem_vliw_bundle_i),
    .chip1_pc_slice_o             (bus.chip1_pc_slice_o),
    .chip1_slice_halted_o         (bus.chip1_slice_halted_o),
    .chip0_host_mem_w_wr_en_i     (bus.chip0_host_mem_w_wr_en_i),
    .chip0_host_mem_w_bank_i      (bus.chip0_host_mem_w_bank_i),
    .chip0_host_mem_w_addr_i      (bus.chip0_host_mem_w_addr_i),
    .chip0_host_mem_w_data_i      (bus.chip0_host_mem_w_data_i),
    .chip1_host_mem_w_wr_en_i     (bus.chip1_host_mem_w_wr_en_i),
    .chip1_host_mem_w_bank_i      (bus.chip1_host_mem_w_bank_i),
    .chip1_host_mem_w_addr_i      (bus.chip1_host_mem_w_addr_i),
    .chip1_host_mem_w_data_i      (bus.chip1_host_mem_w_data_i),
    .chip0_host_mem_e_wr_en_i     (bus.chip0_host_mem_e_wr_en_i),
    .chip0_host_mem_e_bank_i      (bus.chip0_host_mem_e_bank_i),
    .chip0_host_mem_e_addr_i      (bus.chip0_host_mem_e_addr_i),
    .chip0_host_mem_e_data_i      (bus.chip0_host_mem_e_data_i),
    .chip1_host_mem_e_wr_en_i     (bus.chip1_host_mem_e_wr_en_i),
    .chip1_host_mem_e_bank_i      (bus.chip1_host_mem_e_bank_i),
    .chip1_host_mem_e_addr_i      (bus.chip1_host_mem_e_addr_i),
    .chip1_host_mem_e_data_i      (bus.chip1_host_mem_e_data_i),
    .chip0_mem_err_inject_en_i    (bus.chip0_mem_err_inject_en_i),
    .chip0_mem_err_inject_mask_i  (bus.chip0_mem_err_inject_mask_i),
    .chip1_mem_err_inject_en_i    (bus.chip1_mem_err_inject_en_i),
    .chip1_mem_err_inject_mask_i  (bus.chip1_mem_err_inject_mask_i),
    .c2c_link_delay_sel_i         (bus.c2c_link_delay_sel_i),
    .expected_flight_cycles_i     (bus.expected_flight_cycles_i),
    .chip1_realsync_adj_en_i      (bus.chip1_realsync_adj_en_i),
    .chip1_realsync_adj_val_i     (bus.chip1_realsync_adj_val_i),
    .chip0_stream_valid_east_o    (bus.chip0_stream_valid_east_o),
    .chip0_stream_data_east_o     (raw_c0_east_data),
    .chip1_stream_valid_east_o    (bus.chip1_stream_valid_east_o),
    .chip1_stream_data_east_o     (raw_c1_east_data),
    .chip0_c2c_tx_valid_o         (bus.chip0_c2c_tx_valid_o),
    .chip1_c2c_tx_valid_o         (bus.chip1_c2c_tx_valid_o),
    .chip0_deskew_release_valid_o (bus.chip0_deskew_release_valid_o),
    .chip1_deskew_release_valid_o (bus.chip1_deskew_release_valid_o),
    .chip0_measured_skew_o        (bus.chip0_measured_skew_o),
    .chip1_measured_skew_o        (bus.chip1_measured_skew_o),
    .cluster_collision_fault_o    (bus.cluster_collision_fault_o),
    .cluster_c2c_crc_err_o        (bus.cluster_c2c_crc_err_o),
    .chip0_gated_hop_count_o      (bus.chip0_gated_hop_count_o),
    .chip1_gated_hop_count_o      (bus.chip1_gated_hop_count_o)
  );

  assign bus.chip0_stream_valid_west_o    = u_cluster.c0_wval_unused;
  assign bus.chip0_stream_data_west_o     = u_cluster.c0_wdat_unused;
  assign bus.chip1_stream_valid_west_o    = u_cluster.c1_wval_unused;
  assign bus.chip1_stream_data_west_o     = u_cluster.c1_wdat_unused;
  assign bus.chip0_ecc_single_err_o       = u_cluster.c0_ecc1_unused;
  assign bus.chip0_ecc_double_err_o       = u_cluster.c0_ecc2_unused;
  assign bus.chip1_ecc_single_err_o       = u_cluster.c1_ecc1_unused;
  assign bus.chip1_ecc_double_err_o       = u_cluster.c1_ecc2_unused;
  assign bus.chip0_barrier_release_pulse_o= u_cluster.c0_brel_unused;
  assign bus.chip0_barrier_release_cnt_o  = u_cluster.c0_bcnt_unused;
  assign bus.chip1_barrier_release_pulse_o= u_cluster.c1_brel_unused;
  assign bus.chip1_barrier_release_cnt_o  = u_cluster.c1_bcnt_unused;

  always_comb begin
    bus.chip0_stream_data_east_o = raw_c0_east_data;
    bus.chip1_stream_data_east_o = raw_c1_east_data;
    if (bus.inject_full_chip_bug) begin
      for (int s = 0; s < NUM_SLICES; s++) begin
        if (bus.chip0_stream_valid_east_o[s][0])
          bus.chip0_stream_data_east_o[s][0] = raw_c0_east_data[s][0] ^ 128'hDEADBEEF_CAFEBABE;
        if (bus.chip1_stream_valid_east_o[s][0])
          bus.chip1_stream_data_east_o[s][0] = raw_c1_east_data[s][0] ^ 128'hDEADBEEF_CAFEBABE;
      end
    end
  end

endmodule : groq_full_chip_dut_wrap

`endif // GROQ_FULL_CHIP_IF_SV
