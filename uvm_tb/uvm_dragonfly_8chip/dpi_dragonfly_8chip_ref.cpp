// =============================================================================
// File: uvm_tb/uvm_dragonfly_8chip/dpi_dragonfly_8chip_ref.cpp
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Cycle-Accurate C++17 DPI-C Golden Reference Model for Stage 14B
//              8-Chip Dragonfly Group Scale-Out Cluster (groq_dragonfly_8chip_cluster).
// =============================================================================
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include "svdpi.h"

namespace {

struct Vec128 {
 uint32_t w[4];
};

static uint32_t g_dpi_calls = 0;
static int g_sim_status = 1;

// Golden Cluster DMA State (4-entry circular ring)
static Vec128 g_dma_ring[4];
static uint8_t g_dma_head = 0;
static uint8_t g_dma_tail = 0;
static uint8_t g_dma_count = 0;
static bool g_dma_active = false;
static uint8_t g_dma_target = 0;
static uint8_t g_dma_sel = 0;
static uint16_t g_dma_addr = 0;
static uint8_t g_dma_stride = 0;
static uint8_t g_dma_rem_beats = 0;
static uint16_t g_dma_imem_upper = 0;
static bool g_dma_done_irq = false;
static uint8_t g_dma_comp_cnt = 0;
static uint16_t g_dma_beats_cnt = 0;

// Golden Per-Chip SRAM [8 chips][4 banks][1024 rows] (West & East)
static Vec128 g_sram_w[8][4][1024];
static Vec128 g_sram_e[8][4][1024];

// Golden PCS Link Training FSM State
static uint8_t g_pcs_state = 0; // 0=RESET,1=TS1,2=TS2,3=LOCK,4=ACTIVE,5=RETRAIN

// Golden Per-Chip Pipeline & C2C Replay State
static bool g_vliw_mem_w_busy[8];
static bool g_vliw_mem_e_busy[8];
static bool g_rd_pipe_w_val[8];
static bool g_rd_pipe_e_val[8];
static uint8_t g_lpu_tx_dst[8];
static Vec128 g_replay_data[8][4];
static uint8_t g_replay_dst[8][4];
static uint8_t g_replay_seq[8][4];
static bool g_replay_val[8][4];
static uint8_t g_tx_seq[8];
static bool g_replay_act[8];
static uint8_t g_replay_ptr[8];
static bool g_nack_in[8];
static uint8_t g_nack_seq_in[8];
static uint8_t g_last_src_for_dst[8];

// 1-Cycle Plesiochronous Link Delay Pipeline State
static bool g_dly_valid[8];
static Vec128 g_dly_data[8];
static uint8_t g_dly_dst[8];
static uint8_t g_dly_seq[8];
static bool g_dly_crc_err[8];

static inline Vec128 unpack128(const svBitVecVal* v) {
 Vec128 out;
 for (int i = 0; i < 4; i++) out.w[i] = v[i];
 return out;
}

static inline void pack128(svBitVecVal* dst, const Vec128& src) {
 for (int i = 0; i < 4; i++) dst[i] = src.w[i];
}

static inline uint16_t calc_parity16(const Vec128& d) {
 uint16_t p = 0;
 for (int i = 0; i < 16; i++) {
 uint8_t byte_v = static_cast<uint8_t>((d.w[i / 4] >> ((i % 4) * 8)) & 0xFFu);
 uint8_t par = 0;
 for (int b = 0; b < 8; b++) par ^= (byte_v >> b) & 1u;
 p |= static_cast<uint16_t>(par) << i;
 }
 return p;
}

static inline uint8_t calc_dragonfly_dst_cpp(
  uint8_t src_chip,
  uint8_t req_dst,
  uint8_t mode,
  bool    ring_west,
  bool    congested,
  uint8_t bstage
) {
  switch (mode & 0x3u) {
    case 0: return req_dst & 0x7u;
    case 1: return ring_west ? ((src_chip + 7u) & 0x7u) : ((src_chip + 1u) & 0x7u);
    case 2: return (congested && ((src_chip & 0x7u) != (req_dst & 0x7u)))
                   ? ((src_chip ^ 4u) & 0x7u)
                   : (req_dst & 0x7u);
    case 3: return (src_chip ^ (bstage & 0x7u)) & 0x7u;
    default: return req_dst & 0x7u;
  }
}

static const uint8_t kPosMap[64] = {
  3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21,
  22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 33, 34, 35, 36, 37, 38,
  39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54,
  55, 56, 57, 58, 59, 60, 61, 62, 63, 65, 66, 67, 68, 69, 70, 71
};

static inline void eval_secded_mask72(uint64_t mask_lo64, uint8_t mask_hi8, bool& single_err, bool& double_err) {
  uint8_t syn_low = mask_hi8 & 0x7Fu;
  for (int i = 0; i < 64; i++) {
    if ((mask_lo64 >> i) & 1ULL) {
      syn_low ^= (kPosMap[i] & 0x7Fu);
    }
  }
  uint64_t p64 = __builtin_popcountll(mask_lo64) & 1ULL;
  uint32_t p8  = __builtin_popcount(mask_hi8 & 0xFFu) & 1u;
  bool overall_par = (p64 ^ p8) != 0;
  single_err = overall_par;
  double_err = (!overall_par) && (syn_low != 0);
}

} // namespace

extern "C" {

void dpi_dragonfly_8chip_reset() {
 std::memset(g_dma_ring, 0, sizeof(g_dma_ring));
 g_dma_head = 0;
 g_dma_tail = 0;
 g_dma_count = 0;
 g_dma_active = false;
 g_dma_target = 0;
 g_dma_sel = 0;
 g_dma_addr = 0;
 g_dma_stride = 0;
 g_dma_rem_beats = 0;
 g_dma_imem_upper = 0;
 g_dma_done_irq = false;
 g_dma_comp_cnt = 0;
 g_dma_beats_cnt = 0;
 std::memset(g_sram_w, 0, sizeof(g_sram_w));
 std::memset(g_sram_e, 0, sizeof(g_sram_e));
 g_pcs_state = 0;
 for (int c = 0; c < 8; c++) {
 g_vliw_mem_w_busy[c] = false;
 g_vliw_mem_e_busy[c] = false;
 g_rd_pipe_w_val[c] = false;
 g_rd_pipe_e_val[c] = false;
 g_lpu_tx_dst[c] = 0;
 g_tx_seq[c] = 0;
 g_replay_act[c] = false;
 g_replay_ptr[c] = 0;
 g_nack_in[c] = false;
 g_nack_seq_in[c] = 0;
 g_last_src_for_dst[c] = c ^ 1;
 g_dly_valid[c] = false;
 g_dly_dst[c] = 0;
 g_dly_seq[c] = 0;
 g_dly_crc_err[c] = false;
 std::memset(&g_dly_data[c], 0, sizeof(Vec128));
 for (int r = 0; r < 4; r++) {
 std::memset(&g_replay_data[c][r], 0, sizeof(Vec128));
 g_replay_dst[c][r] = 0;
 g_replay_seq[c][r] = 0;
 g_replay_val[c][r] = false;
 }
 }
}

uint32_t dpi_get_calls() { return g_dpi_calls; }
int      dpi_get_status() { return g_sim_status; }
void     dpi_set_status(int status) { g_sim_status = status; }

void dpi_dragonfly_8chip_step(
  uint32_t global_cycle_i,
  uint32_t dma_target_chip_i,
  uint32_t dma_bcast_all_chips_i,
  uint32_t dma_vliw_sram_busy_i,
  uint32_t vliw_mem_w_busy_mask_i,
  uint32_t vliw_mem_e_busy_mask_i,
  uint32_t dma_desc_push_valid_i,
  const svBitVecVal* dma_desc_push_data_i,
  uint32_t dma_payload_valid_i,
  const svBitVecVal* dma_payload_data_i,
  uint32_t dma_payload_parity_i,
  uint32_t cluster_route_mode_i,
  uint32_t ring_dir_west_i,
  uint32_t congestion_mask_i,
  uint32_t butterfly_stage_i,
  uint32_t pcs_link_enable_i,
  uint32_t pcs_rx_ts1_seen_i,
  uint32_t pcs_rx_ts2_seen_i,
  uint32_t pcs_deskew_done_i,
  uint32_t pcs_retrain_req_i,
  uint32_t nim_send_valid_mask_i,
  uint32_t nim_send_dst_packed_i,
  uint32_t mem_rd_w_mask_i,
  uint32_t mem_rd_e_mask_i,
  uint32_t mem_err_inject_en_i,
  const svBitVecVal* mem_err_inject_mask_i,
  uint32_t* exp_dma_desc_ready_o,
  uint32_t* exp_dma_pay_ready_o,
  uint32_t* exp_dma_busy_o,
  uint32_t* exp_dma_window_stall_o,
  uint32_t* exp_dma_parity_err_o,
  uint32_t* exp_dma_done_irq_o,
  uint32_t* exp_dma_completed_desc_cnt_o,
  uint32_t* exp_dma_beats_transferred_o,
  uint32_t* exp_pcs_link_up_o,
  uint32_t* exp_routed_dst_packed_o,
  uint32_t* exp_ecc_single_err_o,
  uint32_t* exp_ecc_double_err_o
) {
  g_dpi_calls++;

  // 1. Evaluate Combinational Cluster DMA Outputs before Clock Edge
  bool full  = (g_dma_count == 4);
  bool empty = (g_dma_count == 0);
  Vec128 head_desc = g_dma_ring[g_dma_head & 0x3u];
  uint8_t  head_target    = head_desc.w[0] & 0x3u;
  uint8_t  head_sel       = (head_desc.w[0] >> 2) & 0x7u;
  uint16_t head_base_addr = (head_desc.w[0] >> 8) & 0xFFFFu;
  uint8_t  head_stride    = (head_desc.w[0] >> 24) & 0xFFu;
  uint8_t  raw_burst      = head_desc.w[1] & 0xFFu;
  uint8_t  head_burst_len = (raw_burst == 0) ? 1u : raw_burst;
  uint16_t head_sched_cyc = (head_desc.w[1] >> 8) & 0xFFFFu;
  uint16_t head_imem_up   = (head_desc.w[1] >> 24) | ((head_desc.w[2] & 0xFFu) << 8);
  bool head_sched_ready   = (!empty) && ((global_cycle_i & 0xFFFFu) >= head_sched_cyc);

  bool cluster_w_busy = dma_bcast_all_chips_i
                        ? ((vliw_mem_w_busy_mask_i & 0xFFu) != 0)
                        : (((vliw_mem_w_busy_mask_i >> (dma_target_chip_i & 0x7u)) & 1u) != 0);
  bool cluster_e_busy = dma_bcast_all_chips_i
                        ? ((vliw_mem_e_busy_mask_i & 0xFFu) != 0)
                        : (((vliw_mem_e_busy_mask_i >> (dma_target_chip_i & 0x7u)) & 1u) != 0);
  bool cluster_any_busy = (dma_vliw_sram_busy_i != 0) || cluster_w_busy || cluster_e_busy;

  bool tgt_is_w = (g_dma_target == 1u) || (g_dma_target == 3u);
  bool tgt_is_e = (g_dma_target == 2u) || (g_dma_target == 3u);
  bool w_blocked = tgt_is_w && (cluster_any_busy || cluster_w_busy || (dma_vliw_sram_busy_i != 0));
  bool e_blocked = tgt_is_e && (cluster_any_busy || cluster_e_busy || (dma_vliw_sram_busy_i != 0));
  bool sram_blocked = w_blocked || e_blocked;

  Vec128 pay_data = unpack128(dma_payload_data_i);
  bool parity_err = (dma_payload_valid_i != 0) &&
                    (calc_parity16(pay_data) != (dma_payload_parity_i & 0xFFFFu));
  bool beat_fire  = g_dma_active && (dma_payload_valid_i != 0) && (!sram_blocked) && (!parity_err);

  *exp_dma_desc_ready_o         = full ? 0u : 1u;
  *exp_dma_pay_ready_o          = (g_dma_active && !sram_blocked) ? 1u : 0u;
  *exp_dma_busy_o               = g_dma_active ? 1u : 0u;
  *exp_dma_window_stall_o       = (g_dma_active && (dma_payload_valid_i != 0) && sram_blocked) ? 1u : 0u;
  *exp_dma_parity_err_o         = parity_err ? 1u : 0u;
  *exp_dma_done_irq_o           = g_dma_done_irq ? 1u : 0u;
  *exp_dma_completed_desc_cnt_o = g_dma_comp_cnt;
  *exp_dma_beats_transferred_o  = g_dma_beats_cnt;

  // 2. Evaluate PCS Link Up, Dragonfly Routed Destinations & SECDED ECC Outputs
  *exp_pcs_link_up_o = (g_pcs_state == 4u) ? 0xFFu : 0x00u;

  uint32_t routed_packed = 0;
  for (int c = 0; c < 8; c++) {
    bool cong = ((congestion_mask_i >> c) & 1u) != 0;
    uint8_t rdst = calc_dragonfly_dst_cpp(
      static_cast<uint8_t>(c),
      g_lpu_tx_dst[c],
      static_cast<uint8_t>(cluster_route_mode_i & 0x3u),
      ring_dir_west_i != 0,
      cong,
      static_cast<uint8_t>(butterfly_stage_i & 0x7u)
    );
    routed_packed |= (static_cast<uint32_t>(rdst & 0x7u) << (c * 3));
  }
  *exp_routed_dst_packed_o = routed_packed;

  // Evaluate 144-bit SECDED ECC mask (2 x 72-bit subwords)
  uint64_t m0_lo = static_cast<uint64_t>(mem_err_inject_mask_i[0]) |
                   (static_cast<uint64_t>(mem_err_inject_mask_i[1]) << 32);
  uint8_t  m0_hi = static_cast<uint8_t>(mem_err_inject_mask_i[2] & 0xFFu);
  uint64_t m1_lo = (static_cast<uint64_t>(mem_err_inject_mask_i[2]) >> 8) |
                   (static_cast<uint64_t>(mem_err_inject_mask_i[3]) << 24) |
                   (static_cast<uint64_t>(mem_err_inject_mask_i[4] & 0xFFu) << 56);
  uint8_t  m1_hi = static_cast<uint8_t>((mem_err_inject_mask_i[4] >> 8) & 0xFFu);

  bool s0_sec = false, s0_ded = false, s1_sec = false, s1_ded = false;
  eval_secded_mask72(m0_lo, m0_hi, s0_sec, s0_ded);
  eval_secded_mask72(m1_lo, m1_hi, s1_sec, s1_ded);
  bool mask_has_sec = s0_sec || s1_sec;
  bool mask_has_ded = s0_ded || s1_ded;

  uint32_t ecc_s_mask = 0;
  uint32_t ecc_d_mask = 0;
  for (int c = 0; c < 8; c++) {
    bool rd_active = g_rd_pipe_w_val[c] || g_rd_pipe_e_val[c];
    bool inj_en    = ((mem_err_inject_en_i >> c) & 1u) != 0;
    if (rd_active && inj_en && mask_has_sec) ecc_s_mask |= (1u << c);
    if (rd_active && inj_en && mask_has_ded) ecc_d_mask |= (1u << c);
  }
  *exp_ecc_single_err_o = ecc_s_mask;
  *exp_ecc_double_err_o = ecc_d_mask;

  // 3. Advance Sequential State (Posedge clk)
  g_dma_done_irq = false;
  bool do_push = (dma_desc_push_valid_i != 0) && (!full);
  bool do_pop  = (!g_dma_active) && head_sched_ready;
  if (do_push) {
    g_dma_ring[g_dma_tail & 0x3u] = unpack128(dma_desc_push_data_i);
    g_dma_tail = (g_dma_tail + 1u) & 0x3u;
  }
  if (do_pop) {
    g_dma_head = (g_dma_head + 1u) & 0x3u;
  }
  if (do_push && !do_pop) g_dma_count++;
  else if (!do_push && do_pop) g_dma_count--;

  if (beat_fire) {
    uint8_t bank = g_dma_sel & 0x3u;
    uint16_t row = g_dma_addr & 0x3FFu;
    for (int c = 0; c < 8; c++) {
      bool sel = (dma_bcast_all_chips_i != 0) || ((dma_target_chip_i & 0x7u) == static_cast<uint32_t>(c));
      if (sel && tgt_is_w && !w_blocked) g_sram_w[c][bank][row] = pay_data;
      if (sel && tgt_is_e && !e_blocked) g_sram_e[c][bank][row] = pay_data;
    }
  }

  if (do_pop) {
    g_dma_active     = true;
    g_dma_target     = head_target;
    g_dma_sel        = head_sel;
    g_dma_addr       = head_base_addr;
    g_dma_stride     = head_stride;
    g_dma_rem_beats  = head_burst_len;
    g_dma_imem_upper = head_imem_up;
  } else if (beat_fire) {
    g_dma_beats_cnt = static_cast<uint16_t>(g_dma_beats_cnt + 1u);
    if (g_dma_rem_beats <= 1u) {
      g_dma_active    = false;
      g_dma_rem_beats = 0;
      g_dma_done_irq  = true;
      g_dma_comp_cnt  = static_cast<uint8_t>(g_dma_comp_cnt + 1u);
    } else {
      g_dma_addr      = static_cast<uint16_t>(g_dma_addr + g_dma_stride);
      g_dma_rem_beats = static_cast<uint8_t>(g_dma_rem_beats - 1u);
    }
  }

  // Advance PCS Link Training FSM
  if (!pcs_link_enable_i) {
    g_pcs_state = 0u;
  } else {
    switch (g_pcs_state) {
      case 0u: g_pcs_state = 1u; break;
      case 1u: if (pcs_rx_ts1_seen_i) g_pcs_state = 2u; break;
      case 2u: if (pcs_rx_ts2_seen_i) g_pcs_state = 3u; break;
      case 3u: if (pcs_deskew_done_i) g_pcs_state = 4u; break;
      case 4u: if (pcs_retrain_req_i) g_pcs_state = 5u; break;
      case 5u: g_pcs_state = 1u; break;
      default: g_pcs_state = 0u; break;
    }
  }

  for (int c = 0; c < 8; c++) {
    g_rd_pipe_w_val[c] = ((mem_rd_w_mask_i >> c) & 1u) != 0;
    g_rd_pipe_e_val[c] = ((mem_rd_e_mask_i >> c) & 1u) != 0;
    if ((nim_send_valid_mask_i >> c) & 1u) {
      g_lpu_tx_dst[c] = (nim_send_dst_packed_i >> (c * 3)) & 0x7u;
    }
  }
}

uint32_t dpi_check_c2c_rx_from_sram(
  uint32_t src_chip,
  uint32_t sram_bank,
  uint32_t sram_row,
  const svBitVecVal* act_rx_data_i
) {
  Vec128 exp = g_sram_w[src_chip & 0x7u][sram_bank & 0x3u][sram_row & 0x3FFu];
  Vec128 act = unpack128(act_rx_data_i);
  for (int w = 0; w < 4; w++) {
    if (exp.w[w] != act.w[w]) return 0u;
  }
  return 1u;
}

} // extern "C"
