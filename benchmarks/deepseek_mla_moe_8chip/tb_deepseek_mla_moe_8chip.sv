// =============================================================================
// File: benchmarks/deepseek_mla_moe_8chip/tb_deepseek_mla_moe_8chip.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 16 Verilator 5.054 Cycle-Accurate 8-Chip Dragonfly RTL
//              Benchmark for 4-Token Autoregressive Decode of DeepSeek-V3/R1
//              Multi-Head Latent Attention (MLA) + Routed Mixture-of-Experts (MoE).
//              Simultaneously injects:
//                1) Live single-bit SRAM SECDED ECC upsets across all 8 chips, AND
//                2) Live C2C PCS CRC-16 link bit-flips during MoE Butterfly AllToAll
//                   and Bidirectional Ring AllReduce (verifying 100% transparent
//                   Go-Back-N hardware replay + RealSync elastic deskew).
// =============================================================================
`timescale 1ns/1ps
/* verilator lint_off WIDTHCONCAT */
/* verilator lint_off UNUSEDSIGNAL */

`include "groq_pkg.sv"

module tb_deepseek_mla_moe_8chip (
  input logic clk,
  input logic rst_n
);
  import groq_pkg::*;

  localparam int P_NUM_CHIPS    = 8;
  localparam int P_NUM_SLICES   = NUM_SLICES;
  localparam int P_NUM_TOKENS   = 4;
  localparam int P_TOKEN_STRIDE = 300;
  localparam int MAX_IMEM_PC    = P_NUM_TOKENS * P_TOKEN_STRIDE + 20; // 1220

  localparam logic [2:0] MODE_NVFP4_E2M1 = 3'd3;
  localparam logic [2:0] MODE_W4A8_MIXED = 3'd4;

  // Global cycle counter
  logic [15:0] global_cycle_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) global_cycle_q <= 16'd0;
    else        global_cycle_q <= global_cycle_q + 16'd1;
  end

  // Per-Chip Instruction Memory ROMs (8 chips x 8 slices x 1220 PCs)
  logic [143:0] chip_imem_rom [0:P_NUM_CHIPS-1][0:P_NUM_SLICES-1][0:MAX_IMEM_PC-1];
  logic [P_NUM_CHIPS-1:0]                                    chip_icu_en_q;
  logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0][143:0]           chip_vliw_bundle;
  logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0][15:0]            chip_pc_slice;
  logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0]                  chip_halted;

  always_comb begin
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      for (int s = 0; s < P_NUM_SLICES; s++) begin
        logic [15:0] eff_pc;
        eff_pc = (chip_pc_slice[c][s] < 16'(MAX_IMEM_PC)) ? chip_pc_slice[c][s] : 16'(MAX_IMEM_PC - 1);
        chip_vliw_bundle[c][s] = chip_imem_rom[c][s][eff_pc];
      end
    end
  end

  // Cluster DMA Signals
  logic [2:0]   dma_target_chip;
  logic         dma_bcast_all;
  logic         dma_vliw_busy;
  logic         dma_desc_valid, dma_desc_ready;
  logic [127:0] dma_desc_data;
  logic         dma_pay_valid,  dma_pay_ready;
  logic [127:0] dma_pay_data;
  logic [15:0]  dma_pay_parity;
  logic         dma_busy, dma_stall, dma_perr, dma_irq;
  logic [7:0]   dma_desc_cnt;
  logic [15:0]  dma_beats_cnt;

  // Dragonfly Routing & PCS Control Signals
  logic [1:0]             cluster_route_mode;
  logic                   ring_dir_west;
  logic [P_NUM_CHIPS-1:0] congestion_mask;
  logic [2:0]             butterfly_stage;
  logic                   pcs_link_en, pcs_scram_en;
  logic                   pcs_ts1, pcs_ts2, pcs_dsk_done, pcs_retrain;
  logic [P_NUM_CHIPS-1:0] link_delay_en;
  logic [15:0]            expected_flight;
  logic [P_NUM_CHIPS-1:0] pcs_err_inj_en;
  logic [15:0]            pcs_err_inj_mask;

  // Cluster Status & Telemetry Outputs
  logic                   cluster_all_halted, cluster_any_barrier;
  logic [P_NUM_CHIPS-1:0] cluster_pcs_link_up, cluster_crc16_err, cluster_realsync_err;
  logic [P_NUM_CHIPS-1:0] cluster_ecc_s_err, cluster_ecc_d_err;
  logic [P_NUM_CHIPS-1:0] cluster_c2c_tx_valid, cluster_deskew_release;
  logic [P_NUM_CHIPS-1:0][2:0]   cluster_routed_dst;
  logic [P_NUM_CHIPS-1:0][127:0] cluster_nim_rx_data;


  // ---------------------------------------------------------------------------
  // 1. Dynamic Per-Token Dragonfly Topology & Live PCS CRC-16 Error Injection
  // ---------------------------------------------------------------------------
  logic [15:0] cur_pc0;
  int          cur_token_idx;
  int          cur_token_off;

  assign cur_pc0       = chip_pc_slice[0][SLICE_NIM];
  assign cur_token_idx = int'(cur_pc0) / P_TOKEN_STRIDE;
  assign cur_token_off = int'(cur_pc0) % P_TOKEN_STRIDE;

  always_comb begin
    cluster_route_mode = 2'b00; // ROUTE_DIRECT_CROSSBAR default
    ring_dir_west      = 1'b0;  // Eastward ring (c -> (c + 1) % 8)
    congestion_mask    = 8'h00;
    case (cur_token_idx)
      0:       butterfly_stage = 3'd1;
      1:       butterfly_stage = 3'd2;
      2:       butterfly_stage = 3'd4;
      default: butterfly_stage = 3'd3;
    endcase

    pcs_err_inj_en   = 8'h00;
    pcs_err_inj_mask = 16'h0000;

    if (chip_icu_en_q == 8'hFF && cur_token_idx < P_NUM_TOKENS) begin
      if (cur_token_off >= 180 && cur_token_off <= 195) begin
        // Stage C: MoE Butterfly AllToAll Dispatch across all 8 chips
        cluster_route_mode = 2'b11; // ROUTE_MOE_ALLTOALL_BUTTERFLY
        if (cur_token_off == 183) begin
          // Inject live C2C PCS CRC-16 2-bit link error on all 8 links during Butterfly TX!
          pcs_err_inj_en   = 8'hFF;
          pcs_err_inj_mask = 16'h0005;
        end
      end else if (cur_token_off >= 268 && cur_token_off <= 285) begin
        // Stage D: 8-Chip Bidirectional Ring In-Network AllReduce
        cluster_route_mode = 2'b01; // ROUTE_BIDIR_RING
        if (cur_token_off == 273) begin
          // Inject live C2C PCS CRC-16 2-bit link error on all 8 links during Ring TX!
          pcs_err_inj_en   = 8'hFF;
          pcs_err_inj_mask = 16'h0003;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 2. Primary 8-Chip Dragonfly Group Scale-Out Cluster Under Test
  // ---------------------------------------------------------------------------
  groq_dragonfly_8chip_cluster u_cluster (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .chip_icu_enable_i        (chip_icu_en_q),
    .chip_imem_vliw_bundle_i  (chip_vliw_bundle),
    .chip_pc_slice_o          (chip_pc_slice),
    .chip_slice_halted_o      (chip_halted),
    .global_cycle_i           (global_cycle_q),
    .dma_target_chip_i        (dma_target_chip),
    .dma_bcast_all_chips_i    (dma_bcast_all),
    .dma_vliw_sram_busy_i     (dma_vliw_busy),
    .dma_desc_push_valid_i    (dma_desc_valid),
    .dma_desc_push_data_i     (dma_desc_data),
    .dma_desc_push_ready_o    (dma_desc_ready),
    .dma_payload_valid_i      (dma_pay_valid),
    .dma_payload_data_i       (dma_pay_data),
    .dma_payload_parity_i     (dma_pay_parity),
    .dma_payload_ready_o      (dma_pay_ready),
    .dma_busy_o               (dma_busy),
    .dma_window_stall_o       (dma_stall),
    .dma_parity_err_o         (dma_perr),
    .dma_done_irq_o           (dma_irq),
    .dma_completed_desc_cnt_o (dma_desc_cnt),
    .dma_beats_transferred_o  (dma_beats_cnt),
    .cluster_route_mode_i     (cluster_route_mode),
    .ring_dir_west_i          (ring_dir_west),
    .congestion_mask_i        (congestion_mask),
    .butterfly_stage_i        (butterfly_stage),
    .pcs_link_enable_i        (pcs_link_en),
    .pcs_scramble_en_i        (pcs_scram_en),
    .pcs_rx_ts1_seen_i        (pcs_ts1),
    .pcs_rx_ts2_seen_i        (pcs_ts2),
    .pcs_deskew_done_i        (pcs_dsk_done),
    .pcs_retrain_req_i        (pcs_retrain),
    .link_delay_en_i          (link_delay_en),
    .expected_flight_cycles_i (expected_flight),
    .pcs_err_inject_en_i      (pcs_err_inj_en),
    .pcs_err_inject_mask_i    (pcs_err_inj_mask),
    .cluster_all_halted_o     (cluster_all_halted),
    .cluster_any_barrier_o    (cluster_any_barrier),
    .cluster_pcs_link_up_o    (cluster_pcs_link_up),
    .cluster_crc16_err_o      (cluster_crc16_err),
    .cluster_realsync_err_o   (cluster_realsync_err),
    .cluster_ecc_single_err_o (cluster_ecc_s_err),
    .cluster_ecc_double_err_o (cluster_ecc_d_err),
    .cluster_c2c_tx_valid_o   (cluster_c2c_tx_valid),
    .cluster_deskew_release_o (cluster_deskew_release),
    .cluster_routed_dst_o     (cluster_routed_dst),
    .cluster_nim_rx_data_o    (cluster_nim_rx_data)
  );


  // ---------------------------------------------------------------------------
  // 3. 8 x Shadow LPU Instances with Live Single-Bit SRAM SECDED ECC Upsets
  //    & 8 x Companion groq_mxfp8_nvfp4_dot_engine Microscaling Co-Processors
  // ---------------------------------------------------------------------------
  logic [P_NUM_CHIPS-1:0][1:0]  ecc_dut_single_err, ecc_dut_double_err;
  logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0][15:0]        ecc_dut_east_val;
  logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0][15:0][127:0] ecc_dut_east_dat;
  logic [P_NUM_CHIPS-1:0][127:0] ecc_dut_mem_e_wr_data;
  logic [P_NUM_CHIPS-1:0][4:0]   ecc_dut_zsw, ecc_dut_zse;
  logic [P_NUM_CHIPS-1:0][15:0]  ecc_dut_gated_hops;

  logic [127:0] dot_wt_rom      [0:P_NUM_CHIPS-1][0:1];
  logic [127:0] latest_h_swiglu [0:P_NUM_CHIPS-1];

  logic [P_NUM_CHIPS-1:0]        dot_valid_in, dot_accum_en, dot_accum_clear;
  logic [2:0]                    dot_mode_in;
  logic [7:0]                    dot_act_scale, dot_wt_scale;
  logic [P_NUM_CHIPS-1:0][127:0] dot_wt_in;
  logic [P_NUM_CHIPS-1:0]        dot_valid_out, dot_bzero_out, dot_nan_out;
  logic [P_NUM_CHIPS-1:0][31:0]  dot_unaccum_out, dot_accum_out, dot_fp32_out;
  logic [P_NUM_CHIPS-1:0][5:0]   dot_zskip_out;

  for (genvar c = 0; c < P_NUM_CHIPS; c++) begin : gen_shadow_and_dot
    logic [P_NUM_SLICES-1:0]       sh_fetch, sh_vval, sh_halted, sh_bwait;
    logic [P_NUM_SLICES-1:0][15:0] sh_pc;
    logic [P_NUM_SLICES-1:0][143:0] sh_vbun;
    logic [P_NUM_SLICES-1:0][15:0] sh_wval;
    logic [P_NUM_SLICES-1:0][15:0][127:0] sh_wdat;
    logic [1:0]  sh_bconf, sh_tx_port;
    logic        sh_mg, sh_lg, sh_tx_val, sh_coll, sh_cstk, sh_brel, sh_drift, sh_dsk, sh_crc;
    logic [127:0] sh_tx_dat;
    logic [15:0] sh_tx_ts, sh_bcnt;
    logic [3:0]  sh_tx_dst;
    logic [7:0]  sh_tx_crc8;
    logic [63:0] sh_rtime;
    logic signed [15:0] sh_skew, sh_rsum;
    logic signed [7:0]  sh_rmax;

    groq_lpu_top u_ecc_shadow_lpu (
      .clk                      (clk),
      .rst_n                    (rst_n),
      .icu_enable_i             (chip_icu_en_q[c]),
      .imem_vliw_bundle_i       (chip_vliw_bundle[c]),
      .imem_fetch_en_o          (sh_fetch),
      .pc_slice_o               (sh_pc),
      .slice_vliw_valid_o       (sh_vval),
      .slice_vliw_bundle_o      (sh_vbun),
      .slice_halted_o           (sh_halted),
      .ext_east_inject_en_i     ('0),
      .ext_east_inject_data_i   ('0),
      .ext_west_inject_en_i     ('0),
      .ext_west_inject_data_i   ('0),
      .ext_overwrite_allow_i    (1'b0),
      .stream_valid_east_o      (ecc_dut_east_val[c]),
      .stream_data_east_o       (ecc_dut_east_dat[c]),
      .stream_valid_west_o      (sh_wval),
      .stream_data_west_o       (sh_wdat),
      .host_mem_w_wr_en_i       (u_cluster.chip_dma_w_wr_en[c]),
      .host_mem_w_bank_i        (u_cluster.dma_mem_w_bank),
      .host_mem_w_addr_i        (u_cluster.dma_mem_w_addr),
      .host_mem_w_data_i        (u_cluster.dma_mem_w_data),
      .host_mem_e_wr_en_i       (u_cluster.chip_dma_e_wr_en[c]),
      .host_mem_e_bank_i        (u_cluster.dma_mem_e_bank),
      .host_mem_e_addr_i        (u_cluster.dma_mem_e_addr),
      .host_mem_e_data_i        (u_cluster.dma_mem_e_data),
      .mem_err_inject_en_i      (chip_icu_en_q[c]),
      .mem_err_inject_mask_i    (144'h1 << (c * 7 + 3)),
      .local_chip_id_i          (4'(c)),
      .expected_flight_cycles_i (expected_flight),
      .realsync_ext_adj_en_i    (1'b0),
      .realsync_ext_adj_val_i   (16'sd0),
      .c2c_rx_valid_i           (u_cluster.lpu_rx_valid[c]),
      .c2c_rx_data_i            (u_cluster.lpu_rx_data[c]),
      .c2c_rx_tx_timestamp_i    (u_cluster.lpu_rx_ts[c]),
      .c2c_rx_dst_chip_i        (u_cluster.lpu_rx_dst[c]),
      .c2c_rx_crc8_i            (u_cluster.lpu_rx_crc8[c]),
      .c2c_tx_valid_o           (sh_tx_val),
      .c2c_tx_data_o            (sh_tx_dat),
      .c2c_tx_timestamp_o       (sh_tx_ts),
      .c2c_tx_dst_chip_o        (sh_tx_dst),
      .c2c_tx_crc8_o            (sh_tx_crc8),
      .c2c_tx_port_sel_o        (sh_tx_port),
      .collision_fault_o        (sh_coll),
      .collision_sticky_o       (sh_cstk),
      .barrier_waiting_o        (sh_bwait),
      .barrier_release_pulse_o  (sh_brel),
      .barrier_release_cnt_o    (sh_bcnt),
      .realsync_aligned_time_o  (sh_rtime),
      .realsync_drift_fault_o   (sh_drift),
      .deskew_release_valid_o   (sh_dsk),
      .measured_skew_o          (sh_skew),
      .c2c_crc_err_o            (sh_crc),
      .ecc_single_err_o         (ecc_dut_single_err[c]),
      .ecc_double_err_o         (ecc_dut_double_err[c]),
      .bank_conflict_err_o      (sh_bconf),
      .gated_hop_count_o        (ecc_dut_gated_hops[c]),
      .zero_skip_count_w_o      (ecc_dut_zsw[c]),
      .zero_skip_count_e_o      (ecc_dut_zse[c]),
      .mul_gate_active_o        (sh_mg),
      .lut_gate_active_o        (sh_lg),
      .vxm_reduce_sum_o         (sh_rsum),
      .vxm_reduce_max_o         (sh_rmax)
    );

    assign ecc_dut_mem_e_wr_data[c] = u_ecc_shadow_lpu.mem_e_wr_data;


    groq_mxfp8_nvfp4_dot_engine u_dot_engine (
      .clk                  (clk),
      .rst_n                (rst_n),
      .valid_i              (dot_valid_in[c]),
      .mode_i               (dot_mode_in),
      .zero_skip_en_i       (1'b1),
      .accum_en_i           (dot_accum_en[c]),
      .accum_clear_i        (dot_accum_clear[c]),
      .act_scale_e8m0_i     (dot_act_scale),
      .wt_scale_e8m0_i      (dot_wt_scale),
      .act_stream_i         (latest_h_swiglu[c]),
      .wt_stream_i          (dot_wt_in[c]),
      .valid_o              (dot_valid_out[c]),
      .unaccum_dot_o        (dot_unaccum_out[c]),
      .dot_accum_o          (dot_accum_out[c]),
      .dot_fp32_o           (dot_fp32_out[c]),
      .zero_skip_lanes_o    (dot_zskip_out[c]),
      .block_zero_skipped_o (dot_bzero_out[c]),
      .nan_inf_flag_o       (dot_nan_out[c])
    );
  end

  // Drive companion groq_mxfp8_nvfp4_dot_engine co-processors at Stage D off=265 (W4A8) & off=268 (NVFP4)
  always_comb begin
    dot_valid_in    = 8'h00;
    dot_accum_en    = 8'h00;
    dot_accum_clear = 8'h00;
    dot_mode_in     = MODE_W4A8_MIXED;
    dot_act_scale   = 8'd127;
    dot_wt_scale    = 8'd128;
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      dot_wt_in[c] = dot_wt_rom[c][0];
    end

    if (chip_icu_en_q == 8'hFF && cur_token_idx < P_NUM_TOKENS) begin
      if (cur_token_off == 265) begin
        dot_valid_in    = 8'hFF;
        dot_accum_en    = 8'hFF;
        dot_accum_clear = 8'hFF;
        dot_mode_in     = MODE_W4A8_MIXED;
        dot_act_scale   = 8'd127;
        dot_wt_scale    = 8'd128;
        for (int c = 0; c < P_NUM_CHIPS; c++) dot_wt_in[c] = dot_wt_rom[c][0];
      end else if (cur_token_off == 268) begin
        dot_valid_in    = 8'hFF;
        dot_accum_en    = 8'hFF;
        dot_accum_clear = 8'h00;
        dot_mode_in     = MODE_NVFP4_E2M1;
        dot_act_scale   = 8'd127;
        dot_wt_scale    = 8'd127;
        for (int c = 0; c < P_NUM_CHIPS; c++) dot_wt_in[c] = dot_wt_rom[c][1];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 4. Per-Token, Per-Chip Tensor Capture Arrays & Telemetry Counters
  // ---------------------------------------------------------------------------
  logic [127:0] cap_x_in        [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_x_norm      [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_q_rope      [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_c_kv_rope   [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_s_attn      [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_p_attn      [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_o_attn      [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_h_attn      [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_h_peer_rx   [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_e_in        [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_h_swiglu    [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_y_down      [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_y_ring1     [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_y_final     [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [127:0] cap_ecc_y_final [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];

  logic [31:0]  cap_w4a8_unacc  [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [31:0]  cap_w4a8_fp32   [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [7:0]   cap_w4a8_zskip  [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [31:0]  cap_nvfp4_unacc [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [31:0]  cap_nvfp4_acc   [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [31:0]  cap_nvfp4_fp32  [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];
  logic [7:0]   cap_nvfp4_zskip [0:P_NUM_TOKENS-1][0:P_NUM_CHIPS-1];

  int total_exec_cycles;
  int ecc_corrected_count;
  int ecc_double_err_count;
  int stream_mismatch_vs_ecc_dut;
  int pcs_crc16_injected_count;
  int pcs_nack_replay_count;
  int total_c2c_flits_tx;
  int total_deskew_releases;
  int total_zero_skip_lanes;


  // Extract internal per-chip signals via constant genvar indexing
  logic [P_NUM_CHIPS-1:0][127:0] chip_mem_w_wr_data;
  logic [P_NUM_CHIPS-1:0][127:0] chip_mem_e_wr_data;
  logic [P_NUM_CHIPS-1:0][127:0] chip_vxm_stream_a;
  logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0][15:0]        chip_east_val;
  logic [P_NUM_CHIPS-1:0][P_NUM_SLICES-1:0][15:0][127:0] chip_east_dat;
  logic [P_NUM_CHIPS-1:0]        chip_mxm_w_act_val;
  logic [P_NUM_CHIPS-1:0]        chip_mxm_e_act_val;

  for (genvar gc = 0; gc < P_NUM_CHIPS; gc++) begin : gen_obs_tap
    assign chip_mem_w_wr_data[gc] = u_cluster.gen_chip[gc].u_lpu.mem_w_wr_data;
    assign chip_mem_e_wr_data[gc] = u_cluster.gen_chip[gc].u_lpu.mem_e_wr_data;
    assign chip_vxm_stream_a[gc]  = u_cluster.gen_chip[gc].u_lpu.vxm_stream_a;
    assign chip_east_val[gc]      = u_cluster.gen_chip[gc].eval_unused;
    assign chip_east_dat[gc]      = u_cluster.gen_chip[gc].edat_unused;
    assign chip_mxm_w_act_val[gc] = u_cluster.gen_chip[gc].u_lpu.mxm_w_act_valid;
    assign chip_mxm_e_act_val[gc] = u_cluster.gen_chip[gc].u_lpu.mxm_e_act_valid;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      total_exec_cycles          <= 0;
      ecc_corrected_count        <= 0;
      ecc_double_err_count       <= 0;
      stream_mismatch_vs_ecc_dut <= 0;
      pcs_crc16_injected_count   <= 0;
      pcs_nack_replay_count      <= 0;
      total_c2c_flits_tx         <= 0;
      total_deskew_releases      <= 0;
      total_zero_skip_lanes      <= 0;
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        latest_h_swiglu[c] <= '0;
      end
    end else if (chip_icu_en_q == 8'hFF && !cluster_all_halted) begin
      int cyc_ecc_s, cyc_ecc_d, cyc_mism, cyc_zskip;
      cyc_ecc_s = 0;
      cyc_ecc_d = 0;
      cyc_mism  = 0;
      cyc_zskip = 0;
      total_exec_cycles <= total_exec_cycles + 1;

      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        if (|ecc_dut_single_err[c]) cyc_ecc_s++;
        if (|ecc_dut_double_err[c]) cyc_ecc_d++;
        if ((chip_east_val[c] != ecc_dut_east_val[c]) || (chip_east_dat[c] != ecc_dut_east_dat[c]))
          cyc_mism++;
        if (chip_mxm_w_act_val[c]) cyc_zskip += int'(ecc_dut_zsw[c]);
        if (chip_mxm_e_act_val[c]) cyc_zskip += int'(ecc_dut_zse[c]);
      end

      ecc_corrected_count        <= ecc_corrected_count        + cyc_ecc_s;
      ecc_double_err_count       <= ecc_double_err_count       + cyc_ecc_d;
      stream_mismatch_vs_ecc_dut <= stream_mismatch_vs_ecc_dut + cyc_mism;
      pcs_crc16_injected_count   <= pcs_crc16_injected_count   + $countones(cluster_crc16_err);
      pcs_nack_replay_count      <= pcs_nack_replay_count      + $countones(u_cluster.pcs_nack_in);
      total_c2c_flits_tx         <= total_c2c_flits_tx         + $countones(cluster_c2c_tx_valid);
      total_deskew_releases      <= total_deskew_releases      + $countones(cluster_deskew_release);
      total_zero_skip_lanes      <= total_zero_skip_lanes      + cyc_zskip;

      if (cur_token_idx < P_NUM_TOKENS) begin
        for (int c = 0; c < P_NUM_CHIPS; c++) begin
          if (cur_token_off == 4)   cap_x_in[cur_token_idx][c]      <= chip_vxm_stream_a[c];
          if (cur_token_off == 23)  cap_x_norm[cur_token_idx][c]    <= chip_mem_w_wr_data[c];
          if (cur_token_off == 86)  cap_q_rope[cur_token_idx][c]    <= chip_mem_w_wr_data[c];
          if (cur_token_off == 87)  cap_c_kv_rope[cur_token_idx][c] <= chip_mem_w_wr_data[c];
          if (cur_token_off == 125) cap_s_attn[cur_token_idx][c]    <= chip_mem_w_wr_data[c];
          if (cur_token_off == 148) cap_p_attn[cur_token_idx][c]    <= chip_mem_w_wr_data[c];
          if (cur_token_off == 180) cap_o_attn[cur_token_idx][c]    <= chip_mem_w_wr_data[c];
          if (cur_token_off == 181) cap_h_attn[cur_token_idx][c]    <= chip_mem_w_wr_data[c];
          if (cur_token_off == 193) cap_h_peer_rx[cur_token_idx][c] <= chip_mem_e_wr_data[c];
          if (cur_token_off == 200) cap_e_in[cur_token_idx][c]      <= chip_mem_w_wr_data[c];
          if (cur_token_off == 264) begin
            cap_h_swiglu[cur_token_idx][c] <= chip_mem_w_wr_data[c];
            latest_h_swiglu[c]             <= chip_mem_w_wr_data[c];
          end
          if (cur_token_off == 267) begin
            cap_w4a8_unacc[cur_token_idx][c] <= dot_unaccum_out[c];
            cap_w4a8_fp32[cur_token_idx][c]  <= dot_fp32_out[c];
            cap_w4a8_zskip[cur_token_idx][c] <= {2'b00, dot_zskip_out[c]};
          end
          if (cur_token_off == 270) begin
            cap_nvfp4_unacc[cur_token_idx][c] <= dot_unaccum_out[c];
            cap_nvfp4_acc[cur_token_idx][c]   <= dot_accum_out[c];
            cap_nvfp4_fp32[cur_token_idx][c]  <= dot_fp32_out[c];
            cap_nvfp4_zskip[cur_token_idx][c] <= {2'b00, dot_zskip_out[c]};
          end
          if (cur_token_off == 271) cap_y_down[cur_token_idx][c]    <= chip_mem_w_wr_data[c];
          if (cur_token_off == 283) cap_y_ring1[cur_token_idx][c]   <= chip_mem_e_wr_data[c];
          if (cur_token_off == 286) begin
            cap_y_final[cur_token_idx][c]     <= chip_mem_e_wr_data[c];
            cap_ecc_y_final[cur_token_idx][c] <= ecc_dut_mem_e_wr_data[c];
          end
        end
      end
    end
  end


  // ---------------------------------------------------------------------------
  // 5. Host DMA Preload Tasks & Execution Sequencer
  // ---------------------------------------------------------------------------
  function automatic logic [15:0] calc_parity16(input logic [127:0] d);
    logic [15:0] p;
    for (int i = 0; i < 16; i++) p[i] = ^d[i*8 +: 8];
    return p;
  endfunction

  task automatic dma_write_word(
    input logic         bcast,
    input logic [2:0]   tgt_chip,
    input logic [1:0]   dma_tgt,
    input logic [2:0]   slice_or_bank,
    input logic [15:0]  base_addr,
    input logic [127:0] payload
  );
    @(negedge clk);
    dma_bcast_all   = bcast;
    dma_target_chip = tgt_chip;
    dma_desc_valid  = 1'b1;
    dma_desc_data   = {56'd0, 16'd0, 16'd0, 8'd1, 8'd1, base_addr, 3'd0, slice_or_bank, dma_tgt};
    @(posedge clk);
    @(negedge clk);
    dma_desc_valid  = 1'b0;
    @(posedge clk);
    @(negedge clk);
    dma_pay_valid   = 1'b1;
    dma_pay_data    = payload;
    dma_pay_parity  = calc_parity16(payload);
    @(posedge clk);
    @(negedge clk);
    dma_pay_valid   = 1'b0;
    @(posedge clk);
  endtask

  initial begin
    int fd, gfd, log_fd, json_fd, r;
    int b_id, addr, gt, gc;
    logic [127:0] d_word;
    logic [127:0] gx_in, gx_norm, gq_rope, gc_kv, gs_attn, gp_attn, go_attn;
    logic [127:0] gh_attn, gh_peer, ge_in, gh_swi, gy_down, gy_ring1, gy_final;
    logic [31:0]  gw4_unacc, gw4_fp32, gnv_unacc, gnv_acc, gnv_fp32;
    logic [7:0]   gw4_zs, gnv_zs;
    int total_bit_errors;
    int total_tensor_checks;

    chip_icu_en_q   = 8'h00;
    dma_target_chip = 3'd0;
    dma_bcast_all   = 1'b0;
    dma_vliw_busy   = 1'b0;
    dma_desc_valid  = 1'b0;
    dma_desc_data   = '0;
    dma_pay_valid   = 1'b0;
    dma_pay_data    = '0;
    dma_pay_parity  = '0;
    pcs_link_en     = 1'b0;
    pcs_scram_en    = 1'b0;
    pcs_ts1         = 1'b0;
    pcs_ts2         = 1'b0;
    pcs_dsk_done    = 1'b0;
    pcs_retrain     = 1'b0;
    link_delay_en   = 8'h00;
    expected_flight = 16'd3;

    // Load VLIW Instruction ROMs & Dot Engine Weight ROMs for all 8 Chips
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      $readmemh($sformatf("vectors/chip%0d_dot_weights.hex", c), dot_wt_rom[c]);
      for (int s = 0; s < P_NUM_SLICES; s++) begin
        $readmemh($sformatf("vectors/chip%0d_imem_s%0d.hex", c, s), chip_imem_rom[c][s]);
      end
    end

    @(posedge rst_n);
    repeat (2) @(posedge clk);

    // Preload West SRAM Banks across all 8 Chips via Cluster Host DMA Controller
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      fd = $fopen($sformatf("vectors/chip%0d_sram_preload.txt", c), "r");
      if (fd == 0) begin
        $display("FATAL: Could not open vectors/chip%0d_sram_preload.txt", c);
        $finish(1);
      end
      while (!$feof(fd)) begin
        r = $fscanf(fd, "%d %d %h\n", b_id, addr, d_word);
        if (r == 3) begin
          dma_write_word(1'b0, 3'(c), 2'b01, 3'(b_id), 16'(addr), d_word);
        end
      end
      $fclose(fd);
    end


    // Train all 8 C2C 64B/66B SerDes PCS Links to LINK_ACTIVE (8'hFF)
    @(negedge clk); pcs_link_en  = 1'b1; @(posedge clk);
    @(negedge clk); pcs_ts1      = 1'b1; @(posedge clk);
    @(negedge clk); pcs_ts2      = 1'b1; @(posedge clk);
    @(negedge clk); pcs_dsk_done = 1'b1; @(posedge clk);
    @(posedge clk);

    if (cluster_pcs_link_up !== 8'hFF || dma_perr !== 1'b0) begin
      $display("FATAL: PCS Link Training or DMA Parity Failed: link_up=%b dma_perr=%b",
               cluster_pcs_link_up, dma_perr);
      $finish(1);
    end

    // Launch all 8 LPU Chips in Lockstep across all 4 Autoregressive Tokens
    @(negedge clk);
    chip_icu_en_q = 8'hFF;

    wait (cluster_all_halted == 1'b1);
    repeat (4) @(posedge clk);

    // Compare Captured RTL Tensors vs Python Golden Reference across 4 Tokens x 8 Chips
    total_bit_errors    = 0;
    total_tensor_checks = 0;
    log_fd = $fopen("deepseek_mla_moe_8chip.log", "w");
    gfd    = $fopen("vectors/golden_tokens_8chip.txt", "r");
    if (gfd == 0 || log_fd == 0) begin
      $display("FATAL: Could not open golden_tokens_8chip.txt or log file");
      $finish(1);
    end

    $fdisplay(log_fd, "================================================================================");
    $fdisplay(log_fd, " STAGE 16: 8-CHIP DRAGONFLY DEEPSEEK-V3/R1 MLA + ROUTED MOE 4-TOKEN RTL LOG");
    $fdisplay(log_fd, "================================================================================");

    while (!$feof(gfd)) begin
      r = $fscanf(gfd, "%d %d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                  gt, gc, gx_in, gx_norm, gq_rope, gc_kv, gs_attn, gp_attn, go_attn,
                  gh_attn, gh_peer, ge_in, gh_swi, gy_down, gy_ring1, gy_final,
                  gw4_unacc, gw4_fp32, gw4_zs, gnv_unacc, gnv_acc, gnv_fp32, gnv_zs);
      if (r == 23) begin
        int pair_errs;
        pair_errs = 0;
        pair_errs += $countones(cap_x_in[gt][gc]        ^ gx_in);
        pair_errs += $countones(cap_x_norm[gt][gc]      ^ gx_norm);
        pair_errs += $countones(cap_q_rope[gt][gc]      ^ gq_rope);
        pair_errs += $countones(cap_c_kv_rope[gt][gc]   ^ gc_kv);
        pair_errs += $countones(cap_s_attn[gt][gc]      ^ gs_attn);
        pair_errs += $countones(cap_p_attn[gt][gc]      ^ gp_attn);
        pair_errs += $countones(cap_o_attn[gt][gc]      ^ go_attn);
        pair_errs += $countones(cap_h_attn[gt][gc]      ^ gh_attn);
        pair_errs += $countones(cap_h_peer_rx[gt][gc]   ^ gh_peer);
        pair_errs += $countones(cap_e_in[gt][gc]        ^ ge_in);
        pair_errs += $countones(cap_h_swiglu[gt][gc]    ^ gh_swi);
        pair_errs += $countones(cap_y_down[gt][gc]      ^ gy_down);
        pair_errs += $countones(cap_y_ring1[gt][gc]     ^ gy_ring1);
        pair_errs += $countones(cap_y_final[gt][gc]     ^ gy_final);
        pair_errs += $countones(cap_ecc_y_final[gt][gc] ^ gy_final);
        pair_errs += $countones(cap_w4a8_unacc[gt][gc]  ^ gw4_unacc);
        pair_errs += $countones(cap_w4a8_fp32[gt][gc]   ^ gw4_fp32);
        pair_errs += $countones(cap_w4a8_zskip[gt][gc]  ^ gw4_zs);
        pair_errs += $countones(cap_nvfp4_unacc[gt][gc] ^ gnv_unacc);
        pair_errs += $countones(cap_nvfp4_acc[gt][gc]   ^ gnv_acc);
        pair_errs += $countones(cap_nvfp4_fp32[gt][gc]  ^ gnv_fp32);
        pair_errs += $countones(cap_nvfp4_zskip[gt][gc] ^ gnv_zs);

        total_bit_errors    += pair_errs;
        total_tensor_checks += 22;

        $fdisplay(log_fd,
          "[TOKEN %0d | CHIP %0d | seq_len=%0d] x_in=%h -> c_kv=%h -> h_peer=%h -> y_final=%h | W4A8_FP32=%h NVFP4_FP32=%h | bit_errs=%0d",
          gt, gc, gt + 1, cap_x_in[gt][gc], cap_c_kv_rope[gt][gc], cap_h_peer_rx[gt][gc],
          cap_y_final[gt][gc], cap_w4a8_fp32[gt][gc], cap_nvfp4_fp32[gt][gc], pair_errs);
        if (pair_errs != 0) begin
          $display("MISMATCH Token %0d Chip %0d: pair_errs=%0d", gt, gc, pair_errs);
          $display("  x_in   : rtl=%h exp=%h", cap_x_in[gt][gc], gx_in);
          $display("  c_kv   : rtl=%h exp=%h", cap_c_kv_rope[gt][gc], gc_kv);
          $display("  s_attn : rtl=%h exp=%h", cap_s_attn[gt][gc], gs_attn);
          $display("  o_attn : rtl=%h exp=%h", cap_o_attn[gt][gc], go_attn);
          $display("  h_attn : rtl=%h exp=%h", cap_h_attn[gt][gc], gh_attn);
          $display("  h_peer : rtl=%h exp=%h", cap_h_peer_rx[gt][gc], gh_peer);
          $display("  e_in   : rtl=%h exp=%h", cap_e_in[gt][gc], ge_in);
          $display("  h_swi  : rtl=%h exp=%h", cap_h_swiglu[gt][gc], gh_swi);
          $display("  y_down : rtl=%h exp=%h", cap_y_down[gt][gc], gy_down);
          $display("  y_ring1: rtl=%h exp=%h", cap_y_ring1[gt][gc], gy_ring1);
          $display("  y_final: rtl=%h exp=%h", cap_y_final[gt][gc], gy_final);
          $display("  w4a8   : rtl=%h/%h/%h exp=%h/%h/%h", cap_w4a8_unacc[gt][gc], cap_w4a8_fp32[gt][gc], cap_w4a8_zskip[gt][gc], gw4_unacc, gw4_fp32, gw4_zs);
          $display("  nvfp4  : rtl=%h/%h/%h/%h exp=%h/%h/%h/%h", cap_nvfp4_unacc[gt][gc], cap_nvfp4_acc[gt][gc], cap_nvfp4_fp32[gt][gc], cap_nvfp4_zskip[gt][gc], gnv_unacc, gnv_acc, gnv_fp32, gnv_zs);
        end
      end
    end
    $fclose(gfd);

    $fdisplay(log_fd, "--------------------------------------------------------------------------------");
    $fdisplay(log_fd, "Total Execution Cycles            : %0d", total_exec_cycles);
    $fdisplay(log_fd, "Total Tensor & Co-Proc Checks     : %0d (32 token-chip pairs x 22 checks)", total_tensor_checks);
    $fdisplay(log_fd, "Total Bit Errors                  : %0d", total_bit_errors);
    $fdisplay(log_fd, "Live SRAM SECDED 1-Bit Corrected  : %0d", ecc_corrected_count);
    $fdisplay(log_fd, "Live SRAM SECDED 2-Bit Uncorr     : %0d", ecc_double_err_count);
    $fdisplay(log_fd, "ECC Shadow vs Primary Mismatches  : %0d", stream_mismatch_vs_ecc_dut);
    $fdisplay(log_fd, "Live PCS CRC-16 Errors Injected   : %0d", pcs_crc16_injected_count);
    $fdisplay(log_fd, "Live PCS Go-Back-N Replays        : %0d", pcs_nack_replay_count);
    $fdisplay(log_fd, "Total C2C Flits Transmitted       : %0d", total_c2c_flits_tx);
    $fdisplay(log_fd, "Total RealSync Deskew Releases    : %0d", total_deskew_releases);
    $fdisplay(log_fd, "Total MXM Zero-Skip Lanes         : %0d", total_zero_skip_lanes);
    $fdisplay(log_fd, "Cluster RealSync/CRC8 Faults      : %0b", cluster_realsync_err);
    $fdisplay(log_fd, "OVERALL VERIFICATION STATUS       : %s",
              (total_bit_errors == 0 && ecc_double_err_count == 0 && stream_mismatch_vs_ecc_dut == 0 &&
               ecc_corrected_count > 0 && pcs_crc16_injected_count == 64 && pcs_nack_replay_count == 64 &&
               cluster_realsync_err == 8'h00) ? "PASS (100% BIT-EXACT)" : "FAIL");
    $fdisplay(log_fd, "================================================================================");
    $fclose(log_fd);

    json_fd = $fopen("rtl_execution_trace.json", "w");
    $fdisplay(json_fd, "{");
    $fdisplay(json_fd, "  \"total_exec_cycles\": %0d,", total_exec_cycles);
    $fdisplay(json_fd, "  \"total_tensor_checks\": %0d,", total_tensor_checks);
    $fdisplay(json_fd, "  \"total_bit_errors\": %0d,", total_bit_errors);
    $fdisplay(json_fd, "  \"ecc_corrected_count\": %0d,", ecc_corrected_count);
    $fdisplay(json_fd, "  \"ecc_double_err_count\": %0d,", ecc_double_err_count);
    $fdisplay(json_fd, "  \"stream_mismatch_vs_ecc_dut\": %0d,", stream_mismatch_vs_ecc_dut);
    $fdisplay(json_fd, "  \"pcs_crc16_injected_count\": %0d,", pcs_crc16_injected_count);
    $fdisplay(json_fd, "  \"pcs_nack_replay_count\": %0d,", pcs_nack_replay_count);
    $fdisplay(json_fd, "  \"total_c2c_flits_tx\": %0d,", total_c2c_flits_tx);
    $fdisplay(json_fd, "  \"total_deskew_releases\": %0d,", total_deskew_releases);
    $fdisplay(json_fd, "  \"total_zero_skip_lanes\": %0d,", total_zero_skip_lanes);
    $fdisplay(json_fd, "  \"dma_beats_transferred\": %0d", dma_beats_cnt);
    $fdisplay(json_fd, "}");
    $fclose(json_fd);

    $display("[STAGE 16 RTL] Completed 4-Token 8-Chip MLA+MoE Run: cycles=%0d checks=%0d bit_errors=%0d ecc_corr=%0d pcs_crc16_inj=%0d pcs_replays=%0d",
             total_exec_cycles, total_tensor_checks, total_bit_errors, ecc_corrected_count,
             pcs_crc16_injected_count, pcs_nack_replay_count);
    if (total_bit_errors != 0 || stream_mismatch_vs_ecc_dut != 0 || ecc_double_err_count != 0) begin
      $finish(1);
    end
    $finish(0);
  end

endmodule
