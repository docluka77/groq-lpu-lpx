# Stage 14A: Accellera IEEE 1800.2-2020 UVM Verification Report (`groq_mxfp8_nvfp4_dot_engine`, `groq_c2c_serdes_pcs` & `groq_pcie_c2c_dma`)

## 1. Executive Summary
- **Target Phase-II RTL Modules**:
  - `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_mxfp8_nvfp4_dot_engine.sv` (NVIDIA Groq 3 LPX / Vera Rubin Microscaling `INT8_SYM`, `MXFP8_E4M3`, `MXFP8_E5M2`, `NVFP4_E2M1`, and `W4A8_MIXED` Dot-Product Engine with shared `E8M0` power-of-two block scales, zero-skip gating, and deterministic 2-stage pipeline into `INT32` & IEEE-754 `FP32`)
  - `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_c2c_serdes_pcs.sv` (High-Speed C2C 64B/66B Physical Coding Sublayer, Self-Synchronizing LFSR Scrambler/Descrambler, Link Training & RealSync Skew Calibration FSM, CRC-16-CCITT `0x1021`, and 4-Entry Go-Back-N Replay Buffer)
  - `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_pcie_c2c_dma.sv` (NVLink-C2C / PCIe Gen5 4-Entry Circular Scatter-Gather Descriptor Ring DMA Engine & Deterministic VLIW Admission Window Controller across `IMEM`, `SRAM_WEST`, `SRAM_EAST`, and `BCAST_BOTH`)
- **Verification Toolchain (`ict-eda-9`)**:
  - Simulator: **Verilator 5.054** (`--cc --exe --build --timing --coverage-line --coverage-toggle --coverage-user`)
  - UVM Library: **Accellera IEEE 1800.2-2020 UVM (`uvm-core-2020.3.1`)**
  - Golden Reference Model: **C++17 DPI-C Bit-Exact Reference (`dpi_lpx_mxfp8_dma_ref.cpp`)**
- **Overall Status**: **PASS** (Clean run exit code `0`, `0` UVM_ERROR, `0` UVM_FATAL, `0` mismatches across `3,600` cycles / `10,800` IP checks, `100.00%` functional covergroup coverage, `99.82%` aggregate RTL line coverage (`548/549`) and `99.09%` toggle/branch coverage (`7,818/7,890`), and non-vacuous `+INJECT_FAULT=1` rejection with `9,089` mismatches caught and exit code `1`).

---

## 2. UVM Architecture & Deliverables (`uvm_tb/uvm_lpx_mxfp8_dma/`)

| File | Role & Description |
| :--- | :--- |
| `lpx_mxfp8_dma_if.sv` | SystemVerilog interface & `lpx_mxfp8_dma_dut_wrap` connecting Accellera UVM to all 3 Phase-II RTL modules, with `+INJECT_FAULT=1` fault-injection logic |
| `dpi_lpx_mxfp8_dma_ref.cpp` | Cycle-accurate bit-exact C++17 DPI-C golden reference model (`dpi_dot_engine_step`, `dpi_serdes_pcs_step`, `dpi_pcie_dma_step`) |
| `uvm_lpx_mxfp8_dma_pkg.sv` | Complete IEEE 1800.2-2020 UVM package (`lpx_mxfp8_dma_seq_item`, `lpx_mxfp8_dma_sequencer`, `lpx_mxfp8_dma_sequence`, `lpx_mxfp8_dma_driver`, `lpx_mxfp8_dma_monitor`, `lpx_mxfp8_dma_agent`, `lpx_mxfp8_dma_cov_subscriber`, `lpx_mxfp8_dma_scoreboard`, `lpx_mxfp8_dma_env`, `lpx_mxfp8_dma_test`) |
| `tb_uvm_lpx_mxfp8_dma.sv` | Top-level testbench module registering `virtual lpx_mxfp8_dma_if` via `uvm_config_db` and invoking `run_test("lpx_mxfp8_dma_test")` |
| `sim_main.cpp` | Verilator 5.054 C++ `VerilatedContext` event loop writing `coverage.dat` and returning `dpi_get_status()` |
| `run_uvm_lpx_mxfp8_dma.sh` | End-to-end build, clean simulation (`uvm_lpx_mxfp8_dma.log`), LCOV export (`coverage.info`, `lcov_summary.txt`), and `+INJECT_FAULT=1` qualification (`fault_injection_qual.log`) |

---

## 3. Stimulus Phases & Quantitative Results (`3,600` Cycles)

1. **Phase 0 (Cycles `0..799`)**: Directed + corner-case sweep across all 5 `MXFP8`/`NVFP4` precision modes (`INT8_SYM`, `MXFP8_E4M3`, `MXFP8_E5M2`, `NVFP4_E2M1`, `W4A8_MIXED`), zero block scale (`8'h00`), zero-skip lane counts (`0..16` and `0..32`), `E4M3`/`E5M2` subnormals, `NaN`/`Inf` injection, and positive/negative accumulator saturation; PCS Link Training FSM (`RESET -> TS1 -> TS2 -> LOCK -> ACTIVE -> RETRAIN`), 1-bit & multi-bit CRC-16 errors, sync errors, and Go-Back-N NACK replay; DMA ring fill-to-full (`desc_count == 4`), all 4 DMA targets (`IMEM`, `SRAM_WEST`, `SRAM_EAST`, `BCAST`), VLIW busy window stalls, and parity errors.
2. **Phase 1 (Cycles `800..1599`)**: Intensive PCS scrambled/unscrambled 128-bit streaming, multi-entry Go-Back-N replay recovery, RealSync skew calibration, and mixed-precision dot-product accumulation.
3. **Phase 2 (Cycles `1600..2399`)**: Intensive DMA scatter-gather ring stress, VLIW contention window stalls (`vliw_sram_busy_i`, `vliw_sram_w_busy_i`, `vliw_sram_e_busy_i`, `vliw_active_window_i`), strided multi-beat burst transfers, and parity error rejection.
4. **Phase 3 (Cycles `2400..3599`)**: `1,200` cycles of high-entropy constrained-random full-toggle stress across all 3 IP blocks simultaneously.

### Summary Comparison (`clean` vs. `+INJECT_FAULT=1`)

| Metric | Clean Run (`uvm_lpx_mxfp8_dma.log`) | Fault-Injected Run (`fault_injection_qual.log`) |
| :--- | :---: | :---: |
| Exit Code | `0` (PASS) | `1` (Expected Rejection) |
| Driven / Observed / Checked Cycles | `3,600 / 3,600 / 3,600` | `3,600 / 3,600 / 3,600` |
| C++17 DPI-C Reference Calls | `3,600` (`10,800` IP checks) | `3,600` (`10,800` IP checks) |
| Dot Zero-Skip / NaN-Inf Events | `1,523 / 466` | `1,523 / 466` |
| PCS Go-Back-N Replay / CRC-16 Error Events | `145 / 147` | `145 / 147` |
| DMA VLIW Window Stall / Parity Error Events | `324 / 96` | `324 / 96` |
| Scoreboard Mismatches | **`0`** | **`9,089`** (`3,505 DOT` + `3,548 PCS` + `2,036 DMA`) |
| Functional Covergroup (`lpx_mxfp8_dma_cg`) | **`100.00%`** | **`100.00%`** |
| LCOV `rtl/groq_mxfp8_nvfp4_dot_engine.sv` | **`244/244` (`100.00%`) Line / `98.81%` Toggle** | **`244/244` (`100.00%`) Line** |
| LCOV `rtl/groq_c2c_serdes_pcs.sv` | **`185/186` (`99.46%`) Line / `99.44%` Toggle** | **`185/186` (`99.46%`) Line** |
| LCOV `rtl/groq_pcie_c2c_dma.sv` | **`119/119` (`100.00%`) Line / `98.99%` Toggle** | **`119/119` (`100.00%`) Line** |
| **Aggregate Phase-II RTL Coverage** | **`548/549` (`99.82%`) Line / `7,818/7,890` (`99.09%`) Toggle** | **`548/549` (`99.82%`) Line** |
