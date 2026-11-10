// =============================================================================
// File: rtl/groq_dragonfly_8chip_cluster.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 13 8-Chip Dragonfly Group Scale-Out Cluster RTL:
//              - 8 x groq_lpu_top instances (chip_id = 0..7)
//              - 8 x groq_c2c_serdes_pcs instances (64B/66B, LFSR, CRC-16, GBN)
//              - 1 x groq_pcie_c2c_dma Cluster Host DMA + Broadcast/Unicast
//              - 8x8 Dragonfly Switch Matrix supporting 4 Routing Modes:
//                00: ROUTE_DIRECT_CROSSBAR (1-hop full mesh)
//                01: ROUTE_BIDIR_RING      (8-chip East/West ring AllReduce)
//                10: ROUTE_UGAL_ADAPTIVE   (Minimal vs Valiant c^4 non-minimal)
//                11: ROUTE_MOE_ALLTOALL_BUTTERFLY (Radix-2/8 XOR permutation)
// =============================================================================
`ifndef GROQ_DRAGONFLY_8CHIP_CLUSTER_SV
`define GROQ_DRAGONFLY_8CHIP_CLUSTER_SV

`include "groq_pkg.sv"

module groq_dragonfly_8chip_cluster #(
 parameter int P_NUM_CHIPS = 8,
 parameter int P_NUM_SLICES = groq_pkg::NUM_SLICES,
 parameter int P_NUM_EAST_STREAMS = groq_pkg::NUM_EAST_STREAMS,
 parameter int P_NUM_WEST_STREAMS = groq_pkg::NUM_WEST_STREAMS,
 parameter int P_STREAM_WIDTH = groq_pkg::STREAM_WIDTH,
 parameter int unsigned P_MEM_BANKS = 4,
 parameter int unsigned P_MEM_BANK_ID_W = 2,
`ifdef FORMAL
 parameter int unsigned P_MEM_ADDR_W = 3
`else
 parameter int unsigned P_MEM_ADDR_W = 10
`endif
) (
 input logic clk,
 input logic rst_n,

 // 1. Per-Chip ICU Dispatch & VLIW Program Bundle Interface
 input logic [P_NUM_CHIPS-1:0] chip_icu_enable_i,
 input logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0][groq_pkg::VLIW_INSTR_BITS-1:0] chip_imem_vliw_bundle_i,
 output logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0][15:0] chip_pc_slice_o,
 output logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0] chip_slice_halted_o,

 // 2. Cluster-Level Host NVLink-C2C / PCIe Gen5 DMA Controller Interface
 input logic [15:0] global_cycle_i,
 input logic [2:0] dma_target_chip_i,
 input logic dma_bcast_all_chips_i,
 input logic dma_vliw_sram_busy_i,
 input logic dma_desc_push_valid_i,
 input logic [127:0] dma_desc_push_data_i,
 output logic dma_desc_push_ready_o,
 input logic dma_payload_valid_i,
 input logic [P_STREAM_WIDTH-1:0] dma_payload_data_i,
 input logic [15:0] dma_payload_parity_i,
 output logic dma_payload_ready_o,
 output logic dma_busy_o,
 output logic dma_window_stall_o,
 output logic dma_parity_err_o,
 output logic dma_done_irq_o,
 output logic [7:0] dma_completed_desc_cnt_o,
 output logic [15:0] dma_beats_transferred_o,

 // 3. Dragonfly Group Multi-Topology Routing & Collective Control
 input logic [1:0] cluster_route_mode_i,
 input logic ring_dir_west_i,
 input logic [P_NUM_CHIPS-1:0] congestion_mask_i,
 input logic [2:0] butterfly_stage_i,

 // 4. PCS Link Training, Plesiochronous Delay & Error Injection Control
 input logic pcs_link_enable_i,
 input logic pcs_scramble_en_i,
 input logic pcs_rx_ts1_seen_i,
 input logic pcs_rx_ts2_seen_i,
 input logic pcs_deskew_done_i,
 input logic pcs_retrain_req_i,
 input logic [P_NUM_CHIPS-1:0] link_delay_en_i,
 input logic [15:0] expected_flight_cycles_i,
 input logic [P_NUM_CHIPS-1:0] pcs_err_inject_en_i,
 input logic [15:0] pcs_err_inject_mask_i,
 input logic [P_NUM_CHIPS-1:0] mem_err_inject_en_i = '0,
 input logic [143:0] mem_err_inject_mask_i = '0,

 // 5. Cluster-Wide Hardware Sync, Stream Observation & Fault Telemetry
 output logic cluster_all_halted_o,
 output logic cluster_any_barrier_o,
 output logic [P_NUM_CHIPS-1:0] cluster_pcs_link_up_o,
 output logic [P_NUM_CHIPS-1:0] cluster_crc16_err_o,
 output logic [P_NUM_CHIPS-1:0] cluster_realsync_err_o,
 output logic [P_NUM_CHIPS-1:0] cluster_ecc_single_err_o,
 output logic [P_NUM_CHIPS-1:0] cluster_ecc_double_err_o,
 output logic [P_NUM_CHIPS-1:0] cluster_c2c_tx_valid_o,
 output logic [P_NUM_CHIPS-1:0] cluster_deskew_release_o,
 output logic [P_NUM_CHIPS-1:0][2:0] cluster_routed_dst_o,
 output logic [P_NUM_CHIPS-1:0][P_STREAM_WIDTH-1:0] cluster_nim_rx_data_o
);

  // ---------------------------------------------------------------------------
  // 1. Dragonfly Group Routing Mode Encodings & Pure Routing Function
  // ---------------------------------------------------------------------------
  localparam logic [1:0] ROUTE_DIRECT_CROSSBAR        = 2'b00;
  localparam logic [1:0] ROUTE_BIDIR_RING             = 2'b01;
  localparam logic [1:0] ROUTE_UGAL_ADAPTIVE          = 2'b10;
  localparam logic [1:0] ROUTE_MOE_ALLTOALL_BUTTERFLY = 2'b11;

  localparam int P_PCS_FRAME_W = 2 + 16 + 16 + P_STREAM_WIDTH; // 162-bit PCS frame

  function automatic logic [2:0] calc_dragonfly_dst(
    input logic [2:0] src_chip,
    input logic [2:0] req_dst,
    input logic [1:0] mode,
    input logic       ring_west,
    input logic       congested,
    input logic [2:0] bstage
  );
    begin
      unique case (mode)
        ROUTE_DIRECT_CROSSBAR: begin
          calc_dragonfly_dst = req_dst;
        end
        ROUTE_BIDIR_RING: begin
          calc_dragonfly_dst = ring_west ? (src_chip + 3'd7) : (src_chip + 3'd1);
        end
        ROUTE_UGAL_ADAPTIVE: begin
          // Minimal 1-hop when uncongested; Valiant non-minimal chordal hop (c ^ 4) when congested
          calc_dragonfly_dst = (congested && (src_chip != req_dst)) ? (src_chip ^ 3'd4) : req_dst;
        end
        ROUTE_MOE_ALLTOALL_BUTTERFLY: begin
          // Hardware Radix-2/Radix-8 Butterfly XOR involution (bijective for all bstage)
          calc_dragonfly_dst = src_chip ^ bstage;
        end
        default: calc_dragonfly_dst = req_dst;
      endcase
    end
  endfunction

  function automatic logic [15:0] cluster_lfsr16_next(input logic [15:0] s_in);
    logic [15:0] s;
    logic fb;
    begin
      s = s_in;
      for (int i = 0; i < 16; i++) begin
        fb = s[15] ^ s[13] ^ s[12] ^ s[10];
        s  = {s[14:0], fb};
      end
      cluster_lfsr16_next = s;
    end
  endfunction

  function automatic logic [P_STREAM_WIDTH-1:0] cluster_apply_scram(
    input logic [P_STREAM_WIDTH-1:0] data_in,
    input logic [15:0]               seed,
    input logic                      en
  );
    logic [15:0]               s;
    logic [P_STREAM_WIDTH-1:0] mask;
    logic                      fb;
    begin
      if (!en) begin
        cluster_apply_scram = data_in;
      end else begin
        s    = seed;
        mask = '0;
        for (int b = 0; b < P_STREAM_WIDTH; b++) begin
          fb      = s[15] ^ s[13] ^ s[12] ^ s[10];
          mask[b] = fb;
          s       = {s[14:0], fb};
        end
        cluster_apply_scram = data_in ^ mask;
      end
    end
  endfunction

  logic [P_NUM_CHIPS-1:0][15:0] chip_tx_lfsr_q, chip_rx_lfsr_q;

  // ---------------------------------------------------------------------------
  // 2. Cluster-Level Host NVLink-C2C / PCIe Gen5 DMA Controller & Fanout
  // ---------------------------------------------------------------------------
  logic [P_NUM_CHIPS-1:0]      chip_vliw_sram_w_busy, chip_vliw_sram_e_busy;
  logic                        cluster_sram_w_busy, cluster_sram_e_busy, cluster_sram_any_busy;

  assign cluster_sram_w_busy   = dma_bcast_all_chips_i ? (|chip_vliw_sram_w_busy) : chip_vliw_sram_w_busy[dma_target_chip_i];
  assign cluster_sram_e_busy   = dma_bcast_all_chips_i ? (|chip_vliw_sram_e_busy) : chip_vliw_sram_e_busy[dma_target_chip_i];
  assign cluster_sram_any_busy = dma_vliw_sram_busy_i | cluster_sram_w_busy | cluster_sram_e_busy;

  logic                        dma_imem_wr_en;
  logic [2:0]                  dma_imem_wr_slice;
  logic [15:0]                 dma_imem_wr_addr_unused;
  logic [groq_pkg::VLIW_INSTR_BITS-1:0] dma_imem_wr_data;

  logic                        dma_mem_w_wr_en, dma_mem_e_wr_en;
  logic [P_MEM_BANK_ID_W-1:0]  dma_mem_w_bank,  dma_mem_e_bank;
  logic [P_MEM_ADDR_W-1:0]     dma_mem_w_addr,  dma_mem_e_addr;
  logic [P_STREAM_WIDTH-1:0]   dma_mem_w_data,  dma_mem_e_data;

  logic                        dma_full_unused, dma_empty_unused;
  logic [1:0]                  dma_head_unused, dma_tail_unused;
  logic [2:0]                  dma_cnt_unused;

  groq_pcie_c2c_dma #(
    .P_STREAM_WIDTH (P_STREAM_WIDTH),
    .P_VLIW_BITS    (groq_pkg::VLIW_INSTR_BITS),
    .P_RING_DEPTH   (4),
    .P_BANK_ID_W    (P_MEM_BANK_ID_W),
    .P_MEM_ADDR_W   (P_MEM_ADDR_W)
  ) u_cluster_dma (
    .clk                  (clk),
    .rst_n                (rst_n),
    .global_cycle_i       (global_cycle_i),
    .vliw_active_window_i (dma_vliw_sram_busy_i),
    .vliw_sram_busy_i     (cluster_sram_any_busy),
    .vliw_sram_w_busy_i   (cluster_sram_w_busy),
    .vliw_sram_e_busy_i   (cluster_sram_e_busy),
    .desc_push_valid_i    (dma_desc_push_valid_i),
    .desc_push_data_i     (dma_desc_push_data_i),
    .desc_push_ready_o    (dma_desc_push_ready_o),
    .full_o               (dma_full_unused),
    .empty_o              (dma_empty_unused),
    .head_ptr_o           (dma_head_unused),
    .tail_ptr_o           (dma_tail_unused),
    .desc_count_o         (dma_cnt_unused),
    .dma_payload_valid_i  (dma_payload_valid_i),
    .dma_payload_data_i   (dma_payload_data_i),
    .dma_payload_parity_i (dma_payload_parity_i),
    .dma_payload_ready_o  (dma_payload_ready_o),
    .imem_wr_en_o         (dma_imem_wr_en),
    .imem_wr_slice_o      (dma_imem_wr_slice),
    .imem_wr_addr_o       (dma_imem_wr_addr_unused),
    .imem_wr_data_o       (dma_imem_wr_data),
    .host_mem_w_wr_en_o   (dma_mem_w_wr_en),
    .host_mem_w_bank_o    (dma_mem_w_bank),
    .host_mem_w_addr_o    (dma_mem_w_addr),
    .host_mem_w_data_o    (dma_mem_w_data),
    .host_mem_e_wr_en_o   (dma_mem_e_wr_en),
    .host_mem_e_bank_o    (dma_mem_e_bank),
    .host_mem_e_addr_o    (dma_mem_e_addr),
    .host_mem_e_data_o    (dma_mem_e_data),
    .dma_busy_o           (dma_busy_o),
    .dma_window_stall_o   (dma_window_stall_o),
    .payload_parity_err_o (dma_parity_err_o),
    .dma_done_irq_o       (dma_done_irq_o),
    .completed_desc_cnt_o (dma_completed_desc_cnt_o),
    .beats_transferred_o  (dma_beats_transferred_o)
  );

  // Per-Chip DMA Target Selection & Preloaded IMEM Latch Array
  logic [P_NUM_CHIPS-1:0] chip_dma_sel;
  logic [P_NUM_CHIPS-1:0] chip_dma_w_wr_en;
  logic [P_NUM_CHIPS-1:0] chip_dma_e_wr_en;

  for (genvar c = 0; c < P_NUM_CHIPS; c++) begin : gen_dma_fanout
    assign chip_dma_sel[c]     = dma_bcast_all_chips_i || (dma_target_chip_i == 3'(c));
    assign chip_dma_w_wr_en[c] = dma_mem_w_wr_en && chip_dma_sel[c];
    assign chip_dma_e_wr_en[c] = dma_mem_e_wr_en && chip_dma_sel[c];
  end

  // ---------------------------------------------------------------------------
  // 3. Per-Chip LPU & PCS Signals + Programmable Plesiochronous Delay Pipes
  // ---------------------------------------------------------------------------
  logic [P_NUM_CHIPS-1:0]                      lpu_tx_valid,     lpu_rx_valid;
  logic [P_NUM_CHIPS-1:0][P_STREAM_WIDTH-1:0]  lpu_tx_data,      lpu_rx_data;
  logic [P_NUM_CHIPS-1:0][15:0]                lpu_tx_ts,        lpu_rx_ts;
  logic [P_NUM_CHIPS-1:0][3:0]                 lpu_tx_dst,       lpu_rx_dst;
  logic [P_NUM_CHIPS-1:0][7:0]                 lpu_tx_crc8,      lpu_rx_crc8;
  logic [P_NUM_CHIPS-1:0][1:0]                 lpu_tx_port_sel;

  logic [P_NUM_CHIPS-1:0][2:0]                 routed_dst_chip;
  logic [P_NUM_CHIPS-1:0]                      pcs_phy_tx_valid, pcs_phy_rx_valid;
  logic [P_NUM_CHIPS-1:0][P_PCS_FRAME_W-1:0]   pcs_phy_tx_frame, pcs_phy_rx_frame;
  logic [P_NUM_CHIPS-1:0][3:0]                 pcs_tx_seq_num,   pcs_rx_seq_unused;
  logic [P_NUM_CHIPS-1:0]                      pcs_rx_flit_valid;
  logic [P_NUM_CHIPS-1:0][P_STREAM_WIDTH-1:0]  pcs_rx_flit_data;
  logic [P_NUM_CHIPS-1:0][3:0]                 pcs_rx_dst_chip;
  logic [P_NUM_CHIPS-1:0]                      pcs_nack_out,     pcs_nack_in;
  logic [P_NUM_CHIPS-1:0][1:0]                 pcs_nack_seq_out, pcs_nack_seq_in;

  // Companion RealSync Timestamp & CRC-8 Wires
  logic [P_NUM_CHIPS-1:0][15:0]                pcs_tx_ts_wire,   pcs_rx_ts_wire;
  logic [P_NUM_CHIPS-1:0][7:0]                 pcs_tx_crc8_wire, pcs_rx_crc8_wire;

  // Post-Error-Injection & Post-Delay Physical Link Signals Entering Switch Matrix
  logic [P_NUM_CHIPS-1:0]                      link_tx_valid_eff;
  logic [P_NUM_CHIPS-1:0][P_PCS_FRAME_W-1:0]   link_tx_frame_eff;
  logic [P_NUM_CHIPS-1:0][15:0]                link_tx_ts_eff;
  logic [P_NUM_CHIPS-1:0][7:0]                 link_tx_crc8_eff;
  logic [P_NUM_CHIPS-1:0][2:0]                 link_tx_dst_eff;

  logic [P_NUM_CHIPS-1:0]                      dly_valid_q;
  logic [P_NUM_CHIPS-1:0][P_PCS_FRAME_W-1:0]   dly_frame_q;
  logic [P_NUM_CHIPS-1:0][15:0]                dly_ts_q;
  logic [P_NUM_CHIPS-1:0][7:0]                 dly_crc8_q;
  logic [P_NUM_CHIPS-1:0][2:0]                 dly_dst_q;

  logic [P_NUM_CHIPS-1:0]                      chip_all_slices_halted;
  logic [P_NUM_CHIPS-1:0]                      chip_any_slice_barrier;

  /* verilator lint_off WIDTHCONCAT */
  logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] zero_east_data;
  logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] zero_west_data;
  assign zero_east_data = '0;
  assign zero_west_data = '0;
  /* verilator lint_on WIDTHCONCAT */

  // ---------------------------------------------------------------------------
  // 4. Generate 8 x groq_lpu_top & 8 x groq_c2c_serdes_pcs Instances (c = 0..7)
  // ---------------------------------------------------------------------------
  for (genvar c = 0; c < P_NUM_CHIPS; c++) begin : gen_chip
    logic [P_NUM_SLICES-1:0]                                 fetch_unused, vval_unused, bwait_obs;
    logic [P_NUM_SLICES*groq_pkg::VLIW_INSTR_BITS-1:0]       vbun_obs;
    logic [P_NUM_SLICES*groq_pkg::VLIW_INSTR_BITS-1:0]       imem_reg_q;
    logic [P_NUM_SLICES*groq_pkg::VLIW_INSTR_BITS-1:0]       eff_imem_flat;
    logic [P_NUM_SLICES*groq_pkg::VLIW_INSTR_BITS-1:0]       in_imem_flat;
    assign in_imem_flat = chip_imem_vliw_bundle_i[c];
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        imem_reg_q <= '0;
      end else if (dma_imem_wr_en && chip_dma_sel[c]) begin
        imem_reg_q[dma_imem_wr_slice*groq_pkg::VLIW_INSTR_BITS +: groq_pkg::VLIW_INSTR_BITS] <= dma_imem_wr_data;
      end
    end
    assign eff_imem_flat = (in_imem_flat != '0) ? in_imem_flat : imem_reg_q;
    logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0]         eval_unused;
    logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] edat_unused;
    logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0]         wval_unused;
    logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] wdat_unused;
    logic        coll_flt_unused, coll_stk_unused, brel_unused, drift_flt, c2c_crc8_err;
    logic [15:0] bcnt_unused, ghop_unused;
    logic [63:0] rtime_obs;
    logic [55:0] rtime_hi_unused;
    assign rtime_hi_unused = rtime_obs[63:8];
    wire _unused_chip_bits = &{1'b0, vbun_obs, pcs_tx_seq_num[c][3:2]};
    logic signed [15:0] mskew_unused, vsum_unused;
    logic [1:0]  ecc_s_err, ecc_d_err, bconf_unused;
    logic [4:0]  zskip_w_unused, zskip_e_unused;
    logic        mgate_unused, lgate_unused;
    logic signed [7:0] vmax_unused;

    // Detect active VLIW SRAM operations on West (Hop 1) and East (Hop 7) slices
    assign chip_vliw_sram_w_busy[c] = vval_unused[groq_pkg::SLICE_MEM_W] &&
                                      (vbun_obs[groq_pkg::SLICE_MEM_W*groq_pkg::VLIW_INSTR_BITS + 132 +: 4] != groq_pkg::MEM_NOP);
    assign chip_vliw_sram_e_busy[c] = vval_unused[groq_pkg::SLICE_MEM_E] &&
                                      (vbun_obs[groq_pkg::SLICE_MEM_E*groq_pkg::VLIW_INSTR_BITS + 132 +: 4] != groq_pkg::MEM_NOP);

    groq_lpu_top #(
      .P_NUM_SLICES       (P_NUM_SLICES),
      .P_NUM_EAST_STREAMS (P_NUM_EAST_STREAMS),
      .P_NUM_WEST_STREAMS (P_NUM_WEST_STREAMS),
      .P_STREAM_WIDTH     (P_STREAM_WIDTH),
      .P_MEM_BANKS        (P_MEM_BANKS),
      .P_MEM_BANK_ID_W    (P_MEM_BANK_ID_W),
      .P_MEM_ADDR_W       (P_MEM_ADDR_W)
    ) u_lpu (
      .clk                      (clk),
      .rst_n                    (rst_n),
      .icu_enable_i             (chip_icu_enable_i[c]),
      .imem_vliw_bundle_i       (eff_imem_flat),
      .imem_fetch_en_o          (fetch_unused),
      .pc_slice_o               (chip_pc_slice_o[c]),
      .slice_vliw_valid_o       (vval_unused),
      .slice_vliw_bundle_o      (vbun_obs),
      .slice_halted_o           (chip_slice_halted_o[c]),
      .ext_east_inject_en_i     ('0),
      .ext_east_inject_data_i   (zero_east_data),
      .ext_west_inject_en_i     ('0),
      .ext_west_inject_data_i   (zero_west_data),
      .ext_overwrite_allow_i    (1'b0),
      .stream_valid_east_o      (eval_unused),
      .stream_data_east_o       (edat_unused),
      .stream_valid_west_o      (wval_unused),
      .stream_data_west_o       (wdat_unused),
      .host_mem_w_wr_en_i       (chip_dma_w_wr_en[c]),
      .host_mem_w_bank_i        (dma_mem_w_bank),
      .host_mem_w_addr_i        (dma_mem_w_addr),
      .host_mem_w_data_i        (dma_mem_w_data),
      .host_mem_e_wr_en_i       (chip_dma_e_wr_en[c]),
      .host_mem_e_bank_i        (dma_mem_e_bank),
      .host_mem_e_addr_i        (dma_mem_e_addr),
      .host_mem_e_data_i        (dma_mem_e_data),
      .mem_err_inject_en_i      (mem_err_inject_en_i[c]),
      .mem_err_inject_mask_i    (mem_err_inject_mask_i),
      .local_chip_id_i          (4'(c)),
      .expected_flight_cycles_i (expected_flight_cycles_i),
      .realsync_ext_adj_en_i    (1'b0),
      .realsync_ext_adj_val_i   (16'sd0),
      .c2c_rx_valid_i           (lpu_rx_valid[c]),
      .c2c_rx_data_i            (lpu_rx_data[c]),
      .c2c_rx_tx_timestamp_i    (lpu_rx_ts[c]),
      .c2c_rx_dst_chip_i        (lpu_rx_dst[c]),
      .c2c_rx_crc8_i            (lpu_rx_crc8[c]),
      .c2c_tx_valid_o           (lpu_tx_valid[c]),
      .c2c_tx_data_o            (lpu_tx_data[c]),
      .c2c_tx_timestamp_o       (lpu_tx_ts[c]),
      .c2c_tx_dst_chip_o        (lpu_tx_dst[c]),
      .c2c_tx_crc8_o            (lpu_tx_crc8[c]),
      .c2c_tx_port_sel_o        (lpu_tx_port_sel[c]),
      .collision_fault_o        (coll_flt_unused),
      .collision_sticky_o       (coll_stk_unused),
      .barrier_waiting_o        (bwait_obs),
      .barrier_release_pulse_o  (brel_unused),
      .barrier_release_cnt_o    (bcnt_unused),
      .realsync_aligned_time_o  (rtime_obs),
      .realsync_drift_fault_o   (drift_flt),
      .deskew_release_valid_o   (cluster_deskew_release_o[c]),
      .measured_skew_o          (mskew_unused),
      .c2c_crc_err_o            (c2c_crc8_err),
      .ecc_single_err_o         (ecc_s_err),
      .ecc_double_err_o         (ecc_d_err),
      .bank_conflict_err_o      (bconf_unused),
      .gated_hop_count_o        (ghop_unused),
      .zero_skip_count_w_o      (zskip_w_unused),
      .zero_skip_count_e_o      (zskip_e_unused),
      .mul_gate_active_o        (mgate_unused),
      .lut_gate_active_o        (lgate_unused),
      .vxm_reduce_sum_o         (vsum_unused),
      .vxm_reduce_max_o         (vmax_unused)
    );

    assign routed_dst_chip[c] = calc_dragonfly_dst(
      3'(c),
      lpu_tx_dst[c][2:0],
      cluster_route_mode_i,
      ring_dir_west_i,
      congestion_mask_i[c],
      butterfly_stage_i
    );

    logic        pcs_tx_ready_unused, pcs_replay_act_unused, pcs_rx_sync_err;
    logic [1:0]  pcs_tx_shdr_unused;
    logic [15:0] pcs_tx_crc16_unused, pcs_tx_meta_unused;
    logic [P_STREAM_WIDTH-1:0] pcs_tx_scram_unused;
    logic [3:0]  pcs_rx_hop_unused, pcs_rx_op_unused;
    logic [2:0]  pcs_lstate_unused;
    logic [7:0]  pcs_mskew_unused;

    groq_c2c_serdes_pcs #(
      .P_STREAM_WIDTH (P_STREAM_WIDTH),
      .P_META_WIDTH   (16),
      .P_CRC_WIDTH    (16),
      .P_REPLAY_DEPTH (4)
    ) u_pcs (
      .clk                     (clk),
      .rst_n                   (rst_n),
      .link_enable_i           (pcs_link_enable_i),
      .scramble_en_i           (pcs_scramble_en_i),
      .rx_ts1_seen_i           (pcs_rx_ts1_seen_i),
      .rx_ts2_seen_i           (pcs_rx_ts2_seen_i),
      .deskew_done_i           (pcs_deskew_done_i),
      .retrain_req_i           (pcs_retrain_req_i),
      .local_realsync_cnt_i    (rtime_obs[7:0]),
      .rx_beacon_ts_i          (rtime_obs[7:0]),
      .tx_flit_valid_i         (lpu_tx_valid[c]),
      .tx_flit_data_i          (lpu_tx_data[c]),
      .tx_dst_chip_i           ({1'b0, routed_dst_chip[c]}),
      .tx_hop_cnt_i            ({2'b00, lpu_tx_port_sel[c]}),
      .tx_opcode_i             (lpu_tx_crc8[c][3:0]),
      .tx_ready_o              (pcs_tx_ready_unused),
      .nack_req_i              (pcs_nack_in[c]),
      .nack_seq_i              (pcs_nack_seq_in[c]),
      .phy_tx_valid_o          (pcs_phy_tx_valid[c]),
      .phy_tx_frame_o          (pcs_phy_tx_frame[c]),
      .tx_sync_hdr_o           (pcs_tx_shdr_unused),
      .tx_crc16_o              (pcs_tx_crc16_unused),
      .tx_meta_o               (pcs_tx_meta_unused),
      .tx_scrambled_payload_o  (pcs_tx_scram_unused),
      .replay_active_o         (pcs_replay_act_unused),
      .tx_seq_num_o            (pcs_tx_seq_num[c]),
      .phy_rx_valid_i          (pcs_phy_rx_valid[c]),
      .phy_rx_frame_i          (pcs_phy_rx_frame[c]),
      .rx_flit_valid_o         (pcs_rx_flit_valid[c]),
      .rx_flit_data_o          (pcs_rx_flit_data[c]),
      .rx_dst_chip_o           (pcs_rx_dst_chip[c]),
      .rx_hop_cnt_o            (pcs_rx_hop_unused),
      .rx_opcode_o             (pcs_rx_op_unused),
      .rx_seq_num_o            (pcs_rx_seq_unused[c]),
      .rx_crc16_err_o          (cluster_crc16_err_o[c]),
      .rx_sync_err_o           (pcs_rx_sync_err),
      .nack_req_o              (pcs_nack_out[c]),
      .nack_seq_o              (pcs_nack_seq_out[c]),
      .link_state_o            (pcs_lstate_unused),
      .link_up_o               (cluster_pcs_link_up_o[c]),
      .measured_skew_o         (pcs_mskew_unused)
    );

    // Record RealSync timestamp & CRC8 in 4-entry companion replay table
    logic [63:0] ts_replay_flat_q;
    logic [31:0] crc8_replay_flat_q;
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        ts_replay_flat_q   <= '0;
        crc8_replay_flat_q <= '0;
      end else if (lpu_tx_valid[c] && cluster_pcs_link_up_o[c] && !pcs_replay_act_unused && !pcs_nack_in[c]) begin
        ts_replay_flat_q[pcs_tx_seq_num[c][1:0]*16 +: 16]  <= lpu_tx_ts[c];
        crc8_replay_flat_q[pcs_tx_seq_num[c][1:0]*8 +: 8]  <= lpu_tx_crc8[c];
      end
    end

    assign pcs_tx_ts_wire[c]   = (!pcs_replay_act_unused && !pcs_nack_in[c]) ?
                                 lpu_tx_ts[c]   : ts_replay_flat_q[pcs_tx_seq_num[c][1:0]*16 +: 16];
    assign pcs_tx_crc8_wire[c] = (!pcs_replay_act_unused && !pcs_nack_in[c]) ?
                                 lpu_tx_crc8[c] : crc8_replay_flat_q[pcs_tx_seq_num[c][1:0]*8 +: 8];

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        chip_tx_lfsr_q[c] <= 16'hACE1;
        chip_rx_lfsr_q[c] <= 16'hACE1;
      end else if (!cluster_pcs_link_up_o[c]) begin
        chip_tx_lfsr_q[c] <= 16'hACE1;
        chip_rx_lfsr_q[c] <= 16'hACE1;
      end else begin
        if (pcs_phy_tx_valid[c] && (pcs_phy_tx_frame[c][P_PCS_FRAME_W-1 -: 2] == 2'b01) && pcs_scramble_en_i) begin
          chip_tx_lfsr_q[c] <= cluster_lfsr16_next(chip_tx_lfsr_q[c]);
        end
        if (pcs_phy_rx_valid[c] && (pcs_phy_rx_frame[c][P_PCS_FRAME_W-1 -: 2] == 2'b01) && !cluster_crc16_err_o[c] && pcs_scramble_en_i) begin
          chip_rx_lfsr_q[c] <= cluster_lfsr16_next(chip_rx_lfsr_q[c]);
        end
      end
    end

    logic [P_PCS_FRAME_W-1:0] frame_tx_norm;
    assign frame_tx_norm = {
      pcs_phy_tx_frame[c][P_PCS_FRAME_W-1 : P_STREAM_WIDTH],
      cluster_apply_scram(
        pcs_phy_tx_frame[c][P_STREAM_WIDTH-1:0],
        chip_tx_lfsr_q[c],
        pcs_scramble_en_i && (pcs_phy_tx_frame[c][P_PCS_FRAME_W-1 -: 2] == 2'b01)
      )
    };

    // Programmable CRC-16 Error Injection & 1-Cycle Plesiochronous Link Delay
    logic [P_PCS_FRAME_W-1:0] frame_err_injected;
    assign frame_err_injected = pcs_err_inject_en_i[c] ?
                                (frame_tx_norm ^ {{(P_PCS_FRAME_W-16){1'b0}}, pcs_err_inject_mask_i}) :
                                frame_tx_norm;

    logic [2:0] eff_routed_dst;
    assign eff_routed_dst = (!pcs_replay_act_unused && !pcs_nack_in[c]) ?
                            routed_dst_chip[c] : pcs_tx_meta_unused[14:12];

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        dly_valid_q[c] <= 1'b0;
        dly_frame_q[c] <= '0;
        dly_ts_q[c]    <= '0;
        dly_crc8_q[c]  <= '0;
        dly_dst_q[c]   <= '0;
      end else begin
        dly_valid_q[c] <= pcs_phy_tx_valid[c];
        dly_frame_q[c] <= frame_err_injected;
        dly_ts_q[c]    <= pcs_tx_ts_wire[c];
        dly_crc8_q[c]  <= pcs_tx_crc8_wire[c];
        dly_dst_q[c]   <= eff_routed_dst;
      end
    end

    assign link_tx_valid_eff[c] = link_delay_en_i[c] ? dly_valid_q[c] : pcs_phy_tx_valid[c];
    assign link_tx_frame_eff[c] = link_delay_en_i[c] ? dly_frame_q[c] : frame_err_injected;
    assign link_tx_ts_eff[c]    = link_delay_en_i[c] ? dly_ts_q[c]    : pcs_tx_ts_wire[c];
    assign link_tx_crc8_eff[c]  = link_delay_en_i[c] ? dly_crc8_q[c]  : pcs_tx_crc8_wire[c];
    assign link_tx_dst_eff[c]   = link_delay_en_i[c] ? dly_dst_q[c]   : eff_routed_dst;

    // Feed PCS-deframed error-free flits into LPU Hop 0 NIM RealSync
    assign lpu_rx_valid[c] = pcs_rx_flit_valid[c];
    assign lpu_rx_data[c]  = pcs_rx_flit_data[c];
    assign lpu_rx_dst[c]   = pcs_rx_dst_chip[c];
    assign lpu_rx_ts[c]    = pcs_rx_ts_wire[c];
    assign lpu_rx_crc8[c]  = pcs_rx_crc8_wire[c];

    // Per-Chip Telemetry
    assign chip_all_slices_halted[c]  = &chip_slice_halted_o[c];
    assign chip_any_slice_barrier[c]  = |bwait_obs;
    assign cluster_realsync_err_o[c]  = drift_flt | c2c_crc8_err | pcs_rx_sync_err;
    assign cluster_ecc_single_err_o[c]= |ecc_s_err;
    assign cluster_ecc_double_err_o[c]= |ecc_d_err;
    assign cluster_c2c_tx_valid_o[c]  = lpu_tx_valid[c];
    assign cluster_routed_dst_o[c]    = routed_dst_chip[c];
    assign cluster_nim_rx_data_o[c]   = lpu_rx_data[c];
  end

  assign cluster_all_halted_o  = &chip_all_slices_halted;
  assign cluster_any_barrier_o = |chip_any_slice_barrier;

  // ---------------------------------------------------------------------------
  // 5. 8x8 Dragonfly Switch Matrix (Forward Data Frame + Reverse NACK Routing)
  // ---------------------------------------------------------------------------
  logic [2:0] last_src_for_dst_q [0:P_NUM_CHIPS-1];
  logic [2:0] active_src_for_dst [0:P_NUM_CHIPS-1];

  always_comb begin
    for (int d = 0; d < P_NUM_CHIPS; d++) begin
      pcs_phy_rx_valid[d]   = 1'b0;
      pcs_phy_rx_frame[d]   = '0;
      pcs_rx_ts_wire[d]     = '0;
      pcs_rx_crc8_wire[d]   = '0;
      active_src_for_dst[d] = 3'(d) ^ 3'd1;

      for (int s = 0; s < P_NUM_CHIPS; s++) begin
        if (!pcs_phy_rx_valid[d] && link_tx_valid_eff[s] && (link_tx_dst_eff[s] == 3'(d))) begin
          pcs_phy_rx_valid[d]   = 1'b1;
          pcs_phy_rx_frame[d]   = {
            link_tx_frame_eff[s][P_PCS_FRAME_W-1 : P_STREAM_WIDTH],
            cluster_apply_scram(
              link_tx_frame_eff[s][P_STREAM_WIDTH-1:0],
              chip_rx_lfsr_q[d],
              pcs_scramble_en_i && (link_tx_frame_eff[s][P_PCS_FRAME_W-1 -: 2] == 2'b01)
            )
          };
          pcs_rx_ts_wire[d]     = link_tx_ts_eff[s];
          pcs_rx_crc8_wire[d]   = link_tx_crc8_eff[s];
          active_src_for_dst[d] = 3'(s);
        end
      end
    end

  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pcs_nack_in     <= '0;
      pcs_nack_seq_in <= '0;
      for (int d = 0; d < P_NUM_CHIPS; d++) begin
        last_src_for_dst_q[d] <= 3'(d) ^ 3'd1;
      end
    end else begin
      for (int d = 0; d < P_NUM_CHIPS; d++) begin
        if (pcs_phy_rx_valid[d]) begin
          last_src_for_dst_q[d] <= active_src_for_dst[d];
        end
      end
      for (int s = 0; s < P_NUM_CHIPS; s++) begin
        pcs_nack_in[s]     <= 1'b0;
        pcs_nack_seq_in[s] <= 2'd0;
        for (int d = 0; d < P_NUM_CHIPS; d++) begin
          if (pcs_nack_out[d] && (active_src_for_dst[d] == 3'(s) || last_src_for_dst_q[d] == 3'(s))) begin
            pcs_nack_in[s]     <= 1'b1;
            pcs_nack_seq_in[s] <= pcs_nack_seq_out[d];
          end
        end
      end
    end
  end

`ifdef FORMAL
  always_comb begin
    for (int i = 0; i < P_NUM_CHIPS; i++) begin
      // 1. Butterfly XOR Involution: dst(dst(i)) == i
      assert (calc_dragonfly_dst(
        calc_dragonfly_dst(3'(i), 3'd0, ROUTE_MOE_ALLTOALL_BUTTERFLY, 1'b0, 1'b0, butterfly_stage_i),
        3'd0, ROUTE_MOE_ALLTOALL_BUTTERFLY, 1'b0, 1'b0, butterfly_stage_i
      ) == 3'(i));
      // 2. UGAL Adaptive minimal vs Valiant non-minimal (i ^ 4) selection
      if (congestion_mask_i[i] && (3'(i) != lpu_tx_dst[i][2:0])) begin
        assert (calc_dragonfly_dst(3'(i), lpu_tx_dst[i][2:0], ROUTE_UGAL_ADAPTIVE, 1'b0, 1'b1, 3'd0) == (3'(i) ^ 3'd4));
      end else begin
        assert (calc_dragonfly_dst(3'(i), lpu_tx_dst[i][2:0], ROUTE_UGAL_ADAPTIVE, 1'b0, congestion_mask_i[i], 3'd0) == lpu_tx_dst[i][2:0]);
      end
      // 3. PCS CRC-16 Error Containment: corrupted frame never asserts lpu_rx_valid
      if (cluster_crc16_err_o[i]) begin
        assert (lpu_rx_valid[i] == 1'b0);
      end
      for (int j = i + 1; j < P_NUM_CHIPS; j++) begin
        // 4. Bidirectional Ring Bijectivity (zero contention across all 8 chips)
        assert (calc_dragonfly_dst(3'(i), 3'd0, ROUTE_BIDIR_RING, ring_dir_west_i, 1'b0, 3'd0) !=
                calc_dragonfly_dst(3'(j), 3'd0, ROUTE_BIDIR_RING, ring_dir_west_i, 1'b0, 3'd0));
        // 5. MoE AllToAll Butterfly Bijectivity (zero contention across all 8 chips)
        assert (calc_dragonfly_dst(3'(i), 3'd0, ROUTE_MOE_ALLTOALL_BUTTERFLY, 1'b0, 1'b0, butterfly_stage_i) !=
                calc_dragonfly_dst(3'(j), 3'd0, ROUTE_MOE_ALLTOALL_BUTTERFLY, 1'b0, 1'b0, butterfly_stage_i));
      end
    end
    // 6. Cluster Host DMA VLIW Admission Safety across all 8 chips
    if (dma_vliw_sram_busy_i) begin
      assert (chip_dma_w_wr_en == '0);
      assert (chip_dma_e_wr_en == '0);
    end
  end
`endif

endmodule : groq_dragonfly_8chip_cluster

`endif // GROQ_DRAGONFLY_8CHIP_CLUSTER_SV
