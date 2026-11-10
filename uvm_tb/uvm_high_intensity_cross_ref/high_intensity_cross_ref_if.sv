// =============================================================================
// File: uvm_tb/uvm_high_intensity_cross_ref/high_intensity_cross_ref_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface for UVM Suite 10 (6-DUT Lockstep Cross-Ref)
// =============================================================================
`ifndef HIGH_INTENSITY_CROSS_REF_IF_SV
`define HIGH_INTENSITY_CROSS_REF_IF_SV

interface high_intensity_cross_ref_if (
  input logic clk
);
  logic        rst_n        = 1'b0;
  logic        inject_fault = 1'b0;
  logic        sample_en    = 1'b0;
  int unsigned tx_id        = 0;

  // 1. groq_sxm_slice signals
  logic [3:0]   sxm_op_i;
  logic [3:0]   sxm_shift_amt_i;
  logic [3:0]   sxm_src_lane_i;
  logic [3:0]   sxm_butterfly_mask_i;
  logic [3:0]   sxm_transpose_idx_i;
  logic         sxm_rope_neg_even_en_i;
  logic         sxm_in_valid_i;
  logic [127:0] sxm_in_data_i;
  logic         sxm_out_valid_o;
  logic [127:0] sxm_out_data_o;
  logic [127:0] sxm_perm_comb_o;

  // 2. groq_vxm_slice signals
  logic         vxm_op_valid_i;
  logic [3:0]   vxm_op_i;
  logic [3:0]   vxm_prec_mode_i;
  logic [2:0]   vxm_quant_shift_i;
  logic         vxm_use_accum_32b_i;
  logic [127:0] vxm_stream_a_i;
  logic [127:0] vxm_stream_b_i;
  logic [127:0] vxm_stream_c_i;
  logic [511:0] vxm_accum_32b_in_i;
  logic         vxm_out_valid_o;
  logic [127:0] vxm_out_data_o;
  logic [511:0] vxm_accum_32b_out_o;
  logic [127:0] vxm_comb_data_o;
  logic signed [15:0] vxm_reduce_sum_o;
  logic signed [7:0]  vxm_reduce_max_o;
  logic         vxm_mul_gate_o;
  logic         vxm_lut_gate_o;

  // 3. groq_nim_realsync signals
  logic         nim_op_valid_i;
  logic [3:0]   nim_op_i;
  logic [15:0]  nim_realsync_time_i;
  logic [15:0]  nim_flight_cycles_i;
  logic [3:0]   nim_local_chip_id_i;
  logic [3:0]   nim_tx_dst_chip_i;
  logic         nim_ugal_en_i;
  logic         nim_link_congested_i;
  logic         nim_loc_in_valid_i;
  logic [127:0] nim_loc_in_data_i;
  logic         nim_c2c_rx_valid_i;
  logic [127:0] nim_c2c_rx_data_i;
  logic [15:0]  nim_c2c_rx_ts_i;
  logic [3:0]   nim_c2c_rx_dst_i;
  logic [7:0]   nim_c2c_rx_crc8_i;
  logic         nim_loc_out_valid_o;
  logic [127:0] nim_loc_out_data_o;
  logic         nim_c2c_tx_valid_o;
  logic [127:0] nim_c2c_tx_data_o;
  logic [15:0]  nim_c2c_tx_ts_o;
  logic [3:0]   nim_c2c_tx_dst_o;
  logic [7:0]   nim_c2c_tx_crc8_o;
  logic [1:0]   nim_c2c_tx_port_o;
  logic         nim_deskew_rel_valid_o;
  logic [15:0]  nim_deskew_rel_target_o;
  logic         nim_ping_ack_o;
  logic signed [15:0] nim_measured_skew_o;
  logic         nim_crc_err_o;
  // 4. groq_mxfp8_nvfp4_dot_engine signals
  logic         dot_valid_i;
  logic [2:0]   dot_mode_i;
  logic         dot_zero_skip_en_i;
  logic         dot_accum_en_i;
  logic         dot_accum_clear_i;
  logic [7:0]   dot_act_scale_i;
  logic [7:0]   dot_wt_scale_i;
  logic [127:0] dot_act_stream_i;
  logic [127:0] dot_wt_stream_i;
  logic         dot_valid_o;
  logic signed [31:0] dot_unaccum_o;
  logic signed [31:0] dot_accum_o;
  logic [31:0]  dot_fp32_o;
  logic [5:0]   dot_zero_skip_lanes_o;
  logic         dot_block_zero_skipped_o;
  logic         dot_nan_inf_flag_o;

  // 5. groq_c2c_kv_quant_rx_engine signals
  logic         kvq_valid_i;
  logic [1:0]   kvq_mode_i;
  logic [127:0] kvq_in_lo_i;
  logic [127:0] kvq_in_hi_i;
  logic [1:0]   kvq_bank_i;
  logic [15:0]  kvq_addr_i;
  logic         kvq_valid_o;
  logic [127:0] kvq_quant_vec_o;
  logic [7:0]   kvq_scale_e8m0_o;
  logic         kvq_sram_wr_en_o;
  logic [1:0]   kvq_sram_wr_bank_o;
  logic [15:0]  kvq_sram_wr_addr_o;
  logic [4:0]   kvq_zero_lanes_cnt_o;
  logic         kvq_nan_inf_clamped_o;
  logic [1:0]   kvq_comp_ratio_o;

  // 6. groq_spec_decode_tree_sampler signals
  logic         spec_valid_i;
  logic [1:0]   spec_op_mode_i;
  logic [127:0] spec_logits_i;
  logic [127:0] spec_token_ids_i;
  logic [3:0]   spec_top_k_i;
  logic [7:0]   spec_inv_temp_i;
  logic [15:0]  spec_top_p_thresh_i;
  logic         spec_rng_seed_step_i;
  logic [7:0]   spec_rng_threshold_i;
  logic [23:0]  spec_tree_parent_idx_i;
  logic [63:0]  spec_tree_draft_prob_i;
  logic [63:0]  spec_tree_target_prob_i;
  logic [63:0]  spec_tree_rand_u_i;
  logic [63:0]  spec_tree_draft_tok_i;
  logic [7:0]   spec_bonus_tok_i;
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

endinterface : high_intensity_cross_ref_if
`endif
