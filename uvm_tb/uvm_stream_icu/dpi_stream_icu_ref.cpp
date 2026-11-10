// =============================================================================
// File: uvm_tb/uvm_stream_icu/dpi_stream_icu_ref.cpp
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Cycle-Accurate C++17 DPI-C Reference Model for groq_stream_fabric
//              and groq_icu_slice (8 spatial slices, 16 East + 16 West 128-bit
//              streams, NOP_DELAY timers, SYNC/NOTIFY barrier, RealSync deskew).
// =============================================================================
#include <cstdint>
#include <cstring>
#include <cstdlib>

namespace {

constexpr int kNumSlices = 8;
constexpr int kNumStreams = 16;
constexpr int kSliceIcu = 5;
constexpr int kMaxDriftCyc = 64;

enum IcuOp : uint32_t {
  ICU_NOP          = 0,
  ICU_NOP_DELAY    = 1,
  ICU_SYNC_BARRIER = 2,
  ICU_NOTIFY       = 3,
  ICU_JUMP_IMM     = 4,
  ICU_REALSYNC_ADJ = 5,
  ICU_HALT         = 6
};

struct RefState {
  uint16_t east_valid_q[kNumSlices];
  uint64_t east_data_lo_q[kNumSlices][kNumStreams];
  uint64_t east_data_hi_q[kNumSlices][kNumStreams];

  uint16_t west_valid_q[kNumSlices];
  uint64_t west_data_lo_q[kNumSlices][kNumStreams];
  uint64_t west_data_hi_q[kNumSlices][kNumStreams];

  uint8_t  collision_sticky_q;
  uint16_t gated_hop_count_q;

  uint16_t pc_slice_q[kNumSlices];
  uint8_t  nop_active_q[kNumSlices];
  uint16_t nop_timer_q[kNumSlices];
  uint8_t  barrier_waiting_q[kNumSlices];
  uint8_t  sync_mask_q[kNumSlices];
  uint8_t  notify_latched_q[kNumSlices];
  uint8_t  slice_halted_q[kNumSlices];

  uint64_t realsync_cycle_cnt_q;
  int16_t  realsync_deskew_q;
  uint16_t barrier_release_cnt_q;
};

struct CycleInputs {
  uint8_t  icu_enable;
  uint8_t  slice_notify_ready;
  uint8_t  realsync_ext_adj_en;
  int16_t  realsync_ext_adj_val;

  uint8_t  icu_op[kNumSlices];
  uint8_t  sync_mask[kNumSlices];
  uint16_t nop_cnt[kNumSlices];
  uint16_t imm16[kNumSlices];

  uint16_t east_inj_en[kNumSlices];
  uint16_t east_ovw_en[kNumSlices];
  uint16_t east_con_en[kNumSlices];
  uint64_t east_seed[kNumSlices];

  uint16_t west_inj_en[kNumSlices];
  uint16_t west_ovw_en[kNumSlices];
  uint16_t west_con_en[kNumSlices];
  uint64_t west_seed[kNumSlices];
};

struct CombOutputs {
  uint16_t collision_east[kNumSlices];
  uint16_t collision_west[kNumSlices];
  uint8_t  collision_any;

  uint16_t east_hop_valid[kNumSlices];
  uint64_t east_hop_lo[kNumSlices][kNumStreams];
  uint64_t east_hop_hi[kNumSlices][kNumStreams];

  uint16_t west_hop_valid[kNumSlices];
  uint64_t west_hop_lo[kNumSlices][kNumStreams];
  uint64_t west_hop_hi[kNumSlices][kNumStreams];

  uint8_t  slice_entering_sync[kNumSlices];
  uint8_t  slice_sync_active[kNumSlices];
  uint8_t  imem_fetch_en;
  uint8_t  slice_vliw_valid;
  uint8_t  barrier_ready_mask;
  uint8_t  barrier_release_pulse;
  uint64_t realsync_aligned_time;
  uint8_t  realsync_drift_fault;
};

RefState g_state{};
CycleInputs g_in{};
CombOutputs g_comb{};
uint32_t g_dpi_calls = 0;
int g_status = 2; // Default non-zero so missing report phase never passes

} // namespace
extern "C" void dpi_set_status(int status) { g_status = status; }
extern "C" int  dpi_get_status() { return g_status; }
extern "C" unsigned int dpi_get_calls() { return g_dpi_calls; }

extern "C" void dpi_ref_reset() {
  std::memset(&g_state, 0, sizeof(g_state));
  std::memset(&g_in, 0, sizeof(g_in));
  std::memset(&g_comb, 0, sizeof(g_comb));
}

extern "C" void dpi_ref_set_global_inputs(
    unsigned int icu_en,
    unsigned int notify_ready_mask,
    unsigned int realsync_ext_en,
    int realsync_ext_val) {
  g_in.icu_enable = static_cast<uint8_t>(icu_en & 1U);
  g_in.slice_notify_ready = static_cast<uint8_t>(notify_ready_mask & 0xFFU);
  g_in.realsync_ext_adj_en = static_cast<uint8_t>(realsync_ext_en & 1U);
  g_in.realsync_ext_adj_val = static_cast<int16_t>(realsync_ext_val);
}

extern "C" void dpi_ref_set_slice_inputs(
    int s,
    unsigned int icu_op,
    unsigned int sync_mask,
    unsigned int nop_cnt,
    unsigned int imm16,
    unsigned int east_inj_en,
    unsigned int east_ovw_en,
    unsigned int east_con_en,
    unsigned long long east_seed,
    unsigned int west_inj_en,
    unsigned int west_ovw_en,
    unsigned int west_con_en,
    unsigned long long west_seed) {
  if (s < 0 || s >= kNumSlices) return;
  g_in.icu_op[s]      = static_cast<uint8_t>(icu_op & 0xFU);
  g_in.sync_mask[s]   = static_cast<uint8_t>(sync_mask & 0xFFU);
  g_in.nop_cnt[s]     = static_cast<uint16_t>(nop_cnt & 0xFFFFU);
  g_in.imm16[s]       = static_cast<uint16_t>(imm16 & 0xFFFFU);
  g_in.east_inj_en[s] = static_cast<uint16_t>(east_inj_en & 0xFFFFU);
  g_in.east_ovw_en[s] = static_cast<uint16_t>(east_ovw_en & 0xFFFFU);
  g_in.east_con_en[s] = static_cast<uint16_t>(east_con_en & 0xFFFFU);
  g_in.east_seed[s]   = static_cast<uint64_t>(east_seed);
  g_in.west_inj_en[s] = static_cast<uint16_t>(west_inj_en & 0xFFFFU);
  g_in.west_ovw_en[s] = static_cast<uint16_t>(west_ovw_en & 0xFFFFU);
  g_in.west_con_en[s] = static_cast<uint16_t>(west_con_en & 0xFFFFU);
  g_in.west_seed[s]   = static_cast<uint64_t>(west_seed);
}

extern "C" void dpi_ref_eval_comb() {
  std::memset(&g_comb, 0, sizeof(g_comb));
  for (int s = 0; s < kNumSlices; ++s) {
    uint16_t e_val = g_state.east_valid_q[s];
    uint16_t e_inj = g_in.east_inj_en[s];
    uint16_t e_con = g_in.east_con_en[s];
    uint16_t e_ovw = g_in.east_ovw_en[s];
    g_comb.collision_east[s] = e_inj & e_val & (~e_con) & (~e_ovw);
    g_comb.east_hop_valid[s] = e_inj | (e_val & (~e_con));
    for (int c = 0; c < kNumStreams; ++c) {
      if ((e_inj >> c) & 1U) {
        g_comb.east_hop_lo[s][c] = g_in.east_seed[s] + static_cast<uint64_t>(c);
        g_comb.east_hop_hi[s][c] = g_in.east_seed[s] ^ (static_cast<uint64_t>(c) * 0x0101010101010101ULL);
      } else {
        g_comb.east_hop_lo[s][c] = g_state.east_data_lo_q[s][c];
        g_comb.east_hop_hi[s][c] = g_state.east_data_hi_q[s][c];
      }
    }

    uint16_t w_val = g_state.west_valid_q[s];
    uint16_t w_inj = g_in.west_inj_en[s];
    uint16_t w_con = g_in.west_con_en[s];
    uint16_t w_ovw = g_in.west_ovw_en[s];
    g_comb.collision_west[s] = w_inj & w_val & (~w_con) & (~w_ovw);
    g_comb.west_hop_valid[s] = w_inj | (w_val & (~w_con));
    for (int c = 0; c < kNumStreams; ++c) {
      if ((w_inj >> c) & 1U) {
        g_comb.west_hop_lo[s][c] = g_in.west_seed[s] + static_cast<uint64_t>(c);
        g_comb.west_hop_hi[s][c] = g_in.west_seed[s] ^ (static_cast<uint64_t>(c) * 0x0202020202020202ULL);
      } else {
        g_comb.west_hop_lo[s][c] = g_state.west_data_lo_q[s][c];
        g_comb.west_hop_hi[s][c] = g_state.west_data_hi_q[s][c];
      }
    }
    if (g_comb.collision_east[s] || g_comb.collision_west[s]) {
      g_comb.collision_any = 1U;
    }
  }
  uint8_t active_sync_mask = 0U;
  uint8_t any_sync_active = 0U;
  for (int s = 0; s < kNumSlices; ++s) {
    bool entering = g_in.icu_enable && !g_state.slice_halted_q[s] &&
                    !g_state.nop_active_q[s] && !g_state.barrier_waiting_q[s] &&
                    (g_in.icu_op[s] == ICU_SYNC_BARRIER);
    g_comb.slice_entering_sync[s] = entering ? 1U : 0U;
    g_comb.slice_sync_active[s] = (g_state.barrier_waiting_q[s] || entering) ? 1U : 0U;
    if (g_comb.slice_sync_active[s]) {
      any_sync_active = 1U;
      uint8_t m = g_state.barrier_waiting_q[s] ? g_state.sync_mask_q[s] : g_in.sync_mask[s];
      active_sync_mask |= static_cast<uint8_t>(m | (1U << s));
    }
    bool notify_op = g_in.icu_enable && !g_state.slice_halted_q[s] &&
                     !g_state.nop_active_q[s] && !g_state.barrier_waiting_q[s] &&
                     (g_in.icu_op[s] == ICU_NOTIFY);
    if (g_comb.slice_sync_active[s] || g_state.notify_latched_q[s] ||
        ((g_in.slice_notify_ready >> s) & 1U) || notify_op) {
      g_comb.barrier_ready_mask |= static_cast<uint8_t>(1U << s);
    }
    if (g_in.icu_enable && !g_state.slice_halted_q[s] &&
        !g_state.nop_active_q[s] && !g_state.barrier_waiting_q[s]) {
      g_comb.imem_fetch_en |= static_cast<uint8_t>(1U << s);
    }
    if (g_in.icu_enable && !g_state.slice_halted_q[s] &&
        !g_state.nop_active_q[s] && !g_comb.slice_sync_active[s]) {
      g_comb.slice_vliw_valid |= static_cast<uint8_t>(1U << s);
    }
  }
  g_comb.barrier_release_pulse =
      (any_sync_active && ((g_comb.barrier_ready_mask & active_sync_mask) == active_sync_mask)) ? 1U : 0U;

  int64_t sext_deskew = static_cast<int64_t>(g_state.realsync_deskew_q);
  g_comb.realsync_aligned_time = g_state.realsync_cycle_cnt_q + static_cast<uint64_t>(sext_deskew);
  int32_t abs_d = (g_state.realsync_deskew_q < 0) ? -static_cast<int32_t>(g_state.realsync_deskew_q)
                                                  : static_cast<int32_t>(g_state.realsync_deskew_q);
  g_comb.realsync_drift_fault = (abs_d > kMaxDriftCyc) ? 1U : 0U;
}

extern "C" void dpi_ref_step_seq() {
  ++g_dpi_calls;
  if (g_comb.collision_any) {
    g_state.collision_sticky_q = 1U;
  }
  if ((g_comb.east_hop_valid[0] & 1U) == 0U) {
    g_state.gated_hop_count_q = static_cast<uint16_t>(g_state.gated_hop_count_q + 1U);
  }
  for (int s = kNumSlices - 1; s >= 1; --s) {
    g_state.east_valid_q[s] = g_comb.east_hop_valid[s - 1];
    for (int c = 0; c < kNumStreams; ++c) {
      if ((g_comb.east_hop_valid[s - 1] >> c) & 1U) {
        g_state.east_data_lo_q[s][c] = g_comb.east_hop_lo[s - 1][c];
        g_state.east_data_hi_q[s][c] = g_comb.east_hop_hi[s - 1][c];
      }
    }
  }
  g_state.east_valid_q[0] = 0U;

  for (int s = 0; s < kNumSlices - 1; ++s) {
    g_state.west_valid_q[s] = g_comb.west_hop_valid[s + 1];
    for (int c = 0; c < kNumStreams; ++c) {
      if ((g_comb.west_hop_valid[s + 1] >> c) & 1U) {
        g_state.west_data_lo_q[s][c] = g_comb.west_hop_lo[s + 1][c];
        g_state.west_data_hi_q[s][c] = g_comb.west_hop_hi[s + 1][c];
      }
    }
  }
  g_state.west_valid_q[kNumSlices - 1] = 0U;

  g_state.realsync_cycle_cnt_q += 1ULL;
  if (g_comb.barrier_release_pulse) {
    g_state.barrier_release_cnt_q = static_cast<uint16_t>(g_state.barrier_release_cnt_q + 1U);
    for (int s = 0; s < kNumSlices; ++s) g_state.notify_latched_q[s] = 0U;
  } else {
    for (int s = 0; s < kNumSlices; ++s) {
      bool notify_op = g_in.icu_enable && !g_state.slice_halted_q[s] &&
                       !g_state.nop_active_q[s] && !g_state.barrier_waiting_q[s] &&
                       (g_in.icu_op[s] == ICU_NOTIFY);
      if (((g_in.slice_notify_ready >> s) & 1U) || notify_op) {
        g_state.notify_latched_q[s] = 1U;
      }
    }
  }
  if (g_in.realsync_ext_adj_en) {
    g_state.realsync_deskew_q = g_in.realsync_ext_adj_val;
  } else if (g_in.icu_enable && !g_state.slice_halted_q[kSliceIcu] &&
             !g_state.nop_active_q[kSliceIcu] && !g_comb.slice_sync_active[kSliceIcu] &&
             (g_in.icu_op[kSliceIcu] == ICU_REALSYNC_ADJ)) {
    g_state.realsync_deskew_q = static_cast<int16_t>(g_in.imm16[kSliceIcu]);
  }

  for (int s = 0; s < kNumSlices; ++s) {
    if (g_state.slice_halted_q[s]) {
      // Hold PC
    } else if (g_state.nop_active_q[s]) {
      if (g_state.nop_timer_q[s] > 1U) {
        g_state.nop_timer_q[s] = static_cast<uint16_t>(g_state.nop_timer_q[s] - 1U);
      } else {
        g_state.nop_active_q[s] = 0U;
        g_state.nop_timer_q[s] = 0U;
        g_state.pc_slice_q[s] = static_cast<uint16_t>(g_state.pc_slice_q[s] + 1U);
      }
    } else if (g_comb.slice_sync_active[s]) {
      if (g_comb.barrier_release_pulse) {
        g_state.barrier_waiting_q[s] = 0U;
        g_state.sync_mask_q[s] = 0U;
        g_state.pc_slice_q[s] = static_cast<uint16_t>(g_state.pc_slice_q[s] + 1U);
      } else {
        if (!g_state.barrier_waiting_q[s]) {
          g_state.sync_mask_q[s] = g_in.sync_mask[s];
        }
        g_state.barrier_waiting_q[s] = 1U;
      }
    } else if (g_in.icu_enable) {
      switch (g_in.icu_op[s]) {
        case ICU_NOP_DELAY:
          if (g_in.nop_cnt[s] > 0U) {
            g_state.nop_active_q[s] = 1U;
            g_state.nop_timer_q[s] = g_in.nop_cnt[s];
          } else {
            g_state.pc_slice_q[s] = static_cast<uint16_t>(g_state.pc_slice_q[s] + 1U);
          }
          break;
        case ICU_JUMP_IMM:
          g_state.pc_slice_q[s] = g_in.imm16[s];
          break;
        case ICU_HALT:
          g_state.slice_halted_q[s] = 1U;
          break;
        default:
          g_state.pc_slice_q[s] = static_cast<uint16_t>(g_state.pc_slice_q[s] + 1U);
          break;
      }
    }
  }
}

extern "C" unsigned int dpi_exp_east_valid(int s) { return g_state.east_valid_q[s]; }
extern "C" unsigned int dpi_exp_west_valid(int s) { return g_state.west_valid_q[s]; }
extern "C" unsigned long long dpi_exp_east_data_lo(int s, int c) { return g_state.east_data_lo_q[s][c]; }
extern "C" unsigned long long dpi_exp_east_data_hi(int s, int c) { return g_state.east_data_hi_q[s][c]; }
extern "C" unsigned long long dpi_exp_west_data_lo(int s, int c) { return g_state.west_data_lo_q[s][c]; }
extern "C" unsigned long long dpi_exp_west_data_hi(int s, int c) { return g_state.west_data_hi_q[s][c]; }
extern "C" unsigned int dpi_exp_collision_east(int s) { return g_comb.collision_east[s]; }
extern "C" unsigned int dpi_exp_collision_west(int s) { return g_comb.collision_west[s]; }
extern "C" unsigned int dpi_exp_collision_any() { return g_comb.collision_any; }
extern "C" unsigned int dpi_exp_collision_sticky() { return g_state.collision_sticky_q; }
extern "C" unsigned int dpi_exp_gated_hop_count() { return g_state.gated_hop_count_q; }
extern "C" unsigned int dpi_exp_pc_slice(int s) { return g_state.pc_slice_q[s]; }
extern "C" unsigned int dpi_exp_nop_timer(int s) { return g_state.nop_timer_q[s]; }
extern "C" unsigned int dpi_exp_slice_halted(int s) { return g_state.slice_halted_q[s]; }
extern "C" unsigned int dpi_exp_barrier_waiting(int s) { return g_state.barrier_waiting_q[s]; }
extern "C" unsigned int dpi_exp_imem_fetch_en() { return g_comb.imem_fetch_en; }
extern "C" unsigned int dpi_exp_slice_vliw_valid() { return g_comb.slice_vliw_valid; }
extern "C" unsigned int dpi_exp_barrier_ready_mask() { return g_comb.barrier_ready_mask; }
extern "C" unsigned int dpi_exp_barrier_release_pulse() { return g_comb.barrier_release_pulse; }
extern "C" unsigned int dpi_exp_barrier_release_cnt() { return g_state.barrier_release_cnt_q; }
extern "C" unsigned long long dpi_exp_realsync_cycle_cnt() { return g_state.realsync_cycle_cnt_q; }
extern "C" int dpi_exp_realsync_deskew() { return static_cast<int>(g_state.realsync_deskew_q); }
extern "C" unsigned long long dpi_exp_realsync_aligned_time() { return g_comb.realsync_aligned_time; }
extern "C" unsigned int dpi_exp_realsync_drift_fault() { return g_comb.realsync_drift_fault; }
