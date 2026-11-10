// =============================================================================
// File: uvm_tb/uvm_mxm_sxm/dpi_mxm_sxm_ref.cpp
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Cycle-Accurate Bit-Exact C++17 DPI-C Reference Model for
//              groq_mxm_slice and groq_sxm_slice under Accellera UVM 2020.3.1.
// =============================================================================
#include <cstdint>
#include <cstring>
#include "svdpi.h"

namespace {

struct MxmSxmRefState {
  // MXM state
  uint8_t  weight_buf_bank0[16][16];
  uint8_t  weight_buf_bank1[16][16];
  uint8_t  active_bank_q;
  uint8_t  exec_en_s1;
  uint8_t  clear_s1;
  uint8_t  preload_s1;
  int32_t  mac_delta_s1[16];
  int32_t  preload_vec_s1[16];
  int32_t  accum_q[16];
  uint8_t  mxm_out_valid_q;

  // SXM state
  uint8_t  transpose_buf[16][16];
  uint8_t  sxm_out_valid_q;
  uint8_t  sxm_out_data_q[16];

  // Telemetry
  uint32_t dpi_calls;
  int      sim_status;
};

static MxmSxmRefState g_state;

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

static inline int32_t elem_mul_ref(uint8_t a_byte, uint8_t w_byte, uint8_t mode) {
  if (a_byte == 0u || w_byte == 0u) {
    return 0;
  }
  if (mode == 1u || mode == 2u) { // PREC_FP8_E4M3 or PREC_FP8_E5M2
    if (((a_byte & 0x7Fu) == 0u) || ((w_byte & 0x7Fu) == 0u)) {
      return 0;
    }
    uint32_t fp8_sign     = ((a_byte >> 7) & 1u) ^ ((w_byte >> 7) & 1u);
    uint32_t fp8_exp_a    = (a_byte >> 3) & 0xFu;
    uint32_t fp8_exp_w    = (w_byte >> 3) & 0xFu;
    uint32_t fp8_man_a    = (fp8_exp_a == 0u) ? (a_byte & 0x7u) : (0x8u | (a_byte & 0x7u));
    uint32_t fp8_man_w    = (fp8_exp_w == 0u) ? (w_byte & 0x7u) : (0x8u | (w_byte & 0x7u));
    uint32_t fp8_man_prod = fp8_man_a * fp8_man_w;
    uint32_t fp8_exp_sum  = fp8_exp_a + fp8_exp_w;
    uint32_t fp8_scaled   = (fp8_man_prod << fp8_exp_sum) >> 10;
    return fp8_sign ? -static_cast<int32_t>(fp8_scaled) : static_cast<int32_t>(fp8_scaled);
  }
  int8_t sa = static_cast<int8_t>(a_byte);
  int8_t sw = static_cast<int8_t>(w_byte);
  return static_cast<int32_t>(sa) * static_cast<int32_t>(sw);
}

} // namespace

extern "C" void dpi_mxm_sxm_reset() {
  std::memset(&g_state, 0, sizeof(g_state));
  g_state.sim_status = 1;
}

extern "C" uint32_t dpi_get_calls() {
  return g_state.dpi_calls;
}

extern "C" void dpi_set_status(int status) {
  g_state.sim_status = status;
}

extern "C" int dpi_get_status() {
  return g_state.sim_status;
}

extern "C" void dpi_mxm_sxm_step(
    uint32_t mxm_op_i,
    uint32_t prec_mode_i,
    uint32_t weight_row_idx_i,
    uint32_t act_zero_gate_en_i,
    uint32_t accum_clear_i,
    uint32_t accum_preload_en_i,
    uint32_t bg_wt_load_en_i,
    uint32_t bg_wt_row_idx_i,
    const svBitVecVal* bg_wt_data_i,
    uint32_t stream_act_valid_i,
    const svBitVecVal* stream_act_data_i,
    uint32_t stream_wt_valid_i,
    const svBitVecVal* stream_wt_data_i,
    const svBitVecVal* accum_preload_data_i,
    uint32_t sxm_op_i,
    uint32_t shift_amt_i,
    uint32_t src_lane_i,
    uint32_t butterfly_mask_i,
    uint32_t transpose_idx_i,
    uint32_t rope_neg_even_en_i,
    uint32_t sxm_in_valid_i,
    const svBitVecVal* sxm_in_data_i,
    uint32_t* exp_mxm_active_bank,
    uint32_t* exp_zero_skip_mask,
    uint32_t* exp_zero_skip_count,
    uint32_t* exp_mxm_out_valid,
    svBitVecVal* exp_mxm_stream_out,
    svBitVecVal* exp_mxm_accum_vec,
    uint32_t* exp_sxm_out_valid,
    svBitVecVal* exp_sxm_out_data,
    svBitVecVal* exp_sxm_perm_comb) {
  g_state.dpi_calls++;

  uint8_t act_raw[16], wt_in[16], bg_wt[16], sxm_in[16];
  unpack_128(stream_act_data_i, act_raw);
  unpack_128(stream_wt_data_i, wt_in);
  unpack_128(bg_wt_data_i, bg_wt);
  unpack_128(sxm_in_data_i, sxm_in);

  uint8_t mode = static_cast<uint8_t>(prec_mode_i & 0xFu);
  uint8_t mxm_op = static_cast<uint8_t>(mxm_op_i & 0xFu);
  bool gate_en = (act_zero_gate_en_i & 1u) != 0u;

  // 1. Pre-posedge MXM zero-skip & operand isolation
  uint32_t zmask = 0u;
  uint32_t zcnt  = 0u;
  uint8_t iso_act[16];
  uint8_t iso_wt[16][16];
  for (int r = 0; r < 16; ++r) {
    bool is_zero = false;
    if (mode == 3u || mode == 4u) {
      int base = 2 * (r / 2);
      is_zero = (act_raw[base] == 0u) && (act_raw[base + 1] == 0u);
    } else {
      is_zero = (act_raw[r] == 0u) ||
                (((mode == 1u) || (mode == 2u)) && ((act_raw[r] & 0x7Fu) == 0u));
    }
    bool gated = gate_en && is_zero;
    if (gated) {
      zmask |= (1u << r);
      zcnt++;
      iso_act[r] = 0u;
      for (int c = 0; c < 16; ++c) iso_wt[r][c] = 0u;
    } else {
      iso_act[r] = act_raw[r];
      for (int c = 0; c < 16; ++c) {
        iso_wt[r][c] = g_state.active_bank_q ? g_state.weight_buf_bank1[r][c]
                                             : g_state.weight_buf_bank0[r][c];
      }
    }
  }

  // 2. Pre-posedge MXM 16x16 wavefront contraction
  int32_t mac_delta_comb[16];
  for (int c = 0; c < 16; ++c) {
    int32_t sum = 0;
    if (mode == 3u || mode == 4u) {
      for (int k = 0; k < 8; ++k) {
        int16_t a16 = static_cast<int16_t>(static_cast<uint16_t>(iso_act[2 * k]) |
                      (static_cast<uint16_t>(iso_act[2 * k + 1]) << 8));
        int16_t w16 = static_cast<int16_t>(static_cast<uint16_t>(iso_wt[2 * k][c]) |
                      (static_cast<uint16_t>(iso_wt[2 * k + 1][c]) << 8));
        int32_t prod = static_cast<int32_t>(a16) * static_cast<int32_t>(w16);
        sum = static_cast<int32_t>(static_cast<uint32_t>(sum) + static_cast<uint32_t>(prod >> 8));
      }
    } else {
      for (int r = 0; r < 16; ++r) {
        int32_t p = elem_mul_ref(iso_act[r], iso_wt[r][c], mode);
        sum = static_cast<int32_t>(static_cast<uint32_t>(sum) + static_cast<uint32_t>(p));
      }
    }
    mac_delta_comb[c] = sum;
  }

  // 3. MXM sequential update at posedge clk (Stage 2 from old Stage 1, then Stage 1, then banks)
  bool exec_en     = (mxm_op == 4u) && ((stream_act_valid_i & 1u) != 0u);
  bool clear_cmd   = ((accum_clear_i & 1u) != 0u) || (mxm_op == 6u);
  bool preload_cmd = ((accum_preload_en_i & 1u) != 0u) || (mxm_op == 7u);

  g_state.mxm_out_valid_q = g_state.exec_en_s1;
  for (int c = 0; c < 16; ++c) {
    if (g_state.clear_s1) {
      g_state.accum_q[c] = 0;
    } else if (g_state.preload_s1) {
      g_state.accum_q[c] = g_state.preload_vec_s1[c];
    } else if (g_state.exec_en_s1) {
      g_state.accum_q[c] = static_cast<int32_t>(
          static_cast<uint32_t>(g_state.accum_q[c]) +
          static_cast<uint32_t>(g_state.mac_delta_s1[c]));
    }
  }

  g_state.exec_en_s1 = exec_en ? 1u : 0u;
  g_state.clear_s1   = clear_cmd ? 1u : 0u;
  g_state.preload_s1 = preload_cmd ? 1u : 0u;
  for (int c = 0; c < 16; ++c) {
    g_state.mac_delta_s1[c]   = exec_en ? mac_delta_comb[c] : 0;
    g_state.preload_vec_s1[c] = static_cast<int32_t>(accum_preload_data_i[c]);
  }

  const uint8_t* wt_load_vec = ((stream_wt_valid_i & 1u) != 0u) ? wt_in : act_raw;
  bool load_b0 = (mxm_op == 1u);
  bool load_b1 = (mxm_op == 2u);
  uint8_t b0_row = static_cast<uint8_t>(weight_row_idx_i & 0xFu);
  uint8_t b1_row = static_cast<uint8_t>(weight_row_idx_i & 0xFu);
  const uint8_t* b0_src = wt_load_vec;
  const uint8_t* b1_src = wt_load_vec;

  if ((bg_wt_load_en_i & 1u) != 0u) {
    if (g_state.active_bank_q == 1u) {
      load_b0 = true;
      b0_row  = static_cast<uint8_t>(bg_wt_row_idx_i & 0xFu);
      b0_src  = bg_wt;
    } else {
      load_b1 = true;
      b1_row  = static_cast<uint8_t>(bg_wt_row_idx_i & 0xFu);
      b1_src  = bg_wt;
    }
  }

  if (mxm_op == 3u) {
    g_state.active_bank_q ^= 1u;
  }
  if (load_b0) {
    std::memcpy(g_state.weight_buf_bank0[b0_row], b0_src, 16);
  }
  if (load_b1) {
    std::memcpy(g_state.weight_buf_bank1[b1_row], b1_src, 16);
  }

  // 4. SXM pre-posedge combinational permutation & post-posedge sequential update
  uint8_t sxm_op   = static_cast<uint8_t>(sxm_op_i & 0xFu);
  uint8_t shamt    = static_cast<uint8_t>(shift_amt_i & 0xFu);
  uint8_t bcast    = static_cast<uint8_t>(src_lane_i & 0xFu);
  uint8_t bfly     = static_cast<uint8_t>(butterfly_mask_i & 0xFu);
  uint8_t tidx     = static_cast<uint8_t>(transpose_idx_i & 0xFu);
  bool    rope_neg = (rope_neg_even_en_i & 1u) != 0u;
  bool    sxm_val  = (sxm_in_valid_i & 1u) != 0u;

  uint8_t pre_perm[16];
  for (int i = 0; i < 16; ++i) {
    if (sxm_op == 11u) { // SXM_TRANSPOSE_READ
      pre_perm[i] = g_state.transpose_buf[i][tidx];
    } else {
      uint8_t idx_rot_l  = static_cast<uint8_t>((i - shamt) & 0xFu);
      uint8_t idx_rot_r  = static_cast<uint8_t>((i + shamt) & 0xFu);
      uint8_t idx_bitrev = static_cast<uint8_t>(((i & 1) << 3) | ((i & 2) << 1) |
                                                ((i & 4) >> 1) | ((i & 8) >> 3));
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

  if (sxm_op == 10u && sxm_val) { // SXM_TRANSPOSE_LOAD
    std::memcpy(g_state.transpose_buf[tidx], sxm_in, 16);
  }
  g_state.sxm_out_valid_q = (sxm_val && (sxm_op != 0u)) ? 1u : 0u;
  if (sxm_val && (sxm_op != 0u)) {
    std::memcpy(g_state.sxm_out_data_q, pre_perm, 16);
  }

  // Post-posedge combinational perm_comb_data_o (same as pre_perm since SXM_TRANSPOSE_LOAD != SXM_TRANSPOSE_READ)
  *exp_mxm_active_bank = g_state.active_bank_q;
  *exp_zero_skip_mask  = zmask;
  *exp_zero_skip_count = zcnt;
  *exp_mxm_out_valid   = g_state.mxm_out_valid_q;

  uint8_t mxm_stream_bytes[16];
  for (int c = 0; c < 16; ++c) {
    exp_mxm_accum_vec[c] = static_cast<svBitVecVal>(g_state.accum_q[c]);
    mxm_stream_bytes[c]  = static_cast<uint8_t>(g_state.accum_q[c] & 0xFF);
  }
  pack_128(mxm_stream_bytes, exp_mxm_stream_out);

  *exp_sxm_out_valid = g_state.sxm_out_valid_q;
  pack_128(g_state.sxm_out_data_q, exp_sxm_out_data);
  pack_128(pre_perm, exp_sxm_perm_comb);
}
