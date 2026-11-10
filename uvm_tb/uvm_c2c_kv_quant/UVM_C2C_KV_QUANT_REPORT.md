# Stage 24: Accellera IEEE 1800.2-2020 UVM Verification Suite 9 (`uvm_c2c_kv_quant`) Report

## 1. Executive Summary
- **Suite Name**: `uvm_c2c_kv_quant` (Suite 9)
- **Simulator & UVM Library**: Verilator `5.054` (`--timing --coverage-line --coverage-toggle --coverage-user`) + Accellera IEEE 1800.2-2020 `uvm-core-2020.3.1`
- **DUTs Verified in Closed-Loop Round-Trip**:
  1. `rtl/groq_c2c_kv_quant_rx_engine.sv` (DUT 1: 16-Lane NVLink-C2C Prefill-to-Decode KV-Cache Disaggregation Receiver & On-the-Fly BF16/FP16 -> MXFP8/NVFP4 Microscaling Block Quantizer, 1-cycle registered)
  2. `rtl/groq_mxfp8_nvfp4_dot_engine.sv` (DUT 2: 16-Lane / 32-Sublane OCP MXFP8 E4M3/E5M2 & NVFP4 E2M1 Microscaling Dot-Product Engine connected directly in closed-loop round-trip to `quant_vec_o[127:0]` and `scale_e8m0_o[7:0]` of DUT 1, 2-cycle pipelined)

## 2. Clean Verification Metrics (`uvm_c2c_kv_quant_clean.log`)
| Metric | Value | Status |
|---|---|---|
| **Driven / Observed / Checked Cycles** | `3,600 / 3,600 / 3,600` | PASS |
| **DUT 1 (`groq_c2c_kv_quant_rx_engine`) Checks** | `3,600` (`0` mismatches) | PASS |
| **DUT 2 (`groq_mxfp8_nvfp4_dot_engine`) Closed-Loop Checks** | `3,600` (`0` mismatches) | PASS |
| **NaN/Inf Clamping Events Verified** | `511` | PASS |
| **All-Zero Vector Events Verified** | `21` | PASS |
| **Non-Zero Closed-Loop Dot Products Verified** | `3,125` | PASS |
| **UVM Severity Counts** | `UVM_ERROR : 0`, `UVM_FATAL : 0` | PASS |
| **Functional Coverage (`c2c_kv_quant_cg`)** | `100.00%` | PASS |

## 3. Negative Fault-Injection Qualification (`+INJECT_FAULT=1`, `uvm_c2c_kv_quant_fault.log`)
| Metric | Value | Status |
|---|---|---|
| **Exit Code** | `1` (Non-zero as required) | PASS |
| **Total Mismatches Caught** | `7,200` (`3,600` KV quantizer + `3,600` closed-loop dot engine) | PASS |
| **UVM Severity Counts** | `UVM_ERROR : 10` (throttled), `UVM_FATAL : 1` (`UVM_C2C_KV_QUANT_FAIL`) | PASS |

## 4. Verilator LCOV Line & Toggle/Branch Coverage (`cov.info` / `lcov_summary.txt`)
| RTL Module | LCOV Line Coverage | LCOV Toggle/Branch Coverage |
|---|---|---|
| `groq_c2c_kv_quant_rx_engine.sv` | `137 / 141` (`97.16%`) | `4,362 / 4,362` (`100.00%`) |
| `groq_mxfp8_nvfp4_dot_engine.sv` | `241 / 244` (`98.77%`) | `2,809 / 2,860` (`98.22%`) |
| **TOTAL (Stage 24 Closed-Loop RTL)** | **`378 / 385` (`98.18%`)** | **`7,171 / 7,222` (`99.29%`)** |
