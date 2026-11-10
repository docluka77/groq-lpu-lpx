// =============================================================================
// File: uvm_tb/uvm_spec_power_scrub/spec_power_scrub_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface & DUT Wrapper connecting Accellera
//              IEEE 1800.2-2020 UVM environment to:
//              1) groq_spec_decode_tree_sampler
//              2) groq_power_droop_controller
//              3) groq_sram_controller_scrubber (with groq_sram_ecc_secded)
// =============================================================================
`ifndef SPEC_POWER_SCRUB_IF_SV
`define SPEC_POWER_SCRUB_IF_SV

`include "groq_pkg.sv"

interface spec_power_scrub_if (
  input logic clk
);
  import groq_pkg::*;

  logic        rst_n        = 1'b0;
  logic        inject_fault = 1'b0;
  logic        sample_en    = 1'b0;
  int unsigned tx_id        = 0;
  int unsigned phase_id     = 0;

  // --- 1. groq_spec_decode_tree_sampler Signals ---
  logic         spec_valid_i            = 1'b0;
  logic [1:0]   spec_op_mode_i          = 2'd0;
  logic [127:0] spec_logits_i           = '0;
  logic [127:0] spec_token_ids_i        = '0;
  logic [3:0]   spec_top_k_i            = 4'd0;
  logic [7:0]   spec_inv_temp_i         = 8'd0;
  logic [15:0]  spec_top_p_thresh_i     = 16'd0;
  logic         spec_rng_seed_step_i    = 1'b0;
  logic [7:0]   spec_rng_threshold_i    = 8'd0;
  logic [23:0]  spec_tree_parent_idx_i  = 24'd0;
  logic [63:0]  spec_tree_draft_prob_i  = 64'd0;
  logic [63:0]  spec_tree_target_prob_i = 64'd0;
  logic [63:0]  spec_tree_rand_u_i      = 64'd0;
  logic [63:0]  spec_tree_draft_tok_i   = 64'd0;
  logic [7:0]   spec_bonus_tok_i        = 8'd0;

  logic         spec_valid_o;
  logic [7:0]   spec_selected_token_o;
  logic [7:0]   spec_selected_logit_o;
  logic [127:0] spec_sorted_logits_o;
  logic [127:0] spec_sorted_tokens_o;
  logic [15:0]  spec_nucleus_mask_o;
  logic [7:0]   spec_accepted_node_mask_o;
  logic [2:0]   spec_best_leaf_idx_o;
  logic [2:0]   spec_accepted_draft_len_o;
  logic [2:0]   spec_total_emitted_tokens_o;
  logic [39:0]  spec_committed_tokens_o;
  logic [2:0]   spec_kv_ring_advance_o;
  logic [31:0]  spec_prng_state_o;

  // --- 2. groq_power_droop_controller Signals ---
  logic              pwr_enable_i                = 1'b0;
  logic [7:0]        pwr_slice_active_i          = 8'd0;
  logic [5:0]        pwr_mxm_zero_skip_cnt_i     = 6'd0;
  logic              pwr_prewarm_hint_i          = 1'b0;
  logic [7:0]        pwr_prewarm_target_level_i  = 8'd0;
  logic [7:0]        pwr_max_didt_step_i         = 8'd0;
  logic [11:0]       pwr_vdd_nominal_mv_i        = 12'd850;
  logic [11:0]       pwr_droop_emerg_thresh_mv_i = 12'd760;

  logic [7:0]        pwr_raw_demand_o;
  logic [7:0]        pwr_eff_current_o;
  logic [7:0]        pwr_dummy_bleed_current_o;
  logic [7:0]        pwr_dummy_bleed_mask_o;
  logic signed [8:0] pwr_didt_signed_o;
  logic [11:0]       pwr_vdd_est_mv_o;
  logic [7:0]        pwr_thermal_temp_c_o;
  logic              pwr_emerg_throttle_o;
  logic [15:0]       pwr_droop_mitigated_events_o;

  // --- 3. groq_sram_controller_scrubber Signals (P_ADDR_W = 6) ---
  logic              sram_efuse_load_req_i  = 1'b0;
  logic [1:0]        sram_efuse_bank_i      = 2'd0;
  logic [5:0]        sram_efuse_bad_addr_i  = 6'd0;
  logic              sram_vliw_rd_en_i      = 1'b0;
  logic [1:0]        sram_vliw_rd_bank_i    = 2'd0;
  logic [5:0]        sram_vliw_rd_addr_i    = 6'd0;
  logic              sram_vliw_wr_en_i      = 1'b0;
  logic [1:0]        sram_vliw_wr_bank_i    = 2'd0;
  logic [5:0]        sram_vliw_wr_addr_i    = 6'd0;
  logic [127:0]      sram_vliw_wr_data_i    = '0;
  logic              sram_dma_wr_en_i       = 1'b0;
  logic [1:0]        sram_dma_wr_bank_i     = 2'd0;
  logic [5:0]        sram_dma_wr_addr_i     = 6'd0;
  logic [127:0]      sram_dma_wr_data_i     = '0;
  logic              sram_scrub_enable_i    = 1'b0;
  logic              sram_ser_inject_en_i   = 1'b0;
  logic [1:0]        sram_ser_inject_bank_i = 2'd0;
  logic [5:0]        sram_ser_inject_addr_i = 6'd0;
  logic [143:0]      sram_ser_inject_mask_i = '0;

  logic [3:0]        sram_bank_repair_en_o;
  logic [3:0][5:0]   sram_bank_repair_addr_o;
  logic              sram_efuse_load_ack_o;
  logic              sram_vliw_rd_valid_o;
  logic [127:0]      sram_vliw_rd_data_o;
  logic              sram_vliw_rd_sec_err_o;
  logic              sram_vliw_rd_ded_err_o;
  logic              sram_vliw_rd_repaired_row_hit_o;
  logic              sram_scrub_rd_fire_o;
  logic              sram_scrub_wb_fire_o;
  logic [1:0]        sram_scrub_active_bank_o;
  logic [5:0]        sram_scrub_active_addr_o;
  logic [15:0]       sram_scrub_corrected_cnt_o;
  logic              sram_scrub_ded_alert_o;
  logic [1:0]        sram_first_ded_bank_o;
  logic [5:0]        sram_first_ded_addr_o;
endinterface : spec_power_scrub_if

module spec_power_scrub_dut_wrap (
  spec_power_scrub_if bus
);
  logic [7:0]   raw_spec_selected_token;
  logic [127:0] raw_spec_sorted_logits;
  logic [7:0]   raw_pwr_eff_current;
  logic [11:0]  raw_pwr_vdd_est_mv;
  logic [127:0] raw_sram_vliw_rd_data;
  logic [15:0]  raw_sram_scrub_corrected_cnt;

  groq_spec_decode_tree_sampler #(
    .P_LANES      (16),
    .P_TREE_NODES (8)
  ) u_spec_sampler (
    .clk                    (bus.clk),
    .rst_n                  (bus.rst_n),
    .valid_i                (bus.spec_valid_i),
    .op_mode_i              (bus.spec_op_mode_i),
    .logits_i               (bus.spec_logits_i),
    .token_ids_i            (bus.spec_token_ids_i),
    .top_k_i                (bus.spec_top_k_i),
    .inv_temp_i             (bus.spec_inv_temp_i),
    .top_p_thresh_i         (bus.spec_top_p_thresh_i),
    .rng_seed_step_i        (bus.spec_rng_seed_step_i),
    .rng_threshold_i        (bus.spec_rng_threshold_i),
    .tree_parent_idx_i      (bus.spec_tree_parent_idx_i),
    .tree_draft_prob_i      (bus.spec_tree_draft_prob_i),
    .tree_target_prob_i     (bus.spec_tree_target_prob_i),
    .tree_rand_u_i          (bus.spec_tree_rand_u_i),
    .tree_draft_tok_i       (bus.spec_tree_draft_tok_i),
    .bonus_tok_i            (bus.spec_bonus_tok_i),
    .valid_o                (bus.spec_valid_o),
    .selected_token_o       (raw_spec_selected_token),
    .selected_logit_o       (bus.spec_selected_logit_o),
    .sorted_logits_o        (raw_spec_sorted_logits),
    .sorted_tokens_o        (bus.spec_sorted_tokens_o),
    .nucleus_mask_o         (bus.spec_nucleus_mask_o),
    .accepted_node_mask_o   (bus.spec_accepted_node_mask_o),
    .best_leaf_idx_o        (bus.spec_best_leaf_idx_o),
    .accepted_draft_len_o   (bus.spec_accepted_draft_len_o),
    .total_emitted_tokens_o (bus.spec_total_emitted_tokens_o),
    .committed_tokens_o     (bus.spec_committed_tokens_o),
    .kv_ring_advance_o      (bus.spec_kv_ring_advance_o),
    .prng_state_o           (bus.spec_prng_state_o)
  );

  groq_power_droop_controller u_power_droop (
    .clk                      (bus.clk),
    .rst_n                    (bus.rst_n),
    .enable_i                 (bus.pwr_enable_i),
    .slice_active_i           (bus.pwr_slice_active_i),
    .mxm_zero_skip_cnt_i      (bus.pwr_mxm_zero_skip_cnt_i),
    .prewarm_hint_i           (bus.pwr_prewarm_hint_i),
    .prewarm_target_level_i   (bus.pwr_prewarm_target_level_i),
    .max_didt_step_i          (bus.pwr_max_didt_step_i),
    .vdd_nominal_mv_i         (bus.pwr_vdd_nominal_mv_i),
    .droop_emerg_thresh_mv_i  (bus.pwr_droop_emerg_thresh_mv_i),
    .raw_demand_o             (bus.pwr_raw_demand_o),
    .eff_current_o            (raw_pwr_eff_current),
    .dummy_bleed_current_o    (bus.pwr_dummy_bleed_current_o),
    .dummy_bleed_mask_o       (bus.pwr_dummy_bleed_mask_o),
    .didt_signed_o            (bus.pwr_didt_signed_o),
    .vdd_est_mv_o             (raw_pwr_vdd_est_mv),
    .thermal_temp_c_o         (bus.pwr_thermal_temp_c_o),
    .emerg_throttle_o         (bus.pwr_emerg_throttle_o),
    .droop_mitigated_events_o (bus.pwr_droop_mitigated_events_o)
  );

  groq_sram_controller_scrubber #(
    .P_NUM_BANKS (4),
    .P_BANK_W    (2),
    .P_ADDR_W    (6)
  ) u_sram_scrubber (
    .clk                        (bus.clk),
    .rst_n                      (bus.rst_n),
    .efuse_load_req_i           (bus.sram_efuse_load_req_i),
    .efuse_bank_i               (bus.sram_efuse_bank_i),
    .efuse_bad_addr_i           (bus.sram_efuse_bad_addr_i),
    .bank_repair_en_o           (bus.sram_bank_repair_en_o),
    .bank_repair_addr_o         (bus.sram_bank_repair_addr_o),
    .efuse_load_ack_o           (bus.sram_efuse_load_ack_o),
    .vliw_rd_en_i               (bus.sram_vliw_rd_en_i),
    .vliw_rd_bank_i             (bus.sram_vliw_rd_bank_i),
    .vliw_rd_addr_i             (bus.sram_vliw_rd_addr_i),
    .vliw_rd_valid_o            (bus.sram_vliw_rd_valid_o),
    .vliw_rd_data_o             (raw_sram_vliw_rd_data),
    .vliw_rd_sec_err_o          (bus.sram_vliw_rd_sec_err_o),
    .vliw_rd_ded_err_o          (bus.sram_vliw_rd_ded_err_o),
    .vliw_rd_repaired_row_hit_o (bus.sram_vliw_rd_repaired_row_hit_o),
    .vliw_wr_en_i               (bus.sram_vliw_wr_en_i),
    .vliw_wr_bank_i             (bus.sram_vliw_wr_bank_i),
    .vliw_wr_addr_i             (bus.sram_vliw_wr_addr_i),
    .vliw_wr_data_i             (bus.sram_vliw_wr_data_i),
    .dma_wr_en_i                (bus.sram_dma_wr_en_i),
    .dma_wr_bank_i              (bus.sram_dma_wr_bank_i),
    .dma_wr_addr_i              (bus.sram_dma_wr_addr_i),
    .dma_wr_data_i              (bus.sram_dma_wr_data_i),
    .scrub_enable_i             (bus.sram_scrub_enable_i),
    .scrub_rd_fire_o            (bus.sram_scrub_rd_fire_o),
    .scrub_wb_fire_o            (bus.sram_scrub_wb_fire_o),
    .scrub_active_bank_o        (bus.sram_scrub_active_bank_o),
    .scrub_active_addr_o        (bus.sram_scrub_active_addr_o),
    .scrub_corrected_cnt_o      (raw_sram_scrub_corrected_cnt),
    .scrub_ded_alert_o          (bus.sram_scrub_ded_alert_o),
    .first_ded_bank_o           (bus.sram_first_ded_bank_o),
    .first_ded_addr_o           (bus.sram_first_ded_addr_o),
    .ser_inject_en_i            (bus.sram_ser_inject_en_i),
    .ser_inject_bank_i          (bus.sram_ser_inject_bank_i),
    .ser_inject_addr_i          (bus.sram_ser_inject_addr_i),
    .ser_inject_mask_i          (bus.sram_ser_inject_mask_i)
  );

  assign bus.spec_selected_token_o      = (bus.inject_fault && bus.spec_valid_o)         ? (raw_spec_selected_token ^ 8'hFF)       : raw_spec_selected_token;
  assign bus.spec_sorted_logits_o       = (bus.inject_fault && bus.spec_valid_o)         ? (raw_spec_sorted_logits ^ 128'h1)       : raw_spec_sorted_logits;
  assign bus.pwr_eff_current_o          = (bus.inject_fault)                             ? (raw_pwr_eff_current ^ 8'hFF)           : raw_pwr_eff_current;
  assign bus.pwr_vdd_est_mv_o           = (bus.inject_fault)                             ? (raw_pwr_vdd_est_mv ^ 12'h0FF)          : raw_pwr_vdd_est_mv;
  assign bus.sram_vliw_rd_data_o        = (bus.inject_fault && bus.sram_vliw_rd_valid_o) ? (raw_sram_vliw_rd_data ^ 128'h1)        : raw_sram_vliw_rd_data;
  assign bus.sram_scrub_corrected_cnt_o = (bus.inject_fault)                             ? (raw_sram_scrub_corrected_cnt ^ 16'h01) : raw_sram_scrub_corrected_cnt;

endmodule : spec_power_scrub_dut_wrap

`endif // SPEC_POWER_SCRUB_IF_SV
