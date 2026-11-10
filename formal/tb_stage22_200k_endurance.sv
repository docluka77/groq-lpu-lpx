// =============================================================================
// File: formal/tb_stage22_200k_endurance.sv
// Description: Stage 22 200,000-Cycle Full-System Phase-III Endurance Stress
//              Simulation (Verilator 5.054). Simultaneously stresses:
//              1) groq_spec_decode_tree_sampler (Bitonic 16, Top-K/P, 8-Node Tree)
//              2) groq_power_droop_controller (Mitigated vs. Unmitigated RLC/di/dt)
//              3) groq_sram_controller_scrubber (1,000+ SER upsets, eFuse, 0-stall)
//              4) groq_mxfp8_nvfp4_dot_engine (MXFP8/NVFP4/W4A8 + zero-skip)
//              5) groq_c2c_serdes_pcs (TX/RX loopback, 500+ CRC-16 + GBN replay)
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"

module tb_stage22_200k_endurance;
 import groq_pkg::*;

 localparam int TOTAL_CYCLES = 200000;

 logic clk = 1'b0;
 logic rst_n = 1'b0;
 always #0.5 clk = ~clk;

 // ---------------------------------------------------------------------------
 // 1. Speculative Decoding Tree & Top-K/Top-P Nucleus Sampler Instance
 // ---------------------------------------------------------------------------
 logic sd_valid_i, sd_rng_step_i, sd_valid_o;
 logic [1:0] sd_op_mode_i;
 logic [127:0] sd_logits_i, sd_token_ids_i, sd_sorted_logits_o, sd_sorted_tokens_o;
 logic [3:0] sd_top_k_i;
 logic [7:0] sd_inv_temp_i, sd_rng_thresh_i, sd_bonus_tok_i;
 logic [15:0] sd_top_p_i, sd_nucleus_mask_o;
 logic [23:0] sd_tree_parent_i;
 logic [63:0] sd_tree_dprob_i, sd_tree_tprob_i, sd_tree_rand_i, sd_tree_dtok_i;
 logic [7:0] sd_sel_tok_o, sd_sel_logit_o, sd_acc_mask_o;
 logic [2:0] sd_best_leaf_o, sd_acc_len_o, sd_emit_cnt_o, sd_kv_adv_o;
 logic [39:0] sd_commit_toks_o;
 logic [31:0] sd_prng_o;

 groq_spec_decode_tree_sampler u_spec_decode (
 .clk (clk),
 .rst_n (rst_n),
 .valid_i (sd_valid_i),
 .op_mode_i (sd_op_mode_i),
 .logits_i (sd_logits_i),
 .token_ids_i (sd_token_ids_i),
 .top_k_i (sd_top_k_i),
 .inv_temp_i (sd_inv_temp_i),
 .top_p_thresh_i (sd_top_p_i),
 .rng_seed_step_i (sd_rng_step_i),
 .rng_threshold_i (sd_rng_thresh_i),
 .tree_parent_idx_i (sd_tree_parent_i),
 .tree_draft_prob_i (sd_tree_dprob_i),
 .tree_target_prob_i (sd_tree_tprob_i),
 .tree_rand_u_i (sd_tree_rand_i),
 .tree_draft_tok_i (sd_tree_dtok_i),
 .bonus_tok_i (sd_bonus_tok_i),
 .valid_o (sd_valid_o),
 .selected_token_o (sd_sel_tok_o),
 .selected_logit_o (sd_sel_logit_o),
 .sorted_logits_o (sd_sorted_logits_o),
 .sorted_tokens_o (sd_sorted_tokens_o),
 .nucleus_mask_o (sd_nucleus_mask_o),
 .accepted_node_mask_o (sd_acc_mask_o),
 .best_leaf_idx_o (sd_best_leaf_o),
 .accepted_draft_len_o (sd_acc_len_o),
 .total_emitted_tokens_o (sd_emit_cnt_o),
 .committed_tokens_o (sd_commit_toks_o),
 .kv_ring_advance_o (sd_kv_adv_o),
 .prng_state_o (sd_prng_o)
 );

 // ---------------------------------------------------------------------------
 // 2. Power Droop Controller (Mitigated vs. Shadow Unmitigated Baseline)
 // ---------------------------------------------------------------------------
 logic pdc_prewarm_i;
 logic [7:0] pdc_slice_act_i, pdc_prewarm_lvl_i, pdc_max_step_i;
 logic [5:0] pdc_zskip_i;
 logic [7:0] pdc_raw_o, pdc_eff_o, pdc_bleed_o, pdc_bmask_o, pdc_temp_o;
 logic signed [8:0] pdc_didt_o;
 logic [11:0] pdc_vdd_o;
 logic pdc_emerg_o;
 logic [15:0] pdc_events_o;

 logic [7:0] unmit_raw_o, unmit_eff_o, unmit_bleed_o, unmit_bmask_o, unmit_temp_o;
 logic signed [8:0] unmit_didt_o;
 logic [11:0] unmit_vdd_o;
 logic unmit_emerg_o;
 logic [15:0] unmit_events_o;

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
    .clk                       (clk),
    .rst_n                     (rst_n),
    .efuse_load_req_i          (sc_efuse_req_i),
    .efuse_bank_i              (sc_efuse_bank_i),
    .efuse_bad_addr_i          (sc_efuse_addr_i),
    .bank_repair_en_o          (sc_repair_en_o),
    .bank_repair_addr_o        (sc_repair_addr_o),
    .efuse_load_ack_o          (sc_efuse_ack_o),
    .vliw_rd_en_i              (sc_vliw_rd_en_i),
    .vliw_rd_bank_i            (sc_vliw_rd_bank_i),
    .vliw_rd_addr_i            (sc_vliw_rd_addr_i),
    .vliw_rd_valid_o           (sc_vliw_rd_val_o),
    .vliw_rd_data_o            (sc_vliw_rd_data_o),
    .vliw_rd_sec_err_o         (sc_vliw_sec_o),
    .vliw_rd_ded_err_o         (sc_vliw_ded_o),
    .vliw_rd_repaired_row_hit_o(sc_vliw_repaired_hit_o),
    .vliw_wr_en_i              (sc_vliw_wr_en_i),
    .vliw_wr_bank_i            (sc_vliw_wr_bank_i),
    .vliw_wr_addr_i            (sc_vliw_wr_addr_i),
    .vliw_wr_data_i            (sc_vliw_wr_data_i),
    .dma_wr_en_i               (sc_dma_wr_en_i),
    .dma_wr_bank_i             (sc_dma_wr_bank_i),
    .dma_wr_addr_i             (sc_dma_wr_addr_i),
    .dma_wr_data_i             (sc_dma_wr_data_i),
    .scrub_enable_i            (sc_scrub_en_i),
    .scrub_rd_fire_o           (sc_scrub_rd_o),
    .scrub_wb_fire_o           (sc_scrub_wb_o),
    .scrub_active_bank_o       (sc_scrub_bank_o),
    .scrub_active_addr_o       (sc_scrub_addr_o),
    .scrub_corrected_cnt_o     (sc_scrub_cnt_o),
    .scrub_ded_alert_o         (sc_scrub_ded_o),
    .first_ded_bank_o          (sc_ded_bank_o),
    .first_ded_addr_o          (sc_ded_addr_o),
    .ser_inject_en_i           (sc_ser_en_i),
    .ser_inject_bank_i         (sc_ser_bank_i),
    .ser_inject_addr_i         (sc_ser_addr_i),
    .ser_inject_mask_i         (sc_ser_mask_i)
  );

  // ---------------------------------------------------------------------------
  // 4. MXFP8 / NVFP4 / W4A8 Microscaling Dot-Product Engine Instance
  // ---------------------------------------------------------------------------
  logic         dot_valid_i, dot_zskip_en_i, dot_acc_en_i, dot_acc_clr_i;
  logic [2:0]   dot_mode_i;
  logic [7:0]   dot_act_scale_i, dot_wt_scale_i;
  logic [127:0] dot_act_i, dot_wt_i;
  logic         dot_valid_o, dot_bzero_o, dot_nan_o;
  logic signed [31:0] dot_unaccum_o, dot_accum_o;
  logic [31:0]  dot_fp32_o;
  logic [5:0]   dot_zlanes_o;

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
  // 6. Shadow Golden State, Telemetry Counters & Every-Cycle Invariant Checkers
  // ---------------------------------------------------------------------------
  logic [127:0] gold_sram [0:3][0:63];
  bit           unhealed_ser [0:3][0:63];
  logic         prev_rd_en_q;
  logic [1:0]   prev_rd_bank_q;
  logic [5:0]   prev_rd_addr_q;
  logic [127:0] expected_rd_data_q;
  logic [7:0]   prev_pdc_eff_q;
  logic [127:0] pcs_sent_table [0:15];

  int err_cnt            = 0;
  int total_checks       = 0;
  int spec_checks        = 0;
  int droop_checks       = 0;
  int sram_checks        = 0;
  int dot_checks         = 0;
  int pcs_checks         = 0;
  int ser_injected_cnt   = 0;
  int crc16_injected_cnt = 0;
  int gbn_replays_cnt    = 0;

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
    end else begin
      prev_rd_en_q       <= sc_vliw_rd_en_i;
      prev_rd_bank_q     <= sc_vliw_rd_bank_i;
      prev_rd_addr_q     <= sc_vliw_rd_addr_i;
      expected_rd_data_q <= gold_sram[sc_vliw_rd_bank_i][sc_vliw_rd_addr_i];
      prev_pdc_eff_q     <= pdc_eff_o;

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

  // Continuous Every-Cycle Self-Checking Monitor across all 5 Subsystems
  always @(posedge clk) begin
    if (rst_n) begin
      // (1) Speculative Decode Tree & Bitonic 16-Lane Sampler Checks (2 checks/cycle)
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
        spec_checks  += 2;
        total_checks += 2;
      end

      // (2) Power Droop Controller Checks & Peak di/dt / Min VDD Telemetry (2 checks/cycle)
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
        droop_checks += 2;
        total_checks += 2;
      end

      // (3) SRAM Controller Zero-Contention & SECDED Readback Exactness (2 checks/cycle)
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
        sram_checks  += 2;
        total_checks += 2;
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
    end
  end

  // ---------------------------------------------------------------------------
  // 7. 200,000-Cycle Randomized Adversarial Stimulus Generator
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

    // Main 200,000-Cycle Adversarial Endurance Loop
    for (int cyc = 0; cyc < TOTAL_CYCLES; cyc++) begin
      int phase32;
      logic [1:0] wr_b, rd_b, dma_b, ser_b;
      logic [5:0] wr_a, rd_a, dma_a, ser_a;

      lfsr = {lfsr[62:0], lfsr[63] ^ lfsr[61] ^ lfsr[60] ^ lfsr[58]} + 64'h9E37_79B9_7F4A_7C15;
      phase32 = cyc & 31;

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
        pdc_slice_act_i = 8'b0010_0000; // ICU active (12), pre-warm ramps up to 200
        pdc_zskip_i     = 6'd0;
      end else if (phase32 < 16) begin
        pdc_prewarm_i   = 1'b0;
        pdc_slice_act_i = 8'b1111_1110; // Full MXM_W/E + VXM + SXM + MEM_W/E + ICU (212)
        pdc_zskip_i     = 6'd8;
      end else begin
        pdc_prewarm_i   = 1'b0;
        pdc_slice_act_i = 8'b0010_0000; // Post-burst bleeder ramp-down
        pdc_zskip_i     = 6'd16;
      end

      // (C) SRAM Controller VLIW/DMA Foreground + 2,000 SER Upsets + Scrubber
      rd_b  = 2'(cyc & 3);
      rd_a  = 6'((cyc >> 2) & 63);
      wr_b  = 2'((cyc + 1) & 3);
      wr_a  = 6'(((cyc + 17) >> 2) & 63);
      dma_b = 2'((cyc + 2) & 3);
      dma_a = 6'(((cyc + 33) >> 2) & 63);
      // Note: bank (cyc+3)&3 is left free every cycle for zero-stall background scrubbing!

      sc_vliw_rd_en_i   = 1'b1;
      sc_vliw_rd_bank_i = rd_b;
      sc_vliw_rd_addr_i = rd_a;

      sc_vliw_wr_en_i   = ((cyc & 1) == 0);
      sc_vliw_wr_bank_i = wr_b;
      sc_vliw_wr_addr_i = wr_a;
      sc_vliw_wr_data_i = {lfsr, lfsr ^ 64'hA5A5_5A5A_F0F0_0F0F};

      sc_dma_wr_en_i    = ((cyc & 3) == 1);
      sc_dma_wr_bank_i  = dma_b;
      sc_dma_wr_addr_i  = dma_a;
      sc_dma_wr_data_i  = {~lfsr, lfsr};

      // Inject 1-bit SER upset on the currently scrubbed bank/addr right before scrubber reads it
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

      // (D) MXFP8 / NVFP4 / W4A8 Dot Engine Stress
      dot_valid_i     = 1'b1;
      dot_mode_i      = 3'(cyc % 5);
      dot_acc_clr_i   = ((cyc & 15) == 0);
      dot_act_scale_i = ((cyc & 63) == 63) ? 8'd0 : 8'd127;
      dot_wt_scale_i  = 8'd127;
      dot_act_i       = {lfsr, lfsr ^ 64'h1234_5678_9ABC_DEF0};
      dot_wt_i        = {~lfsr, lfsr};

      // (E) PCS 64B/66B Loopback + Live CRC-16 Injection every 300 cycles (~666 errors)
      pcs_tx_val_i = pcs_tx_rdy_o;
      pcs_tx_dat_i = {32'(cyc), 32'(~cyc), lfsr};
      if (pcs_tx_rdy_o && ((cyc % 300) == 100)) begin
        pcs_err_inj_en   = 1'b1;
        pcs_err_inj_mask = 16'h0001 << (cyc & 15);
        crc16_injected_cnt++;
      end else begin
        pcs_err_inj_en   = 1'b0;
      end

      @(posedge clk);
    end

    $display("================================================================================");
    $display("STAGE 22 200,000-CYCLE FULL-SYSTEM PHASE-III ENDURANCE STRESS SIMULATION SUMMARY");
    $display("================================================================================");
    $display("Total Consecutive Cycles Executed : %0d", TOTAL_CYCLES);
    $display("Total Invariant Checks Verified   : %0d (spec=%0d droop=%0d sram=%0d dot=%0d pcs=%0d)",
             total_checks, spec_checks, droop_checks, sram_checks, dot_checks, pcs_checks);
    $display("Total Invariant Errors Detected   : %0d", err_cnt);
    $display("Power Droop Peak |di/dt|          : Mitigated=%0d vs Unmitigated=%0d (-%0d%%)",
             max_mit_didt, max_unmit_didt, ((max_unmit_didt - max_mit_didt) * 100) / max_unmit_didt);
    $display("Power Droop Minimum VDD (mV)      : Mitigated=%0d mV vs Unmitigated=%0d mV (thresh=620 mV)",
             min_mit_vdd_mv, min_unmit_vdd_mv);
    $display("SRAM SER Single-Bit Upsets        : Injected=%0d | Background Scrub Healed=%0d | DED=%0d",
             ser_injected_cnt, sc_scrub_cnt_o, sc_scrub_ded_o);
    $display("C2C PCS CRC-16 Link Errors        : Injected=%0d | Go-Back-N Replays=%0d",
             crc16_injected_cnt, gbn_replays_cnt);
    $display("================================================================================");
    if (err_cnt != 0 || total_checks < 1200000 || ser_injected_cnt < 1000 || crc16_injected_cnt < 500) begin
      $fatal(1, "STAGE 22 ENDURANCE STRESS FAILED!");
    end
    $display("STAGE 22 200,000-CYCLE ENDURANCE STRESS PASSED WITH 0 ERRORS!");
    $finish(0);
  end
endmodule
