// =============================================================================
// File: uvm_tb/uvm_lpx_mxfp8_dma/dpi_lpx_mxfp8_dma_ref.cpp
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Cycle-Accurate Bit-Exact C++17 DPI-C Golden Reference Model for
//              groq_mxfp8_nvfp4_dot_engine, groq_c2c_serdes_pcs, and
//              groq_pcie_c2c_dma under Accellera IEEE 1800.2-2020 UVM.
// =============================================================================
#include <cstdint>
#include <cstring>
#include "svdpi.h"

namespace {

struct DotEngineState {
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

struct SerdesPcsState {
  uint8_t  link_state_q;
  uint8_t  measured_skew_q;
  uint16_t tx_lfsr_q;
  uint16_t rx_lfsr_q;
  uint8_t  replay_valid_q;
  uint8_t  replay_data_q[4][16];
  uint16_t replay_hdr_q[4];
  uint8_t  replay_seq_q[4];
  uint8_t  tx_seq_q;
  uint8_t  replay_active_q;
  uint8_t  replay_ptr_q;
  uint8_t  rx_expected_seq_q;
};

struct PcieDmaState {
  uint8_t  desc_ring_q[4][16];
  uint8_t  head_ptr_q;
  uint8_t  tail_ptr_q;
  uint8_t  desc_count_q;
  uint8_t  dma_active_q;
  uint8_t  dma_target_q;
  uint8_t  dma_sel_q;
  uint16_t addr_q;
  uint8_t  stride_q;
  uint8_t  rem_beats_q;
  uint16_t imem_upper_q;
  uint8_t  dma_done_irq_q;
  uint8_t  completed_desc_cnt_q;
  uint16_t beats_transferred_q;
};

static DotEngineState g_dot;
static SerdesPcsState g_pcs;
static PcieDmaState   g_dma;
static uint32_t       g_dpi_calls  = 0;
static int            g_sim_status = 1;

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

static inline uint8_t fn_nvfp4_mag_2x(uint8_t em) {
  static const uint8_t kLut[8] = {0, 1, 2, 3, 4, 6, 8, 12};
  return kLut[em & 0x7u];
}

static inline uint16_t lfsr16_next_state(uint16_t s_in) {
  uint16_t s = s_in;
  for (int i = 0; i < 16; ++i) {
    uint16_t fb = ((s >> 15) ^ (s >> 13) ^ (s >> 12) ^ (s >> 10)) & 1u;
    s = static_cast<uint16_t>(((s << 1) | fb) & 0xFFFFu);
  }
  return s;
}

static inline void apply_scrambler(const uint8_t in_bytes[16], uint16_t seed, bool en, uint8_t out_bytes[16]) {
  if (!en) {
    std::memcpy(out_bytes, in_bytes, 16);
    return;
  }
  uint16_t s = seed;
  for (int i = 0; i < 16; ++i) {
    uint8_t mask_b = 0;
    for (int b = 0; b < 8; ++b) {
      uint16_t fb = ((s >> 15) ^ (s >> 13) ^ (s >> 12) ^ (s >> 10)) & 1u;
      mask_b |= static_cast<uint8_t>(fb << b);
      s = static_cast<uint16_t>(((s << 1) | fb) & 0xFFFFu);
    }
    out_bytes[i] = in_bytes[i] ^ mask_b;
  }
}

static inline uint16_t crc16_ccitt_byte(uint16_t crc_in, uint8_t data_byte) {
  uint16_t c = crc_in ^ (static_cast<uint16_t>(data_byte) << 8);
  for (int b = 0; b < 8; ++b) {
    if (c & 0x8000u) c = static_cast<uint16_t>(((c << 1) ^ 0x1021u) & 0xFFFFu);
    else             c = static_cast<uint16_t>((c << 1) & 0xFFFFu);
  }
  return c;
}

static inline uint16_t crc16_ccitt_calc(uint16_t meta, const uint8_t payload[16]) {
  uint16_t c = 0xFFFFu;
  for (int i = 0; i < 16; ++i) {
    c = crc16_ccitt_byte(c, payload[i]);
  }
  c = crc16_ccitt_byte(c, static_cast<uint8_t>(meta & 0xFFu));
  c = crc16_ccitt_byte(c, static_cast<uint8_t>((meta >> 8) & 0xFFu));
  return c;
}

static inline uint16_t calc_payload_parity16(const uint8_t data_in[16]) {
  uint16_t p = 0;
  for (int i = 0; i < 16; ++i) {
    uint8_t x = data_in[i];
    x ^= (x >> 4);
    x ^= (x >> 2);
    x ^= (x >> 1);
    p |= static_cast<uint16_t>((x & 1u) << i);
  }
  return p;
}

} // namespace

extern "C" void dpi_lpx_mxfp8_dma_reset() {
  std::memset(&g_dot, 0, sizeof(g_dot));
  std::memset(&g_pcs, 0, sizeof(g_pcs));
  std::memset(&g_dma, 0, sizeof(g_dma));
  g_pcs.tx_lfsr_q = 0xACE1u;
  g_pcs.rx_lfsr_q = 0xACE1u;
}

extern "C" uint32_t dpi_get_calls() {
  return g_dpi_calls;
}

extern "C" void dpi_set_status(int status) {
  g_sim_status = status;
}

extern "C" int dpi_get_status() {
  return g_sim_status;
}

extern "C" void dpi_dot_engine_step(
  uint32_t          valid_i,
  uint32_t          mode_i,
  uint32_t          zero_skip_en_i,
  uint32_t          accum_en_i,
  uint32_t          accum_clear_i,
  uint32_t          act_scale_e8m0_i,
  uint32_t          wt_scale_e8m0_i,
  const svBitVecVal* act_stream_i,
  const svBitVecVal* wt_stream_i,
  uint32_t*         exp_valid_o,
  int*              exp_unaccum_dot_o,
  int*              exp_dot_accum_o,
  uint32_t*         exp_dot_fp32_o,
  uint32_t*         exp_zero_skip_lanes_o,
  uint32_t*         exp_block_zero_skipped_o,
  uint32_t*         exp_nan_inf_flag_o
) {
  g_dpi_calls++;

  uint8_t act_b[16];
  uint8_t wt_b[16];
  unpack_128(act_stream_i, act_b);
  unpack_128(wt_stream_i, wt_b);

  uint8_t mode  = static_cast<uint8_t>(mode_i & 0x7u);
  uint8_t zskip = static_cast<uint8_t>(zero_skip_en_i & 1u);
  uint8_t asc   = static_cast<uint8_t>(act_scale_e8m0_i & 0xFFu);
  uint8_t wsc   = static_cast<uint8_t>(wt_scale_e8m0_i & 0xFFu);

  bool block_zero_skip_comb = (mode == 5u) ? ((zskip != 0u) && (((asc & 0x7Fu) == 0u) || ((wsc & 0x7Fu) == 0u))) : ((asc == 0u) || (wsc == 0u));

  // 1) 32-Sublane NVFP4 (E2M1)
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

  // 2) 16-Lane INT8 / MXFP8_E4M3 / MXFP8_E5M2 / W4A8_MIXED
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
        uint8_t a_e4  = (a_iso >> 3) & 0xFu;
        uint8_t w_e4  = (w_iso >> 3) & 0xFu;
        uint8_t a_ee4 = (a_e4 == 0u) ? 1u : a_e4;
        uint8_t w_ee4 = (w_e4 == 0u) ? 1u : w_e4;
        uint8_t a_sg4 = (a_e4 == 0u) ? (a_iso & 0x7u) : (0x8u | (a_iso & 0x7u));
        uint8_t w_sg4 = (w_e4 == 0u) ? (w_iso & 0x7u) : (0x8u | (w_iso & 0x7u));
        uint8_t sh4   = ((a_ee4 >> 1) + (w_ee4 >> 1) + ((a_ee4 & 1u) & (w_ee4 & 1u))) & 0xFu;
        uint8_t prod8 = static_cast<uint8_t>(a_sg4 * w_sg4);
        aligned_mag24 = (static_cast<uint32_t>(prod8) << sh4) & 0xFFFFFFu;
      } else if (mode == 2u) {
        uint8_t a_e5  = (a_iso >> 2) & 0x1Fu;
        uint8_t w_e5  = (w_iso >> 2) & 0x1Fu;
        uint8_t a_ee5 = (a_e5 == 0u) ? 1u : a_e5;
        uint8_t w_ee5 = (w_e5 == 0u) ? 1u : w_e5;
        uint8_t a_sg5 = (a_e5 == 0u) ? static_cast<uint8_t>((a_iso & 0x3u) << 1) : static_cast<uint8_t>(0x8u | ((a_iso & 0x3u) << 1));
        uint8_t w_sg5 = (w_e5 == 0u) ? static_cast<uint8_t>((w_iso & 0x3u) << 1) : static_cast<uint8_t>(0x8u | ((w_iso & 0x3u) << 1));
        uint8_t sh5   = ((a_ee5 >> 2) + (w_ee5 >> 2) + (((a_ee5 & 0x3u) & (w_ee5 & 0x3u)) ? 1u : 0u)) & 0xFu;
        uint8_t prod8 = static_cast<uint8_t>(a_sg5 * w_sg5);
        aligned_mag24 = (static_cast<uint32_t>(prod8) << sh5) & 0xFFFFFFu;
      } else {
        uint8_t a_e4  = (a_iso >> 3) & 0xFu;
        uint8_t a_ee4 = (a_e4 == 0u) ? 1u : a_e4;
        uint8_t a_sg4 = (a_e4 == 0u) ? (a_iso & 0x7u) : (0x8u | (a_iso & 0x7u));
        uint8_t w_mag = fn_nvfp4_mag_2x(w_fp4 & 0x7u);
        uint8_t prod8 = static_cast<uint8_t>(a_sg4 * w_mag);
        aligned_mag24 = (static_cast<uint32_t>(prod8) << a_ee4) & 0xFFFFFFu;
      }
      int32_t ls = ps ? -static_cast<int32_t>(aligned_mag24) : static_cast<int32_t>(aligned_mag24);
      lane16_sum += ls;
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

  // Stage 2 Datapath (evaluated from s1_*_q before updating s1_*_q)
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
  if (!g_dot.s1_accum_en_q) {
    s2_accum = g_dot.s1_accum_clear_q ? 0 : s2_unaccum;
  } else if (acc_ext > 2147483647LL) {
    s2_accum = 2147483647;
  } else if (acc_ext < -2147483648LL) {
    s2_accum = -2147483647;
  } else {
    s2_accum = static_cast<int32_t>(acc_ext);
  }

  uint32_t msb_idx = 0u;
  for (int b = 0; b < 31; ++b) {
    if ((s2_abs >> b) & 1u) msb_idx = static_cast<uint32_t>(b);
  }
  uint32_t norm_shift    = s2_abs << (31u - msb_idx);
  uint32_t fp32_exp_wide = (scale_sum + msb_idx - 127u) & 0x3FFu;
  uint32_t s2_fp32       = 0u;
  if (g_dot.s1_nan_inf_q) {
    s2_fp32 = 0x7FC00000u;
  } else if (g_dot.s1_block_zero_skip_q || (s2_abs == 0u)) {
    s2_fp32 = 0x00000000u;
  } else if (((fp32_exp_wide >> 9) & 1u) || (fp32_exp_wide == 0u)) {
    s2_fp32 = (s2_sign << 31);
  } else if (fp32_exp_wide >= 255u) {
    s2_fp32 = (s2_sign << 31) | 0x7F800000u;
  } else {
    s2_fp32 = (s2_sign << 31) | ((fp32_exp_wide & 0xFFu) << 23) | ((norm_shift >> 8) & 0x7FFFFFu);
  }

  // Update Stage 2 & Stage 1 registers
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

extern "C" void dpi_serdes_pcs_step(
  uint32_t           link_enable_i,
  uint32_t           scramble_en_i,
  uint32_t           rx_ts1_seen_i,
  uint32_t           rx_ts2_seen_i,
  uint32_t           deskew_done_i,
  uint32_t           retrain_req_i,
  uint32_t           local_realsync_cnt_i,
  uint32_t           rx_beacon_ts_i,
  uint32_t           tx_flit_valid_i,
  const svBitVecVal* tx_flit_data_i,
  uint32_t           tx_dst_chip_i,
  uint32_t           tx_hop_cnt_i,
  uint32_t           tx_opcode_i,
  uint32_t           nack_req_i,
  uint32_t           nack_seq_i,
  uint32_t           phy_rx_valid_i,
  uint32_t           phy_rx_sync_hdr_i,
  uint32_t           phy_rx_crc16_i,
  uint32_t           phy_rx_meta_i,
  const svBitVecVal* phy_rx_payload_i,
  uint32_t*          exp_tx_ready_o,
  uint32_t*          exp_phy_tx_valid_o,
  uint32_t*          exp_tx_sync_hdr_o,
  uint32_t*          exp_tx_crc16_o,
  uint32_t*          exp_tx_meta_o,
  svBitVecVal*       exp_tx_scrambled_payload_o,
  uint32_t*          exp_tx_seq_num_o,
  uint32_t*          exp_rx_flit_valid_o,
  svBitVecVal*       exp_rx_flit_data_o,
  uint32_t*          exp_rx_dst_chip_o,
  uint32_t*          exp_rx_hop_cnt_o,
  uint32_t*          exp_rx_opcode_o,
  uint32_t*          exp_rx_seq_num_o,
  uint32_t*          exp_rx_crc16_err_o,
  uint32_t*          exp_rx_sync_err_o,
  uint32_t*          exp_nack_req_o,
  uint32_t*          exp_nack_seq_o,
  uint32_t*          exp_replay_active_o,
  uint32_t*          exp_link_state_o,
  uint32_t*          exp_link_up_o,
  uint32_t*          exp_measured_skew_o
) {
  uint8_t tx_in_b[16];
  uint8_t rx_in_b[16];
  unpack_128(tx_flit_data_i, tx_in_b);
  unpack_128(phy_rx_payload_i, rx_in_b);

  bool link_en     = (link_enable_i & 1u) != 0u;
  bool scram_en    = (scramble_en_i & 1u) != 0u;
  bool nack_in     = (nack_req_i & 1u) != 0u;
  uint8_t nack_sq  = static_cast<uint8_t>(nack_seq_i & 0x3u);
  bool tx_v        = (tx_flit_valid_i & 1u) != 0u;
  bool rx_v        = (phy_rx_valid_i & 1u) != 0u;
  bool link_up_pre = (g_pcs.link_state_q == 4u);

  bool rep_v_ptr   = ((g_pcs.replay_valid_q >> (g_pcs.replay_ptr_q & 0x3u)) & 1u) != 0u;
  bool rep_v_nack  = ((g_pcs.replay_valid_q >> nack_sq) & 1u) != 0u;
  bool tx_send_data = link_up_pre &&
                      ((g_pcs.replay_active_q && rep_v_ptr) ||
                       (nack_in && rep_v_nack) ||
                       (!g_pcs.replay_active_q && !nack_in && tx_v));

  uint8_t  tx_sync_hdr = 2u;
  uint8_t  tx_raw[16];
  std::memset(tx_raw, 0, 16);
  uint16_t tx_meta_word = 0u;
  uint8_t  tx_seq_num   = 0u;

  if (!link_up_pre) {
    tx_sync_hdr = 2u;
    if (g_pcs.link_state_q == 2u) {
      std::memset(tx_raw, 0x45, 16);
    } else if (g_pcs.link_state_q == 3u) {
      tx_raw[0] = static_cast<uint8_t>(local_realsync_cnt_i & 0xFFu);
    } else {
      std::memset(tx_raw, 0x4A, 16);
    }
    tx_meta_word = static_cast<uint16_t>((g_pcs.link_state_q & 0x7u) << 4);
    tx_seq_num   = 0u;
  } else if (nack_in && rep_v_nack) {
    tx_sync_hdr  = 1u;
    std::memcpy(tx_raw, g_pcs.replay_data_q[nack_sq], 16);
    tx_meta_word = static_cast<uint16_t>(((g_pcs.replay_hdr_q[nack_sq] & 0xFFFu) << 4) | (g_pcs.replay_seq_q[nack_sq] & 0xFu));
    tx_seq_num   = g_pcs.replay_seq_q[nack_sq] & 0xFu;
  } else if (g_pcs.replay_active_q && rep_v_ptr) {
    uint8_t rp   = g_pcs.replay_ptr_q & 0x3u;
    tx_sync_hdr  = 1u;
    std::memcpy(tx_raw, g_pcs.replay_data_q[rp], 16);
    tx_meta_word = static_cast<uint16_t>(((g_pcs.replay_hdr_q[rp] & 0xFFFu) << 4) | (g_pcs.replay_seq_q[rp] & 0xFu));
    tx_seq_num   = g_pcs.replay_seq_q[rp] & 0xFu;
  } else if (tx_v) {
    tx_sync_hdr  = 1u;
    std::memcpy(tx_raw, tx_in_b, 16);
    tx_meta_word = static_cast<uint16_t>(((tx_dst_chip_i & 0xFu) << 12) |
                                         ((tx_hop_cnt_i & 0xFu) << 8) |
                                         ((tx_opcode_i & 0xFu) << 4) |
                                         (g_pcs.tx_seq_q & 0xFu));
    tx_seq_num   = g_pcs.tx_seq_q & 0xFu;
  } else {
    tx_sync_hdr  = 2u;
    tx_meta_word = 0u;
    tx_seq_num   = g_pcs.tx_seq_q & 0xFu;
  }

  uint8_t tx_scram[16];
  apply_scrambler(tx_raw, g_pcs.tx_lfsr_q, scram_en && (tx_sync_hdr == 1u), tx_scram);
  uint16_t tx_crc16 = crc16_ccitt_calc(tx_meta_word, tx_raw);
  bool phy_tx_valid = (!link_up_pre && link_en) || tx_send_data;

  uint8_t  rx_sync_hdr      = static_cast<uint8_t>(phy_rx_sync_hdr_i & 0x3u);
  uint16_t rx_crc16_in      = static_cast<uint16_t>(phy_rx_crc16_i & 0xFFFFu);
  uint16_t rx_meta_in       = static_cast<uint16_t>(phy_rx_meta_i & 0xFFFFu);
  bool     rx_is_data_block = rx_v && (rx_sync_hdr == 1u);
  bool     rx_sync_err      = rx_v && (rx_sync_hdr != 1u) && (rx_sync_hdr != 2u);

  uint8_t rx_descram[16];
  apply_scrambler(rx_in_b, g_pcs.rx_lfsr_q, scram_en && rx_is_data_block, rx_descram);
  uint16_t rx_crc16_calc    = crc16_ccitt_calc(rx_meta_in, rx_descram);
  bool     rx_crc16_err     = rx_is_data_block && (rx_crc16_calc != rx_crc16_in);
  bool     rx_flit_valid    = link_up_pre && rx_is_data_block && !rx_crc16_err && !rx_sync_err;

  *exp_tx_ready_o      = (link_up_pre && !g_pcs.replay_active_q && !nack_in) ? 1u : 0u;
  *exp_phy_tx_valid_o  = phy_tx_valid ? 1u : 0u;
  *exp_tx_sync_hdr_o   = tx_sync_hdr;
  *exp_tx_crc16_o      = tx_crc16;
  *exp_tx_meta_o       = tx_meta_word;
  pack_128(tx_scram, exp_tx_scrambled_payload_o);
  *exp_tx_seq_num_o    = tx_seq_num;

  *exp_rx_flit_valid_o = rx_flit_valid ? 1u : 0u;
  pack_128(rx_descram, exp_rx_flit_data_o);
  *exp_rx_dst_chip_o   = (rx_meta_in >> 12) & 0xFu;
  *exp_rx_hop_cnt_o    = (rx_meta_in >> 8) & 0xFu;
  *exp_rx_opcode_o     = (rx_meta_in >> 4) & 0xFu;
  *exp_rx_seq_num_o    = rx_meta_in & 0xFu;
  *exp_rx_crc16_err_o  = rx_crc16_err ? 1u : 0u;
  *exp_rx_sync_err_o   = rx_sync_err ? 1u : 0u;
  *exp_nack_req_o      = (link_up_pre && (rx_crc16_err || rx_sync_err)) ? 1u : 0u;
  *exp_nack_seq_o      = rx_is_data_block ? (rx_meta_in & 0x3u) : (g_pcs.rx_expected_seq_q & 0x3u);

  // Sequential updates at posedge clk
  uint8_t link_state_d = g_pcs.link_state_q;
  if (!link_en) {
    link_state_d = 0u;
  } else {
    switch (g_pcs.link_state_q) {
      case 0u: link_state_d = 1u; break;
      case 1u: if (rx_ts1_seen_i & 1u) link_state_d = 2u; break;
      case 2u: if (rx_ts2_seen_i & 1u) link_state_d = 3u; break;
      case 3u: if (deskew_done_i & 1u) link_state_d = 4u; break;
      case 4u: if (retrain_req_i & 1u) link_state_d = 5u; break;
      case 5u: link_state_d = 1u; break;
      default: link_state_d = 0u; break;
    }
  }

  if (g_pcs.link_state_q == 3u) {
    g_pcs.measured_skew_q = static_cast<uint8_t>((local_realsync_cnt_i - rx_beacon_ts_i) & 0xFFu);
  }

  if (!link_up_pre) {
    g_pcs.tx_lfsr_q       = 0xACE1u;
    g_pcs.rx_lfsr_q       = 0xACE1u;
    g_pcs.replay_active_q = 0u;
  } else {
    if (tx_send_data && scram_en) {
      g_pcs.tx_lfsr_q = lfsr16_next_state(g_pcs.tx_lfsr_q);
    }
    if (rx_is_data_block && !rx_crc16_err && scram_en) {
      g_pcs.rx_lfsr_q = lfsr16_next_state(g_pcs.rx_lfsr_q);
    }

    if (nack_in && rep_v_nack) {
      if (((nack_sq + 1u) & 0x3u) == (g_pcs.tx_seq_q & 0x3u)) {
        g_pcs.replay_active_q = 0u;
      } else {
        g_pcs.replay_active_q = 1u;
        g_pcs.replay_ptr_q    = static_cast<uint8_t>((nack_sq + 1u) & 0x3u);
      }
    } else if (g_pcs.replay_active_q) {
      if (((g_pcs.replay_ptr_q + 1u) & 0x3u) == (g_pcs.tx_seq_q & 0x3u)) {
        g_pcs.replay_active_q = 0u;
      } else {
        g_pcs.replay_ptr_q = static_cast<uint8_t>((g_pcs.replay_ptr_q + 1u) & 0x3u);
      }
    } else if (tx_v) {
      uint8_t idx = g_pcs.tx_seq_q & 0x3u;
      g_pcs.replay_valid_q |= static_cast<uint8_t>(1u << idx);
      std::memcpy(g_pcs.replay_data_q[idx], tx_in_b, 16);
      g_pcs.replay_hdr_q[idx] = static_cast<uint16_t>(((tx_dst_chip_i & 0xFu) << 8) |
                                                      ((tx_hop_cnt_i & 0xFu) << 4) |
                                                      (tx_opcode_i & 0xFu));
      g_pcs.replay_seq_q[idx] = g_pcs.tx_seq_q & 0xFu;
      g_pcs.tx_seq_q          = static_cast<uint8_t>((g_pcs.tx_seq_q + 1u) & 0xFu);
    }

    if (rx_flit_valid) {
      g_pcs.rx_expected_seq_q = static_cast<uint8_t>(((rx_meta_in & 0x3u) + 1u) & 0x3u);
    }
  }

  g_pcs.link_state_q = link_state_d;

  *exp_replay_active_o = g_pcs.replay_active_q;
  *exp_link_state_o    = g_pcs.link_state_q;
  *exp_link_up_o       = (g_pcs.link_state_q == 4u) ? 1u : 0u;
  *exp_measured_skew_o = g_pcs.measured_skew_q;
}

extern "C" void dpi_pcie_dma_step(
  uint32_t           global_cycle_i,
  uint32_t           vliw_active_window_i,
  uint32_t           vliw_sram_busy_i,
  uint32_t           vliw_sram_w_busy_i,
  uint32_t           vliw_sram_e_busy_i,
  uint32_t           desc_push_valid_i,
  const svBitVecVal* desc_push_data_i,
  uint32_t           dma_payload_valid_i,
  const svBitVecVal* dma_payload_data_i,
  uint32_t           dma_payload_parity_i,
  uint32_t*          exp_desc_push_ready_o,
  uint32_t*          exp_dma_payload_ready_o,
  uint32_t*          exp_imem_wr_en_o,
  uint32_t*          exp_imem_wr_slice_o,
  uint32_t*          exp_imem_wr_addr_o,
  uint32_t*          exp_imem_wr_upper_o,
  svBitVecVal*       exp_imem_wr_payload_o,
  uint32_t*          exp_host_mem_w_wr_en_o,
  uint32_t*          exp_host_mem_w_bank_o,
  uint32_t*          exp_host_mem_w_addr_o,
  svBitVecVal*       exp_host_mem_w_data_o,
  uint32_t*          exp_host_mem_e_wr_en_o,
  uint32_t*          exp_host_mem_e_bank_o,
  uint32_t*          exp_host_mem_e_addr_o,
  svBitVecVal*       exp_host_mem_e_data_o,
  uint32_t*          exp_dma_window_stall_o,
  uint32_t*          exp_payload_parity_err_o,
  uint32_t*          exp_full_o,
  uint32_t*          exp_empty_o,
  uint32_t*          exp_head_ptr_o,
  uint32_t*          exp_tail_ptr_o,
  uint32_t*          exp_desc_count_o,
  uint32_t*          exp_dma_busy_o,
  uint32_t*          exp_dma_done_irq_o,
  uint32_t*          exp_completed_desc_cnt_o,
  uint32_t*          exp_beats_transferred_o
) {
  uint8_t desc_in_b[16];
  uint8_t pay_in_b[16];
  unpack_128(desc_push_data_i, desc_in_b);
  unpack_128(dma_payload_data_i, pay_in_b);

  bool full_pre  = (g_dma.desc_count_q == 4u);
  bool empty_pre = (g_dma.desc_count_q == 0u);

  const uint8_t* hd = g_dma.desc_ring_q[g_dma.head_ptr_q & 0x3u];
  uint8_t  head_target      = hd[0] & 0x3u;
  uint8_t  head_sel         = (hd[0] >> 2) & 0x7u;
  uint16_t head_base_addr   = static_cast<uint16_t>(hd[1]) | (static_cast<uint16_t>(hd[2]) << 8);
  uint8_t  head_stride      = hd[3];
  uint8_t  head_burst_len   = (hd[4] == 0u) ? 1u : hd[4];
  uint16_t head_sched_cycle = static_cast<uint16_t>(hd[5]) | (static_cast<uint16_t>(hd[6]) << 8);
  uint16_t head_imem_upper  = static_cast<uint16_t>(hd[7]) | (static_cast<uint16_t>(hd[8]) << 8);
  bool     head_sched_ready = !empty_pre && ((global_cycle_i & 0xFFFFu) >= head_sched_cycle);

  bool do_push = ((desc_push_valid_i & 1u) != 0u) && !full_pre;
  bool do_pop  = !g_dma.dma_active_q && head_sched_ready;

  bool tgt_w = (g_dma.dma_target_q == 1u) || (g_dma.dma_target_q == 3u);
  bool tgt_e = (g_dma.dma_target_q == 2u) || (g_dma.dma_target_q == 3u);
  bool vliw_w_blk = tgt_w && ((vliw_sram_busy_i & 1u) || (vliw_sram_w_busy_i & 1u) || (vliw_active_window_i & 1u));
  bool vliw_e_blk = tgt_e && ((vliw_sram_busy_i & 1u) || (vliw_sram_e_busy_i & 1u) || (vliw_active_window_i & 1u));
  bool sram_blk   = vliw_w_blk || vliw_e_blk;

  bool pay_v    = (dma_payload_valid_i & 1u) != 0u;
  bool par_err  = pay_v && (calc_payload_parity16(pay_in_b) != (dma_payload_parity_i & 0xFFFFu));
  bool beat_fire = (g_dma.dma_active_q != 0u) && pay_v && !sram_blk && !par_err;

  *exp_desc_push_ready_o    = (!full_pre) ? 1u : 0u;
  *exp_dma_payload_ready_o  = ((g_dma.dma_active_q != 0u) && !sram_blk) ? 1u : 0u;
  *exp_imem_wr_en_o         = (beat_fire && (g_dma.dma_target_q == 0u)) ? 1u : 0u;
  *exp_imem_wr_slice_o      = g_dma.dma_sel_q & 0x7u;
  *exp_imem_wr_addr_o       = g_dma.addr_q;
  *exp_imem_wr_upper_o      = g_dma.imem_upper_q;
  pack_128(pay_in_b, exp_imem_wr_payload_o);

  *exp_host_mem_w_wr_en_o   = (beat_fire && tgt_w && !vliw_w_blk) ? 1u : 0u;
  *exp_host_mem_w_bank_o    = g_dma.dma_sel_q & 0x3u;
  *exp_host_mem_w_addr_o    = g_dma.addr_q;
  pack_128(pay_in_b, exp_host_mem_w_data_o);

  *exp_host_mem_e_wr_en_o   = (beat_fire && tgt_e && !vliw_e_blk) ? 1u : 0u;
  *exp_host_mem_e_bank_o    = g_dma.dma_sel_q & 0x3u;
  *exp_host_mem_e_addr_o    = g_dma.addr_q;
  pack_128(pay_in_b, exp_host_mem_e_data_o);

  *exp_dma_window_stall_o   = ((g_dma.dma_active_q != 0u) && pay_v && sram_blk) ? 1u : 0u;
  *exp_payload_parity_err_o = par_err ? 1u : 0u;

  // Sequential updates at posedge clk
  g_dma.dma_done_irq_q = 0u;
  if (do_push) {
    std::memcpy(g_dma.desc_ring_q[g_dma.tail_ptr_q & 0x3u], desc_in_b, 16);
    g_dma.tail_ptr_q = static_cast<uint8_t>((g_dma.tail_ptr_q + 1u) & 0x3u);
  }
  if (do_pop) {
    g_dma.head_ptr_q = static_cast<uint8_t>((g_dma.head_ptr_q + 1u) & 0x3u);
  }
  if (do_push && !do_pop)      g_dma.desc_count_q = static_cast<uint8_t>((g_dma.desc_count_q + 1u) & 0x7u);
  else if (!do_push && do_pop) g_dma.desc_count_q = static_cast<uint8_t>((g_dma.desc_count_q - 1u) & 0x7u);

  if (do_pop) {
    g_dma.dma_active_q = 1u;
    g_dma.dma_target_q = head_target;
    g_dma.dma_sel_q    = head_sel;
    g_dma.addr_q       = head_base_addr;
    g_dma.stride_q     = head_stride;
    g_dma.rem_beats_q  = head_burst_len;
    g_dma.imem_upper_q = head_imem_upper;
  } else if (beat_fire) {
    g_dma.beats_transferred_q = static_cast<uint16_t>((g_dma.beats_transferred_q + 1u) & 0xFFFFu);
    if (g_dma.rem_beats_q <= 1u) {
      g_dma.dma_active_q         = 0u;
      g_dma.rem_beats_q          = 0u;
      g_dma.dma_done_irq_q       = 1u;
      g_dma.completed_desc_cnt_q = static_cast<uint8_t>((g_dma.completed_desc_cnt_q + 1u) & 0xFFu);
    } else {
      g_dma.addr_q      = static_cast<uint16_t>((g_dma.addr_q + static_cast<uint16_t>(g_dma.stride_q)) & 0xFFFFu);
      g_dma.rem_beats_q = static_cast<uint8_t>((g_dma.rem_beats_q - 1u) & 0xFFu);
    }
  }

  *exp_full_o               = (g_dma.desc_count_q == 4u) ? 1u : 0u;
  *exp_empty_o              = (g_dma.desc_count_q == 0u) ? 1u : 0u;
  *exp_head_ptr_o           = g_dma.head_ptr_q;
  *exp_tail_ptr_o           = g_dma.tail_ptr_q;
  *exp_desc_count_o         = g_dma.desc_count_q;
  *exp_dma_busy_o           = g_dma.dma_active_q;
  *exp_dma_done_irq_o       = g_dma.dma_done_irq_q;
  *exp_completed_desc_cnt_o = g_dma.completed_desc_cnt_q;
  *exp_beats_transferred_o  = g_dma.beats_transferred_q;
}
