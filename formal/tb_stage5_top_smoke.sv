// =============================================================================
// File: formal/tb_stage5_top_smoke.sv
// Description: Verilator 5.054 Full-Chip & 2-Chip Cluster Smoke Verification
//              Tests groq_lpu_top (8-slice pipeline: MEM_W -> SXM -> VXM ->
//              MXM_W -> MEM_E + ICU barrier) and groq_lpu_cluster_top (2-chip
//              Dragonfly C2C transfer + RealSync deskew).
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"

module tb_stage5_top_smoke;
  import groq_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #0.5 clk = ~clk; // 1 GHz clock

  logic                                       c0_icu_en, c1_icu_en;
  logic [NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] c0_vliw,   c1_vliw;
  logic [NUM_SLICES-1:0][15:0]                c0_pc,     c1_pc;
  logic [NUM_SLICES-1:0]                      c0_halted, c1_halted;

  logic                      c0_mem_wr_en, c1_mem_wr_en;
  logic [1:0]                c0_mem_bank,  c1_mem_bank;
  logic [9:0]                c0_mem_addr,  c1_mem_addr;
  logic [STREAM_WIDTH-1:0]   c0_mem_data,  c1_mem_data;

  logic [1:0]                c2c_delay_sel;
  logic [15:0]               expected_flight;
  logic                      c1_rs_adj_en;
  logic signed [15:0]        c1_rs_adj_val;

  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   c0_eval, c1_eval;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] c0_edat, c1_edat;
  logic                      c0_tx_val, c1_tx_val;
  logic                      c0_dsk_val, c1_dsk_val;
  logic signed [15:0]        c0_skew, c1_skew;
  logic                      coll_flt, crc_err;
  logic [15:0]               c0_gated, c1_gated;

  groq_lpu_cluster_top u_cluster (
    .clk                          (clk),
    .rst_n                        (rst_n),
    .chip0_icu_enable_i           (c0_icu_en),
    .chip0_imem_vliw_bundle_i     (c0_vliw),
    .chip0_pc_slice_o             (c0_pc),
    .chip0_slice_halted_o         (c0_halted),
    .chip1_icu_enable_i           (c1_icu_en),
    .chip1_imem_vliw_bundle_i     (c1_vliw),
    .chip1_pc_slice_o             (c1_pc),
    .chip1_slice_halted_o         (c1_halted),
    .chip0_host_mem_w_wr_en_i     (c0_mem_wr_en),
    .chip0_host_mem_w_bank_i      (c0_mem_bank),
    .chip0_host_mem_w_addr_i      (c0_mem_addr),
    .chip0_host_mem_w_data_i      (c0_mem_data),
    .chip1_host_mem_w_wr_en_i     (c1_mem_wr_en),
    .chip1_host_mem_w_bank_i      (c1_mem_bank),
    .chip1_host_mem_w_addr_i      (c1_mem_addr),
    .chip1_host_mem_w_data_i      (c1_mem_data),
    .c2c_link_delay_sel_i         (c2c_delay_sel),
    .expected_flight_cycles_i     (expected_flight),
    .chip1_realsync_adj_en_i      (c1_rs_adj_en),
    .chip1_realsync_adj_val_i     (c1_rs_adj_val),
    .chip0_stream_valid_east_o    (c0_eval),
    .chip0_stream_data_east_o     (c0_edat),
    .chip1_stream_valid_east_o    (c1_eval),
    .chip1_stream_data_east_o     (c1_edat),
    .chip0_c2c_tx_valid_o         (c0_tx_val),
    .chip1_c2c_tx_valid_o         (c1_tx_val),
    .chip0_deskew_release_valid_o (c0_dsk_val),
    .chip1_deskew_release_valid_o (c1_dsk_val),
    .chip0_measured_skew_o        (c0_skew),
    .chip1_measured_skew_o        (c1_skew),
    .cluster_collision_fault_o    (coll_flt),
    .cluster_c2c_crc_err_o        (crc_err),
    .chip0_gated_hop_count_o      (c0_gated),
    .chip1_gated_hop_count_o      (c1_gated)
  );

  groq_vliw_instr_t instr;

  initial begin
    c0_icu_en = 1'b0; c1_icu_en = 1'b0;
    c0_vliw = '0;     c1_vliw = '0;
    c0_mem_wr_en = 1'b0; c0_mem_bank = '0; c0_mem_addr = '0; c0_mem_data = '0;
    c1_mem_wr_en = 1'b0; c1_mem_bank = '0; c1_mem_addr = '0; c1_mem_data = '0;
    c2c_delay_sel = 2'd1; // 1-cycle physical link delay + 1-cycle NIM TX reg = 2 flight cycles
    expected_flight = 16'd2;
    c1_rs_adj_en = 1'b0; c1_rs_adj_val = 16'sd0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // 1. Preload Chip 0 West SRAM (Bank 0, Row 0) via Host DMA
    c0_mem_wr_en = 1'b1;
    c0_mem_bank  = 2'd0;
    c0_mem_addr  = 10'd0;
    c0_mem_data  = 128'h0F0E_0D0C_0B0A_0908_0706_0504_0302_0100;
    @(posedge clk);
    c0_mem_wr_en = 1'b0;
    c0_icu_en    = 1'b1;
    c1_icu_en    = 1'b1;

    // 2. Dispatch MEM_READ_EAST on Chip 0 SLICE_MEM_W (Hop 1) -> Stream 0 East
    instr = '0;
    instr.target_slice  = 4'(SLICE_MEM_W);
    instr.mem_op        = MEM_READ_EAST;
    instr.dst_stream    = 5'd0;
    instr.mem_base_addr = 16'd0;
    c0_vliw[SLICE_MEM_W] = instr;
    @(posedge clk);
    c0_vliw = '0;

    // Wait 1 cycle for SRAM read + 1 cycle for fabric injection -> arrives at Hop 2 (SLICE_SXM)
    @(posedge clk);
    // 3. Dispatch SXM_REVERSE on Chip 0 SLICE_SXM (Hop 2) -> Stream 1 East
    instr = '0;
    instr.target_slice = 4'(SLICE_SXM);
    instr.sxm_op       = SXM_REVERSE;
    instr.src_stream_a = 5'd0;
    instr.dst_stream   = 5'd1;
    c0_vliw[SLICE_SXM] = instr;
    @(posedge clk);
    c0_vliw = '0;

    // 4. Test Dragonfly C2C TX from Chip 0 SLICE_NIM -> Chip 1 SLICE_NIM with RealSync Deskew
    instr = '0;
    instr.target_slice = 4'(SLICE_NIM);
    instr.nim_op       = NIM_REALSYNC_PING;
    instr.imm16        = 16'h0001; // dst_chip = 1
    c0_vliw[SLICE_NIM] = instr;
    @(posedge clk);
    c0_vliw = '0;

    repeat (10) @(posedge clk);

    if (coll_flt !== 1'b0 || crc_err !== 1'b0) begin
      $display("ERROR: Unexpected fault coll_flt=%b crc_err=%b", coll_flt, crc_err);
      $finish(1);
    end
    $display("STAGE 5 FULL-CHIP & 2-CHIP CLUSTER SMOKE TEST PASSED: c0_gated=%0d c1_gated=%0d c1_skew=%0d",
             c0_gated, c1_gated, c1_skew);
    $finish(0);
  end
endmodule
