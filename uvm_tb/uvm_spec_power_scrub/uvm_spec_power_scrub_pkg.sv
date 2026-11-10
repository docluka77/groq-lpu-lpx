// =============================================================================
// File: uvm_tb/uvm_spec_power_scrub/uvm_spec_power_scrub_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Accellera IEEE 1800.2-2020 UVM Verification Package for
//              groq_spec_decode_tree_sampler, groq_power_droop_controller, and
//              groq_sram_controller_scrubber.
// =============================================================================
`ifndef UVM_SPEC_POWER_SCRUB_PKG_SV
`define UVM_SPEC_POWER_SCRUB_PKG_SV

`include "uvm_macros.svh"
`include "groq_pkg.sv"

package uvm_spec_power_scrub_pkg;
  import uvm_pkg::*;
  import groq_pkg::*;

  // ---------------------------------------------------------------------------
  // 1. C++17 DPI-C Reference Model Imports
  // ---------------------------------------------------------------------------
  import "DPI-C" function void dpi_spec_power_scrub_reset();
  import "DPI-C" function int unsigned dpi_get_calls();
  import "DPI-C" function void dpi_set_status(input int status);

  import "DPI-C" function void dpi_spec_sampler_step(
 input int unsigned valid_i,
 input int unsigned op_mode_i,
 input bit [127:0] logits_i,
 input bit [127:0] token_ids_i,
 input int unsigned top_k_i,
 input int unsigned inv_temp_i,
 input int unsigned top_p_thresh_i,
 input int unsigned rng_seed_step_i,
 input int unsigned rng_threshold_i,
 input int unsigned tree_parent_idx_i,
 input longint unsigned tree_draft_prob_i,
 input longint unsigned tree_target_prob_i,
 input longint unsigned tree_rand_u_i,
 input longint unsigned tree_draft_tok_i,
 input int unsigned bonus_tok_i,
 output int unsigned exp_valid_o,
 output int unsigned exp_selected_token_o,
 output int unsigned exp_selected_logit_o,
 output bit [127:0] exp_sorted_logits_o,
 output bit [127:0] exp_sorted_tokens_o,
 output int unsigned exp_nucleus_mask_o,
 output int unsigned exp_accepted_node_mask_o,
 output int unsigned exp_best_leaf_idx_o,
 output int unsigned exp_accepted_draft_len_o,
 output int unsigned exp_total_emitted_tokens_o,
 output longint unsigned exp_committed_tokens_o,
 output int unsigned exp_kv_ring_advance_o,
 output int unsigned exp_prng_state_o
 );

  import "DPI-C" function void dpi_power_droop_step(
 input int unsigned exp_in_enable_i,
 input int unsigned slice_active_i,
 input int unsigned mxm_zero_skip_cnt_i,
 input int unsigned prewarm_hint_i,
 input int unsigned prewarm_target_level_i,
 input int unsigned max_didt_step_i,
 input int unsigned vdd_nominal_mv_i,
 input int unsigned droop_emerg_thresh_mv_i,
 output int unsigned exp_raw_demand_o,
 output int unsigned exp_eff_current_o,
 output int unsigned exp_dummy_bleed_current_o,
 output int unsigned exp_dummy_bleed_mask_o,
 output int exp_didt_signed_o,
 output int unsigned exp_vdd_est_mv_o,
 output int unsigned exp_thermal_temp_c_o,
 output int unsigned exp_emerg_throttle_o,
 output int unsigned exp_droop_mitigated_events_o
 );

  import "DPI-C" function void dpi_sram_scrubber_step(
 input int unsigned efuse_load_req_i,
 input int unsigned efuse_bank_i,
 input int unsigned efuse_bad_addr_i,
 input int unsigned vliw_rd_en_i,
 input int unsigned vliw_rd_bank_i,
 input int unsigned vliw_rd_addr_i,
 input int unsigned vliw_wr_en_i,
 input int unsigned vliw_wr_bank_i,
 input int unsigned vliw_wr_addr_i,
 input bit [127:0] vliw_wr_data_i,
 input int unsigned dma_wr_en_i,
 input int unsigned dma_wr_bank_i,
 input int unsigned dma_wr_addr_i,
 input bit [127:0] dma_wr_data_i,
 input int unsigned scrub_enable_i,
 input int unsigned ser_inject_en_i,
 input int unsigned ser_inject_bank_i,
 input int unsigned ser_inject_addr_i,
 input longint unsigned ser_mask_lo_data_i,
 input int unsigned ser_mask_lo_ecc_i,
 input longint unsigned ser_mask_hi_data_i,
 input int unsigned ser_mask_hi_ecc_i,
 output int unsigned exp_bank_repair_en_o,
 output int unsigned exp_bank_repair_addr_o,
 output int unsigned exp_efuse_load_ack_o,
 output int unsigned exp_vliw_rd_valid_o,
 output bit [127:0] exp_vliw_rd_data_o,
 output int unsigned exp_vliw_rd_sec_err_o,
 output int unsigned exp_vliw_rd_ded_err_o,
 output int unsigned exp_vliw_rd_repaired_row_hit_o,
 output int unsigned exp_scrub_rd_fire_o,
 output int unsigned exp_scrub_wb_fire_o,
 output int unsigned exp_scrub_active_bank_o,
 output int unsigned exp_scrub_active_addr_o,
 output int unsigned exp_scrub_corrected_cnt_o,
 output int unsigned exp_scrub_ded_alert_o,
 output int unsigned exp_first_ded_bank_o,
 output int unsigned exp_first_ded_addr_o
 );

  // ---------------------------------------------------------------------------
  // 2. UVM Sequence Item (Transaction)
  // ---------------------------------------------------------------------------
  class spec_power_scrub_seq_item extends uvm_sequence_item;
    `uvm_object_utils(spec_power_scrub_seq_item)

    int unsigned tx_id    = 0;
    int unsigned phase_id = 0;

    // 1) Speculative Decode Tree & Sampler Stimulus
    bit          spec_valid            = 1'b0;
    bit [1:0]    spec_op_mode          = 2'd0;
    bit [127:0]  spec_logits           = '0;
    bit [127:0]  spec_token_ids        = '0;
    bit [3:0]    spec_top_k            = 4'd0;
    bit [7:0]    spec_inv_temp         = 8'd0;
    bit [15:0]   spec_top_p_thresh     = 16'd0;
    bit          spec_rng_seed_step    = 1'b0;
    bit [7:0]    spec_rng_threshold    = 8'd0;
    bit [23:0]   spec_tree_parent_idx  = 24'd0;
    bit [63:0]   spec_tree_draft_prob  = 64'd0;
    bit [63:0]   spec_tree_target_prob = 64'd0;
    bit [63:0]   spec_tree_rand_u      = 64'd0;
    bit [63:0]   spec_tree_draft_tok   = 64'd0;
    bit [7:0]    spec_bonus_tok        = 8'd0;

    // 2) Power & Droop Controller Stimulus
    bit          pwr_enable                = 1'b0;
    bit [7:0]    pwr_slice_active          = 8'd0;
    bit [5:0]    pwr_mxm_zero_skip_cnt     = 6'd0;
    bit          pwr_prewarm_hint          = 1'b0;
    bit [7:0]    pwr_prewarm_target_level  = 8'd0;
    bit [7:0]    pwr_max_didt_step         = 8'd0;
    bit [11:0]   pwr_vdd_nominal_mv        = 12'd850;
    bit [11:0]   pwr_droop_emerg_thresh_mv = 12'd760;

    // 3) SRAM Controller & Scrubber Stimulus
    bit          sram_efuse_load_req  = 1'b0;
    bit [1:0]    sram_efuse_bank      = 2'd0;
    bit [5:0]    sram_efuse_bad_addr  = 6'd0;
    bit          sram_vliw_rd_en      = 1'b0;
    bit [1:0]    sram_vliw_rd_bank    = 2'd0;
    bit [5:0]    sram_vliw_rd_addr    = 6'd0;
    bit          sram_vliw_wr_en      = 1'b0;
    bit [1:0]    sram_vliw_wr_bank    = 2'd0;
    bit [5:0]    sram_vliw_wr_addr    = 6'd0;
    bit [127:0]  sram_vliw_wr_data    = '0;
    bit          sram_dma_wr_en       = 1'b0;
    bit [1:0]    sram_dma_wr_bank     = 2'd0;
    bit [5:0]    sram_dma_wr_addr     = 6'd0;
    bit [127:0]  sram_dma_wr_data     = '0;
    bit          sram_scrub_enable    = 1'b0;
    bit          sram_ser_inject_en   = 1'b0;
    bit [1:0]    sram_ser_inject_bank = 2'd0;
    bit [5:0]    sram_ser_inject_addr = 6'd0;
    bit [143:0]  sram_ser_inject_mask = '0;

    // Observed DUT Outputs
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

    bit [7:0]        act_pwr_raw_demand;
    bit [7:0]        act_pwr_eff_current;
    bit [7:0]        act_pwr_dummy_bleed_current;
    bit [7:0]        act_pwr_dummy_bleed_mask;
    bit signed [8:0] act_pwr_didt_signed;
    bit [11:0]       act_pwr_vdd_est_mv;
    bit [7:0]        act_pwr_thermal_temp_c;
    bit              act_pwr_emerg_throttle;
    bit [15:0]       act_pwr_droop_mitigated_events;

    bit [3:0]    act_sram_bank_repair_en;
    bit [23:0]   act_sram_bank_repair_addr;
    bit          act_sram_efuse_load_ack;
    bit          act_sram_vliw_rd_valid;
    bit [127:0]  act_sram_vliw_rd_data;
    bit          act_sram_vliw_rd_sec_err;
    bit          act_sram_vliw_rd_ded_err;
    bit          act_sram_vliw_rd_repaired_row_hit;
    bit          act_sram_scrub_rd_fire;
    bit          act_sram_scrub_wb_fire;
    bit [1:0]    act_sram_scrub_active_bank;
    bit [5:0]    act_sram_scrub_active_addr;
    bit [15:0]   act_sram_scrub_corrected_cnt;
    bit          act_sram_scrub_ded_alert;
    bit [1:0]    act_sram_first_ded_bank;
    bit [5:0]    act_sram_first_ded_addr;

    function new(string name = "spec_power_scrub_seq_item");
      super.new(name);
    endfunction
  endclass : spec_power_scrub_seq_item

  typedef uvm_sequencer #(spec_power_scrub_seq_item) spec_power_scrub_sequencer;

  // ---------------------------------------------------------------------------
  // 3. UVM Sequence (3,600 Cycles across 4 Verification Phases)
  // ---------------------------------------------------------------------------
  class spec_power_scrub_sequence extends uvm_sequence #(spec_power_scrub_seq_item);
    `uvm_object_utils(spec_power_scrub_sequence)

    int unsigned next_tx_id = 0;

    function new(string name = "spec_power_scrub_sequence");
      super.new(name);
    endfunction

 function automatic bit [127:0] gen_entropy_128(input int c, input int salt);
 bit [31:0] w0, w1, w2, w3;
 w0 = 32'(c * 32'h9E37_79B9 + salt * 32'h85EB_CA6B + 32'h1234_5678);
 w1 = 32'((w0 ^ (w0 >> 13)) * 32'hC2B2_AE35);
 w2 = 32'((w1 ^ (w1 >> 15)) * 32'h27D4_EB2F);
 w3 = 32'((w2 ^ (w2 >> 11)) * 32'h1656_67B1);
 return {w3, w2, w1, w0};
 endfunction

 function automatic void apply_spec_stimulus(ref spec_power_scrub_seq_item it, input int c);
 it.spec_valid = (c % 37 != 36);
 it.spec_op_mode = (c < 200) ? 2'd0 :
 (c < 400) ? 2'd1 :
 (c < 720) ? 2'd2 :
 (c < 800) ? 2'd3 : 2'(c % 4);
 it.spec_logits = (c % 16 == 0) ? ~gen_entropy_128(c, 11) : gen_entropy_128(c, 11);
 it.spec_token_ids = (c % 16 == 1) ? ~gen_entropy_128(c, 12) : gen_entropy_128(c, 12);
 it.spec_top_k = 4'(c % 16);
 it.spec_inv_temp = (c % 8 == 0) ? 8'd0 : (c % 8 == 1) ? 8'd255 : 8'(1 + ((c * 13) % 64));
 it.spec_top_p_thresh = (c % 6 == 0) ? 16'h0000 :
 (c % 6 == 1) ? 16'hFFFF : 16'(128 + ((c * 97) % 3500));
 it.spec_rng_seed_step = (c % 3 != 0);
 it.spec_rng_threshold = 8'(c * 29 + 7);
 it.spec_tree_draft_tok = gen_entropy_128(c, 13)[63:0];
 it.spec_bonus_tok = 8'(c * 17 ^ 8'hA5);

 if (c >= 400 && c < 720) begin
 // Directed tree topologies to guarantee best_leaf_idx 0..7 and depths 1..4
 int sub = (c - 400) % 16;
 case (sub)
 0: begin
 // Depth 1: reject all nodes 1..7 -> best_leaf_idx = 0, accepted_draft_len = 1
 it.spec_tree_parent_idx = 24'h00_0000;
 it.spec_tree_target_prob = 64'h0000_0000_0000_00F0;
 it.spec_tree_draft_prob = 64'hFFFF_FFFF_FFFF_FF10;
 it.spec_tree_rand_u = 64'hFFFF_FFFF_FFFF_FF00;
 end
 1, 2, 3, 4, 5, 6, 7: begin
 // Depth 2: node sub has parent 0 and highest prob -> best_leaf_idx = sub, depth = 2
 it.spec_tree_parent_idx = 24'h00_0000;
 it.spec_tree_target_prob = 64'(64'hFF << (8 * sub)) | 64'h10;
 it.spec_tree_draft_prob = 64'(64'h10 << (8 * sub)) | 64'hFF_FFFF_FFFF_FF00;
 it.spec_tree_rand_u = 64'hFFFF_FFFF_FFFF_FF00 ^ (64'hFF << (8 * sub));
 end
 8: begin
 // Depth 3: chain 0 -> 1 -> 2 accepted -> best_leaf_idx = 2, depth = 3
 it.spec_tree_parent_idx = (24'd1 << 6) | (24'd0 << 3);
 it.spec_tree_target_prob = 64'h0000_0000_00F8_E0D0;
 it.spec_tree_draft_prob = 64'hFFFF_FFFF_FF10_1010;
 it.spec_tree_rand_u = 64'hFFFF_FFFF_FF00_0000;
 end
 9: begin
 // Depth 4: chain 0 -> 1 -> 2 -> 3 accepted -> best_leaf_idx = 3, depth = 4
 it.spec_tree_parent_idx = (24'd2 << 9) | (24'd1 << 6) | (24'd0 << 3);
 it.spec_tree_target_prob = 64'h0000_0000_FC_F0_E0_D0;
 it.spec_tree_draft_prob = 64'hFFFF_FFFF_10_10_10_10;
 it.spec_tree_rand_u = 64'hFFFF_FFFF_00_00_00_00;
 end
 10: begin
 // Depth 4 with leaf at node 7: 0 -> 2 -> 5 -> 7 -> best_leaf_idx = 7, depth = 4
 it.spec_tree_parent_idx = (24'd5 << 21) | (24'd2 << 15) | (24'd0 << 6);
 it.spec_tree_target_prob = 64'hFE_00_F0_00_00_E0_00_D0;
 it.spec_tree_draft_prob = 64'h10_FF_10_FF_FF_10_FF_10;
 it.spec_tree_rand_u = 64'h00_FF_00_FF_FF_00_FF_00;
 end
 11: begin
 // Invalid parent index (p_idx >= d) & depth > 4 saturation
 it.spec_tree_parent_idx = 24'hFF_FFFF;
 it.spec_tree_target_prob = 64'hFFFF_FFFF_FFFF_FFFF;
 it.spec_tree_draft_prob = 64'h1010_1010_1010_1010;
 it.spec_tree_rand_u = 64'h0;
 end
 default: begin
 // Probabilistic acceptance (p_d < q_d, lhs_p >= rhs_uq) + tie-breaking
 it.spec_tree_parent_idx = (24'd4 << 18) | (24'd2 << 12) | (24'd1 << 9) | (24'd0 << 6) | (24'd0 << 3);
 it.spec_tree_target_prob = gen_entropy_128(c, 14)[63:0];
 it.spec_tree_draft_prob = gen_entropy_128(c, 15)[63:0];
 it.spec_tree_rand_u = gen_entropy_128(c, 16)[63:0];
 end
 endcase
 end else begin
 it.spec_tree_parent_idx = gen_entropy_128(c, 17)[23:0];
 it.spec_tree_target_prob = gen_entropy_128(c, 18)[63:0];
 it.spec_tree_draft_prob = gen_entropy_128(c, 19)[63:0];
 it.spec_tree_rand_u = gen_entropy_128(c, 20)[63:0];
 end
 endfunction

    function automatic void apply_pwr_stimulus(ref spec_power_scrub_seq_item it, input int c);
      it.pwr_enable                = (c != 10 && c != 405 && c != 1595);
      it.pwr_vdd_nominal_mv        = (c >= 750 && c < 770) ? 12'd40  :
                                     (c >= 770 && c < 780) ? 12'hAAA :
                                     (c >= 780 && c < 790) ? 12'h555 :
                                     (c >= 790 && c < 795) ? 12'hFFF : 12'd850;
      it.pwr_droop_emerg_thresh_mv = (c >= 770 && c < 780) ? 12'h555 :
                                     (c >= 780 && c < 790) ? 12'hAAA :
                                     (c >= 790 && c < 795) ? 12'hFFF :
                                     (c >= 795 && c < 800) ? 12'h000 : 12'd760;

      if (c < 100) begin
        // Pre-warmed ramp up from 0 -> 220 with max_didt_step = 16
        it.pwr_slice_active         = (c < 20) ? 8'h00 : 8'hFF;
        it.pwr_mxm_zero_skip_cnt    = 6'd0;
        it.pwr_prewarm_hint         = (c < 25);
        it.pwr_prewarm_target_level = 8'd224;
        it.pwr_max_didt_step        = 8'd16;
      end else if (c < 200) begin
        // Post-burst ramp down from 240 -> 0 with small step = 4 (triggers all 8 bleed mask bits!)
        it.pwr_slice_active         = 8'h00;
        it.pwr_mxm_zero_skip_cnt    = 6'd32;
        it.pwr_prewarm_hint         = 1'b0;
        it.pwr_prewarm_target_level = 8'd0;
        it.pwr_max_didt_step        = 8'd4;
      end else if (c < 300) begin
        // Unmitigated step jumps (large max_didt_step = 250) causing inductive L*di/dt droop < 760mV
        it.pwr_slice_active         = c[0] ? 8'hFF : 8'h00;
        it.pwr_mxm_zero_skip_cnt    = 6'(c % 48); // covers > 32 clamp
        it.pwr_prewarm_hint         = 1'b0;
        it.pwr_prewarm_target_level = 8'd0;
        it.pwr_max_didt_step        = 8'd250;
      end else if (c >= 1600 && c < 2120) begin
        // Phase 2 sustained max power (raw_demand = 240 -> temp_eq = 105C) to drive thermal_temp_c_o to 105C!
        it.pwr_enable               = 1'b1;
        it.pwr_slice_active         = 8'hFF;
        it.pwr_mxm_zero_skip_cnt    = 6'd0;
        it.pwr_prewarm_hint         = 1'b1;
        it.pwr_prewarm_target_level = 8'd240;
        it.pwr_max_didt_step        = 8'd32;
      end else if (c >= 2120 && c < 2250) begin
        // Phase 2 cooling (raw_demand = 0 -> temp_eq = 45C) so thermal_temp_c_o cools down
        it.pwr_enable               = 1'b1;
        it.pwr_slice_active         = 8'h00;
        it.pwr_mxm_zero_skip_cnt    = 6'd40;
        it.pwr_prewarm_hint         = 1'b0;
        it.pwr_prewarm_target_level = 8'd0;
        it.pwr_max_didt_step        = 8'd8;
      end else begin
        it.pwr_slice_active         = gen_entropy_128(c, 21)[7:0];
        it.pwr_mxm_zero_skip_cnt    = gen_entropy_128(c, 22)[5:0];
        it.pwr_prewarm_hint         = c[1];
        it.pwr_prewarm_target_level = gen_entropy_128(c, 23)[7:0];
        it.pwr_max_didt_step        = 8'(4 + (c % 64));
      end
    endfunction

    function automatic void apply_sram_stimulus(ref spec_power_scrub_seq_item it, input int c);
      if (c < 128) begin
        // Initialize all 256 words (4 banks x 64 rows) + load eFuse repair table
        it.sram_efuse_load_req = (c < 16);
        it.sram_efuse_bank     = 2'(c % 4);
        it.sram_efuse_bad_addr = (c < 4) ? 6'h3F : (c < 8) ? 6'h00 : (c < 12) ? 6'h2A : 6'(4 + (c % 4) * 5);

        it.sram_vliw_wr_en   = 1'b1;
        it.sram_vliw_wr_bank = 2'(c[6]);
        it.sram_vliw_wr_addr = 6'(c[5:0]);
        it.sram_vliw_wr_data = (c[0]) ? ~gen_entropy_128(c, 31) : gen_entropy_128(c, 31);

        it.sram_dma_wr_en    = 1'b1;
        it.sram_dma_wr_bank  = 2'(2 + c[6]);
        it.sram_dma_wr_addr  = 6'(c[5:0]);
        it.sram_dma_wr_data  = (c[0]) ? ~gen_entropy_128(c, 32) : gen_entropy_128(c, 32);

        it.sram_vliw_rd_en   = (c >= 16);
        it.sram_vliw_rd_bank = 2'(c % 4);
        it.sram_vliw_rd_addr = (c % 8 < 4) ? 6'(4 + (c % 4) * 5) : 6'(c[5:0]);
        it.sram_scrub_enable = 1'b0;
      end else if (c >= 128 && c < 272) begin
        // 72 pairs of cycles: inject walking-1 error in lo & hi, then VLIW read next cycle
        int step = c - 128;
        int bit_idx = step >> 1;
        bit [1:0] b_bank = 2'(bit_idx & 3);
        bit [5:0] b_addr = 6'(bit_idx >> 2);
        it.sram_scrub_enable = 1'b0;
        if ((step & 1) == 0) begin
          it.sram_ser_inject_en   = 1'b1;
          it.sram_ser_inject_bank = b_bank;
          it.sram_ser_inject_addr = b_addr;
          it.sram_ser_inject_mask = (144'd1 << bit_idx) | (144'd1 << (72 + bit_idx));
        end else begin
          it.sram_vliw_rd_en   = 1'b1;
          it.sram_vliw_rd_bank = b_bank;
          it.sram_vliw_rd_addr = b_addr;
        end
      end else if (c >= 272 && c < 650) begin
        // Background scrubber heals all 72 walking-1 errors in banks 0..3, addr 0..17
        it.sram_scrub_enable = 1'b1;
        // Foreground accesses restricted to addr 32..63 so scrubber heals 0..17 uninterrupted
        it.sram_vliw_rd_en   = (c % 5 == 0);
        it.sram_vliw_rd_bank = 2'(c % 4);
        it.sram_vliw_rd_addr = 6'(32 + (c % 32));
        it.sram_vliw_wr_en   = (c % 7 == 0);
        it.sram_vliw_wr_bank = 2'((c + 1) % 4);
        it.sram_vliw_wr_addr = 6'(32 + ((c * 3) % 32));
        it.sram_vliw_wr_data = gen_entropy_128(c, 33);
        it.sram_dma_wr_en    = (c % 9 == 0);
        it.sram_dma_wr_bank  = 2'((c + 2) % 4);
        it.sram_dma_wr_addr  = 6'(32 + ((c * 5) % 32));
        it.sram_dma_wr_data  = gen_entropy_128(c, 34);
      end else if (c >= 650 && c < 780) begin
        // Inject 2-bit DED errors & test VLIW DED read + Scrubber DED alert + wb_pending overwrite
        int dstep = c - 650;
        it.sram_scrub_enable = 1'b1;
        if (dstep < 40) begin
          if ((dstep & 1) == 0) begin
            int b0 = (dstep >> 1) % 70;
            it.sram_ser_inject_en   = 1'b1;
            it.sram_ser_inject_bank = 2'd3;
            it.sram_ser_inject_addr = 6'h3F;
            it.sram_ser_inject_mask = (144'd3 << b0) | (144'd3 << (72 + b0));
          end else begin
            it.sram_vliw_rd_en   = 1'b1;
            it.sram_vliw_rd_bank = 2'd3;
            it.sram_vliw_rd_addr = 6'h3F;
          end
        end else begin
          // Inject 1-bit error right at current scrub pointer and overwrite next cycle
          it.sram_ser_inject_en   = (dstep % 3 == 0);
          it.sram_ser_inject_bank = 2'(c % 4);
          it.sram_ser_inject_addr = 6'(c % 64);
          it.sram_ser_inject_mask = (144'd1 << (c % 72));
          it.sram_vliw_wr_en      = (dstep % 3 == 1);
          it.sram_vliw_wr_bank    = 2'(c % 4);
          it.sram_vliw_wr_addr    = 6'(c % 64);
          it.sram_vliw_wr_data    = gen_entropy_128(c, 35);
        end
      end else begin
        // High-entropy mixed foreground VLIW/DMA + background scrubbing + periodic SER
        it.sram_efuse_load_req  = (c % 250 == 0);
        it.sram_efuse_bank      = 2'((c / 250) % 4);
        it.sram_efuse_bad_addr  = 6'(4 + ((c / 250) % 4) * 5);
        it.sram_scrub_enable    = (c % 64 != 63);
        it.sram_vliw_rd_en      = (c % 3 != 2);
        it.sram_vliw_rd_bank    = 2'(c % 4);
        it.sram_vliw_rd_addr    = (c % 16 == 0) ? 6'(4 + (c % 4) * 5) : 6'((c * 7) % 64);
        it.sram_vliw_wr_en      = (c % 5 == 0);
        it.sram_vliw_wr_bank    = 2'((c >> 1) % 4);
        it.sram_vliw_wr_addr    = 6'((c * 11) % 64);
        it.sram_vliw_wr_data    = gen_entropy_128(c, 36);
        it.sram_dma_wr_en       = (c % 6 == 0);
        it.sram_dma_wr_bank     = 2'((c >> 2) % 4);
        it.sram_dma_wr_addr     = 6'((c * 13) % 64);
        it.sram_dma_wr_data     = gen_entropy_128(c, 37);
        if ((c % 11 == 3) && !it.sram_vliw_wr_en && !it.sram_dma_wr_en) begin
          it.sram_ser_inject_en   = 1'b1;
          it.sram_ser_inject_bank = 2'(c % 4);
          it.sram_ser_inject_addr = 6'((c * 17) % 64);
          if (c % 33 == 3) begin
            it.sram_ser_inject_mask = (144'd3 << (c % 70));
          end else begin
            it.sram_ser_inject_mask = (144'd1 << (c % 144));
          end
        end
      end
    endfunction

    task body();
      for (int c = 0; c < 3600; c++) begin
        spec_power_scrub_seq_item it = spec_power_scrub_seq_item::type_id::create("it");
        start_item(it);
        it.tx_id    = next_tx_id++;
        it.phase_id = (c < 800) ? 0 : (c < 1600) ? 1 : (c < 2400) ? 2 : 3;
        apply_spec_stimulus(it, c);
        apply_pwr_stimulus(it, c);
        apply_sram_stimulus(it, c);
        finish_item(it);
      end
    endtask
  endclass : spec_power_scrub_sequence

  // ---------------------------------------------------------------------------
  // 4. UVM Driver, Monitor & Agent
  // ---------------------------------------------------------------------------
  class spec_power_scrub_driver extends uvm_driver #(spec_power_scrub_seq_item);
    `uvm_component_utils(spec_power_scrub_driver)

    virtual spec_power_scrub_if vif;
    int unsigned driven = 0;

    function new(string name = "spec_power_scrub_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual spec_power_scrub_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface spec_power_scrub_if missing in driver")
      end
    endfunction

 task run_phase(uvm_phase phase);
 spec_power_scrub_seq_item item;
 vif.sample_en = 1'b0;
 vif.rst_n = 1'b0;
 @(negedge vif.clk);
 vif.rst_n = 1'b1;
 @(negedge vif.clk);
 vif.rst_n = 1'b0;
 repeat (2) @(negedge vif.clk);

 forever begin
 seq_item_port.get_next_item(item);
 vif.rst_n = 1'b1;
 vif.sample_en = 1'b1;
 vif.tx_id = item.tx_id;
 vif.phase_id = item.phase_id;

 vif.spec_valid_i = item.spec_valid;
 vif.spec_op_mode_i = item.spec_op_mode;
 vif.spec_logits_i = item.spec_logits;
 vif.spec_token_ids_i = item.spec_token_ids;
 vif.spec_top_k_i = item.spec_top_k;
 vif.spec_inv_temp_i = item.spec_inv_temp;
 vif.spec_top_p_thresh_i = item.spec_top_p_thresh;
 vif.spec_rng_seed_step_i = item.spec_rng_seed_step;
 vif.spec_rng_threshold_i = item.spec_rng_threshold;
 vif.spec_tree_parent_idx_i = item.spec_tree_parent_idx;
 vif.spec_tree_draft_prob_i = item.spec_tree_draft_prob;
 vif.spec_tree_target_prob_i = item.spec_tree_target_prob;
 vif.spec_tree_rand_u_i = item.spec_tree_rand_u;
 vif.spec_tree_draft_tok_i = item.spec_tree_draft_tok;
 vif.spec_bonus_tok_i = item.spec_bonus_tok;

 vif.pwr_enable_i = item.pwr_enable;
 vif.pwr_slice_active_i = item.pwr_slice_active;
 vif.pwr_mxm_zero_skip_cnt_i = item.pwr_mxm_zero_skip_cnt;
 vif.pwr_prewarm_hint_i = item.pwr_prewarm_hint;
 vif.pwr_prewarm_target_level_i = item.pwr_prewarm_target_level;
 vif.pwr_max_didt_step_i = item.pwr_max_didt_step;
 vif.pwr_vdd_nominal_mv_i = item.pwr_vdd_nominal_mv;
 vif.pwr_droop_emerg_thresh_mv_i = item.pwr_droop_emerg_thresh_mv;

 vif.sram_efuse_load_req_i = item.sram_efuse_load_req;
 vif.sram_efuse_bank_i = item.sram_efuse_bank;
 vif.sram_efuse_bad_addr_i = item.sram_efuse_bad_addr;
 vif.sram_vliw_rd_en_i = item.sram_vliw_rd_en;
 vif.sram_vliw_rd_bank_i = item.sram_vliw_rd_bank;
 vif.sram_vliw_rd_addr_i = item.sram_vliw_rd_addr;
 vif.sram_vliw_wr_en_i = item.sram_vliw_wr_en;
 vif.sram_vliw_wr_bank_i = item.sram_vliw_wr_bank;
 vif.sram_vliw_wr_addr_i = item.sram_vliw_wr_addr;
 vif.sram_vliw_wr_data_i = item.sram_vliw_wr_data;
 vif.sram_dma_wr_en_i = item.sram_dma_wr_en;
 vif.sram_dma_wr_bank_i = item.sram_dma_wr_bank;
 vif.sram_dma_wr_addr_i = item.sram_dma_wr_addr;
 vif.sram_dma_wr_data_i = item.sram_dma_wr_data;
 vif.sram_scrub_enable_i = item.sram_scrub_enable;
 vif.sram_ser_inject_en_i = item.sram_ser_inject_en;
 vif.sram_ser_inject_bank_i = item.sram_ser_inject_bank;
 vif.sram_ser_inject_addr_i = item.sram_ser_inject_addr;
 vif.sram_ser_inject_mask_i = item.sram_ser_inject_mask;

 @(negedge vif.clk);
 vif.sample_en = 1'b0;
 driven++;
 seq_item_port.item_done();
 end
 endtask
 endclass : spec_power_scrub_driver

  class spec_power_scrub_monitor extends uvm_monitor;
    `uvm_component_utils(spec_power_scrub_monitor)

    virtual spec_power_scrub_if vif;
    uvm_analysis_port #(spec_power_scrub_seq_item) ap;
    int unsigned seen = 0;

    function new(string name = "spec_power_scrub_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual spec_power_scrub_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface spec_power_scrub_if missing in monitor")
      end
    endfunction

    task run_phase(uvm_phase phase);
      forever begin
        @(negedge vif.clk);
        #1ns;
        if (vif.rst_n && vif.sample_en) begin
          spec_power_scrub_seq_item item = spec_power_scrub_seq_item::type_id::create("obs_item");
 item.tx_id = vif.tx_id;
 item.phase_id = vif.phase_id;

 item.spec_valid = vif.spec_valid_i;
 item.spec_op_mode = vif.spec_op_mode_i;
 item.spec_logits = vif.spec_logits_i;
 item.spec_token_ids = vif.spec_token_ids_i;
 item.spec_top_k = vif.spec_top_k_i;
 item.spec_inv_temp = vif.spec_inv_temp_i;
 item.spec_top_p_thresh = vif.spec_top_p_thresh_i;
 item.spec_rng_seed_step = vif.spec_rng_seed_step_i;
 item.spec_rng_threshold = vif.spec_rng_threshold_i;
 item.spec_tree_parent_idx = vif.spec_tree_parent_idx_i;
 item.spec_tree_draft_prob = vif.spec_tree_draft_prob_i;
 item.spec_tree_target_prob = vif.spec_tree_target_prob_i;
 item.spec_tree_rand_u = vif.spec_tree_rand_u_i;
 item.spec_tree_draft_tok = vif.spec_tree_draft_tok_i;
 item.spec_bonus_tok = vif.spec_bonus_tok_i;

 item.pwr_enable = vif.pwr_enable_i;
 item.pwr_slice_active = vif.pwr_slice_active_i;
 item.pwr_mxm_zero_skip_cnt = vif.pwr_mxm_zero_skip_cnt_i;
 item.pwr_prewarm_hint = vif.pwr_prewarm_hint_i;
 item.pwr_prewarm_target_level = vif.pwr_prewarm_target_level_i;
 item.pwr_max_didt_step = vif.pwr_max_didt_step_i;
 item.pwr_vdd_nominal_mv = vif.pwr_vdd_nominal_mv_i;
 item.pwr_droop_emerg_thresh_mv = vif.pwr_droop_emerg_thresh_mv_i;

 item.sram_efuse_load_req = vif.sram_efuse_load_req_i;
 item.sram_efuse_bank = vif.sram_efuse_bank_i;
 item.sram_efuse_bad_addr = vif.sram_efuse_bad_addr_i;
 item.sram_vliw_rd_en = vif.sram_vliw_rd_en_i;
 item.sram_vliw_rd_bank = vif.sram_vliw_rd_bank_i;
 item.sram_vliw_rd_addr = vif.sram_vliw_rd_addr_i;
 item.sram_vliw_wr_en = vif.sram_vliw_wr_en_i;
 item.sram_vliw_wr_bank = vif.sram_vliw_wr_bank_i;
 item.sram_vliw_wr_addr = vif.sram_vliw_wr_addr_i;
 item.sram_vliw_wr_data = vif.sram_vliw_wr_data_i;
 item.sram_dma_wr_en = vif.sram_dma_wr_en_i;
 item.sram_dma_wr_bank = vif.sram_dma_wr_bank_i;
 item.sram_dma_wr_addr = vif.sram_dma_wr_addr_i;
 item.sram_dma_wr_data = vif.sram_dma_wr_data_i;
 item.sram_scrub_enable = vif.sram_scrub_enable_i;
 item.sram_ser_inject_en = vif.sram_ser_inject_en_i;
 item.sram_ser_inject_bank = vif.sram_ser_inject_bank_i;
 item.sram_ser_inject_addr = vif.sram_ser_inject_addr_i;
 item.sram_ser_inject_mask = vif.sram_ser_inject_mask_i;

 // Sample pre-posedge combinational outputs
 item.act_pwr_raw_demand = vif.pwr_raw_demand_o;
 item.act_pwr_dummy_bleed_current = vif.pwr_dummy_bleed_current_o;
 item.act_pwr_dummy_bleed_mask = vif.pwr_dummy_bleed_mask_o;
 item.act_pwr_didt_signed = vif.pwr_didt_signed_o;
 item.act_pwr_vdd_est_mv = vif.pwr_vdd_est_mv_o;
 item.act_pwr_emerg_throttle = vif.pwr_emerg_throttle_o;

 item.act_sram_scrub_rd_fire = vif.sram_scrub_rd_fire_o;
 item.act_sram_scrub_wb_fire = vif.sram_scrub_wb_fire_o;
 item.act_sram_scrub_active_bank = vif.sram_scrub_active_bank_o;
 item.act_sram_scrub_active_addr = vif.sram_scrub_active_addr_o;

 // Wait for posedge clk and sample post-posedge registered outputs
 @(posedge vif.clk);
 #1ps;
 item.act_spec_valid = vif.spec_valid_o;
 item.act_spec_selected_token = vif.spec_selected_token_o;
 item.act_spec_selected_logit = vif.spec_selected_logit_o;
 item.act_spec_sorted_logits = vif.spec_sorted_logits_o;
 item.act_spec_sorted_tokens = vif.spec_sorted_tokens_o;
 item.act_spec_nucleus_mask = vif.spec_nucleus_mask_o;
 item.act_spec_accepted_node_mask = vif.spec_accepted_node_mask_o;
 item.act_spec_best_leaf_idx = vif.spec_best_leaf_idx_o;
 item.act_spec_accepted_draft_len = vif.spec_accepted_draft_len_o;
 item.act_spec_total_emitted_tokens = vif.spec_total_emitted_tokens_o;
 item.act_spec_committed_tokens = vif.spec_committed_tokens_o;
 item.act_spec_kv_ring_advance = vif.spec_kv_ring_advance_o;
 item.act_spec_prng_state = vif.spec_prng_state_o;

 item.act_pwr_eff_current = vif.pwr_eff_current_o;
 item.act_pwr_thermal_temp_c = vif.pwr_thermal_temp_c_o;
 item.act_pwr_droop_mitigated_events = vif.pwr_droop_mitigated_events_o;

 item.act_sram_bank_repair_en = vif.sram_bank_repair_en_o;
 item.act_sram_bank_repair_addr = {vif.sram_bank_repair_addr_o[3],
 vif.sram_bank_repair_addr_o[2],
 vif.sram_bank_repair_addr_o[1],
 vif.sram_bank_repair_addr_o[0]};
 item.act_sram_efuse_load_ack = vif.sram_efuse_load_ack_o;
 item.act_sram_vliw_rd_valid = vif.sram_vliw_rd_valid_o;
 item.act_sram_vliw_rd_data = vif.sram_vliw_rd_data_o;
 item.act_sram_vliw_rd_sec_err = vif.sram_vliw_rd_sec_err_o;
 item.act_sram_vliw_rd_ded_err = vif.sram_vliw_rd_ded_err_o;
 item.act_sram_vliw_rd_repaired_row_hit = vif.sram_vliw_rd_repaired_row_hit_o;
 item.act_sram_scrub_corrected_cnt = vif.sram_scrub_corrected_cnt_o;
 item.act_sram_scrub_ded_alert = vif.sram_scrub_ded_alert_o;
 item.act_sram_first_ded_bank = vif.sram_first_ded_bank_o;
 item.act_sram_first_ded_addr = vif.sram_first_ded_addr_o;

 seen++;
 ap.write(item);
 end
 end
 endtask
 endclass : spec_power_scrub_monitor

  class spec_power_scrub_agent extends uvm_agent;
    `uvm_component_utils(spec_power_scrub_agent)

    spec_power_scrub_sequencer sequencer;
    spec_power_scrub_driver    driver;
    spec_power_scrub_monitor   monitor;

    function new(string name = "spec_power_scrub_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = spec_power_scrub_sequencer::type_id::create("sequencer", this);
      driver    = spec_power_scrub_driver::type_id::create("driver", this);
      monitor   = spec_power_scrub_monitor::type_id::create("monitor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass : spec_power_scrub_agent

  // ---------------------------------------------------------------------------
  // 5. UVM Functional Coverage Subscriber (uvm_subscriber)
  // ---------------------------------------------------------------------------
  class spec_power_scrub_cov_subscriber extends uvm_subscriber #(spec_power_scrub_seq_item);
    `uvm_component_utils(spec_power_scrub_cov_subscriber)

 covergroup spec_power_scrub_cg with function sample(
 bit [1:0] spec_mode,
 bit [3:0] spec_topk,
 bit spec_rng_step,
 bit [2:0] spec_leaf_idx,
 bit [2:0] spec_draft_len,
 bit pwr_en,
 bit pwr_prewarm,
 bit pwr_bleed_act,
 bit pwr_emerg,
 bit [7:0] pwr_temp,
 bit sram_efuse_ack,
 bit sram_rep_hit,
 bit sram_vliw_sec,
 bit sram_vliw_ded,
 bit sram_scrub_rd,
 bit sram_scrub_wb,
 bit sram_scrub_ded,
 bit [1:0] sram_scrub_bank
 );
 option.per_instance = 1;

 cp_spec_mode: coverpoint spec_mode {
 bins greedy = {2'd0};
 bins topk_topp = {2'd1};
 bins spec_tree = {2'd2};
 bins def_mode = {2'd3};
 }
 cp_spec_topk: coverpoint spec_topk {
 bins k_unbounded = {4'd0};
 bins k_small = {[4'd1:4'd4]};
 bins k_medium = {[4'd5:4'd10]};
 bins k_large = {[4'd11:4'd15]};
 }
 cp_spec_rng_step: coverpoint spec_rng_step {
 bins hold = {1'b0};
 bins step = {1'b1};
 }
 cp_spec_leaf_idx: coverpoint spec_leaf_idx {
 bins leaf[] = {[3'd0:3'd7]};
 }
 cp_spec_draft_len: coverpoint spec_draft_len {
 bins d1 = {3'd1};
 bins d2 = {3'd2};
 bins d3 = {3'd3};
 bins d4 = {3'd4};
 }
 cp_pwr_en: coverpoint pwr_en {
 bins off = {1'b0};
 bins on = {1'b1};
 }
 cp_pwr_prewarm: coverpoint pwr_prewarm {
 bins off = {1'b0};
 bins on = {1'b1};
 }
 cp_pwr_bleed_act: coverpoint pwr_bleed_act {
 bins idle = {1'b0};
 bins active = {1'b1};
 }
 cp_pwr_emerg: coverpoint pwr_emerg {
 bins normal = {1'b0};
 bins throttle = {1'b1};
 }
 cp_pwr_temp: coverpoint pwr_temp {
 bins cool_base = {[8'd45:8'd59]};
 bins warm_mid = {[8'd60:8'd89]};
 bins hot_high = {[8'd90:8'd104]};
 bins trip_105 = {[8'd105:8'd255]};
 }
 cp_sram_efuse_ack: coverpoint sram_efuse_ack { bins b0 = {1'b0}; bins b1 = {1'b1}; }
 cp_sram_rep_hit: coverpoint sram_rep_hit { bins b0 = {1'b0}; bins b1 = {1'b1}; }
 cp_sram_vliw_sec: coverpoint sram_vliw_sec { bins b0 = {1'b0}; bins b1 = {1'b1}; }
 cp_sram_vliw_ded: coverpoint sram_vliw_ded { bins b0 = {1'b0}; bins b1 = {1'b1}; }
 cp_sram_scrub_rd: coverpoint sram_scrub_rd { bins b0 = {1'b0}; bins b1 = {1'b1}; }
 cp_sram_scrub_wb: coverpoint sram_scrub_wb { bins b0 = {1'b0}; bins b1 = {1'b1}; }
 cp_sram_scrub_ded: coverpoint sram_scrub_ded { bins b0 = {1'b0}; bins b1 = {1'b1}; }
 cp_sram_scrub_bank: coverpoint sram_scrub_bank {
 bins bank[] = {[2'd0:2'd3]};
 }
 endgroup

    function new(string name = "spec_power_scrub_cov_subscriber", uvm_component parent = null);
      super.new(name, parent);
      spec_power_scrub_cg = new();
    endfunction

 function void write(spec_power_scrub_seq_item t);
 spec_power_scrub_cg.sample(
 t.spec_op_mode,
 t.spec_top_k,
 t.spec_rng_seed_step,
 t.act_spec_best_leaf_idx,
 t.act_spec_accepted_draft_len,
 t.pwr_enable,
 t.pwr_prewarm_hint,
 (t.act_pwr_dummy_bleed_current != 8'd0),
 t.act_pwr_emerg_throttle,
 t.act_pwr_thermal_temp_c,
 t.act_sram_efuse_load_ack,
 t.act_sram_vliw_rd_repaired_row_hit,
 t.act_sram_vliw_rd_sec_err,
 t.act_sram_vliw_rd_ded_err,
 t.act_sram_scrub_rd_fire,
 t.act_sram_scrub_wb_fire,
 t.act_sram_scrub_ded_alert,
 t.act_sram_scrub_active_bank
 );
 endfunction
 endclass : spec_power_scrub_cov_subscriber

  // ---------------------------------------------------------------------------
  // 6. UVM Scoreboard with Bit-Exact C++17 DPI-C Reference Model Comparison
  // ---------------------------------------------------------------------------
  class spec_power_scrub_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(spec_power_scrub_scoreboard)

    uvm_analysis_imp #(spec_power_scrub_seq_item, spec_power_scrub_scoreboard) imp;

    int unsigned checked_cycles            = 0;
    int unsigned spec_checks               = 0;
    int unsigned pwr_checks                = 0;
    int unsigned sram_checks               = 0;
    int unsigned spec_mismatches           = 0;
    int unsigned pwr_mismatches            = 0;
    int unsigned sram_mismatches           = 0;
    int unsigned mismatches                = 0;
    int unsigned spec_tree_multi_accept    = 0;
    int unsigned pwr_bleed_mitigated_cnt   = 0;
    int unsigned pwr_emerg_throttle_events = 0;
    int unsigned sram_vliw_sec_events      = 0;
    int unsigned sram_vliw_ded_events      = 0;
    int unsigned sram_scrub_wb_events      = 0;
    int unsigned sram_repaired_hit_events  = 0;

    function new(string name = "spec_power_scrub_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      imp = new("imp", this);
    endfunction

 function void build_phase(uvm_phase phase);
 super.build_phase(phase);
 dpi_spec_power_scrub_reset();
 endfunction

 function void write(spec_power_scrub_seq_item item);
 int unsigned exp_spec_valid, exp_spec_sel_tok, exp_spec_sel_logit;
 bit [127:0] exp_spec_sorted_logits, exp_spec_sorted_tokens;
 int unsigned exp_spec_nuc_mask, exp_spec_acc_mask, exp_spec_leaf_idx;
 int unsigned exp_spec_draft_len, exp_spec_tot_emit, exp_spec_kv_adv, exp_spec_prng;
 longint unsigned exp_spec_committed;

 int unsigned exp_pwr_raw, exp_pwr_eff, exp_pwr_bleed, exp_pwr_mask;
 int exp_pwr_didt;
 int unsigned exp_pwr_vdd, exp_pwr_temp, exp_pwr_emerg, exp_pwr_events;

 int unsigned exp_sram_rep_en, exp_sram_rep_addr, exp_sram_efuse_ack;
 int unsigned exp_sram_rd_val, exp_sram_rd_sec, exp_sram_rd_ded, exp_sram_rep_hit;
 bit [127:0] exp_sram_rd_data;
 int unsigned exp_sram_scrub_rd, exp_sram_scrub_wb, exp_sram_scrub_bank, exp_sram_scrub_addr;
 int unsigned exp_sram_corr_cnt, exp_sram_ded_alert, exp_sram_ded_bank, exp_sram_ded_addr;

 dpi_spec_sampler_step(
 int'(item.spec_valid),
 int'(item.spec_op_mode),
 item.spec_logits,
 item.spec_token_ids,
 int'(item.spec_top_k),
 int'(item.spec_inv_temp),
 int'(item.spec_top_p_thresh),
 int'(item.spec_rng_seed_step),
 int'(item.spec_rng_threshold),
 int'(item.spec_tree_parent_idx),
 longint'(item.spec_tree_draft_prob),
 longint'(item.spec_tree_target_prob),
 longint'(item.spec_tree_rand_u),
 longint'(item.spec_tree_draft_tok),
 int'(item.spec_bonus_tok),
 exp_spec_valid,
 exp_spec_sel_tok,
 exp_spec_sel_logit,
 exp_spec_sorted_logits,
 exp_spec_sorted_tokens,
 exp_spec_nuc_mask,
 exp_spec_acc_mask,
 exp_spec_leaf_idx,
 exp_spec_draft_len,
 exp_spec_tot_emit,
 exp_spec_committed,
 exp_spec_kv_adv,
 exp_spec_prng
 );

 dpi_power_droop_step(
 int'(item.pwr_enable),
 int'(item.pwr_slice_active),
 int'(item.pwr_mxm_zero_skip_cnt),
 int'(item.pwr_prewarm_hint),
 int'(item.pwr_prewarm_target_level),
 int'(item.pwr_max_didt_step),
 int'(item.pwr_vdd_nominal_mv),
 int'(item.pwr_droop_emerg_thresh_mv),
 exp_pwr_raw,
 exp_pwr_eff,
 exp_pwr_bleed,
 exp_pwr_mask,
 exp_pwr_didt,
 exp_pwr_vdd,
 exp_pwr_temp,
 exp_pwr_emerg,
 exp_pwr_events
 );

      dpi_sram_scrubber_step(
        int'(item.sram_efuse_load_req),
        int'(item.sram_efuse_bank),
        int'(item.sram_efuse_bad_addr),
        int'(item.sram_vliw_rd_en),
        int'(item.sram_vliw_rd_bank),
        int'(item.sram_vliw_rd_addr),
        int'(item.sram_vliw_wr_en),
        int'(item.sram_vliw_wr_bank),
        int'(item.sram_vliw_wr_addr),
        item.sram_vliw_wr_data,
        int'(item.sram_dma_wr_en),
        int'(item.sram_dma_wr_bank),
        int'(item.sram_dma_wr_addr),
        item.sram_dma_wr_data,
        int'(item.sram_scrub_enable),
        int'(item.sram_ser_inject_en),
        int'(item.sram_ser_inject_bank),
        int'(item.sram_ser_inject_addr),
        longint'(item.sram_ser_inject_mask[63:0]),
        int'(item.sram_ser_inject_mask[71:64]),
        longint'(item.sram_ser_inject_mask[135:72]),
        int'(item.sram_ser_inject_mask[143:136]),
        exp_sram_rep_en,
        exp_sram_rep_addr,
        exp_sram_efuse_ack,
        exp_sram_rd_val,
        exp_sram_rd_data,
        exp_sram_rd_sec,
        exp_sram_rd_ded,
        exp_sram_rep_hit,
        exp_sram_scrub_rd,
        exp_sram_scrub_wb,
        exp_sram_scrub_bank,
        exp_sram_scrub_addr,
        exp_sram_corr_cnt,
        exp_sram_ded_alert,
        exp_sram_ded_bank,
        exp_sram_ded_addr
      );

      checked_cycles++;
      spec_checks++;
      pwr_checks++;
      sram_checks++;

      if (item.act_spec_accepted_draft_len > 3'd1) spec_tree_multi_accept++;
      if (item.act_pwr_dummy_bleed_current != 8'd0) pwr_bleed_mitigated_cnt++;
      if (item.act_pwr_emerg_throttle) pwr_emerg_throttle_events++;
      if (item.act_sram_vliw_rd_sec_err) sram_vliw_sec_events++;
      if (item.act_sram_vliw_rd_ded_err) sram_vliw_ded_events++;
      if (item.act_sram_scrub_wb_fire) sram_scrub_wb_events++;
      if (item.act_sram_vliw_rd_repaired_row_hit) sram_repaired_hit_events++;

      // 1) Check Speculative Decode Tree & Sampler
      if ((item.act_spec_valid                !== bit'(exp_spec_valid[0]))          ||
          (item.act_spec_selected_token       !== exp_spec_sel_tok[7:0])            ||
          (item.act_spec_selected_logit       !== exp_spec_sel_logit[7:0])          ||
          (item.act_spec_sorted_logits        !== exp_spec_sorted_logits)           ||
          (item.act_spec_sorted_tokens        !== exp_spec_sorted_tokens)           ||
          (item.act_spec_nucleus_mask         !== exp_spec_nuc_mask[15:0])          ||
          (item.act_spec_accepted_node_mask   !== exp_spec_acc_mask[7:0])           ||
          (item.act_spec_best_leaf_idx        !== exp_spec_leaf_idx[2:0])           ||
          (item.act_spec_accepted_draft_len   !== exp_spec_draft_len[2:0])          ||
          (item.act_spec_total_emitted_tokens !== exp_spec_tot_emit[2:0])           ||
          (item.act_spec_committed_tokens     !== exp_spec_committed[39:0])         ||
          (item.act_spec_kv_ring_advance      !== exp_spec_kv_adv[2:0])             ||
          (item.act_spec_prng_state           !== exp_spec_prng)) begin
        spec_mismatches++;
        mismatches++;
        if (spec_mismatches <= 5) begin
          `uvm_error("SPEC_MISMATCH", $sformatf(
            "tx=%0d mode=%0d tok=%0h/%0h logit=%0h/%0h nuc=%0h/%0h acc=%0h/%0h leaf=%0d/%0d len=%0d/%0d",
            item.tx_id, item.spec_op_mode, item.act_spec_selected_token, exp_spec_sel_tok[7:0],
            item.act_spec_selected_logit, exp_spec_sel_logit[7:0], item.act_spec_nucleus_mask, exp_spec_nuc_mask[15:0],
            item.act_spec_accepted_node_mask, exp_spec_acc_mask[7:0], item.act_spec_best_leaf_idx, exp_spec_leaf_idx[2:0],
            item.act_spec_accepted_draft_len, exp_spec_draft_len[2:0]))
        end
      end

      // 2) Check Power & Droop Controller
      if ((item.act_pwr_raw_demand             !== exp_pwr_raw[7:0])        ||
          (item.act_pwr_eff_current            !== exp_pwr_eff[7:0])        ||
          (item.act_pwr_dummy_bleed_current    !== exp_pwr_bleed[7:0])      ||
          (item.act_pwr_dummy_bleed_mask       !== exp_pwr_mask[7:0])       ||
          (item.act_pwr_didt_signed            !== signed'(exp_pwr_didt[8:0])) ||
          (item.act_pwr_vdd_est_mv             !== exp_pwr_vdd[11:0])       ||
          (item.act_pwr_thermal_temp_c         !== exp_pwr_temp[7:0])       ||
          (item.act_pwr_emerg_throttle         !== bit'(exp_pwr_emerg[0]))  ||
          (item.act_pwr_droop_mitigated_events !== exp_pwr_events[15:0])) begin
        pwr_mismatches++;
        mismatches++;
        if (pwr_mismatches <= 5) begin
          `uvm_error("PWR_MISMATCH", $sformatf(
            "tx=%0d raw=%0d/%0d eff=%0d/%0d bleed=%0d/%0d vdd=%0d/%0d temp=%0d/%0d emerg=%0b/%0b",
            item.tx_id, item.act_pwr_raw_demand, exp_pwr_raw[7:0], item.act_pwr_eff_current, exp_pwr_eff[7:0],
            item.act_pwr_dummy_bleed_current, exp_pwr_bleed[7:0], item.act_pwr_vdd_est_mv, exp_pwr_vdd[11:0],
            item.act_pwr_thermal_temp_c, exp_pwr_temp[7:0], item.act_pwr_emerg_throttle, exp_pwr_emerg[0]))
        end
      end

      // 3) Check SRAM Controller & Scrubber
      if ((item.act_sram_bank_repair_en           !== exp_sram_rep_en[3:0])        ||
          (item.act_sram_bank_repair_addr         !== exp_sram_rep_addr[23:0])     ||
          (item.act_sram_efuse_load_ack           !== bit'(exp_sram_efuse_ack[0])) ||
          (item.act_sram_vliw_rd_valid            !== bit'(exp_sram_rd_val[0]))    ||
          (item.act_sram_vliw_rd_data             !== exp_sram_rd_data)            ||
          (item.act_sram_vliw_rd_sec_err          !== bit'(exp_sram_rd_sec[0]))    ||
          (item.act_sram_vliw_rd_ded_err          !== bit'(exp_sram_rd_ded[0]))    ||
          (item.act_sram_vliw_rd_repaired_row_hit !== bit'(exp_sram_rep_hit[0]))   ||
          (item.act_sram_scrub_rd_fire            !== bit'(exp_sram_scrub_rd[0]))  ||
          (item.act_sram_scrub_wb_fire            !== bit'(exp_sram_scrub_wb[0]))  ||
          (item.act_sram_scrub_active_bank        !== exp_sram_scrub_bank[1:0])    ||
          (item.act_sram_scrub_active_addr        !== exp_sram_scrub_addr[5:0])    ||
          (item.act_sram_scrub_corrected_cnt      !== exp_sram_corr_cnt[15:0])     ||
          (item.act_sram_scrub_ded_alert          !== bit'(exp_sram_ded_alert[0])) ||
          (item.act_sram_first_ded_bank           !== exp_sram_ded_bank[1:0])      ||
          (item.act_sram_first_ded_addr           !== exp_sram_ded_addr[5:0])) begin
        sram_mismatches++;
        mismatches++;
        if (sram_mismatches <= 5) begin
          `uvm_error("SRAM_MISMATCH", $sformatf(
            "tx=%0d rd_v=%0b/%0b sec=%0b/%0b ded=%0b/%0b scrub_rd=%0b/%0b wb=%0b/%0b corr=%0d/%0d",
            item.tx_id, item.act_sram_vliw_rd_valid, exp_sram_rd_val[0],
            item.act_sram_vliw_rd_sec_err, exp_sram_rd_sec[0], item.act_sram_vliw_rd_ded_err, exp_sram_rd_ded[0],
            item.act_sram_scrub_rd_fire, exp_sram_scrub_rd[0], item.act_sram_scrub_wb_fire, exp_sram_scrub_wb[0],
            item.act_sram_scrub_corrected_cnt, exp_sram_corr_cnt[15:0]))
        end
      end
    endfunction
  endclass : spec_power_scrub_scoreboard

  // ---------------------------------------------------------------------------
  // 7. UVM Environment & UVM Test
  // ---------------------------------------------------------------------------
  class spec_power_scrub_env extends uvm_env;
    `uvm_component_utils(spec_power_scrub_env)

    spec_power_scrub_agent          agent;
    spec_power_scrub_cov_subscriber cov_sub;
    spec_power_scrub_scoreboard     scoreboard;

    function new(string name = "spec_power_scrub_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = spec_power_scrub_agent::type_id::create("agent", this);
      cov_sub    = spec_power_scrub_cov_subscriber::type_id::create("cov_sub", this);
      scoreboard = spec_power_scrub_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.monitor.ap.connect(cov_sub.analysis_export);
      agent.monitor.ap.connect(scoreboard.imp);
    endfunction
  endclass : spec_power_scrub_env

  class spec_power_scrub_test extends uvm_test;
    `uvm_component_utils(spec_power_scrub_test)

    spec_power_scrub_env env;

    function new(string name = "spec_power_scrub_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = spec_power_scrub_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      spec_power_scrub_sequence seq = spec_power_scrub_sequence::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.agent.sequencer);
      repeat (2) @(negedge env.agent.driver.vif.clk);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      int unsigned dpi_calls;
      real func_cov;
      bit pass_gate;
      int fd;
      super.report_phase(phase);

      dpi_calls = dpi_get_calls();
      func_cov  = env.cov_sub.spec_power_scrub_cg.get_inst_coverage();
      pass_gate = (env.agent.driver.driven >= 3500) &&
                  (env.agent.monitor.seen == env.agent.driver.driven) &&
                  (env.scoreboard.checked_cycles == env.agent.driver.driven) &&
                  (dpi_calls == env.agent.driver.driven) &&
                  (env.scoreboard.mismatches == 0) &&
                  (env.scoreboard.spec_tree_multi_accept > 0) &&
                  (env.scoreboard.pwr_bleed_mitigated_cnt > 0) &&
                  (env.scoreboard.pwr_emerg_throttle_events > 0) &&
                  (env.scoreboard.sram_vliw_sec_events > 0) &&
                  (env.scoreboard.sram_vliw_ded_events > 0) &&
                  (env.scoreboard.sram_scrub_wb_events > 0) &&
                  (env.scoreboard.sram_repaired_hit_events > 0) &&
                  (func_cov == 100.0);

      fd = $fopen("spec_power_scrub_summary.json", "w");
      if (fd == 0) `uvm_fatal("JSON_OPEN", "Cannot open spec_power_scrub_summary.json")
      $fdisplay(fd, "{");
      $fdisplay(fd, "  \"suite\": \"uvm_spec_power_scrub\",");
      $fdisplay(fd, "  \"dut\": [\"groq_spec_decode_tree_sampler\", \"groq_power_droop_controller\", \"groq_sram_controller_scrubber\"],");
      $fdisplay(fd, "  \"driven_cycles\": %0d,", env.agent.driver.driven);
      $fdisplay(fd, "  \"observed_cycles\": %0d,", env.agent.monitor.seen);
      $fdisplay(fd, "  \"checked_cycles\": %0d,", env.scoreboard.checked_cycles);
      $fdisplay(fd, "  \"dpi_calls\": %0d,", dpi_calls);
      $fdisplay(fd, "  \"spec_sampler_checks\": %0d,", env.scoreboard.spec_checks);
      $fdisplay(fd, "  \"power_droop_checks\": %0d,", env.scoreboard.pwr_checks);
      $fdisplay(fd, "  \"sram_scrubber_checks\": %0d,", env.scoreboard.sram_checks);
      $fdisplay(fd, "  \"spec_tree_multi_accept_events\": %0d,", env.scoreboard.spec_tree_multi_accept);
      $fdisplay(fd, "  \"pwr_bleed_mitigated_events\": %0d,", env.scoreboard.pwr_bleed_mitigated_cnt);
      $fdisplay(fd, "  \"pwr_emerg_throttle_events\": %0d,", env.scoreboard.pwr_emerg_throttle_events);
      $fdisplay(fd, "  \"sram_vliw_sec_events\": %0d,", env.scoreboard.sram_vliw_sec_events);
      $fdisplay(fd, "  \"sram_vliw_ded_events\": %0d,", env.scoreboard.sram_vliw_ded_events);
      $fdisplay(fd, "  \"sram_scrub_wb_events\": %0d,", env.scoreboard.sram_scrub_wb_events);
      $fdisplay(fd, "  \"sram_repaired_hit_events\": %0d,", env.scoreboard.sram_repaired_hit_events);
      $fdisplay(fd, "  \"spec_mismatches\": %0d,", env.scoreboard.spec_mismatches);
      $fdisplay(fd, "  \"pwr_mismatches\": %0d,", env.scoreboard.pwr_mismatches);
      $fdisplay(fd, "  \"sram_mismatches\": %0d,", env.scoreboard.sram_mismatches);
      $fdisplay(fd, "  \"mismatches\": %0d,", env.scoreboard.mismatches);
      $fdisplay(fd, "  \"functional_coverage_pct\": %0.2f,", func_cov);
      $fdisplay(fd, "  \"pass\": %0d", pass_gate);
      $fdisplay(fd, "}");
      $fclose(fd);

      dpi_set_status(pass_gate ? 0 : 1);
      if (!pass_gate) begin
        `uvm_fatal("UVM_SPEC_POWER_SCRUB_FAIL", $sformatf(
          "Gate failed: driven=%0d checked=%0d mismatches=%0d (spec=%0d pwr=%0d sram=%0d) cov=%0.2f%%",
          env.agent.driver.driven, env.scoreboard.checked_cycles,
          env.scoreboard.mismatches, env.scoreboard.spec_mismatches,
          env.scoreboard.pwr_mismatches, env.scoreboard.sram_mismatches, func_cov))
      end else begin
        `uvm_info("UVM_SPEC_POWER_SCRUB_PASS", $sformatf(
          "PASS: %0d transactions checked via C++17 DPI-C reference, 0 mismatches, 100.00%% functional coverage",
          env.scoreboard.checked_cycles), UVM_LOW)
      end
    endfunction
  endclass : spec_power_scrub_test

endpackage : uvm_spec_power_scrub_pkg

`endif // UVM_SPEC_POWER_SCRUB_PKG_SV
