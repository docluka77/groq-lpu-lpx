# Stage 7C: Accellera IEEE 1800.2-2020 UVM Verification Report (`groq_mxm_slice` & `groq_sxm_slice`)

## 1. Executive Summary
- **Target RTL Modules**:
  - `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_mxm_slice.sv` (16x16 Multi-Precision Wavefront Matrix Execution Module with Dual Ping-Pong Weight Staging Buffers, Concurrent Background Weight Pre-Loading, and Zero-Skip Operand Isolation)
  - `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_sxm_slice.sv` (16-Lane Spatial Switch / Shift / 16x16 Matrix Transpose / Butterfly / Bit-Reverse / Interleave Execution Module)
- **Verification Toolchain (`ict-eda-9`)**:
  - Simulator: **Verilator 5.054** (`--cc --exe --build --timing --coverage-line --coverage-toggle --coverage-user`)
  - UVM Library: **Accellera IEEE 1800.2-2020 UVM (`uvm-core-2020.3.1`)**
  - Golden Reference Model: **C++17 DPI-C Bit-Exact Reference (`dpi_mxm_sxm_ref.cpp`)**
- **Overall Status**: **PASS** (Clean run exit code `0`, `0` mismatches across `3,200` transactions / `6,400` slice checks, `100.00%` functional covergroup coverage, `100.00%` LCOV coverage on both `groq_mxm_slice.sv` (`160/160`) and `groq_sxm_slice.sv` (`70/70`), and non-vacuous `+INJECT_DUT_BUG` rejection with `5,387` mismatches caught and exit code `1`).

---

## 2. UVM Architecture & Deliverables (`uvm_tb/uvm_mxm_sxm/`)

| File | Lines | Role & Description |
| :--- | :---: | :--- |
| `groq_mxm_sxm_if.sv` | 121 | SystemVerilog interface & `groq_mxm_sxm_dut_wrap` connecting UVM to `groq_mxm_slice` and `groq_sxm_slice`, with `+INJECT_DUT_BUG` fault-injection logic |
| `groq_mxm_sxm_uvm_pkg.sv` | 757 | Complete IEEE 1800.2-2020 UVM package (`mxm_sxm_seq_item`, `mxm_sxm_sequencer`, `mxm_sxm_sequence`, `mxm_sxm_driver`, `mxm_sxm_monitor` + `mxm_sxm_cg`, `mxm_sxm_scoreboard`, `mxm_sxm_env`, `mxm_sxm_test`) |
| `dpi_mxm_sxm_ref.cpp` | 313 | Cycle-accurate bit-exact C++17 DPI-C reference model (`dpi_mxm_sxm_step`) modeling dual weight banks, background preloads, 5 precision modes, zero-skip gating, 2-stage MAC pipeline, and all 13 SXM opcodes |
| `tb_mxm_sxm_top.sv` | 32 | Top-level testbench module registering `virtual groq_mxm_sxm_if` via `uvm_config_db` and invoking `run_test("mxm_sxm_test")` |
| `sim_main.cpp` | 24 | Verilator 5.054 C++ `VerilatedContext` event loop writing `coverage.dat` and returning `dpi_get_status()` |
| `run_uvm_mxm_sxm.sh` | 59 | End-to-end build, clean simulation, LCOV export, and `+INJECT_DUT_BUG` negative-test qualification script |

---

## 3. Stimulus Phases & Quantitative Results (`3,200` Transactions)

1. **Phase 0 (Cycles `0..63`)**: Dual ping-pong weight bank staging (`MXM_LOAD_WEIGHT_B0` rows `0..15`, `MXM_LOAD_WEIGHT_B1` rows `0..15`), zero-cycle bank swap (`MXM_SWAP_WEIGHT`), concurrent background preload (`bg_wt_load_en_i`), `MXM_ACCUM_CLEAR`, `MXM_ACCUM_PRELOAD`, `MXM_ACCUM_FLUSH`, plus full 16x16 SXM transpose buffer load (`SXM_TRANSPOSE_LOAD`) and column readout (`SXM_TRANSPOSE_READ`).
2. **Phase 1 (Cycles `64..573`)**: Exhaustive cartesian sweep across all 5 MXM precision modes (`PREC_INT8`, `PREC_FP8_E4M3`, `PREC_FP8_E5M2`, `PREC_FP16`, `PREC_BF16`) $\times$ all 17 zero-skip lane counts (`0..16`, including FP8 `-0.0 = 8'h80` and half-zero 16-bit planar operands `16'h0300`) $\times$ `act_zero_gate_en` (`0, 1`) $\times$ active/background bank states.
3. **Phase 2 (Cycles `574..989`)**: Exhaustive cartesian sweep across all 13 SXM opcodes (`SXM_NOP`, `SXM_PASS`, `SXM_BARREL_ROTATE`, `SXM_TRANSPOSE_4X4`, `SXM_BIT_REVERSE`, `SXM_BROADCAST`, `SXM_INTERLEAVE`, `SXM_ROTATE_LEFT`, `SXM_ROTATE_RIGHT`, `SXM_REVERSE`, `SXM_TRANSPOSE_LOAD`, `SXM_TRANSPOSE_READ`, `SXM_BUTTERFLY_SWAP`) $\times$ all 16 shift/lane/mask/transpose indices (`0..15`) $\times$ RoPE sign negation (`0, 1`).
4. **Phase 3 (Cycles `990..3199`)**: `2,210` cycles of high-entropy full-toggle stress simultaneously exercising MXM systolic contraction, ping-pong swaps, background weight staging, and SXM permutations.

### Summary Comparison (`clean` vs. `dut_bug`)

| Metric | Clean Run (`results/clean/`) | Fault-Injected Run (`+INJECT_DUT_BUG`) |
| :--- | :---: | :---: |
| Exit Code | `0` (PASS) | `1` (Expected Rejection) |
| Driven / Observed / Checked Cycles | `3,200 / 3,200 / 3,200` | `3,200 / 3,200 / 3,200` |
| C++17 DPI-C Reference Calls | `3,200` | `3,200` |
| MXM Slice Checks / SXM Slice Checks | `3,200 / 3,200` | `3,200 / 3,200` |
| Zero-Skip Gating Events Verified | `774` | `774` |
| Ping-Pong Weight Bank Swaps Verified | `221` | `221` |
| Scoreboard Mismatches | **`0`** | **`5,387`** (`2,311 MXM` + `3,076 SXM`) |
| Functional Covergroup (`mxm_sxm_cg`) | **`100.00%`** | **`100.00%`** |
| LCOV `rtl/groq_mxm_slice.sv` Coverage | **`160 / 160` (`100.00%`)** | **`160 / 160` (`100.00%`)** |
| LCOV `rtl/groq_sxm_slice.sv` Coverage | **`70 / 70` (`100.00%`)** | **`70 / 70` (`100.00%`)** |

---

## 4. RTL Bug Discovered & Fixed (`BUG-MXM-001`)
- **`BUG-MXM-001` (`rtl/groq_mxm_slice.sv`)**: In 16-bit planar contraction modes (`PREC_FP16` and `PREC_BF16`), each 16-bit activation is formed across an even/odd lane pair `{iso_act_lane[2*k+1], iso_act_lane[2*k]}` and multiplied against `{iso_wt_mat[2*k+1][c], iso_wt_mat[2*k][c]}`. Previously, `lane_is_zero[r]` checked each 8-bit lane independently (`act_lane_raw[r] == 8'h00`) regardless of `prec_mode_i`. When a non-zero 16-bit activation had a zero low byte (e.g., `16'h0300`), `zero_skip_gate_mask_o[2*k]` asserted and zeroed `iso_wt_mat[2*k][c] = 8'h00`, corrupting the lower byte of the 16-bit weight pair.
- **Resolution**: Updated `lane_is_zero[r]` in `rtl/groq_mxm_slice.sv` so that in `PREC_FP16` / `PREC_BF16` modes, a lane pair `(2*(r/2)+1, 2*(r/2))` is zero-gated if and only if both bytes of the 16-bit operand are zero. Re-verified with Yosys 0.60 formal SAT proof (`SAT proof finished - no model found: SUCCESS!`) and logged in `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/reports/BUG_LEDGER_AND_FIXES.md`.
