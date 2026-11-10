// =============================================================================
// File: uvm_tb/uvm_high_intensity_cross_ref/dpi_master_golden_ref.cpp
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 35/36 Unified Cycle-Accurate Bit-Exact C++17 DPI-C Master
//              Golden Reference Model for 6 Core RTL Subsystems in Lockstep:
//              1. groq_sxm_slice (incl. -128 RoPE saturating negation BUG-LIT-001)
//              2. groq_vxm_slice (incl. PREC_INT8_RNE IEEE 754-2019 ties BUG-LIT-005)
//              3. groq_nim_realsync (incl. RUNTIME_DESKEW & HAC consensus BUG-LIT-003)
//              4. groq_mxfp8_nvfp4_dot_engine (incl. MODE_NVFP4_E4M3_SCALE BUG-LIT-002)
//              5. groq_c2c_kv_quant_rx_engine (incl. NVFP4 E4M3 scale BUG-LIT-006)
//              6. groq_spec_decode_tree_sampler (incl. EAGLE-2 tree BUG-LIT-007)
// =============================================================================
#include <cstdint>
#include <cstring>
#include "svdpi.h"

namespace {

struct SxmState {
  uint8_t transpose_buf[16][16];
  uint8_t sxm_out_valid_q;
  uint8_t sxm_out_data_q[16];
};

struct VxmState {
  uint8_t vxm_out_valid_q;
  uint8_t vxm_out_data_q[16];
  int32_t vxm_accum_out_q[16];
};

struct NimState {
  bool     buf_valid[4];
  uint8_t  buf_data[4][16];
  uint16_t buf_target_cycle[4];
  uint8_t  wr_ptr;
  uint8_t  nim_local_out_data_q[16];
  uint8_t  c2c_tx_data_q[16];
  uint16_t c2c_tx_ts_q;
  uint8_t  c2c_tx_dst_q;
  uint8_t  c2c_tx_crc8_q;
  uint8_t  c2c_tx_port_q;
  int16_t  measured_skew_q;
};

struct DotState {
  uint8_t  s1_valid_q;
  uint8_t  s1_accum_en_q;
  uint8_t  s1_accum_clear_q;
  uint8_t  s1_act_scale_q;
  uint8_t  s1_wt_scale_q;
  int32_t  s1_tree_sum_q;
  uint8_t  s1_zero_skip_lanes_q;
  uint8_t  s1_block_zero_skip_q;
  uint8_t  s1_nan_inf_q;
  uint8_t  valid_q;
  int32_t  unaccum_dot_q;
  int32_t  dot_accum_q;
  uint32_t dot_fp32_q;
  uint8_t  zero_skip_lanes_q;
  uint8_t  block_zero_skipped_q;
  uint8_t  nan_inf_flag_q;
};

struct KvqState {
  uint8_t  valid_q;
  uint8_t  quant_vec_q[16];
  uint8_t  scale_e8m0_q;
  uint8_t  sram_wr_en_q;
  uint8_t  sram_wr_bank_q;
  uint16_t sram_wr_addr_q;
  uint8_t  zero_lanes_cnt_q;
  uint8_t  nan_inf_clamped_q;
  uint8_t  comp_ratio_q;
};

struct SpecState {
  uint8_t  valid_q;
  uint8_t  selected_token_q;
  uint8_t  selected_logit_q;
  uint8_t  sorted_logits_q[16];
  uint8_t  sorted_tokens_q[16];
  uint16_t nucleus_mask_q;
  uint8_t  accepted_node_mask_q;
  uint8_t  best_leaf_idx_q;
  uint8_t  accepted_draft_len_q;
  uint8_t  total_emitted_tokens_q;
  uint64_t committed_tokens_q;
  uint8_t  kv_ring_advance_q;
  uint32_t prng_state_q;
};
static SxmState  g_sxm;
static VxmState  g_vxm;
static NimState  g_nim;
static DotState  g_dot;
static KvqState  g_kvq;
static SpecState g_spec;
static uint32_t  g_dpi_tx_calls     = 0;
static uint32_t  g_dpi_module_steps = 0;
static int       g_sim_status       = 1;

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
    vec[i] = (static_cast<uint32_t>(bytes[4 * i + 0]) << 0) |
             (static_cast<uint32_t>(bytes[4 * i + 1]) << 8) |
             (static_cast<uint32_t>(bytes[4 * i + 2]) << 16) |
             (static_cast<uint32_t>(bytes[4 * i + 3]) << 24);
  }
}

static inline int8_t sat_int8_ref(int64_t val) {
  if (val > 127)  return 127;
  if (val < -128) return -128;
  return static_cast<int8_t>(val);
}

static inline int8_t relu_int8_ref(int8_t x) { return (x <= 0) ? 0 : x; }

static inline int8_t silu_lut_int8_ref(int8_t x) {
  int16_t x_ext = static_cast<int16_t>(x);
  int16_t y = 0;
  if (x <= -64)      y = 0;
  else if (x <= -32) y = static_cast<int16_t>(-((x_ext + 64) >> 3));
  else if (x < 0)    y = static_cast<int16_t>(x_ext >> 2);
  else if (x < 32)   y = static_cast<int16_t>(((x_ext << 2) + x_ext) >> 3);
  else if (x < 64)   y = static_cast<int16_t>(x_ext - 12);
  else               y = x_ext;
  return sat_int8_ref(y);
}

static inline int8_t gelu_lut_int8_ref(int8_t x) {
  int16_t x_ext = static_cast<int16_t>(x);
  int16_t y = 0;
  if (x <= -48)     y = 0;
  else if (x < 0)   y = static_cast<int16_t>(((x_ext + 48) >> 4) - 3);
  else if (x < 48)  y = static_cast<int16_t>(((x_ext << 1) + x_ext) >> 2);
  else              y = x_ext;
  return sat_int8_ref(y);
}

static inline int8_t exp_lut_int8_ref(int8_t x) {
  if (x >= 0)   return 127;
  if (x <= -64) return 1;
  uint8_t neg_x  = static_cast<uint8_t>(-x) & 0x3Fu;
  uint8_t seg    = (neg_x >> 3) & 0x7u;
  int16_t frac_s = static_cast<int16_t>(neg_x & 0x7u);
  int16_t base_val = 15, delta_val = frac_s;
  switch (seg) {
    case 0: base_val = 127; delta_val = static_cast<int16_t>(frac_s << 2); break;
    case 1: base_val = 95;  delta_val = static_cast<int16_t>((frac_s << 1) + frac_s); break;
    case 2: base_val = 71;  delta_val = static_cast<int16_t>(frac_s << 1); break;
    case 3: base_val = 55;  delta_val = static_cast<int16_t>(frac_s << 1); break;
    case 4: base_val = 39;  delta_val = frac_s; break;
    case 5: base_val = 31;  delta_val = frac_s; break;
    case 6: base_val = 23;  delta_val = frac_s; break;
    default: base_val = 15; delta_val = frac_s; break;
  }
  return sat_int8_ref(base_val - delta_val);
}

static inline int8_t rsqrt_lut_int8_ref(int8_t x) {
  uint8_t abs_x = (x < 0) ? ((x == -128) ? 127u : (static_cast<uint8_t>(-x) & 0x7Fu))
                          : (static_cast<uint8_t>(x) & 0x7Fu);
  uint8_t seg    = (abs_x >> 4) & 0x7u;
  int16_t frac_s = static_cast<int16_t>(abs_x & 0xFu);
  int16_t base_val = 25, delta_val = 0;
  switch (seg) {
    case 0: base_val = 127; delta_val = static_cast<int16_t>((frac_s << 1) + frac_s); break;
    case 1: base_val = 79;  delta_val = static_cast<int16_t>(frac_s << 1); break;
    case 2: base_val = 55;  delta_val = frac_s; break;
    case 3: base_val = 43;  delta_val = frac_s; break;
    case 4: base_val = 35;  delta_val = 0; break;
    case 5: base_val = 31;  delta_val = 0; break;
    case 6: base_val = 28;  delta_val = 0; break;
    default: base_val = 25; delta_val = 0; break;
  }
  return sat_int8_ref(base_val - (delta_val >> 1));
}
static inline int8_t quant_scale_elem_ref(int32_t raw_val, uint8_t shamt, uint8_t pmode) {
  int64_t raw_ext       = static_cast<int64_t>(raw_val);
  int64_t half_val      = (shamt == 0u) ? 0LL : (1LL << (shamt - 1u));
  int64_t rem_mask      = (shamt == 0u) ? 0LL : ((1LL << shamt) - 1LL);
  bool    is_exact_tie  = ((raw_ext & rem_mask) == half_val);
  bool    quot_lsb_even = (((static_cast<uint32_t>(raw_val) >> shamt) & 1u) == 0u);
  int64_t round_bias    = ((pmode == 3u) && is_exact_tie && quot_lsb_even) ? 0LL : half_val;
  int64_t rounded       = (shamt == 0u) ? raw_ext : ((raw_ext + round_bias) >> shamt);
  int8_t  q_int8        = sat_int8_ref(rounded);
  if (pmode == 1u) { // PREC_FP8_E4M3
    if (q_int8 == 127) return 126;
    if (q_int8 == -1)  return -2;
  }
  return q_int8;
}

static inline uint8_t crc8_byte_step_ref(uint8_t crc_in, uint8_t data_byte) {
  uint8_t c = crc_in ^ data_byte;
  for (int b = 0; b < 8; ++b) {
    if (c & 0x80u) c = static_cast<uint8_t>((c << 1) ^ 0x07u);
    else           c = static_cast<uint8_t>(c << 1);
  }
  return c;
}

static inline uint8_t crc8_calc_ref(const uint8_t payload[16], uint16_t ts) {
  uint8_t crc = 0xFFu;
  for (int i = 0; i < 16; ++i) crc = crc8_byte_step_ref(crc, payload[i]);
  crc = crc8_byte_step_ref(crc, static_cast<uint8_t>(ts & 0xFFu));
  crc = crc8_byte_step_ref(crc, static_cast<uint8_t>((ts >> 8) & 0xFFu));
  return crc;
}

static inline uint8_t dragonfly_route_ref(uint8_t src_chip, uint8_t dst_chip, bool ugal_en, bool congested) {
  if (ugal_en && congested && (src_chip != dst_chip)) return 2u;
  if (((src_chip >> 2) & 0x3u) != ((dst_chip >> 2) & 0x3u)) return 1u;
  return 0u;
}

static inline uint8_t fn_nvfp4_mag_2x(uint8_t em) {
  static const uint8_t kLut[8] = {0, 1, 2, 3, 4, 6, 8, 12};
  return kLut[em & 0x7u];
}

} // namespace

extern "C" void dpi_master_reset() {
  std::memset(&g_sxm,  0, sizeof(g_sxm));
  std::memset(&g_vxm,  0, sizeof(g_vxm));
  std::memset(&g_nim,  0, sizeof(g_nim));
  std::memset(&g_dot,  0, sizeof(g_dot));
  std::memset(&g_kvq,  0, sizeof(g_kvq));
  g_kvq.comp_ratio_q = 1u;
  std::memset(&g_spec, 0, sizeof(g_spec));
  g_spec.nucleus_mask_q         = 0x0001u;
  g_spec.accepted_node_mask_q   = 0x01u;
  g_spec.best_leaf_idx_q        = 0u;
  g_spec.accepted_draft_len_q   = 1u;
  g_spec.total_emitted_tokens_q = 2u;
  g_spec.committed_tokens_q     = 0ULL;
  g_spec.kv_ring_advance_q      = 1u;
  g_spec.prng_state_q           = 0x9E3779B9u;
  g_dpi_tx_calls                = 0;
  g_dpi_module_steps            = 0;
  g_sim_status                  = 1;
}

extern "C" uint32_t dpi_get_calls()        { return g_dpi_tx_calls; }
extern "C" uint32_t dpi_get_module_steps() { return g_dpi_module_steps; }
extern "C" void     dpi_set_status(int s)  { g_sim_status = s; }
extern "C" int      dpi_get_status()       { return g_sim_status; }

extern "C" void dpi_sxm_step(
    uint32_t sxm_op_i,
    uint32_t shift_amt_i,
    uint32_t src_lane_i,
    uint32_t butterfly_mask_i,
    uint32_t transpose_idx_i,
    uint32_t rope_neg_even_en_i,
    uint32_t stream_in_valid_i,
    const svBitVecVal* stream_in_data_i,
    uint32_t* exp_stream_out_valid_o,
    svBitVecVal* exp_stream_out_data_o,
    svBitVecVal* exp_perm_comb_data_o) {
  g_dpi_tx_calls++;
  g_dpi_module_steps++;
  uint8_t sxm_in[16];
  unpack_128(stream_in_data_i, sxm_in);
  uint8_t sxm_op   = static_cast<uint8_t>(sxm_op_i & 0xFu);
  uint8_t shamt    = static_cast<uint8_t>(shift_amt_i & 0xFu);
  uint8_t bcast    = static_cast<uint8_t>(src_lane_i & 0xFu);
  uint8_t bfly     = static_cast<uint8_t>(butterfly_mask_i & 0xFu);
  uint8_t tidx     = static_cast<uint8_t>(transpose_idx_i & 0xFu);
  bool    rope_neg = (rope_neg_even_en_i & 1u) != 0u;
  bool    sxm_val  = (stream_in_valid_i & 1u) != 0u;

  uint8_t pre_perm[16];
  for (int i = 0; i < 16; ++i) {
    if (sxm_op == 11u) {
      pre_perm[i] = g_sxm.transpose_buf[i][tidx];
    } else {
      uint8_t idx_rot_l  = static_cast<uint8_t>((i - shamt) & 0xFu);
      uint8_t idx_rot_r  = static_cast<uint8_t>((i + shamt) & 0xFu);
      uint8_t idx_bitrev = static_cast<uint8_t>(((i & 1) << 3) | ((i & 2) << 1) | ((i & 4) >> 1) | ((i & 8) >> 3));
      uint8_t idx_bfly   = static_cast<uint8_t>((i ^ bfly) & 0xFu);
      uint8_t idx_t4     = static_cast<uint8_t>(((i & 3) << 2) | ((i >> 2) & 3));
      switch (sxm_op) {
        case 1u:  pre_perm[i] = sxm_in[i]; break;
        case 2u:
        case 7u:  pre_perm[i] = sxm_in[idx_rot_l]; break;
        case 8u:  pre_perm[i] = sxm_in[idx_rot_r]; break;
        case 5u:  pre_perm[i] = sxm_in[bcast]; break;
        case 9u:  pre_perm[i] = sxm_in[15 - i]; break;
        case 4u:  pre_perm[i] = sxm_in[idx_bitrev]; break;
        case 3u:  pre_perm[i] = sxm_in[idx_t4]; break;
        case 6u:  pre_perm[i] = (i < 8) ? sxm_in[2 * i] : sxm_in[2 * (i - 8) + 1]; break;
        case 12u: pre_perm[i] = (rope_neg && ((i & 1) == 0))
                                    ? ((sxm_in[idx_bfly] == 0x80u) ? 0x7Fu : static_cast<uint8_t>(-sxm_in[idx_bfly]))
                                    : sxm_in[idx_bfly];
                  break;
        default:  pre_perm[i] = sxm_in[i]; break;
      }
    }
  }
  if (sxm_op == 10u && sxm_val) {
    std::memcpy(g_sxm.transpose_buf[tidx], sxm_in, 16);
  }
  g_sxm.sxm_out_valid_q = (sxm_val && (sxm_op != 0u)) ? 1u : 0u;
  if (sxm_val && (sxm_op != 0u)) {
    std::memcpy(g_sxm.sxm_out_data_q, pre_perm, 16);
  }
  *exp_stream_out_valid_o = g_sxm.sxm_out_valid_q;
  pack_128(g_sxm.sxm_out_data_q, exp_stream_out_data_o);
  pack_128(pre_perm, exp_perm_comb_data_o);
}

extern "C" void dpi_vxm_step(
    uint32_t op_valid_i,
    uint32_t vxm_op_i,
    uint32_t prec_mode_i,
    uint32_t quant_shift_i,
    uint32_t use_accum_32b_i,
    const svBitVecVal* stream_a_i,
    const svBitVecVal* stream_b_i,
    const svBitVecVal* stream_c_i,
    const svBitVecVal* accum_32b_in_i,
    uint32_t* exp_stream_out_valid_o,
    svBitVecVal* exp_stream_out_data_o,
    svBitVecVal* exp_accum_32b_out_o,
    svBitVecVal* exp_vxm_comb_data_o,
    int* exp_reduce_sum_scalar_o,
    int* exp_reduce_max_scalar_o,
    uint32_t* exp_mul_gate_active_o,
    uint32_t* exp_lut_gate_active_o) {
  g_dpi_module_steps++;
  uint8_t a_bytes[16], b_bytes[16], c_bytes[16], comb_bytes[16];
  unpack_128(stream_a_i, a_bytes);
  unpack_128(stream_b_i, b_bytes);
  unpack_128(stream_c_i, c_bytes);
  int32_t in_acc32[16];
  for (int i = 0; i < 16; ++i) in_acc32[i] = static_cast<int32_t>(accum_32b_in_i[i]);

  uint32_t vop       = vxm_op_i & 0xFu;
  bool     vvalid    = (op_valid_i & 1u) != 0u;
  bool     is_mul_op = vvalid && (vop == 2u || vop == 3u || vop == 8u);
  bool     is_lut_op = vvalid && (vop == 4u || vop == 8u || vop == 5u || vop == 7u || vop == 6u);
  *exp_mul_gate_active_o = is_mul_op ? 0u : 1u;
  *exp_lut_gate_active_o = is_lut_op ? 0u : 1u;

  int16_t tree_sum = 0;
  int8_t  tree_max = static_cast<int8_t>(a_bytes[0]);
  for (int i = 0; i < 16; ++i) {
    int8_t ai = static_cast<int8_t>(a_bytes[i]);
    tree_sum = static_cast<int16_t>(tree_sum + ai);
    if (ai > tree_max) tree_max = ai;
  }
  *exp_reduce_sum_scalar_o = static_cast<int>(tree_sum);
  *exp_reduce_max_scalar_o = static_cast<int>(tree_max);
  int32_t out_acc32_comb[16];
  for (int i = 0; i < 16; ++i) {
    int8_t  ai = static_cast<int8_t>(a_bytes[i]);
    int8_t  bi = static_cast<int8_t>(b_bytes[i]);
    int8_t  ci = static_cast<int8_t>(c_bytes[i]);
    int8_t  lut_in   = is_lut_op ? ai : 0;
    int8_t  silu_val = silu_lut_int8_ref(lut_in);
    int8_t  mul_a    = is_mul_op ? ((vop == 8u) ? silu_val : ai) : 0;
    int8_t  mul_b    = is_mul_op ? bi : 0;
    int16_t mul_p    = static_cast<int16_t>(mul_a) * static_cast<int16_t>(mul_b);
    int8_t  out_lane = 0;
    int32_t out_acc  = 0;
    if (vvalid) {
      switch (vop) {
        case 0u:  out_lane = 0; out_acc = in_acc32[i]; break;
        case 1u:  out_acc = static_cast<int32_t>(ai) + static_cast<int32_t>(bi); out_lane = sat_int8_ref(out_acc); break;
        case 10u: out_acc = static_cast<int32_t>(ai) - static_cast<int32_t>(bi); out_lane = sat_int8_ref(out_acc); break;
        case 2u:  out_acc = static_cast<int32_t>(mul_p); out_lane = sat_int8_ref(out_acc); break;
        case 3u:  out_acc = static_cast<int32_t>(mul_p) + ((use_accum_32b_i & 1u) ? in_acc32[i] : static_cast<int32_t>(ci)); out_lane = sat_int8_ref(out_acc); break;
        case 11u: out_lane = (ai >= bi) ? ai : bi; out_acc = static_cast<int32_t>(out_lane); break;
        case 12u: out_lane = (ai <= bi) ? ai : bi; out_acc = static_cast<int32_t>(out_lane); break;
        case 13u: out_lane = relu_int8_ref(ai); out_acc = static_cast<int32_t>(out_lane); break;
        case 4u:  out_lane = silu_val; out_acc = static_cast<int32_t>(out_lane); break;
        case 8u:  out_acc = static_cast<int32_t>(mul_p) >> 6; out_lane = sat_int8_ref(out_acc); break;
        case 5u:  out_lane = gelu_lut_int8_ref(lut_in); out_acc = static_cast<int32_t>(out_lane); break;
        case 7u:  out_lane = exp_lut_int8_ref(lut_in); out_acc = static_cast<int32_t>(out_lane); break;
        case 6u:  out_lane = rsqrt_lut_int8_ref(lut_in); out_acc = static_cast<int32_t>(out_lane); break;
        case 14u: out_acc = static_cast<int32_t>(tree_sum); out_lane = sat_int8_ref(out_acc); break;
        case 15u: out_lane = tree_max; out_acc = static_cast<int32_t>(tree_max); break;
        case 9u:  out_acc = (use_accum_32b_i & 1u) ? in_acc32[i] : static_cast<int32_t>(ai);
                  out_lane = quant_scale_elem_ref(out_acc, quant_shift_i & 0x7u, prec_mode_i & 0xFu);
                  break;
        default:  out_lane = 0; out_acc = 0; break;
      }
    }
    comb_bytes[i]     = static_cast<uint8_t>(out_lane);
    out_acc32_comb[i] = out_acc;
  }
  pack_128(comb_bytes, exp_vxm_comb_data_o);
  g_vxm.vxm_out_valid_q = (vvalid && (vop != 0u)) ? 1u : 0u;
  if (vvalid && (vop != 0u)) {
    std::memcpy(g_vxm.vxm_out_data_q, comb_bytes, 16);
    for (int i = 0; i < 16; ++i) g_vxm.vxm_accum_out_q[i] = out_acc32_comb[i];
  }
  *exp_stream_out_valid_o = g_vxm.vxm_out_valid_q;
  pack_128(g_vxm.vxm_out_data_q, exp_stream_out_data_o);
  for (int i = 0; i < 16; ++i) {
    exp_accum_32b_out_o[i] = static_cast<svBitVecVal>(g_vxm.vxm_accum_out_q[i]);
  }
}

extern "C" void dpi_nim_step(
    uint32_t op_valid_i,
    uint32_t nim_op_i,
    uint32_t realsync_aligned_time_i,
    uint32_t expected_flight_cycles_i,
    uint32_t local_chip_id_i,
    uint32_t tx_dst_chip_i,
    uint32_t ugal_nonminimal_en_i,
    uint32_t link_congested_i,
    uint32_t local_stream_in_valid_i,
    const svBitVecVal* local_stream_in_data_i,
    uint32_t c2c_rx_valid_i,
    const svBitVecVal* c2c_rx_data_i,
    uint32_t c2c_rx_tx_timestamp_i,
    uint32_t c2c_rx_dst_chip_i,
    uint32_t c2c_rx_crc8_i,
    uint32_t* exp_local_stream_out_valid_o,
    svBitVecVal* exp_local_stream_out_data_o,
    uint32_t* exp_c2c_tx_valid_o,
    svBitVecVal* exp_c2c_tx_data_o,
    uint32_t* exp_c2c_tx_timestamp_o,
    uint32_t* exp_c2c_tx_dst_chip_o,
    uint32_t* exp_c2c_tx_crc8_o,
    uint32_t* exp_c2c_tx_port_sel_o,
    uint32_t* exp_deskew_release_valid_o,
    uint32_t* exp_deskew_released_target_cycle_o,
    uint32_t* exp_realsync_ping_ack_o,
    int* exp_measured_skew_o,
    uint32_t* exp_crc_err_o) {
  g_dpi_module_steps++;
  uint8_t loc_in_bytes[16], rx_bytes[16];
  unpack_128(local_stream_in_data_i, loc_in_bytes);
  unpack_128(c2c_rx_data_i, rx_bytes);

  bool     nvalid    = (op_valid_i & 1u) != 0u;
  uint32_t nop       = nim_op_i & 0xFu;
  uint16_t r_time    = static_cast<uint16_t>(realsync_aligned_time_i & 0xFFFFu);
  uint16_t f_cycles  = static_cast<uint16_t>(expected_flight_cycles_i & 0xFFFFu);
  uint8_t  loc_chip  = static_cast<uint8_t>(local_chip_id_i & 0xFu);
  uint8_t  tx_dst    = static_cast<uint8_t>(tx_dst_chip_i & 0xFu);
  bool     ugal_en   = (ugal_nonminimal_en_i & 1u) != 0u;
  bool     congested = (link_congested_i & 1u) != 0u;
  bool     loc_in_v  = (local_stream_in_valid_i & 1u) != 0u;
  bool     rx_v      = (c2c_rx_valid_i & 1u) != 0u;
  uint16_t rx_ts     = static_cast<uint16_t>(c2c_rx_tx_timestamp_i & 0xFFFFu);
  uint8_t  rx_dst    = static_cast<uint8_t>(c2c_rx_dst_chip_i & 0xFu);
  uint8_t  rx_crc    = static_cast<uint8_t>(c2c_rx_crc8_i & 0xFFu);
  bool rx_crc_err = rx_v && (crc8_calc_ref(rx_bytes, rx_ts) != rx_crc);
  *exp_crc_err_o  = rx_crc_err ? 1u : 0u;
  uint16_t incoming_target_cycle = static_cast<uint16_t>(rx_ts + f_cycles);

  bool    pre_slot_match_valid = false;
  uint8_t pre_slot_match_idx   = 0u;
  uint8_t pre_released_data[16] = {0};
  for (int s = 0; s < 4; ++s) {
    if (!pre_slot_match_valid && g_nim.buf_valid[s] && (g_nim.buf_target_cycle[s] == r_time)) {
      pre_slot_match_valid = true;
      pre_slot_match_idx   = static_cast<uint8_t>(s);
      std::memcpy(pre_released_data, g_nim.buf_data[s], 16);
    }
  }

  uint8_t allreduce_sum[16];
  const uint8_t* remote_op = pre_slot_match_valid ? pre_released_data : rx_bytes;
  for (int i = 0; i < 16; ++i) {
    int16_t s = static_cast<int16_t>(static_cast<int8_t>(loc_in_bytes[i])) +
                static_cast<int16_t>(static_cast<int8_t>(remote_op[i]));
    allreduce_sum[i] = static_cast<uint8_t>(sat_int8_ref(s));
  }

  uint32_t loc_out_v = 0u, tx_out_v = 0u, ping_ack = 0u;
  if (pre_slot_match_valid) {
    loc_out_v = 1u;
    std::memcpy(g_nim.nim_local_out_data_q, pre_released_data, 16);
  }

  if (nvalid) {
    switch (nop) {
      case 0u: break;
      case 1u:
        if (loc_in_v) {
          tx_out_v = 1u;
          std::memcpy(g_nim.c2c_tx_data_q, loc_in_bytes, 16);
          g_nim.c2c_tx_ts_q   = r_time;
          g_nim.c2c_tx_dst_q  = tx_dst;
          g_nim.c2c_tx_crc8_q = crc8_calc_ref(loc_in_bytes, r_time);
          g_nim.c2c_tx_port_q = dragonfly_route_ref(loc_chip, tx_dst, ugal_en, congested);
        }
        break;
      case 2u:
        if (pre_slot_match_valid) {
          loc_out_v = 1u;
          std::memcpy(g_nim.nim_local_out_data_q, pre_released_data, 16);
        }
        break;
      case 3u:
      case 6u:
        if (rx_v && !rx_crc_err) {
          ping_ack = 1u;
          g_nim.measured_skew_q = static_cast<int16_t>(static_cast<int16_t>(r_time) - static_cast<int16_t>(incoming_target_cycle));
        }
        break;
      case 4u:
        if (rx_v && !rx_crc_err) {
          tx_out_v = 1u;
          std::memcpy(g_nim.c2c_tx_data_q, rx_bytes, 16);
          g_nim.c2c_tx_ts_q   = r_time;
          g_nim.c2c_tx_dst_q  = rx_dst;
          g_nim.c2c_tx_crc8_q = crc8_calc_ref(rx_bytes, r_time);
          g_nim.c2c_tx_port_q = dragonfly_route_ref(loc_chip, rx_dst, ugal_en, congested);
        }
        break;
      case 5u:
        if (loc_in_v && (pre_slot_match_valid || (rx_v && !rx_crc_err))) {
          loc_out_v = 1u;
          std::memcpy(g_nim.nim_local_out_data_q, allreduce_sum, 16);
          tx_out_v  = 1u;
          std::memcpy(g_nim.c2c_tx_data_q, allreduce_sum, 16);
          g_nim.c2c_tx_ts_q   = r_time;
          g_nim.c2c_tx_dst_q  = tx_dst;
          g_nim.c2c_tx_crc8_q = crc8_calc_ref(allreduce_sum, r_time);
          g_nim.c2c_tx_port_q = dragonfly_route_ref(loc_chip, tx_dst, ugal_en, congested);
        }
        break;
      case 7u:
        if (loc_in_v) {
          loc_out_v = 1u;
          std::memcpy(g_nim.nim_local_out_data_q, loc_in_bytes, 16);
          tx_out_v  = 1u;
          std::memcpy(g_nim.c2c_tx_data_q, loc_in_bytes, 16);
          g_nim.c2c_tx_ts_q   = r_time;
          g_nim.c2c_tx_dst_q  = loc_chip;
          g_nim.c2c_tx_crc8_q = crc8_calc_ref(loc_in_bytes, r_time);
          g_nim.c2c_tx_port_q = 0u;
        }
        break;
      default: break;
    }
  }
  if (pre_slot_match_valid) g_nim.buf_valid[pre_slot_match_idx] = false;
  if (rx_v && !rx_crc_err && !(nvalid && (nop == 4u))) {
    uint8_t wp = g_nim.wr_ptr & 0x3u;
    g_nim.buf_valid[wp]        = true;
    std::memcpy(g_nim.buf_data[wp], rx_bytes, 16);
    g_nim.buf_target_cycle[wp] = incoming_target_cycle;
    g_nim.wr_ptr               = static_cast<uint8_t>((wp + 1u) & 0x3u);
  }
  bool post_match_valid = false;
  uint16_t post_match_target = 0u;
  for (int s = 0; s < 4; ++s) {
    if (!post_match_valid && g_nim.buf_valid[s] && (g_nim.buf_target_cycle[s] == r_time)) {
      post_match_valid  = true;
      post_match_target = g_nim.buf_target_cycle[s];
    }
  }
  *exp_local_stream_out_valid_o         = loc_out_v;
  pack_128(g_nim.nim_local_out_data_q, exp_local_stream_out_data_o);
  *exp_c2c_tx_valid_o                   = tx_out_v;
  pack_128(g_nim.c2c_tx_data_q, exp_c2c_tx_data_o);
  *exp_c2c_tx_timestamp_o               = g_nim.c2c_tx_ts_q;
  *exp_c2c_tx_dst_chip_o                = g_nim.c2c_tx_dst_q;
  *exp_c2c_tx_crc8_o                    = g_nim.c2c_tx_crc8_q;
  *exp_c2c_tx_port_sel_o                = g_nim.c2c_tx_port_q;
  *exp_deskew_release_valid_o           = post_match_valid ? 1u : 0u;
  *exp_deskew_released_target_cycle_o   = post_match_target;
  *exp_realsync_ping_ack_o              = ping_ack;
  *exp_measured_skew_o                  = static_cast<int>(g_nim.measured_skew_q);
}
extern "C" void dpi_dot_step(
    uint32_t valid_i,
    uint32_t mode_i,
    uint32_t zero_skip_en_i,
    uint32_t accum_en_i,
    uint32_t accum_clear_i,
    uint32_t act_scale_e8m0_i,
    uint32_t wt_scale_e8m0_i,
    const svBitVecVal* act_stream_i,
    const svBitVecVal* wt_stream_i,
    uint32_t* exp_valid_o,
    int* exp_unaccum_dot_o,
    int* exp_dot_accum_o,
    uint32_t* exp_dot_fp32_o,
    uint32_t* exp_zero_skip_lanes_o,
    uint32_t* exp_block_zero_skipped_o,
    uint32_t* exp_nan_inf_flag_o) {
  g_dpi_module_steps++;
  uint8_t act_b[16], wt_b[16];
  unpack_128(act_stream_i, act_b);
  unpack_128(wt_stream_i, wt_b);

  uint8_t mode  = static_cast<uint8_t>(mode_i & 0x7u);
  uint8_t zskip = static_cast<uint8_t>(zero_skip_en_i & 1u);
  uint8_t asc   = static_cast<uint8_t>(act_scale_e8m0_i & 0xFFu);
  uint8_t wsc   = static_cast<uint8_t>(wt_scale_e8m0_i & 0xFFu);

  bool block_zero_skip_comb = (mode == 5u)
      ? ((zskip != 0u) && (((asc & 0x7Fu) == 0u) || ((wsc & 0x7Fu) == 0u)))
      : ((asc == 0u) || (wsc == 0u));

  int32_t nvfp4_sum = 0;
  uint8_t zero_cnt32 = 0;
  bool    all32_zero = true;
  for (int k = 0; k < 32; ++k) {
    uint8_t a_nib = static_cast<uint8_t>((act_b[k / 2] >> ((k & 1) * 4)) & 0xFu);
    uint8_t w_nib = static_cast<uint8_t>((wt_b[k / 2]  >> ((k & 1) * 4)) & 0xFu);
    uint8_t a_mag = fn_nvfp4_mag_2x(a_nib & 0x7u);
    uint8_t w_mag = fn_nvfp4_mag_2x(w_nib & 0x7u);
    bool is_z = block_zero_skip_comb || ((a_nib & 0x7u) == 0u) || ((w_nib & 0x7u) == 0u);
    if (is_z) {
      zero_cnt32++;
    } else {
      all32_zero = false;
      int32_t prod = static_cast<int32_t>(a_mag) * static_cast<int32_t>(w_mag);
      uint8_t ps   = ((a_nib >> 3) ^ (w_nib >> 3)) & 1u;
      nvfp4_sum   += (ps ? -prod : prod);
    }
  }
  int32_t nvfp4_s14 = (nvfp4_sum << 18) >> 18;

  int32_t lane16_sum = 0;
  uint8_t zero_cnt16 = 0;
  bool    all16_zero = true;
  bool    any_nan_inf = false;
  for (int i = 0; i < 16; ++i) {
    uint8_t a_byte = act_b[i];
    uint8_t w_byte = wt_b[i];
    uint8_t w_fp4  = static_cast<uint8_t>((wt_b[i / 2] >> ((i & 1) * 4)) & 0xFu);
    bool is_z = false;
    if (mode == 0u)      is_z = block_zero_skip_comb || (a_byte == 0u) || (w_byte == 0u);
    else if (mode == 4u) is_z = block_zero_skip_comb || ((a_byte & 0x7Fu) == 0u) || ((w_fp4 & 0x7u) == 0u);
    else                 is_z = block_zero_skip_comb || ((a_byte & 0x7Fu) == 0u) || ((w_byte & 0x7Fu) == 0u);

    uint8_t a_iso = (zskip && is_z) ? 0u : a_byte;
    uint8_t w_iso = (zskip && is_z) ? 0u : w_byte;
    uint8_t a_s   = (a_iso >> 7) & 1u;
    uint8_t w_s   = (mode == 4u) ? ((w_fp4 >> 3) & 1u) : ((w_iso >> 7) & 1u);
    uint8_t ps    = a_s ^ w_s;

    if (mode == 1u && (((a_byte & 0x7Fu) == 0x7Fu) || ((w_byte & 0x7Fu) == 0x7Fu))) any_nan_inf = true;
    if (mode == 2u && ((((a_byte >> 2) & 0x1Fu) == 0x1Fu) || (((w_byte >> 2) & 0x1Fu) == 0x1Fu))) any_nan_inf = true;
    if (mode == 4u && ((a_byte & 0x7Fu) == 0x7Fu)) any_nan_inf = true;

    if (is_z) {
      zero_cnt16++;
    } else {
      all16_zero = false;
      uint32_t aligned_mag24 = 0u;
      if (mode == 0u) {
        uint8_t ma = a_s ? static_cast<uint8_t>(-a_iso) : a_iso;
        uint8_t mw = w_s ? static_cast<uint8_t>(-w_iso) : w_iso;
        aligned_mag24 = static_cast<uint32_t>(ma) * static_cast<uint32_t>(mw);
      } else if (mode == 1u) {
        uint8_t a_e4  = (a_iso >> 3) & 0xFu, w_e4 = (w_iso >> 3) & 0xFu;
        uint8_t a_ee4 = (a_e4 == 0u) ? 1u : a_e4, w_ee4 = (w_e4 == 0u) ? 1u : w_e4;
        uint8_t a_sg4 = (a_e4 == 0u) ? (a_iso & 0x7u) : (0x8u | (a_iso & 0x7u));
        uint8_t w_sg4 = (w_e4 == 0u) ? (w_iso & 0x7u) : (0x8u | (w_iso & 0x7u));
        uint8_t sh4   = ((a_ee4 >> 1) + (w_ee4 >> 1) + ((a_ee4 & 1u) & (w_ee4 & 1u))) & 0xFu;
        aligned_mag24 = (static_cast<uint32_t>(static_cast<uint8_t>(a_sg4 * w_sg4)) << sh4) & 0xFFFFFFu;
      } else if (mode == 2u) {
        uint8_t a_e5  = (a_iso >> 2) & 0x1Fu, w_e5 = (w_iso >> 2) & 0x1Fu;
        uint8_t a_ee5 = (a_e5 == 0u) ? 1u : a_e5, w_ee5 = (w_e5 == 0u) ? 1u : w_e5;
        uint8_t a_sg5 = (a_e5 == 0u) ? static_cast<uint8_t>((a_iso & 0x3u) << 1) : static_cast<uint8_t>(0x8u | ((a_iso & 0x3u) << 1));
        uint8_t w_sg5 = (w_e5 == 0u) ? static_cast<uint8_t>((w_iso & 0x3u) << 1) : static_cast<uint8_t>(0x8u | ((w_iso & 0x3u) << 1));
        uint8_t sh5   = ((a_ee5 >> 2) + (w_ee5 >> 2) + (((a_ee5 & 0x3u) & (w_ee5 & 0x3u)) ? 1u : 0u)) & 0xFu;
        aligned_mag24 = (static_cast<uint32_t>(static_cast<uint8_t>(a_sg5 * w_sg5)) << sh5) & 0xFFFFFFu;
      } else {
        uint8_t a_e4  = (a_iso >> 3) & 0xFu;
        uint8_t a_ee4 = (a_e4 == 0u) ? 1u : a_e4;
        uint8_t a_sg4 = (a_e4 == 0u) ? (a_iso & 0x7u) : (0x8u | (a_iso & 0x7u));
        uint8_t w_mag = fn_nvfp4_mag_2x(w_fp4 & 0x7u);
        aligned_mag24 = (static_cast<uint32_t>(static_cast<uint8_t>(a_sg4 * w_mag)) << a_ee4) & 0xFFFFFFu;
      }
      lane16_sum += ps ? -static_cast<int32_t>(aligned_mag24) : static_cast<int32_t>(aligned_mag24);
    }
  }
  uint8_t act_m4 = (((asc >> 3) & 0xFu) == 0u) ? (asc & 0x7u) : (0x8u | (asc & 0x7u));
  uint8_t wt_m4  = (((wsc >> 3) & 0xFu) == 0u) ? (wsc & 0x7u) : (0x8u | (wsc & 0x7u));
  int32_t nvfp4_e4m3_scaled_comb = (nvfp4_s14 * static_cast<int32_t>((act_m4 * wt_m4) & 0xFu)) >> 6;

  uint8_t zero_skip_lanes_comb = (mode == 3u || mode == 5u) ? zero_cnt32 : zero_cnt16;
  uint8_t nan_inf_comb         = (mode == 3u || mode == 0u) ? 0u :
                                 ((mode == 5u) ? ((((asc & 0x7Fu) == 0x7Fu) || ((wsc & 0x7Fu) == 0x7Fu)) ? 1u : 0u) :
                                                 (any_nan_inf ? 1u : 0u));
  int32_t tree_sum_comb        = block_zero_skip_comb ? 0 :
                                 ((mode == 3u) ? (all32_zero ? 0 : nvfp4_s14) :
                                 ((mode == 5u) ? (all32_zero ? 0 : nvfp4_e4m3_scaled_comb) :
                                                 (all16_zero ? 0 : lane16_sum)));

  uint32_t s1_u      = static_cast<uint32_t>(g_dot.s1_tree_sum_q);
  uint32_t s2_sign   = (s1_u >> 31) & 1u;
  uint32_t s2_abs    = s2_sign ? (~s1_u + 1u) : s1_u;
  uint32_t scale_sum = static_cast<uint32_t>(g_dot.s1_act_scale_q) + static_cast<uint32_t>(g_dot.s1_wt_scale_q);

  uint64_t shifted_mag = 0ULL;
  if (scale_sum >= 254u) {
    uint32_t diff_pos = scale_sum - 254u;
    uint32_t lsh      = (diff_pos > 7u) ? 7u : diff_pos;
    shifted_mag       = (static_cast<uint64_t>(s2_abs) << lsh) & 0x7FFFFFFFFFULL;
  } else {
    uint32_t diff_neg = 254u - scale_sum;
    uint32_t rsh      = (diff_neg > 7u) ? 7u : diff_neg;
    shifted_mag       = static_cast<uint64_t>(s2_abs >> rsh);
  }

  int32_t s2_unaccum = 0;
  if (!g_dot.s1_block_zero_skip_q && (g_dot.s1_tree_sum_q != 0) && (shifted_mag != 0ULL)) {
    uint32_t sat_mag = ((shifted_mag >> 31) != 0ULL) ? 0x7FFFFFFFu : static_cast<uint32_t>(shifted_mag & 0x7FFFFFFFu);
    s2_unaccum = s2_sign ? -static_cast<int32_t>(sat_mag) : static_cast<int32_t>(sat_mag);
  }

  int32_t base_acc = g_dot.s1_accum_clear_q ? 0 : g_dot.dot_accum_q;
  int64_t acc_ext  = static_cast<int64_t>(base_acc) + static_cast<int64_t>(s2_unaccum);
  int32_t s2_accum = 0;
  if (!g_dot.s1_accum_en_q)       s2_accum = g_dot.s1_accum_clear_q ? 0 : s2_unaccum;
  else if (acc_ext > 2147483647LL) s2_accum = 2147483647;
  else if (acc_ext < -2147483648LL) s2_accum = -2147483647;
  else                             s2_accum = static_cast<int32_t>(acc_ext);

  uint32_t msb_idx = 0u;
  for (int b = 0; b < 31; ++b) {
    if ((s2_abs >> b) & 1u) msb_idx = static_cast<uint32_t>(b);
  }
  uint32_t norm_shift    = s2_abs << (31u - msb_idx);
  uint32_t fp32_exp_wide = (scale_sum + msb_idx - 127u) & 0x3FFu;
  uint32_t s2_fp32       = 0u;
  if (g_dot.s1_nan_inf_q)                                      s2_fp32 = 0x7FC00000u;
  else if (g_dot.s1_block_zero_skip_q || (s2_abs == 0u))       s2_fp32 = 0x00000000u;
  else if (((fp32_exp_wide >> 9) & 1u) || (fp32_exp_wide == 0u)) s2_fp32 = (s2_sign << 31);
  else if (fp32_exp_wide >= 255u)                              s2_fp32 = (s2_sign << 31) | 0x7F800000u;
  else                                                         s2_fp32 = (s2_sign << 31) | ((fp32_exp_wide & 0xFFu) << 23) | ((norm_shift >> 8) & 0x7FFFFFu);

  g_dot.valid_q              = g_dot.s1_valid_q;
  g_dot.unaccum_dot_q        = s2_unaccum;
  g_dot.dot_accum_q          = s2_accum;
  g_dot.dot_fp32_q           = s2_fp32;
  g_dot.zero_skip_lanes_q    = g_dot.s1_zero_skip_lanes_q;
  g_dot.block_zero_skipped_q = g_dot.s1_block_zero_skip_q;
  g_dot.nan_inf_flag_q       = g_dot.s1_nan_inf_q;

  g_dot.s1_valid_q           = static_cast<uint8_t>(valid_i & 1u);
  g_dot.s1_accum_en_q        = static_cast<uint8_t>(accum_en_i & 1u);
  g_dot.s1_accum_clear_q     = static_cast<uint8_t>(accum_clear_i & 1u);
  g_dot.s1_act_scale_q       = (mode == 5u) ? static_cast<uint8_t>(120u + ((asc >> 3) & 0xFu)) : asc;
  g_dot.s1_wt_scale_q        = (mode == 5u) ? static_cast<uint8_t>(120u + ((wsc >> 3) & 0xFu)) : wsc;
  g_dot.s1_tree_sum_q        = tree_sum_comb;
  g_dot.s1_zero_skip_lanes_q = zero_skip_lanes_comb;
  g_dot.s1_block_zero_skip_q = block_zero_skip_comb ? 1u : 0u;
  g_dot.s1_nan_inf_q         = nan_inf_comb;

  *exp_valid_o              = g_dot.valid_q;
  *exp_unaccum_dot_o        = g_dot.unaccum_dot_q;
  *exp_dot_accum_o          = g_dot.dot_accum_q;
  *exp_dot_fp32_o           = g_dot.dot_fp32_q;
  *exp_zero_skip_lanes_o    = g_dot.zero_skip_lanes_q;
  *exp_block_zero_skipped_o = g_dot.block_zero_skipped_q;
  *exp_nan_inf_flag_o       = g_dot.nan_inf_flag_q;
}
extern "C" void dpi_kvq_step(
    uint32_t valid_i,
    uint32_t quant_mode_i,
    const svBitVecVal* kv_in_lo_i,
    const svBitVecVal* kv_in_hi_i,
    uint32_t target_sram_bank_i,
    uint32_t target_sram_addr_i,
    uint32_t* exp_valid_o,
    svBitVecVal* exp_quant_vec_o,
    uint32_t* exp_scale_e8m0_o,
    uint32_t* exp_sram_wr_en_o,
    uint32_t* exp_sram_wr_bank_o,
    uint32_t* exp_sram_wr_addr_o,
    uint32_t* exp_zero_lanes_cnt_o,
    uint32_t* exp_nan_inf_clamped_o,
    uint32_t* exp_compression_ratio_code_o) {
  g_dpi_module_steps++;
  uint8_t lo_b[16], hi_b[16];
  unpack_128(kv_in_lo_i, lo_b);
  unpack_128(kv_in_hi_i, hi_b);

  uint8_t qmode = static_cast<uint8_t>(quant_mode_i & 0x3u);
  uint8_t sign_c[16], exp8_c[16], frac7_c[16];
  bool    is_zero_c[16], is_nan_inf_c[16], is_finite_nz_c[16];
  bool    any_finite_nz = false;
  bool    any_nan_inf   = false;
  uint8_t max_finite_exp = 0u;

  for (int i = 0; i < 16; ++i) {
    const uint8_t* src = (i < 8) ? &lo_b[2 * i] : &hi_b[2 * (i - 8)];
    uint16_t raw16 = static_cast<uint16_t>(src[0]) | (static_cast<uint16_t>(src[1]) << 8);
    sign_c[i] = static_cast<uint8_t>((raw16 >> 15) & 1u);
    if (qmode == 1u) {
      uint8_t exp5 = static_cast<uint8_t>((raw16 >> 10) & 0x1Fu);
      exp8_c[i]  = (exp5 == 0u) ? 0u : ((exp5 == 31u) ? 255u : static_cast<uint8_t>(exp5 + 112u));
      frac7_c[i] = static_cast<uint8_t>((raw16 >> 3) & 0x7Fu);
    } else {
      exp8_c[i]  = static_cast<uint8_t>((raw16 >> 7) & 0xFFu);
      frac7_c[i] = static_cast<uint8_t>(raw16 & 0x7Fu);
    }
    is_zero_c[i]      = (exp8_c[i] == 0u);
    is_nan_inf_c[i]   = (exp8_c[i] == 255u);
    is_finite_nz_c[i] = (exp8_c[i] != 0u) && (exp8_c[i] != 255u);
    if (is_nan_inf_c[i]) any_nan_inf = true;
    if (is_finite_nz_c[i]) {
      any_finite_nz = true;
      if (exp8_c[i] > max_finite_exp) max_finite_exp = exp8_c[i];
    }
  }

  uint8_t e_max_c = any_finite_nz ? max_finite_exp : 127u;
  uint8_t scale_e8m0_c = 127u;
  if (qmode == 0u || qmode == 1u) scale_e8m0_c = (e_max_c > 7u) ? static_cast<uint8_t>(e_max_c - 7u) : 0u;
  else if (qmode == 2u)           scale_e8m0_c = (e_max_c > 2u) ? static_cast<uint8_t>(e_max_c - 2u) : 0u;

  uint8_t mxfp8_pack[16], nvfp4_pack[16];
  std::memset(nvfp4_pack, 0, 16);
  uint8_t zero_cnt = 0u;
  for (int i = 0; i < 16; ++i) {
    if (is_zero_c[i]) zero_cnt++;
    uint8_t rel_exp = static_cast<uint8_t>(exp8_c[i] - scale_e8m0_c);
    uint8_t mx = 0u;
    if (is_zero_c[i] || (exp8_c[i] <= scale_e8m0_c)) mx = static_cast<uint8_t>(sign_c[i] << 7);
    else if (is_nan_inf_c[i] || (rel_exp >= 14u))    mx = static_cast<uint8_t>((sign_c[i] << 7) | 0x77u);
    else                                             mx = static_cast<uint8_t>((sign_c[i] << 7) | ((rel_exp & 0xFu) << 3) | ((frac7_c[i] >> 4) & 0x7u));
    mxfp8_pack[i] = mx;

    uint8_t nv = 0u;
    if (is_zero_c[i] || (exp8_c[i] <= scale_e8m0_c)) nv = static_cast<uint8_t>(sign_c[i] << 3);
    else if (is_nan_inf_c[i] || (rel_exp >= 3u))     nv = static_cast<uint8_t>((sign_c[i] << 3) | 0x7u);
    else                                             nv = static_cast<uint8_t>((sign_c[i] << 3) | ((rel_exp & 0x3u) << 1) | ((frac7_c[i] >> 6) & 0x1u));
    nvfp4_pack[i / 2] |= static_cast<uint8_t>((nv & 0xFu) << ((i & 1) * 4));
  }
  for (int b = 0; b < 8; ++b) nvfp4_pack[b + 8] = nvfp4_pack[b];

  g_kvq.valid_q          = static_cast<uint8_t>(valid_i & 1u);
  g_kvq.scale_e8m0_q     = scale_e8m0_c;
  g_kvq.sram_wr_en_q     = static_cast<uint8_t>(valid_i & 1u);
  g_kvq.sram_wr_bank_q   = static_cast<uint8_t>(target_sram_bank_i & 0x3u);
  g_kvq.sram_wr_addr_q   = static_cast<uint16_t>(target_sram_addr_i & 0xFFFFu);
  g_kvq.zero_lanes_cnt_q = zero_cnt;
  if (qmode == 0u || qmode == 1u) {
    std::memcpy(g_kvq.quant_vec_q, mxfp8_pack, 16);
    g_kvq.nan_inf_clamped_q = any_nan_inf ? 1u : 0u;
    g_kvq.comp_ratio_q      = 2u;
  } else if (qmode == 2u) {
    std::memcpy(g_kvq.quant_vec_q, nvfp4_pack, 16);
    g_kvq.nan_inf_clamped_q = any_nan_inf ? 1u : 0u;
    g_kvq.comp_ratio_q      = 3u;
  } else {
    std::memcpy(g_kvq.quant_vec_q, lo_b, 16);
    g_kvq.nan_inf_clamped_q = 0u;
    g_kvq.comp_ratio_q      = 1u;
  }

  *exp_valid_o                  = g_kvq.valid_q;
  pack_128(g_kvq.quant_vec_q, exp_quant_vec_o);
  *exp_scale_e8m0_o             = g_kvq.scale_e8m0_q;
  *exp_sram_wr_en_o             = g_kvq.sram_wr_en_q;
  *exp_sram_wr_bank_o           = g_kvq.sram_wr_bank_q;
  *exp_sram_wr_addr_o           = g_kvq.sram_wr_addr_q;
  *exp_zero_lanes_cnt_o         = g_kvq.zero_lanes_cnt_q;
  *exp_nan_inf_clamped_o        = g_kvq.nan_inf_clamped_q;
  *exp_compression_ratio_code_o = g_kvq.comp_ratio_q;
}
extern "C" void dpi_spec_step(
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
  g_dpi_module_steps++;
  uint8_t b_val[16], b_tok[16];
  unpack_128(logits_i, b_val);
  unpack_128(token_ids_i, b_tok);

  for (int gs = 0; gs < 10; ++gs) {
    int lk = (gs == 0) ? 2 : (gs < 3) ? 4 : (gs < 6) ? 8 : 16;
    int lj = (gs == 0 || gs == 2 || gs == 5 || gs == 9) ? 1 :
             (gs == 1 || gs == 4 || gs == 8) ? 2 :
             (gs == 3 || gs == 7) ? 4 : 8;
    uint8_t next_val[16], next_tok[16];
    for (int gi = 0; gi < 16; ++gi) {
      int  ixj      = gi ^ lj;
      bool dir_desc = ((gi & lk) == 0);
      if (ixj > gi) {
        int8_t  va   = static_cast<int8_t>(b_val[gi]);
        uint8_t ta   = b_tok[gi];
        int8_t  vb   = static_cast<int8_t>(b_val[ixj]);
        uint8_t tb   = b_tok[ixj];
        bool    swap = dir_desc ? (va < vb) : (va > vb);
        next_val[gi]  = swap ? static_cast<uint8_t>(vb) : static_cast<uint8_t>(va);
        next_tok[gi]  = swap ? tb : ta;
        next_val[ixj] = swap ? static_cast<uint8_t>(va) : static_cast<uint8_t>(vb);
        next_tok[ixj] = swap ? ta : tb;
      }
    }
    std::memcpy(b_val, next_val, 16);
    std::memcpy(b_tok, next_tok, 16);
  }

  uint32_t s_tmp = g_spec.prng_state_q ^ (g_spec.prng_state_q << 13);
  s_tmp ^= (s_tmp >> 17);
  s_tmp ^= (s_tmp << 5);
  uint32_t prng_state_next = (s_tmp == 0u) ? 0x9E3779B9u : s_tmp;

  uint16_t cum_weight[16];
  uint16_t nucleus_mask_comb       = 0x0001u;
  uint16_t total_nucleus_mass_comb = 0u;
  uint16_t run_cum                 = 0u;
  uint8_t  inv_t                   = static_cast<uint8_t>(inv_temp_i & 0xFFu);
  uint8_t  top_k                   = static_cast<uint8_t>(top_k_i & 0xFu);
  uint16_t top_p                   = static_cast<uint16_t>(top_p_thresh_i & 0xFFFFu);

  for (int r = 0; r < 16; ++r) {
    int16_t  diff_s      = static_cast<int16_t>(static_cast<int8_t>(b_val[0])) -
                           static_cast<int16_t>(static_cast<int8_t>(b_val[r]));
    uint16_t diff_pos    = static_cast<uint16_t>(diff_s);
    uint16_t scaled_drop = static_cast<uint16_t>((diff_pos * static_cast<uint16_t>(inv_t)) & 0xFFFFu);
    uint16_t w_r         = (scaled_drop >= 255u) ? 1u : static_cast<uint16_t>(256u - scaled_drop);
    uint16_t c_r         = static_cast<uint16_t>((run_cum + w_r) & 0xFFFFu);
    cum_weight[r]        = c_r;
    bool topk_ok         = (top_k == 0u) ? true : (r < static_cast<int>(top_k));
    bool topp_ok         = (r == 0) ? true : (run_cum < top_p);
    bool m_r             = (r == 0) ? true : (topk_ok && topp_ok);
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
    bool     loc_acc = (p_d >= q_d) || (lhs_p >= rhs_uq);
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

  uint8_t  total_emitted = static_cast<uint8_t>((best_depth + 1u) & 0x7u);
  uint8_t  anc0 = best_leaf_idx & 0x7u;
  uint8_t  anc1 = static_cast<uint8_t>((tree_parent_idx_i >> (3 * anc0)) & 0x7u);
  uint8_t  anc2 = static_cast<uint8_t>((tree_parent_idx_i >> (3 * anc1)) & 0x7u);
  uint8_t  anc3 = static_cast<uint8_t>((tree_parent_idx_i >> (3 * anc2)) & 0x7u);
  uint64_t t0   = (tree_draft_tok_i >> (8 * anc0)) & 0xFFULL;
  uint64_t t1   = (tree_draft_tok_i >> (8 * anc1)) & 0xFFULL;
  uint64_t t2   = (tree_draft_tok_i >> (8 * anc2)) & 0xFFULL;
  uint64_t t3   = (tree_draft_tok_i >> (8 * anc3)) & 0xFFULL;
  uint64_t btok = bonus_tok_i & 0xFFULL;
  uint64_t committed_tokens_comb = 0ULL;
  switch (best_depth) {
    case 1u: committed_tokens_comb = (btok << 8)  | t0; break;
    case 2u: committed_tokens_comb = (btok << 16) | (t0 << 8)  | t1; break;
    case 3u: committed_tokens_comb = (btok << 24) | (t0 << 16) | (t1 << 8)  | t2; break;
    default: committed_tokens_comb = (btok << 32) | (t0 << 24) | (t1 << 16) | (t2 << 8) | t3; break;
  }

  uint8_t selected_token_comb = 0u, selected_logit_comb = 0u;
  switch (op_mode_i & 0x3u) {
    case 0u: selected_logit_comb = b_val[0];            selected_token_comb = b_tok[0]; break;
    case 1u: selected_logit_comb = b_val[sampled_rank]; selected_token_comb = b_tok[sampled_rank]; break;
    case 2u: selected_logit_comb = best_prob;           selected_token_comb = static_cast<uint8_t>((tree_draft_tok_i >> (8 * best_leaf_idx)) & 0xFFULL); break;
    default: selected_logit_comb = b_val[0];            selected_token_comb = b_tok[0]; break;
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
    if ((rng_seed_step_i & 1u) != 0u) g_spec.prng_state_q = prng_state_next;
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
