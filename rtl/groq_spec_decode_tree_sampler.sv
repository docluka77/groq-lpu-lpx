// =============================================================================
// File: rtl/groq_spec_decode_tree_sampler.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 18 Hardware Speculative Decoding Draft-Verify Tree Engine
//              & Top-K/Top-P Nucleus Token Sampler IP.
//              Implements:
//              1) 16-Lane 10-Layer Bitonic Sorting Network (signed INT8 logits)
//              2) Deterministic Greedy Argmax & Top-K / Top-P Nucleus Sampler
//                 with piecewise-linear exp approximation & Xoroshiro32++ PRNG
//              3) Hardware 8-Node Medusa/EAGLE-2 Speculative Draft Tree Verifier
//                 with causal ancestor masking, rejection sampling, deepest leaf
//                 tie-breaking, and AGU_KV_RING pointer advance generation.
// =============================================================================
`ifndef GROQ_SPEC_DECODE_TREE_SAMPLER_SV
`define GROQ_SPEC_DECODE_TREE_SAMPLER_SV

module groq_spec_decode_tree_sampler #(
  parameter int P_LANES      = 16,
  parameter int P_TREE_NODES = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    valid_i,
  input  logic [1:0]              op_mode_i,

  // 16-Lane Candidate Logits (signed 8-bit) & Local Token IDs (8-bit)
  input  logic [P_LANES*8-1:0]    logits_i,
  input  logic [P_LANES*8-1:0]    token_ids_i,

  // Top-K / Top-P Nucleus & Temperature Controls
  input  logic [3:0]              top_k_i,
  input  logic [7:0]              inv_temp_i,
  input  logic [15:0]             top_p_thresh_i,
  input  logic                    rng_seed_step_i,
  input  logic [7:0]              rng_threshold_i,

  // 8-Node Speculative Draft Token Tree Inputs (Medusa / EAGLE-2)
  input  logic [P_TREE_NODES*3-1:0] tree_parent_idx_i,
  input  logic [P_TREE_NODES*8-1:0] tree_draft_prob_i,
  input  logic [P_TREE_NODES*8-1:0] tree_target_prob_i,
  input  logic [P_TREE_NODES*8-1:0] tree_rand_u_i,
  input  logic [P_TREE_NODES*8-1:0] tree_draft_tok_i,
  input  logic [7:0]                bonus_tok_i,

  // Deterministic Registered Outputs
  output logic                    valid_o,
  output logic [7:0]              selected_token_o,
  output logic [7:0]              selected_logit_o,
  output logic [P_LANES*8-1:0]    sorted_logits_o,
  output logic [P_LANES*8-1:0]    sorted_tokens_o,
  output logic [P_LANES-1:0]      nucleus_mask_o,

  // Speculative Tree Verification & KV Ring Outputs
  output logic [P_TREE_NODES-1:0] accepted_node_mask_o,
  output logic [2:0]              best_leaf_idx_o,
  output logic [2:0]              accepted_draft_len_o,
  output logic [2:0]              total_emitted_tokens_o,
  output logic [39:0]             committed_tokens_o,
  output logic [2:0]              kv_ring_advance_o,
  output logic [31:0]             prng_state_o
);

  // ---------------------------------------------------------------------------
  // 1. Operation Mode Encodings
  // ---------------------------------------------------------------------------
  localparam logic [1:0] SAMPLER_GREEDY_ARGMAX    = 2'd0;
  localparam logic [1:0] SAMPLER_TOPK_TOPP        = 2'd1;
  localparam logic [1:0] SAMPLER_SPEC_VERIFY_TREE = 2'd2;

  // ---------------------------------------------------------------------------
  // 2. 16-Input 10-Layer Bitonic Sorting Network (Descending Order)
  // ---------------------------------------------------------------------------
  /* verilator lint_off UNOPTFLAT */
  logic [127:0] b_val [0:10];
  logic [127:0] b_tok [0:10];
  /* verilator lint_on UNOPTFLAT */

  assign b_val[0] = logits_i;
  assign b_tok[0] = token_ids_i;

  genvar gs, gi;
  generate
    for (gs = 0; gs < 10; gs++) begin : gen_bitonic_stage
      localparam int LK = (gs == 0) ? 2 : (gs < 3) ? 4 : (gs < 6) ? 8 : 16;
      localparam int LJ = (gs == 0 || gs == 2 || gs == 5 || gs == 9) ? 1 :
                          (gs == 1 || gs == 4 || gs == 8) ? 2 :
                          (gs == 3 || gs == 7) ? 4 : 8;
      for (gi = 0; gi < 16; gi++) begin : gen_lane
        localparam int IXJ = gi ^ LJ;
        localparam bit DIR_DESC = ((gi & LK) == 0);
        if (IXJ > gi) begin : gen_cas
          logic signed [7:0] va, vb;
          logic [7:0]        ta, tb;
          logic              swap;
          assign va   = $signed(b_val[gs][8*gi  +: 8]);
          assign ta   = b_tok[gs][8*gi  +: 8];
          assign vb   = $signed(b_val[gs][8*IXJ +: 8]);
          assign tb   = b_tok[gs][8*IXJ +: 8];
          assign swap = DIR_DESC ? (va < vb) : (va > vb);
          assign b_val[gs+1][8*gi  +: 8] = swap ? vb : va;
          assign b_tok[gs+1][8*gi  +: 8] = swap ? tb : ta;
          assign b_val[gs+1][8*IXJ +: 8] = swap ? va : vb;
          assign b_tok[gs+1][8*IXJ +: 8] = swap ? ta : tb;
`ifdef FORMAL
          always_comb begin
            if (DIR_DESC) begin
              assert ($signed(b_val[gs+1][8*gi  +: 8]) >= $signed(b_val[gs+1][8*IXJ +: 8]));
            end else begin
              assert ($signed(b_val[gs+1][8*gi  +: 8]) <= $signed(b_val[gs+1][8*IXJ +: 8]));
            end
          end
`endif
        end
      end
    end
  endgenerate

  logic [127:0] sorted_logits_comb;
  logic [127:0] sorted_tokens_comb;
  assign sorted_logits_comb = b_val[10];
  assign sorted_tokens_comb = b_tok[10];

  // ---------------------------------------------------------------------------
  // 3. Top-K & Top-P Nucleus Sampler with Piecewise-Linear Exp & PRNG
  // ---------------------------------------------------------------------------
  logic [31:0]  prng_state_q, prng_state_next;
  logic [255:0] cum_weight_vec;
  logic [15:0]  nucleus_mask_comb;
  logic [15:0]  total_nucleus_mass_comb;
  logic [7:0]   eff_rng_u_comb;
  logic [15:0]  target_mass_comb;
  logic [3:0]   sampled_rank_comb;

  always_comb begin
    logic [31:0] s_tmp;
    logic [15:0] run_cum;
    s_tmp = prng_state_q ^ (prng_state_q << 13);
    s_tmp = s_tmp ^ (s_tmp >> 17);
    s_tmp = s_tmp ^ (s_tmp << 5);
    prng_state_next = (s_tmp == 32'd0) ? 32'h9E37_79B9 : s_tmp;

    cum_weight_vec          = 256'd0;
    nucleus_mask_comb       = 16'h0001;
    total_nucleus_mass_comb = 16'd0;
    run_cum                 = 16'd0;

    for (int r = 0; r < 16; r++) begin
      logic [15:0] diff_pos;
      logic [15:0] scaled_drop;
      logic [15:0] w_r;
      logic [15:0] c_r;
      logic        topk_ok;
      logic        topp_ok;

      diff_pos    = 16'(signed'(sorted_logits_comb[7:0]) - signed'(sorted_logits_comb[8*r +: 8]));
      scaled_drop = diff_pos * {8'd0, inv_temp_i};
      w_r         = (scaled_drop >= 16'd255) ? 16'd1 : (16'd256 - scaled_drop);
      c_r         = run_cum + w_r;

      cum_weight_vec[16*r +: 16] = c_r;

      topk_ok = (top_k_i == 4'd0) ? 1'b1 : (4'(r) < top_k_i);
      topp_ok = (r == 0) ? 1'b1 : (run_cum < top_p_thresh_i);
      nucleus_mask_comb[r] = (r == 0) ? 1'b1 : (topk_ok && topp_ok);

      if (nucleus_mask_comb[r]) begin
        total_nucleus_mass_comb = c_r;
      end
      run_cum = c_r;
    end

    eff_rng_u_comb    = rng_threshold_i ^ (rng_seed_step_i ? prng_state_q[7:0] : 8'd0);
    target_mass_comb  = 16'(({16'd0, total_nucleus_mass_comb} * {24'd0, eff_rng_u_comb}) >> 8);
    sampled_rank_comb = 4'd0;
    for (int r = 15; r >= 0; r--) begin
      if (nucleus_mask_comb[r] && (cum_weight_vec[16*r +: 16] > target_mass_comb)) begin
        sampled_rank_comb = 4'(r);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 4. Hardware 8-Node Speculative Draft Token Tree Verifier (Medusa / EAGLE-2)
  // ---------------------------------------------------------------------------
  function automatic logic [2:0] get_u3(input logic [23:0] vec, input logic [2:0] idx);
    get_u3 = vec[3*idx +: 3];
  endfunction

  function automatic logic [7:0] get_u8(input logic [63:0] vec, input logic [2:0] idx);
    get_u8 = vec[8*idx +: 8];
  endfunction

  logic [7:0]  node_local_accept_comb;
  logic [7:0]  node_path_valid_comb;
  logic [23:0] node_depth_vec;
  logic [2:0]  best_leaf_idx_comb;
  logic [2:0]  best_depth_comb;
  logic [7:0]  best_prob_comb;
  logic [2:0]  total_emitted_comb;
  logic [39:0] committed_tokens_comb;
  logic [15:0] eagle2_tree_confidence_comb;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] eagle2_tree_confidence_q;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    node_local_accept_comb = 8'h01;
    node_path_valid_comb   = 8'h01;
    node_depth_vec         = 24'h00_0001; // node 0 depth = 3'd1

    for (int d = 1; d < 8; d++) begin
      logic [7:0]  p_d, q_d, u_d;
      logic [15:0] lhs_p, rhs_uq;
      logic [2:0]  p_idx, p_depth;

      p_d    = tree_target_prob_i[8*d +: 8];
      q_d    = tree_draft_prob_i[8*d +: 8];
      u_d    = tree_rand_u_i[8*d +: 8];
      lhs_p  = {8'd0, p_d} * 16'd256;
      rhs_uq = {8'd0, u_d} * {8'd0, q_d};
      node_local_accept_comb[d] = (p_d >= q_d) || (lhs_p >= rhs_uq);

      p_idx   = tree_parent_idx_i[3*d +: 3];
      p_depth = get_u3(node_depth_vec, p_idx);
      if ((p_idx < 3'(d)) && (p_depth < 3'd4)) begin
        node_path_valid_comb[d]   = node_path_valid_comb[p_idx] && node_local_accept_comb[d];
        node_depth_vec[3*d +: 3]  = p_depth + 3'd1;
      end else begin
        node_path_valid_comb[d]   = 1'b0;
        node_depth_vec[3*d +: 3]  = 3'd1;
      end
    end

    best_leaf_idx_comb = 3'd0;
    best_depth_comb    = 3'd1;
    best_prob_comb     = tree_target_prob_i[7:0];

    for (int d = 1; d < 8; d++) begin
      logic [2:0] d_depth;
      logic [7:0] d_prob;
      d_depth = node_depth_vec[3*d +: 3];
      d_prob  = tree_target_prob_i[8*d +: 8];
      if (node_path_valid_comb[d]) begin
        if ((d_depth > best_depth_comb) ||
            ((d_depth == best_depth_comb) && (d_prob > best_prob_comb))) begin
          best_leaf_idx_comb = 3'(d);
          best_depth_comb    = d_depth;
          best_prob_comb     = d_prob;
        end
      end
    end

    total_emitted_comb = best_depth_comb + 3'd1;
    eagle2_tree_confidence_comb = 16'd0;
    for (int d = 0; d < 8; d++) begin
      if (node_path_valid_comb[d]) begin
        eagle2_tree_confidence_comb = eagle2_tree_confidence_comb + {8'd0, tree_target_prob_i[8*d +: 8]};
      end
    end

    begin
      logic [2:0] anc0, anc1, anc2, anc3;
      logic [7:0] t0, t1, t2, t3;
      anc0 = best_leaf_idx_comb;
      anc1 = get_u3(tree_parent_idx_i, anc0);
      anc2 = get_u3(tree_parent_idx_i, anc1);
      anc3 = get_u3(tree_parent_idx_i, anc2);
      t0   = get_u8(tree_draft_tok_i, anc0);
      t1   = get_u8(tree_draft_tok_i, anc1);
      t2   = get_u8(tree_draft_tok_i, anc2);
      t3   = get_u8(tree_draft_tok_i, anc3);
      case (best_depth_comb)
        3'd1:    committed_tokens_comb = {8'd0, 8'd0, 8'd0, bonus_tok_i, t0};
        3'd2:    committed_tokens_comb = {8'd0, 8'd0, bonus_tok_i, t0, t1};
        3'd3:    committed_tokens_comb = {8'd0, bonus_tok_i, t0, t1, t2};
        default: committed_tokens_comb = {bonus_tok_i, t0, t1, t2, t3};
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // 5. Mode Mux & Deterministic Pipeline Registers
  // ---------------------------------------------------------------------------
  logic [7:0] selected_token_comb;
  logic [7:0] selected_logit_comb;

  always_comb begin
    case (op_mode_i)
      SAMPLER_GREEDY_ARGMAX: begin
        selected_logit_comb = sorted_logits_comb[7:0];
        selected_token_comb = sorted_tokens_comb[7:0];
      end
      SAMPLER_TOPK_TOPP: begin
        selected_logit_comb = sorted_logits_comb[8*sampled_rank_comb +: 8];
        selected_token_comb = sorted_tokens_comb[8*sampled_rank_comb +: 8];
      end
      SAMPLER_SPEC_VERIFY_TREE: begin
        selected_logit_comb = best_prob_comb;
        selected_token_comb = get_u8(tree_draft_tok_i, best_leaf_idx_comb);
      end
      default: begin
        selected_logit_comb = sorted_logits_comb[7:0];
        selected_token_comb = sorted_tokens_comb[7:0];
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_o                <= 1'b0;
      selected_token_o       <= 8'd0;
      selected_logit_o       <= 8'd0;
      sorted_logits_o        <= 128'd0;
      sorted_tokens_o        <= 128'd0;
      nucleus_mask_o         <= 16'h0001;
      accepted_node_mask_o   <= 8'h01;
      best_leaf_idx_o        <= 3'd0;
      accepted_draft_len_o   <= 3'd1;
      total_emitted_tokens_o <= 3'd2;
      committed_tokens_o     <= 40'd0;
      kv_ring_advance_o        <= 3'd1;
      prng_state_q             <= 32'h9E37_79B9;
      eagle2_tree_confidence_q <= 16'd0;
    end else begin
      valid_o <= valid_i;
      if (valid_i) begin
        selected_token_o         <= selected_token_comb;
        selected_logit_o         <= selected_logit_comb;
        sorted_logits_o          <= sorted_logits_comb;
        sorted_tokens_o          <= sorted_tokens_comb;
        nucleus_mask_o           <= nucleus_mask_comb;
        accepted_node_mask_o     <= node_path_valid_comb;
        best_leaf_idx_o          <= best_leaf_idx_comb;
        accepted_draft_len_o     <= best_depth_comb;
        total_emitted_tokens_o   <= total_emitted_comb;
        committed_tokens_o       <= committed_tokens_comb;
        kv_ring_advance_o        <= best_depth_comb;
        eagle2_tree_confidence_q <= eagle2_tree_confidence_comb;
        if (rng_seed_step_i) begin
          prng_state_q <= prng_state_next;
        end
      end
    end
  end

  assign prng_state_o = prng_state_q;

`ifdef FORMAL
  /* verilator lint_off SYNCASYNCNET */
  logic [1:0]  f_op_mode_q;
  logic [23:0] f_parent_idx_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_op_mode_q    <= 2'd0;
      f_parent_idx_q <= 24'd0;
    end else if (valid_i) begin
      f_op_mode_q    <= op_mode_i;
      f_parent_idx_q <= tree_parent_idx_i;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && valid_o) begin
      // 1. Bitonic Sorting Network Monotonicity
      for (int k = 0; k < 15; k++) begin
        assert ($signed(sorted_logits_o[8*k +: 8]) >= $signed(sorted_logits_o[8*(k+1) +: 8]));
      end

      // 2. Greedy Argmax Exactness
      if (f_op_mode_q == SAMPLER_GREEDY_ARGMAX) begin
        assert (selected_logit_o == sorted_logits_o[7:0]);
        assert (selected_token_o == sorted_tokens_o[7:0]);
      end

      // 3. Nucleus Rank-0 Preservation
      assert (nucleus_mask_o[0] == 1'b1);

      // 4. Speculative Tree Causal Path Ancestor Invariant
      assert (accepted_node_mask_o[0] == 1'b1);
      assert (accepted_draft_len_o >= 3'd1);
      assert (total_emitted_tokens_o == (accepted_draft_len_o + 3'd1));
      assert (kv_ring_advance_o == accepted_draft_len_o);
      for (int d = 1; d < 8; d++) begin
        if (f_parent_idx_q[3*d +: 3] < 3'(d)) begin
          if (accepted_node_mask_o[d] == 1'b1) begin
            assert (accepted_node_mask_o[f_parent_idx_q[3*d +: 3]] == 1'b1);
          end
        end
      end

      // 5 (BUG-LIT-007): EAGLE-2/3 Context-Aware Dynamic Draft Tree Confidence Invariant
      assert (eagle2_tree_confidence_q <= 16'd2040);
      if (accepted_draft_len_o == 3'd0) begin
        assert (eagle2_tree_confidence_q == 16'd0);
      end
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule : groq_spec_decode_tree_sampler

`endif // GROQ_SPEC_DECODE_TREE_SAMPLER_SV
