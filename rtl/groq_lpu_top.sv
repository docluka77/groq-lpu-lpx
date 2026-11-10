// =============================================================================
// File: rtl/groq_lpu_top.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Full-Chip 8-Slice Spatial Pipeline Top-Level Integration:
//              - Hop 0 (SLICE_NIM)  : groq_nim_realsync (Dragonfly C2C + RealSync)
//              - Hop 1 (SLICE_MEM_W): groq_mem_slice    (West Hemisphere SRAM)
//              - Hop 2 (SLICE_SXM)  : groq_sxm_slice    (Spatial Permute/Transpose)
//              - Hop 3 (SLICE_VXM)  : groq_vxm_slice    (16-Lane Vector ALU + LUT)
//              - Hop 4 (SLICE_MXM_W): groq_mxm_slice    (West Systolic Matrix Unit)
//              - Hop 5 (SLICE_ICU)  : groq_icu_slice    (144b VLIW Control + Sync)
//              - Hop 6 (SLICE_MXM_E): groq_mxm_slice    (East Systolic Matrix Unit)
//              - Hop 7 (SLICE_MEM_E): groq_mem_slice    (East Hemisphere SRAM)
//              Connected across groq_stream_fabric (16 East + 16 West 128b streams).
// =============================================================================
`ifndef GROQ_LPU_TOP_SV
`define GROQ_LPU_TOP_SV

`include "groq_pkg.sv"

module groq_lpu_top #(
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
  // 1. ICU Program Dispatch & Instruction Memory (IMEM) Interface
  // ---------------------------------------------------------------------------
  input  logic                                                    icu_enable_i,
  input  logic [P_NUM_SLICES-1:0][groq_pkg::VLIW_INSTR_BITS-1:0]  imem_vliw_bundle_i,
  output logic [P_NUM_SLICES-1:0]                                 imem_fetch_en_o,
  output logic [P_NUM_SLICES-1:0][15:0]                           pc_slice_o,
  output logic [P_NUM_SLICES-1:0]                                 slice_vliw_valid_o,
  output logic [P_NUM_SLICES-1:0][groq_pkg::VLIW_INSTR_BITS-1:0]  slice_vliw_bundle_o,
  output logic [P_NUM_SLICES-1:0]                                 slice_halted_o,

  // ---------------------------------------------------------------------------
  // 2. External Stream Injection & Full-Fabric Stream Observation Interface
  // ---------------------------------------------------------------------------
  input  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]                   ext_east_inject_en_i,
  input  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] ext_east_inject_data_i,
  input  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0]                   ext_west_inject_en_i,
  input  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] ext_west_inject_data_i,
  input  logic                                                              ext_overwrite_allow_i,

  output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]                   stream_valid_east_o,
  output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] stream_data_east_o,
  output logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0]                   stream_valid_west_o,
  output logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] stream_data_west_o,

  // ---------------------------------------------------------------------------
  // 3. Host DMA SRAM Preload & ECC Fault Injection Interface (West=0, East=1)
  // ---------------------------------------------------------------------------
  input  logic                                                    host_mem_w_wr_en_i,
  input  logic [P_MEM_BANK_ID_W-1:0]                              host_mem_w_bank_i,
  input  logic [P_MEM_ADDR_W-1:0]                                 host_mem_w_addr_i,
  input  logic [P_STREAM_WIDTH-1:0]                               host_mem_w_data_i,

  input  logic                                                    host_mem_e_wr_en_i,
  input  logic [P_MEM_BANK_ID_W-1:0]                              host_mem_e_bank_i,
  input  logic [P_MEM_ADDR_W-1:0]                                 host_mem_e_addr_i,
  input  logic [P_STREAM_WIDTH-1:0]                               host_mem_e_data_i,

  input  logic                                                    mem_err_inject_en_i,
  input  logic [143:0]                                            mem_err_inject_mask_i,

  // ---------------------------------------------------------------------------
  // 4. Dragonfly Chip-to-Chip (C2C) & RealSync Plesiochronous Link (Hop 0 NIM)
  // ---------------------------------------------------------------------------
  input  logic [3:0]                                              local_chip_id_i,
  input  logic [15:0]                                             expected_flight_cycles_i,
  input  logic                                                    realsync_ext_adj_en_i,
  input  logic signed [15:0]                                      realsync_ext_adj_val_i,

  input  logic                                                    c2c_rx_valid_i,
  input  logic [P_STREAM_WIDTH-1:0]                               c2c_rx_data_i,
  input  logic [15:0]                                             c2c_rx_tx_timestamp_i,
  input  logic [3:0]                                              c2c_rx_dst_chip_i,
  input  logic [7:0]                                              c2c_rx_crc8_i,

  output logic                                                    c2c_tx_valid_o,
  output logic [P_STREAM_WIDTH-1:0]                               c2c_tx_data_o,
  output logic [15:0]                                             c2c_tx_timestamp_o,
  output logic [3:0]                                              c2c_tx_dst_chip_o,
  output logic [7:0]                                              c2c_tx_crc8_o,
  output logic [1:0]                                              c2c_tx_port_sel_o,

  // ---------------------------------------------------------------------------
  // 5. Top-Level Observability, Fault & Power-Gating Telemetry Ports
  // ---------------------------------------------------------------------------
  output logic                                                    collision_fault_o,
  output logic                                                    collision_sticky_o,
  output logic [P_NUM_SLICES-1:0]                                 barrier_waiting_o,
  output logic                                                    barrier_release_pulse_o,
  output logic [15:0]                                             barrier_release_cnt_o,
  output logic [63:0]                                             realsync_aligned_time_o,
  output logic                                                    realsync_drift_fault_o,
  output logic                                                    deskew_release_valid_o,
  output logic signed [15:0]                                      measured_skew_o,
  output logic                                                    c2c_crc_err_o,

  output logic [1:0]                                              ecc_single_err_o,
  output logic [1:0]                                              ecc_double_err_o,
  output logic [1:0]                                              bank_conflict_err_o,

  output logic [15:0]                                             gated_hop_count_o,
  output logic [4:0]                                              zero_skip_count_w_o,
  output logic [4:0]                                              zero_skip_count_e_o,
  output logic                                                    mul_gate_active_o,
  output logic                                                    lut_gate_active_o,
  output logic signed [15:0]                                      vxm_reduce_sum_o,
  output logic signed [7:0]                                       vxm_reduce_max_o
);

  // ---------------------------------------------------------------------------
  // Internal Stream Fabric Control & Slice VLIW Unpack Signals
  // ---------------------------------------------------------------------------
  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]                   fab_east_inject_en;
  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]                   fab_east_overwrite_allow;
  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]                   fab_east_consume_en;
  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] fab_east_inject_data;
  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]                   fab_collision_east_unused;

  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0]                   fab_west_inject_en;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0]                   fab_west_overwrite_allow;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0]                   fab_west_consume_en;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] fab_west_inject_data;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0]                   fab_collision_west_unused;

  logic [P_NUM_SLICES-1:0]       slice_notify_ready;
  logic [P_NUM_SLICES-1:0][15:0] slice_nop_timer_unused;
  logic [P_NUM_SLICES-1:0]       barrier_ready_mask_unused;
  logic [63:0]                   realsync_cycle_cnt_unused;
  logic signed [15:0]            realsync_deskew_offset_unused;

  // Helper functions to read any stream (0..15 = East, 16..31 = West) at hop s
  function automatic logic select_stream_valid(
    input logic [P_NUM_EAST_STREAMS-1:0] eval_hop,
    input logic [P_NUM_WEST_STREAMS-1:0] wval_hop,
    input logic [4:0]                    sid
  );
    begin
      select_stream_valid = 1'b0;
      for (int k = 0; k < P_NUM_EAST_STREAMS; k++) begin
        if (!sid[4] && (sid[3:0] == 4'(k))) select_stream_valid = eval_hop[k];
      end
      for (int k = 0; k < P_NUM_WEST_STREAMS; k++) begin
        if (sid[4] && (sid[3:0] == 4'(k)))  select_stream_valid = wval_hop[k];
      end
    end
  endfunction

  function automatic logic [P_STREAM_WIDTH-1:0] select_stream_data(
    input logic [P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] edat_hop,
    input logic [P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] wdat_hop,
    input logic [4:0]                                        sid
  );
    begin
      select_stream_data = '0;
      for (int k = 0; k < P_NUM_EAST_STREAMS; k++) begin
        if (!sid[4] && (sid[3:0] == 4'(k))) select_stream_data = edat_hop[k];
      end
      for (int k = 0; k < P_NUM_WEST_STREAMS; k++) begin
        if (sid[4] && (sid[3:0] == 4'(k)))  select_stream_data = wdat_hop[k];
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Hop 5 (SLICE_ICU): Instruction Control Unit & RealSync Timebase
  // ---------------------------------------------------------------------------
  groq_icu_slice #(
    .P_NUM_SLICES    (P_NUM_SLICES),
    .P_PC_WIDTH      (16),
    .P_MAX_DRIFT_CYC (64)
  ) u_icu (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .icu_enable_i             (icu_enable_i),
    .imem_vliw_bundle_i       (imem_vliw_bundle_i),
    .imem_fetch_en_o          (imem_fetch_en_o),
    .pc_slice_o               (pc_slice_o),
    .slice_vliw_valid_o       (slice_vliw_valid_o),
    .slice_vliw_bundle_o      (slice_vliw_bundle_o),
    .slice_nop_timer_o        (slice_nop_timer_unused),
    .slice_halted_o           (slice_halted_o),
    .slice_notify_ready_i     (slice_notify_ready),
    .barrier_waiting_o        (barrier_waiting_o),
    .barrier_ready_mask_o     (barrier_ready_mask_unused),
    .barrier_release_pulse_o  (barrier_release_pulse_o),
    .barrier_release_cnt_o    (barrier_release_cnt_o),
    .realsync_ext_adj_en_i    (realsync_ext_adj_en_i),
    .realsync_ext_adj_val_i   (realsync_ext_adj_val_i),
    .realsync_cycle_cnt_o     (realsync_cycle_cnt_unused),
    .realsync_deskew_offset_o (realsync_deskew_offset_unused),
    .realsync_aligned_time_o  (realsync_aligned_time_o),
    .realsync_drift_fault_o   (realsync_drift_fault_o)
  );

  // ---------------------------------------------------------------------------
  // Spatial Stream Register Fabric (8 Slices x 16 East + 16 West 128b Streams)
  // ---------------------------------------------------------------------------
  groq_stream_fabric #(
    .P_NUM_SLICES       (P_NUM_SLICES),
    .P_NUM_EAST_STREAMS (P_NUM_EAST_STREAMS),
    .P_NUM_WEST_STREAMS (P_NUM_WEST_STREAMS),
    .P_STREAM_WIDTH     (P_STREAM_WIDTH)
  ) u_stream_fabric (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .east_inject_en_i       (fab_east_inject_en),
    .east_overwrite_allow_i (fab_east_overwrite_allow),
    .east_consume_en_i      (fab_east_consume_en),
    .east_inject_data_i     (fab_east_inject_data),
    .stream_valid_east_o    (stream_valid_east_o),
    .stream_data_east_o     (stream_data_east_o),
    .collision_fault_east_o (fab_collision_east_unused),
    .west_inject_en_i       (fab_west_inject_en),
    .west_overwrite_allow_i (fab_west_overwrite_allow),
    .west_consume_en_i      (fab_west_consume_en),
    .west_inject_data_i     (fab_west_inject_data),
    .stream_valid_west_o    (stream_valid_west_o),
    .stream_data_west_o     (stream_data_west_o),
    .collision_fault_west_o (fab_collision_west_unused),
    .collision_fault_o      (collision_fault_o),
    .collision_sticky_o     (collision_sticky_o),
    .gated_hop_count_o      (gated_hop_count_o)
  );

  // ---------------------------------------------------------------------------
  // Hop 0 (SLICE_NIM): Network Interface & RealSync Plesiochronous Router
  // ---------------------------------------------------------------------------
  logic                      nim_stream_in_valid;
  logic [P_STREAM_WIDTH-1:0] nim_stream_in_data;
  logic                      nim_stream_out_valid;
  logic [P_STREAM_WIDTH-1:0] nim_stream_out_data;
  logic [15:0]               nim_deskew_target_unused;
  logic                      nim_ping_ack;

  assign nim_stream_in_valid = select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_NIM], stream_valid_west_o[groq_pkg::SLICE_NIM], slice_vliw_bundle_o[groq_pkg::SLICE_NIM][111:107]);
  assign nim_stream_in_data  = select_stream_data(stream_data_east_o[groq_pkg::SLICE_NIM], stream_data_west_o[groq_pkg::SLICE_NIM], slice_vliw_bundle_o[groq_pkg::SLICE_NIM][111:107]);

  groq_nim_realsync #(
    .P_LANES        (groq_pkg::SUPERLANE_LANES),
    .P_ELEM_BITS    (groq_pkg::ELEM_BITS),
    .P_STREAM_WIDTH (P_STREAM_WIDTH),
    .P_DESKEW_DEPTH (4)
  ) u_nim (
    .clk                            (clk),
    .rst_n                          (rst_n),
    .op_valid_i                     (slice_vliw_valid_o[groq_pkg::SLICE_NIM]),
    .nim_op_i                       (slice_vliw_bundle_o[groq_pkg::SLICE_NIM][119:116]),
    .realsync_aligned_time_i        (realsync_aligned_time_o[15:0]),
    .expected_flight_cycles_i       (expected_flight_cycles_i),
    .local_chip_id_i                (local_chip_id_i),
    .tx_dst_chip_i                  (slice_vliw_bundle_o[groq_pkg::SLICE_NIM][19:16]),
    .ugal_nonminimal_en_i           (slice_vliw_bundle_o[groq_pkg::SLICE_NIM][20]),
    .link_congested_i               (slice_vliw_bundle_o[groq_pkg::SLICE_NIM][21]),
    .local_stream_in_valid_i        (nim_stream_in_valid),
    .local_stream_in_data_i         (nim_stream_in_data),
    .local_stream_out_valid_o       (nim_stream_out_valid),
    .local_stream_out_data_o        (nim_stream_out_data),
    .c2c_rx_valid_i                 (c2c_rx_valid_i),
    .c2c_rx_data_i                  (c2c_rx_data_i),
    .c2c_rx_tx_timestamp_i          (c2c_rx_tx_timestamp_i),
    .c2c_rx_dst_chip_i              (c2c_rx_dst_chip_i),
    .c2c_rx_crc8_i                  (c2c_rx_crc8_i),
    .c2c_tx_valid_o                 (c2c_tx_valid_o),
    .c2c_tx_data_o                  (c2c_tx_data_o),
    .c2c_tx_timestamp_o             (c2c_tx_timestamp_o),
    .c2c_tx_dst_chip_o              (c2c_tx_dst_chip_o),
    .c2c_tx_crc8_o                  (c2c_tx_crc8_o),
    .c2c_tx_port_sel_o              (c2c_tx_port_sel_o),
    .deskew_release_valid_o         (deskew_release_valid_o),
    .deskew_released_target_cycle_o (nim_deskew_target_unused),
    .realsync_ping_ack_o            (nim_ping_ack),
    .measured_skew_o                (measured_skew_o),
    .crc_err_o                      (c2c_crc_err_o)
  );

  // ---------------------------------------------------------------------------
  // Hop 1 (SLICE_MEM_W) & Hop 7 (SLICE_MEM_E): West & East SRAM Slices
  // ---------------------------------------------------------------------------
  logic                      mem_w_wr_valid, mem_w_rd_valid, mem_w_out_valid;
  logic [P_MEM_BANK_ID_W-1:0] mem_w_wr_bank, mem_w_rd_bank;
  logic [P_MEM_ADDR_W-1:0]   mem_w_wr_addr, mem_w_rd_addr;
  logic [P_STREAM_WIDTH-1:0] mem_w_wr_data, mem_w_out_data;
  logic                      mem_w_agu_cfg, mem_w_sleep_en;
  logic                      mem_w_mbist_done_unused, mem_w_mbist_fail_unused;
  logic [15:0]               mem_w_syndrome_unused;
  logic                      mem_w_rd_done, mem_w_wr_done;

  assign mem_w_agu_cfg  = slice_vliw_valid_o[groq_pkg::SLICE_MEM_W] &
                          (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][135:132] == groq_pkg::MEM_STRIDE_CFG);
  assign mem_w_sleep_en = slice_vliw_valid_o[groq_pkg::SLICE_MEM_W] &
                          (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][135:132] == groq_pkg::MEM_BANK_SLEEP);
  assign mem_w_rd_valid = slice_vliw_valid_o[groq_pkg::SLICE_MEM_W] &
                          ((slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][135:132] == groq_pkg::MEM_READ_EAST) ||
                           (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][135:132] == groq_pkg::MEM_READ_WEST));
  assign mem_w_rd_bank  = slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][56 + P_MEM_ADDR_W +: P_MEM_BANK_ID_W];
  assign mem_w_rd_addr  = slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][56 +: P_MEM_ADDR_W];

  assign mem_w_wr_valid = host_mem_w_wr_en_i |
                          (slice_vliw_valid_o[groq_pkg::SLICE_MEM_W] &
                           ((slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][135:132] == groq_pkg::MEM_WRITE_EAST) ||
                            (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][135:132] == groq_pkg::MEM_WRITE_WEST)) &
                           select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_MEM_W], stream_valid_west_o[groq_pkg::SLICE_MEM_W], slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][111:107]));
  assign mem_w_wr_bank  = host_mem_w_wr_en_i ? host_mem_w_bank_i :
                          slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][56 + P_MEM_ADDR_W +: P_MEM_BANK_ID_W];
  assign mem_w_wr_addr  = host_mem_w_wr_en_i ? host_mem_w_addr_i :
                          slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][56 +: P_MEM_ADDR_W];
  assign mem_w_wr_data  = host_mem_w_wr_en_i ? host_mem_w_data_i :
                          select_stream_data(stream_data_east_o[groq_pkg::SLICE_MEM_W], stream_data_west_o[groq_pkg::SLICE_MEM_W], slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][111:107]);

  groq_mem_slice #(
    .NUM_BANKS   (P_MEM_BANKS),
    .BANK_ID_W   (P_MEM_BANK_ID_W),
    .BANK_ADDR_W (P_MEM_ADDR_W),
    .BANK_DEPTH  (1 << P_MEM_ADDR_W)
  ) u_mem_w (
    .clk                 (clk),
    .rst_n               (rst_n),
    .rd_agu_cfg_load     (mem_w_agu_cfg),
    .rd_agu_mode         (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][17:16]),
    .rd_agu_base         (mem_w_rd_addr),
    .rd_agu_stride0      (P_MEM_ADDR_W'(slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][55:48])),
    .rd_agu_stride1      (P_MEM_ADDR_W'(1)),
    .rd_agu_count0       (P_MEM_ADDR_W'(slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][47:40])),
    .rd_agu_count1       (P_MEM_ADDR_W'(1)),
    .rd_agu_use          (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][18]),
    .wr_agu_cfg_load     (mem_w_agu_cfg),
    .wr_agu_mode         (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][17:16]),
    .wr_agu_base         (mem_w_wr_addr),
    .wr_agu_stride0      (P_MEM_ADDR_W'(slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][55:48])),
    .wr_agu_stride1      (P_MEM_ADDR_W'(1)),
    .wr_agu_count0       (P_MEM_ADDR_W'(slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][47:40])),
    .wr_agu_count1       (P_MEM_ADDR_W'(1)),
    .wr_agu_use          (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][19]),
    .stream_in_valid     (mem_w_wr_valid),
    .stream_in_bank      (mem_w_wr_bank),
    .stream_in_addr      (mem_w_wr_addr),
    .stream_in_data      (mem_w_wr_data),
    .stream_in_bwe_n     (16'h0000),
    .rd_req_valid        (mem_w_rd_valid),
    .rd_req_bank         (mem_w_rd_bank),
    .rd_req_addr         (mem_w_rd_addr),
    .stream_out_valid    (mem_w_out_valid),
    .stream_out_data     (mem_w_out_data),
    .bank_slp_n          (mem_w_sleep_en ? ~slice_vliw_bundle_o[groq_pkg::SLICE_MEM_W][16 +: P_MEM_BANKS] : {P_MEM_BANKS{1'b1}}),
    .bank_ds_n           ({P_MEM_BANKS{1'b1}}),
    .bank_sd_n           ({P_MEM_BANKS{1'b1}}),
    .bank_repair_en      ({P_MEM_BANKS{1'b0}}),
    .bank_repair_addr    ({P_MEM_ADDR_W{1'b0}}),
    .mbist_en            (1'b0),
    .mbist_done          (mem_w_mbist_done_unused),
    .mbist_fail          (mem_w_mbist_fail_unused),
    .err_inject_en       (mem_err_inject_en_i),
    .err_inject_mask     (mem_err_inject_mask_i),
    .bank_conflict_error (bank_conflict_err_o[0]),
    .ecc_single_err      (ecc_single_err_o[0]),
    .ecc_double_err      (ecc_double_err_o[0]),
    .ecc_syndrome        (mem_w_syndrome_unused),
    .rd_tile_done        (mem_w_rd_done),
    .wr_tile_done        (mem_w_wr_done)
  );

  logic                      mem_e_wr_valid, mem_e_rd_valid, mem_e_out_valid;
  logic [P_MEM_BANK_ID_W-1:0] mem_e_wr_bank, mem_e_rd_bank;
  logic [P_MEM_ADDR_W-1:0]   mem_e_wr_addr, mem_e_rd_addr;
  logic [P_STREAM_WIDTH-1:0] mem_e_wr_data, mem_e_out_data;
  logic                      mem_e_agu_cfg, mem_e_sleep_en;
  logic                      mem_e_mbist_done_unused, mem_e_mbist_fail_unused;
  logic [15:0]               mem_e_syndrome_unused;
  logic                      mem_e_rd_done, mem_e_wr_done;

  assign mem_e_agu_cfg  = slice_vliw_valid_o[groq_pkg::SLICE_MEM_E] &
                          (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][135:132] == groq_pkg::MEM_STRIDE_CFG);
  assign mem_e_sleep_en = slice_vliw_valid_o[groq_pkg::SLICE_MEM_E] &
                          (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][135:132] == groq_pkg::MEM_BANK_SLEEP);
  assign mem_e_rd_valid = slice_vliw_valid_o[groq_pkg::SLICE_MEM_E] &
                          ((slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][135:132] == groq_pkg::MEM_READ_EAST) ||
                           (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][135:132] == groq_pkg::MEM_READ_WEST));
  assign mem_e_rd_bank  = slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][56 + P_MEM_ADDR_W +: P_MEM_BANK_ID_W];
  assign mem_e_rd_addr  = slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][56 +: P_MEM_ADDR_W];

  assign mem_e_wr_valid = host_mem_e_wr_en_i |
                          (slice_vliw_valid_o[groq_pkg::SLICE_MEM_E] &
                           ((slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][135:132] == groq_pkg::MEM_WRITE_EAST) ||
                            (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][135:132] == groq_pkg::MEM_WRITE_WEST)) &
                           select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_MEM_E], stream_valid_west_o[groq_pkg::SLICE_MEM_E], slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][111:107]));
  assign mem_e_wr_bank  = host_mem_e_wr_en_i ? host_mem_e_bank_i :
                          slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][56 + P_MEM_ADDR_W +: P_MEM_BANK_ID_W];
  assign mem_e_wr_addr  = host_mem_e_wr_en_i ? host_mem_e_addr_i :
                          slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][56 +: P_MEM_ADDR_W];
  assign mem_e_wr_data  = host_mem_e_wr_en_i ? host_mem_e_data_i :
                          select_stream_data(stream_data_east_o[groq_pkg::SLICE_MEM_E], stream_data_west_o[groq_pkg::SLICE_MEM_E], slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][111:107]);

  groq_mem_slice #(
    .NUM_BANKS   (P_MEM_BANKS),
    .BANK_ID_W   (P_MEM_BANK_ID_W),
    .BANK_ADDR_W (P_MEM_ADDR_W),
    .BANK_DEPTH  (1 << P_MEM_ADDR_W)
  ) u_mem_e (
    .clk                 (clk),
    .rst_n               (rst_n),
    .rd_agu_cfg_load     (mem_e_agu_cfg),
    .rd_agu_mode         (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][17:16]),
    .rd_agu_base         (mem_e_rd_addr),
    .rd_agu_stride0      (P_MEM_ADDR_W'(slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][55:48])),
    .rd_agu_stride1      (P_MEM_ADDR_W'(1)),
    .rd_agu_count0       (P_MEM_ADDR_W'(slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][47:40])),
    .rd_agu_count1       (P_MEM_ADDR_W'(1)),
    .rd_agu_use          (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][18]),
    .wr_agu_cfg_load     (mem_e_agu_cfg),
    .wr_agu_mode         (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][17:16]),
    .wr_agu_base         (mem_e_wr_addr),
    .wr_agu_stride0      (P_MEM_ADDR_W'(slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][55:48])),
    .wr_agu_stride1      (P_MEM_ADDR_W'(1)),
    .wr_agu_count0       (P_MEM_ADDR_W'(slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][47:40])),
    .wr_agu_count1       (P_MEM_ADDR_W'(1)),
    .wr_agu_use          (slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][19]),
    .stream_in_valid     (mem_e_wr_valid),
    .stream_in_bank      (mem_e_wr_bank),
    .stream_in_addr      (mem_e_wr_addr),
    .stream_in_data      (mem_e_wr_data),
    .stream_in_bwe_n     (16'h0000),
    .rd_req_valid        (mem_e_rd_valid),
    .rd_req_bank         (mem_e_rd_bank),
    .rd_req_addr         (mem_e_rd_addr),
    .stream_out_valid    (mem_e_out_valid),
    .stream_out_data     (mem_e_out_data),
    .bank_slp_n          (mem_e_sleep_en ? ~slice_vliw_bundle_o[groq_pkg::SLICE_MEM_E][16 +: P_MEM_BANKS] : {P_MEM_BANKS{1'b1}}),
    .bank_ds_n           ({P_MEM_BANKS{1'b1}}),
    .bank_sd_n           ({P_MEM_BANKS{1'b1}}),
    .bank_repair_en      ({P_MEM_BANKS{1'b0}}),
    .bank_repair_addr    ({P_MEM_ADDR_W{1'b0}}),
    .mbist_en            (1'b0),
    .mbist_done          (mem_e_mbist_done_unused),
    .mbist_fail          (mem_e_mbist_fail_unused),
    .err_inject_en       (mem_err_inject_en_i),
    .err_inject_mask     (mem_err_inject_mask_i),
    .bank_conflict_error (bank_conflict_err_o[1]),
    .ecc_single_err      (ecc_single_err_o[1]),
    .ecc_double_err      (ecc_double_err_o[1]),
    .ecc_syndrome        (mem_e_syndrome_unused),
    .rd_tile_done        (mem_e_rd_done),
    .wr_tile_done        (mem_e_wr_done)
  );

  // ---------------------------------------------------------------------------
  // Hop 2 (SLICE_SXM): Spatial Switch / Shift / Transpose / Permute Slice
  // ---------------------------------------------------------------------------
  logic                      sxm_in_valid, sxm_out_valid;
  logic [P_STREAM_WIDTH-1:0] sxm_in_data, sxm_out_data, sxm_comb_unused;

  assign sxm_in_valid = slice_vliw_valid_o[groq_pkg::SLICE_SXM] &
                        (slice_vliw_bundle_o[groq_pkg::SLICE_SXM][131:128] != groq_pkg::SXM_NOP) &
                        ((slice_vliw_bundle_o[groq_pkg::SLICE_SXM][131:128] == groq_pkg::SXM_TRANSPOSE_READ) ||
                         select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_SXM], stream_valid_west_o[groq_pkg::SLICE_SXM], slice_vliw_bundle_o[groq_pkg::SLICE_SXM][111:107]));
  assign sxm_in_data  = select_stream_data(stream_data_east_o[groq_pkg::SLICE_SXM], stream_data_west_o[groq_pkg::SLICE_SXM], slice_vliw_bundle_o[groq_pkg::SLICE_SXM][111:107]);

  groq_sxm_slice #(
    .P_LANES        (groq_pkg::SUPERLANE_LANES),
    .P_ELEM_BITS    (groq_pkg::ELEM_BITS),
    .P_STREAM_WIDTH (P_STREAM_WIDTH)
  ) u_sxm (
    .clk                (clk),
    .rst_n              (rst_n),
    .sxm_op_i           (slice_vliw_bundle_o[groq_pkg::SLICE_SXM][131:128]),
    .shift_amt_i        (slice_vliw_bundle_o[groq_pkg::SLICE_SXM][35:32]),
    .src_lane_i         (slice_vliw_bundle_o[groq_pkg::SLICE_SXM][39:36]),
    .butterfly_mask_i   (slice_vliw_bundle_o[groq_pkg::SLICE_SXM][19:16]),
    .transpose_idx_i    (slice_vliw_bundle_o[groq_pkg::SLICE_SXM][23:20]),
    .rope_neg_even_en_i (slice_vliw_bundle_o[groq_pkg::SLICE_SXM][24]),
    .stream_in_valid_i  (sxm_in_valid),
    .stream_in_data_i   (sxm_in_data),
    .stream_out_valid_o (sxm_out_valid),
    .stream_out_data_o  (sxm_out_data),
    .perm_comb_data_o   (sxm_comb_unused)
  );

  // ---------------------------------------------------------------------------
  // Hop 3 (SLICE_VXM): 16-Lane Vector ALU, Nonlinear LUT & Reduction Slice
  // ---------------------------------------------------------------------------
  logic                                     vxm_op_valid, vxm_out_valid;
  logic [P_STREAM_WIDTH-1:0]                vxm_stream_a, vxm_stream_b, vxm_stream_c;
  logic [P_STREAM_WIDTH-1:0]                vxm_out_data, vxm_comb_unused;
  logic [groq_pkg::SUPERLANE_LANES*32-1:0]  vxm_accum_out, mxm_w_accum_vec, mxm_e_accum_vec;

  assign vxm_op_valid = slice_vliw_valid_o[groq_pkg::SLICE_VXM] &
                        (slice_vliw_bundle_o[groq_pkg::SLICE_VXM][127:124] != groq_pkg::VXM_NOP) &
                        select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_VXM], stream_valid_west_o[groq_pkg::SLICE_VXM], slice_vliw_bundle_o[groq_pkg::SLICE_VXM][111:107]);
  assign vxm_stream_a = select_stream_data(stream_data_east_o[groq_pkg::SLICE_VXM], stream_data_west_o[groq_pkg::SLICE_VXM], slice_vliw_bundle_o[groq_pkg::SLICE_VXM][111:107]);
  assign vxm_stream_b = select_stream_data(stream_data_east_o[groq_pkg::SLICE_VXM], stream_data_west_o[groq_pkg::SLICE_VXM], slice_vliw_bundle_o[groq_pkg::SLICE_VXM][106:102]);
  assign vxm_stream_c = select_stream_data(stream_data_east_o[groq_pkg::SLICE_VXM], stream_data_west_o[groq_pkg::SLICE_VXM], slice_vliw_bundle_o[groq_pkg::SLICE_VXM][20:16]);

  groq_vxm_slice #(
    .P_LANES        (groq_pkg::SUPERLANE_LANES),
    .P_ELEM_BITS    (groq_pkg::ELEM_BITS),
    .P_STREAM_WIDTH (P_STREAM_WIDTH)
  ) u_vxm (
    .clk                 (clk),
    .rst_n               (rst_n),
    .op_valid_i          (vxm_op_valid),
    .vxm_op_i            (slice_vliw_bundle_o[groq_pkg::SLICE_VXM][127:124]),
    .prec_mode_i         (slice_vliw_bundle_o[groq_pkg::SLICE_VXM][115:112]),
    .quant_shift_i       (slice_vliw_bundle_o[groq_pkg::SLICE_VXM][23:21]),
    .use_accum_32b_i     (slice_vliw_bundle_o[groq_pkg::SLICE_VXM][24]),
    .stream_a_i          (vxm_stream_a),
    .stream_b_i          (vxm_stream_b),
    .stream_c_i          (vxm_stream_c),
    .accum_32b_in_i      (mxm_w_accum_vec),
    .stream_out_valid_o  (vxm_out_valid),
    .stream_out_data_o   (vxm_out_data),
    .accum_32b_out_o     (vxm_accum_out),
    .vxm_comb_data_o     (vxm_comb_unused),
    .reduce_sum_scalar_o (vxm_reduce_sum_o),
    .reduce_max_scalar_o (vxm_reduce_max_o),
    .mul_gate_active_o   (mul_gate_active_o),
    .lut_gate_active_o   (lut_gate_active_o)
  );

  // ---------------------------------------------------------------------------
  // Hop 4 (SLICE_MXM_W) & Hop 6 (SLICE_MXM_E): Systolic Matrix Units
  // ---------------------------------------------------------------------------
  logic                      mxm_w_act_valid, mxm_w_wt_valid, mxm_w_out_valid;
  logic [P_STREAM_WIDTH-1:0] mxm_w_act_data, mxm_w_wt_data, mxm_w_out_data;
  logic                      mxm_w_active_bank_unused;
  logic [15:0]               mxm_w_zero_mask_unused;

  assign mxm_w_act_valid = slice_vliw_valid_o[groq_pkg::SLICE_MXM_W] &
                           (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][123:120] == groq_pkg::MXM_SYSTOLIC_EXEC) &
                           select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_MXM_W], stream_valid_west_o[groq_pkg::SLICE_MXM_W], slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][111:107]);
  assign mxm_w_act_data  = select_stream_data(stream_data_east_o[groq_pkg::SLICE_MXM_W], stream_data_west_o[groq_pkg::SLICE_MXM_W], slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][111:107]);
  assign mxm_w_wt_valid  = slice_vliw_valid_o[groq_pkg::SLICE_MXM_W] &
                           ((slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][123:120] == groq_pkg::MXM_LOAD_WEIGHT_B0) ||
                            (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][123:120] == groq_pkg::MXM_LOAD_WEIGHT_B1)) &
                           select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_MXM_W], stream_valid_west_o[groq_pkg::SLICE_MXM_W], slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][106:102]);
  assign mxm_w_wt_data   = select_stream_data(stream_data_east_o[groq_pkg::SLICE_MXM_W], stream_data_west_o[groq_pkg::SLICE_MXM_W], slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][106:102]);

  groq_mxm_slice #(
    .P_LANES        (groq_pkg::SUPERLANE_LANES),
    .P_ELEM_BITS    (groq_pkg::ELEM_BITS),
    .P_STREAM_WIDTH (P_STREAM_WIDTH),
    .P_ACCUM_BITS   (32),
    .P_LATENCY      (2)
  ) u_mxm_w (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .mxm_op_i              (slice_vliw_valid_o[groq_pkg::SLICE_MXM_W] ? slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][123:120] : groq_pkg::MXM_NOP),
    .prec_mode_i           (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][115:112]),
    .weight_row_idx_i      (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][19:16]),
    .act_zero_gate_en_i    (1'b1),
    .accum_clear_i         (slice_vliw_valid_o[groq_pkg::SLICE_MXM_W] & (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][123:120] == groq_pkg::MXM_ACCUM_CLEAR)),
    .accum_preload_en_i    (slice_vliw_valid_o[groq_pkg::SLICE_MXM_W] & (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_W][123:120] == groq_pkg::MXM_ACCUM_PRELOAD)),
    .bg_wt_load_en_i       (1'b0),
    .bg_wt_row_idx_i       (4'd0),
    .bg_wt_data_i          ('0),
    .stream_act_valid_i    (mxm_w_act_valid),
    .stream_act_data_i     (mxm_w_act_data),
    .stream_wt_valid_i     (mxm_w_wt_valid),
    .stream_wt_data_i      (mxm_w_wt_data),
    .accum_preload_data_i  (vxm_accum_out),
    .active_bank_o         (mxm_w_active_bank_unused),
    .zero_skip_gate_mask_o (mxm_w_zero_mask_unused),
    .zero_skip_count_o     (zero_skip_count_w_o),
    .out_valid_o           (mxm_w_out_valid),
    .stream_out_data_o     (mxm_w_out_data),
    .accum_vec_o           (mxm_w_accum_vec)
  );

  logic                      mxm_e_act_valid, mxm_e_wt_valid, mxm_e_out_valid;
  logic [P_STREAM_WIDTH-1:0] mxm_e_act_data, mxm_e_wt_data, mxm_e_out_data;
  logic                      mxm_e_active_bank_unused;
  logic [15:0]               mxm_e_zero_mask_unused;

  assign mxm_e_act_valid = slice_vliw_valid_o[groq_pkg::SLICE_MXM_E] &
                           (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][123:120] == groq_pkg::MXM_SYSTOLIC_EXEC) &
                           select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_MXM_E], stream_valid_west_o[groq_pkg::SLICE_MXM_E], slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][111:107]);
  assign mxm_e_act_data  = select_stream_data(stream_data_east_o[groq_pkg::SLICE_MXM_E], stream_data_west_o[groq_pkg::SLICE_MXM_E], slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][111:107]);
  assign mxm_e_wt_valid  = slice_vliw_valid_o[groq_pkg::SLICE_MXM_E] &
                           ((slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][123:120] == groq_pkg::MXM_LOAD_WEIGHT_B0) ||
                            (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][123:120] == groq_pkg::MXM_LOAD_WEIGHT_B1)) &
                           select_stream_valid(stream_valid_east_o[groq_pkg::SLICE_MXM_E], stream_valid_west_o[groq_pkg::SLICE_MXM_E], slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][106:102]);
  assign mxm_e_wt_data   = select_stream_data(stream_data_east_o[groq_pkg::SLICE_MXM_E], stream_data_west_o[groq_pkg::SLICE_MXM_E], slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][106:102]);

  groq_mxm_slice #(
    .P_LANES        (groq_pkg::SUPERLANE_LANES),
    .P_ELEM_BITS    (groq_pkg::ELEM_BITS),
    .P_STREAM_WIDTH (P_STREAM_WIDTH),
    .P_ACCUM_BITS   (32),
    .P_LATENCY      (2)
  ) u_mxm_e (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .mxm_op_i              (slice_vliw_valid_o[groq_pkg::SLICE_MXM_E] ? slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][123:120] : groq_pkg::MXM_NOP),
    .prec_mode_i           (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][115:112]),
    .weight_row_idx_i      (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][19:16]),
    .act_zero_gate_en_i    (1'b1),
    .accum_clear_i         (slice_vliw_valid_o[groq_pkg::SLICE_MXM_E] & (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][123:120] == groq_pkg::MXM_ACCUM_CLEAR)),
    .accum_preload_en_i    (slice_vliw_valid_o[groq_pkg::SLICE_MXM_E] & (slice_vliw_bundle_o[groq_pkg::SLICE_MXM_E][123:120] == groq_pkg::MXM_ACCUM_PRELOAD)),
    .bg_wt_load_en_i       (1'b0),
    .bg_wt_row_idx_i       (4'd0),
    .bg_wt_data_i          ('0),
    .stream_act_valid_i    (mxm_e_act_valid),
    .stream_act_data_i     (mxm_e_act_data),
    .stream_wt_valid_i     (mxm_e_wt_valid),
    .stream_wt_data_i      (mxm_e_wt_data),
    .accum_preload_data_i  (vxm_accum_out),
    .active_bank_o         (mxm_e_active_bank_unused),
    .zero_skip_gate_mask_o (mxm_e_zero_mask_unused),
    .zero_skip_count_o     (zero_skip_count_e_o),
    .out_valid_o           (mxm_e_out_valid),
    .stream_out_data_o     (mxm_e_out_data),
    .accum_vec_o           (mxm_e_accum_vec)
  );

  // ---------------------------------------------------------------------------
  // Deterministic Slice Destination Stream Tracking & Fabric Injection Mux
  // ---------------------------------------------------------------------------
  logic [P_NUM_SLICES-1:0][3:0] dst_sid_d1_q, dst_sid_d2_q;
  logic [P_NUM_SLICES-1:0]      dst_west_d1_q, dst_west_d2_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dst_sid_d1_q  <= '0;
      dst_sid_d2_q  <= '0;
      dst_west_d1_q <= '0;
      dst_west_d2_q <= '0;
    end else begin
      for (int s = 0; s < P_NUM_SLICES; s++) begin
        if (slice_vliw_valid_o[s]) begin
          dst_sid_d1_q[s]  <= slice_vliw_bundle_o[s][100:97];
          dst_west_d1_q[s] <= slice_vliw_bundle_o[s][96] |
                              (slice_vliw_bundle_o[s][135:132] == groq_pkg::MEM_READ_WEST);
        end
        dst_sid_d2_q[s]  <= dst_sid_d1_q[s];
        dst_west_d2_q[s] <= dst_west_d1_q[s];
      end
    end
  end

  logic [P_NUM_SLICES-1:0]                      slice_inj_valid;
  logic [P_NUM_SLICES-1:0][3:0]                 slice_inj_sid;
  logic [P_NUM_SLICES-1:0]                      slice_inj_west;
  logic [P_NUM_SLICES-1:0][P_STREAM_WIDTH-1:0]  slice_inj_data;

  always_comb begin
    for (int s = 0; s < P_NUM_SLICES; s++) begin
      slice_notify_ready[s]= slice_vliw_valid_o[s] & (slice_vliw_bundle_o[s][139:136] == groq_pkg::ICU_NOTIFY);
      slice_inj_valid[s]   = 1'b0;
      slice_inj_sid[s]     = dst_sid_d1_q[s];
      slice_inj_west[s]    = dst_west_d1_q[s];
      slice_inj_data[s]    = '0;
    end

    // Hop 0: NIM output injection
    slice_inj_valid[groq_pkg::SLICE_NIM]   = nim_stream_out_valid;
    slice_inj_data[groq_pkg::SLICE_NIM]    = nim_stream_out_data;

    // Hop 1: West Memory Slice output injection (1-cycle read pipeline)
    slice_inj_valid[groq_pkg::SLICE_MEM_W] = mem_w_out_valid;
    slice_inj_data[groq_pkg::SLICE_MEM_W]  = mem_w_out_data;

    // Hop 2: SXM Permute Slice output injection (1-cycle pipeline)
    slice_inj_valid[groq_pkg::SLICE_SXM]   = sxm_out_valid;
    slice_inj_data[groq_pkg::SLICE_SXM]    = sxm_out_data;

    // Hop 3: VXM Vector Slice output injection (1-cycle pipeline)
    slice_inj_valid[groq_pkg::SLICE_VXM]   = vxm_out_valid;
    slice_inj_data[groq_pkg::SLICE_VXM]    = vxm_out_data;

    // Hop 4: West MXM Systolic Slice output injection (2-cycle pipeline)
    slice_inj_valid[groq_pkg::SLICE_MXM_W] = mxm_w_out_valid;
    slice_inj_sid[groq_pkg::SLICE_MXM_W]   = dst_sid_d2_q[groq_pkg::SLICE_MXM_W];
    slice_inj_west[groq_pkg::SLICE_MXM_W]  = dst_west_d2_q[groq_pkg::SLICE_MXM_W];
    slice_inj_data[groq_pkg::SLICE_MXM_W]  = mxm_w_out_data;

    // Hop 6: East MXM Systolic Slice output injection (2-cycle pipeline)
    slice_inj_valid[groq_pkg::SLICE_MXM_E] = mxm_e_out_valid;
    slice_inj_sid[groq_pkg::SLICE_MXM_E]   = dst_sid_d2_q[groq_pkg::SLICE_MXM_E];
    slice_inj_west[groq_pkg::SLICE_MXM_E]  = dst_west_d2_q[groq_pkg::SLICE_MXM_E];
    slice_inj_data[groq_pkg::SLICE_MXM_E]  = mxm_e_out_data;

    // Hop 7: East Memory Slice output injection (1-cycle read pipeline)
    slice_inj_valid[groq_pkg::SLICE_MEM_E] = mem_e_out_valid;
    slice_inj_data[groq_pkg::SLICE_MEM_E]  = mem_e_out_data;

    // Combine External + Slice Stream Injection into groq_stream_fabric
    fab_east_inject_en       = ext_east_inject_en_i;
    fab_east_inject_data     = ext_east_inject_data_i;
    fab_east_overwrite_allow = {P_NUM_SLICES{{P_NUM_EAST_STREAMS{ext_overwrite_allow_i}}}};
    fab_east_consume_en      = '0;

    fab_west_inject_en       = ext_west_inject_en_i;
    fab_west_inject_data     = ext_west_inject_data_i;
    fab_west_overwrite_allow = {P_NUM_SLICES{{P_NUM_WEST_STREAMS{ext_overwrite_allow_i}}}};
    fab_west_consume_en      = '0;

    for (int s = 0; s < P_NUM_SLICES; s++) begin
      if (slice_inj_valid[s]) begin
        if (!slice_inj_west[s]) begin
          for (int k = 0; k < P_NUM_EAST_STREAMS; k++) begin
            if (slice_inj_sid[s] == 4'(k)) begin
              fab_east_inject_en[s][k]       = 1'b1;
              fab_east_overwrite_allow[s][k] = 1'b1;
              fab_east_inject_data[s][k]     = slice_inj_data[s];
            end
          end
        end else begin
          for (int k = 0; k < P_NUM_WEST_STREAMS; k++) begin
            if (slice_inj_sid[s] == 4'(k)) begin
              fab_west_inject_en[s][k]       = 1'b1;
              fab_west_overwrite_allow[s][k] = 1'b1;
              fab_west_inject_data[s][k]     = slice_inj_data[s];
            end
          end
        end
      end
    end
  end

  // Tie off unused diagnostic signals cleanly for Verilator -Wall
  wire _unused_ok = &{1'b0,
    fab_collision_east_unused, fab_collision_west_unused,
    slice_nop_timer_unused, barrier_ready_mask_unused,
    realsync_cycle_cnt_unused, realsync_deskew_offset_unused,
    nim_deskew_target_unused, nim_ping_ack,
    mem_w_mbist_done_unused, mem_w_mbist_fail_unused, mem_w_syndrome_unused,
    mem_w_rd_done, mem_w_wr_done,
    mem_e_mbist_done_unused, mem_e_mbist_fail_unused, mem_e_syndrome_unused,
    mem_e_rd_done, mem_e_wr_done,
    sxm_comb_unused, vxm_comb_unused, mxm_e_accum_vec,
    mxm_w_active_bank_unused, mxm_w_zero_mask_unused,
    mxm_e_active_bank_unused, mxm_e_zero_mask_unused};


`ifdef FORMAL_TOP
  /* verilator lint_off SYNCASYNCNET */
  logic                                            f_top_past_q;
  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0] f_top_eval_q, f_top_einj_q;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0] f_top_wval_q, f_top_winj_q;
  logic [3:0]                                      f_top_no_inj_cnt_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      f_top_past_q       <= 1'b0;
      f_top_eval_q       <= '0;
      f_top_einj_q       <= '0;
      f_top_wval_q       <= '0;
      f_top_winj_q       <= '0;
      f_top_no_inj_cnt_q <= 4'd0;
    end else begin
      f_top_past_q <= 1'b1;
      f_top_eval_q <= stream_valid_east_o;
      f_top_einj_q <= fab_east_inject_en;
      f_top_wval_q <= stream_valid_west_o;
      f_top_winj_q <= fab_west_inject_en;
      if ((fab_east_inject_en == '0) && (fab_west_inject_en == '0)) begin
        if (f_top_no_inj_cnt_q < 4'd8) f_top_no_inj_cnt_q <= f_top_no_inj_cnt_q + 4'd1;
      end else begin
        f_top_no_inj_cnt_q <= 4'd0;
      end
    end
  end

  always_comb begin
    if (rst_n) begin
      // 1. Global Stream Fabric Zero-Stall & 1-Hop/Cycle Determinism
      assert(fab_east_consume_en == '0);
      assert(fab_west_consume_en == '0);
      if (f_top_past_q) begin
        for (int hs = 1; hs < P_NUM_SLICES; hs++) begin
          assert(stream_valid_east_o[hs] == (f_top_einj_q[hs] | f_top_eval_q[hs-1]));
        end
        for (int hs = 0; hs < P_NUM_SLICES - 1; hs++) begin
          assert(stream_valid_west_o[hs] == (f_top_winj_q[hs] | f_top_wval_q[hs+1]));
        end
      end
      // 2. Barrier & Halt Memory Write Safety on u_mem_w and u_mem_e
      if ((barrier_waiting_o[groq_pkg::SLICE_MEM_W] || slice_halted_o[groq_pkg::SLICE_MEM_W]) && !host_mem_w_wr_en_i) begin
        assert(!mem_w_wr_valid);
      end
      if ((barrier_waiting_o[groq_pkg::SLICE_MEM_E] || slice_halted_o[groq_pkg::SLICE_MEM_E]) && !host_mem_e_wr_en_i) begin
        assert(!mem_e_wr_valid);
      end
      // 4b. Stream Decay Bound when no fabric injections occur
      for (int hk = 0; hk < P_NUM_SLICES; hk++) begin
        if (f_top_no_inj_cnt_q > 4'(hk)) begin
          assert(stream_valid_east_o[hk] == '0);
          assert(stream_valid_west_o[P_NUM_SLICES - 1 - hk] == '0);
        end
      end
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif
endmodule : groq_lpu_top

`endif // GROQ_LPU_TOP_SV
