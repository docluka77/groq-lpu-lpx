// =============================================================================
// File: formal/tb_stage29_500k_soak.sv
// Description: Stage 29 500,000-Cycle 9-Subsystem Ultra-Endurance Soak Test
//              Simulation (Verilator 5.054). Simultaneously stresses all 9
//              Subsystems across 500,000 consecutive clock cycles (4,500,000+
//              cycle-by-cycle golden invariant checks):
//              1) groq_spec_decode_tree_sampler (Bitonic 16, Top-K/P, 8-Node Tree)
//              2) groq_power_droop_controller (Mitigated vs. Unmitigated RLC/di/dt)
//              3) groq_sram_controller_scrubber (SER upsets, eFuse, 0-stall scrub)
//              4) groq_mxfp8_nvfp4_dot_engine (MXFP8/NVFP4/W4A8 + zero-skip)
//              5) groq_c2c_serdes_pcs (TX/RX loopback, CRC-16 + GBN replay)
//              6) groq_c2c_kv_quant_rx_engine (BF16/FP16->MXFP8/NVFP4 + closed-loop)
//              7) groq_mxm_slice (16x16 Systolic MAC + FP16 zero-skip gating)
//              8) groq_sxm_slice (16x16 Matrix Transpose + Butterfly RoPE)
//              9) groq_vxm_slice (16-Lane Vector ALU + Tree Reduction Sum/Max)
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"

module tb_stage29_500k_soak;
  import groq_pkg::*;

  localparam int TOTAL_CYCLES = 500000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #0.5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // 1. Speculative Decoding Tree & Top-K/Top-P Nucleus Sampler Instance
  // ---------------------------------------------------------------------------
  logic         sd_valid_i, sd_rng_step_i, sd_valid_o;
  logic [1:0]   sd_op_mode_i;
  logic [127:0] sd_logits_i, sd_token_ids_i, sd_sorted_logits_o, sd_sorted_tokens_o;
  logic [3:0]   sd_top_k_i;
  logic [7:0]   sd_inv_temp_i, sd_rng_thresh_i, sd_bonus_tok_i;
  logic [15:0]  sd_top_p_i, sd_nucleus_mask_o;
  logic [23:0]  sd_tree_parent_i;
  logic [63:0]  sd_tree_dprob_i, sd_tree_tprob_i, sd_tree_rand_i, sd_tree_dtok_i;
  logic [7:0]   sd_sel_tok_o, sd_sel_logit_o, sd_acc_mask_o;
  logic [2:0]   sd_best_leaf_o, sd_acc_len_o, sd_emit_cnt_o, sd_kv_adv_o;
  logic [39:0]  sd_commit_toks_o;
  logic [31:0]  sd_prng_o;

  groq_spec_decode_tree_sampler u_spec_decode (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .valid_i                (sd_valid_i),
    .op_mode_i              (sd_op_mode_i),
    .logits_i               (sd_logits_i),
    .token_ids_i            (sd_token_ids_i),
    .top_k_i                (sd_top_k_i),
    .inv_temp_i             (sd_inv_temp_i),
    .top_p_thresh_i         (sd_top_p_i),
    .rng_seed_step_i        (sd_rng_step_i),
    .rng_threshold_i        (sd_rng_thresh_i),
    .tree_parent_idx_i      (sd_tree_parent_i),
    .tree_draft_prob_i      (sd_tree_dprob_i),
    .tree_target_prob_i     (sd_tree_tprob_i),
    .tree_rand_u_i          (sd_tree_rand_i),
    .tree_draft_tok_i       (sd_tree_dtok_i),
    .bonus_tok_i            (sd_bonus_tok_i),
    .valid_o                (sd_valid_o),
    .selected_token_o       (sd_sel_tok_o),
    .selected_logit_o       (sd_sel_logit_o),
    .sorted_logits_o        (sd_sorted_logits_o),
    .sorted_tokens_o        (sd_sorted_tokens_o),
    .nucleus_mask_o         (sd_nucleus_mask_o),
    .accepted_node_mask_o   (sd_acc_mask_o),
    .best_leaf_idx_o        (sd_best_leaf_o),
    .accepted_draft_len_o   (sd_acc_len_o),
    .total_emitted_tokens_o (sd_emit_cnt_o),
    .committed_tokens_o     (sd_commit_toks_o),
    .kv_ring_advance_o      (sd_kv_adv_o),
    .prng_state_o           (sd_prng_o)
  );

  // ---------------------------------------------------------------------------
  // 2. Power Droop Controller (Mitigated vs. Shadow Unmitigated Baseline)
  // ---------------------------------------------------------------------------
  logic              pdc_prewarm_i;
  logic [7:0]        pdc_slice_act_i, pdc_prewarm_lvl_i, pdc_max_step_i;
  logic [5:0]        pdc_zskip_i;
  logic [7:0]        pdc_raw_o, pdc_eff_o, pdc_bleed_o, pdc_bmask_o, pdc_temp_o;
  logic signed [8:0] pdc_didt_o;
  logic [11:0]       pdc_vdd_o;
  logic              pdc_emerg_o;
  logic [15:0]       pdc_events_o;

  logic [7:0]        unmit_raw_o, unmit_eff_o, unmit_bleed_o, unmit_bmask_o, unmit_temp_o;
  logic signed [8:0] unmit_didt_o;
  logic [11:0]       unmit_vdd_o;
  logic              unmit_emerg_o;
  logic [15:0]       unmit_events_o;

  groq_power_droop_controller u_droop_mitigated (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .enable_i                 (1'b1),
    .slice_active_i           (pdc_slice_act_i),
    .mxm_zero_skip_cnt_i      (pdc_zskip_i),
    .prewarm_hint_i           (pdc_prewarm_i),
    .prewarm_target_level_i   (pdc_prewarm_lvl_i),
    .max_didt_step_i          (pdc_max_step_i),
    .vdd_nominal_mv_i         (12'd750),
    .droop_emerg_thresh_mv_i  (12'd620),
    .raw_demand_o             (pdc_raw_o),
    .eff_current_o            (pdc_eff_o),
    .dummy_bleed_current_o    (pdc_bleed_o),
    .dummy_bleed_mask_o       (pdc_bmask_o),
    .didt_signed_o            (pdc_didt_o),
    .vdd_est_mv_o             (pdc_vdd_o),
    .thermal_temp_c_o         (pdc_temp_o),
    .emerg_throttle_o         (pdc_emerg_o),
    .droop_mitigated_events_o (pdc_events_o)
  );

  groq_power_droop_controller u_droop_unmitigated (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .enable_i                 (1'b0),
    .slice_active_i           (pdc_slice_act_i),
    .mxm_zero_skip_cnt_i      (pdc_zskip_i),
    .prewarm_hint_i           (pdc_prewarm_i),
    .prewarm_target_level_i   (pdc_prewarm_lvl_i),
    .max_didt_step_i          (pdc_max_step_i),
    .vdd_nominal_mv_i         (12'd750),
    .droop_emerg_thresh_mv_i  (12'd620),
    .raw_demand_o             (unmit_raw_o),
    .eff_current_o            (unmit_eff_o),
    .dummy_bleed_current_o    (unmit_bleed_o),
    .dummy_bleed_mask_o       (unmit_bmask_o),
    .didt_signed_o            (unmit_didt_o),
    .vdd_est_mv_o             (unmit_vdd_o),
    .thermal_temp_c_o         (unmit_temp_o),
    .emerg_throttle_o         (unmit_emerg_o),
    .droop_mitigated_events_o (unmit_events_o)
  );

  // ---------------------------------------------------------------------------
  // 3. Multi-Bank SRAM Controller with Background Dual-SECDED Scrubber & eFuse
  // ---------------------------------------------------------------------------
  logic         sc_efuse_req_i, sc_efuse_ack_o;
  logic [1:0]   sc_efuse_bank_i, sc_vliw_rd_bank_i, sc_vliw_wr_bank_i, sc_dma_wr_bank_i;
  logic [5:0]   sc_efuse_addr_i, sc_vliw_rd_addr_i, sc_vliw_wr_addr_i, sc_dma_wr_addr_i;
  logic [3:0]   sc_repair_en_o;
  logic [3:0][5:0] sc_repair_addr_o;
  logic         sc_vliw_rd_en_i, sc_vliw_wr_en_i, sc_dma_wr_en_i, sc_scrub_en_i;
  logic         sc_vliw_rd_val_o, sc_vliw_sec_o, sc_vliw_ded_o, sc_vliw_repaired_hit_o;
  logic [127:0] sc_vliw_rd_data_o, sc_vliw_wr_data_i, sc_dma_wr_data_i;
  logic         sc_scrub_rd_o, sc_scrub_wb_o, sc_scrub_ded_o;
  logic [1:0]   sc_scrub_bank_o, sc_ded_bank_o, sc_ser_bank_i;
  logic [5:0]   sc_scrub_addr_o, sc_ded_addr_o, sc_ser_addr_i;
  logic [15:0]  sc_scrub_cnt_o;
  logic         sc_ser_en_i;
  logic [143:0] sc_ser_mask_i;

  groq_sram_controller_scrubber #(
    .P_NUM_BANKS (4),
    .P_BANK_W    (2),
    .P_ADDR_W    (6)
  ) u_sram_scrubber (
    .clk                        (clk),
    .rst_n                      (rst_n),
    .efuse_load_req_i           (sc_efuse_req_i),
    .efuse_bank_i               (sc_efuse_bank_i),
    .efuse_bad_addr_i           (sc_efuse_addr_i),
    .bank_repair_en_o           (sc_repair_en_o),
    .bank_repair_addr_o         (sc_repair_addr_o),
    .efuse_load_ack_o           (sc_efuse_ack_o),
    .vliw_rd_en_i               (sc_vliw_rd_en_i),
    .vliw_rd_bank_i             (sc_vliw_rd_bank_i),
    .vliw_rd_addr_i             (sc_vliw_rd_addr_i),
    .vliw_rd_valid_o            (sc_vliw_rd_val_o),
    .vliw_rd_data_o             (sc_vliw_rd_data_o),
    .vliw_rd_sec_err_o          (sc_vliw_sec_o),
    .vliw_rd_ded_err_o          (sc_vliw_ded_o),
    .vliw_rd_repaired_row_hit_o (sc_vliw_repaired_hit_o),
    .vliw_wr_en_i               (sc_vliw_wr_en_i),
    .vliw_wr_bank_i             (sc_vliw_wr_bank_i),
    .vliw_wr_addr_i             (sc_vliw_wr_addr_i),
    .vliw_wr_data_i             (sc_vliw_wr_data_i),
    .dma_wr_en_i                (sc_dma_wr_en_i),
    .dma_wr_bank_i              (sc_dma_wr_bank_i),
    .dma_wr_addr_i              (sc_dma_wr_addr_i),
    .dma_wr_data_i              (sc_dma_wr_data_i),
    .scrub_enable_i             (sc_scrub_en_i),
    .scrub_rd_fire_o            (sc_scrub_rd_o),
    .scrub_wb_fire_o            (sc_scrub_wb_o),
    .scrub_active_bank_o        (sc_scrub_bank_o),
    .scrub_active_addr_o        (sc_scrub_addr_o),
    .scrub_corrected_cnt_o      (sc_scrub_cnt_o),
    .scrub_ded_alert_o          (sc_scrub_ded_o),
    .first_ded_bank_o           (sc_ded_bank_o),
    .first_ded_addr_o           (sc_ded_addr_o),
    .ser_inject_en_i            (sc_ser_en_i),
    .ser_inject_bank_i          (sc_ser_bank_i),
    .ser_inject_addr_i          (sc_ser_addr_i),
    .ser_inject_mask_i          (sc_ser_mask_i)
  );

  // ---------------------------------------------------------------------------
  // 4. MXFP8 / NVFP4 / W4A8 Microscaling Dot-Product Engine Instance
  // ---------------------------------------------------------------------------
  logic               dot_valid_i, dot_zskip_en_i, dot_acc_en_i, dot_acc_clr_i;
  logic [2:0]         dot_mode_i;
  logic [7:0]         dot_act_scale_i, dot_wt_scale_i;
  logic [127:0]       dot_act_i, dot_wt_i;
  logic               dot_valid_o, dot_bzero_o, dot_nan_o;
  logic signed [31:0] dot_unaccum_o, dot_accum_o;
  logic [31:0]        dot_fp32_o;
  logic [5:0]         dot_zlanes_o;

  groq_mxfp8_nvfp4_dot_engine u_dot_engine (
    .clk                  (clk),
    .rst_n                (rst_n),
    .valid_i              (dot_valid_i),
    .mode_i               (dot_mode_i),
    .zero_skip_en_i       (dot_zskip_en_i),
    .accum_en_i           (dot_acc_en_i),
    .accum_clear_i        (dot_acc_clr_i),
    .act_scale_e8m0_i     (dot_act_scale_i),
    .wt_scale_e8m0_i      (dot_wt_scale_i),
    .act_stream_i         (dot_act_i),
    .wt_stream_i          (dot_wt_i),
    .valid_o              (dot_valid_o),
    .unaccum_dot_o        (dot_unaccum_o),
    .dot_accum_o          (dot_accum_o),
    .dot_fp32_o           (dot_fp32_o),
    .zero_skip_lanes_o    (dot_zlanes_o),
    .block_zero_skipped_o (dot_bzero_o),
    .nan_inf_flag_o       (dot_nan_o)
  );

  // ---------------------------------------------------------------------------
  // 5. C2C 64B/66B SerDes PCS TX/RX Loopback Pair + Live CRC-16 Fault Injection
  // ---------------------------------------------------------------------------
  logic         pcs_link_en, pcs_scram_en, pcs_ts1, pcs_ts2, pcs_dsk_done;
  logic         pcs_tx_val_i, pcs_tx_rdy_o, pcs_phy_tx_val, pcs_replay_act_o;
  logic [127:0] pcs_tx_dat_i, pcs_tx_scram_o, pcs_rx_dat_o;
  logic [3:0]   pcs_tx_dst_i, pcs_tx_hop_i, pcs_tx_op_i, pcs_tx_seq_o;
  logic [1:0]   pcs_tx_shdr_o, pcs_rx_nack_seq_o, pcs_nack_seq_q;
  logic [15:0]  pcs_tx_crc16_o, pcs_tx_meta_o;
  logic [161:0] pcs_phy_tx_frame, pcs_phy_rx_frame;
  logic         pcs_rx_val_o, pcs_rx_crc16_err_o, pcs_rx_sync_err_o, pcs_rx_nack_req_o, pcs_nack_req_q;
  logic [3:0]   pcs_rx_dst_o, pcs_rx_hop_o, pcs_rx_op_o, pcs_rx_seq_o;
  logic [2:0]   pcs_tx_lstate_o, pcs_rx_lstate_o;
  logic         pcs_tx_up_o, pcs_rx_up_o;
  logic [7:0]   pcs_tx_skew_o, pcs_rx_skew_o;
  logic         pcs_err_inj_en;
  logic [15:0]  pcs_err_inj_mask;

  assign pcs_phy_rx_frame = pcs_err_inj_en ?
                            (pcs_phy_tx_frame ^ {146'd0, pcs_err_inj_mask}) :
                            pcs_phy_tx_frame;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pcs_nack_req_q <= 1'b0;
      pcs_nack_seq_q <= 2'd0;
    end else begin
      pcs_nack_req_q <= pcs_rx_nack_req_o;
      pcs_nack_seq_q <= pcs_rx_nack_seq_o;
    end
  end

  groq_c2c_serdes_pcs u_pcs_tx (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .link_enable_i          (pcs_link_en),
    .scramble_en_i          (pcs_scram_en),
    .rx_ts1_seen_i          (pcs_ts1),
    .rx_ts2_seen_i          (pcs_ts2),
    .deskew_done_i          (pcs_dsk_done),
    .retrain_req_i          (1'b0),
    .local_realsync_cnt_i   (8'h40),
    .rx_beacon_ts_i         (8'h3E),
    .tx_flit_valid_i        (pcs_tx_val_i),
    .tx_flit_data_i         (pcs_tx_dat_i),
    .tx_dst_chip_i          (pcs_tx_dst_i),
    .tx_hop_cnt_i           (pcs_tx_hop_i),
    .tx_opcode_i            (pcs_tx_op_i),
    .tx_ready_o             (pcs_tx_rdy_o),
    .nack_req_i             (pcs_nack_req_q),
    .nack_seq_i             (pcs_nack_seq_q),
    .phy_tx_valid_o         (pcs_phy_tx_val),
    .phy_tx_frame_o         (pcs_phy_tx_frame),
    .tx_sync_hdr_o          (pcs_tx_shdr_o),
    .tx_crc16_o             (pcs_tx_crc16_o),
    .tx_meta_o              (pcs_tx_meta_o),
    .tx_scrambled_payload_o (pcs_tx_scram_o),
    .replay_active_o        (pcs_replay_act_o),
    .tx_seq_num_o           (pcs_tx_seq_o),
    .phy_rx_valid_i         (1'b0),
    .phy_rx_frame_i         (162'd0),
    .rx_flit_valid_o        (),
    .rx_flit_data_o         (),
    .rx_dst_chip_o          (),
    .rx_hop_cnt_o           (),
    .rx_opcode_o            (),
    .rx_seq_num_o           (),
    .rx_crc16_err_o         (),
    .rx_sync_err_o          (),
    .nack_req_o             (),
    .nack_seq_o             (),
    .link_state_o           (pcs_tx_lstate_o),
    .link_up_o              (pcs_tx_up_o),
    .measured_skew_o        (pcs_tx_skew_o)
  );

  groq_c2c_serdes_pcs u_pcs_rx (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .link_enable_i          (pcs_link_en),
    .scramble_en_i          (pcs_scram_en),
    .rx_ts1_seen_i          (pcs_ts1),
    .rx_ts2_seen_i          (pcs_ts2),
    .deskew_done_i          (pcs_dsk_done),
    .retrain_req_i          (1'b0),
    .local_realsync_cnt_i   (8'h40),
    .rx_beacon_ts_i         (8'h3E),
    .tx_flit_valid_i        (1'b0),
    .tx_flit_data_i         (128'd0),
    .tx_dst_chip_i          (4'd0),
    .tx_hop_cnt_i           (4'd0),
    .tx_opcode_i            (4'd0),
    .tx_ready_o             (),
    .nack_req_i             (1'b0),
    .nack_seq_i             (2'd0),
    .phy_tx_valid_o         (),
    .phy_tx_frame_o         (),
    .tx_sync_hdr_o          (),
    .tx_crc16_o             (),
    .tx_meta_o              (),
    .tx_scrambled_payload_o (),
    .replay_active_o        (),
    .tx_seq_num_o           (),
    .phy_rx_valid_i         (pcs_phy_tx_val),
    .phy_rx_frame_i         (pcs_phy_rx_frame),
    .rx_flit_valid_o        (pcs_rx_val_o),
    .rx_flit_data_o         (pcs_rx_dat_o),
    .rx_dst_chip_o          (pcs_rx_dst_o),
    .rx_hop_cnt_o           (pcs_rx_hop_o),
    .rx_opcode_o            (pcs_rx_op_o),
    .rx_seq_num_o           (pcs_rx_seq_o),
    .rx_crc16_err_o         (pcs_rx_crc16_err_o),
    .rx_sync_err_o          (pcs_rx_sync_err_o),
    .nack_req_o             (pcs_rx_nack_req_o),
    .nack_seq_o             (pcs_rx_nack_seq_o),
    .link_state_o           (pcs_rx_lstate_o),
    .link_up_o              (pcs_rx_up_o),
    .measured_skew_o        (pcs_rx_skew_o)
  );

  // ---------------------------------------------------------------------------
  // 6. C2C KV-Cache Disaggregation Receiver & Microscaling Block Quantizer
  // ---------------------------------------------------------------------------
  logic         kvq_valid_i, kvq_valid_o, kvq_sram_wr_en_o, kvq_clamped_o;
  logic [1:0]   kvq_mode_i, kvq_bank_i, kvq_sram_wr_bank_o, kvq_comp_o;
  logic [5:0]   kvq_addr_i, kvq_sram_wr_addr_o;
  logic [127:0] kvq_lo_i, kvq_hi_i, kvq_vec_o;
  logic [7:0]   kvq_scale_o;
  logic [4:0]   kvq_zlanes_o;

  groq_c2c_kv_quant_rx_engine #(
    .P_NUM_LANES (16),
    .P_BANK_W    (2),
    .P_ADDR_W    (6)
  ) u_kv_quant_rx (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .valid_i                  (kvq_valid_i),
    .quant_mode_i             (kvq_mode_i),
    .kv_in_lo_i               (kvq_lo_i),
    .kv_in_hi_i               (kvq_hi_i),
    .target_sram_bank_i       (kvq_bank_i),
    .target_sram_addr_i       (kvq_addr_i),
    .valid_o                  (kvq_valid_o),
    .quant_vec_o              (kvq_vec_o),
    .scale_e8m0_o             (kvq_scale_o),
    .sram_wr_en_o             (kvq_sram_wr_en_o),
    .sram_wr_bank_o           (kvq_sram_wr_bank_o),
    .sram_wr_addr_o           (kvq_sram_wr_addr_o),
    .zero_lanes_cnt_o         (kvq_zlanes_o),
    .nan_inf_clamped_o        (kvq_clamped_o),
    .compression_ratio_code_o (kvq_comp_o)
  );

  // ---------------------------------------------------------------------------
  // 7. MXM 16x16 Systolic Weight-Stationary MAC Array Slice
  // ---------------------------------------------------------------------------
  logic [3:0]   mxm_op, mxm_prec, mxm_wt_row, mxm_bg_row;
  logic         mxm_zgate_en, mxm_acc_clr, mxm_acc_pre, mxm_bg_en;
  logic         mxm_act_val, mxm_wt_val, mxm_act_bank, mxm_out_val;
  logic [127:0] mxm_act_dat, mxm_wt_dat, mxm_bg_dat, mxm_out_dat;
  logic [511:0] mxm_pre_dat, mxm_acc_vec;
  logic [15:0]  mxm_zmask;
  logic [4:0]   mxm_zcnt;

  groq_mxm_slice u_stress_mxm (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .mxm_op_i              (mxm_op),
    .prec_mode_i           (mxm_prec),
    .weight_row_idx_i      (mxm_wt_row),
    .act_zero_gate_en_i    (mxm_zgate_en),
    .accum_clear_i         (mxm_acc_clr),
    .accum_preload_en_i    (mxm_acc_pre),
    .bg_wt_load_en_i       (mxm_bg_en),
    .bg_wt_row_idx_i       (mxm_bg_row),
    .bg_wt_data_i          (mxm_bg_dat),
    .stream_act_valid_i    (mxm_act_val),
    .stream_act_data_i     (mxm_act_dat),
    .stream_wt_valid_i     (mxm_wt_val),
    .stream_wt_data_i      (mxm_wt_dat),
    .accum_preload_data_i  (mxm_pre_dat),
    .active_bank_o         (mxm_act_bank),
    .zero_skip_gate_mask_o (mxm_zmask),
    .zero_skip_count_o     (mxm_zcnt),
    .out_valid_o           (mxm_out_val),
    .stream_out_data_o     (mxm_out_dat),
    .accum_vec_o           (mxm_acc_vec)
  );

  // ---------------------------------------------------------------------------
  // 8. SXM 16-Lane Crossbar Permute & 16x16 Matrix Transpose Slice
  // ---------------------------------------------------------------------------
  logic [3:0]   sxm_op, sxm_shamt, sxm_slane, sxm_bfly, sxm_tidx;
  logic         sxm_rope_neg, sxm_in_val, sxm_out_val;
  logic [127:0] sxm_in_dat, sxm_out_dat, sxm_comb_dat;

  groq_sxm_slice u_stress_sxm (
    .clk                (clk),
    .rst_n              (rst_n),
    .sxm_op_i           (sxm_op),
    .shift_amt_i        (sxm_shamt),
    .src_lane_i         (sxm_slane),
    .butterfly_mask_i   (sxm_bfly),
    .transpose_idx_i    (sxm_tidx),
    .rope_neg_even_en_i (sxm_rope_neg),
    .stream_in_valid_i  (sxm_in_val),
    .stream_in_data_i   (sxm_in_dat),
    .stream_out_valid_o (sxm_out_val),
    .stream_out_data_o  (sxm_out_dat),
    .perm_comb_data_o   (sxm_comb_dat)
  );

  // ---------------------------------------------------------------------------
  // 9. VXM 16-Lane Vector ALU, Tree Reducer & Piecewise-Linear LUT Slice
  // ---------------------------------------------------------------------------
  logic               vxm_val, vxm_use_acc, vxm_out_val, vxm_mgate, vxm_lgate;
  logic [3:0]         vxm_op, vxm_prec;
  logic [2:0]         vxm_qshift;
  logic [127:0]       vxm_sa, vxm_sb, vxm_sc, vxm_out_dat, vxm_comb_dat;
  logic [511:0]       vxm_acc_in, vxm_acc_out;
  logic signed [15:0] vxm_rsum;
  logic signed [7:0]  vxm_rmax;

  groq_vxm_slice u_stress_vxm (
    .clk                 (clk),
    .rst_n               (rst_n),
    .op_valid_i          (vxm_val),
    .vxm_op_i            (vxm_op),
    .prec_mode_i         (vxm_prec),
    .quant_shift_i       (vxm_qshift),
    .use_accum_32b_i     (vxm_use_acc),
    .stream_a_i          (vxm_sa),
    .stream_b_i          (vxm_sb),
    .stream_c_i          (vxm_sc),
    .accum_32b_in_i      (vxm_acc_in),
    .stream_out_valid_o  (vxm_out_val),
    .stream_out_data_o   (vxm_out_dat),
    .accum_32b_out_o     (vxm_acc_out),
    .vxm_comb_data_o     (vxm_comb_dat),
    .reduce_sum_scalar_o (vxm_rsum),
    .reduce_max_scalar_o (vxm_rmax),
    .mul_gate_active_o   (vxm_mgate),
    .lut_gate_active_o   (vxm_lgate)
  );

  // ---------------------------------------------------------------------------
  // 10. Golden Reference Function for C2C KV-Cache Microscaling Quantizer
  // ---------------------------------------------------------------------------
  function automatic void compute_kv_quant_golden(
    input  logic [1:0]   mode,
    input  logic [127:0] lo,
    input  logic [127:0] hi,
    output logic [127:0] exp_vec,
    output logic [7:0]   exp_scale,
    output logic [4:0]   exp_zeros,
    output logic         exp_clamped,
    output logic [1:0]   exp_comp_code
  );
    logic [255:0] full_in;
    logic         sgn     [0:15];
    logic [7:0]   e8      [0:15];
    logic [6:0]   f7      [0:15];
    logic         is_z    [0:15];
    logic         is_ni   [0:15];
    logic         any_fnz;
    logic [7:0]   emax;
    logic [7:0]   rexp;
    logic [127:0] mxfp8_v;
    logic [63:0]  nvfp4_v;

    full_in     = {hi, lo};
    any_fnz     = 1'b0;
    emax        = 8'd0;
    exp_zeros   = 5'd0;
    exp_clamped = 1'b0;

    for (int i = 0; i < 16; i++) begin
      logic [15:0] w;
      w      = full_in[i*16 +: 16];
      sgn[i] = w[15];
      if (mode == 2'd1) begin
        if (w[14:10] == 5'd0)       e8[i] = 8'd0;
        else if (w[14:10] == 5'd31) e8[i] = 8'd255;
        else                        e8[i] = {3'd0, w[14:10]} + 8'd112;
        f7[i] = w[9:3];
      end else begin
        e8[i] = w[14:7];
        f7[i] = w[6:0];
      end
      is_z[i]  = (e8[i] == 8'd0);
      is_ni[i] = (e8[i] == 8'd255);
      if (is_z[i]) exp_zeros = exp_zeros + 5'd1;
      if (is_ni[i] && (mode != 2'd3)) exp_clamped = 1'b1;
      if (!is_z[i] && !is_ni[i]) begin
        any_fnz = 1'b1;
        if (e8[i] > emax) emax = e8[i];
      end
    end
    if (!any_fnz) emax = 8'd127;

    if (mode == 2'd0 || mode == 2'd1) begin
      exp_scale     = (emax > 8'd7) ? (emax - 8'd7) : 8'd0;
      exp_comp_code = 2'd2;
    end else if (mode == 2'd2) begin
      exp_scale     = (emax > 8'd2) ? (emax - 8'd2) : 8'd0;
      exp_comp_code = 2'd3;
    end else begin
      exp_scale     = 8'd127;
      exp_comp_code = 2'd1;
    end

    for (int i = 0; i < 16; i++) begin
      rexp = e8[i] - exp_scale;
      if (is_z[i])                 mxfp8_v[i*8 +: 8] = {sgn[i], 7'd0};
      else if (is_ni[i])           mxfp8_v[i*8 +: 8] = {sgn[i], 4'd14, 3'd7};
      else if (e8[i] <= exp_scale) mxfp8_v[i*8 +: 8] = {sgn[i], 7'd0};
      else if (rexp >= 8'd14)      mxfp8_v[i*8 +: 8] = {sgn[i], 4'd14, 3'd7};
      else                         mxfp8_v[i*8 +: 8] = {sgn[i], rexp[3:0], f7[i][6:4]};

      if (is_z[i])                 nvfp4_v[i*4 +: 4] = {sgn[i], 3'd0};
      else if (is_ni[i])           nvfp4_v[i*4 +: 4] = {sgn[i], 2'd3, 1'b1};
      else if (e8[i] <= exp_scale) nvfp4_v[i*4 +: 4] = {sgn[i], 3'd0};
      else if (rexp >= 8'd3)       nvfp4_v[i*4 +: 4] = {sgn[i], 2'd3, 1'b1};
      else                         nvfp4_v[i*4 +: 4] = {sgn[i], rexp[1:0], f7[i][6]};
    end

    if (mode == 2'd0 || mode == 2'd1) exp_vec = mxfp8_v;
    else if (mode == 2'd2)            exp_vec = {nvfp4_v, nvfp4_v};
    else                              exp_vec = lo;
  endfunction

  // ---------------------------------------------------------------------------
  // 11. Shadow Golden State, Telemetry Counters & Every-Cycle Invariant Checkers
  // ---------------------------------------------------------------------------
  logic [127:0] gold_sram [0:3][0:63];
  bit           unhealed_ser [0:3][0:63];
  logic         prev_rd_en_q;
  logic [1:0]   prev_rd_bank_q;
  logic [5:0]   prev_rd_addr_q;
  logic [127:0] expected_rd_data_q;
  logic [7:0]   prev_pdc_eff_q;
  logic [127:0] pcs_sent_table [0:15];

  logic         kvq_val_q;
  logic [1:0]   kvq_mode_q, kvq_bank_q;
  logic [5:0]   kvq_addr_q;
  logic [127:0] kvq_lo_q, kvq_hi_q;

  logic [15:0][7:0] ref_sxm_tbuf [0:15];
  logic             mxm_exec_d1, mxm_exec_d2;
  logic             sxm_exp_val_d1;
  logic [3:0]       sxm_op_d1, sxm_tidx_d1;

  int err_cnt            = 0;
  int total_checks       = 0;
  int spec_checks        = 0;
  int droop_checks       = 0;
  int sram_checks        = 0;
  int dot_checks         = 0;
  int pcs_checks         = 0;
  int kvq_checks         = 0;
  int mxm_checks         = 0;
  int sxm_checks         = 0;
  int vxm_checks         = 0;
  int ser_injected_cnt   = 0;
  int crc16_injected_cnt = 0;
  int gbn_replays_cnt    = 0;
  int kvq_clamped_cnt    = 0;

  int max_mit_didt       = 0;
  int max_unmit_didt     = 0;
  int min_mit_vdd_mv     = 750;
  int min_unmit_vdd_mv   = 750;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < 4; b++) begin
        for (int a = 0; a < 64; a++) begin
          gold_sram[b][a]    <= 128'd0;
          unhealed_ser[b][a] <= 1'b0;
        end
      end
      prev_rd_en_q       <= 1'b0;
      prev_rd_bank_q     <= 2'd0;
      prev_rd_addr_q     <= 6'd0;
      expected_rd_data_q <= 128'd0;
      prev_pdc_eff_q     <= 8'd0;
      for (int s = 0; s < 16; s++) pcs_sent_table[s] <= 128'd0;
      kvq_val_q          <= 1'b0;
      kvq_mode_q         <= 2'd0;
      kvq_bank_q         <= 2'd0;
      kvq_addr_q         <= 6'd0;
      kvq_lo_q           <= 128'd0;
      kvq_hi_q           <= 128'd0;
      mxm_exec_d1        <= 1'b0;
      mxm_exec_d2        <= 1'b0;
      sxm_exp_val_d1     <= 1'b0;
      sxm_op_d1          <= 4'd0;
      sxm_tidx_d1        <= 4'd0;
      for (int r = 0; r < 16; r++) ref_sxm_tbuf[r] <= '0;
    end else begin
      prev_rd_en_q       <= sc_vliw_rd_en_i;
      prev_rd_bank_q     <= sc_vliw_rd_bank_i;
      prev_rd_addr_q     <= sc_vliw_rd_addr_i;
      expected_rd_data_q <= gold_sram[sc_vliw_rd_bank_i][sc_vliw_rd_addr_i];
      prev_pdc_eff_q     <= pdc_eff_o;

      kvq_val_q          <= kvq_valid_i;
      kvq_mode_q         <= kvq_mode_i;
      kvq_bank_q         <= kvq_bank_i;
      kvq_addr_q         <= kvq_addr_i;
      kvq_lo_q           <= kvq_lo_i;
      kvq_hi_q           <= kvq_hi_i;

      mxm_exec_d1        <= mxm_act_val && (mxm_op == MXM_SYSTOLIC_EXEC);
      mxm_exec_d2        <= mxm_exec_d1;
      sxm_exp_val_d1     <= sxm_in_val && (sxm_op != SXM_NOP);
      sxm_op_d1          <= sxm_op;
      sxm_tidx_d1        <= sxm_tidx;
      if (sxm_in_val && (sxm_op == SXM_TRANSPOSE_LOAD)) begin
        for (int c = 0; c < 16; c++) begin
          ref_sxm_tbuf[sxm_tidx][c] <= sxm_in_dat[c*8 +: 8];
        end
      end

      if (sc_scrub_wb_o) begin
        unhealed_ser[sc_scrub_bank_o][sc_scrub_addr_o] <= 1'b0;
      end
      if (sc_dma_wr_en_i) begin
        gold_sram[sc_dma_wr_bank_i][sc_dma_wr_addr_i]    <= sc_dma_wr_data_i;
        unhealed_ser[sc_dma_wr_bank_i][sc_dma_wr_addr_i] <= 1'b0;
      end
      if (sc_vliw_wr_en_i) begin
        gold_sram[sc_vliw_wr_bank_i][sc_vliw_wr_addr_i]    <= sc_vliw_wr_data_i;
        unhealed_ser[sc_vliw_wr_bank_i][sc_vliw_wr_addr_i] <= 1'b0;
      end
      if (sc_ser_en_i) begin
        unhealed_ser[sc_ser_bank_i][sc_ser_addr_i] <= 1'b1;
      end
      if (pcs_tx_up_o && pcs_tx_rdy_o && pcs_tx_val_i) begin
        pcs_sent_table[pcs_tx_seq_o] <= pcs_tx_dat_i;
      end
    end
  end

  // Continuous Every-Cycle Self-Checking Monitor across all 9 Subsystems
  always @(posedge clk) begin
    if (rst_n) begin
      // (1) Speculative Decode Tree & Bitonic 16-Lane Sampler Checks (1 check/cycle)
      if (sd_valid_o) begin
        bit mono_ok;
        bit tree_ok;
        mono_ok = 1'b1;
        for (int k = 0; k < 15; k++) begin
          if ($signed(sd_sorted_logits_o[8*k +: 8]) < $signed(sd_sorted_logits_o[8*(k+1) +: 8]))
            mono_ok = 1'b0;
        end
        tree_ok = (sd_nucleus_mask_o[0] == 1'b1) &&
                  (sd_acc_mask_o[0] == 1'b1) &&
                  (sd_acc_len_o >= 3'd1 && sd_acc_len_o <= 3'd4) &&
                  (sd_kv_adv_o == sd_acc_len_o) &&
                  (sd_emit_cnt_o == (sd_acc_len_o + 3'd1));
        for (int n = 1; n < 8; n++) begin
          logic [2:0] p_idx;
          p_idx = sd_tree_parent_i[3*n +: 3];
          if (sd_acc_mask_o[n] && !sd_acc_mask_o[p_idx]) tree_ok = 1'b0;
        end
        if (!mono_ok || !tree_ok) begin
          $display("[ERR] SpecDecode violation mono=%b tree=%b mask=%b len=%0d",
                   mono_ok, tree_ok, sd_acc_mask_o, sd_acc_len_o);
          err_cnt++;
        end
        spec_checks  += 1;
        total_checks += 1;
      end

      // (2) Power Droop Controller Checks & Peak di/dt / Min VDD Telemetry (1 check/cycle)
      begin
        int eff_next_calc, abs_mit_d, abs_unmit_d;
        eff_next_calc = int'(pdc_eff_o) + int'(pdc_didt_o);
        abs_mit_d     = (pdc_didt_o < 0) ? -int'(pdc_didt_o) : int'(pdc_didt_o);
        abs_unmit_d   = (unmit_didt_o < 0) ? -int'(unmit_didt_o) : int'(unmit_didt_o);

        if (abs_mit_d > max_mit_didt)             max_mit_didt     = abs_mit_d;
        if (abs_unmit_d > max_unmit_didt)         max_unmit_didt   = abs_unmit_d;
        if (int'(pdc_vdd_o) < min_mit_vdd_mv)     min_mit_vdd_mv   = int'(pdc_vdd_o);
        if (int'(unmit_vdd_o) < min_unmit_vdd_mv) min_unmit_vdd_mv = int'(unmit_vdd_o);

        if ((eff_next_calc != (int'(pdc_raw_o) + int'(pdc_bleed_o))) ||
            ((pdc_didt_o < 0) && ((-int'(pdc_didt_o)) > int'(pdc_max_step_i))) ||
            (pdc_emerg_o !== 1'b0)) begin
          $display("[ERR] Droop violation eff_next=%0d raw=%0d bleed=%0d didt=%0d vdd=%0d",
                   eff_next_calc, pdc_raw_o, pdc_bleed_o, pdc_didt_o, pdc_vdd_o);
          err_cnt++;
        end
        droop_checks += 1;
        total_checks += 1;
      end

      // (3) SRAM Controller Zero-Contention & SECDED Readback Exactness (1 check/cycle)
      begin
        bit no_contention;
        no_contention = !(sc_scrub_rd_o && sc_scrub_wb_o) &&
                        !(sc_vliw_rd_en_i && (sc_scrub_rd_o || sc_scrub_wb_o) && (sc_scrub_bank_o == sc_vliw_rd_bank_i)) &&
                        !(sc_vliw_wr_en_i && (sc_scrub_rd_o || sc_scrub_wb_o) && (sc_scrub_bank_o == sc_vliw_wr_bank_i)) &&
                        !(sc_dma_wr_en_i  && (sc_scrub_rd_o || sc_scrub_wb_o) && (sc_scrub_bank_o == sc_dma_wr_bank_i));
        if (!no_contention || (sc_scrub_ded_o !== 1'b0)) begin
          $display("[ERR] SRAM scrubber contention/DED err");
          err_cnt++;
        end
        if (prev_rd_en_q) begin
          if ((sc_vliw_rd_val_o !== 1'b1) || (sc_vliw_ded_o !== 1'b0) ||
              (sc_vliw_rd_data_o !== expected_rd_data_q)) begin
            $display("[ERR] SRAM readback mismatch bank=%0d addr=%0d got=%h exp=%h",
                     prev_rd_bank_q, prev_rd_addr_q, sc_vliw_rd_data_o, expected_rd_data_q);
            err_cnt++;
          end
        end
        sram_checks  += 1;
        total_checks += 1;
      end

      // (4) MXFP8 / NVFP4 Dot Engine Checks (1 check/cycle)
      if (dot_valid_o) begin
        if ((dot_zlanes_o > 6'd32) || (dot_bzero_o && (dot_unaccum_o != 32'sd0))) begin
          $display("[ERR] Dot engine invariant violation");
          err_cnt++;
        end
        dot_checks   += 1;
        total_checks += 1;
      end

      // (5) PCS 64B/66B Loopback & Go-Back-N Replay Checks (1 check/cycle)
      if (pcs_rx_up_o) begin
        logic [127:0] exp_pcs_dat;
        exp_pcs_dat = (pcs_replay_act_o || pcs_nack_req_q) ?
                      pcs_sent_table[pcs_rx_seq_o] : pcs_tx_dat_i;
        if (pcs_replay_act_o || pcs_nack_req_q) gbn_replays_cnt++;
        if (pcs_rx_crc16_err_o && pcs_rx_val_o) begin
          $display("[ERR] PCS corrupted frame leaked to rx_flit_valid_o!");
          err_cnt++;
        end
        if (pcs_rx_val_o && (pcs_rx_dat_o !== exp_pcs_dat)) begin
          $display("[ERR] PCS payload mismatch seq=%0d got=%h exp=%h",
                   pcs_rx_seq_o, pcs_rx_dat_o, exp_pcs_dat);
          err_cnt++;
        end
        pcs_checks   += 1;
        total_checks += 1;
      end

      // (6) C2C KV-Cache Quantizer Golden Reference & Sign-Preservation Checks (1 check/cycle)
      if (kvq_val_q) begin
        logic [127:0] exp_kvq_vec;
        logic [7:0]   exp_kvq_scale;
        logic [4:0]   exp_kvq_zeros;
        logic         exp_kvq_clamped;
        logic [1:0]   exp_kvq_comp;
        logic [255:0] full_q;
        bit           sign_ok;

        compute_kv_quant_golden(
          kvq_mode_q, kvq_lo_q, kvq_hi_q,
          exp_kvq_vec, exp_kvq_scale, exp_kvq_zeros, exp_kvq_clamped, exp_kvq_comp
        );
        full_q  = {kvq_hi_q, kvq_lo_q};
        sign_ok = 1'b1;
        if (kvq_mode_q == 2'd0 || kvq_mode_q == 2'd1) begin
          for (int i = 0; i < 16; i++) begin
            if (kvq_vec_o[i*8 + 7] !== full_q[i*16 + 15]) sign_ok = 1'b0;
          end
        end else if (kvq_mode_q == 2'd2) begin
          for (int i = 0; i < 16; i++) begin
            if (kvq_vec_o[i*4 + 3] !== full_q[i*16 + 15] ||
                kvq_vec_o[64 + i*4 + 3] !== full_q[i*16 + 15]) sign_ok = 1'b0;
          end
        end
        if (kvq_clamped_o) kvq_clamped_cnt++;
        if (kvq_valid_o !== 1'b1 || kvq_sram_wr_en_o !== 1'b1 ||
            kvq_sram_wr_bank_o !== kvq_bank_q || kvq_sram_wr_addr_o !== kvq_addr_q ||
            kvq_vec_o !== exp_kvq_vec || kvq_scale_o !== exp_kvq_scale ||
            kvq_zlanes_o !== exp_kvq_zeros || kvq_zlanes_o > 5'd16 ||
            kvq_clamped_o !== exp_kvq_clamped || kvq_comp_o !== exp_kvq_comp || !sign_ok) begin
          $display("[ERR] KVQuant mismatch mode=%0d got_vec=%h exp_vec=%h scale=%0d/%0d sign_ok=%b",
                   kvq_mode_q, kvq_vec_o, exp_kvq_vec, kvq_scale_o, exp_kvq_scale, sign_ok);
          err_cnt++;
        end
        kvq_checks   += 1;
        total_checks += 1;
      end

      // (7) MXM 16x16 Systolic MAC & Zero-Skip Gating Checks (1 check/cycle)
      begin
        if (mxm_out_val !== mxm_exec_d2 || mxm_zcnt > 5'd16) begin
          $display("[ERR] MXM out_val=%b exp=%b zcnt=%0d", mxm_out_val, mxm_exec_d2, mxm_zcnt);
          err_cnt++;
        end
        mxm_checks   += 1;
        total_checks += 1;
      end

      // (8) SXM 16x16 Matrix Transpose & Crossbar Checks (1 check/cycle)
      begin
        if (sxm_out_val !== sxm_exp_val_d1) begin
          $display("[ERR] SXM out_val=%b exp=%b", sxm_out_val, sxm_exp_val_d1);
          err_cnt++;
        end
        if (sxm_out_val && (sxm_op_d1 == SXM_TRANSPOSE_READ)) begin
          for (int i = 0; i < 16; i++) begin
            if (sxm_out_dat[i*8 +: 8] !== ref_sxm_tbuf[i][sxm_tidx_d1]) begin
              $display("[ERR] SXM transpose mismatch lane %0d", i);
              err_cnt++;
            end
          end
        end
        sxm_checks   += 1;
        total_checks += 1;
      end

      // (9) VXM 16-Lane Vector ALU & Tree Reduction Exactness Checks (1 check/cycle)
      begin
        logic signed [15:0] exp_sum;
        logic signed [7:0]  exp_max, lane_v;
        exp_sum = 16'sd0;
        exp_max = -8'sd128;
        for (int i = 0; i < 16; i++) begin
          lane_v  = $signed(vxm_sa[i*8 +: 8]);
          exp_sum = exp_sum + {{8{lane_v[7]}}, lane_v};
          if (i == 0 || lane_v > exp_max) exp_max = lane_v;
        end
        if (vxm_rsum !== exp_sum || vxm_rmax !== exp_max) begin
          $display("[ERR] VXM reduce mismatch rsum=%0d exp=%0d", vxm_rsum, exp_sum);
          err_cnt++;
        end
        vxm_checks   += 1;
        total_checks += 1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 12. 500,000-Cycle 9-Subsystem Adversarial Soak Stimulus Generator
  // ---------------------------------------------------------------------------
  logic [63:0] lfsr;

  initial begin
    rst_n            = 1'b0;
    lfsr             = 64'hCAFE_BABE_DEAD_BEEF;
    sd_valid_i       = 1'b0;
    sd_op_mode_i     = 2'd0;
    sd_logits_i      = '0;
    sd_token_ids_i   = '0;
    sd_top_k_i       = 4'd4;
    sd_inv_temp_i    = 8'd2;
    sd_top_p_i       = 16'd600;
    sd_rng_step_i    = 1'b1;
    sd_rng_thresh_i  = 8'd128;
    sd_tree_parent_i = {3'd5, 3'd3, 3'd2, 3'd1, 3'd1, 3'd0, 3'd0, 3'd0};
    sd_tree_dprob_i  = '0;
    sd_tree_tprob_i  = '0;
    sd_tree_rand_i   = '0;
    sd_tree_dtok_i   = {8'h17, 8'h16, 8'h15, 8'h14, 8'h13, 8'h12, 8'h11, 8'h10};
    sd_bonus_tok_i   = 8'h99;

    pdc_slice_act_i   = 8'h00;
    pdc_zskip_i       = 6'd0;
    pdc_prewarm_i     = 1'b0;
    pdc_prewarm_lvl_i = 8'd200;
    pdc_max_step_i    = 8'd36;

    sc_efuse_req_i    = 1'b0;
    sc_efuse_bank_i   = 2'd0;
    sc_efuse_addr_i   = 6'd0;
    sc_vliw_rd_en_i   = 1'b0;
    sc_vliw_rd_bank_i = 2'd0;
    sc_vliw_rd_addr_i = 6'd0;
    sc_vliw_wr_en_i   = 1'b0;
    sc_vliw_wr_bank_i = 2'd0;
    sc_vliw_wr_addr_i = 6'd0;
    sc_vliw_wr_data_i = '0;
    sc_dma_wr_en_i    = 1'b0;
    sc_dma_wr_bank_i  = 2'd0;
    sc_dma_wr_addr_i  = 6'd0;
    sc_dma_wr_data_i  = '0;
    sc_scrub_en_i     = 1'b1;
    sc_ser_en_i       = 1'b0;
    sc_ser_bank_i     = 2'd0;
    sc_ser_addr_i     = 6'd0;
    sc_ser_mask_i     = '0;

    dot_valid_i       = 1'b0;
    dot_mode_i        = 3'd0;
    dot_zskip_en_i    = 1'b1;
    dot_acc_en_i      = 1'b1;
    dot_acc_clr_i     = 1'b0;
    dot_act_scale_i   = 8'd127;
    dot_wt_scale_i    = 8'd127;
    dot_act_i         = '0;
    dot_wt_i          = '0;

    pcs_link_en       = 1'b0;
    pcs_scram_en      = 1'b0;
    pcs_ts1           = 1'b0;
    pcs_ts2           = 1'b0;
    pcs_dsk_done      = 1'b0;
    pcs_tx_val_i      = 1'b0;
    pcs_tx_dat_i      = '0;
    pcs_tx_dst_i      = 4'd3;
    pcs_tx_hop_i      = 4'd1;
    pcs_tx_op_i       = 4'd2;
    pcs_err_inj_en    = 1'b0;
    pcs_err_inj_mask  = 16'h0001;

    kvq_valid_i       = 1'b0;
    kvq_mode_i        = 2'd0;
    kvq_lo_i          = '0;
    kvq_hi_i          = '0;
    kvq_bank_i        = 2'd0;
    kvq_addr_i        = 6'd0;

    mxm_op            = MXM_NOP;
    mxm_prec          = PREC_INT8;
    mxm_wt_row        = 4'd0;
    mxm_bg_row        = 4'd0;
    mxm_zgate_en      = 1'b1;
    mxm_acc_clr       = 1'b0;
    mxm_acc_pre       = 1'b0;
    mxm_bg_en         = 1'b0;
    mxm_act_val       = 1'b0;
    mxm_wt_val        = 1'b0;
    mxm_act_dat       = '0;
    mxm_wt_dat        = '0;
    mxm_bg_dat        = '0;
    mxm_pre_dat       = '0;

    sxm_op            = SXM_NOP;
    sxm_shamt         = 4'd0;
    sxm_slane         = 4'd0;
    sxm_bfly          = 4'd0;
    sxm_tidx          = 4'd0;
    sxm_rope_neg      = 1'b0;
    sxm_in_val        = 1'b0;
    sxm_in_dat        = '0;

    vxm_val           = 1'b0;
    vxm_op            = VXM_NOP;
    vxm_prec          = PREC_INT8;
    vxm_qshift        = 3'd0;
    vxm_use_acc       = 1'b0;
    vxm_sa            = '0;
    vxm_sb            = '0;
    vxm_sc            = '0;
    vxm_acc_in        = '0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Boot eFuse Row-Repair Table Loader (4 banks) & PCS Link Training
    for (int b = 0; b < 4; b++) begin
      sc_efuse_req_i  = 1'b1;
      sc_efuse_bank_i = 2'(b);
      sc_efuse_addr_i = 6'(b * 11 + 5);
      @(posedge clk);
    end
    sc_efuse_req_i = 1'b0;

    pcs_link_en  = 1'b1; @(posedge clk);
    pcs_ts1      = 1'b1; @(posedge clk);
    pcs_ts2      = 1'b1; @(posedge clk);
    pcs_dsk_done = 1'b1; @(posedge clk);
    @(posedge clk);

    // Main 500,000-Cycle 9-Subsystem Ultra-Endurance Soak Loop
    for (int cyc = 0; cyc < TOTAL_CYCLES; cyc++) begin
      int phase32;
      logic [1:0] wr_b, rd_b, dma_b, ser_b;
      logic [5:0] wr_a, rd_a, dma_a, ser_a;
      logic [127:0] adv_vec;

      lfsr = {lfsr[62:0], lfsr[63] ^ lfsr[61] ^ lfsr[60] ^ lfsr[58]} + 64'h9E37_79B9_7F4A_7C15;
      phase32 = cyc & 31;
      adv_vec = {lfsr, lfsr ^ 64'hA5A5_5A5A_F0F0_0F0F};

      // (A) Speculative Decode & Sampler Adversarial Inputs
      sd_valid_i      = 1'b1;
      sd_op_mode_i    = 2'(cyc % 3);
      sd_logits_i     = {lfsr, ~lfsr};
      sd_token_ids_i  = {64'(cyc), lfsr ^ 64'h55AA_55AA_55AA_55AA};
      sd_top_k_i      = 4'((cyc & 15) + 1);
      sd_inv_temp_i   = 8'((cyc & 7) + 1);
      sd_top_p_i      = 16'd300 + 16'(lfsr[9:0]);
      sd_rng_thresh_i = lfsr[7:0];
      sd_tree_dprob_i = lfsr | 64'h0101_0101_0101_0101;
      sd_tree_tprob_i = {lfsr[31:0], lfsr[63:32]} | 64'h1010_1010_1010_1010;
      sd_tree_rand_i  = {lfsr[55:0], 8'h00};

      // (B) Power Droop Controller Lookahead Pre-Warm & Burst Stress
      if (phase32 < 6) begin
        pdc_prewarm_i   = 1'b1;
        pdc_slice_act_i = 8'b0010_0000;
        pdc_zskip_i     = 6'd0;
      end else if (phase32 < 16) begin
        pdc_prewarm_i   = 1'b0;
        pdc_slice_act_i = 8'b1111_1110;
        pdc_zskip_i     = 6'd8;
      end else begin
        pdc_prewarm_i   = 1'b0;
        pdc_slice_act_i = 8'b0010_0000;
        pdc_zskip_i     = 6'd16;
      end

      // (C) C2C KV-Cache Quantizer Ingress (all 4 modes + closed-loop SRAM/Dot feed)
      kvq_valid_i = 1'b1;
      kvq_mode_i  = 2'(cyc & 3);
      kvq_lo_i    = {lfsr, ~lfsr};
      kvq_hi_i    = {lfsr ^ 64'h0123_4567_89AB_CDEF, lfsr + 64'h1111_2222_3333_4444};
      kvq_bank_i  = 2'((cyc + 3) & 3);
      kvq_addr_i  = 6'(((cyc + 34) >> 2) & 63);

      // (D) SRAM Controller VLIW/DMA Foreground (closed-loop KVQuant DMA) + SER Upsets
      rd_b  = 2'(cyc & 3);
      rd_a  = 6'((cyc >> 2) & 63);
      wr_b  = 2'((cyc + 1) & 3);
      wr_a  = 6'(((cyc + 17) >> 2) & 63);
      dma_b = 2'((cyc + 2) & 3);
      dma_a = 6'(((cyc + 33) >> 2) & 63);

      sc_vliw_rd_en_i   = 1'b1;
      sc_vliw_rd_bank_i = rd_b;
      sc_vliw_rd_addr_i = rd_a;
      sc_vliw_wr_en_i   = ((cyc & 1) == 0);
      sc_vliw_wr_bank_i = wr_b;
      sc_vliw_wr_addr_i = wr_a;
      sc_vliw_wr_data_i = adv_vec;
      sc_dma_wr_en_i    = ((cyc & 3) == 1);
      sc_dma_wr_bank_i  = dma_b;
      sc_dma_wr_addr_i  = dma_a;
      sc_dma_wr_data_i  = kvq_valid_o ? kvq_vec_o : {~lfsr, lfsr};

      ser_b = sc_scrub_bank_o;
      ser_a = sc_scrub_addr_o;
      if (((cyc % 80) == 15) && !unhealed_ser[ser_b][ser_a] &&
          !(sc_vliw_wr_en_i && sc_vliw_wr_bank_i == ser_b && sc_vliw_wr_addr_i == ser_a) &&
          !(sc_dma_wr_en_i  && sc_dma_wr_bank_i  == ser_b && sc_dma_wr_addr_i  == ser_a) &&
          !sc_scrub_wb_o) begin
        sc_ser_en_i   = 1'b1;
        sc_ser_bank_i = ser_b;
        sc_ser_addr_i = ser_a;
        sc_ser_mask_i = (144'd1 << (cyc % 144));
        ser_injected_cnt++;
      end else begin
        sc_ser_en_i   = 1'b0;
        sc_ser_mask_i = '0;
      end

      // (E) MXFP8 / NVFP4 / W4A8 Dot Engine Stress (closed-loop fed by C2C KV Quantizer)
      dot_valid_i     = 1'b1;
      dot_mode_i      = 3'(cyc % 5);
      dot_acc_clr_i   = ((cyc & 15) == 0);
      dot_act_scale_i = ((cyc & 63) == 63) ? 8'd0 : (kvq_valid_o ? kvq_scale_o : 8'd127);
      dot_wt_scale_i  = 8'd127;
      dot_act_i       = kvq_valid_o ? kvq_vec_o : {lfsr, lfsr ^ 64'h1234_5678_9ABC_DEF0};
      dot_wt_i        = {~lfsr, lfsr};

      // (F) PCS 64B/66B Loopback + Live CRC-16 Injection every 300 cycles (~1,667 errors)
      pcs_tx_val_i = pcs_tx_rdy_o;
      pcs_tx_dat_i = {32'(cyc), 32'(~cyc), lfsr};
      if (pcs_tx_rdy_o && ((cyc % 300) == 100)) begin
        pcs_err_inj_en   = 1'b1;
        pcs_err_inj_mask = 16'h0001 << (cyc & 15);
        crc16_injected_cnt++;
      end else begin
        pcs_err_inj_en   = 1'b0;
      end

      // (G) MXM, SXM & VXM Spatial Compute Slices
      mxm_bg_en    = 1'b1;
      mxm_bg_row   = cyc[3:0];
      mxm_bg_dat   = adv_vec ^ {16{8'h80}};
      mxm_prec     = (cyc % 3 == 0) ? PREC_INT8 : ((cyc % 3 == 1) ? PREC_FP8_E4M3 : PREC_FP16);
      mxm_op       = ((cyc & 15) == 0) ? MXM_SWAP_WEIGHT : MXM_SYSTOLIC_EXEC;
      mxm_act_val  = ((cyc & 15) != 0);
      mxm_act_dat  = adv_vec;
      mxm_acc_clr  = ((cyc & 31) == 31);

      sxm_in_val   = 1'b1;
      sxm_in_dat   = adv_vec;
      sxm_tidx     = cyc[3:0];
      sxm_bfly     = cyc[3:0] ^ 4'h5;
      sxm_rope_neg = cyc[0];
      sxm_op       = (cyc % 3 == 0) ? SXM_TRANSPOSE_LOAD :
                     ((cyc % 3 == 1) ? SXM_TRANSPOSE_READ : SXM_BUTTERFLY_SWAP);

      vxm_val      = 1'b1;
      vxm_sa       = adv_vec;
      vxm_sb       = ~adv_vec;
      vxm_sc       = {16{8'(cyc[7:0])}};
      vxm_op       = (cyc % 3 == 0) ? VXM_SWIGLU :
                     ((cyc % 3 == 1) ? VXM_REDUCE_SUM : VXM_REDUCE_MAX);

      @(posedge clk);
    end

    $display("================================================================================");
    $display("STAGE 29 500,000-CYCLE 9-SUBSYSTEM ULTRA-ENDURANCE SOAK SIMULATION SUMMARY");
    $display("================================================================================");
    $display("Total Consecutive Cycles Executed : %0d", TOTAL_CYCLES);
    $display("Total Subsystems Verified         : 9 (spec, droop, sram, dot, pcs, kv_quant, mxm, sxm, vxm)");
    $display("Total Invariant Checks Verified   : %0d (spec=%0d droop=%0d sram=%0d dot=%0d pcs=%0d kvq=%0d mxm=%0d sxm=%0d vxm=%0d)",
             total_checks, spec_checks, droop_checks, sram_checks, dot_checks, pcs_checks, kvq_checks, mxm_checks, sxm_checks, vxm_checks);
    $display("Total Invariant Errors Detected   : %0d", err_cnt);
    $display("Power Droop Peak |di/dt|          : Mitigated=%0d vs Unmitigated=%0d (-%0d%%)",
             max_mit_didt, max_unmit_didt, ((max_unmit_didt - max_mit_didt) * 100) / max_unmit_didt);
    $display("Power Droop Minimum VDD (mV)      : Mitigated=%0d mV vs Unmitigated=%0d mV (thresh=620 mV)",
             min_mit_vdd_mv, min_unmit_vdd_mv);
    $display("SRAM SER Single-Bit Upsets        : Injected=%0d | Background Scrub Healed=%0d | DED=%0d",
             ser_injected_cnt, sc_scrub_cnt_o, sc_scrub_ded_o);
    $display("C2C PCS CRC-16 Link Errors        : Injected=%0d | Go-Back-N Replays=%0d",
             crc16_injected_cnt, gbn_replays_cnt);
    $display("C2C KV-Cache Quantizer Blocks     : Verified=%0d | NaN/Inf Clamped=%0d",
             kvq_checks, kvq_clamped_cnt);
    $display("================================================================================");
    if (err_cnt != 0 || total_checks < 4500000 || ser_injected_cnt < 2500 || crc16_injected_cnt < 1000) begin
      $fatal(1, "STAGE 29 500,000-CYCLE SOAK TEST FAILED!");
    end
    $display("STAGE 29 500,000-CYCLE 9-SUBSYSTEM SOAK TEST PASSED WITH 0 ERRORS!");
    $finish(0);
  end
endmodule
