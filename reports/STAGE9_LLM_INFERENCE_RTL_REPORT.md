# Stage 9: End-to-End LLM Inference Execution on Verilator RTL (`benchmarks/llm_inference_rtl/`) + Bit-Exact Golden Comparison & VCD Switching Power Analysis

## 1. Executive Summary

We executed an end-to-end deterministic **Multi-Chip Tensor-Parallel Llama-3 / DeepSeek Transformer Token Decode Pipeline** across two interconnected 8-slice Groq LPU / NVIDIA Groq 3 LPX chips (`groq_lpu_cluster_top`, instantiating `u_lpu_chip0` and `u_lpu_chip1` over a bidirectional Dragonfly C2C link with hardware `RealSync` plesiochronous elastic deskew) compiled with **Verilator 5.054 (`--cc --exe --build --timing --trace`)**.

All **21 intermediate and final 128-bit superlane stream/SRAM tensors** across all four pipeline stages (Stage A RMSNorm, Stage B QKV + RoPE + Circular `AGU_KV_RING` KV-Cache Append, Stage C GQA `Q*K^T` + Numerically Stable Softmax + `Score*V`, and Stage D Fused SwiGLU FFN + Multi-Chip Dragonfly `RealSync` `NIM_ALLREDUCE_ADD` + `MEM_E` Writeback) achieved **100% bit-exact agreement (`0` bit errors across 2,688 verified output bits)** against the Python golden reference model (`verify_llm_rtl_vs_golden.py`).

Furthermore, live single-bit SRAM fault injection (`mem_err_inject_en_i = 1'b1`, `mem_err_inject_mask_i = 144'h8`) into all **142 live SRAM reads** (embeddings, RoPE tables, KV-Cache, and QKV/FFN weights) was **100% transparently corrected in-flight in zero extra clock cycles** by `groq_sram_ecc_secded` (`ecc_single_bit_corrected_reads = 142`, `ecc_double_bit_errors = 0`, `stream_mismatch_vs_ecc_dut = 0`).

---

## 2. 4-Stage Deterministic Spatial VLIW Schedule & Hop-by-Hop Architecture

Both `u_lpu_chip0` (`local_chip_id = 0`) and `u_lpu_chip1` (`local_chip_id = 1`) execute a compiler-scheduled **272-cycle** 8-slice VLIW program (`chip0_imem_s0..s7.hex`, `chip1_imem_s0..s7.hex`) with **zero dynamic arbiters, zero FIFOs, zero stream collisions (`cluster_collision_fault = 0`), and zero SRAM bank conflicts**:

| Pipeline Stage | Deterministic PC Window | Spatial Hardware Dataflow & Functional Slice Sequence | Cycles |
| :--- | :---: | :--- | :---: |
| **Stage A: Input Embedding & Hardware RMSNorm** | `PC = 1 .. 28` | `MEM_W (Read x) -> VXM_MUL (x^2) -> SXM_PASS -> VXM_REDUCE_SUM -> SXM_PASS -> VXM_RSQRT_LUT -> SXM_BROADCAST_LANE -> VXM_MUL (x * rsqrt) -> VXM_QUANT_SCALE -> MEM_W / MEM_E` | 28 |
| **Stage B: Attention QKV, RoPE & KV-Cache Ring** | `PC = 25 .. 96` | `MEM_W -> MXM_W (W_Q, Bank 0) & MXM_E (W_K, Bank 0) & MXM_W (W_V, Ping-Pong Bank 1) -> SXM_BUTTERFLY_SWAP (RoPE pair swap + even negation) -> VXM_FMA (q_rot * sin + q_raw) -> MEM_W AGU_KV_RING (Mode 2'b10 Circular KV-Cache Append)` | 72 |
| **Stage C: GQA Score & Numerically Stable Softmax** | `PC = 94 .. 188` | `MXM_E (Q * K^T, Ping-Pong Bank 1) -> VXM_REDUCE_MAX (s_max) -> SXM_BROADCAST_LANE -> VXM_SUB (s - s_max) -> VXM_EXP_LUT -> VXM_REDUCE_SUM -> VXM_QUANT_SCALE -> MXM_E (Score * V, Ping-Pong Bank 0) -> MEM_W / MEM_E` | 95 |
| **Stage D: Fused SwiGLU FFN & Multi-Chip AllReduce** | `PC = 182 .. 271` | `MXM_W (Gate) + MXM_E (Up) -> VXM_SWIGLU (SiLU(g)*u >> 6) -> MXM_W (Down, Ping-Pong Bank 1) -> NIM_SEND (Chip 0 -> Chip 1, CRC-8) -> RealSync Deskew (3-cyc flight) -> NIM_ALLREDUCE_ADD (Chip 1) -> C2C Return -> NIM_RECV (Chip 0) -> MEM_E Writeback -> ICU_SYNC_BARRIER (0xFF) -> ICU_HALT` | 90 |
| **Total End-to-End Token Decode Latency** | **`PC = 0 .. 271`** | **Full 2-Chip Tensor-Parallel Transformer Token Decode (Overlapped Spatial Schedule)** | **272 cycles** |


---

## 3. Bit-Exact Verification Results: Verilator RTL vs. Python Golden Reference

Every intermediate stream tensor and final `MEM_E` writeback tensor captured from `groq_lpu_cluster_top` and `u_chip0_ecc_dut` matches `golden_reference.json` with **0 bit errors**:

| # | Tensor / Checkpoint Name | Pipeline Stage & Hardware Origin | Python Golden 128-Bit Hex | Verilator RTL 128-Bit Hex | Decoded 16-Lane INT8 Vector (`lane[0..15]`) | Bit Errors | Status |
| :-: | :--- | :--- | :--- | :--- | :--- | :---: | :---: |
| 1 | `stage_a_x_norm` | Stage A (`VXM_QUANT_SCALE -> MEM_W/E`) | `fb05f60f0afb0005f10a05f6000ffb0a` | `fb05f60f0afb0005f10a05f6000ffb0a` | `[10, -5, 15, 0, -10, 5, 10, -15, 5, 0, -5, 10, 15, -10, 5, -5]` | **0** | **PASS** |
| 2 | `chip0_q_raw` | Stage B (`Chip 0 MXM_W: x_norm * W_Q`) | `000ad8f646f6233ce2d31ea64b282805` | `000ad8f646f6233ce2d31ea64b282805` | `[5, 40, 40, 75, -90, 30, -45, -30, 60, 35, -10, 70, -10, -40, 10, 0]` | **0** | **PASS** |
| 3 | `chip0_q_rope` | Stage B (`Chip 0 SXM_BUTTERFLY + VXM_FMA`) | `f60ac4463cb0e75fb5f1808073dd2ddd` | `f60ac4463cb0e75fb5f1808073dd2ddd` | `[-35, 45, -35, 115, -128, -128, -15, -75, 95, -25, -80, 60, 70, -60, 10, -10]` | **0** | **PASS** |
| 4 | `chip0_k_rope` | Stage B (`Chip 0 RoPE + AGU_KV_RING`) | `28f1b52dddfb4b3cfbc9ced8730ff60a` | `28f1b52dddfb4b3cfbc9ced8730ff60a` | `[10, -10, 15, 115, -40, -50, -55, -5, 60, 75, -5, -35, 45, -75, -15, 40]` | **0** | **PASS** |
| 5 | `chip0_v_vec` | Stage B (`Chip 0 MXM_W Bank 1: x_norm * W_V`) | `05191efbfbf614ece2ec0500f1fb1efb` | `05191efbfbf614ece2ec0500f1fb1efb` | `[-5, 30, -5, -15, 0, 5, -20, -30, -20, 20, -10, -5, -5, 30, 25, 5]` | **0** | **PASS** |
| 6 | `chip0_s_attn` | Stage C (`Chip 0 MXM_E: q_rope * K_cache^T`) | `aa818c55129a22575ce1c350a8173c71` | `aa818c55129a22575ce1c350a8173c71` | `[113, 60, 23, -88, 80, -61, -31, 92, 87, 34, -102, 18, 85, -116, -127, -86]` | **0** | **PASS** |
| 7 | `chip0_p_exp` | Stage C (`Chip 0 VXM_EXP_LUT(s - s_max)`) | `0101012f010101333d0101260101127f` | `0101012f010101333d0101260101127f` | `[127, 18, 1, 1, 38, 1, 1, 61, 51, 1, 1, 1, 47, 1, 1, 1]` | **0** | **PASS** |
| 8 | `chip0_p_attn` | Stage C (`Chip 0 VXM_QUANT_SCALE Softmax`) | `00000006000000060800000500000210` | `00000006000000060800000500000210` | `[16, 2, 0, 0, 5, 0, 0, 8, 6, 0, 0, 0, 6, 0, 0, 0]` | **0** | **PASS** |
| 9 | `chip0_o_attn` | Stage C (`Chip 0 MXM_E: P_attn * V_cache`) | `13ef0bf8e1fcf40600f70bfef3efe9f8` | `13ef0bf8e1fcf40600f70bfef3efe9f8` | `[-8, -23, -17, -13, -2, 11, -9, 0, 6, -12, -4, -31, -8, 11, -17, 19]` | **0** | **PASS** |
| 10 | `chip0_g_ffn` | Stage D (`Chip 0 MXM_W: o_attn * W_gate`) | `28e51dd91ec39ac1deabd010fd0f406e` | `28e51dd91ec39ac1deabd010fd0f406e` | `[110, 64, 15, -3, 16, -48, -85, -34, -63, -102, -61, 30, -39, 29, -27, 40]` | **0** | **PASS** |
| 11 | `chip0_u_ffn` | Stage D (`Chip 0 MXM_E: o_attn * W_up`) | `bf87071df3e7c8c688380f22f20e2898` | `bf87071df3e7c8c688380f22f20e2898` | `[-104, 40, 14, -14, 34, 15, 56, -120, -58, -56, -25, -13, 29, 7, -121, -65]` | **0** | **PASS** |
| 12 | `chip0_h_swiglu` | Stage D (`Chip 0 VXM_SWIGLU(g_ffn, u_ffn)`) | `e30d01fefc0000000500ff0500012880` | `e30d01fefc0000000500ff0500012880` | `[-128, 40, 1, 0, 5, -1, 0, 5, 0, 0, 0, -4, -2, 1, 13, -29]` | **0** | **PASS** |
| 13 | `chip0_y_down` | Stage D (`Chip 0 MXM_W: h_swiglu * W_down`) | `de3cf4dad03e76b0a51e4bcf2a28e3e5` | `de3cf4dad03e76b0a51e4bcf2a28e3e5` | `[-27, -29, 40, 42, -49, 75, 30, -91, -80, 118, 62, -48, -38, -12, 60, -34]` | **0** | **PASS** |
| 14 | `chip1_q_rope` | Stage B (`Chip 1 SXM_BUTTERFLY + VXM_FMA`) | `606eb0d832ec14e2d373b0f123fb978d` | `606eb0d832ec14e2d373b0f123fb978d` | `[-115, -105, -5, 35, -15, -80, 115, -45, -30, 20, -20, 50, -40, -80, 110, 96]` | **0** | **PASS** |
| 15 | `chip1_k_rope` | Stage B (`Chip 1 RoPE + AGU_KV_RING`) | `37fb3c1e320a0af6fb23ce0f19d8fbfb` | `37fb3c1e320a0af6fb23ce0f19d8fbfb` | `[-5, -5, -40, 25, 15, -50, 35, -5, -10, 10, 10, 50, 30, 60, -5, 55]` | **0** | **PASS** |
| 16 | `chip1_o_attn` | Stage C (`Chip 1 MXM_E: P_attn * V_cache`) | `090bfbdf020afd04f3edfe142822fff7` | `090bfbdf020afd04f3edfe142822fff7` | `[-9, -1, 34, 40, 20, -2, -19, -13, 4, -3, 10, 2, -33, -5, 11, 9]` | **0** | **PASS** |
| 17 | `chip1_h_swiglu` | Stage D (`Chip 1 VXM_SWIGLU(g_ffn, u_ffn)`) | `3b31fe00007f0007ff79ff8d01007b10` | `3b31fe00007f0007ff79ff8d01007b10` | `[16, 123, 0, 1, -115, -1, 121, -1, 7, 0, 127, 0, 0, -2, 49, 59]` | **0** | **PASS** |
| 18 | `chip1_y_down` | Stage D (`Chip 1 MXM_W: h_swiglu * W_down`) | `fe973097adfcaaf8beaf4edb813a8a69` | `fe973097adfcaaf8beaf4edb813a8a69` | `[105, -118, 58, -127, -37, 78, -81, -66, -8, -86, -4, -83, -105, 48, -105, -2]` | **0** | **PASS** |
| 19 | `y_final_allreduce` | Stage D (`Chip 0 MEM_E Final Token Writeback`) | `dcd32480803a20a880cd7faaab62804e` | `dcd32480803a20a880cd7faaab62804e` | `[78, -128, 98, -85, -86, 127, -51, -128, -88, 32, 58, -128, -128, 36, -45, -36]` | **0** | **PASS** |
| 20 | `chip1_y_final_mem_e` | Stage D (`Chip 1 MEM_E Final Token Writeback`) | `dcd32480803a20a880cd7faaab62804e` | `dcd32480803a20a880cd7faaab62804e` | `[78, -128, 98, -85, -86, 127, -51, -128, -88, 32, 58, -128, -128, 36, -45, -36]` | **0** | **PASS** |
| 21 | `ecc_dut_y_final_mem_e` | Stage D (`Live SECDED ECC-Injected Chip 0 MEM_E`) | `dcd32480803a20a880cd7faaab62804e` | `dcd32480803a20a880cd7faaab62804e` | `[78, -128, 98, -85, -86, 127, -51, -128, -88, 32, 58, -128, -128, 36, -45, -36]` | **0** | **PASS** |


---

## 4. Live Single-Bit SRAM SECDED ECC Fault Injection & Multi-Chip RealSync Telemetry

During the live 272-cycle LLM token decode execution, the shadow LPU instance `u_chip0_ecc_dut` ran with continuous single-bit SRAM codeword corruption (`mem_err_inject_en_i = 1'b1`, `mem_err_inject_mask_i = 144'h0000_0000_0000_0000_0000_0000_0000_0000_0008`, flipping bit 3 of the lower 72-bit Hamming(72,64) SECDED subword on every SRAM read):

| Hardware Telemetry Metric | Measured Value | Verification Requirement | Status |
| :--- | :---: | :---: | :---: |
| **Total Execution Cycles (`PC = 0 .. 271`)** | `272 cycles` (`272.0 ns` @ 1.0 GHz) | Deterministic lockstep completion | **PASS** |
| **All-Slice Halt Mask (`chip0_halted_mask / chip1_halted_mask`)** | `8'hFF (255)` / `8'hFF (255)` | All 8 slices on both chips halted cleanly | **PASS** |
| **Spatial Stream Write Collisions (`cluster_collision_fault`)** | `0` | `0` collisions across 272 cycles | **PASS** |
| **Dragonfly C2C Link CRC-8 Errors (`cluster_c2c_crc_err`)** | `0` | `0` link CRC-8 errors | **PASS** |
| **RealSync Elastic Deskew Releases (`chip0 / chip1`)** | `1` / `1` | Exact 3-cycle flight target match (`PC=256`, `PC=259`) | **PASS** |
| **Measured Plesiochronous Residual Skew (`chip0 / chip1`)** | `0 cycles` / `0 cycles` | `0-cycle` deskewed alignment | **PASS** |
| **Live SRAM Reads Corrected by SECDED (`ecc_single_bit_corrected_reads`)** | **`142 reads`** | Every weight, KV-cache & embedding read corrected in-flight | **PASS** |
| **Uncorrectable Double-Bit ECC Errors (`ecc_double_bit_errors`)** | `0` | `0` uncorrectable errors | **PASS** |
| **Cycle-by-Cycle Stream Mismatches (`u_lpu_chip0` vs. `u_chip0_ecc_dut`)** | **`0`** | `100%` cycle-by-cycle & bit-for-bit equivalence | **PASS** |

---

## 5. VCD Switching Activity & Trace-Driven Energy-Per-Token Analysis

From the exported Verilator VCD waveform (`benchmarks/llm_inference_rtl/llm_decode_cluster.vcd`) and hardware power-gating telemetry counters calibrated to our FreePDK45nm post-synthesis library:

- **MXM Hardware Zero-Skip Gating**: Across the 16 matrix-vector contractions (`4,096` raw INT8 MACs across Chip 0 and Chip 1), hardware activation zero-skip (`act_zero_gate_en_i = 1'b1`) gated **`736` MACs (`17.97%` MAC gating)** (`23` zero activation lanes per chip $\times 16$ columns $\times 2$ chips), leaving `3,360` active MACs.
- **VXM Operand Isolation Gating**: Multiplier operand isolation (`mul_gate_active_o`) was active for **`268 / 272` cycles (`98.5%`)**, and nonlinear LUT operand isolation (`lut_gate_active_o`) was active for **`269 / 272` cycles (`98.9%`)**.
- **Valid-Driven Stream Register Clock Gating**: Across the 2-chip cluster, **`812` channel-0 stream hops** were clock-gated with zero data FF toggles (`chip0_gated_hops = 406`, `chip1_gated_hops = 406`).

| Subsystem / Functional Unit | Active Events (2-Chip Cluster) | Dynamic Energy (`pJ`) | Share (`%`) | Energy Saved by Hardware Gating (`pJ`) |
| :--- | :---: | :---: | :---: | :---: |
| **On-Chip SRAM Slices (`MEM_W` + `MEM_E` + SECDED ECC)** | `294` 144-bit R/W accesses | `4,174.80 pJ` | `70.11%` | Bank sleep & Conflict-free 1R1W |
| **Systolic Matrix Units (`MXM_W` + `MXM_E`, 2 Chips)** | `3,360` active MACs (`736` gated) | `1,411.20 pJ` | `23.70%` | **`309.12 pJ` saved** (`17.97%` zero-skip) |
| **Bidirectional Spatial Stream Fabric (`32 x 128b`)** | `812` gated channel-0 hops | `264.69 pJ` | `4.45%` | **`1,266.72 pJ` saved** (valid-driven gating) |
| **Dragonfly C2C Link + `RealSync` Deskew + `NIM_ALLREDUCE`** | `2` C2C flits (`Chip0<->Chip1`) | `45.00 pJ` | `0.76%` | In-network AllReduce eliminates SRAM spill |
| **Vector Execution Module (`VXM` 16-Lane SIMD + LUT)** | `22` vector/LUT/reduction ops | `40.70 pJ` | `0.68%` | Operand isolation (`98.5%` mul / `98.9%` lut gated) |
| **Spatial Switch & Permute Module (`SXM` RoPE/Broadcast)** | `20` spatial permute ops | `19.00 pJ` | `0.32%` | Zero-SRAM spatial wire permutation |
| **Total 2-Chip Cluster Energy per Token** | **272 cycles (`272 ns`)** | **`5,955.39 pJ` (`5.96 nJ/token`)** | **`100.0%`** | **`1,575.84 pJ` saved (`20.92%` reduction)** |

---

## 6. Generated Benchmark Artifacts (`ict-eda-9`)

- `benchmarks/llm_inference_rtl/gen_llm_schedule_and_golden.py` — Deterministic 4-stage VLIW compiler & bit-exact Python golden reference generator.
- `benchmarks/llm_inference_rtl/tb_llm_inference_cluster.sv` — 2-Chip `groq_lpu_cluster_top` + live SECDED ECC fault-injection (`u_chip0_ecc_dut`) SystemVerilog testbench.
- `benchmarks/llm_inference_rtl/sim_llm_main.cpp` — Verilator 5.054 C++ simulation driver with VCD trace generation (`llm_decode_cluster.vcd`).
- `benchmarks/llm_inference_rtl/verify_llm_rtl_vs_golden.py` — Automated bit-exact scoreboard & VCD switching power analyzer.
- `benchmarks/llm_inference_rtl/llm_benchmark_results.json` — Complete machine-readable verification & energy report.
- `reports/STAGE9_LLM_INFERENCE_RTL_REPORT.md` — This comprehensive Stage 9 engineering report.
