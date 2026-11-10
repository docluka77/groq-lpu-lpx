# Stage 7D: Accellera IEEE 1800.2-2020 UVM Verification Report (`uvm_vxm_nim`)

## 1. Executive Summary

| Metric | Value | Status |
|---|---|---|
| **DUT Modules Verified** | `rtl/groq_vxm_slice.sv`, `rtl/groq_nim_realsync.sv` | **Verified** |
| **UVM Standard & Library** | Accellera IEEE 1800.2-2020 (`uvm-core-2020.3.1`) | **Active** |
| **Simulator** | Verilator 5.054 (`--cc --exe --build --timing --coverage-line --coverage-toggle --coverage-user`) | **Active** |
| **Reference Model** | Cycle-Accurate Bit-Exact C++17 DPI-C (`dpi_vxm_nim_ref.cpp`) | **Active** |
| **Total Transactions Driven** | **3,200** (Phase 1: 640, Phase 2: 640, Phase 3: 640, Phase 4: 1,280) | **>= 3,000 Gate Met** |
| **Observed & DPI-Checked Cycles** | **3,200 / 3,200** (`vxm_slice_checks = 3,200`, `nim_realsync_checks = 3,200`) | **100% Checked** |
| **Clean Run Mismatches** | **0** (`exit_code = 0`) | **PASS** |
| **Fault-Injection (`+INJECT_DUT_BUG`)** | **4,905 mismatches caught** (`exit_code = 1`) | **PASS (Properly Rejected)** |
| **UVM Functional Coverage (`vxm_nim_cg`)** | **100.00%** across all 10 coverpoints | **PASS** |
| **LCOV Line Coverage (`groq_nim_realsync.sv`)** | **99.45%** (`182 / 183` lines) | **PASS** |
| **LCOV Line Coverage (`groq_vxm_slice.sv`)** | **98.70%** (`228 / 231` lines) | **PASS** |
| **LCOV Line Coverage (`groq_vxm_nim_if.sv`)** | **100.00%** (`54 / 54` lines) | **PASS** |

---

## 2. Verification Architecture & Stimulus Phases (`uvm_tb/uvm_vxm_nim/`)

- **`groq_vxm_nim_if.sv`**: SystemVerilog interface and `groq_vxm_nim_dut_wrap` connecting `groq_vxm_slice` (Hop 3 16-lane SIMD + Nonlinear LUT + 4-level reduction trees + dynamic quantizer) and `groq_nim_realsync` (Hop 0 Dragonfly C2C router + plesiochronous `RealSync` 4-slot elastic deskew buffer + hardware CRC-8 engine), including `+INJECT_DUT_BUG` output corruption qualification.
- **`groq_vxm_nim_uvm_pkg.sv`**: Full Accellera IEEE 1800.2-2020 UVM environment (`vxm_nim_seq_item`, `vxm_nim_sequencer`, `vxm_nim_sequence`, `vxm_nim_driver`, `vxm_nim_monitor` + `vxm_nim_cg` covergroup, `vxm_nim_scoreboard`, `vxm_nim_env`, `vxm_nim_test`):
  - **Phase 1 (640 cycles)**: Directed sweep of all 16 VXM opcodes (`VXM_NOP`, `VXM_ADD`, `VXM_SUB`, `VXM_MUL`, `VXM_FMA`, `VXM_MAX_ELEM`, `VXM_MIN_ELEM`, `VXM_RELU`, `VXM_SILU`, `VXM_SWIGLU`, `VXM_GELU`, `VXM_EXP_LUT`, `VXM_RSQRT_LUT`, `VXM_REDUCE_SUM`, `VXM_REDUCE_MAX`, `VXM_QUANT_SCALE`) with saturation boundary vectors (`-128`, `+127`, `0`, `+1`, `-1`, `-64`, `+32`, `+64`), `INT32_MAX` (`32'h7FFF_FFF0`) 32-bit rounding boundary, `PREC_INT8` and `PREC_FP8_E4M3` quantizer modes across all `quant_shift_i` (`0..7`), `use_accum_32b_i` (`0, 1`), operand isolation gating (`mul_gate_active_o`, `lut_gate_active_o`), and all 8 NIM opcodes (`NIM_NOP`, `NIM_SEND`, `NIM_RECV`, `NIM_SYNC_BEACON`, `NIM_FORWARD`, `NIM_ALLREDUCE_ADD`, `NIM_DESKEW_CAL`, `NIM_LOOPBACK`).
  - **Phase 2 (640 cycles)**: Plesiochronous `RealSync` elastic deskew buffering stress across varying flight delays (`0..3` cycles), full-duplex simultaneous TX/RX deskew release (`1,597` deskew release events), and Dragonfly routing across `PORT_LOCAL_MIN` (`0`), `PORT_GLOBAL_MIN` (`1`), and `PORT_UGAL_PROXY` (`2`).
  - **Phase 3 (640 cycles)**: Link CRC-8 generation & verification + single-bit/multi-bit CRC fault injection (`466` corrupted C2C flits detected and isolated from deskew buffer & router datapaths).
  - **Phase 4 (1,280 cycles)**: Concurrent pseudo-random full-slice stress across all VXM and NIM opcodes.
- **`dpi_vxm_nim_ref.cpp`**: Cycle-accurate C++17 DPI-C reference model invoked on every observed cycle (`3,200` calls).

---

## 3. RTL Corner-Case Bugs Discovered, Fixed & Formally Re-Verified

1. **`BUG-VXM-001` (`rtl/groq_vxm_slice.sv`) — 32-Bit Signed Rounding Addition Overflow in `VXM_QUANT_SCALE` Near `INT32_MAX`**:
   - **Root Cause**: In `quant_scale_elem()`, `rounded = (raw_val + (32'sd1 <<< (shamt - 3'd1))) >>> shamt` performed rounding addition in 32-bit signed arithmetic (`logic signed [31:0]`). When `use_accum_32b_i == 1` and `accum_32b_in_i` was near `INT32_MAX` (e.g., `32'h7FFF_FFF0`) with `quant_shift_i >= 5`, adding `1 << (shamt - 1)` overflowed 32-bit signed integer range to negative (`-2147483632`), causing `sat_int8` to saturate positive accumulator values to `-128` (`0x80`) instead of `+127` (`0x7F` / `0x7E` in `PREC_FP8_E4M3`).
   - **Fix**: Widened `raw_ext` and `rounded` to 33-bit signed (`logic signed [32:0]`) before adding `(33'sd1 <<< (shamt - 3'd1))` and saturating to `[-128, +127]`.
2. **`BUG-VXM-002` (`rtl/groq_vxm_slice.sv`) — Unsigned Concatenation Before Arithmetic Right Shift (`>>> 6`) in `VXM_SWIGLU` Clamps Negative Products to `+127`**:
   - **Root Cause**: In `groq_vxm_slice.sv`, `VXM_SWIGLU` computed `out_acc32_comb[i] = {{16{mul_prod[i][15]}}, mul_prod[i]} >>> 6;`. Per IEEE 1800-2017 Section 11.4.12, any concatenation `{...}` is unsigned regardless of operand signedness. Thus `>>> 6` performed a logical zero-fill right shift on `32'hFFFF_xxxx`, turning negative SwiGLU products into large positive integers (`32'h03FF_xxxx`) that `sat_int8` clamped to `+127` (`0x7F`). Caught immediately by the UVM scoreboard (`187` mismatches on `vxm_op = 8` before fix).
   - **Fix**: Cast the sign-extended concatenation via `$signed({{16{mul_prod[i][15]}}, mul_prod[i]}) >>> 6`.
3. **`BUG-NIM-001` (`rtl/groq_nim_realsync.sv`) — Silent Deskew Flit Drop When Target Release Cycle Coincides With Active Non-`NIM_RECV` Opcode**:
   - **Root Cause**: When a buffered C2C flit reached its scheduled release cycle (`slot_match_valid == 1`), `buf_valid[slot_match_idx] <= 1'b0` cleared the deskew buffer slot unconditionally, but `local_stream_out_valid_o` was gated by `(!op_valid_i || (nim_op_i == groq_pkg::NIM_RECV))`. Whenever `op_valid_i == 1` with `NIM_NOP`, `NIM_SEND`, `NIM_FORWARD`, or `NIM_SYNC_BEACON` on the exact release cycle, the deskewed flit was silently dropped. Also extended `groq_pkg.sv` and `groq_nim_realsync.sv` with `NIM_SYNC_BEACON`, `NIM_DESKEW_CAL`, and `NIM_LOOPBACK`.
   - **Fix**: Removed the restrictive `(!op_valid_i || (nim_op_i == groq_pkg::NIM_RECV))` gate on `slot_match_valid` ejection so scheduled deskew releases always eject onto `local_stream_out_valid_o` / `local_stream_out_data_o` during full-duplex operation.
