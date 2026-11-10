# Stage 21: Accellera IEEE 1800.2-2020 UVM Verification Report (`groq_spec_decode_tree_sampler`, `groq_power_droop_controller` & `groq_sram_controller_scrubber`)

## 1. Executive Summary
- **Target Phase-III RTL & SRAM IP Modules**:
  - `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_spec_decode_tree_sampler.sv` (Stage 18 Hardware Speculative Decoding Draft-Verify Tree Engine & Top-$K$/Top-$P$ Nucleus Token Sampler IP: 16-lane 10-layer Bitonic sorting network, deterministic greedy argmax, piecewise-linear exponential Top-$K$/Top-$P$ nucleus sampling with Xoroshiro32++ PRNG, and 8-node Medusa/EAGLE-2 speculative draft tree verifier with causal ancestor masking and `AGU_KV_RING` pointer advance)
  - `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_power_droop_controller.sv` (Stage 19 Deterministic $L \cdot di/dt$ Voltage Droop Mitigation & Thermal Controller IP: slice-level current demand estimator across 8 spatial slices, compiler-hinted pre-warm ramp-up & post-burst ramp-down dummy bleeder controller, discrete-time RLC supply voltage estimator, and thermal emergency throttling)
  - `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/sram_ip/groq_sram_controller_scrubber.sv` + `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/sram_ip/groq_sram_ecc_secded.sv` (Stage 20 Multi-Bank SRAM Controller with Cycle-Stealing Background Dual-SECDED Scrubber & eFuse Row-Repair Loader: 4-bank $\times$ 64-row $\times$ 144-bit storage protected by dual Hamming(72,64) SECDED codecs, zero-stall foreground VLIW/DMA priority, background single-bit soft-error healing, and first-DED capture)
- **Verification Toolchain (`ict-eda-9`)**:
  - Simulator: **Verilator 5.054** (`--cc --exe --build --timing --coverage-line --coverage-toggle --coverage-user`)
  - UVM Library: **Accellera IEEE 1800.2-2020 UVM (`uvm-core-2020.3.1`)**
  - Golden Reference Model: **C++17 DPI-C Bit-Exact Reference (`dpi_spec_power_scrub_ref.cpp`)**
- **Overall Status**: **PASS** (Clean run exit code `0`, `0` UVM_ERROR, `0` UVM_FATAL, `0` mismatches across `3,600` cycles / `10,800` IP checks, `100.00%` functional covergroup coverage, `99.59%` aggregate RTL line coverage (`490/492`) and `95.60%` toggle/branch coverage (`14,486/15,152`), and non-vacuous `+INJECT_FAULT=1` rejection with `10,703` mismatches caught and exit code `1`).

---

## 2. UVM Architecture & Deliverables (`uvm_tb/uvm_spec_power_scrub/`)

| File | Role & Description |
| :--- | :--- |
| `spec_power_scrub_if.sv` | SystemVerilog interface & `spec_power_scrub_dut_wrap` connecting Accellera UVM to all 3 Phase-III hardware IPs, with `+INJECT_FAULT=1` fault-injection logic |
| `dpi_spec_power_scrub_ref.cpp` | Cycle-accurate bit-exact C++17 DPI-C golden reference model (`dpi_spec_sampler_step`, `dpi_power_droop_step`, `dpi_sram_scrubber_step`) |
| `uvm_spec_power_scrub_pkg.sv` | Complete IEEE 1800.2-2020 UVM package (`spec_power_scrub_seq_item`, `spec_power_scrub_sequencer`, `spec_power_scrub_sequence`, `spec_power_scrub_driver`, `spec_power_scrub_monitor`, `spec_power_scrub_agent`, `spec_power_scrub_cov_subscriber`, `spec_power_scrub_scoreboard`, `spec_power_scrub_env`, `spec_power_scrub_test`) |
| `tb_uvm_spec_power_scrub.sv` | Top-level testbench module registering `virtual spec_power_scrub_if` via `uvm_config_db` and invoking `run_test("spec_power_scrub_test")` |
| `sim_main.cpp` | Verilator 5.054 C++ `VerilatedContext` event loop writing `coverage.dat` and returning `dpi_get_status()` |
| `run_uvm_spec_power_scrub.sh` | End-to-end build, clean simulation (`results/clean/uvm_clean.log`), LCOV export (`results/clean/coverage_clean.info`, `lcov_summary.txt`), and `+INJECT_FAULT=1` qualification (`results/dut_bug/uvm_dut_bug.log`, `fault_injection_qual.log`) |

---

## 3. Stimulus Phases & Quantitative Results (`3,600` Cycles)

1. **Phase 0 (Cycles `0..799`)**: Directed + corner-case sweep across all 4 sampler operation modes (`SAMPLER_GREEDY_ARGMAX`, `SAMPLER_TOPK_TOPP`, `SAMPLER_SPEC_VERIFY_TREE`, default), Top-$K$ (`0..15`), inverse temperature (`0..255`), Top-$P$ thresholds, Xoroshiro32++ PRNG stepping, and all speculative tree topologies (accepted draft lengths `1..4`, all leaf indices `0..7`, invalid causal parent rejection, and depth saturation); ICU lookahead pre-warm ramp-up (`0 -> 224`), post-burst bleeder ramp-down (`240 -> 0` activating all 8 bits of `dummy_bleed_mask_o`), and unmitigated $L \cdot di/dt$ voltage droop trips; boot eFuse row-repair table initialization across all 4 SRAM banks, full 256-word SECDED array initialization, walking-1 single-bit SER injection across all 72 subword bit positions (`lo` and `hi`) verified via VLIW read correction and background cycle-stealing scrubber healing, and 2-bit DED fault injection.
2. **Phase 1 (Cycles `800..1599`)**: Intensive 16-lane Bitonic sorting network & speculative draft tree stress mixed with foreground VLIW/DMA contention against background scrubbing.
3. **Phase 2 (Cycles `1600..2399`)**: Sustained maximum slice activity (`raw_demand_o == 240`, `temp_eq_c == 105`) driving `thermal_temp_c_o` from `45C` to `105C` thermal emergency trip, followed by zero-activity cooling (`105C -> 89C`).
4. **Phase 3 (Cycles `2400..3599`)**: `1,200` cycles of high-entropy constrained-random stress across all 3 Phase-III IPs simultaneously.

### Summary Comparison (`clean` vs. `+INJECT_FAULT=1`)

| Metric | Clean Run (`results/clean/uvm_clean.log`) | Fault-Injected Run (`results/dut_bug/uvm_dut_bug.log`) |
| :--- | :---: | :---: |
| Exit Code | `0` (PASS) | `1` (Expected Rejection) |
| Driven / Observed / Checked Cycles | `3,600 / 3,600 / 3,600` | `3,600 / 3,600 / 3,600` |
| C++17 DPI-C Reference Calls | `3,600` (`10,800` IP checks) | `3,600` (`10,800` IP checks) |
| Speculative Tree Multi-Token Accept Events | `1,991` | `1,991` |
| Power Bleeder Mitigated / Emergency Throttle Events | `1,726 / 489` | `1,726 / 489` |
| SRAM VLIW SEC / DED / Scrubber WB / Repaired Row Hits | `201 / 173 / 176 / 237` | `201 / 173 / 176 / 237` |
| Scoreboard Mismatches | **`0`** | **`10,703`** (`3,503 SPEC` + `3,600 PWR` + `3,600 SRAM`) |
| Functional Covergroup (`spec_power_scrub_cg`) | **`100.00%`** | **`100.00%`** |
| LCOV `rtl/groq_spec_decode_tree_sampler.sv` | **`189/189` (`100.00%`) Line / `97.64%` Toggle** | **`189/189` (`100.00%`) Line** |
| LCOV `rtl/groq_power_droop_controller.sv` | **`95/95` (`100.00%`) Line / `81.49%` Toggle** | **`95/95` (`100.00%`) Line** |
| LCOV `sram_ip/groq_sram_controller_scrubber.sv` | **`151/153` (`98.69%`) Line / `92.85%` Toggle** | **`151/153` (`98.69%`) Line** |
| LCOV `sram_ip/groq_sram_ecc_secded.sv` | **`55/55` (`100.00%`) Line / `99.81%` Toggle** | **`55/55` (`100.00%`) Line** |
| **Aggregate Phase-III RTL + SRAM IP Coverage** | **`490/492` (`99.59%`) Line / `14,486/15,152` (`95.60%`) Toggle** | **`490/492` (`99.59%`) Line** |
