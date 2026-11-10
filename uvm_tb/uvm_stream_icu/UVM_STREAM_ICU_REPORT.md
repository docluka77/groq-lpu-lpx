# Stage 7A: Accellera IEEE 1800.2-2020 UVM Verification Report (`uvm_stream_icu`)

## 1. Executive Summary
- **DUT Modules Verified**: `rtl/groq_stream_fabric.sv` (8 spatial slices $\times$ 16 East + 16 West 128-bit superlanes) & `rtl/groq_icu_slice.sv` (8-slice independent VLIW PCs, `NOP_DELAY` timers, `SYNC_BARRIER`/`NOTIFY` hardware barrier, `RealSync` plesiochronous deskew engine).
- **Simulator & UVM Library**: Verilator 5.054 (`--timing --coverage-line --coverage-toggle --coverage-user`) + Accellera IEEE 1800.2-2020 UVM 2020.3.1 (`uvm_pkg.sv`).
- **Reference Model**: Cycle-accurate C++17 DPI-C reference model (`dpi_stream_icu_ref.cpp`) stepping in lockstep across all 8 spatial slices and 32 stream channels per slice.

## 2. Quantitative Verification & Coverage Metrics

| Metric | Result | Status |
|---|---|---|
| **Driven / Observed / Checked Cycles** | `2,200 / 2,200 / 2,200` | **PASS** |
| **C++17 DPI-C Reference Calls** | `2,200` (`70,400` per-slice checks) | **PASS** |
| **Clean Run Scoreboard Mismatches** | `0` (`UVM_ERROR: 0`, `UVM_FATAL: 0`) | **PASS** |
| **Functional Covergroup (`stream_icu_cg`)** | `100.00%` (`26 / 26` bins hit) | **PASS** |
| **RTL Line & Toggle Coverage (`groq_stream_fabric.sv`)** | `100.00%` (`63 / 63` annotated points hit) | **PASS** |
| **RTL Line & Toggle Coverage (`groq_icu_slice.sv`)** | `100.00%` (`133 / 133` annotated points hit) | **PASS** |
| **Fault-Injection Run (`+INJECT_STREAM_FAULT`)** | Caught (`STREAM_DATA_MISMATCH` @ `cyc=1`, `rc=1`) | **PASS (Non-Vacuous)** |
| **Fault-Injection Run (`+INJECT_BARRIER_FAULT`)** | Caught (`GLOBAL_ICU_STREAM_MISMATCH` @ `cyc=201`, `rc=1`) | **PASS (Non-Vacuous)** |

## 3. Functional Covergroup Breakdown (`26/26` Bins Hit)
- **`cp_icu_op` (7/7 bins)**: `op_nop` (8,102), `op_nop_delay` (2,325), `op_sync_barrier` (129), `op_notify` (4,498), `op_jump_imm` (2,264), `op_realsync_adj` (274), `op_halt` (8).
- **`cp_slice_hop` (8/8 bins)**: `slice_0`..`slice_7` (2,200 samples each across all 8 spatial slices).
- **`cp_stream_dir` (4/4 bins)**: `dir_idle` (1,658), `dir_east` (2,134), `dir_west` (2,929), `dir_both` (10,879).
- **`cp_collision` (2/2 bins)**: `no_collision` (16), `hit_collision` (17,584).
- **`cp_barrier_mask` (3/3 bins)**: `b_none` (17,471), `b_partial` (109), `b_all8` (20).
- **`cp_barrier_rel` (2/2 bins)**: `rel_0` (16,888), `rel_1` (712).

## 4. Hardware Bugs Discovered & Fixed in RTL
1. **`BUG-ICU-001` (`rtl/groq_icu_slice.sv`)**: Added per-slice `sync_mask_q[8][8]` register to preserve the barrier participation mask across multi-cycle `ICU_SYNC_BARRIER` stalls when `imem_fetch_en_o` is gated to `0` for SRAM power saving.
2. **`BUG-ICU-002` (`rtl/groq_icu_slice.sv`)**: Gated `ICU_NOTIFY` and `ICU_REALSYNC_ADJ` instruction decode with `~slice_halted_q` and `~barrier_waiting_q` so halted or waiting slices cannot trigger spurious barrier notifications or deskew updates.
- Both fixes were re-verified with Yosys 0.60 formal verification (`formal/prove_icu_slice.ys` ? `SUCCESS!`) and logged in `reports/BUG_LEDGER_AND_FIXES.md`.

## 5. Artifacts & Evidence Paths
- **UVM Interface & Wrapper**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_stream_icu/groq_stream_icu_if.sv`
- **UVM Package**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_stream_icu/groq_stream_icu_uvm_pkg.sv`
- **C++17 DPI-C Reference Model**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_stream_icu/dpi_stream_icu_ref.cpp`
- **Summary JSON**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_stream_icu/stream_icu_summary.json`
- **LCOV Coverage Info**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_stream_icu/results/clean/coverage_clean.info`
