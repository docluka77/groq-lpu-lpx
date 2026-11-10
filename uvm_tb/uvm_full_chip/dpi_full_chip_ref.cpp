// =============================================================================
// File: uvm_tb/uvm_full_chip/dpi_full_chip_ref.cpp
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Cycle-Accurate C++17 DPI-C Golden Reference Model for Stage 7E
//              Full-Chip & 2-Chip Cluster UVM Verification Suite.
// =============================================================================
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include "svdpi.h"

namespace {

struct Vec128 {
 uint8_t lane[16];
};

// Golden state for 2 Chips (Chip 0, Chip 1)
static Vec128 g_w_sram[2][4][1024];
static Vec128 g_e_sram[2][4][1024];
static int8_t g_mxm_wt[2][2][16][16]; // [chip][0=W,1=E][row][col]
static int32_t g_mxm_accum[2][2][16]; // [chip][0=W,1=E][col]

static uint64_t g_total_checks = 0;
static uint64_t g_mismatches = 0;
static uint64_t g_pipeline_checks = 0;
static uint64_t g_ecc_checks = 0;
static uint64_t g_barrier_checks = 0;
static uint64_t g_c2c_checks = 0;
static uint64_t g_cycle_inv_checks = 0;

static inline Vec128 unpack_sv128(const svBitVecVal* v) {
 Vec128 out;
 for (int w = 0; w < 4; w++) {
 uint32_t word = v[w];
 out.lane[w * 4 + 0] = static_cast<uint8_t>((word >> 0) & 0xFFu);
 out.lane[w * 4 + 1] = static_cast<uint8_t>((word >> 8) & 0xFFu);
 out.lane[w * 4 + 2] = static_cast<uint8_t>((word >> 16) & 0xFFu);
 out.lane[w * 4 + 3] = static_cast<uint8_t>((word >> 24) & 0xFFu);
 }
 return out;
}

static inline bool eq_vec128(const Vec128& a, const Vec128& b) {
 return std::memcmp(a.lane, b.lane, 16) == 0;
}

static inline int8_t sat_int8(int32_t val) {
 if (val > 127) return 127;
 if (val < -128) return -128;
 return static_cast<int8_t>(val);
}

static inline int8_t silu_lut_int8(int8_t x) {
 int16_t x_ext = static_cast<int16_t>(x);
 int16_t y = 0;
 if (x <= -64) y = 0;
 else if (x <= -32) y = static_cast<int16_t>(-((x_ext + 64) >> 3));
 else if (x < 0) y = static_cast<int16_t>(x_ext >> 2);
 else if (x < 32) y = static_cast<int16_t>(((x_ext << 2) + x_ext) >> 3);
 else if (x < 64) y = static_cast<int16_t>(x_ext - 12);
 else y = x_ext;
 return sat_int8(y);
}

static inline int8_t gelu_lut_int8(int8_t x) {
  int16_t x_ext = static_cast<int16_t>(x);
  int16_t y = 0;
  if (x <= -48)    y = 0;
  else if (x < 0)  y = static_cast<int16_t>(((x_ext + 48) >> 4) - 3);
  else if (x < 48) y = static_cast<int16_t>(((x_ext << 1) + x_ext) >> 2);
  else             y = x_ext;
  return sat_int8(y);
}

static Vec128 eval_sxm(const Vec128& in, int sxm_op, int shamt, int bfly_mask) {
  Vec128 out{};
  int sh = shamt & 0xF;
  int bcast = (shamt >> 4) & 0xF;
  int mask = bfly_mask & 0xF;
  for (int i = 0; i < 16; i++) {
    int idx_rot_l  = (i - sh) & 0xF;
    int idx_rot_r  = (i + sh) & 0xF;
    int idx_bitrev = ((i & 1) << 3) | ((i & 2) << 1) | ((i & 4) >> 1) | ((i & 8) >> 3);
    int idx_bfly   = (i ^ mask) & 0xF;
    int idx_t4     = ((i & 3) << 2) | ((i >> 2) & 3);
    switch (sxm_op) {
      case 1:  out.lane[i] = in.lane[i]; break;          // SXM_PASSTHROUGH
      case 2:
      case 7:  out.lane[i] = in.lane[idx_rot_l]; break;  // SXM_ROTATE_LEFT
      case 8:  out.lane[i] = in.lane[idx_rot_r]; break;  // SXM_ROTATE_RIGHT
      case 3:  out.lane[i] = in.lane[idx_t4]; break;     // SXM_TRANSPOSE_4X4
      case 4:  out.lane[i] = in.lane[idx_bitrev]; break; // SXM_BIT_REVERSE
      case 5:  out.lane[i] = in.lane[bcast]; break;      // SXM_BROADCAST_LANE
      case 6:  out.lane[i] = (i < 8) ? in.lane[2 * i] : in.lane[2 * (i - 8) + 1]; break;
      case 9:  out.lane[i] = in.lane[15 - i]; break;     // SXM_REVERSE
      case 12: out.lane[i] = in.lane[idx_bfly]; break;   // SXM_BUTTERFLY_SWAP
      default: out.lane[i] = in.lane[i]; break;
    }
  }
  return out;
}

static Vec128 eval_vxm(const Vec128& a, const Vec128& b, int vxm_op) {
  Vec128 out{};
  for (int i = 0; i < 16; i++) {
    int8_t sa = static_cast<int8_t>(a.lane[i]);
    int8_t sb = static_cast<int8_t>(b.lane[i]);
    int8_t res = 0;
    switch (vxm_op) {
      case 1:  res = sat_int8(static_cast<int32_t>(sa) + static_cast<int32_t>(sb)); break; // VXM_VADD
      case 2:  res = sat_int8(static_cast<int32_t>(sa) * static_cast<int32_t>(sb)); break; // VXM_VMUL
      case 4:  res = silu_lut_int8(sa); break;                                             // VXM_SILU_LUT
      case 5:  res = gelu_lut_int8(sa); break;                                             // VXM_GELU_LUT
      case 10: res = sat_int8(static_cast<int32_t>(sa) - static_cast<int32_t>(sb)); break; // VXM_SUB
      case 11: res = (sa >= sb) ? sa : sb; break;                                          // VXM_MAX_ELEM
      case 12: res = (sa <= sb) ? sa : sb; break;                                          // VXM_MIN_ELEM
      case 13: res = (sa <= 0) ? 0 : sa; break;                                            // VXM_RELU
      default: res = sa; break;
    }
    out.lane[i] = static_cast<uint8_t>(res);
  }
  return out;
}

static Vec128 eval_mxm_step(int chip, int is_east, const Vec128& act) {
  Vec128 out{};
  for (int c = 0; c < 16; c++) {
    int32_t delta = 0;
    for (int r = 0; r < 16; r++) {
      int8_t a_val = static_cast<int8_t>(act.lane[r]);
      int8_t w_val = g_mxm_wt[chip][is_east][r][c];
      delta += static_cast<int32_t>(a_val) * static_cast<int32_t>(w_val);
    }
    g_mxm_accum[chip][is_east][c] += delta;
    out.lane[c] = static_cast<uint8_t>(g_mxm_accum[chip][is_east][c] & 0xFF);
  }
  return out;
}

} // namespace

extern "C" {

void dpi_full_chip_reset() {
  std::memset(g_w_sram, 0, sizeof(g_w_sram));
  std::memset(g_e_sram, 0, sizeof(g_e_sram));
  std::memset(g_mxm_wt, 0, sizeof(g_mxm_wt));
  std::memset(g_mxm_accum, 0, sizeof(g_mxm_accum));
}

void dpi_ref_dma_write(int chip, int is_east, int bank, int addr, const svBitVecVal* data128) {
  int c = chip & 1;
  int b = bank & 3;
  int a = addr & 1023;
  Vec128 v = unpack_sv128(data128);
  if (is_east) g_e_sram[c][b][a] = v;
  else         g_w_sram[c][b][a] = v;
}

void dpi_ref_load_mxm_weight(int chip, int is_east, int row, const svBitVecVal* data128) {
  int c = chip & 1;
  int e = is_east & 1;
  int r = row & 15;
  Vec128 v = unpack_sv128(data128);
  for (int col = 0; col < 16; col++) {
    g_mxm_wt[c][e][r][col] = static_cast<int8_t>(v.lane[col]);
  }
}

void dpi_ref_clear_mxm_accum(int chip, int is_east) {
  int c = chip & 1;
  int e = is_east & 1;
  for (int col = 0; col < 16; col++) {
    g_mxm_accum[c][e][col] = 0;
  }
}

int dpi_ref_check_pipeline(
    int chip, int w_bank, int w_addr,
    int sxm_op, int sxm_shift, int bfly_mask,
    int vxm_op,
    int e_bank, int e_addr,
    const svBitVecVal* rtl_sxm_out,
    const svBitVecVal* rtl_vxm_out,
    const svBitVecVal* rtl_mxm_w_out,
    const svBitVecVal* rtl_mxm_e_out,
    int rtl_ecc_single_err, int exp_ecc_single_err) {
  int c = chip & 1;
  Vec128 mem_w_vec = g_w_sram[c][w_bank & 3][w_addr & 1023];
  Vec128 exp_sxm   = eval_sxm(mem_w_vec, sxm_op, sxm_shift, bfly_mask);
  Vec128 exp_vxm   = eval_vxm(exp_sxm, exp_sxm, vxm_op);
  Vec128 exp_mxm_w = eval_mxm_step(c, 0, exp_vxm);
  Vec128 exp_mxm_e = eval_mxm_step(c, 1, exp_mxm_w);
  g_e_sram[c][e_bank & 3][e_addr & 1023] = exp_mxm_e;

  Vec128 act_sxm   = unpack_sv128(rtl_sxm_out);
  Vec128 act_vxm   = unpack_sv128(rtl_vxm_out);
  Vec128 act_mxm_w = unpack_sv128(rtl_mxm_w_out);
  Vec128 act_mxm_e = unpack_sv128(rtl_mxm_e_out);

  g_total_checks++;
  g_pipeline_checks++;
  if (exp_ecc_single_err) g_ecc_checks++;

  bool ok = eq_vec128(act_sxm, exp_sxm) &&
            eq_vec128(act_vxm, exp_vxm) &&
            eq_vec128(act_mxm_w, exp_mxm_w) &&
            eq_vec128(act_mxm_e, exp_mxm_e) &&
            (rtl_ecc_single_err == exp_ecc_single_err);
  if (!ok) {
    g_mismatches++;
    std::printf("[DPI-FULL-CHIP-ERR] Pipeline mismatch chip=%d w=%d/%d sxm=%d vxm=%d ecc=%d/%d\n",
                c, w_bank, w_addr, sxm_op, vxm_op, rtl_ecc_single_err, exp_ecc_single_err);
    return 1;
  }
  return 0;
}

int dpi_ref_check_e_sram_readback(
    int chip, int e_bank, int e_addr,
    const svBitVecVal* rtl_readback_data,
    int rtl_ecc_single_err, int exp_ecc_single_err) {
  int c = chip & 1;
  Vec128 exp_vec = g_e_sram[c][e_bank & 3][e_addr & 1023];
  Vec128 act_vec = unpack_sv128(rtl_readback_data);
  g_total_checks++;
  if (exp_ecc_single_err) g_ecc_checks++;
  bool ok = eq_vec128(act_vec, exp_vec) && (rtl_ecc_single_err == exp_ecc_single_err);
  if (!ok) {
    g_mismatches++;
    std::printf("[DPI-FULL-CHIP-ERR] East SRAM readback mismatch chip=%d b=%d a=%d ecc=%d/%d\n",
                c, e_bank, e_addr, rtl_ecc_single_err, exp_ecc_single_err);
    return 1;
  }
  return 0;
}

int dpi_ref_check_barrier(
    int chip, int rtl_release_pulse, int rtl_release_cnt, int exp_release_cnt, int all_notified) {
  g_total_checks++;
  g_barrier_checks++;
  int exp_pulse = all_notified ? 1 : 0;
  bool ok = (rtl_release_pulse == exp_pulse) && (rtl_release_cnt == exp_release_cnt);
  if (!ok) {
    g_mismatches++;
    std::printf("[DPI-FULL-CHIP-ERR] Barrier mismatch chip=%d pulse=%d/%d cnt=%d/%d\n",
                chip, rtl_release_pulse, exp_pulse, rtl_release_cnt, exp_release_cnt);
    return 1;
  }
  return 0;
}

int dpi_ref_check_c2c_transfer(
    int nim_op, int delay_sel, int exp_flight,
    const svBitVecVal* c0_tx_data,
    const svBitVecVal* c1_local_data,
    const svBitVecVal* rtl_c1_stream_out,
    int rtl_deskew_cycles, int rtl_measured_skew, int rtl_crc_err) {
  Vec128 tx_v  = unpack_sv128(c0_tx_data);
  Vec128 loc_v = unpack_sv128(c1_local_data);
  Vec128 act_v = unpack_sv128(rtl_c1_stream_out);
  Vec128 exp_v = tx_v;
  if (nim_op == 5) { // NIM_ALLREDUCE_ADD
    for (int i = 0; i < 16; i++) {
      int32_t s = static_cast<int32_t>(static_cast<int8_t>(loc_v.lane[i])) +
                  static_cast<int32_t>(static_cast<int8_t>(tx_v.lane[i]));
      exp_v.lane[i] = static_cast<uint8_t>(sat_int8(s));
    }
  }
  int exp_skew = (delay_sel + 1) - exp_flight;
  g_total_checks++;
  g_c2c_checks++;
  bool ok = eq_vec128(act_v, exp_v) &&
            (rtl_deskew_cycles == exp_flight) &&
            (rtl_crc_err == 0) &&
            ((nim_op != 3) || (rtl_measured_skew == exp_skew));
  if (!ok) {
    g_mismatches++;
    std::printf("[DPI-FULL-CHIP-ERR] C2C mismatch op=%d delay=%d dsk_cyc=%d/%d skew=%d/%d crc=%d\n",
                nim_op, delay_sel, rtl_deskew_cycles, exp_flight, rtl_measured_skew, exp_skew, rtl_crc_err);
    return 1;
  }
  return 0;
}

int dpi_ref_check_cycle_invariants(
    int cycle_id, int coll_fault, int crc_err, int c0_ecc_dbl, int c1_ecc_dbl) {
  g_total_checks++;
  g_cycle_inv_checks++;
  if (coll_fault != 0 || crc_err != 0 || c0_ecc_dbl != 0 || c1_ecc_dbl != 0) {
    g_mismatches++;
    std::printf("[DPI-FULL-CHIP-ERR] Cycle %d invariant fault coll=%d crc=%d ecc2=%d/%d\n",
                cycle_id, coll_fault, crc_err, c0_ecc_dbl, c1_ecc_dbl);
    return 1;
  }
  return 0;
}

int dpi_get_status() {
  std::printf("[DPI-FULL-CHIP-SUMMARY] total_checks=%llu (cycle_inv=%llu pipe=%llu ecc=%llu barrier=%llu c2c=%llu) mismatches=%llu\n",
              static_cast<unsigned long long>(g_total_checks),
              static_cast<unsigned long long>(g_cycle_inv_checks),
              static_cast<unsigned long long>(g_pipeline_checks),
              static_cast<unsigned long long>(g_ecc_checks),
              static_cast<unsigned long long>(g_barrier_checks),
              static_cast<unsigned long long>(g_c2c_checks),
              static_cast<unsigned long long>(g_mismatches));
  return (g_total_checks > 0 && g_mismatches == 0) ? 0 : 1;
}

} // extern "C"
