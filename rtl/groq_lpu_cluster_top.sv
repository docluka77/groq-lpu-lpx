// =============================================================================
// File: rtl/groq_lpu_cluster_top.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: 2-Chip Plesiochronous RealSync Dragonfly LPU Cluster Top-Level.
//              - Instantiates two full 8-Slice Groq LPU chips (u_lpu_chip0 &
//                u_lpu_chip1) connected via bidirectional Dragonfly C2C links.
//              - Includes a programmable 0..4-cycle physical link flight pipeline
//                to model optical/electrical C2C link transit + plesiochronous
//                jitter, deskewed by hardware RealSync elastic buffers.
//              - Supports multi-chip tensor pipeline parallelism & in-network
//                16-lane NIM_ALLREDUCE_ADD collective summation.
// =============================================================================
`ifndef GROQ_LPU_CLUSTER_TOP_SV
`define GROQ_LPU_CLUSTER_TOP_SV

`include "groq_pkg.sv"

module groq_lpu_cluster_top #(
  parameter int P_NUM_SLICES       = groq_pkg::NUM_SLICES,
  parameter int P_NUM_EAST_STREAMS = groq_pkg::NUM_EAST_STREAMS,
  parameter int P_NUM_WEST_STREAMS = groq_pkg::NUM_WEST_STREAMS,
  parameter int P_STREAM_WIDTH     = groq_pkg::STREAM_WIDTH,
  parameter int unsigned P_MEM_BANKS     = 4,
  parameter int unsigned P_MEM_BANK_ID_W = 2,
`ifdef FORMAL
  parameter int unsigned P_MEM_ADDR_W    = 3
`else
  parameter int unsigned P_MEM_ADDR_W    = 10
`endif
) (
  input  logic                                                    clk,
  input  logic                                                    rst_n,

  // ---------------------------------------------------------------------------
  // 1. Cluster ICU Enable & Per-Chip VLIW Program Dispatch Interface
  // ---------------------------------------------------------------------------
  input  logic                                                    chip0_icu_enable_i,
  input  logic [P_NUM_SLICES-1:0][groq_pkg::VLIW_INSTR_BITS-1:0]  chip0_imem_vliw_bundle_i,
  output logic [P_NUM_SLICES-1:0][15:0]                           chip0_pc_slice_o,
  output logic [P_NUM_SLICES-1:0]                                 chip0_slice_halted_o,

  input  logic                                                    chip1_icu_enable_i,
  input  logic [P_NUM_SLICES-1:0][groq_pkg::VLIW_INSTR_BITS-1:0]  chip1_imem_vliw_bundle_i,
  output logic [P_NUM_SLICES-1:0][15:0]                           chip1_pc_slice_o,
  output logic [P_NUM_SLICES-1:0]                                 chip1_slice_halted_o,

  // ---------------------------------------------------------------------------
  // 2. Host DMA SRAM Preload Interface (Chip 0 & Chip 1 West Memory Slices)
  // ---------------------------------------------------------------------------
  input  logic                                                    chip0_host_mem_w_wr_en_i,
  input  logic [P_MEM_BANK_ID_W-1:0]                              chip0_host_mem_w_bank_i,
  input  logic [P_MEM_ADDR_W-1:0]                                 chip0_host_mem_w_addr_i,
  input  logic [P_STREAM_WIDTH-1:0]                               chip0_host_mem_w_data_i,

  input  logic                                                    chip1_host_mem_w_wr_en_i,
  input  logic [P_MEM_BANK_ID_W-1:0]                              chip1_host_mem_w_bank_i,
  input  logic [P_MEM_ADDR_W-1:0]                                 chip1_host_mem_w_addr_i,
  input  logic [P_STREAM_WIDTH-1:0]                               chip1_host_mem_w_data_i,

  input  logic                                                    chip0_host_mem_e_wr_en_i = 1'b0,
  input  logic [P_MEM_BANK_ID_W-1:0]                              chip0_host_mem_e_bank_i  = '0,
  input  logic [P_MEM_ADDR_W-1:0]                                 chip0_host_mem_e_addr_i  = '0,
  input  logic [P_STREAM_WIDTH-1:0]                               chip0_host_mem_e_data_i  = '0,

  input  logic                                                    chip1_host_mem_e_wr_en_i = 1'b0,
  input  logic [P_MEM_BANK_ID_W-1:0]                              chip1_host_mem_e_bank_i  = '0,
  input  logic [P_MEM_ADDR_W-1:0]                                 chip1_host_mem_e_addr_i  = '0,
  input  logic [P_STREAM_WIDTH-1:0]                               chip1_host_mem_e_data_i  = '0,

  input  logic                                                    chip0_mem_err_inject_en_i   = 1'b0,
  input  logic [143:0]                                            chip0_mem_err_inject_mask_i = '0,
  input  logic                                                    chip1_mem_err_inject_en_i   = 1'b0,
  input  logic [143:0]                                            chip1_mem_err_inject_mask_i = '0,

  // ---------------------------------------------------------------------------
  // 3. Dragonfly C2C Physical Link Delay & RealSync Deskew Configuration
  // ---------------------------------------------------------------------------
  input  logic [1:0]                                              c2c_link_delay_sel_i,
  input  logic [15:0]                                             expected_flight_cycles_i,
  input  logic                                                    chip1_realsync_adj_en_i,
  input  logic signed [15:0]                                      chip1_realsync_adj_val_i,

  // ---------------------------------------------------------------------------
  // 4. Cluster Stream Observation & Multi-Chip Telemetry Outputs
  // ---------------------------------------------------------------------------
  output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]                   chip0_stream_valid_east_o,
  output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] chip0_stream_data_east_o,
  output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]                   chip1_stream_valid_east_o,
  output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] chip1_stream_data_east_o,

  output logic                                                    chip0_c2c_tx_valid_o,
  output logic                                                    chip1_c2c_tx_valid_o,
  output logic                                                    chip0_deskew_release_valid_o,
  output logic                                                    chip1_deskew_release_valid_o,
  output logic signed [15:0]                                      chip0_measured_skew_o,
  output logic signed [15:0]                                      chip1_measured_skew_o,
  output logic                                                    cluster_collision_fault_o,
  output logic                                                    cluster_c2c_crc_err_o,
  output logic [15:0]                                             chip0_gated_hop_count_o,
  output logic [15:0]                                             chip1_gated_hop_count_o
);

  // ---------------------------------------------------------------------------
  // Internal Dragonfly C2C Link Signals & Programmable 0..3-Cycle Flight Pipe
  // ---------------------------------------------------------------------------
  logic [P_STREAM_WIDTH-1:0] c0_tx_data, c1_tx_data;
  logic [15:0]               c0_tx_ts,   c1_tx_ts;
  logic [3:0]                c0_tx_dst,  c1_tx_dst;
  logic [7:0]                c0_tx_crc,  c1_tx_crc;
  logic [1:0]                c0_tx_port_unused, c1_tx_port_unused;

  logic [2:0]                pipe_c01_valid_q, pipe_c10_valid_q;
  logic [P_STREAM_WIDTH-1:0] pipe_c01_data_q [0:2], pipe_c10_data_q [0:2];
  logic [15:0]               pipe_c01_ts_q   [0:2], pipe_c10_ts_q   [0:2];
  logic [3:0]                pipe_c01_dst_q  [0:2], pipe_c10_dst_q  [0:2];
  logic [7:0]                pipe_c01_crc_q  [0:2], pipe_c10_crc_q  [0:2];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pipe_c01_valid_q <= '0;
      pipe_c10_valid_q <= '0;
      for (int i = 0; i < 3; i++) begin
        pipe_c01_data_q[i] <= '0; pipe_c10_data_q[i] <= '0;
        pipe_c01_ts_q[i]   <= '0; pipe_c10_ts_q[i]   <= '0;
        pipe_c01_dst_q[i]  <= '0; pipe_c10_dst_q[i]  <= '0;
        pipe_c01_crc_q[i]  <= '0; pipe_c10_crc_q[i]  <= '0;
      end
    end else begin
      pipe_c01_valid_q <= {pipe_c01_valid_q[1:0], chip0_c2c_tx_valid_o};
      pipe_c10_valid_q <= {pipe_c10_valid_q[1:0], chip1_c2c_tx_valid_o};
      pipe_c01_data_q[0] <= c0_tx_data; pipe_c10_data_q[0] <= c1_tx_data;
      pipe_c01_ts_q[0]   <= c0_tx_ts;   pipe_c10_ts_q[0]   <= c1_tx_ts;
      pipe_c01_dst_q[0]  <= c0_tx_dst;  pipe_c10_dst_q[0]  <= c1_tx_dst;
      pipe_c01_crc_q[0]  <= c0_tx_crc;  pipe_c10_crc_q[0]  <= c1_tx_crc;
      for (int i = 1; i < 3; i++) begin
        pipe_c01_data_q[i] <= pipe_c01_data_q[i-1];
        pipe_c01_ts_q[i]   <= pipe_c01_ts_q[i-1];
        pipe_c01_dst_q[i]  <= pipe_c01_dst_q[i-1];
        pipe_c01_crc_q[i]  <= pipe_c01_crc_q[i-1];
        pipe_c10_data_q[i] <= pipe_c10_data_q[i-1];
        pipe_c10_ts_q[i]   <= pipe_c10_ts_q[i-1];
        pipe_c10_dst_q[i]  <= pipe_c10_dst_q[i-1];
        pipe_c10_crc_q[i]  <= pipe_c10_crc_q[i-1];
      end
    end
  end

  logic                      c0_rx_valid, c1_rx_valid;
  logic [P_STREAM_WIDTH-1:0] c0_rx_data,  c1_rx_data;
  logic [15:0]               c0_rx_ts,    c1_rx_ts;
  logic [3:0]                c0_rx_dst,   c1_rx_dst;
  logic [7:0]                c0_rx_crc,   c1_rx_crc;

  always_comb begin
    case (c2c_link_delay_sel_i)
      2'd0: begin
        c1_rx_valid = chip0_c2c_tx_valid_o; c1_rx_data = c0_tx_data;
        c1_rx_ts    = c0_tx_ts;             c1_rx_dst  = c0_tx_dst; c1_rx_crc = c0_tx_crc;
        c0_rx_valid = chip1_c2c_tx_valid_o; c0_rx_data = c1_tx_data;
        c0_rx_ts    = c1_tx_ts;             c0_rx_dst  = c1_tx_dst; c0_rx_crc = c1_tx_crc;
      end
      2'd1: begin
        c1_rx_valid = pipe_c01_valid_q[0]; c1_rx_data = pipe_c01_data_q[0];
        c1_rx_ts    = pipe_c01_ts_q[0];    c1_rx_dst  = pipe_c01_dst_q[0]; c1_rx_crc = pipe_c01_crc_q[0];
        c0_rx_valid = pipe_c10_valid_q[0]; c0_rx_data = pipe_c10_data_q[0];
        c0_rx_ts    = pipe_c10_ts_q[0];    c0_rx_dst  = pipe_c10_dst_q[0]; c0_rx_crc = pipe_c10_crc_q[0];
      end
      2'd2: begin
        c1_rx_valid = pipe_c01_valid_q[1]; c1_rx_data = pipe_c01_data_q[1];
        c1_rx_ts    = pipe_c01_ts_q[1];    c1_rx_dst  = pipe_c01_dst_q[1]; c1_rx_crc = pipe_c01_crc_q[1];
        c0_rx_valid = pipe_c10_valid_q[1]; c0_rx_data = pipe_c10_data_q[1];
        c0_rx_ts    = pipe_c10_ts_q[1];    c0_rx_dst  = pipe_c10_dst_q[1]; c0_rx_crc = pipe_c10_crc_q[1];
      end
      default: begin
        c1_rx_valid = pipe_c01_valid_q[2]; c1_rx_data = pipe_c01_data_q[2];
        c1_rx_ts    = pipe_c01_ts_q[2];    c1_rx_dst  = pipe_c01_dst_q[2]; c1_rx_crc = pipe_c01_crc_q[2];
        c0_rx_valid = pipe_c10_valid_q[2]; c0_rx_data = pipe_c10_data_q[2];
        c0_rx_ts    = pipe_c10_ts_q[2];    c0_rx_dst  = pipe_c10_dst_q[2]; c0_rx_crc = pipe_c10_crc_q[2];
      end
    endcase
  end

  /* verilator lint_off WIDTHCONCAT */
  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] zero_east_data;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] zero_west_data;
  assign zero_east_data = '0;
  assign zero_west_data = '0;
  /* verilator lint_on WIDTHCONCAT */

  // ---------------------------------------------------------------------------
  // Chip 0 & Chip 1 LPU Top-Level Instances
  // ---------------------------------------------------------------------------
  logic [P_NUM_SLICES-1:0]                                 c0_fetch_unused, c1_fetch_unused;
  logic [P_NUM_SLICES-1:0]                                 c0_vval_unused,  c1_vval_unused;
  logic [P_NUM_SLICES-1:0][groq_pkg::VLIW_INSTR_BITS-1:0]  c0_vbun_unused,  c1_vbun_unused;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0]         c0_wval_unused,  c1_wval_unused;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] c0_wdat_unused, c1_wdat_unused;
  logic                                                    c0_coll_flt, c1_coll_flt, c0_coll_stk, c1_coll_stk;
  logic [P_NUM_SLICES-1:0]                                 c0_bwait_unused, c1_bwait_unused;
  logic                                                    c0_brel_unused,  c1_brel_unused;
  logic [15:0]                                             c0_bcnt_unused,  c1_bcnt_unused;
  logic [63:0]                                             c0_rstime_unused,c1_rstime_unused;
  logic                                                    c0_drift_unused, c1_drift_unused;
  logic                                                    c0_crc_err,      c1_crc_err;
  logic [1:0]                                              c0_ecc1_unused,  c1_ecc1_unused;
  logic [1:0]                                              c0_ecc2_unused,  c1_ecc2_unused;
  logic [1:0]                                              c0_bconf_unused, c1_bconf_unused;
  logic [4:0]                                              c0_zsw_unused,   c1_zsw_unused;
  logic [4:0]                                              c0_zse_unused,   c1_zse_unused;
  logic                                                    c0_mg_unused,    c1_mg_unused;
  logic                                                    c0_lg_unused,    c1_lg_unused;
  logic signed [15:0]                                      c0_rsum_unused,  c1_rsum_unused;
  logic signed [7:0]                                       c0_rmax_unused,  c1_rmax_unused;

  groq_lpu_top #(
    .P_NUM_SLICES       (P_NUM_SLICES),
    .P_NUM_EAST_STREAMS (P_NUM_EAST_STREAMS),
    .P_NUM_WEST_STREAMS (P_NUM_WEST_STREAMS),
    .P_STREAM_WIDTH     (P_STREAM_WIDTH),
    .P_MEM_BANKS        (P_MEM_BANKS),
    .P_MEM_BANK_ID_W    (P_MEM_BANK_ID_W),
    .P_MEM_ADDR_W       (P_MEM_ADDR_W)
  ) u_lpu_chip0 (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .icu_enable_i             (chip0_icu_enable_i),
    .imem_vliw_bundle_i       (chip0_imem_vliw_bundle_i),
    .imem_fetch_en_o          (c0_fetch_unused),
    .pc_slice_o               (chip0_pc_slice_o),
    .slice_vliw_valid_o       (c0_vval_unused),
    .slice_vliw_bundle_o      (c0_vbun_unused),
    .slice_halted_o           (chip0_slice_halted_o),
    .ext_east_inject_en_i     ('0),
    .ext_east_inject_data_i   (zero_east_data),
    .ext_west_inject_en_i     ('0),
    .ext_west_inject_data_i   (zero_west_data),
    .ext_overwrite_allow_i    (1'b1),
    .stream_valid_east_o      (chip0_stream_valid_east_o),
    .stream_data_east_o       (chip0_stream_data_east_o),
    .stream_valid_west_o      (c0_wval_unused),
    .stream_data_west_o       (c0_wdat_unused),
    .host_mem_w_wr_en_i       (chip0_host_mem_w_wr_en_i),
    .host_mem_w_bank_i        (chip0_host_mem_w_bank_i),
    .host_mem_w_addr_i        (chip0_host_mem_w_addr_i),
    .host_mem_w_data_i        (chip0_host_mem_w_data_i),
    .host_mem_e_wr_en_i       (chip0_host_mem_e_wr_en_i),
    .host_mem_e_bank_i        (chip0_host_mem_e_bank_i),
    .host_mem_e_addr_i        (chip0_host_mem_e_addr_i),
    .host_mem_e_data_i        (chip0_host_mem_e_data_i),
    .mem_err_inject_en_i      (chip0_mem_err_inject_en_i),
    .mem_err_inject_mask_i    (chip0_mem_err_inject_mask_i),
    .local_chip_id_i          (4'd0),
    .expected_flight_cycles_i (expected_flight_cycles_i),
    .realsync_ext_adj_en_i    (1'b0),
    .realsync_ext_adj_val_i   (16'sd0),
    .c2c_rx_valid_i           (c0_rx_valid),
    .c2c_rx_data_i            (c0_rx_data),
    .c2c_rx_tx_timestamp_i    (c0_rx_ts),
    .c2c_rx_dst_chip_i        (c0_rx_dst),
    .c2c_rx_crc8_i            (c0_rx_crc),
    .c2c_tx_valid_o           (chip0_c2c_tx_valid_o),
    .c2c_tx_data_o            (c0_tx_data),
    .c2c_tx_timestamp_o       (c0_tx_ts),
    .c2c_tx_dst_chip_o        (c0_tx_dst),
    .c2c_tx_crc8_o            (c0_tx_crc),
    .c2c_tx_port_sel_o        (c0_tx_port_unused),
    .collision_fault_o        (c0_coll_flt),
    .collision_sticky_o       (c0_coll_stk),
    .barrier_waiting_o        (c0_bwait_unused),
    .barrier_release_pulse_o  (c0_brel_unused),
    .barrier_release_cnt_o    (c0_bcnt_unused),
    .realsync_aligned_time_o  (c0_rstime_unused),
    .realsync_drift_fault_o   (c0_drift_unused),
    .deskew_release_valid_o   (chip0_deskew_release_valid_o),
    .measured_skew_o          (chip0_measured_skew_o),
    .c2c_crc_err_o            (c0_crc_err),
    .ecc_single_err_o         (c0_ecc1_unused),
    .ecc_double_err_o         (c0_ecc2_unused),
    .bank_conflict_err_o      (c0_bconf_unused),
    .gated_hop_count_o        (chip0_gated_hop_count_o),
    .zero_skip_count_w_o      (c0_zsw_unused),
    .zero_skip_count_e_o      (c0_zse_unused),
    .mul_gate_active_o        (c0_mg_unused),
    .lut_gate_active_o        (c0_lg_unused),
    .vxm_reduce_sum_o         (c0_rsum_unused),
    .vxm_reduce_max_o         (c0_rmax_unused)
  );

  groq_lpu_top #(
    .P_NUM_SLICES       (P_NUM_SLICES),
    .P_NUM_EAST_STREAMS (P_NUM_EAST_STREAMS),
    .P_NUM_WEST_STREAMS (P_NUM_WEST_STREAMS),
    .P_STREAM_WIDTH     (P_STREAM_WIDTH),
    .P_MEM_BANKS        (P_MEM_BANKS),
    .P_MEM_BANK_ID_W    (P_MEM_BANK_ID_W),
    .P_MEM_ADDR_W       (P_MEM_ADDR_W)
  ) u_lpu_chip1 (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .icu_enable_i             (chip1_icu_enable_i),
    .imem_vliw_bundle_i       (chip1_imem_vliw_bundle_i),
    .imem_fetch_en_o          (c1_fetch_unused),
    .pc_slice_o               (chip1_pc_slice_o),
    .slice_vliw_valid_o       (c1_vval_unused),
    .slice_vliw_bundle_o      (c1_vbun_unused),
    .slice_halted_o           (chip1_slice_halted_o),
    .ext_east_inject_en_i     ('0),
    .ext_east_inject_data_i   (zero_east_data),
    .ext_west_inject_en_i     ('0),
    .ext_west_inject_data_i   (zero_west_data),
    .ext_overwrite_allow_i    (1'b1),
    .stream_valid_east_o      (chip1_stream_valid_east_o),
    .stream_data_east_o       (chip1_stream_data_east_o),
    .stream_valid_west_o      (c1_wval_unused),
    .stream_data_west_o       (c1_wdat_unused),
    .host_mem_w_wr_en_i       (chip1_host_mem_w_wr_en_i),
    .host_mem_w_bank_i        (chip1_host_mem_w_bank_i),
    .host_mem_w_addr_i        (chip1_host_mem_w_addr_i),
    .host_mem_w_data_i        (chip1_host_mem_w_data_i),
    .host_mem_e_wr_en_i       (chip1_host_mem_e_wr_en_i),
    .host_mem_e_bank_i        (chip1_host_mem_e_bank_i),
    .host_mem_e_addr_i        (chip1_host_mem_e_addr_i),
    .host_mem_e_data_i        (chip1_host_mem_e_data_i),
    .mem_err_inject_en_i      (chip1_mem_err_inject_en_i),
    .mem_err_inject_mask_i    (chip1_mem_err_inject_mask_i),
    .local_chip_id_i          (4'd1),
    .expected_flight_cycles_i (expected_flight_cycles_i),
    .realsync_ext_adj_en_i    (chip1_realsync_adj_en_i),
    .realsync_ext_adj_val_i   (chip1_realsync_adj_val_i),
    .c2c_rx_valid_i           (c1_rx_valid),
    .c2c_rx_data_i            (c1_rx_data),
    .c2c_rx_tx_timestamp_i    (c1_rx_ts),
    .c2c_rx_dst_chip_i        (c1_rx_dst),
    .c2c_rx_crc8_i            (c1_rx_crc),
    .c2c_tx_valid_o           (chip1_c2c_tx_valid_o),
    .c2c_tx_data_o            (c1_tx_data),
    .c2c_tx_timestamp_o       (c1_tx_ts),
    .c2c_tx_dst_chip_o        (c1_tx_dst),
    .c2c_tx_crc8_o            (c1_tx_crc),
    .c2c_tx_port_sel_o        (c1_tx_port_unused),
    .collision_fault_o        (c1_coll_flt),
    .collision_sticky_o       (c1_coll_stk),
    .barrier_waiting_o        (c1_bwait_unused),
    .barrier_release_pulse_o  (c1_brel_unused),
    .barrier_release_cnt_o    (c1_bcnt_unused),
    .realsync_aligned_time_o  (c1_rstime_unused),
    .realsync_drift_fault_o   (c1_drift_unused),
    .deskew_release_valid_o   (chip1_deskew_release_valid_o),
    .measured_skew_o          (chip1_measured_skew_o),
    .c2c_crc_err_o            (c1_crc_err),
    .ecc_single_err_o         (c1_ecc1_unused),
    .ecc_double_err_o         (c1_ecc2_unused),
    .bank_conflict_err_o      (c1_bconf_unused),
    .gated_hop_count_o        (chip1_gated_hop_count_o),
    .zero_skip_count_w_o      (c1_zsw_unused),
    .zero_skip_count_e_o      (c1_zse_unused),
    .mul_gate_active_o        (c1_mg_unused),
    .lut_gate_active_o        (c1_lg_unused),
    .vxm_reduce_sum_o         (c1_rsum_unused),
    .vxm_reduce_max_o         (c1_rmax_unused)
  );

  assign cluster_collision_fault_o = c0_coll_flt | c1_coll_flt | c0_coll_stk | c1_coll_stk;
  assign cluster_c2c_crc_err_o     = c0_crc_err  | c1_crc_err;

  wire _unused_cluster_ok = &{1'b0,
    c0_tx_port_unused, c1_tx_port_unused,
    c0_fetch_unused, c1_fetch_unused, c0_vval_unused, c1_vval_unused,
    c0_vbun_unused, c1_vbun_unused, c0_wval_unused, c1_wval_unused,
    c0_wdat_unused, c1_wdat_unused, c0_bwait_unused, c1_bwait_unused,
    c0_brel_unused, c1_brel_unused, c0_bcnt_unused, c1_bcnt_unused,
    c0_rstime_unused, c1_rstime_unused, c0_drift_unused, c1_drift_unused,
    c0_ecc1_unused, c1_ecc1_unused, c0_ecc2_unused, c1_ecc2_unused,
    c0_bconf_unused, c1_bconf_unused, c0_zsw_unused, c1_zsw_unused,
    c0_zse_unused, c1_zse_unused, c0_mg_unused, c1_mg_unused,
    c0_lg_unused, c1_lg_unused, c0_rsum_unused, c1_rsum_unused,
    c0_rmax_unused, c1_rmax_unused};

endmodule : groq_lpu_cluster_top

`endif // GROQ_LPU_CLUSTER_TOP_SV
