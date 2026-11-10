// =============================================================================
// File: uvm_tb/uvm_high_intensity_cross_ref/uvm_high_intensity_cross_ref_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Accellera IEEE 1800.2-2020 UVM Package for Suite 10
//              (50,000 Transactions = 300,000 Lockstep Module Checks across 6 DUTs)
// =============================================================================
`ifndef UVM_HIGH_INTENSITY_CROSS_REF_PKG_SV
`define UVM_HIGH_INTENSITY_CROSS_REF_PKG_SV

package uvm_high_intensity_cross_ref_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import groq_pkg::*;

  // ---------------------------------------------------------------------------
  // 1. C++17 DPI-C Master Golden Reference Model Imports
  // ---------------------------------------------------------------------------
  import "DPI-C" function void         dpi_master_reset();
  import "DPI-C" function int unsigned dpi_get_calls();
  import "DPI-C" function int unsigned dpi_get_module_steps();
  import "DPI-C" function void         dpi_set_status(input int status);
  import "DPI-C" function int          dpi_get_status();

  import "DPI-C" function void dpi_sxm_step(
    input  int unsigned sxm_op_i,
    input  int unsigned shift_amt_i,
    input  int unsigned src_lane_i,
    input  int unsigned butterfly_mask_i,
    input  int unsigned transpose_idx_i,
    input  int unsigned rope_neg_even_en_i,
    input  int unsigned stream_in_valid_i,
    input  bit [127:0]  stream_in_data_i,
    output int unsigned exp_stream_out_valid_o,
    output bit [127:0]  exp_stream_out_data_o,
    output bit [127:0]  exp_perm_comb_data_o
  );

  import "DPI-C" function void dpi_vxm_step(
    input  int unsigned op_valid_i,
    input  int unsigned vxm_op_i,
    input  int unsigned prec_mode_i,
    input  int unsigned quant_shift_i,
    input  int unsigned use_accum_32b_i,
    input  bit [127:0]  stream_a_i,
    input  bit [127:0]  stream_b_i,
    input  bit [127:0]  stream_c_i,
    input  bit [511:0]  accum_32b_in_i,
    output int unsigned exp_stream_out_valid_o,
    output bit [127:0]  exp_stream_out_data_o,
    output bit [511:0]  exp_accum_32b_out_o,
    output bit [127:0]  exp_vxm_comb_data_o,
    output int          exp_reduce_sum_scalar_o,
    output int          exp_reduce_max_scalar_o,
    output int unsigned exp_mul_gate_active_o,
    output int unsigned exp_lut_gate_active_o
  );

  import "DPI-C" function void dpi_nim_step(
    input  int unsigned op_valid_i,
    input  int unsigned nim_op_i,
    input  int unsigned realsync_aligned_time_i,
    input  int unsigned expected_flight_cycles_i,
    input  int unsigned local_chip_id_i,
    input  int unsigned tx_dst_chip_i,
    input  int unsigned ugal_nonminimal_en_i,
    input  int unsigned link_congested_i,
    input  int unsigned local_stream_in_valid_i,
    input  bit [127:0]  local_stream_in_data_i,
    input  int unsigned c2c_rx_valid_i,
    input  bit [127:0]  c2c_rx_data_i,
    input  int unsigned c2c_rx_tx_timestamp_i,
    input  int unsigned c2c_rx_dst_chip_i,
    input  int unsigned c2c_rx_crc8_i,
    output int unsigned exp_local_stream_out_valid_o,
    output bit [127:0]  exp_local_stream_out_data_o,
    output int unsigned exp_c2c_tx_valid_o,
    output bit [127:0]  exp_c2c_tx_data_o,
    output int unsigned exp_c2c_tx_timestamp_o,
    output int unsigned exp_c2c_tx_dst_chip_o,
    output int unsigned exp_c2c_tx_crc8_o,
    output int unsigned exp_c2c_tx_port_sel_o,
    output int unsigned exp_deskew_release_valid_o,
    output int unsigned exp_deskew_released_target_cycle_o,
    output int unsigned exp_realsync_ping_ack_o,
    output int          exp_measured_skew_o,
    output int unsigned exp_crc_err_o
  );
  import "DPI-C" function void dpi_dot_step(
    input  int unsigned valid_i,
    input  int unsigned mode_i,
    input  int unsigned zero_skip_en_i,
    input  int unsigned accum_en_i,
    input  int unsigned accum_clear_i,
    input  int unsigned act_scale_e8m0_i,
    input  int unsigned wt_scale_e8m0_i,
    input  bit [127:0]  act_stream_i,
    input  bit [127:0]  wt_stream_i,
    output int unsigned exp_valid_o,
    output int          exp_unaccum_dot_o,
    output int          exp_dot_accum_o,
    output int unsigned exp_dot_fp32_o,
    output int unsigned exp_zero_skip_lanes_o,
    output int unsigned exp_block_zero_skipped_o,
    output int unsigned exp_nan_inf_flag_o
  );

  import "DPI-C" function void dpi_kvq_step(
    input  int unsigned valid_i,
    input  int unsigned quant_mode_i,
    input  bit [127:0]  kv_in_lo_i,
    input  bit [127:0]  kv_in_hi_i,
    input  int unsigned target_sram_bank_i,
    input  int unsigned target_sram_addr_i,
    output int unsigned exp_valid_o,
    output bit [127:0]  exp_quant_vec_o,
    output int unsigned exp_scale_e8m0_o,
    output int unsigned exp_sram_wr_en_o,
    output int unsigned exp_sram_wr_bank_o,
    output int unsigned exp_sram_wr_addr_o,
    output int unsigned exp_zero_lanes_cnt_o,
    output int unsigned exp_nan_inf_clamped_o,
    output int unsigned exp_compression_ratio_code_o
  );

  import "DPI-C" function void dpi_spec_step(
    input  int unsigned     valid_i,
    input  int unsigned     op_mode_i,
    input  bit [127:0]      logits_i,
    input  bit [127:0]      token_ids_i,
    input  int unsigned     top_k_i,
    input  int unsigned     inv_temp_i,
    input  int unsigned     top_p_thresh_i,
    input  int unsigned     rng_seed_step_i,
    input  int unsigned     rng_threshold_i,
    input  int unsigned     tree_parent_idx_i,
    input  longint unsigned tree_draft_prob_i,
    input  longint unsigned tree_target_prob_i,
    input  longint unsigned tree_rand_u_i,
    input  longint unsigned tree_draft_tok_i,
    input  int unsigned     bonus_tok_i,
    output int unsigned     exp_valid_o,
    output int unsigned     exp_selected_token_o,
    output int unsigned     exp_selected_logit_o,
    output bit [127:0]      exp_sorted_logits_o,
    output bit [127:0]      exp_sorted_tokens_o,
    output int unsigned     exp_nucleus_mask_o,
    output int unsigned     exp_accepted_node_mask_o,
    output int unsigned     exp_best_leaf_idx_o,
    output int unsigned     exp_accepted_draft_len_o,
    output int unsigned     exp_total_emitted_tokens_o,
    output longint unsigned exp_committed_tokens_o,
    output int unsigned     exp_kv_ring_advance_o,
    output int unsigned     exp_prng_state_o
  );

  // ---------------------------------------------------------------------------
  // 2. UVM Sequence Item (uvm_sequence_item)
  // ---------------------------------------------------------------------------
  class high_intensity_seq_item extends uvm_sequence_item;
    `uvm_object_utils(high_intensity_seq_item)

    int unsigned tx_id;

    // 1. SXM inputs & observed outputs
    bit [3:0]    sxm_op;
    bit [3:0]    sxm_shift_amt;
    bit [3:0]    sxm_src_lane;
    bit [3:0]    sxm_butterfly_mask;
    bit [3:0]    sxm_transpose_idx;
    bit          sxm_rope_neg_even_en;
    bit          sxm_in_valid;
    bit [127:0]  sxm_in_data;
    bit          act_sxm_out_valid;
    bit [127:0]  act_sxm_out_data;
    bit [127:0]  act_sxm_perm_comb;
    // 2. VXM inputs & observed outputs
    bit          vxm_op_valid;
    bit [3:0]    vxm_op;
    bit [3:0]    vxm_prec_mode;
    bit [2:0]    vxm_quant_shift;
    bit          vxm_use_accum_32b;
    bit [127:0]  vxm_stream_a;
    bit [127:0]  vxm_stream_b;
    bit [127:0]  vxm_stream_c;
    bit [511:0]  vxm_accum_32b_in;
    bit          act_vxm_out_valid;
    bit [127:0]  act_vxm_out_data;
    bit [511:0]  act_vxm_accum_32b_out;
    bit [127:0]  act_vxm_comb_data;
    shortint     act_vxm_reduce_sum;
    byte         act_vxm_reduce_max;
    bit          act_vxm_mul_gate;
    bit          act_vxm_lut_gate;

    // 3. NIM inputs & observed outputs
    bit          nim_op_valid;
    bit [3:0]    nim_op;
    bit [15:0]   nim_realsync_time;
    bit [15:0]   nim_flight_cycles;
    bit [3:0]    nim_local_chip_id;
    bit [3:0]    nim_tx_dst_chip;
    bit          nim_ugal_en;
    bit          nim_link_congested;
    bit          nim_loc_in_valid;
    bit [127:0]  nim_loc_in_data;
    bit          nim_c2c_rx_valid;
    bit [127:0]  nim_c2c_rx_data;
    bit [15:0]   nim_c2c_rx_ts;
    bit [3:0]    nim_c2c_rx_dst;
    bit [7:0]    nim_c2c_rx_crc8;
    bit          act_nim_loc_out_valid;
    bit [127:0]  act_nim_loc_out_data;
    bit          act_nim_c2c_tx_valid;
    bit [127:0]  act_nim_c2c_tx_data;
    bit [15:0]   act_nim_c2c_tx_ts;
    bit [3:0]    act_nim_c2c_tx_dst;
    bit [7:0]    act_nim_c2c_tx_crc8;
    bit [1:0]    act_nim_c2c_tx_port;
    bit          act_nim_deskew_rel_valid;
    bit [15:0]   act_nim_deskew_rel_target;
    bit          act_nim_ping_ack;
    shortint     act_nim_measured_skew;
    bit          act_nim_crc_err;

    // 4. DOT inputs & observed outputs
    bit          dot_valid;
    bit [2:0]    dot_mode;
    bit          dot_zero_skip_en;
    bit          dot_accum_en;
    bit          dot_accum_clear;
    bit [7:0]    dot_act_scale;
    bit [7:0]    dot_wt_scale;
    bit [127:0]  dot_act_stream;
    bit [127:0]  dot_wt_stream;
    bit          act_dot_valid;
    int          act_dot_unaccum;
    int          act_dot_accum;
    bit [31:0]   act_dot_fp32;
    bit [5:0]    act_dot_zero_skip_lanes;
    bit          act_dot_block_zero_skipped;
    bit          act_dot_nan_inf_flag;

    // 5. KVQ inputs & observed outputs
    bit          kvq_valid;
    bit [1:0]    kvq_mode;
    bit [127:0]  kvq_in_lo;
    bit [127:0]  kvq_in_hi;
    bit [1:0]    kvq_bank;
    bit [15:0]   kvq_addr;
    bit          act_kvq_valid;
    bit [127:0]  act_kvq_quant_vec;
    bit [7:0]    act_kvq_scale_e8m0;
    bit          act_kvq_sram_wr_en;
    bit [1:0]    act_kvq_sram_wr_bank;
    bit [15:0]   act_kvq_sram_wr_addr;
    bit [4:0]    act_kvq_zero_lanes_cnt;
    bit          act_kvq_nan_inf_clamped;
    bit [1:0]    act_kvq_comp_ratio;

    // 6. SPEC inputs & observed outputs
    bit          spec_valid;
    bit [1:0]    spec_op_mode;
    bit [127:0]  spec_logits;
    bit [127:0]  spec_token_ids;
    bit [3:0]    spec_top_k;
    bit [7:0]    spec_inv_temp;
    bit [15:0]   spec_top_p_thresh;
    bit          spec_rng_seed_step;
    bit [7:0]    spec_rng_threshold;
    bit [23:0]   spec_tree_parent_idx;
    bit [63:0]   spec_tree_draft_prob;
    bit [63:0]   spec_tree_target_prob;
    bit [63:0]   spec_tree_rand_u;
    bit [63:0]   spec_tree_draft_tok;
    bit [7:0]    spec_bonus_tok;
    bit          act_spec_valid;
    bit [7:0]    act_spec_selected_token;
    bit [7:0]    act_spec_selected_logit;
    bit [127:0]  act_spec_sorted_logits;
    bit [127:0]  act_spec_sorted_tokens;
    bit [15:0]   act_spec_nucleus_mask;
    bit [7:0]    act_spec_accepted_node_mask;
    bit [2:0]    act_spec_best_leaf_idx;
    bit [2:0]    act_spec_accepted_draft_len;
    bit [2:0]    act_spec_total_emitted_tokens;
    bit [39:0]   act_spec_committed_tokens;
    bit [2:0]    act_spec_kv_ring_advance;
    bit [31:0]   act_spec_prng_state;

    function new(string name = "high_intensity_seq_item");
      super.new(name);
    endfunction
  endclass : high_intensity_seq_item
  // ---------------------------------------------------------------------------
  // 3. Helper Functions & High-Intensity 50,000-Tx UVM Sequence
  // ---------------------------------------------------------------------------
  function automatic bit [7:0] tb_crc8_step(input bit [7:0] crc_in, input bit [7:0] d);
    bit [7:0] c = crc_in ^ d;
    for (int b = 0; b < 8; b++) c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
    return c;
  endfunction

  function automatic bit [7:0] tb_crc8_calc(input bit [127:0] payload, input bit [15:0] ts);
    bit [7:0] crc = 8'hFF;
    for (int i = 0; i < 16; i++) crc = tb_crc8_step(crc, payload[i*8 +: 8]);
    crc = tb_crc8_step(crc, ts[7:0]);
    crc = tb_crc8_step(crc, ts[15:8]);
    return crc;
  endfunction

  function automatic bit [127:0] gen_entropy_128(input int unsigned cyc, input int unsigned salt);
    bit [127:0] res;
    int unsigned s = (cyc * 32'h9E3779B9) ^ (salt * 32'h85EBCA6B) ^ 32'hA5A5_5A5A;
    for (int w = 0; w < 4; w++) begin
      s ^= (s << 13);
      s ^= (s >> 17);
      s ^= (s << 5);
      res[w*32 +: 32] = s + (w * 32'hC2B2AE35);
    end
    return res;
  endfunction

  class high_intensity_sequence extends uvm_sequence #(high_intensity_seq_item);
    `uvm_object_utils(high_intensity_sequence)

    function new(string name = "high_intensity_sequence");
      super.new(name);
    endfunction

    task body();
      high_intensity_seq_item it = high_intensity_seq_item::type_id::create("it");
      for (int unsigned c = 0; c < 50000; c++) begin
        start_item(it);
        it.tx_id = c;

        // --- 1. groq_sxm_slice Stimulus (incl. BUG-LIT-001 -128 RoPE Butterfly) ---
        if (c < 64) begin
          // Full 16x16 transpose buffer toggle sweep (0xFF, 0x00, 0xAA, 0x55)
          it.sxm_in_valid         = 1'b1;
          it.sxm_op               = (c < 16 || (c >= 32 && c < 48)) ? 4'd10 : 4'd11;
          it.sxm_transpose_idx    = 4'(c & 15);
          it.sxm_shift_amt        = 4'(c & 15);
          it.sxm_src_lane         = 4'(~c & 15);
          it.sxm_butterfly_mask   = 4'(c & 15);
          it.sxm_rope_neg_even_en = c[0];
          it.sxm_in_data          = (c < 16) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF :
                                    (c < 48) ? 128'h0000_0000_0000_0000_0000_0000_0000_0000 :
                                               gen_entropy_128(c, 1);
        end else if (c < 500) begin
          // Directed RoPE Butterfly -128 (0x80) saturating negation + all 13 SXM ops
          it.sxm_in_valid         = (c % 17 != 16);
          it.sxm_op               = (c < 200) ? 4'd12 : 4'(c % 16);
          it.sxm_shift_amt        = 4'(c);
          it.sxm_src_lane         = 4'(c >> 1);
          it.sxm_butterfly_mask   = 4'(c);
          it.sxm_transpose_idx    = 4'(c >> 2);
          it.sxm_rope_neg_even_en = (c < 200) ? 1'b1 : c[0];
          it.sxm_in_data          = (c < 120) ? 128'h8080_8080_8080_8080_8080_8080_8080_8080 :
                                                gen_entropy_128(c, 2);
        end else begin
          it.sxm_in_valid         = (c % 31 != 30);
          it.sxm_op               = 4'(c % 14);
          it.sxm_shift_amt        = 4'(c);
          it.sxm_src_lane         = 4'(c >> 2);
          it.sxm_butterfly_mask   = 4'(c ^ (c >> 3));
          it.sxm_transpose_idx    = 4'(c >> 1);
          it.sxm_rope_neg_even_en = c[0];
          it.sxm_in_data          = (c % 64 == 0) ? 128'h8080_7F7F_8080_7F7F_8080_7F7F_8080_7F7F :
                                                    gen_entropy_128(c, 3);
        end
        // --- 2. groq_vxm_slice Stimulus (incl. BUG-LIT-005 PREC_INT8_RNE Ties) ---
        if (c < 32) begin
          // Full 512-bit accum_32b_in / accum_32b_out toggle sweep
          it.vxm_op_valid      = 1'b1;
          it.vxm_op            = 4'd9; // VXM_QUANT_SCALE
          it.vxm_prec_mode     = 4'(c & 15);
          it.vxm_quant_shift   = 3'(c & 7);
          it.vxm_use_accum_32b = 1'b1;
          it.vxm_stream_a      = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
          it.vxm_stream_b      = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
          it.vxm_stream_c      = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
          it.vxm_accum_32b_in  = (c[0]) ? {16{32'hFFFF_FFFF}} : {16{32'h0000_0000}};
        end else if (c < 600) begin
          // Directed PREC_INT8_RNE = 4'd3 exact halfway tie sweep (even & odd quotients)
          it.vxm_op_valid      = (c % 29 != 28);
          it.vxm_op            = (c < 300) ? 4'd9 : 4'(c % 16);
          it.vxm_prec_mode     = (c < 220) ? 4'd3 : 4'((c / 4) % 4);
          it.vxm_quant_shift   = (c < 220) ? 3'(1 + (c % 7)) : 3'(c & 7);
          it.vxm_use_accum_32b = (c < 150) ? 1'b0 : c[0];
          for (int i = 0; i < 16; i++) begin
            int sh = int'(it.vxm_quant_shift);
            int half_b = (sh == 0) ? 0 : (1 << (sh - 1));
            int q_val  = int'(i + c) - 16;
            int tie_v  = (q_val << sh) | half_b;
            it.vxm_stream_a[i*8 +: 8]      = 8'(tie_v);
            it.vxm_accum_32b_in[i*32 +: 32] = 32'(tie_v);
          end
          it.vxm_stream_b = gen_entropy_128(c, 11);
          it.vxm_stream_c = gen_entropy_128(c, 12);
        end else begin
          it.vxm_op_valid      = (c % 37 != 36);
          it.vxm_op            = 4'(c % 16);
          it.vxm_prec_mode     = 4'((c / 3) % 4);
          it.vxm_quant_shift   = 3'(c & 7);
          it.vxm_use_accum_32b = c[1];
          it.vxm_stream_a      = gen_entropy_128(c, 13);
          it.vxm_stream_b      = gen_entropy_128(c, 14);
          it.vxm_stream_c      = gen_entropy_128(c, 15);
          it.vxm_accum_32b_in  = {gen_entropy_128(c, 16), gen_entropy_128(c, 17),
                                  gen_entropy_128(c, 18), gen_entropy_128(c, 19)};
        end

        // --- 3. groq_nim_realsync Stimulus (incl. BUG-NIM-001 & BUG-LIT-003 HAC) ---
        if (c < 40) begin
          // Full toggle + 4-slot deskew buffer fill & exact scheduled release
          it.nim_op_valid       = 1'b1;
          it.nim_op             = (c < 8) ? 4'd6 : 4'(c % 8);
          it.nim_realsync_time  = (c < 16) ? 16'(100 + (c % 4)) : (c[0] ? 16'hFFFF : 16'h0000);
          it.nim_flight_cycles  = (c < 16) ? 16'd4 : (c[0] ? 16'hFFFF : 16'h0000);
          it.nim_local_chip_id  = 4'(c);
          it.nim_tx_dst_chip    = 4'(~c);
          it.nim_ugal_en        = c[0];
          it.nim_link_congested = c[1];
          it.nim_loc_in_valid   = 1'b1;
          it.nim_loc_in_data    = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
          it.nim_c2c_rx_valid   = 1'b1;
          it.nim_c2c_rx_data    = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
          it.nim_c2c_rx_ts      = (c < 16) ? 16'(96 + (c % 4)) : (c[0] ? 16'hFFFF : 16'h0000);
          it.nim_c2c_rx_dst     = 4'(c >> 1);
          it.nim_c2c_rx_crc8    = tb_crc8_calc(it.nim_c2c_rx_data, it.nim_c2c_rx_ts);
        end else begin
          it.nim_op_valid       = (c % 23 != 22);
          it.nim_op             = 4'(c % 9);
          it.nim_realsync_time  = 16'(c);
          it.nim_flight_cycles  = 16'(2 + (c & 3));
          it.nim_local_chip_id  = 4'(c & 15);
          it.nim_tx_dst_chip    = 4'((c >> 2) & 15);
          it.nim_ugal_en        = c[0];
          it.nim_link_congested = c[1];
          it.nim_loc_in_valid   = (c % 5 != 4);
          it.nim_loc_in_data    = gen_entropy_128(c, 21);
          it.nim_c2c_rx_valid   = (c % 4 != 3);
          it.nim_c2c_rx_data    = gen_entropy_128(c, 22);
          it.nim_c2c_rx_ts      = 16'(c - 2);
          it.nim_c2c_rx_dst     = 4'((c >> 1) & 15);
          it.nim_c2c_rx_crc8    = (c % 19 == 18) ? ~tb_crc8_calc(it.nim_c2c_rx_data, it.nim_c2c_rx_ts)
                                                 :  tb_crc8_calc(it.nim_c2c_rx_data, it.nim_c2c_rx_ts);
        end
        // --- 4. groq_mxfp8_nvfp4_dot_engine Stimulus (incl. BUG-LIT-002 Mode 5) ---
        it.dot_valid        = (c % 29 != 28);
        it.dot_mode         = (c < 20) ? (c[0] ? 3'd7 : 3'd0) : 3'(c % 6);
        it.dot_zero_skip_en = (c < 40) ? 1'b1 : c[0];
        it.dot_accum_en     = (c % 4 != 0);
        it.dot_accum_clear  = (c % 25 == 0);
        if (c < 40) begin
          it.dot_act_scale  = (c < 10) ? 8'h00 : (c < 20) ? 8'hFF : 8'd127;
          it.dot_wt_scale   = (c >= 10 && c < 15) ? 8'h00 : (c < 20) ? 8'hFF : 8'd127;
          it.dot_act_stream = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
          it.dot_wt_stream  = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
        end else if (c < 260) begin
          // Directed zero-skip lane sweep (0..32) + Mode 5 NVFP4 E4M3 scale sweep
          int z_t = (c - 40) % 33;
          it.dot_act_scale  = (it.dot_mode == 3'd5 && (c % 18 == 0)) ? 8'h00 :
                              (it.dot_mode == 3'd5 && (c % 18 == 6)) ? 8'h7F : 8'(118 + (c % 20));
          it.dot_wt_scale   = 8'(120 + ((c / 2) % 20));
          it.dot_act_stream = gen_entropy_128(c, 31);
          it.dot_wt_stream  = gen_entropy_128(c, 32);
          if (it.dot_mode == 3'd3 || it.dot_mode == 3'd5) begin
            for (int k = 0; k < 32; k++) begin
              if (k < z_t) it.dot_act_stream[k*4 +: 4] = 4'b0000;
              else begin
                it.dot_act_stream[k*4 +: 4] = {k[0], 3'(1 + (k % 7))};
                it.dot_wt_stream[k*4 +: 4]  = {k[1], 3'(1 + ((k + c) % 7))};
              end
            end
          end else begin
            for (int i = 0; i < 16; i++) begin
              if (i < (z_t % 17)) it.dot_act_stream[i*8 +: 8] = 8'h00;
              else begin
                it.dot_act_stream[i*8 +: 8] = {i[0], 7'(1 + ((i + c) % 120))};
                it.dot_wt_stream[i*8 +: 8]  = {i[1], 7'(1 + ((i * 3 + c) % 120))};
                it.dot_wt_stream[i*4 +: 4]  = {i[1], 3'(1 + (i % 7))};
              end
            end
          end
        end else if (c < 360) begin
          // Positive & Negative Saturation
          it.dot_mode        = (c < 310) ? 3'd1 : 3'd2;
          it.dot_accum_en    = 1'b1;
          it.dot_accum_clear = (c == 260 || c == 310);
          it.dot_act_scale   = 8'd140;
          it.dot_wt_scale    = 8'd140;
          it.dot_act_stream  = (c < 310) ? {16{8'h7E}} : {16{8'hFE}};
          it.dot_wt_stream   = {16{8'h7B}};
        end else begin
          it.dot_act_scale  = (c % 60 == 0) ? 8'h00 : 8'(96 + (c % 70));
          it.dot_wt_scale   = (c % 60 == 30) ? 8'h00 : 8'(96 + ((c * 3) % 70));
          it.dot_act_stream = gen_entropy_128(c, 33);
          it.dot_wt_stream  = gen_entropy_128(c, 34);
        end

        // --- 5. groq_c2c_kv_quant_rx_engine Stimulus (incl. BUG-LIT-006) ---
        it.kvq_valid = (c % 31 != 30);
        it.kvq_mode  = 2'(c % 4);
        it.kvq_bank  = 2'((c >> 1) & 3);
        it.kvq_addr  = (c < 20) ? (c[0] ? 16'hFFFF : 16'h0000) : 16'(c * 257);
        if (c < 40) begin
          it.kvq_in_lo = (c < 16) ? 128'h0 : (c[0] ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0);
          it.kvq_in_hi = (c < 16) ? 128'h0 : (c[0] ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0);
        end else if (c < 240) begin
          // Sweep 0..16 zero lanes, NaN/Inf clamping, and NVFP4 E4M3 scale <120, 121..133, >=134
          int z_kv = (c - 40) % 17;
          bit [7:0] base_exp = (c < 100) ? 8'd115 : (c < 170) ? 8'(122 + (c % 12)) : 8'd140;
          for (int i = 0; i < 8; i++) begin
            it.kvq_in_lo[i*16 +: 16] = (i < z_kv) ? 16'h0000 : {i[0], base_exp, 7'(i * 9 + c)};
            it.kvq_in_hi[i*16 +: 16] = ((i + 8) < z_kv) ? 16'h0000 :
                                       (c % 9 == 0 && i == 7) ? 16'h7F80 : {~i[0], base_exp, 7'(i * 13 + c)};
          end
        end else begin
          it.kvq_in_lo = gen_entropy_128(c, 41);
          it.kvq_in_hi = gen_entropy_128(c, 42);
        end
        // --- 6. groq_spec_decode_tree_sampler Stimulus (incl. BUG-LIT-007 EAGLE-2) ---
        it.spec_valid         = (c % 29 != 28);
        it.spec_op_mode       = (c < 20) ? (c[0] ? 2'd3 : 2'd0) : 2'(c % 3);
        it.spec_top_k         = 4'(c & 15);
        it.spec_inv_temp      = (c < 20) ? (c[0] ? 8'hFF : 8'h00) : 8'(1 + (c % 32));
        it.spec_top_p_thresh  = (c < 20) ? (c[0] ? 16'hFFFF : 16'h0000) : 16'(128 + (c * 37));
        it.spec_rng_seed_step = (c % 3 != 0);
        it.spec_rng_threshold = 8'(c * 19);
        it.spec_bonus_tok     = (c < 20) ? (c[0] ? 8'hFF : 8'h00) : 8'(200 + (c & 31));
        if (c < 20) begin
          it.spec_logits            = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
          it.spec_token_ids         = (c[0]) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF : 128'h0;
          it.spec_tree_parent_idx   = (c[0]) ? 24'hFF_FFFF : 24'h00_0000;
          it.spec_tree_draft_prob   = (c[0]) ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0;
          it.spec_tree_target_prob  = (c[0]) ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0;
          it.spec_tree_rand_u       = (c[0]) ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0;
          it.spec_tree_draft_tok    = (c[0]) ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0;
        end else if (c < 300) begin
          // Directed EAGLE-2 speculative tree verification across draft lengths 1..4
          it.spec_logits    = gen_entropy_128(c, 51);
          it.spec_token_ids = gen_entropy_128(c, 52);
          // Linear chain 0<-1<-2<-3 (depth 1..4) and branch 0<-4<-5<-6<-7
          it.spec_tree_parent_idx = {3'd6, 3'd5, 3'd4, 3'd0, 3'd2, 3'd1, 3'd0, 3'd0};
          it.spec_tree_draft_tok  = 64'h1716_1514_1312_1110 ^ {8{8'(c)}};
          case (c & 3)
            0: begin // Accept only root -> draft_len = 1
              it.spec_tree_draft_prob  = 64'hFFFF_FFFF_FFFF_FF80;
              it.spec_tree_target_prob = 64'h0000_0000_0000_00F0;
              it.spec_tree_rand_u      = 64'hFFFF_FFFF_FFFF_FF00;
            end
            1: begin // Accept 0<-1 -> draft_len = 2
              it.spec_tree_draft_prob  = 64'hFFFF_FFFF_FFFF_4080;
              it.spec_tree_target_prob = 64'h0000_0000_0000_F0F0;
              it.spec_tree_rand_u      = 64'hFFFF_FFFF_FFFF_1000;
            end
            2: begin // Accept 0<-1<-2 -> draft_len = 3
              it.spec_tree_draft_prob  = 64'hFFFF_FFFF_FF40_4080;
              it.spec_tree_target_prob = 64'h0000_0000_00F0_F0F0;
              it.spec_tree_rand_u      = 64'hFFFF_FFFF_FF10_1000;
            end
            default: begin // Accept 0<-1<-2<-3 -> draft_len = 4
              it.spec_tree_draft_prob  = 64'h4040_4040_4040_4040;
              it.spec_tree_target_prob = 64'hF0F0_F0F0_F0F0_F0F0;
              it.spec_tree_rand_u      = 64'h1010_1010_1010_1010;
            end
          endcase
        end else begin
          it.spec_logits           = gen_entropy_128(c, 53);
          it.spec_token_ids        = gen_entropy_128(c, 54);
          it.spec_tree_parent_idx  = 24'(gen_entropy_128(c, 55));
          it.spec_tree_draft_prob  = 64'(gen_entropy_128(c, 56));
          it.spec_tree_target_prob = 64'(gen_entropy_128(c, 57));
          it.spec_tree_rand_u      = 64'(gen_entropy_128(c, 58));
          it.spec_tree_draft_tok   = 64'(gen_entropy_128(c, 59));
        end

        finish_item(it);
      end
    endtask
  endclass : high_intensity_sequence
  // ---------------------------------------------------------------------------
  // 4. UVM Sequencer & Driver
  // ---------------------------------------------------------------------------
  class high_intensity_sequencer extends uvm_sequencer #(high_intensity_seq_item);
    `uvm_component_utils(high_intensity_sequencer)
    function new(string name = "high_intensity_sequencer", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass : high_intensity_sequencer

  class high_intensity_driver extends uvm_driver #(high_intensity_seq_item);
    `uvm_component_utils(high_intensity_driver)

    virtual high_intensity_cross_ref_if vif;
    int unsigned driven = 0;

    function new(string name = "high_intensity_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual high_intensity_cross_ref_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface high_intensity_cross_ref_if missing in driver")
      end
    endfunction

    task run_phase(uvm_phase phase);
      high_intensity_seq_item item;
      vif.sample_en = 1'b0;
      vif.rst_n     = 1'b0;
      @(negedge vif.clk);
      vif.rst_n     = 1'b1;
      @(negedge vif.clk);
      vif.rst_n     = 1'b0;
      repeat (2) @(negedge vif.clk);

      forever begin
        seq_item_port.get_next_item(item);
        vif.rst_n     = 1'b1;
        vif.sample_en = 1'b1;
        vif.tx_id     = item.tx_id;

        vif.sxm_op_i               = item.sxm_op;
        vif.sxm_shift_amt_i        = item.sxm_shift_amt;
        vif.sxm_src_lane_i         = item.sxm_src_lane;
        vif.sxm_butterfly_mask_i   = item.sxm_butterfly_mask;
        vif.sxm_transpose_idx_i    = item.sxm_transpose_idx;
        vif.sxm_rope_neg_even_en_i = item.sxm_rope_neg_even_en;
        vif.sxm_in_valid_i         = item.sxm_in_valid;
        vif.sxm_in_data_i          = item.sxm_in_data;

        vif.vxm_op_valid_i         = item.vxm_op_valid;
        vif.vxm_op_i               = item.vxm_op;
        vif.vxm_prec_mode_i        = item.vxm_prec_mode;
        vif.vxm_quant_shift_i      = item.vxm_quant_shift;
        vif.vxm_use_accum_32b_i    = item.vxm_use_accum_32b;
        vif.vxm_stream_a_i         = item.vxm_stream_a;
        vif.vxm_stream_b_i         = item.vxm_stream_b;
        vif.vxm_stream_c_i         = item.vxm_stream_c;
        vif.vxm_accum_32b_in_i     = item.vxm_accum_32b_in;

        vif.nim_op_valid_i         = item.nim_op_valid;
        vif.nim_op_i               = item.nim_op;
        vif.nim_realsync_time_i    = item.nim_realsync_time;
        vif.nim_flight_cycles_i    = item.nim_flight_cycles;
        vif.nim_local_chip_id_i    = item.nim_local_chip_id;
        vif.nim_tx_dst_chip_i      = item.nim_tx_dst_chip;
        vif.nim_ugal_en_i          = item.nim_ugal_en;
        vif.nim_link_congested_i   = item.nim_link_congested;
        vif.nim_loc_in_valid_i     = item.nim_loc_in_valid;
        vif.nim_loc_in_data_i      = item.nim_loc_in_data;
        vif.nim_c2c_rx_valid_i     = item.nim_c2c_rx_valid;
        vif.nim_c2c_rx_data_i      = item.nim_c2c_rx_data;
        vif.nim_c2c_rx_ts_i        = item.nim_c2c_rx_ts;
        vif.nim_c2c_rx_dst_i       = item.nim_c2c_rx_dst;
        vif.nim_c2c_rx_crc8_i      = item.nim_c2c_rx_crc8;

        vif.dot_valid_i            = item.dot_valid;
        vif.dot_mode_i             = item.dot_mode;
        vif.dot_zero_skip_en_i     = item.dot_zero_skip_en;
        vif.dot_accum_en_i         = item.dot_accum_en;
        vif.dot_accum_clear_i      = item.dot_accum_clear;
        vif.dot_act_scale_i        = item.dot_act_scale;
        vif.dot_wt_scale_i         = item.dot_wt_scale;
        vif.dot_act_stream_i       = item.dot_act_stream;
        vif.dot_wt_stream_i        = item.dot_wt_stream;

        vif.kvq_valid_i            = item.kvq_valid;
        vif.kvq_mode_i             = item.kvq_mode;
        vif.kvq_in_lo_i            = item.kvq_in_lo;
        vif.kvq_in_hi_i            = item.kvq_in_hi;
        vif.kvq_bank_i             = item.kvq_bank;
        vif.kvq_addr_i             = item.kvq_addr;

        vif.spec_valid_i           = item.spec_valid;
        vif.spec_op_mode_i         = item.spec_op_mode;
        vif.spec_logits_i          = item.spec_logits;
        vif.spec_token_ids_i       = item.spec_token_ids;
        vif.spec_top_k_i           = item.spec_top_k;
        vif.spec_inv_temp_i        = item.spec_inv_temp;
        vif.spec_top_p_thresh_i    = item.spec_top_p_thresh;
        vif.spec_rng_seed_step_i   = item.spec_rng_seed_step;
        vif.spec_rng_threshold_i   = item.spec_rng_threshold;
        vif.spec_tree_parent_idx_i = item.spec_tree_parent_idx;
        vif.spec_tree_draft_prob_i = item.spec_tree_draft_prob;
        vif.spec_tree_target_prob_i= item.spec_tree_target_prob;
        vif.spec_tree_rand_u_i     = item.spec_tree_rand_u;
        vif.spec_tree_draft_tok_i  = item.spec_tree_draft_tok;
        vif.spec_bonus_tok_i       = item.spec_bonus_tok;

        @(negedge vif.clk);
        vif.sample_en = 1'b0;
        driven++;
        seq_item_port.item_done();
      end
    endtask
  endclass : high_intensity_driver
  // ---------------------------------------------------------------------------
  // 5. UVM Monitor & Agent
  // ---------------------------------------------------------------------------
  class high_intensity_monitor extends uvm_monitor;
    `uvm_component_utils(high_intensity_monitor)

    virtual high_intensity_cross_ref_if vif;
    uvm_analysis_port #(high_intensity_seq_item) ap;
    int unsigned seen = 0;

    function new(string name = "high_intensity_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual high_intensity_cross_ref_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface high_intensity_cross_ref_if missing in monitor")
      end
    endfunction

    task run_phase(uvm_phase phase);
      high_intensity_seq_item item = high_intensity_seq_item::type_id::create("obs_item");
      forever begin
        @(negedge vif.clk);
        #1ns;
        if (vif.rst_n && vif.sample_en) begin
          item.tx_id = vif.tx_id;

          item.sxm_op               = vif.sxm_op_i;
          item.sxm_shift_amt        = vif.sxm_shift_amt_i;
          item.sxm_src_lane         = vif.sxm_src_lane_i;
          item.sxm_butterfly_mask   = vif.sxm_butterfly_mask_i;
          item.sxm_transpose_idx    = vif.sxm_transpose_idx_i;
          item.sxm_rope_neg_even_en = vif.sxm_rope_neg_even_en_i;
          item.sxm_in_valid         = vif.sxm_in_valid_i;
          item.sxm_in_data          = vif.sxm_in_data_i;

          item.vxm_op_valid         = vif.vxm_op_valid_i;
          item.vxm_op               = vif.vxm_op_i;
          item.vxm_prec_mode        = vif.vxm_prec_mode_i;
          item.vxm_quant_shift      = vif.vxm_quant_shift_i;
          item.vxm_use_accum_32b    = vif.vxm_use_accum_32b_i;
          item.vxm_stream_a         = vif.vxm_stream_a_i;
          item.vxm_stream_b         = vif.vxm_stream_b_i;
          item.vxm_stream_c         = vif.vxm_stream_c_i;
          item.vxm_accum_32b_in     = vif.vxm_accum_32b_in_i;

          item.nim_op_valid         = vif.nim_op_valid_i;
          item.nim_op               = vif.nim_op_i;
          item.nim_realsync_time    = vif.nim_realsync_time_i;
          item.nim_flight_cycles    = vif.nim_flight_cycles_i;
          item.nim_local_chip_id    = vif.nim_local_chip_id_i;
          item.nim_tx_dst_chip      = vif.nim_tx_dst_chip_i;
          item.nim_ugal_en          = vif.nim_ugal_en_i;
          item.nim_link_congested   = vif.nim_link_congested_i;
          item.nim_loc_in_valid     = vif.nim_loc_in_valid_i;
          item.nim_loc_in_data      = vif.nim_loc_in_data_i;
          item.nim_c2c_rx_valid     = vif.nim_c2c_rx_valid_i;
          item.nim_c2c_rx_data      = vif.nim_c2c_rx_data_i;
          item.nim_c2c_rx_ts        = vif.nim_c2c_rx_ts_i;
          item.nim_c2c_rx_dst       = vif.nim_c2c_rx_dst_i;
          item.nim_c2c_rx_crc8      = vif.nim_c2c_rx_crc8_i;

          item.dot_valid            = vif.dot_valid_i;
          item.dot_mode             = vif.dot_mode_i;
          item.dot_zero_skip_en     = vif.dot_zero_skip_en_i;
          item.dot_accum_en         = vif.dot_accum_en_i;
          item.dot_accum_clear      = vif.dot_accum_clear_i;
          item.dot_act_scale        = vif.dot_act_scale_i;
          item.dot_wt_scale         = vif.dot_wt_scale_i;
          item.dot_act_stream       = vif.dot_act_stream_i;
          item.dot_wt_stream        = vif.dot_wt_stream_i;

          item.kvq_valid            = vif.kvq_valid_i;
          item.kvq_mode             = vif.kvq_mode_i;
          item.kvq_in_lo            = vif.kvq_in_lo_i;
          item.kvq_in_hi            = vif.kvq_in_hi_i;
          item.kvq_bank             = vif.kvq_bank_i;
          item.kvq_addr             = vif.kvq_addr_i;

          item.spec_valid           = vif.spec_valid_i;
          item.spec_op_mode         = vif.spec_op_mode_i;
          item.spec_logits          = vif.spec_logits_i;
          item.spec_token_ids       = vif.spec_token_ids_i;
          item.spec_top_k           = vif.spec_top_k_i;
          item.spec_inv_temp        = vif.spec_inv_temp_i;
          item.spec_top_p_thresh    = vif.spec_top_p_thresh_i;
          item.spec_rng_seed_step   = vif.spec_rng_seed_step_i;
          item.spec_rng_threshold   = vif.spec_rng_threshold_i;
          item.spec_tree_parent_idx = vif.spec_tree_parent_idx_i;
          item.spec_tree_draft_prob = vif.spec_tree_draft_prob_i;
          item.spec_tree_target_prob= vif.spec_tree_target_prob_i;
          item.spec_tree_rand_u     = vif.spec_tree_rand_u_i;
          item.spec_tree_draft_tok  = vif.spec_tree_draft_tok_i;
          item.spec_bonus_tok       = vif.spec_bonus_tok_i;
          @(posedge vif.clk);
          #1ps;
          item.act_sxm_out_valid         = vif.sxm_out_valid_o;
          item.act_sxm_out_data          = vif.sxm_out_data_o ^ (vif.inject_fault ? 128'h1 : 128'h0);
          item.act_sxm_perm_comb         = vif.sxm_perm_comb_o;

          item.act_vxm_out_valid         = vif.vxm_out_valid_o;
          item.act_vxm_out_data          = vif.vxm_out_data_o;
          item.act_vxm_accum_32b_out     = vif.vxm_accum_32b_out_o;
          item.act_vxm_comb_data         = vif.vxm_comb_data_o;
          item.act_vxm_reduce_sum        = vif.vxm_reduce_sum_o;
          item.act_vxm_reduce_max        = vif.vxm_reduce_max_o;
          item.act_vxm_mul_gate          = vif.vxm_mul_gate_o;
          item.act_vxm_lut_gate          = vif.vxm_lut_gate_o;

          item.act_nim_loc_out_valid     = vif.nim_loc_out_valid_o;
          item.act_nim_loc_out_data      = vif.nim_loc_out_data_o;
          item.act_nim_c2c_tx_valid      = vif.nim_c2c_tx_valid_o;
          item.act_nim_c2c_tx_data       = vif.nim_c2c_tx_data_o;
          item.act_nim_c2c_tx_ts         = vif.nim_c2c_tx_ts_o;
          item.act_nim_c2c_tx_dst        = vif.nim_c2c_tx_dst_o;
          item.act_nim_c2c_tx_crc8       = vif.nim_c2c_tx_crc8_o;
          item.act_nim_c2c_tx_port       = vif.nim_c2c_tx_port_o;
          item.act_nim_deskew_rel_valid  = vif.nim_deskew_rel_valid_o;
          item.act_nim_deskew_rel_target = vif.nim_deskew_rel_target_o;
          item.act_nim_ping_ack          = vif.nim_ping_ack_o;
          item.act_nim_measured_skew     = vif.nim_measured_skew_o;
          item.act_nim_crc_err           = vif.nim_crc_err_o;

          item.act_dot_valid             = vif.dot_valid_o;
          item.act_dot_unaccum           = vif.dot_unaccum_o;
          item.act_dot_accum             = vif.dot_accum_o;
          item.act_dot_fp32              = vif.dot_fp32_o;
          item.act_dot_zero_skip_lanes   = vif.dot_zero_skip_lanes_o;
          item.act_dot_block_zero_skipped= vif.dot_block_zero_skipped_o;
          item.act_dot_nan_inf_flag      = vif.dot_nan_inf_flag_o;

          item.act_kvq_valid             = vif.kvq_valid_o;
          item.act_kvq_quant_vec         = vif.kvq_quant_vec_o;
          item.act_kvq_scale_e8m0        = vif.kvq_scale_e8m0_o;
          item.act_kvq_sram_wr_en        = vif.kvq_sram_wr_en_o;
          item.act_kvq_sram_wr_bank      = vif.kvq_sram_wr_bank_o;
          item.act_kvq_sram_wr_addr      = vif.kvq_sram_wr_addr_o;
          item.act_kvq_zero_lanes_cnt    = vif.kvq_zero_lanes_cnt_o;
          item.act_kvq_nan_inf_clamped   = vif.kvq_nan_inf_clamped_o;
          item.act_kvq_comp_ratio        = vif.kvq_comp_ratio_o;

          item.act_spec_valid            = vif.spec_valid_o;
          item.act_spec_selected_token   = vif.spec_selected_token_o;
          item.act_spec_selected_logit   = vif.spec_selected_logit_o;
          item.act_spec_sorted_logits    = vif.spec_sorted_logits_o;
          item.act_spec_sorted_tokens    = vif.spec_sorted_tokens_o;
          item.act_spec_nucleus_mask     = vif.spec_nucleus_mask_o;
          item.act_spec_accepted_node_mask= vif.spec_accepted_node_mask_o;
          item.act_spec_best_leaf_idx    = vif.spec_best_leaf_idx_o;
          item.act_spec_accepted_draft_len= vif.spec_accepted_draft_len_o;
          item.act_spec_total_emitted_tokens= vif.spec_total_emitted_tokens_o;
          item.act_spec_committed_tokens = vif.spec_committed_tokens_o;
          item.act_spec_kv_ring_advance  = vif.spec_kv_ring_advance_o;
          item.act_spec_prng_state       = vif.spec_prng_state_o;

          seen++;
          ap.write(item);
        end
      end
    endtask
  endclass : high_intensity_monitor

  class high_intensity_agent extends uvm_agent;
    `uvm_component_utils(high_intensity_agent)
    high_intensity_sequencer sequencer;
    high_intensity_driver    driver;
    high_intensity_monitor   monitor;

    function new(string name = "high_intensity_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = high_intensity_sequencer::type_id::create("sequencer", this);
      driver    = high_intensity_driver::type_id::create("driver", this);
      monitor   = high_intensity_monitor::type_id::create("monitor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass : high_intensity_agent
  // ---------------------------------------------------------------------------
  // 6. UVM Functional Coverage Subscriber (uvm_subscriber)
  // ---------------------------------------------------------------------------
  class high_intensity_cov_subscriber extends uvm_subscriber #(high_intensity_seq_item);
    `uvm_component_utils(high_intensity_cov_subscriber)

    covergroup high_intensity_cg with function sample(
      bit [3:0] sxm_op,
      bit       sxm_rope_neg_sat128,
      bit [3:0] vxm_op,
      bit [3:0] vxm_prec,
      bit       vxm_rne_tie_hit,
      bit [3:0] nim_op,
      bit       nim_deskew_rel,
      bit       nim_hac_cal_hit,
      bit       nim_crc_err,
      bit [2:0] dot_mode,
      bit       dot_nvfp4_e4m3_hit,
      bit       dot_blk_zskip,
      bit       dot_nan_inf,
      bit [1:0] kvq_mode,
      bit       kvq_nan_inf_clamped,
      bit       kvq_all_zero_blk,
      bit [1:0] spec_mode,
      bit [2:0] spec_draft_len
    );
      option.per_instance = 1;

      cp_sxm_op: coverpoint sxm_op {
        bins ops[] = {[4'd0:4'd12]};
      }
      cp_sxm_rope_sat128: coverpoint sxm_rope_neg_sat128 {
        bins normal = {1'b0};
        bins sat128 = {1'b1};
      }
      cp_vxm_op: coverpoint vxm_op {
        bins ops[] = {[4'd0:4'd15]};
      }
      cp_vxm_prec: coverpoint vxm_prec {
        bins p_int8     = {4'd0};
        bins p_fp8_e4m3 = {4'd1};
        bins p_fp8_e5m2 = {4'd2};
        bins p_int8_rne = {4'd3};
      }
      cp_vxm_rne_tie: coverpoint vxm_rne_tie_hit {
        bins non_tie = {1'b0};
        bins rne_tie = {1'b1};
      }
      cp_nim_op: coverpoint nim_op {
        bins ops[] = {[4'd0:4'd7]};
      }
      cp_nim_deskew_rel: coverpoint nim_deskew_rel {
        bins idle     = {1'b0};
        bins released = {1'b1};
      }
      cp_nim_hac_cal: coverpoint nim_hac_cal_hit {
        bins normal  = {1'b0};
        bins hac_cal = {1'b1};
      }
      cp_nim_crc_err: coverpoint nim_crc_err {
        bins clean = {1'b0};
        bins err   = {1'b1};
      }
      cp_dot_mode: coverpoint dot_mode {
        bins m_int8_sym         = {3'd0};
        bins m_mxfp8_e4m3       = {3'd1};
        bins m_mxfp8_e5m2       = {3'd2};
        bins m_nvfp4_e2m1       = {3'd3};
        bins m_w4a8_mixed       = {3'd4};
        bins m_nvfp4_e4m3_scale = {3'd5};
      }
      cp_dot_nvfp4_e4m3: coverpoint dot_nvfp4_e4m3_hit {
        bins other     = {1'b0};
        bins e4m3_mode = {1'b1};
      }
      cp_dot_blk_zskip: coverpoint dot_blk_zskip {
        bins active = {1'b0};
        bins bzero  = {1'b1};
      }
      cp_dot_nan_inf: coverpoint dot_nan_inf {
        bins finite  = {1'b0};
        bins nan_inf = {1'b1};
      }
      cp_kvq_mode: coverpoint kvq_mode {
        bins m_bf16_mxfp8 = {2'd0};
        bins m_fp16_mxfp8 = {2'd1};
        bins m_bf16_nvfp4 = {2'd2};
        bins m_bypass_raw = {2'd3};
      }
      cp_kvq_nan_inf: coverpoint kvq_nan_inf_clamped {
        bins finite  = {1'b0};
        bins clamped = {1'b1};
      }
      cp_kvq_all_zero: coverpoint kvq_all_zero_blk {
        bins non_zero = {1'b0};
        bins all_zero = {1'b1};
      }
      cp_spec_mode: coverpoint spec_mode {
        bins m_greedy = {2'd0};
        bins m_topkp  = {2'd1};
        bins m_tree   = {2'd2};
      }
      cp_spec_draft_len: coverpoint spec_draft_len {
        bins len1 = {3'd1};
        bins len2 = {3'd2};
        bins len3 = {3'd3};
        bins len4 = {3'd4};
      }
    endgroup

    function new(string name = "high_intensity_cov_subscriber", uvm_component parent = null);
      super.new(name, parent);
      high_intensity_cg = new();
    endfunction
    function void write(high_intensity_seq_item t);
      bit sxm_sat128 = (t.sxm_op == 4'd12) && t.sxm_rope_neg_even_en && (t.sxm_in_data[7:0] == 8'h80);
      bit vxm_tie    = (t.vxm_op == 4'd9) && (t.vxm_prec_mode == 4'd3) && (t.vxm_quant_shift > 3'd0);
      bit nim_hac    = t.nim_op_valid && (t.nim_op == 4'd6) && t.nim_c2c_rx_valid && !t.act_nim_crc_err;
      high_intensity_cg.sample(
        t.sxm_op,
        sxm_sat128,
        t.vxm_op,
        t.vxm_prec_mode,
        vxm_tie,
        t.nim_op,
        t.act_nim_deskew_rel_valid,
        nim_hac,
        t.act_nim_crc_err,
        t.dot_mode,
        (t.dot_mode == 3'd5),
        t.act_dot_block_zero_skipped,
        t.act_dot_nan_inf_flag,
        t.kvq_mode,
        t.act_kvq_nan_inf_clamped,
        (t.act_kvq_zero_lanes_cnt == 5'd16),
        t.spec_op_mode,
        t.act_spec_accepted_draft_len
      );
    endfunction
  endclass : high_intensity_cov_subscriber

  // ---------------------------------------------------------------------------
  // 7. UVM Scoreboard (uvm_scoreboard) Calling 6-DUT C++17 DPI-C Master Ref
  // ---------------------------------------------------------------------------
  class high_intensity_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(high_intensity_scoreboard)

    uvm_analysis_imp #(high_intensity_seq_item, high_intensity_scoreboard) ap_imp;

    int unsigned checked_cycles  = 0;
    int unsigned sxm_mismatches  = 0;
    int unsigned vxm_mismatches  = 0;
    int unsigned nim_mismatches  = 0;
    int unsigned dot_mismatches  = 0;
    int unsigned kvq_mismatches  = 0;
    int unsigned spec_mismatches = 0;
    int unsigned mismatches      = 0;

    int unsigned sxm_sat128_events = 0;
    int unsigned vxm_rne_events    = 0;
    int unsigned nim_hac_events    = 0;
    int unsigned dot_mode5_events  = 0;
    int unsigned kvq_clamp_events  = 0;
    int unsigned spec_tree_events  = 0;

    function new(string name = "high_intensity_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      ap_imp = new("ap_imp", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      dpi_master_reset();
    endfunction
    function void write(high_intensity_seq_item item);
      int unsigned exp_sxm_valid;
      bit [127:0]  exp_sxm_data, exp_sxm_comb;

      int unsigned exp_vxm_valid, exp_vxm_mul_g, exp_vxm_lut_g;
      bit [127:0]  exp_vxm_data, exp_vxm_comb;
      bit [511:0]  exp_vxm_acc32;
      int          exp_vxm_rsum, exp_vxm_rmax;

      int unsigned exp_nim_loc_v, exp_nim_tx_v, exp_nim_tx_ts, exp_nim_tx_dst;
      int unsigned exp_nim_tx_crc, exp_nim_tx_port, exp_nim_drel_v, exp_nim_drel_t;
      int unsigned exp_nim_pack, exp_nim_crc_err;
      bit [127:0]  exp_nim_loc_d, exp_nim_tx_d;
      int          exp_nim_skew;

      int unsigned exp_dot_v, exp_dot_fp32, exp_dot_zlanes, exp_dot_bzero, exp_dot_nan;
      int          exp_dot_unacc, exp_dot_acc;

      int unsigned exp_kvq_v, exp_kvq_scale, exp_kvq_wren, exp_kvq_bank, exp_kvq_addr;
      int unsigned exp_kvq_zcnt, exp_kvq_clamp, exp_kvq_ratio;
      bit [127:0]  exp_kvq_vec;

      int unsigned exp_spec_v, exp_spec_tok, exp_spec_logit, exp_spec_nmask;
      int unsigned exp_spec_amask, exp_spec_leaf, exp_spec_dlen, exp_spec_emit;
      int unsigned exp_spec_kvadv, exp_spec_prng;
      bit [127:0]  exp_spec_slogits, exp_spec_stokens;
      longint unsigned exp_spec_commit;

      dpi_sxm_step(
        int'(item.sxm_op), int'(item.sxm_shift_amt), int'(item.sxm_src_lane),
        int'(item.sxm_butterfly_mask), int'(item.sxm_transpose_idx),
        int'(item.sxm_rope_neg_even_en), int'(item.sxm_in_valid), item.sxm_in_data,
        exp_sxm_valid, exp_sxm_data, exp_sxm_comb
      );

      dpi_vxm_step(
        int'(item.vxm_op_valid), int'(item.vxm_op), int'(item.vxm_prec_mode),
        int'(item.vxm_quant_shift), int'(item.vxm_use_accum_32b),
        item.vxm_stream_a, item.vxm_stream_b, item.vxm_stream_c, item.vxm_accum_32b_in,
        exp_vxm_valid, exp_vxm_data, exp_vxm_acc32, exp_vxm_comb,
        exp_vxm_rsum, exp_vxm_rmax, exp_vxm_mul_g, exp_vxm_lut_g
      );

      dpi_nim_step(
        int'(item.nim_op_valid), int'(item.nim_op), int'(item.nim_realsync_time),
        int'(item.nim_flight_cycles), int'(item.nim_local_chip_id), int'(item.nim_tx_dst_chip),
        int'(item.nim_ugal_en), int'(item.nim_link_congested),
        int'(item.nim_loc_in_valid), item.nim_loc_in_data,
        int'(item.nim_c2c_rx_valid), item.nim_c2c_rx_data,
        int'(item.nim_c2c_rx_ts), int'(item.nim_c2c_rx_dst), int'(item.nim_c2c_rx_crc8),
        exp_nim_loc_v, exp_nim_loc_d, exp_nim_tx_v, exp_nim_tx_d,
        exp_nim_tx_ts, exp_nim_tx_dst, exp_nim_tx_crc, exp_nim_tx_port,
        exp_nim_drel_v, exp_nim_drel_t, exp_nim_pack, exp_nim_skew, exp_nim_crc_err
      );

      dpi_dot_step(
        int'(item.dot_valid), int'(item.dot_mode), int'(item.dot_zero_skip_en),
        int'(item.dot_accum_en), int'(item.dot_accum_clear),
        int'(item.dot_act_scale), int'(item.dot_wt_scale),
        item.dot_act_stream, item.dot_wt_stream,
        exp_dot_v, exp_dot_unacc, exp_dot_acc, exp_dot_fp32,
        exp_dot_zlanes, exp_dot_bzero, exp_dot_nan
      );

      dpi_kvq_step(
        int'(item.kvq_valid), int'(item.kvq_mode), item.kvq_in_lo, item.kvq_in_hi,
        int'(item.kvq_bank), int'(item.kvq_addr),
        exp_kvq_v, exp_kvq_vec, exp_kvq_scale, exp_kvq_wren,
        exp_kvq_bank, exp_kvq_addr, exp_kvq_zcnt, exp_kvq_clamp, exp_kvq_ratio
      );

      dpi_spec_step(
        int'(item.spec_valid), int'(item.spec_op_mode), item.spec_logits, item.spec_token_ids,
        int'(item.spec_top_k), int'(item.spec_inv_temp), int'(item.spec_top_p_thresh),
        int'(item.spec_rng_seed_step), int'(item.spec_rng_threshold),
        int'(item.spec_tree_parent_idx), longint'(item.spec_tree_draft_prob),
        longint'(item.spec_tree_target_prob), longint'(item.spec_tree_rand_u),
        longint'(item.spec_tree_draft_tok), int'(item.spec_bonus_tok),
        exp_spec_v, exp_spec_tok, exp_spec_logit, exp_spec_slogits, exp_spec_stokens,
        exp_spec_nmask, exp_spec_amask, exp_spec_leaf, exp_spec_dlen,
        exp_spec_emit, exp_spec_commit, exp_spec_kvadv, exp_spec_prng
      );
      checked_cycles++;
      if ((item.sxm_op == 4'd12) && item.sxm_rope_neg_even_en && (item.sxm_in_data[7:0] == 8'h80)) sxm_sat128_events++;
      if ((item.vxm_op == 4'd9) && (item.vxm_prec_mode == 4'd3) && (item.vxm_quant_shift > 3'd0))  vxm_rne_events++;
      if (item.nim_op_valid && (item.nim_op == 4'd6) && item.nim_c2c_rx_valid && !item.act_nim_crc_err) nim_hac_events++;
      if (item.dot_mode == 3'd5)        dot_mode5_events++;
      if (item.act_kvq_nan_inf_clamped) kvq_clamp_events++;
      if (item.spec_op_mode == 2'd2)    spec_tree_events++;

      if ((item.act_sxm_out_valid !== bit'(exp_sxm_valid)) ||
          (item.act_sxm_out_data  !== exp_sxm_data) ||
          (item.act_sxm_perm_comb !== exp_sxm_comb)) begin
        sxm_mismatches++;
        mismatches++;
        if (sxm_mismatches <= 5)
          `uvm_error("SXM_MISMATCH", $sformatf("tx=%0d op=%0d exp=%h act=%h", item.tx_id, item.sxm_op, exp_sxm_data, item.act_sxm_out_data))
      end

      if ((item.act_vxm_out_valid     !== bit'(exp_vxm_valid)) ||
          (item.act_vxm_out_data      !== exp_vxm_data) ||
          (item.act_vxm_accum_32b_out !== exp_vxm_acc32) ||
          (item.act_vxm_comb_data     !== exp_vxm_comb) ||
          (int'(item.act_vxm_reduce_sum) !== exp_vxm_rsum) ||
          (int'(item.act_vxm_reduce_max) !== exp_vxm_rmax) ||
          (item.act_vxm_mul_gate      !== bit'(exp_vxm_mul_g)) ||
          (item.act_vxm_lut_gate      !== bit'(exp_vxm_lut_g))) begin
        vxm_mismatches++;
        mismatches++;
        if (vxm_mismatches <= 5)
          `uvm_error("VXM_MISMATCH", $sformatf("tx=%0d op=%0d prec=%0d exp=%h act=%h", item.tx_id, item.vxm_op, item.vxm_prec_mode, exp_vxm_data, item.act_vxm_out_data))
      end

      if ((item.act_nim_loc_out_valid     !== bit'(exp_nim_loc_v)) ||
          (item.act_nim_loc_out_data      !== exp_nim_loc_d) ||
          (item.act_nim_c2c_tx_valid      !== bit'(exp_nim_tx_v)) ||
          (item.act_nim_c2c_tx_data       !== exp_nim_tx_d) ||
          (item.act_nim_c2c_tx_ts         !== 16'(exp_nim_tx_ts)) ||
          (item.act_nim_c2c_tx_dst        !== 4'(exp_nim_tx_dst)) ||
          (item.act_nim_c2c_tx_crc8       !== 8'(exp_nim_tx_crc)) ||
          (item.act_nim_c2c_tx_port       !== 2'(exp_nim_tx_port)) ||
          (item.act_nim_deskew_rel_valid  !== bit'(exp_nim_drel_v)) ||
          (item.act_nim_deskew_rel_target !== 16'(exp_nim_drel_t)) ||
          (item.act_nim_ping_ack          !== bit'(exp_nim_pack)) ||
          (int'(item.act_nim_measured_skew) !== exp_nim_skew) ||
          (item.act_nim_crc_err           !== bit'(exp_nim_crc_err))) begin
        nim_mismatches++;
        mismatches++;
        if (nim_mismatches <= 5)
          `uvm_error("NIM_MISMATCH", $sformatf("tx=%0d op=%0d", item.tx_id, item.nim_op))
      end

      if ((item.act_dot_valid              !== bit'(exp_dot_v)) ||
          (item.act_dot_unaccum            !== exp_dot_unacc) ||
          (item.act_dot_accum              !== exp_dot_acc) ||
          (item.act_dot_fp32               !== exp_dot_fp32) ||
          (item.act_dot_zero_skip_lanes    !== 6'(exp_dot_zlanes)) ||
          (item.act_dot_block_zero_skipped !== bit'(exp_dot_bzero)) ||
          (item.act_dot_nan_inf_flag       !== bit'(exp_dot_nan))) begin
        dot_mismatches++;
        mismatches++;
        if (dot_mismatches <= 5)
          `uvm_error("DOT_MISMATCH", $sformatf("tx=%0d mode=%0d exp_u=%h act_u=%h", item.tx_id, item.dot_mode, exp_dot_unacc, item.act_dot_unaccum))
      end

      if ((item.act_kvq_valid          !== bit'(exp_kvq_v)) ||
          (item.act_kvq_quant_vec      !== exp_kvq_vec) ||
          (item.act_kvq_scale_e8m0     !== 8'(exp_kvq_scale)) ||
          (item.act_kvq_sram_wr_en     !== bit'(exp_kvq_wren)) ||
          (item.act_kvq_sram_wr_bank   !== 2'(exp_kvq_bank)) ||
          (item.act_kvq_sram_wr_addr   !== 16'(exp_kvq_addr)) ||
          (item.act_kvq_zero_lanes_cnt !== 5'(exp_kvq_zcnt)) ||
          (item.act_kvq_nan_inf_clamped!== bit'(exp_kvq_clamp)) ||
          (item.act_kvq_comp_ratio     !== 2'(exp_kvq_ratio))) begin
        kvq_mismatches++;
        mismatches++;
        if (kvq_mismatches <= 5)
          `uvm_error("KVQ_MISMATCH", $sformatf("tx=%0d mode=%0d exp=%h act=%h", item.tx_id, item.kvq_mode, exp_kvq_vec, item.act_kvq_quant_vec))
      end

      if ((item.act_spec_valid                !== bit'(exp_spec_v)) ||
          (item.act_spec_selected_token       !== 8'(exp_spec_tok)) ||
          (item.act_spec_selected_logit       !== 8'(exp_spec_logit)) ||
          (item.act_spec_sorted_logits        !== exp_spec_slogits) ||
          (item.act_spec_sorted_tokens        !== exp_spec_stokens) ||
          (item.act_spec_nucleus_mask         !== 16'(exp_spec_nmask)) ||
          (item.act_spec_accepted_node_mask   !== 8'(exp_spec_amask)) ||
          (item.act_spec_best_leaf_idx        !== 3'(exp_spec_leaf)) ||
          (item.act_spec_accepted_draft_len   !== 3'(exp_spec_dlen)) ||
          (item.act_spec_total_emitted_tokens !== 3'(exp_spec_emit)) ||
          (item.act_spec_committed_tokens     !== 40'(exp_spec_commit)) ||
          (item.act_spec_kv_ring_advance      !== 3'(exp_spec_kvadv)) ||
          (item.act_spec_prng_state           !== exp_spec_prng)) begin
        spec_mismatches++;
        mismatches++;
        if (spec_mismatches <= 5)
          `uvm_error("SPEC_MISMATCH", $sformatf("tx=%0d mode=%0d", item.tx_id, item.spec_op_mode))
      end
    endfunction
  endclass : high_intensity_scoreboard
  // ---------------------------------------------------------------------------
  // 8. UVM Environment & Test
  // ---------------------------------------------------------------------------
  class high_intensity_env extends uvm_env;
    `uvm_component_utils(high_intensity_env)

    high_intensity_agent          agent;
    high_intensity_cov_subscriber cov_sub;
    high_intensity_scoreboard     scoreboard;

    function new(string name = "high_intensity_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = high_intensity_agent::type_id::create("agent", this);
      cov_sub    = high_intensity_cov_subscriber::type_id::create("cov_sub", this);
      scoreboard = high_intensity_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.monitor.ap.connect(cov_sub.analysis_export);
      agent.monitor.ap.connect(scoreboard.ap_imp);
    endfunction
  endclass : high_intensity_env

  class high_intensity_cross_ref_test extends uvm_test;
    `uvm_component_utils(high_intensity_cross_ref_test)

    high_intensity_env env;

    function new(string name = "high_intensity_cross_ref_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = high_intensity_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      high_intensity_sequence seq = high_intensity_sequence::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.agent.sequencer);
      repeat (2) @(negedge env.agent.driver.vif.clk);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      int unsigned dpi_calls, dpi_mod_steps;
      real func_cov;
      bit pass_gate;
      int fd;
      super.report_phase(phase);

      dpi_calls     = dpi_get_calls();
      dpi_mod_steps = dpi_get_module_steps();
      func_cov      = env.cov_sub.high_intensity_cg.get_inst_coverage();
      pass_gate     = (env.agent.driver.driven == 50000) &&
                      (env.agent.monitor.seen == 50000) &&
                      (env.scoreboard.checked_cycles == 50000) &&
                      (dpi_calls == 50000) &&
                      (dpi_mod_steps == 300000) &&
                      (env.scoreboard.mismatches == 0) &&
                      (env.scoreboard.sxm_sat128_events > 0) &&
                      (env.scoreboard.vxm_rne_events > 0) &&
                      (env.scoreboard.nim_hac_events > 0) &&
                      (env.scoreboard.dot_mode5_events > 0) &&
                      (env.scoreboard.kvq_clamp_events > 0) &&
                      (env.scoreboard.spec_tree_events > 0) &&
                      (func_cov == 100.0);

      fd = $fopen("high_intensity_cross_ref_summary.json", "w");
      if (fd == 0) `uvm_fatal("JSON_OPEN", "Cannot open high_intensity_cross_ref_summary.json")
      $fwrite(fd, "{\n");
      $fwrite(fd, "  \"suite\": \"uvm_high_intensity_cross_ref\",\n");
      $fwrite(fd, "  \"dut\": [\"groq_sxm_slice\", \"groq_vxm_slice\", \"groq_nim_realsync\", \"groq_mxfp8_nvfp4_dot_engine\", \"groq_c2c_kv_quant_rx_engine\", \"groq_spec_decode_tree_sampler\"],\n");
      $fwrite(fd, "  \"driven_cycles\": %0d,\n", env.agent.driver.driven);
      $fwrite(fd, "  \"observed_cycles\": %0d,\n", env.agent.monitor.seen);
      $fwrite(fd, "  \"checked_cycles\": %0d,\n", env.scoreboard.checked_cycles);
      $fwrite(fd, "  \"dpi_tx_calls\": %0d,\n", dpi_calls);
      $fwrite(fd, "  \"dpi_lockstep_module_comparisons\": %0d,\n", dpi_mod_steps);
      $fwrite(fd, "  \"sxm_mismatches\": %0d,\n", env.scoreboard.sxm_mismatches);
      $fwrite(fd, "  \"vxm_mismatches\": %0d,\n", env.scoreboard.vxm_mismatches);
      $fwrite(fd, "  \"nim_mismatches\": %0d,\n", env.scoreboard.nim_mismatches);
      $fwrite(fd, "  \"dot_mismatches\": %0d,\n", env.scoreboard.dot_mismatches);
      $fwrite(fd, "  \"kvq_mismatches\": %0d,\n", env.scoreboard.kvq_mismatches);
      $fwrite(fd, "  \"spec_mismatches\": %0d,\n", env.scoreboard.spec_mismatches);
      $fwrite(fd, "  \"mismatches\": %0d,\n", env.scoreboard.mismatches);
      $fwrite(fd, "  \"functional_coverage_pct\": %0.2f,\n", func_cov);
      $fwrite(fd, "  \"pass\": %0d\n", pass_gate);
      $fwrite(fd, "}\n");
      $fclose(fd);

      if (pass_gate) begin
        dpi_set_status(0);
        `uvm_info("UVM_HIGH_INTENSITY_PASS", $sformatf("Suite 10 PASSED: tx=%0d module_checks=%0d mismatches=0 cov=%0.2f%%", dpi_calls, dpi_mod_steps, func_cov), UVM_LOW)
      end else begin
        dpi_set_status(1);
        `uvm_fatal("UVM_HIGH_INTENSITY_FAIL", $sformatf("Suite 10 FAILED: tx=%0d mismatches=%0d cov=%0.2f%%", dpi_calls, env.scoreboard.mismatches, func_cov))
      end
    endfunction
  endclass : high_intensity_cross_ref_test
endpackage : uvm_high_intensity_cross_ref_pkg
`endif
