// =============================================================================
// File: uvm_tb/uvm_vxm_nim/dpi_vxm_nim_ref.cpp
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Cycle-Accurate Bit-Exact C++17 DPI-C Reference Model for
//              groq_vxm_slice and groq_nim_realsync under Accellera UVM 2020.3.1.
// =============================================================================
#include <cstdint>
#include <cstring>
#include "svdpi.h"

namespace {

struct VxmNimRefState {
  // NIM elastic deskew buffer state (4 slots)
  bool     buf_valid[4];
  uint8_t  buf_data[4][16];
  uint16_t buf_target_cycle[4];
  uint8_t  wr_ptr;
  uint8_t  vxm_out_data_q[16];
  int32_t  vxm_accum_out_q[16];
  uint8_t  nim_local_out_data_q[16];
  uint8_t  c2c_tx_data_q[16];
  uint16_t c2c_tx_ts_q;
  uint8_t  c2c_tx_dst_q;
  uint8_t  c2c_tx_crc8_q;
  uint8_t  c2c_tx_port_q;
  int16_t  measured_skew_q;

  // Telemetry
  uint32_t dpi_calls;
  int      sim_status;
};

static VxmNimRefState g_state;

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

static inline int8_t relu_int8_ref(int8_t x) {
  return (x <= 0) ? 0 : x;
}

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
  int8_t q_int8 = sat_int8_ref(rounded);
  if (pmode == 1u) { // PREC_FP8_E4M3
    if (q_int8 == 127)     return 126;
    if (q_int8 == -1)      return -2;
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
  for (int i = 0; i < 16; ++i) {
    crc = crc8_byte_step_ref(crc, payload[i]);
  }
  crc = crc8_byte_step_ref(crc, static_cast<uint8_t>(ts & 0xFFu));
  crc = crc8_byte_step_ref(crc, static_cast<uint8_t>((ts >> 8) & 0xFFu));
  return crc;
}

static inline uint8_t dragonfly_route_ref(uint8_t src_chip, uint8_t dst_chip, bool ugal_en, bool congested) {
  if (ugal_en && congested && (src_chip != dst_chip)) return 2u; // PORT_UGAL_PROXY
  if (((src_chip >> 2) & 0x3u) != ((dst_chip >> 2) & 0x3u)) return 1u; // PORT_GLOBAL_MIN
  return 0u; // PORT_LOCAL_MIN
}

} // namespace

extern "C" void dpi_vxm_nim_reset() {
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

extern "C" void dpi_vxm_nim_step(
    uint32_t vxm_op_valid_i,
    uint32_t vxm_op_i,
    uint32_t prec_mode_i,
    uint32_t quant_shift_i,
    uint32_t use_accum_32b_i,
    const svBitVecVal* stream_a_i,
    const svBitVecVal* stream_b_i,
    const svBitVecVal* stream_c_i,
    const svBitVecVal* accum_32b_in_i,
    uint32_t nim_op_valid_i,
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
    uint32_t* exp_vxm_out_valid,
    svBitVecVal* exp_vxm_out_data,
    svBitVecVal* exp_vxm_accum_out,
    svBitVecVal* exp_vxm_comb_data,
    int* exp_vxm_reduce_sum,
    int* exp_vxm_reduce_max,
    uint32_t* exp_vxm_mul_gate,
    uint32_t* exp_vxm_lut_gate,
    uint32_t* exp_nim_local_out_valid,
    svBitVecVal* exp_nim_local_out_data,
    uint32_t* exp_c2c_tx_valid,
    svBitVecVal* exp_c2c_tx_data,
    uint32_t* exp_c2c_tx_ts,
    uint32_t* exp_c2c_tx_dst,
    uint32_t* exp_c2c_tx_crc8,
    uint32_t* exp_c2c_tx_port,
    uint32_t* exp_deskew_rel_valid,
    uint32_t* exp_deskew_rel_target,
    uint32_t* exp_ping_ack,
    int* exp_measured_skew,
    uint32_t* exp_crc_err) {

  g_state.dpi_calls++;

  // --- 1. VXM Slice Reference Evaluation ---
  uint8_t a_bytes[16], b_bytes[16], c_bytes[16], comb_bytes[16];
  unpack_128(stream_a_i, a_bytes);
  unpack_128(stream_b_i, b_bytes);
  unpack_128(stream_c_i, c_bytes);

  int32_t in_acc32[16];
  for (int i = 0; i < 16; ++i) {
    in_acc32[i] = static_cast<int32_t>(accum_32b_in_i[i]);
  }

  uint32_t vop = vxm_op_i & 0xFu;
  bool vvalid  = (vxm_op_valid_i & 1u) != 0u;
  bool is_mul_op = vvalid && (vop == 2u || vop == 3u || vop == 8u);
  bool is_lut_op = vvalid && (vop == 4u || vop == 8u || vop == 5u || vop == 7u || vop == 6u);

  *exp_vxm_mul_gate = is_mul_op ? 0u : 1u;
  *exp_vxm_lut_gate = is_lut_op ? 0u : 1u;

  int16_t tree_sum = 0;
  int8_t  tree_max = static_cast<int8_t>(a_bytes[0]);
  for (int i = 0; i < 16; ++i) {
    int8_t ai = static_cast<int8_t>(a_bytes[i]);
    tree_sum = static_cast<int16_t>(tree_sum + ai);
    if (ai > tree_max) tree_max = ai;
  }
  *exp_vxm_reduce_sum = static_cast<int>(tree_sum);
  *exp_vxm_reduce_max = static_cast<int>(tree_max);

  int32_t out_acc32_comb[16];
  for (int i = 0; i < 16; ++i) {
    int8_t ai = static_cast<int8_t>(a_bytes[i]);
    int8_t bi = static_cast<int8_t>(b_bytes[i]);
    int8_t ci = static_cast<int8_t>(c_bytes[i]);
    int8_t lut_in   = is_lut_op ? ai : 0;
    int8_t silu_val = silu_lut_int8_ref(lut_in);
    int8_t mul_a    = is_mul_op ? ((vop == 8u) ? silu_val : ai) : 0;
    int8_t mul_b    = is_mul_op ? bi : 0;
    int16_t mul_p   = static_cast<int16_t>(mul_a) * static_cast<int16_t>(mul_b);

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
        case 9u:  out_acc = (use_accum_32b_i & 1u) ? in_acc32[i] : static_cast<int32_t>(ai); out_lane = quant_scale_elem_ref(out_acc, quant_shift_i & 0x7u, prec_mode_i & 0xFu); break;
        default:  out_lane = 0; out_acc = 0; break;
      }
    }
    comb_bytes[i]     = static_cast<uint8_t>(out_lane);
    out_acc32_comb[i] = out_acc;
  }

  pack_128(comb_bytes, exp_vxm_comb_data);
  if (vvalid && (vop != 0u)) {
    *exp_vxm_out_valid = 1u;
    std::memcpy(g_state.vxm_out_data_q, comb_bytes, 16);
    std::memcpy(g_state.vxm_accum_out_q, out_acc32_comb, sizeof(out_acc32_comb));
  } else {
    *exp_vxm_out_valid = 0u;
  }
  pack_128(g_state.vxm_out_data_q, exp_vxm_out_data);
  for (int i = 0; i < 16; ++i) {
    exp_vxm_accum_out[i] = static_cast<svBitVecVal>(g_state.vxm_accum_out_q[i]);
  }

  // --- 2. NIM RealSync Slice Reference Evaluation ---
  uint8_t loc_in_bytes[16], rx_bytes[16];
  unpack_128(local_stream_in_data_i, loc_in_bytes);
  unpack_128(c2c_rx_data_i, rx_bytes);

  bool     nvalid    = (nim_op_valid_i & 1u) != 0u;
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
  *exp_crc_err    = rx_crc_err ? 1u : 0u;

  uint16_t incoming_target_cycle = static_cast<uint16_t>(rx_ts + f_cycles);

  bool    pre_slot_match_valid = false;
  uint8_t pre_slot_match_idx   = 0u;
  uint8_t pre_released_data[16] = {0};
  for (int s = 0; s < 4; ++s) {
    if (!pre_slot_match_valid && g_state.buf_valid[s] && (g_state.buf_target_cycle[s] == r_time)) {
      pre_slot_match_valid = true;
      pre_slot_match_idx   = static_cast<uint8_t>(s);
      std::memcpy(pre_released_data, g_state.buf_data[s], 16);
    }
  }

  uint8_t allreduce_sum[16];
  const uint8_t* remote_op = pre_slot_match_valid ? pre_released_data : rx_bytes;
  for (int i = 0; i < 16; ++i) {
    int16_t s = static_cast<int16_t>(static_cast<int8_t>(loc_in_bytes[i])) +
                static_cast<int16_t>(static_cast<int8_t>(remote_op[i]));
    allreduce_sum[i] = static_cast<uint8_t>(sat_int8_ref(s));
  }

  uint32_t loc_out_v = 0u;
  uint32_t tx_out_v  = 0u;
  uint32_t ping_ack  = 0u;

  if (pre_slot_match_valid) {
    loc_out_v = 1u;
    std::memcpy(g_state.nim_local_out_data_q, pre_released_data, 16);
  }

  if (nvalid) {
    switch (nop) {
      case 0u: break;
      case 1u:
        if (loc_in_v) {
          tx_out_v = 1u;
          std::memcpy(g_state.c2c_tx_data_q, loc_in_bytes, 16);
          g_state.c2c_tx_ts_q   = r_time;
          g_state.c2c_tx_dst_q  = tx_dst;
          g_state.c2c_tx_crc8_q = crc8_calc_ref(loc_in_bytes, r_time);
          g_state.c2c_tx_port_q = dragonfly_route_ref(loc_chip, tx_dst, ugal_en, congested);
        }
        break;
      case 2u:
        if (pre_slot_match_valid) {
          loc_out_v = 1u;
          std::memcpy(g_state.nim_local_out_data_q, pre_released_data, 16);
        }
        break;
      case 3u:
      case 6u:
        if (rx_v && !rx_crc_err) {
          ping_ack = 1u;
          g_state.measured_skew_q = static_cast<int16_t>(static_cast<int16_t>(r_time) - static_cast<int16_t>(incoming_target_cycle));
        }
        break;
      case 4u:
        if (rx_v && !rx_crc_err) {
          tx_out_v = 1u;
          std::memcpy(g_state.c2c_tx_data_q, rx_bytes, 16);
          g_state.c2c_tx_ts_q   = r_time;
          g_state.c2c_tx_dst_q  = rx_dst;
          g_state.c2c_tx_crc8_q = crc8_calc_ref(rx_bytes, r_time);
          g_state.c2c_tx_port_q = dragonfly_route_ref(loc_chip, rx_dst, ugal_en, congested);
        }
        break;
      case 5u:
        if (loc_in_v && (pre_slot_match_valid || (rx_v && !rx_crc_err))) {
          loc_out_v = 1u;
          std::memcpy(g_state.nim_local_out_data_q, allreduce_sum, 16);
          tx_out_v  = 1u;
          std::memcpy(g_state.c2c_tx_data_q, allreduce_sum, 16);
          g_state.c2c_tx_ts_q   = r_time;
          g_state.c2c_tx_dst_q  = tx_dst;
          g_state.c2c_tx_crc8_q = crc8_calc_ref(allreduce_sum, r_time);
          g_state.c2c_tx_port_q = dragonfly_route_ref(loc_chip, tx_dst, ugal_en, congested);
        }
        break;
      case 7u:
        if (loc_in_v) {
          loc_out_v = 1u;
          std::memcpy(g_state.nim_local_out_data_q, loc_in_bytes, 16);
          tx_out_v  = 1u;
          std::memcpy(g_state.c2c_tx_data_q, loc_in_bytes, 16);
          g_state.c2c_tx_ts_q   = r_time;
          g_state.c2c_tx_dst_q  = loc_chip;
          g_state.c2c_tx_crc8_q = crc8_calc_ref(loc_in_bytes, r_time);
          g_state.c2c_tx_port_q = 0u;
        }
        break;
      default: break;
    }
  }

  if (pre_slot_match_valid) {
    g_state.buf_valid[pre_slot_match_idx] = false;
  }
  if (rx_v && !rx_crc_err && !(nvalid && (nop == 4u))) {
    uint8_t wp = g_state.wr_ptr & 0x3u;
    g_state.buf_valid[wp]        = true;
    std::memcpy(g_state.buf_data[wp], rx_bytes, 16);
    g_state.buf_target_cycle[wp] = incoming_target_cycle;
    g_state.wr_ptr               = static_cast<uint8_t>((wp + 1u) & 0x3u);
  }

  bool     post_match_valid  = false;
  uint16_t post_match_target = 0u;
  for (int s = 0; s < 4; ++s) {
    if (!post_match_valid && g_state.buf_valid[s] && (g_state.buf_target_cycle[s] == r_time)) {
      post_match_valid  = true;
      post_match_target = g_state.buf_target_cycle[s];
    }
  }

  *exp_nim_local_out_valid = loc_out_v;
  pack_128(g_state.nim_local_out_data_q, exp_nim_local_out_data);
  *exp_c2c_tx_valid        = tx_out_v;
  pack_128(g_state.c2c_tx_data_q, exp_c2c_tx_data);
  *exp_c2c_tx_ts           = g_state.c2c_tx_ts_q;
  *exp_c2c_tx_dst          = g_state.c2c_tx_dst_q;
  *exp_c2c_tx_crc8         = g_state.c2c_tx_crc8_q;
  *exp_c2c_tx_port         = g_state.c2c_tx_port_q;
  *exp_deskew_rel_valid    = post_match_valid ? 1u : 0u;
  *exp_deskew_rel_target   = post_match_target;
  *exp_ping_ack            = ping_ack;
  *exp_measured_skew       = static_cast<int>(g_state.measured_skew_q);
}
