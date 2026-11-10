// =============================================================================
// File: uvm_tb/uvm_spec_power_scrub/dpi_spec_power_scrub_ref.cpp
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Cycle-Accurate Bit-Exact C++17 DPI-C Golden Reference Model for
//              groq_spec_decode_tree_sampler, groq_power_droop_controller, and
//              groq_sram_controller_scrubber under Accellera IEEE 1800.2-2020 UVM.
// =============================================================================
#include <cstdint>
#include <cstring>
#include "svdpi.h"

namespace {

struct SpecSamplerState {
 uint8_t valid_q;
 uint8_t selected_token_q;
 uint8_t selected_logit_q;
 uint8_t sorted_logits_q[16];
 uint8_t sorted_tokens_q[16];
 uint16_t nucleus_mask_q;
 uint8_t accepted_node_mask_q;
 uint8_t best_leaf_idx_q;
 uint8_t accepted_draft_len_q;
 uint8_t total_emitted_tokens_q;
 uint64_t committed_tokens_q;
 uint8_t kv_ring_advance_q;
 uint32_t prng_state_q;
};

struct PowerDroopState {
 uint8_t eff_current_q;
 uint8_t thermal_temp_c_q;
 uint8_t therm_tick_q;
 uint16_t droop_mitigated_events_q;
};

struct Codeword72 {
 uint64_t data;
 uint8_t ecc;
};

struct Word144 {
 Codeword72 lo;
 Codeword72 hi;
};

struct SramScrubberState {
 Word144 mem_q[4][64];
 uint8_t bank_repair_en_q;
 uint8_t bank_repair_addr_q[4];
 uint8_t efuse_load_ack_q;
 uint8_t vliw_rd_valid_q;
 Word144 vliw_rd_raw_cw_q;
 uint8_t vliw_rd_repaired_row_hit_q;
 uint8_t scrub_bank_q;
 uint8_t scrub_addr_q;
 uint8_t wb_pending_q;
 uint8_t wb_bank_q;
 uint8_t wb_addr_q;
 Word144 wb_clean_codeword_q;
 uint16_t scrub_corrected_cnt_q;
 uint8_t scrub_ded_alert_q;
 uint8_t first_ded_bank_q;
 uint8_t first_ded_addr_q;
};

static SpecSamplerState g_spec;
static PowerDroopState g_pwr;
static SramScrubberState g_sram;
static uint32_t g_dpi_calls = 0;
static int g_sim_status = 1;

static const uint8_t kPosMap[64] = {
 3, 5, 6, 7, 9, 10, 11, 12,
 13, 14, 15, 17, 18, 19, 20, 21,
 22, 23, 24, 25, 26, 27, 28, 29,
 30, 31, 33, 34, 35, 36, 37, 38,
 39, 40, 41, 42, 43, 44, 45, 46,
 47, 48, 49, 50, 51, 52, 53, 54,
 55, 56, 57, 58, 59, 60, 61, 62,
 63, 65, 66, 67, 68, 69, 70, 71
};

static inline void unpack_128(const svBitVecVal* vec, uint8_t bytes[16]) {
 for (int i = 0; i < 4; ++i) {
 uint32_t w = vec[i];
 bytes[4 * i + 0] = static_cast<uint8_t>((w >> 0) & 0xFFu);
 bytes[4 * i + 1] = static_cast<uint8_t>((w >> 8) & 0xFFu);
 bytes[4 * i + 2] = static_cast<uint8_t>((w >> 16) & 0xFFu);
 bytes[4 * i + 3] = static_cast<uint8_t>((w >> 24) & 0xFFu);
 }
}

static inline void pack_128(const uint8_t bytes[16], svBitVecVal* vec) {
 for (int i = 0; i < 4; ++i) {
 vec[i] = static_cast<uint32_t>(bytes[4 * i + 0]) |
 (static_cast<uint32_t>(bytes[4 * i + 1]) << 8) |
 (static_cast<uint32_t>(bytes[4 * i + 2]) << 16) |
 (static_cast<uint32_t>(bytes[4 * i + 3]) << 24);
 }
}

static inline Codeword72 secded_encode(uint64_t data_in) {
  uint8_t ecc = 0;
  for (int k = 0; k < 7; ++k) {
    uint8_t p = 0;
    for (int i = 0; i < 64; ++i) {
      if ((kPosMap[i] >> k) & 1u) {
        p ^= static_cast<uint8_t>((data_in >> i) & 1ULL);
      }
    }
    ecc |= static_cast<uint8_t>(p << k);
  }
  uint8_t par_data = static_cast<uint8_t>(__builtin_popcountll(data_in) & 1);
  uint8_t par_ecc  = static_cast<uint8_t>(__builtin_popcount(ecc & 0x7Fu) & 1);
  ecc |= static_cast<uint8_t>((par_data ^ par_ecc) << 7);
  return Codeword72{data_in, ecc};
}

static inline void secded_decode(
    Codeword72 cw, uint64_t* data_corr, bool* sec_err, bool* ded_err) {
  uint8_t syn_low = 0;
  for (int k = 0; k < 7; ++k) {
    uint8_t s = (cw.ecc >> k) & 1u;
    for (int i = 0; i < 64; ++i) {
      if ((kPosMap[i] >> k) & 1u) {
        s ^= static_cast<uint8_t>((cw.data >> i) & 1ULL);
      }
    }
    syn_low |= static_cast<uint8_t>(s << k);
  }
  uint8_t overall_par = static_cast<uint8_t>(
      (__builtin_popcountll(cw.data) + __builtin_popcount(cw.ecc)) & 1);
  *sec_err = (overall_par == 1u);
  *ded_err = (overall_par == 0u) && (syn_low != 0u);
  uint64_t corr = cw.data;
  if (overall_par == 1u) {
    for (int i = 0; i < 64; ++i) {
      if (syn_low == kPosMap[i]) {
        corr ^= (1ULL << i);
      }
    }
  }
  *data_corr = corr;
}

}  // namespace

extern "C" void dpi_spec_power_scrub_reset() {
  std::memset(&g_spec, 0, sizeof(g_spec));
  g_spec.nucleus_mask_q = 0x0001u;
  g_spec.accepted_node_mask_q = 0x01u;
  g_spec.best_leaf_idx_q = 0u;
  g_spec.accepted_draft_len_q = 1u;
  g_spec.total_emitted_tokens_q = 2u;
  g_spec.committed_tokens_q = 0ULL;
  g_spec.kv_ring_advance_q = 1u;
  g_spec.prng_state_q = 0x9E3779B9u;

  std::memset(&g_pwr, 0, sizeof(g_pwr));
  g_pwr.thermal_temp_c_q = 45u;

  std::memset(&g_sram, 0, sizeof(g_sram));
  g_dpi_calls = 0;
  g_sim_status = 1;
}

extern "C" uint32_t dpi_get_calls() { return g_dpi_calls; }
extern "C" void dpi_set_status(int status) { g_sim_status = status; }
extern "C" int dpi_get_status() { return g_sim_status; }

extern "C" void dpi_spec_sampler_step(
 uint32_t valid_i,
 uint32_t op_mode_i,
 const svBitVecVal* logits_i,
 const svBitVecVal* token_ids_i,
 uint32_t top_k_i,
 uint32_t inv_temp_i,
 uint32_t top_p_thresh_i,
 uint32_t rng_seed_step_i,
 uint32_t rng_threshold_i,
 uint32_t tree_parent_idx_i,
 uint64_t tree_draft_prob_i,
 uint64_t tree_target_prob_i,
 uint64_t tree_rand_u_i,
 uint64_t tree_draft_tok_i,
 uint32_t bonus_tok_i,
 uint32_t* exp_valid_o,
 uint32_t* exp_selected_token_o,
 uint32_t* exp_selected_logit_o,
 svBitVecVal* exp_sorted_logits_o,
 svBitVecVal* exp_sorted_tokens_o,
 uint32_t* exp_nucleus_mask_o,
 uint32_t* exp_accepted_node_mask_o,
 uint32_t* exp_best_leaf_idx_o,
 uint32_t* exp_accepted_draft_len_o,
 uint32_t* exp_total_emitted_tokens_o,
 uint64_t* exp_committed_tokens_o,
 uint32_t* exp_kv_ring_advance_o,
 uint32_t* exp_prng_state_o) {
 ++g_dpi_calls;
 uint8_t b_val[16];
 uint8_t b_tok[16];
 unpack_128(logits_i, b_val);
 unpack_128(token_ids_i, b_tok);

  // 10-layer Bitonic Sorting Network (Descending)
  for (int gs = 0; gs < 10; ++gs) {
    int lk = (gs == 0) ? 2 : (gs < 3) ? 4 : (gs < 6) ? 8 : 16;
    int lj = (gs == 0 || gs == 2 || gs == 5 || gs == 9) ? 1 :
             (gs == 1 || gs == 4 || gs == 8) ? 2 :
             (gs == 3 || gs == 7) ? 4 : 8;
    uint8_t next_val[16];
    uint8_t next_tok[16];
    for (int gi = 0; gi < 16; ++gi) {
      int ixj = gi ^ lj;
      bool dir_desc = ((gi & lk) == 0);
      if (ixj > gi) {
        int8_t  va = static_cast<int8_t>(b_val[gi]);
        uint8_t ta = b_tok[gi];
        int8_t  vb = static_cast<int8_t>(b_val[ixj]);
        uint8_t tb = b_tok[ixj];
        bool swap  = dir_desc ? (va < vb) : (va > vb);
        next_val[gi]  = swap ? static_cast<uint8_t>(vb) : static_cast<uint8_t>(va);
        next_tok[gi]  = swap ? tb : ta;
        next_val[ixj] = swap ? static_cast<uint8_t>(va) : static_cast<uint8_t>(vb);
        next_tok[ixj] = swap ? ta : tb;
      }
    }
    std::memcpy(b_val, next_val, 16);
    std::memcpy(b_tok, next_tok, 16);
  }

  // PRNG next state
  uint32_t s_tmp = g_spec.prng_state_q ^ (g_spec.prng_state_q << 13);
  s_tmp ^= (s_tmp >> 17);
  s_tmp ^= (s_tmp << 5);
  uint32_t prng_state_next = (s_tmp == 0u) ? 0x9E3779B9u : s_tmp;

  // Top-K / Top-P Nucleus Sampler
  uint16_t cum_weight[16];
  uint16_t nucleus_mask_comb = 0x0001u;
  uint16_t total_nucleus_mass_comb = 0u;
  uint16_t run_cum = 0u;
  uint8_t  inv_t = static_cast<uint8_t>(inv_temp_i & 0xFFu);
  uint8_t  top_k = static_cast<uint8_t>(top_k_i & 0xFu);
  uint16_t top_p = static_cast<uint16_t>(top_p_thresh_i & 0xFFFFu);

  for (int r = 0; r < 16; ++r) {
    int16_t  diff_s      = static_cast<int16_t>(static_cast<int8_t>(b_val[0])) -
                           static_cast<int16_t>(static_cast<int8_t>(b_val[r]));
    uint16_t diff_pos    = static_cast<uint16_t>(diff_s);
    uint16_t scaled_drop = static_cast<uint16_t>((diff_pos * static_cast<uint16_t>(inv_t)) & 0xFFFFu);
    uint16_t w_r         = (scaled_drop >= 255u) ? 1u : static_cast<uint16_t>(256u - scaled_drop);
    uint16_t c_r         = static_cast<uint16_t>((run_cum + w_r) & 0xFFFFu);
    cum_weight[r]        = c_r;

    bool topk_ok = (top_k == 0u) ? true : (r < static_cast<int>(top_k));
    bool topp_ok = (r == 0) ? true : (run_cum < top_p);
    bool m_r     = (r == 0) ? true : (topk_ok && topp_ok);
    if (m_r) {
      nucleus_mask_comb |= static_cast<uint16_t>(1u << r);
      total_nucleus_mass_comb = c_r;
    }
    run_cum = c_r;
  }

  uint8_t eff_rng_u = static_cast<uint8_t>((rng_threshold_i & 0xFFu) ^
      (((rng_seed_step_i & 1u) != 0u) ? static_cast<uint8_t>(g_spec.prng_state_q & 0xFFu) : 0u));
  uint16_t target_mass = static_cast<uint16_t>(
      ((static_cast<uint32_t>(total_nucleus_mass_comb) * static_cast<uint32_t>(eff_rng_u)) >> 8) & 0xFFFFu);
  uint8_t sampled_rank = 0u;
  for (int r = 15; r >= 0; --r) {
    if (((nucleus_mask_comb >> r) & 1u) && (cum_weight[r] > target_mass)) {
      sampled_rank = static_cast<uint8_t>(r);
    }
  }

  // 8-Node Speculative Draft Token Tree Verifier
  uint8_t node_local_accept = 0x01u;
  uint8_t node_path_valid   = 0x01u;
  uint8_t node_depth[8];
  node_depth[0] = 1u;
  for (int d = 1; d < 8; ++d) {
    uint8_t  p_d    = static_cast<uint8_t>((tree_target_prob_i >> (8 * d)) & 0xFFULL);
    uint8_t  q_d    = static_cast<uint8_t>((tree_draft_prob_i  >> (8 * d)) & 0xFFULL);
    uint8_t  u_d    = static_cast<uint8_t>((tree_rand_u_i      >> (8 * d)) & 0xFFULL);
    uint16_t lhs_p  = static_cast<uint16_t>(p_d) * 256u;
    uint16_t rhs_uq = static_cast<uint16_t>(u_d) * static_cast<uint16_t>(q_d);
    bool loc_acc    = (p_d >= q_d) || (lhs_p >= rhs_uq);
    if (loc_acc) node_local_accept |= static_cast<uint8_t>(1u << d);

    uint8_t p_idx   = static_cast<uint8_t>((tree_parent_idx_i >> (3 * d)) & 0x7u);
    uint8_t p_depth = node_depth[p_idx];
    if ((p_idx < static_cast<uint8_t>(d)) && (p_depth < 4u)) {
      if (((node_path_valid >> p_idx) & 1u) && loc_acc) {
        node_path_valid |= static_cast<uint8_t>(1u << d);
      }
      node_depth[d] = static_cast<uint8_t>(p_depth + 1u);
    } else {
      node_depth[d] = 1u;
    }
  }

  uint8_t best_leaf_idx = 0u;
  uint8_t best_depth    = 1u;
  uint8_t best_prob     = static_cast<uint8_t>(tree_target_prob_i & 0xFFULL);
  for (int d = 1; d < 8; ++d) {
    uint8_t d_depth = node_depth[d];
    uint8_t d_prob  = static_cast<uint8_t>((tree_target_prob_i >> (8 * d)) & 0xFFULL);
    if ((node_path_valid >> d) & 1u) {
      if ((d_depth > best_depth) || ((d_depth == best_depth) && (d_prob > best_prob))) {
        best_leaf_idx = static_cast<uint8_t>(d);
        best_depth    = d_depth;
        best_prob     = d_prob;
      }
    }
  }

  uint8_t total_emitted = static_cast<uint8_t>((best_depth + 1u) & 0x7u);
  uint8_t anc0 = best_leaf_idx & 0x7u;
  uint8_t anc1 = static_cast<uint8_t>((tree_parent_idx_i >> (3 * anc0)) & 0x7u);
  uint8_t anc2 = static_cast<uint8_t>((tree_parent_idx_i >> (3 * anc1)) & 0x7u);
  uint8_t anc3 = static_cast<uint8_t>((tree_parent_idx_i >> (3 * anc2)) & 0x7u);
  uint64_t t0  = (tree_draft_tok_i >> (8 * anc0)) & 0xFFULL;
  uint64_t t1  = (tree_draft_tok_i >> (8 * anc1)) & 0xFFULL;
  uint64_t t2  = (tree_draft_tok_i >> (8 * anc2)) & 0xFFULL;
  uint64_t t3  = (tree_draft_tok_i >> (8 * anc3)) & 0xFFULL;
  uint64_t btok = bonus_tok_i & 0xFFULL;
  uint64_t committed_tokens_comb = 0ULL;
  switch (best_depth) {
    case 1u: committed_tokens_comb = (btok << 8)  | t0; break;
    case 2u: committed_tokens_comb = (btok << 16) | (t0 << 8)  | t1; break;
    case 3u: committed_tokens_comb = (btok << 24) | (t0 << 16) | (t1 << 8)  | t2; break;
    default: committed_tokens_comb = (btok << 32) | (t0 << 24) | (t1 << 16) | (t2 << 8) | t3; break;
  }

  uint8_t selected_token_comb = 0u;
  uint8_t selected_logit_comb = 0u;
  switch (op_mode_i & 0x3u) {
    case 0u:
      selected_logit_comb = b_val[0];
      selected_token_comb = b_tok[0];
      break;
    case 1u:
      selected_logit_comb = b_val[sampled_rank];
      selected_token_comb = b_tok[sampled_rank];
      break;
    case 2u:
      selected_logit_comb = best_prob;
      selected_token_comb = static_cast<uint8_t>((tree_draft_tok_i >> (8 * best_leaf_idx)) & 0xFFULL);
      break;
    default:
      selected_logit_comb = b_val[0];
      selected_token_comb = b_tok[0];
      break;
  }

  g_spec.valid_q = (valid_i & 1u) ? 1u : 0u;
  if ((valid_i & 1u) != 0u) {
    g_spec.selected_token_q       = selected_token_comb;
    g_spec.selected_logit_q       = selected_logit_comb;
    std::memcpy(g_spec.sorted_logits_q, b_val, 16);
    std::memcpy(g_spec.sorted_tokens_q, b_tok, 16);
    g_spec.nucleus_mask_q         = nucleus_mask_comb;
    g_spec.accepted_node_mask_q   = node_path_valid;
    g_spec.best_leaf_idx_q        = best_leaf_idx;
    g_spec.accepted_draft_len_q   = best_depth;
    g_spec.total_emitted_tokens_q = total_emitted;
    g_spec.committed_tokens_q     = committed_tokens_comb;
    g_spec.kv_ring_advance_q      = best_depth;
    if ((rng_seed_step_i & 1u) != 0u) {
      g_spec.prng_state_q = prng_state_next;
    }
  }

  *exp_valid_o                = g_spec.valid_q;
  *exp_selected_token_o       = g_spec.selected_token_q;
  *exp_selected_logit_o       = g_spec.selected_logit_q;
  pack_128(g_spec.sorted_logits_q, exp_sorted_logits_o);
  pack_128(g_spec.sorted_tokens_q, exp_sorted_tokens_o);
  *exp_nucleus_mask_o         = g_spec.nucleus_mask_q;
  *exp_accepted_node_mask_o   = g_spec.accepted_node_mask_q;
  *exp_best_leaf_idx_o        = g_spec.best_leaf_idx_q;
  *exp_accepted_draft_len_o   = g_spec.accepted_draft_len_q;
  *exp_total_emitted_tokens_o = g_spec.total_emitted_tokens_q;
  *exp_committed_tokens_o     = g_spec.committed_tokens_q;
  *exp_kv_ring_advance_o      = g_spec.kv_ring_advance_q;
  *exp_prng_state_o           = g_spec.prng_state_q;
}

extern "C" void dpi_power_droop_step(
 uint32_t enable_i,
 uint32_t slice_active_i,
 uint32_t mxm_zero_skip_cnt_i,
 uint32_t prewarm_hint_i,
 uint32_t prewarm_target_level_i,
 uint32_t max_didt_step_i,
 uint32_t vdd_nominal_mv_i,
 uint32_t droop_emerg_thresh_mv_i,
 uint32_t* exp_raw_demand_o,
 uint32_t* exp_eff_current_o,
 uint32_t* exp_dummy_bleed_current_o,
 uint32_t* exp_dummy_bleed_mask_o,
 int32_t* exp_didt_signed_o,
 uint32_t* exp_vdd_est_mv_o,
 uint32_t* exp_thermal_temp_c_o,
 uint32_t* exp_emerg_throttle_o,
 uint32_t* exp_droop_mitigated_events_o) {
 uint8_t sa = static_cast<uint8_t>(slice_active_i & 0xFFu);
 uint8_t zskip = static_cast<uint8_t>(mxm_zero_skip_cnt_i & 0x3Fu);
 uint8_t zclamped = (zskip > 32u) ? 32u : zskip;
 uint8_t mxm_curr = static_cast<uint8_t>(64u - zclamped);

 uint8_t nim_c = (sa & (1u << 0)) ? 12u : 0u;
 uint8_t mem_w_c = (sa & (1u << 1)) ? 20u : 0u;
 uint8_t sxm_c = (sa & (1u << 2)) ? 24u : 0u;
 uint8_t vxm_c = (sa & (1u << 3)) ? 24u : 0u;
 uint8_t mxm_w_c = (sa & (1u << 4)) ? mxm_curr : 0u;
 uint8_t icu_c = (sa & (1u << 5)) ? 12u : 0u;
 uint8_t mxm_e_c = (sa & (1u << 6)) ? mxm_curr : 0u;
 uint8_t mem_e_c = (sa & (1u << 7)) ? 20u : 0u;

 uint8_t raw_demand_c = static_cast<uint8_t>(
 nim_c + mem_w_c + sxm_c + vxm_c + mxm_w_c + icu_c + mxm_e_c + mem_e_c);

 uint8_t max_step = static_cast<uint8_t>(max_didt_step_i & 0xFFu);
 uint8_t pre_target = static_cast<uint8_t>(prewarm_target_level_i & 0xFFu);
 uint8_t ramp_down_floor_c = (g_pwr.eff_current_q > max_step)
 ? static_cast<uint8_t>(g_pwr.eff_current_q - max_step)
 : 0u;
 uint16_t step_up_sum_c = static_cast<uint16_t>(g_pwr.eff_current_q) +
 static_cast<uint16_t>(max_step);
 uint8_t prewarm_step_up_c = (step_up_sum_c >= static_cast<uint16_t>(pre_target))
 ? pre_target
 : static_cast<uint8_t>(step_up_sum_c & 0xFFu);

 uint8_t bleed_target_c = ramp_down_floor_c;
 if (((prewarm_hint_i & 1u) != 0u) && (raw_demand_c < pre_target)) {
 if (prewarm_step_up_c > bleed_target_c) {
 bleed_target_c = prewarm_step_up_c;
 }
 }

 uint8_t eff_current_next = 0u;
 uint8_t dummy_bleed_current_c = 0u;
 if ((enable_i & 1u) == 0u) {
 eff_current_next = raw_demand_c;
 dummy_bleed_current_c = 0u;
 } else if (raw_demand_c < bleed_target_c) {
 eff_current_next = bleed_target_c;
 dummy_bleed_current_c = static_cast<uint8_t>(bleed_target_c - raw_demand_c);
 } else {
 eff_current_next = raw_demand_c;
 dummy_bleed_current_c = 0u;
 }

 uint8_t dummy_bleed_mask_c = 0u;
 for (int k = 0; k < 8; ++k) {
 if (dummy_bleed_current_c > static_cast<uint8_t>(k * 16)) {
 dummy_bleed_mask_c |= static_cast<uint8_t>(1u << k);
 }
 }

 int32_t didt_signed_c = static_cast<int32_t>(eff_current_next) -
 static_cast<int32_t>(g_pwr.eff_current_q);
 uint8_t abs_didt_c = (eff_current_next >= g_pwr.eff_current_q)
 ? static_cast<uint8_t>(eff_current_next - g_pwr.eff_current_q)
 : static_cast<uint8_t>(g_pwr.eff_current_q - eff_current_next);
 uint16_t ir_drop_mv_c = static_cast<uint16_t>(eff_current_next >> 2);
 uint16_t ind_drop_mv_c = static_cast<uint16_t>(abs_didt_c >> 1);
 uint16_t total_drop_mv_c = static_cast<uint16_t>(ir_drop_mv_c + ind_drop_mv_c);
 uint16_t vdd_nom = static_cast<uint16_t>(vdd_nominal_mv_i & 0xFFFu);
 uint16_t vdd_thresh = static_cast<uint16_t>(droop_emerg_thresh_mv_i & 0xFFFu);
 uint16_t vdd_est_mv_c = (vdd_nom > total_drop_mv_c)
 ? static_cast<uint16_t>(vdd_nom - total_drop_mv_c)
 : 0u;

 uint8_t temp_eq_c = static_cast<uint8_t>(45u + (g_pwr.eff_current_q >> 2));
 uint8_t emerg_throttle_c =
 ((vdd_est_mv_c < vdd_thresh) || (g_pwr.thermal_temp_c_q >= 105u)) ? 1u : 0u;

 // Sequential update at posedge clk
 g_pwr.eff_current_q = eff_current_next;
 if ((enable_i & 1u) != 0u) {
 uint8_t old_tick = g_pwr.therm_tick_q;
 g_pwr.therm_tick_q = static_cast<uint8_t>((g_pwr.therm_tick_q + 1u) & 0x7u);
 if (old_tick == 7u) {
 if (g_pwr.thermal_temp_c_q < temp_eq_c) {
 g_pwr.thermal_temp_c_q = static_cast<uint8_t>(g_pwr.thermal_temp_c_q + 1u);
 } else if (g_pwr.thermal_temp_c_q > temp_eq_c) {
 g_pwr.thermal_temp_c_q = static_cast<uint8_t>(g_pwr.thermal_temp_c_q - 1u);
 }
 }
 if ((dummy_bleed_current_c != 0u) && (g_pwr.droop_mitigated_events_q != 0xFFFFu)) {
 g_pwr.droop_mitigated_events_q = static_cast<uint16_t>(g_pwr.droop_mitigated_events_q + 1u);
 }
 }

 *exp_raw_demand_o = raw_demand_c;
 *exp_eff_current_o = g_pwr.eff_current_q;
 *exp_dummy_bleed_current_o = dummy_bleed_current_c;
 *exp_dummy_bleed_mask_o = dummy_bleed_mask_c;
 *exp_didt_signed_o = didt_signed_c;
 *exp_vdd_est_mv_o = vdd_est_mv_c;
 *exp_thermal_temp_c_o = g_pwr.thermal_temp_c_q;
 *exp_emerg_throttle_o = emerg_throttle_c;
 *exp_droop_mitigated_events_o = g_pwr.droop_mitigated_events_q;
}

extern "C" void dpi_sram_scrubber_step(
 uint32_t efuse_load_req_i,
 uint32_t efuse_bank_i,
 uint32_t efuse_bad_addr_i,
 uint32_t vliw_rd_en_i,
 uint32_t vliw_rd_bank_i,
 uint32_t vliw_rd_addr_i,
 uint32_t vliw_wr_en_i,
 uint32_t vliw_wr_bank_i,
 uint32_t vliw_wr_addr_i,
 const svBitVecVal* vliw_wr_data_i,
 uint32_t dma_wr_en_i,
 uint32_t dma_wr_bank_i,
 uint32_t dma_wr_addr_i,
 const svBitVecVal* dma_wr_data_i,
 uint32_t scrub_enable_i,
 uint32_t ser_inject_en_i,
 uint32_t ser_inject_bank_i,
 uint32_t ser_inject_addr_i,
 uint64_t ser_mask_lo_data_i,
 uint32_t ser_mask_lo_ecc_i,
 uint64_t ser_mask_hi_data_i,
 uint32_t ser_mask_hi_ecc_i,
 uint32_t* exp_bank_repair_en_o,
 uint32_t* exp_bank_repair_addr_o,
 uint32_t* exp_efuse_load_ack_o,
 uint32_t* exp_vliw_rd_valid_o,
 svBitVecVal* exp_vliw_rd_data_o,
 uint32_t* exp_vliw_rd_sec_err_o,
 uint32_t* exp_vliw_rd_ded_err_o,
 uint32_t* exp_vliw_rd_repaired_row_hit_o,
 uint32_t* exp_scrub_rd_fire_o,
 uint32_t* exp_scrub_wb_fire_o,
 uint32_t* exp_scrub_active_bank_o,
 uint32_t* exp_scrub_active_addr_o,
 uint32_t* exp_scrub_corrected_cnt_o,
 uint32_t* exp_scrub_ded_alert_o,
 uint32_t* exp_first_ded_bank_o,
 uint32_t* exp_first_ded_addr_o) {
 uint8_t vliw_wr_b[16];
 uint8_t dma_wr_b[16];
 unpack_128(vliw_wr_data_i, vliw_wr_b);
 unpack_128(dma_wr_data_i, dma_wr_b);
 uint64_t vliw_wr_lo = 0ULL, vliw_wr_hi = 0ULL;
 uint64_t dma_wr_lo = 0ULL, dma_wr_hi = 0ULL;
 std::memcpy(&vliw_wr_lo, &vliw_wr_b[0], 8);
 std::memcpy(&vliw_wr_hi, &vliw_wr_b[8], 8);
 std::memcpy(&dma_wr_lo, &dma_wr_b[0], 8);
 std::memcpy(&dma_wr_hi, &dma_wr_b[8], 8);

 Word144 vliw_wr_cw{secded_encode(vliw_wr_lo), secded_encode(vliw_wr_hi)};
 Word144 dma_wr_cw{secded_encode(dma_wr_lo), secded_encode(dma_wr_hi)};

 uint8_t rd_b = static_cast<uint8_t>(vliw_rd_bank_i & 0x3u);
 uint8_t rd_a = static_cast<uint8_t>(vliw_rd_addr_i & 0x3Fu);
 uint8_t vwr_b = static_cast<uint8_t>(vliw_wr_bank_i & 0x3u);
 uint8_t vwr_a = static_cast<uint8_t>(vliw_wr_addr_i & 0x3Fu);
 uint8_t dwr_b = static_cast<uint8_t>(dma_wr_bank_i & 0x3u);
 uint8_t dwr_a = static_cast<uint8_t>(dma_wr_addr_i & 0x3Fu);
 uint8_t ser_b = static_cast<uint8_t>(ser_inject_bank_i & 0x3u);
 uint8_t ser_a = static_cast<uint8_t>(ser_inject_addr_i & 0x3Fu);

 bool fg_bank_busy[4];
 for (int b = 0; b < 4; ++b) {
 fg_bank_busy[b] = (((vliw_rd_en_i & 1u) != 0u) && (rd_b == b)) ||
 (((vliw_wr_en_i & 1u) != 0u) && (vwr_b == b)) ||
 (((dma_wr_en_i & 1u) != 0u) && (dwr_b == b));
 }

 bool fg_overwrites_wb =
 (((vliw_wr_en_i & 1u) != 0u) && (vwr_b == g_sram.wb_bank_q) && (vwr_a == g_sram.wb_addr_q)) ||
 (((dma_wr_en_i & 1u) != 0u) && (dwr_b == g_sram.wb_bank_q) && (dwr_a == g_sram.wb_addr_q)) ||
 (((ser_inject_en_i & 1u) != 0u) && (ser_b == g_sram.wb_bank_q) && (ser_a == g_sram.wb_addr_q));

 Word144 scrub_raw_cw = g_sram.mem_q[g_sram.scrub_bank_q][g_sram.scrub_addr_q];
 uint64_t scrub_corr_lo = 0ULL, scrub_corr_hi = 0ULL;
 bool scrub_sec_lo = false, scrub_ded_lo = false;
 bool scrub_sec_hi = false, scrub_ded_hi = false;
 secded_decode(scrub_raw_cw.lo, &scrub_corr_lo, &scrub_sec_lo, &scrub_ded_lo);
 secded_decode(scrub_raw_cw.hi, &scrub_corr_hi, &scrub_sec_hi, &scrub_ded_hi);
 bool scrub_ded_any = scrub_ded_lo || scrub_ded_hi;
 bool scrub_sec_any = (scrub_sec_lo || scrub_sec_hi) && !scrub_ded_any;

 uint8_t scrub_rd_fire_c = 0u;
 uint8_t scrub_wb_fire_c = 0u;
 uint8_t scrub_active_bank_c = g_sram.scrub_bank_q;
 uint8_t scrub_active_addr_c = g_sram.scrub_addr_q;

 if ((scrub_enable_i & 1u) != 0u) {
 if ((g_sram.wb_pending_q != 0u) && !fg_overwrites_wb) {
 scrub_active_bank_c = g_sram.wb_bank_q;
 scrub_active_addr_c = g_sram.wb_addr_q;
 if (!fg_bank_busy[g_sram.wb_bank_q]) {
 scrub_wb_fire_c = 1u;
 }
 } else if (g_sram.wb_pending_q == 0u) {
 scrub_active_bank_c = g_sram.scrub_bank_q;
 scrub_active_addr_c = g_sram.scrub_addr_q;
 if (!fg_bank_busy[g_sram.scrub_bank_q]) {
 scrub_rd_fire_c = 1u;
 }
 }
 }

  // Snapshot pre-posedge state for NBA semantics
  Word144 old_rd_cw  = g_sram.mem_q[rd_b][rd_a];
  Word144 old_ser_cw = g_sram.mem_q[ser_b][ser_a];
  bool    old_rep_hit = (((g_sram.bank_repair_en_q >> rd_b) & 1u) != 0u) &&
                        (rd_a == g_sram.bank_repair_addr_q[rd_b]);

  // 1. Boot eFuse Row-Repair Loader FSM
  g_sram.efuse_load_ack_q = (efuse_load_req_i & 1u) ? 1u : 0u;
  if ((efuse_load_req_i & 1u) != 0u) {
    uint8_t eb = static_cast<uint8_t>(efuse_bank_i & 0x3u);
    uint8_t ea = static_cast<uint8_t>(efuse_bad_addr_i & 0x3Fu);
    g_sram.bank_repair_en_q |= static_cast<uint8_t>(1u << eb);
    g_sram.bank_repair_addr_q[eb] = ea;
  }

  // 2. Foreground VLIW Read
  g_sram.vliw_rd_valid_q = (vliw_rd_en_i & 1u) ? 1u : 0u;
  if ((vliw_rd_en_i & 1u) != 0u) {
    g_sram.vliw_rd_raw_cw_q           = old_rd_cw;
    g_sram.vliw_rd_repaired_row_hit_q = old_rep_hit ? 1u : 0u;
  } else {
    g_sram.vliw_rd_repaired_row_hit_q = 0u;
  }

  // 3. Background Scrubber Writeback & Read
  if (scrub_wb_fire_c != 0u) {
    g_sram.mem_q[g_sram.wb_bank_q][g_sram.wb_addr_q] = g_sram.wb_clean_codeword_q;
    g_sram.wb_pending_q = 0u;
  } else if (fg_overwrites_wb) {
    g_sram.wb_pending_q = 0u;
  }

  if (scrub_rd_fire_c != 0u) {
    uint8_t ptr = static_cast<uint8_t>(((g_sram.scrub_addr_q << 2) | g_sram.scrub_bank_q) + 1u);
    uint8_t cur_b = g_sram.scrub_bank_q;
    uint8_t cur_a = g_sram.scrub_addr_q;
    g_sram.scrub_bank_q = static_cast<uint8_t>(ptr & 0x3u);
    g_sram.scrub_addr_q = static_cast<uint8_t>((ptr >> 2) & 0x3Fu);
    if (scrub_ded_any) {
      if (g_sram.scrub_ded_alert_q == 0u) {
        g_sram.first_ded_bank_q = cur_b;
        g_sram.first_ded_addr_q = cur_a;
      }
      g_sram.scrub_ded_alert_q = 1u;
    } else if (scrub_sec_any) {
      g_sram.wb_pending_q        = 1u;
      g_sram.wb_bank_q           = cur_b;
      g_sram.wb_addr_q           = cur_a;
      g_sram.wb_clean_codeword_q = Word144{secded_encode(scrub_corr_lo), secded_encode(scrub_corr_hi)};
      if (g_sram.scrub_corrected_cnt_q != 0xFFFFu) {
        g_sram.scrub_corrected_cnt_q = static_cast<uint16_t>(g_sram.scrub_corrected_cnt_q + 1u);
      }
    }
  }

  // 4. DMA Write, VLIW Write, SER Injection (NBA priority order)
  if ((dma_wr_en_i & 1u) != 0u) {
    g_sram.mem_q[dwr_b][dwr_a] = dma_wr_cw;
  }
  if ((vliw_wr_en_i & 1u) != 0u) {
    g_sram.mem_q[vwr_b][vwr_a] = vliw_wr_cw;
  }
  if ((ser_inject_en_i & 1u) != 0u) {
    Word144 inj_cw;
    inj_cw.lo.data = old_ser_cw.lo.data ^ ser_mask_lo_data_i;
    inj_cw.lo.ecc  = static_cast<uint8_t>(old_ser_cw.lo.ecc ^ (ser_mask_lo_ecc_i & 0xFFu));
    inj_cw.hi.data = old_ser_cw.hi.data ^ ser_mask_hi_data_i;
    inj_cw.hi.ecc  = static_cast<uint8_t>(old_ser_cw.hi.ecc ^ (ser_mask_hi_ecc_i & 0xFFu));
    g_sram.mem_q[ser_b][ser_a] = inj_cw;
  }

  // Post-posedge VLIW Read Decode
  uint64_t vliw_corr_lo = 0ULL, vliw_corr_hi = 0ULL;
  bool     vliw_sec_lo = false, vliw_ded_lo = false;
  bool     vliw_sec_hi = false, vliw_ded_hi = false;
  secded_decode(g_sram.vliw_rd_raw_cw_q.lo, &vliw_corr_lo, &vliw_sec_lo, &vliw_ded_lo);
  secded_decode(g_sram.vliw_rd_raw_cw_q.hi, &vliw_corr_hi, &vliw_sec_hi, &vliw_ded_hi);

  uint8_t rd_out_b[16];
  std::memcpy(&rd_out_b[0], &vliw_corr_lo, 8);
  std::memcpy(&rd_out_b[8], &vliw_corr_hi, 8);
  pack_128(rd_out_b, exp_vliw_rd_data_o);

  uint32_t packed_rep_addr =
      (static_cast<uint32_t>(g_sram.bank_repair_addr_q[0] & 0x3Fu) << 0) |
      (static_cast<uint32_t>(g_sram.bank_repair_addr_q[1] & 0x3Fu) << 6) |
      (static_cast<uint32_t>(g_sram.bank_repair_addr_q[2] & 0x3Fu) << 12) |
      (static_cast<uint32_t>(g_sram.bank_repair_addr_q[3] & 0x3Fu) << 18);

  *exp_bank_repair_en_o           = g_sram.bank_repair_en_q;
  *exp_bank_repair_addr_o         = packed_rep_addr;
  *exp_efuse_load_ack_o           = g_sram.efuse_load_ack_q;
  *exp_vliw_rd_valid_o            = g_sram.vliw_rd_valid_q;
  *exp_vliw_rd_sec_err_o          = ((g_sram.vliw_rd_valid_q != 0u) && (vliw_sec_lo || vliw_sec_hi)) ? 1u : 0u;
  *exp_vliw_rd_ded_err_o          = ((g_sram.vliw_rd_valid_q != 0u) && (vliw_ded_lo || vliw_ded_hi)) ? 1u : 0u;
  *exp_vliw_rd_repaired_row_hit_o = g_sram.vliw_rd_repaired_row_hit_q;
  *exp_scrub_rd_fire_o            = scrub_rd_fire_c;
  *exp_scrub_wb_fire_o            = scrub_wb_fire_c;
  *exp_scrub_active_bank_o        = scrub_active_bank_c;
  *exp_scrub_active_addr_o        = scrub_active_addr_c;
  *exp_scrub_corrected_cnt_o      = g_sram.scrub_corrected_cnt_q;
  *exp_scrub_ded_alert_o          = g_sram.scrub_ded_alert_q;
  *exp_first_ded_bank_o           = g_sram.first_ded_bank_q;
  *exp_first_ded_addr_o           = g_sram.first_ded_addr_q;
}
