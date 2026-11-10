# Stage 7B: Accellera IEEE 1800.2-2020 UVM Verification Report ? SRAM IP & Superlane Memory Slice (`groq_mem_slice`)

## 1. Executive Summary

- **Verification Target**: `groq_mem_slice` (`sram_ip/groq_mem_slice.sv`) and its complete internal RTL hierarchy:
  - Dual Deterministic Tensor AGUs (`sram_ip/groq_mem_agu.sv`: `u_rd_agu`, `u_wr_agu`)
  - Dual-Subword Extended Hamming(72,64) SECDED Encoders & Decoders (`sram_ip/groq_sram_ecc_secded.sv`: `gen_secded[0..1]`)
  - 4-Bank x 2-Subword Single-Port Foundry SRAM Macros (`sram_ip/groq_sram_macro_sp.sv`: `gen_banks[0..3].gen_sub_macro[0..1]`) with Row-Redundancy Spare CAM, Sleep/Retention/Shut-Down Power Gating, and Hardware March C- MBIST FSM
- **Host & Toolchain**:
  - Host: `ict-eda-9` (`/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_sram_mem`)
  - Simulator: **Verilator 5.054** (`--cc --exe --build --timing --coverage-line --coverage-toggle --coverage-user`)
  - UVM Library: **Accellera IEEE 1800.2-2020 UVM 2020.3.1** (`uvm_pkg.sv`)
  - Golden Reference Oracle: **C++17 Cycle-Accurate DPI-C Reference Model** (`dpi_sram_mem_ref.cpp`)
- **Qualification Verdict**: **PASS (11 / 11 Qualification Gates Verified)**
  - **Clean Baseline (`sim_clean`)**: **2,729 transactions** driven, observed, and verified via DPI-C (`1,904` valid read checks, `1,372` write checks, `300` single-bit SEC auto-corrections, `256` double-bit DED detections, `64` same-bank conflict checks, `1` full 11,264-cycle March C- MBIST run), **0 mismatches**, **100.0% functional covergroup coverage** (`29 / 29` bins hit), **98.08% LCOV RTL line/toggle coverage** (`409 / 417` instrumentation points hit across `sram_ip/*.sv`), exit code `0`.
  - **Fault-Injection Qualification (`sim_dut_bug` with `+INJECT_DUT_BUG`)**: Injects a post-ECC superlane output bit-flip across transactions `64..79`, caught immediately by `sram_mem_scoreboard` with **16 `DPI_MISMATCH` UVM_ERRORs**, `UVM_FATAL [UVM_SRAM_REJECTED]`, and non-zero exit code `1`.

---

## 2. UVM Environment Architecture & Files (`uvm_tb/uvm_sram_mem/`)

| File | Role & Description | Lines |
| :--- | :--- | :---: |
| `groq_sram_mem_if.sv` | SystemVerilog interface connecting UVM testbench to `groq_mem_slice` (128b data, 144b ECC mask, dual AGU descriptors, per-bank power/repair/MBIST controls) | 79 |
| `groq_sram_mem_uvm_pkg.sv` | Full IEEE 1800.2-2020 UVM package (`sram_mem_seq_item`, `sram_mem_sequencer`, `sram_mem_sequence`, `sram_mem_driver`, `sram_mem_monitor` + `sram_mem_cg`, `sram_mem_scoreboard`, `sram_mem_env`, `sram_mem_test`) | 865 |
| `dpi_sram_mem_ref.cpp` | Cycle-accurate C++17 DPI-C golden memory model modeling dual AGUs, Hamming(72,64) SECDED `POS_MAP`, 4-bank x 2-subword SRAM macros, spare row repair, power gating, and March C- MBIST | 331 |
| `sram_mem_top.sv` | Top-level SystemVerilog harness instantiating `groq_mem_slice` (`NUM_BANKS=4, BANK_ADDR_W=10, BANK_DEPTH=1024`) and `+INJECT_DUT_BUG` fault-injection mux | 98 |
| `sim_main.cpp` | Verilator 5.054 C++ simulation loop exporting `coverage.dat` and returning `dpi_sram_get_status()` | 24 |
| `run_uvm_sram_mem.py` | Automated compilation, `clean` + `dut_bug` execution, `verilator_coverage --write-info` LCOV export, and `qualification.json` generator | 124 |

---

## 3. Eight-Phase Verification Plan & Transaction Breakdown (2,729 Transactions)

| Phase | Verification Scope | Transactions | Key Checks Performed by `sram_mem_scoreboard` + DPI-C |
| :---: | :--- | :---: | :--- |
| **Phase 1** | Full-Bank Init & Concurrent 1R+1W Streaming | 640 | Simultaneous 1R+1W across distinct banks (`0..3`), `bwe_n` byte masking (`16'h0000`, `16'hFFFF`), walking/alternating/random 128-bit superlane vectors |
| **Phase 2** | `AGU_LINEAR_STRIDE` (`2'b00`) | 320 | Read & Write AGU 1D linear strided streaming (`base=16+32b, stride0=3, count0=39`) across all 4 banks, verifying `rd_tile_done` & `wr_tile_done` |
| **Phase 3** | `AGU_2D_TILE` (`2'b01`) | 328 | Nested 2D tensor tile walk (`count0=8, stride0=2, count1=5, stride1=16`) across all 4 banks, verifying inner wrap and outer `tile_done` |
| **Phase 4** | `AGU_KV_RING` (`2'b10`) | 328 | Circular KV-cache ring buffer wrap-around (`ring_mask=10'h00F` and full-mask `stride1=0`, plus `count0=0` minimum-bound guard) |
| **Phase 5** | `AGU_GATHER_SCATTER` (`2'b11`) | 328 | Indexed gather/scatter offset addressing (`base + gather_offset_in`) toggling all 10 bank address bits `[9:0]` across all 4 banks |
| **Phase 6** | Single-Bit SECDED Fault Injection (SEC) | 300 | Exhaustive 1-bit error walk across all **144 codeword bits** (`0..143`) + **156** dual-subword simultaneous 1-bit errors (`1` in subword 0 + `1` in subword 1); verifies `ecc_single_err=1`, `ecc_double_err=0`, `ecc_syndrome != 0`, and 100% transparent hardware auto-correction (`stream_out_data == expected`) |
| **Phase 7** | Double-Bit SECDED Fault Injection (DED) | 256 | 2-bit error pairs within subword 0 or subword 1 (data+data, data+parity, parity+parity); verifies `ecc_double_err=1` and even-parity non-zero syndrome |
| **Phase 8** | Row Repair, Bank Conflicts, Sleep Modes & MBIST | 229 | **8A (64 tx)**: Spare row CAM repair (`bank_repair_en`, `bank_repair_addr`); **8B (128 tx)**: Same-bank 1R+1W conflict detection (`bank_conflict_error=1`, write priority, read suppressed + readback); **8C (20 tx)**: Light Sleep (`slp_n=0`), Deep Sleep (`ds_n=0`), Wakeup retention, and Shut Down (`sd_n=0`) spare-row clear; **8D (17 tx)**: Full 11,264-cycle March C- MBIST (`mbist_done=1, mbist_fail=0`) + post-MBIST zero-readback |
| **Total** | **All 8 Phases Combined** | **2,729** | **100% checked via `dpi_sram_step()` in `dpi_sram_mem_ref.cpp` with 0 mismatches** |

---

## 4. SystemVerilog Functional Coverage (`sram_mem_cg`: 29 / 29 Bins = 100.00%)

Extracted directly from `results/clean/coverage.dat`:

| Coverpoint | Bin Name | Hit Count | Status |
| :--- | :--- | :---: | :---: |
| `rd_bank_cp` | `b0`, `b1`, `b2`, `b3` | `511`, `511`, `511`, `447` | 100% (4/4) |
| `wr_bank_cp` | `b0`, `b1`, `b2`, `b3` | `343`, `343`, `343`, `343` | 100% (4/4) |
| `rd_agu_mode_cp` | `linear_stride`, `tile_2d`, `kv_ring`, `gather_scatter` | `960`, `328`, `328`, `1113` | 100% (4/4) |
| `wr_agu_mode_cp` | `linear_stride`, `tile_2d`, `kv_ring`, `gather_scatter` | `960`, `328`, `328`, `1113` | 100% (4/4) |
| `ecc_status_cp` | `clean_0bit`, `sec_1bit`, `ded_2bit` | `2173`, `300`, `256` | 100% (3/3) |
| `conflict_cp` | `no_conflict`, `bank_conflict` | `2665`, `64` | 100% (2/2) |
| `pwr_state_cp` | `active`, `light_sleep`, `deep_sleep`, `shut_down` | `2717`, `4`, `4`, `4` | 100% (4/4) |
| `repair_cp` | `normal_access`, `repaired_access` | `2661`, `68` | 100% (2/2) |
| `mbist_cp` | `functional`, `mbist_done` | `2728`, `1` | 100% (2/2) |
| **Total** | **All 9 Coverpoints (29 Bins)** | **2,729 Samples** | **100.00% (29/29)** |

---

## 5. LCOV RTL Line & Toggle Coverage (`verilator_coverage --write-info`)

Extracted from `results/clean/coverage.info`:

| RTL Module (`sram_ip/`) | Hit Points | Total Points | Coverage (%) | Notes |
| :--- | :---: | :---: | :---: | :--- |
| `groq_sram_ecc_secded.sv` | 55 | 55 | **100.00%** | Every encoder/decoder/corrector bit & syndrome branch exercised |
| `groq_sram_macro_sp.sv` | 175 | 178 | **98.31%** | All 6 March C- MBIST states (`M0..M5` + `COMPLETE`), spare row CAM, and all 4 power states hit |
| `groq_mem_agu.sv` | 96 | 98 | **97.96%** | All 4 AGU modes, inner/outer loop wraps, `tile_done`, and zero-count guard exercised |
| `groq_mem_slice.sv` | 83 | 86 | **96.51%** | Concurrent 1R+1W, dual AGUs, dual SECDED, bank conflict, sleep gating, and MBIST broadcast verified |
| **Total SRAM IP Hierarchy** | **409** | **417** | **98.08%** | Exceeds >95% line/toggle coverage target across all 4 modules |

---

## 6. Clean Baseline vs. Fault-Injection Qualification (`+INJECT_DUT_BUG`)

| Run Case | Plusargs | Exit Code | Driven / Checked | DPI-C Calls | Mismatches | Functional Cov | Verdict |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **`clean`** | `+UVM_VERBOSITY=UVM_LOW` | `0` | `2,729 / 2,729` | `2,729` | `0` | `100.00%` | **PASS** |
| **`dut_bug`** | `+UVM_VERBOSITY=UVM_LOW +INJECT_DUT_BUG` | `1` | `2,729 / 2,729` | `2,729` | `16` | `100.00%` | **CAUGHT (PASS)** |

### Excerpt from `results/sim_clean.log`
```text
UVM_INFO @ 0: reporter [RNTST] Running test sram_mem_test...
UVM_INFO groq_sram_mem_uvm_pkg.sv(860) @ 140010000: uvm_test_top [UVM_SRAM_PASS] ALL 2729 SRAM transactions verified against C++ DPI-C golden model (0 mismatches, 100.0% functional coverage)
--- UVM Report Summary ---
UVM_INFO :    4
UVM_WARNING :    2
UVM_ERROR :    0
UVM_FATAL :    0
```

### Excerpt from `results/sim_dut_bug.log` (`+INJECT_DUT_BUG`)
```text
UVM_ERROR groq_sram_mem_uvm_pkg.sv(764) @ 745001: uvm_test_top.env.scoreboard [DPI_MISMATCH] tx=69 ph=1 rd_addr=35 wr_addr=35 out_val=1/1 conf=0/0 sec=0/0 ded=0/0 syn=0000/0000 rdata=163ad83268bdb0fd228e1c98ef32be67 exp=163ad83268bd6e50_228e1c98ef320088
...
UVM_FATAL groq_sram_mem_uvm_pkg.sv(856) @ 140010000: uvm_test_top [UVM_SRAM_REJECTED] UVM SRAM qualification failed: driven=2729 checked=2729 mismatches=16 cov=100.00%
```

## 7. RTL Bug Audit Summary
No RTL corner-case bugs were found in `sram_ip/` (`groq_sram_ecc_secded.sv`, `groq_sram_macro_sp.sv`, `groq_mem_agu.sv`, `groq_mem_slice.sv`). All 4 modules passed 100% of the 2,729 cycle-accurate DPI-C golden model checks on the first run.
