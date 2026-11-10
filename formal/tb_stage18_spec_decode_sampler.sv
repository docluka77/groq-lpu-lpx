// =============================================================================
// File: formal/tb_stage18_spec_decode_sampler.sv
// Description: Stage 18 Self-Checking Testbench for Speculative Decoding
//              Draft-Verify Tree Engine & Top-K/Top-P Nucleus Token Sampler IP.
// =============================================================================

module tb_stage18_spec_decode_sampler;

  logic         clk;
  logic         rst_n;
  logic         valid_i;
  logic [1:0]   op_mode_i;
  logic [127:0] logits_i;
  logic [127:0] token_ids_i;
  logic [3:0]   top_k_i;
  logic [7:0]   inv_temp_i;
  logic [15:0]  top_p_thresh_i;
  logic         rng_seed_step_i;
  logic [7:0]   rng_threshold_i;
  logic [23:0]  tree_parent_idx_i;
  logic [63:0]  tree_draft_prob_i;
  logic [63:0]  tree_target_prob_i;
  logic [63:0]  tree_rand_u_i;
  logic [63:0]  tree_draft_tok_i;
  logic [7:0]   bonus_tok_i;

  logic         valid_o;
  logic [7:0]   selected_token_o;
  logic [7:0]   selected_logit_o;
  logic [127:0] sorted_logits_o;
  logic [127:0] sorted_tokens_o;
  logic [15:0]  nucleus_mask_o;
  logic [7:0]   accepted_node_mask_o;
  logic [2:0]   best_leaf_idx_o;
  logic [2:0]   accepted_draft_len_o;
  logic [2:0]   total_emitted_tokens_o;
  logic [39:0]  committed_tokens_o;
  logic [2:0]   kv_ring_advance_o;
  logic [31:0]  prng_state_o;

  groq_spec_decode_tree_sampler dut (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .valid_i                (valid_i),
    .op_mode_i              (op_mode_i),
    .logits_i               (logits_i),
    .token_ids_i            (token_ids_i),
    .top_k_i                (top_k_i),
    .inv_temp_i             (inv_temp_i),
    .top_p_thresh_i         (top_p_thresh_i),
    .rng_seed_step_i        (rng_seed_step_i),
    .rng_threshold_i        (rng_threshold_i),
    .tree_parent_idx_i      (tree_parent_idx_i),
    .tree_draft_prob_i      (tree_draft_prob_i),
    .tree_target_prob_i     (tree_target_prob_i),
    .tree_rand_u_i          (tree_rand_u_i),
    .tree_draft_tok_i       (tree_draft_tok_i),
    .bonus_tok_i            (bonus_tok_i),
    .valid_o                (valid_o),
    .selected_token_o       (selected_token_o),
    .selected_logit_o       (selected_logit_o),
    .sorted_logits_o        (sorted_logits_o),
    .sorted_tokens_o        (sorted_tokens_o),
    .nucleus_mask_o         (nucleus_mask_o),
    .accepted_node_mask_o   (accepted_node_mask_o),
    .best_leaf_idx_o        (best_leaf_idx_o),
    .accepted_draft_len_o   (accepted_draft_len_o),
    .total_emitted_tokens_o (total_emitted_tokens_o),
    .committed_tokens_o     (committed_tokens_o),
    .kv_ring_advance_o      (kv_ring_advance_o),
    .prng_state_o           (prng_state_o)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic check_cond(input bit cond, input string msg);
    if (cond) begin
      pass_cnt++;
      $display("[PASS] %s", msg);
    end else begin
      fail_cnt++;
      $display("[FAIL] %s", msg);
    end
  endtask

  task automatic check_sorted_monotonic(input string tag);
    bit mono_ok = 1'b1;
    for (int k = 0; k < 15; k++) begin
      if ($signed(sorted_logits_o[8*k +: 8]) < $signed(sorted_logits_o[8*(k+1) +: 8])) begin
        mono_ok = 1'b0;
      end
    end
    check_cond(mono_ok, {tag, ": 16-lane Bitonic sort non-increasing monotonicity"});
  endtask

  initial begin
    rst_n              = 1'b0;
    valid_i            = 1'b0;
    op_mode_i          = 2'd0;
    logits_i           = 128'd0;
    token_ids_i        = 128'd0;
    top_k_i            = 4'd0;
    inv_temp_i         = 8'd1;
    top_p_thresh_i     = 16'hFFFF;
    rng_seed_step_i    = 1'b0;
    rng_threshold_i    = 8'd0;
    tree_parent_idx_i  = 24'd0;
    tree_draft_prob_i  = 64'd0;
    tree_target_prob_i = 64'd0;
    tree_rand_u_i      = 64'd0;
    tree_draft_tok_i   = 64'd0;
    bonus_tok_i        = 8'd0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // -------------------------------------------------------------------------
    // Test 1: SAMPLER_GREEDY_ARGMAX (signed logits [-128..+127])
    // -------------------------------------------------------------------------
    for (int i = 0; i < 16; i++) begin
      token_ids_i[8*i +: 8] = 8'(8'hA0 + i);
    end
    logits_i[8*0  +: 8] = -8'sd40;
    logits_i[8*1  +: 8] =  8'sd15;
    logits_i[8*2  +: 8] = -8'sd128;
    logits_i[8*3  +: 8] =  8'sd88;
    logits_i[8*4  +: 8] =  8'sd102;
    logits_i[8*5  +: 8] = -8'sd5;
    logits_i[8*6  +: 8] =  8'sd64;
    logits_i[8*7  +: 8] =  8'sd121; // Max logit at lane 7 (token 0xA7)
    logits_i[8*8  +: 8] =  8'sd95;
    logits_i[8*9  +: 8] =  8'sd110;
    logits_i[8*10 +: 8] = -8'sd90;
    logits_i[8*11 +: 8] =  8'sd33;
    logits_i[8*12 +: 8] =  8'sd77;
    logits_i[8*13 +: 8] =  8'sd108;
    logits_i[8*14 +: 8] =  8'sd12;
    logits_i[8*15 +: 8] =  8'sd50;

    valid_i   = 1'b1;
    op_mode_i = 2'd0; // SAMPLER_GREEDY_ARGMAX
    @(posedge clk);
    #1;
    check_cond(valid_o == 1'b1, "Greedy Argmax: valid_o asserted");
    check_sorted_monotonic("Greedy Argmax");
    check_cond(($signed(selected_logit_o) == 8'sd121) && (selected_token_o == 8'hA7),
               "Greedy Argmax: exact max logit (121) and token ID (0xA7) selected");
    check_cond($signed(sorted_logits_o[127:120]) == -8'sd128,
               "Greedy Argmax: rank-15 minimum logit is -128");

    // -------------------------------------------------------------------------
    // Test 2: SAMPLER_TOPK_TOPP (K=1, K=4, K=8, Top-P nucleus & temperature)
    // -------------------------------------------------------------------------
    op_mode_i       = 2'd1; // SAMPLER_TOPK_TOPP
    top_k_i         = 4'd1;
    inv_temp_i      = 8'd4;
    top_p_thresh_i  = 16'd500;
    rng_seed_step_i = 1'b0;
    rng_threshold_i = 8'd200;
    @(posedge clk);
    #1;
    check_cond((nucleus_mask_o == 16'h0001) && (selected_token_o == 8'hA7),
               "Top-K (K=1): only rank-0 kept in nucleus_mask_o, selects 0xA7");

    // K=4, inv_temp=4: top 4 logits are 121 (w=256), 110 (w=212), 108 (w=204), 102 (w=180)
    // Cumulative weights: C0=256, C1=468, C2=672, C3=852
    // With top_p_thresh_i=500: prev_cum for r=0(0), r=1(256), r=2(468) are < 500; r=3(672) >= 500!
    // So active nucleus ranks are 0, 1, 2 (nucleus_mask_o == 16'h0007), total mass = 672
    top_k_i         = 4'd4;
    inv_temp_i      = 8'd4;
    top_p_thresh_i  = 16'd500;
    rng_threshold_i = 8'd220; // target_mass = (672 * 220) >> 8 = 577 -> falls in rank 2 (token 0xAD, logit 108)
    @(posedge clk);
    #1;
    check_cond(nucleus_mask_o == 16'h0007,
               "Top-K=4 & Top-P=500: nucleus_mask_o == 16'h0007 (ranks 0..2 active)");
    check_cond((selected_token_o == 8'hAD) && ($signed(selected_logit_o) == 8'sd108),
               "Top-K=4 & Top-P=500: deterministic inverse-CDF selects rank-2 token 0xAD (logit 108)");

    // K=8 with high Top-P threshold and PRNG seed step enabled
    top_k_i         = 4'd8;
    inv_temp_i      = 8'd1;
    top_p_thresh_i  = 16'hFFFF;
    rng_seed_step_i = 1'b1;
    rng_threshold_i = 8'd64;
    @(posedge clk);
    #1;
    check_cond((nucleus_mask_o == 16'h00FF) && (prng_state_o != 32'h9E37_79B9),
               "Top-K=8 & PRNG step: nucleus_mask_o == 16'h00FF and Xoroshiro PRNG advanced");

    // -------------------------------------------------------------------------
    // Test 3: SAMPLER_SPEC_VERIFY_TREE (8-Node Medusa / EAGLE-2 Draft Tree)
    // Tree topology:
    //   Node 0: Root (depth 1), tok=0x10
    //   Node 1: Parent 0 (depth 2), tok=0x11
    //   Node 2: Parent 0 (depth 2), tok=0x12
    //   Node 3: Parent 1 (depth 3), tok=0x13
    //   Node 4: Parent 1 (depth 3), tok=0x14
    //   Node 5: Parent 2 (depth 3), tok=0x15
    //   Node 6: Parent 3 (depth 4), tok=0x16
    //   Node 7: Parent 5 (depth 4), tok=0x17
    // -------------------------------------------------------------------------
    op_mode_i         = 2'd2; // SAMPLER_SPEC_VERIFY_TREE
    tree_parent_idx_i = {3'd5, 3'd3, 3'd2, 3'd1, 3'd1, 3'd0, 3'd0, 3'd0};
    tree_draft_tok_i  = {8'h17, 8'h16, 8'h15, 8'h14, 8'h13, 8'h12, 8'h11, 8'h10};
    bonus_tok_i       = 8'h99;

    // 3a. Full tree accept along 0 -> 1 -> 3 -> 6 (depth 4, 5 tokens emitted)
    tree_draft_prob_i  = {8'd100, 8'd100, 8'd100, 8'd100, 8'd100, 8'd100, 8'd100, 8'd200};
    tree_target_prob_i = {8'd120, 8'd180, 8'd130, 8'd140, 8'd150, 8'd160, 8'd170, 8'd200};
    tree_rand_u_i      = {8'd50,  8'd50,  8'd50,  8'd50,  8'd50,  8'd50,  8'd50,  8'd0};
    @(posedge clk);
    #1;
    check_cond(accepted_node_mask_o == 8'hFF,
               "SpecTree Full Accept: all 8 draft nodes accepted (mask=0xFF)");
    check_cond((best_leaf_idx_o == 3'd6) && (accepted_draft_len_o == 3'd4) &&
               (total_emitted_tokens_o == 3'd5) && (kv_ring_advance_o == 3'd4),
               "SpecTree Full Accept: deepest leaf d*=6 (p_6=180 > p_7=120), depth=4, emitted=5, kv_adv=4");
    check_cond(committed_tokens_o == {8'h99, 8'h16, 8'h13, 8'h11, 8'h10},
               "SpecTree Full Accept: committed_tokens_o == {0x99(bonus), 0x16, 0x13, 0x11, 0x10}");

    // 3b. Partial branch accept: reject Node 1 (p_1=10 < q_1=200, u_1=200) and Node 7 (p_7=5 < q_7=200, u_7=200)
    //     Even though Nodes 3, 4, 6 have high local p_d=200, their ancestor Node 1 is rejected!
    //     Winning path must be 0 -> 2 -> 5 (depth 3, leaf d*=5, emitted=4)
    tree_draft_prob_i  = {8'd200, 8'd100, 8'd100, 8'd100, 8'd100, 8'd100, 8'd200, 8'd200};
    tree_target_prob_i = {8'd5,   8'd200, 8'd160, 8'd200, 8'd200, 8'd150, 8'd10,  8'd200};
    tree_rand_u_i      = {8'd200, 8'd50,  8'd50,  8'd50,  8'd50,  8'd50,  8'd200, 8'd0};
    @(posedge clk);
    #1;
    check_cond(accepted_node_mask_o == 8'b0010_0101,
               "SpecTree Partial Branch: nodes {0, 2, 5} accepted; children {3,4,6} of rejected node 1 masked out");
    check_cond((best_leaf_idx_o == 3'd5) && (accepted_draft_len_o == 3'd3) &&
               (total_emitted_tokens_o == 3'd4) && (kv_ring_advance_o == 3'd3),
               "SpecTree Partial Branch: best_leaf=5, depth=3, emitted=4, kv_adv=3");
    check_cond(committed_tokens_o == {8'h00, 8'h99, 8'h15, 8'h12, 8'h10},
               "SpecTree Partial Branch: committed_tokens_o == {0x00, 0x99(bonus), 0x15, 0x12, 0x10}");

    // 3c. Root-only fallback: reject both level-2 children (Node 1 and Node 2)
    tree_draft_prob_i  = {8'd200, 8'd200, 8'd200, 8'd200, 8'd200, 8'd200, 8'd200, 8'd200};
    tree_target_prob_i = {8'd200, 8'd200, 8'd200, 8'd200, 8'd200, 8'd2,   8'd2,   8'd200};
    tree_rand_u_i      = {8'd250, 8'd250, 8'd250, 8'd250, 8'd250, 8'd250, 8'd250, 8'd0};
    @(posedge clk);
    #1;
    check_cond((accepted_node_mask_o == 8'h01) && (best_leaf_idx_o == 3'd0) &&
               (accepted_draft_len_o == 3'd1) && (total_emitted_tokens_o == 3'd2),
               "SpecTree Root Fallback: only root node 0 accepted, depth=1, emitted=2");
    check_cond(committed_tokens_o == {8'h00, 8'h00, 8'h00, 8'h99, 8'h10},
               "SpecTree Root Fallback: committed_tokens_o == {0x00, 0x00, 0x00, 0x99(bonus), 0x10}");

    // 3d. Equal-depth tie-breaking (Nodes 6 and 7 both valid at depth 4 with identical p_6 == p_7 == 175 -> lowest index d*=6 wins)
    tree_draft_prob_i  = {8'd100, 8'd100, 8'd100, 8'd100, 8'd100, 8'd100, 8'd100, 8'd200};
    tree_target_prob_i = {8'd175, 8'd175, 8'd150, 8'd150, 8'd150, 8'd150, 8'd150, 8'd200};
    tree_rand_u_i      = {8'd20,  8'd20,  8'd20,  8'd20,  8'd20,  8'd20,  8'd20,  8'd0};
    @(posedge clk);
    #1;
    check_cond((best_leaf_idx_o == 3'd6) && (accepted_draft_len_o == 3'd4),
               "SpecTree Tie-Break: equal depth=4 and equal p=175 selects lowest node index d*=6");

    $display("==================================================================");
    $display("STAGE 18 SPECULATIVE DECODE & NUCLEUS SAMPLER SIM: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
    $display("==================================================================");
    if (fail_cnt != 0) $fatal(1, "Stage 18 testbench failed!");
    $finish;
  end

endmodule
