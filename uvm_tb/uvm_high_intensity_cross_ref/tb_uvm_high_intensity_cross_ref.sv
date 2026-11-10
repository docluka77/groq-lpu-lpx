// =============================================================================
// File: uvm_tb/uvm_high_intensity_cross_ref/tb_uvm_high_intensity_cross_ref.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-Level Accellera IEEE 1800.2-2020 UVM Testbench Instantiating
//              6 Core RTL Subsystems in Lockstep against C++17 DPI-C Master Ref
// =============================================================================
`timescale 1ns/1ps

module tb_uvm_high_intensity_cross_ref;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import groq_pkg::*;
  import uvm_high_intensity_cross_ref_pkg::*;

  logic clk = 1'b0;
  always #5ns clk = ~clk;

  high_intensity_cross_ref_if vif (clk);
  wire rst_n = vif.rst_n;

  // 1. groq_sxm_slice
  groq_sxm_slice u_sxm (
    .clk                (clk),
    .rst_n              (rst_n),
    .sxm_op_i           (vif.sxm_op_i),
    .shift_amt_i        (vif.sxm_shift_amt_i),
    .src_lane_i         (vif.sxm_src_lane_i),
    .butterfly_mask_i   (vif.sxm_butterfly_mask_i),
    .transpose_idx_i    (vif.sxm_transpose_idx_i),
    .rope_neg_even_en_i (vif.sxm_rope_neg_even_en_i),
    .stream_in_valid_i  (vif.sxm_in_valid_i),
    .stream_in_data_i   (vif.sxm_in_data_i),
    .stream_out_valid_o (vif.sxm_out_valid_o),
    .stream_out_data_o  (vif.sxm_out_data_o),
    .perm_comb_data_o   (vif.sxm_perm_comb_o)
  );

  // 2. groq_vxm_slice
  groq_vxm_slice u_vxm (
    .clk                 (clk),
    .rst_n               (rst_n),
    .op_valid_i          (vif.vxm_op_valid_i),
    .vxm_op_i            (vif.vxm_op_i),
    .prec_mode_i         (vif.vxm_prec_mode_i),
    .quant_shift_i       (vif.vxm_quant_shift_i),
    .use_accum_32b_i     (vif.vxm_use_accum_32b_i),
    .stream_a_i          (vif.vxm_stream_a_i),
    .stream_b_i          (vif.vxm_stream_b_i),
    .stream_c_i          (vif.vxm_stream_c_i),
    .accum_32b_in_i      (vif.vxm_accum_32b_in_i),
    .stream_out_valid_o  (vif.vxm_out_valid_o),
    .stream_out_data_o   (vif.vxm_out_data_o),
    .accum_32b_out_o     (vif.vxm_accum_32b_out_o),
    .vxm_comb_data_o     (vif.vxm_comb_data_o),
    .reduce_sum_scalar_o (vif.vxm_reduce_sum_o),
    .reduce_max_scalar_o (vif.vxm_reduce_max_o),
    .mul_gate_active_o   (vif.vxm_mul_gate_o),
    .lut_gate_active_o   (vif.vxm_lut_gate_o)
  );

  // 3. groq_nim_realsync
  groq_nim_realsync u_nim (
    .clk                            (clk),
    .rst_n                          (rst_n),
    .op_valid_i                     (vif.nim_op_valid_i),
    .nim_op_i                       (vif.nim_op_i),
    .realsync_aligned_time_i        (vif.nim_realsync_time_i),
    .expected_flight_cycles_i       (vif.nim_flight_cycles_i),
    .local_chip_id_i                (vif.nim_local_chip_id_i),
    .tx_dst_chip_i                  (vif.nim_tx_dst_chip_i),
    .ugal_nonminimal_en_i           (vif.nim_ugal_en_i),
    .link_congested_i               (vif.nim_link_congested_i),
    .local_stream_in_valid_i        (vif.nim_loc_in_valid_i),
    .local_stream_in_data_i         (vif.nim_loc_in_data_i),
    .local_stream_out_valid_o       (vif.nim_loc_out_valid_o),
    .local_stream_out_data_o        (vif.nim_loc_out_data_o),
    .c2c_rx_valid_i                 (vif.nim_c2c_rx_valid_i),
    .c2c_rx_data_i                  (vif.nim_c2c_rx_data_i),
    .c2c_rx_tx_timestamp_i          (vif.nim_c2c_rx_ts_i),
    .c2c_rx_dst_chip_i              (vif.nim_c2c_rx_dst_i),
    .c2c_rx_crc8_i                  (vif.nim_c2c_rx_crc8_i),
    .c2c_tx_valid_o                 (vif.nim_c2c_tx_valid_o),
    .c2c_tx_data_o                  (vif.nim_c2c_tx_data_o),
    .c2c_tx_timestamp_o             (vif.nim_c2c_tx_ts_o),
    .c2c_tx_dst_chip_o              (vif.nim_c2c_tx_dst_o),
    .c2c_tx_crc8_o                  (vif.nim_c2c_tx_crc8_o),
    .c2c_tx_port_sel_o              (vif.nim_c2c_tx_port_o),
    .deskew_release_valid_o         (vif.nim_deskew_rel_valid_o),
    .deskew_released_target_cycle_o (vif.nim_deskew_rel_target_o),
    .realsync_ping_ack_o            (vif.nim_ping_ack_o),
    .measured_skew_o                (vif.nim_measured_skew_o),
    .crc_err_o                      (vif.nim_crc_err_o)
  );
  // 4. groq_mxfp8_nvfp4_dot_engine
  groq_mxfp8_nvfp4_dot_engine u_dot (
    .clk                  (clk),
    .rst_n                (rst_n),
    .valid_i              (vif.dot_valid_i),
    .mode_i               (vif.dot_mode_i),
    .zero_skip_en_i       (vif.dot_zero_skip_en_i),
    .accum_en_i           (vif.dot_accum_en_i),
    .accum_clear_i        (vif.dot_accum_clear_i),
    .act_scale_e8m0_i     (vif.dot_act_scale_i),
    .wt_scale_e8m0_i      (vif.dot_wt_scale_i),
    .act_stream_i         (vif.dot_act_stream_i),
    .wt_stream_i          (vif.dot_wt_stream_i),
    .valid_o              (vif.dot_valid_o),
    .unaccum_dot_o        (vif.dot_unaccum_o),
    .dot_accum_o          (vif.dot_accum_o),
    .dot_fp32_o           (vif.dot_fp32_o),
    .zero_skip_lanes_o    (vif.dot_zero_skip_lanes_o),
    .block_zero_skipped_o (vif.dot_block_zero_skipped_o),
    .nan_inf_flag_o       (vif.dot_nan_inf_flag_o)
  );

  // 5. groq_c2c_kv_quant_rx_engine
  groq_c2c_kv_quant_rx_engine u_kvq (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .valid_i                  (vif.kvq_valid_i),
    .quant_mode_i             (vif.kvq_mode_i),
    .kv_in_lo_i               (vif.kvq_in_lo_i),
    .kv_in_hi_i               (vif.kvq_in_hi_i),
    .target_sram_bank_i       (vif.kvq_bank_i),
    .target_sram_addr_i       (vif.kvq_addr_i),
    .valid_o                  (vif.kvq_valid_o),
    .quant_vec_o              (vif.kvq_quant_vec_o),
    .scale_e8m0_o             (vif.kvq_scale_e8m0_o),
    .sram_wr_en_o             (vif.kvq_sram_wr_en_o),
    .sram_wr_bank_o           (vif.kvq_sram_wr_bank_o),
    .sram_wr_addr_o           (vif.kvq_sram_wr_addr_o),
    .zero_lanes_cnt_o         (vif.kvq_zero_lanes_cnt_o),
    .nan_inf_clamped_o        (vif.kvq_nan_inf_clamped_o),
    .compression_ratio_code_o (vif.kvq_comp_ratio_o)
  );

  // 6. groq_spec_decode_tree_sampler
  groq_spec_decode_tree_sampler u_spec (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .valid_i                (vif.spec_valid_i),
    .op_mode_i              (vif.spec_op_mode_i),
    .logits_i               (vif.spec_logits_i),
    .token_ids_i            (vif.spec_token_ids_i),
    .top_k_i                (vif.spec_top_k_i),
    .inv_temp_i             (vif.spec_inv_temp_i),
    .top_p_thresh_i         (vif.spec_top_p_thresh_i),
    .rng_seed_step_i        (vif.spec_rng_seed_step_i),
    .rng_threshold_i        (vif.spec_rng_threshold_i),
    .tree_parent_idx_i      (vif.spec_tree_parent_idx_i),
    .tree_draft_prob_i      (vif.spec_tree_draft_prob_i),
    .tree_target_prob_i     (vif.spec_tree_target_prob_i),
    .tree_rand_u_i          (vif.spec_tree_rand_u_i),
    .tree_draft_tok_i       (vif.spec_tree_draft_tok_i),
    .bonus_tok_i            (vif.spec_bonus_tok_i),
    .valid_o                (vif.spec_valid_o),
    .selected_token_o       (vif.spec_selected_token_o),
    .selected_logit_o       (vif.spec_selected_logit_o),
    .sorted_logits_o        (vif.spec_sorted_logits_o),
    .sorted_tokens_o        (vif.spec_sorted_tokens_o),
    .nucleus_mask_o         (vif.spec_nucleus_mask_o),
    .accepted_node_mask_o   (vif.spec_accepted_node_mask_o),
    .best_leaf_idx_o        (vif.spec_best_leaf_idx_o),
    .accepted_draft_len_o   (vif.spec_accepted_draft_len_o),
    .total_emitted_tokens_o (vif.spec_total_emitted_tokens_o),
    .committed_tokens_o     (vif.spec_committed_tokens_o),
    .kv_ring_advance_o      (vif.spec_kv_ring_advance_o),
    .prng_state_o           (vif.spec_prng_state_o)
  );

  initial begin
    int fault_arg = 0;
    void'($value$plusargs("INJECT_FAULT=%d", fault_arg));
    vif.inject_fault = (fault_arg != 0);
    uvm_config_db#(virtual high_intensity_cross_ref_if)::set(null, "*", "vif", vif);
    run_test("high_intensity_cross_ref_test");
  end

  initial begin
    #2000ms;
    $fatal(1, "UVM_HIGH_INTENSITY_TIMEOUT");
  end
endmodule : tb_uvm_high_intensity_cross_ref
