# Stage 27: Full-System Disaggregated NVIDIA Vera Rubin Prefill -> NVLink-C2C -> 8-Chip Groq 3 LPX Decode RTL Benchmark Report

## 1. Executive Summary

Stage 27 establishes and verifies the unified, cycle-accurate **Full-System Disaggregated Prefill-to-Decode RTL Benchmark** (`benchmarks/disagg_prefill_decode_8chip/tb_disagg_prefill_decode_8chip.sv`) on `ict-eda-9` using **Verilator 5.054**. For the first time in the verification campaign, **all Phase I–IV IP subsystems** are simultaneously instantiated and connected in a single closed-loop multi-chip RTL simulation:

1. **External Vera Rubin NVLink-C2C Prefill Ingress (`groq_c2c_serdes_pcs` TX/RX + Go-Back-N Replay)**: Streams 64x 128-bit flits (`32x 256-bit` `BF16`/`FP16` KV-cache blocks) over a 64B/66B-framed, LFSR-scrambled SerDes link with **8 live CRC-16-CCITT link fault injections** and automatic 1-cycle **Go-Back-N hardware replay** (`72` flits transmitted including replays, `64/64` flits received bit-exact).
2. **On-the-Fly KV-Cache Microscaling Block Quantizer (`groq_c2c_kv_quant_rx_engine`)**: Pairs incoming 128-bit NVLink-C2C flits into 256-bit (`16x BF16` and `16x FP16`) KV-cache vectors and quantizes them in 1 registered clock cycle into 128-bit `MXFP8_E4M3` (`2x` compression), `NVFP4_E2M1` (`4x` compression), and `RAW128_BYPASS` (`1x`) vectors plus shared `E8M0` power-of-two block scales (`32/32` blocks quantized bit-exact against `gen_disagg_prefill_decode_vectors.py`, `96` zero lanes detected).
3. **4-Bank Dual-SECDED SRAM Controller & Cycle-Stealing Background Scrubber (`groq_sram_controller_scrubber`)**: Directly connected to `groq_c2c_kv_quant_rx_engine`'s write port (`sram_wr_en_o`), storing all 32 quantized KV-cache blocks across 4 banks with **boot eFuse bad-row repair CAM active** (`4/4` repaired spare-row read hits) and **32 live single-bit radiation soft-error (`SER`) upsets injected** (`8` per decode pass), achieving **100% autonomous background scrub healing (`32/32` corrected, `0` uncorrectable DED alerts)**.
4. **Deterministic $L\,di/dt$ Voltage Droop Controller (`groq_power_droop_controller`)**: Pre-warms and ramps down dummy bleeders around each 8-chip compute burst, slashing peak $|di/dt|$ by **82.0%** (`200 -> 36`), improving minimum supply voltage from **`597 mV -> 684 mV`**, and eliminating all emergency droop throttle events (**`4 -> 0` cycles**).
5. **8-Chip Dragonfly Group Scale-Out Cluster (`groq_dragonfly_8chip_cluster`) + Microscaling Dot-Product Engine (`groq_mxfp8_nvfp4_dot_engine`)**: Reads back the 32 scrubbed quantized KV-cache blocks + `E8M0` block scales, executes **32 microscaling $Q K^T$ attention dot-products** across `MXFP8_E4M3`, `NVFP4_E2M1`, and `W4A8_MIXED` modes (`290` zero-skipped lanes), loads the scrubbed KV blocks into the 8-chip cluster via `groq_pcie_c2c_dma`, and executes 4 passes of 8-chip VLIW compute (`MEM_READ_WEST -> MXM_SYSTOLIC_EXEC -> VXM_SWIGLU -> NIM_SEND`) across all 4 Dragonfly routing modes (`ROUTE_DIRECT_CROSSBAR`, `ROUTE_BIDIR_RING`, `ROUTE_UGAL_ADAPTIVE`, `ROUTE_MOE_ALLTOALL_BUTTERFLY`) with 8 intra-cluster C2C CRC-16 fault injections.
6. **Hardware Speculative Decoding Draft-Verify Tree Engine (`groq_spec_decode_tree_sampler`)**: Verifies 4 passes of 8-node EAGLE-2/Medusa speculative draft token trees (`[4, 5, 3, 4]` tokens accepted per pass), emitting **`16` verified tokens in `4` target passes (`4.00x` effective speculative decoding speedup)** and advancing the KV-cache ring pointer by `12` slots.

---

## 2. End-to-End Subsystem Verification Metrics (`disagg_prefill_decode_summary.json`)

| Subsystem / Metric | RTL Simulation Result | Golden Target | Status |
| :--- | :---: | :---: | :---: |
| **Total Simulation Cycles** | `535` cycles | Deterministic | **PASS** |
| **Total Self-Checking Assertions** | `176 / 176` | `176` | **PASS (0 Errors)** |
| **1. Rubin-to-Groq NVLink-C2C Prefill Ingress (`groq_c2c_serdes_pcs`)** | | | |
| — C2C Flits Received (128-bit) | `64 / 64` | `64` | **PASS** |
| — Live CRC-16-CCITT Faults Injected | `8` | `8` | **PASS** |
| — Go-Back-N NACKs & Automatic Replays | `8 NACKs / 8 Replays` (`72` total TX flits) | `8 / 8` | **PASS** |
| **2. On-the-Fly KV-Cache Quantizer (`groq_c2c_kv_quant_rx_engine`)** | | | |
| — 256b -> 128b KV Blocks Quantized | `32 / 32` | `32` | **PASS** |
| — Modes Verified (`8` blocks each) | `BF16->MXFP8`, `FP16->MXFP8`, `BF16->NVFP4`, `RAW128` | All 4 Modes | **PASS** |
| — Sparsity Zero Lanes Detected | `96` | `96` | **PASS** |
| **3. 4-Bank Dual-SECDED SRAM & Scrubber (`groq_sram_controller_scrubber`)** | | | |
| — Boot eFuse Bad-Row Repair CAM | `4 / 4` banks active (`4` spare-row read hits) | `4 / 4` | **PASS** |
| — Radiation Single-Bit Upsets (`SER`) Injected | `32` (`8` per decode pass) | `32` | **PASS** |
| — Background Scrubbing Corrections | `32 / 32` (`100%` healed before readback) | `32` | **PASS** |
| — Uncorrectable Double-Bit (`DED`) Alerts | `0` | `0` | **PASS** |
| **4. Deterministic $L\,di/dt$ Voltage Droop Controller (`groq_power_droop_controller`)** | | | |
| — Peak $\|di/dt\|$ (Unmitigated -> Mitigated) | `200 -> 36` (**`-82.0%` reduction**) | $\le 36$ | **PASS** |
| — Minimum Supply Voltage $V_{DD,\min}$ | `597 mV -> 684 mV` (**`+87 mV` margin gain**) | $\ge 620\text{ mV}$ | **PASS** |
| — Emergency Droop Throttle Cycles | `4 -> 0` (**`100%` eliminated**) | `0` | **PASS** |
| **5. 8-Chip Dragonfly Cluster (`groq_dragonfly_8chip_cluster`) & Dot Engine (`groq_mxfp8_nvfp4_dot_engine`)** | | | |
| — Microscaling $Q K^T$ Dot-Products Executed | `32` (`MXFP8_E4M3`, `NVFP4_E2M1`, `W4A8_MIXED`) | `32` | **PASS** |
| — Dot-Engine Zero-Skipped Sub-Lanes | `290` | `290` | **PASS** |
| — Per-Pass Accumulated Attention Dot Output | `[144104, 208776, -7838, -599472]` | Exact Match | **PASS** |
| — Dragonfly Routing Modes Exercised | `DIRECT` (`0`), `RING` (`1`), `UGAL` (`2`), `BUTTERFLY` (`3`) | All 4 Modes | **PASS** |
| — Intra-Cluster C2C Flits TX / CRC-16 Injected | `33` flits / `8` CRC-16 faults injected | `33 / 8` | **PASS** |
| **6. Speculative Decoding Tree Engine (`groq_spec_decode_tree_sampler`)** | | | |
| — Verified Tokens Emitted per Pass (`p = 0..3`) | `[4, 5, 3, 4]` (`16` tokens in `4` passes) | `16` | **PASS** |
| — KV-Cache Ring Pointer Advances (`kv_ring_advance_o`) | `[3, 4, 2, 3]` (`12` total advances) | `12` | **PASS** |
| — Effective Speculative Decoding Speedup | **`4.00x`** (`4.00` tokens/pass) | `4.00x` | **PASS** |

---

## 3. Closed-Loop Disaggregated Prefill-to-Decode Hardware Dataflow

```
+---------------------------------------------------------------------------------------------------+
| 1. External NVIDIA Vera Rubin Prefill Host (u_rubin_c2c_tx: groq_c2c_serdes_pcs)                  |
|    Streams 64x 128b BF16/FP16 KV Flits (32x 256b Blocks) + 8 Live CRC-16 Faults + 8 GBN Replays   |
+-------------------------------------------------+-------------------------------------------------+
                                                  | 64B/66B Framed NVLink-C2C Channel (162-bit)
                                                  v
+---------------------------------------------------------------------------------------------------+
| 2. Groq 3 LPX C2C RX PCS & On-the-Fly KV Microscaling Quantizer (u_groq_c2c_rx -> u_kv_quant)     |
|    Pairs 2x 128b flits -> 256b (16x BF16/FP16) -> 1-Cycle E_max Tree + E8M0 Scale + 128b Quant    |
|    Modes: BF16->MXFP8_E4M3 (2x), FP16->MXFP8_E4M3 (2x), BF16->NVFP4_E2M1 (4x), RAW128_BYPASS (1x) |
+-------------------------------------------------+-------------------------------------------------+
                                                  | Direct DMA Write Port (kvq_sram_wr_en_o, 128b)
                                                  v
+---------------------------------------------------------------------------------------------------+
| 3. 4-Bank Dual-SECDED SRAM Controller & Scrubber (u_sram_scrubber: groq_sram_controller_scrubber) |
|    4 Boot eFuse Repaired Spare Rows + 32 Injected Radiation Upsets (SER) -> 32/32 Scrub Healed    |
+------------------------+-------------------------------------------------+------------------------+
                         | Scrubbed 128b KV + E8M0 Scale                   | Host DMA Write (u_cluster)
                         v                                                 v
+------------------------------------------------+ +------------------------------------------------+
| 4. Microscaling Dot Engine (u_dot_engine)      | | 5. 8-Chip Dragonfly Cluster (u_cluster)        |
|    32x Q*K^T Attention Dot-Products (MXFP8 /   | |    MEM_W -> MXM_W -> VXM_SWIGLU -> NIM_SEND    |
|    NVFP4 / W4A8_MIXED), 290 Zero-Skipped Lanes | |    DIRECT / RING / UGAL / BUTTERFLY + Droop    |
+------------------------+-----------------------+ +-----------------------+------------------------+
                         |                                                 |
                         +------------------------+------------------------+
                                                  v
+---------------------------------------------------------------------------------------------------+
| 6. Hardware Speculative Decoding Tree Verifier (u_spec_decode: groq_spec_decode_tree_sampler)     |
|    8-Node EAGLE-2/Medusa Draft Tree Verification -> [4, 5, 3, 4] = 16 Verified Tokens (4.00x)     |
+---------------------------------------------------------------------------------------------------+
```

---

## 4. Artifact Manifest (`benchmarks/disagg_prefill_decode_8chip/`)

- **Golden Vector Generator & Verifier**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/benchmarks/disagg_prefill_decode_8chip/gen_disagg_prefill_decode_vectors.py`
- **Golden KV-Cache Disaggregation Vectors**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/benchmarks/disagg_prefill_decode_8chip/kv_disagg_golden_vectors.json`
- **Full-System Top-Level RTL Testbench**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/benchmarks/disagg_prefill_decode_8chip/tb_disagg_prefill_decode_8chip.sv`
- **Automated Build & Verification Runner**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/benchmarks/disagg_prefill_decode_8chip/run_disagg_prefill_decode_8chip.sh`
- **Simulation Log**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/benchmarks/disagg_prefill_decode_8chip/disagg_prefill_decode_rtl.log`
- **Machine-Readable Telemetry Summary**: `/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/benchmarks/disagg_prefill_decode_8chip/disagg_prefill_decode_summary.json`
