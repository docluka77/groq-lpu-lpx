# Stage 15: Automated Deterministic Spatial VLIW Compiler & Static Hazard/Collision Verifier (`compiler/`)

## 1. Executive Summary
In accordance with Groq's ISCA 2020 (*"Think Fast: A Tensor Streaming Processor (TSP) for Accelerating Deep Learning Workloads"*) and ISCA 2022 (*"A Scale-Out Tensor Streaming Multiprocessor for Machine Learning"*) compiler-scheduled dataflow architecture, Stage 15 implements, qualifies, and co-simulates an industrial-grade **Deterministic Spatial VLIW Compiler & Static Schedule Hazard Verifier** (`compiler/groq_deterministic_compiler.py`). Because the Groq LPU hardware contains **zero reactive arbiters, zero caches, and zero stall signals**, the compiler has 100% cycle-exact ownership of all 8 spatial slice hops (`SLICE_NIM=0` through `SLICE_MEM_E=7`), all 32 bidirectional 128-bit superlane streams (16 Eastward + 16 Westward moving at 1 hop/cycle), all SRAM bank read/write ports, and all `ICU_NOP_DELAY(N)` / `ICU_HALT` instructions.

| Verification & Qualification Metric | Target Requirement | Measured Result | Status |
| :--- | :--- | :--- | :--- |
| **Supported High-Level `TensorGraphDAG` Operators** | All 17 DL / LLM spatial operators | **17 / 17 operators implemented & exercised** | **PASS** |
| **4D Space-Time `StreamReservationTable` Routing** | Zero-collision stream track selection | **100% collision-free across all 3 workloads** | **PASS** |
| **`ICU_NOP_DELAY(N)` Instruction Compression** | Multi-cycle idle run compression | **5.85x (W1), 12.13x (W2), 10.51x (W3)** | **PASS** |
| **Static Hazard Verifier (`StaticScheduleVerifier`)** | 0 collisions, 0 bank conflicts, 0 uninit reads | **0 hazards across all 39 DAG edges / 121 cycles** | **PASS** |
| **Negative Hazard Injection Qualification** | 100% detection of injected hazards | **4 / 4 injected hazards caught & rejected** | **PASS** |
| **Verilator 5.054 RTL Co-Simulation (`tb_compiler_rtl_cosim.sv`)** | 100% bit-exact match vs. DAG Spec & Golden | **9 / 9 128-bit vectors (144 / 144 lanes), 0 mismatches** | **PASS** |
| **RTL Hardware Runtime Faults (`collision_fault_o`, `crc_err_o`)** | `0` runtime faults across 2-chip cluster | **0 faults across 775 RTL clock cycles** | **PASS** |

---

## 2. Compiler Architecture & Mathematical Foundations

### 2.1 High-Level Tensor Graph IR (`TensorGraphDAG`)
Defined in `compiler/groq_deterministic_compiler.py`, `TensorGraphDAG` accepts arbitrary multi-layer Deep Learning / LLM computation graphs composed of 17 spatial operators (`OperatorType`):
- **Memory & Ring-Cache Operators (`SLICE_MEM_W` @ Hop 1, `SLICE_MEM_E` @ Hop 7)**:
  - `MEM_LOAD_STRIDED`: Strided tensor read onto Eastward (`0..15`) or Westward (`16..31`) streams.
  - `MEM_LOAD_KV_RING`: Modulo-ring KV-cache read (`eff_row = row_addr % ring_modulus`).
  - `MEM_STORE`: Deterministic stream capture and SECDED-protected SRAM bank write.
- **Matrix Systolic Contraction Operators (`SLICE_MXM_W` @ Hop 4, `SLICE_MXM_E` @ Hop 6)**:
  - `MXM_WEIGHT_PRELOAD`: Zero-stall background weight staging into Ping (`B0`) or Pong (`B1`) buffers.
  - `MXM_MATMUL_INT8`: 16x16 INT8 wavefront matrix-vector contraction into 32-bit accumulators.
  - `MXM_MATMUL_FP8`: 16x16 FP8 (`E4M3`) matrix-vector contraction with hardware zero-skip gating.
- **Spatial Switch & Permutation Operators (`SLICE_SXM` @ Hop 2)**:
  - `SXM_ROTATE`: 16-lane circular barrel shift / lane broadcast.
  - `SXM_TRANSPOSE`: 4x4 sub-tile matrix transpose and 16x16 zero-stall transpose buffer load/read.
  - `SXM_ROPE_BUTTERFLY`: Rotary Position Embedding (RoPE) XOR butterfly swap (`i ^ mask`) with even-lane sign negation.
- **Vector SIMD & Nonlinear LUT Operators (`SLICE_VXM` @ Hop 3)**:
  - `VXM_RMSNORM`: Reciprocal-square-root (`RSQRT_LUT`) normalization.
  - `VXM_SILU_SWIGLU`: Fused `SiLU(gate) * up` piecewise-linear LUT + Q1.6 fixed-point multiplier.
  - `VXM_SOFTMAX_REDUCE`: Hardware `EXP_LUT` and 4-level balanced 16-lane tree reductions (`SUM` / `MAX`).
  - `VXM_RESIDUAL_ADD`: Saturating 16-lane INT8 dual-stream addition (`sat_int8(a + b)`).
  - `VXM_QUANT_SCALE`: Dynamic rounding right-shift scaler to `INT8` or `FP8_E4M3`.
- **Multi-Chip Dragonfly & Plesiochronous `RealSync` Operators (`SLICE_NIM` @ Hop 0)**:
  - `NIM_SEND_REALSYNC`: Timestamped CRC-8 protected C2C flit transmission across Dragonfly links.
  - `NIM_RECV_REALSYNC`: Elastic deskew buffer release at exact target cycle $t_{\text{arr}} = t_{\text{tx}} + H_{\text{deskew}}$.
  - `NIM_ALLREDUCE_ADD`: In-network 16-lane saturating summation of deskewed C2C flit and local Westward stream.

### 2.2 4D Spatial-Temporal Stream Reservation Table (`StreamReservationTable`)
`StreamReservationTable` models the exact 4D occupancy tensor:
$$\text{Occupied}[t][h \in \{0..7\}][\text{dir} \in \{\text{EAST}, \text{WEST}\}][k \in \{0..15\}]$$
When producer slice $s_{\text{src}}$ is scheduled at cycle $t_{\text{prod}}$, its output is injected into the stream fabric at cycle $t_{\text{inj}} = t_{\text{prod}} + L_{\text{slice}}(s_{\text{src}})$ and propagates across all downstream hops $h = s_{\text{src}} + d \cdot \text{step}$ at cycle $t_{\text{inj}} + d$ until exiting the chip boundary. Consumer slice $s_{\text{dst}}$ receives and consumes the flit at exact cycle:
$$t_{\text{arr}} = t_{\text{prod}} + L_{\text{slice}}(s_{\text{src}}) + |s_{\text{dst}} - s_{\text{src}}|$$
For multi-input consumers (such as `VXM_SILU_SWIGLU`, `VXM_RESIDUAL_ADD`, and `NIM_ALLREDUCE_ADD`), `GroqDeterministicVliwCompiler` solves the coupled-spacetime constraint system across each connected wave component so that all incoming operand streams arrive at $s_{\text{dst}}$ at the **exact same clock cycle** on distinct, collision-free stream channels.

---

## 3. Formal Static Schedule Verifier & Negative Hazard Qualification (`StaticScheduleVerifier`)

Before emitting machine code or running hardware simulation, `StaticScheduleVerifier` mathematically verifies four safety invariants over the compiled 144-bit VLIW schedule (`cycle_table[chip][t][slice]`):
1. **Zero Stream Write Collisions**: No slice ever injects onto `(hop, dir, stream_id)` at cycle $t$ when an upstream propagating flit from cycle $t-1$ arrives at `hop` (or when two injections target the same slot).
2. **Zero Uninitialized Stream Reads**: Every consumer slice reading `(hop, dir, stream_id)` at cycle $t$ reads a valid, deterministically scheduled producer flit (`valid == True`).
3. **Zero Same-Bank SRAM Read/Write Conflicts**: No cycle accesses the same physical SRAM bank `bank_id` for simultaneous read and write (or dual conflicting requests) on `SLICE_MEM_W` or `SLICE_MEM_E`.
4. **Exact Producer-Consumer Flight-Time Equation Verification**: Verifies $t_{\text{consume}} - t_{\text{issue}} = L_{\text{slice}} + |\text{hop}_{\text{dst}} - \text{hop}_{\text{src}}|$ (and $t_{\text{consume}} - t_{\text{issue}} = H_{\text{deskew}} = 5$ for inter-chip `RealSync` edges) for 100% of DAG edges.

### 3.1 Negative Hazard Injection Qualification Results
To prove that `StaticScheduleVerifier` has zero false negatives, four deliberate hazard mutations were injected into cloned schedules in `compiler/test_compiler_and_rtl_cosim.py`:

| Negative Hazard Test ID | Injected Schedule Fault | Expected Verifier Outcome | Measured Verifier Diagnostic | Status |
| :--- | :--- | :--- | :--- | :--- |
| **Negative Test 1** | Inject `SLICE_SXM` write onto occupied East Stream 0 at Cycle 2 | Reject (`stream_write_collisions > 0`) | `REJECTED (collisions=1)` at Chip 0 Cycle 2 Hop 2 (`SLICE_SXM`) | **PASS** |
| **Negative Test 2** | Inject simultaneous SRAM Read + Write on `SLICE_MEM_W` Bank 0 at Cycle 0 | Reject (`sram_bank_conflicts > 0`) | `REJECTED (bank_conflicts=2)` at Chip 0 Cycle 0 Hop 1 (`SLICE_MEM_W` Bank 0) | **PASS** |
| **Negative Test 3** | Inject `+1` cycle timing skew on consumer `w1_rmsnorm` | Reject (`flight_time_violations > 0` & `uninit_reads > 0`) | `REJECTED (flight_violations=2, uninit_reads=2)` (`t_consume - t_issue = 1 != 2`) | **PASS** |
| **Negative Test 4** | Inject `VXM_VADD` reading uninitialized East Stream 15 at Cycle 1 | Reject (`uninitialized_stream_reads > 0`) | `REJECTED (uninit_reads=2)` at Chip 0 Cycle 1 Hop 3 (`SLICE_VXM`) | **PASS** |

---

## 4. End-to-End Workload Compilation & Verilator 5.054 RTL Co-Simulation Results

All three workloads were compiled into 144-bit `groq_vliw_instr_t` hex files (`compiler/out/*.hex`) and synthesizable SystemVerilog ROM tables (`compiler/out/w1_rom.svh`, `w2_rom.svh`, `w3_rom.svh`), and executed on **both** the Python Golden Reference (`arch_model/groq_golden_model.py` + `RtlBitExactSimulator`) **and** the Verilator 5.054 RTL co-simulation testbench (`compiler/tb_compiler_rtl_cosim.sv` instantiating `groq_lpu_cluster_top`):

| Workload | Nodes / Edges | Total Cycles | Unrolled 144b Bundles | `ICU_NOP_DELAY` Compressed Bundles | Compression Ratio | Static Hazards | RTL Co-Sim Vector Matches |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Workload 1**: Multi-Stage Attention + RoPE + KV-Ring Cache (`w1`) | 14 / 11 | 30 | 240 | 41 | **5.85x** | `0` | **3 / 3 (48/48 lanes)** |
| **Workload 2**: Fused SwiGLU MLP + Dynamic FP8 + Multi-Chip `RealSync` AllReduce (`w2`) | 16 / 13 | 47 | 752 | 62 | **12.13x** | `0` | **3 / 3 (48/48 lanes)** |
| **Workload 3**: DeepSeek-V3/R1 Multi-Head Latent Attention (`MLA`) + Routed MoE Dispatch (`w3`) | 19 / 15 | 44 | 704 | 67 | **10.51x** | `0` | **3 / 3 (48/48 lanes)** |
| **Total Across All 3 Workloads** | **49 / 39** | **121** | **1,696** | **170** | **9.98x avg** | **`0`** | **9 / 9 (144/144 lanes)** |

### 4.1 Bit-Exact 128-Bit (16-Lane) Golden vs. Verilator RTL Co-Simulation Comparison

| Workload & Target SRAM Check | Chip / Slice / Bank / Row | High-Level DAG Spec & Golden Model (128-bit Hex) | Verilator 5.054 RTL Co-Simulation (128-bit Hex) | Bit-Exact Agreement |
| :--- | :--- | :--- | :--- | :---: |
| `W1_C0_E_B0_R8` (Q-Projection Output) | Chip 0 `MEM_E` Bank 0 Row 8 | `6e3236fafec2464aced2165a5ea2a62a` | `6e3236fafec2464aced2165a5ea2a62a` | **EXACT MATCH** |
| `W1_C0_E_B1_R9` (RoPE + Attention Context) | Chip 0 `MEM_E` Bank 1 Row 9 | `d88878a898487868180838e8d808f8a8` | `d88878a898487868180838e8d808f8a8` | **EXACT MATCH** |
| `W1_C0_W_B2_R10` (Softmax + SXM Rotate Output) | Chip 0 `MEM_W` Bank 2 Row 10 | `7f01017f7f7f7f7f7f371f7f5f011f01` | `7f01017f7f7f7f7f7f371f7f5f011f01` | **EXACT MATCH** |
| `W2_C0_E_B0_R11` (Fused SwiGLU + FP8 Down-Proj) | Chip 0 `MEM_E` Bank 0 Row 11 | `d7c0aa64ae346dc688504884609d4292` | `d7c0aa64ae346dc688504884609d4292` | **EXACT MATCH** |
| `W2_C0_W_B3_R12` (FP8 Quant + 4x4 Transpose) | Chip 0 `MEM_W` Bank 3 Row 12 | `ecd7c430e01a28cfd537242132e3c2c9` | `ecd7c430e01a28cfd537242132e3c2c9` | **EXACT MATCH** |
| `W2_C1_E_B2_R12` (Multi-Chip `RealSync` AllReduce) | Chip 1 `MEM_E` Bank 2 Row 12 | `26f2c27fe65062a6a86232227f12c6ca` | `26f2c27fe65062a6a86232227f12c6ca` | **EXACT MATCH** |
| `W3_C0_E_B2_R13` (DeepSeek MLA $c_t^{KV}$ Up-Proj) | Chip 0 `MEM_E` Bank 2 Row 13 | `f0486078906800187088a07890284098` | `f0486078906800187088a07890284098` | **EXACT MATCH** |
| `W3_C0_E_B3_R14` (MLA Decoupled RoPE + FP8 Value) | Chip 0 `MEM_E` Bank 3 Row 14 | `ee874d4cd0790a2d7064c29fb8969b00` | `ee874d4cd0790a2d7064c29fb8969b00` | **EXACT MATCH** |
| `W3_C1_E_B3_R15` (C2C Routed MoE Expert Output) | Chip 1 `MEM_E` Bank 3 Row 15 | `b4239241b09f0ebd2c1b4ab928970675` | `b4239241b09f0ebd2c1b4ab928970675` | **EXACT MATCH** |

---

## 5. Artifact Inventory
- `compiler/groq_deterministic_compiler.py`: High-Level `TensorGraphDAG` IR, 4D `StreamReservationTable`, Coupled-Spacetime VLIW Compiler (`GroqDeterministicVliwCompiler`), `ICU_NOP_DELAY(N)` Compressor, `StaticScheduleVerifier`, 144-bit Machine Code Emitter (`emit_vliw_hex`, `emit_sv_rom`), and Bit-Exact Co-Execution Engine.
- `compiler/tb_compiler_rtl_cosim.sv` & `compiler/sim_compiler_cosim.cpp`: Verilator 5.054 2-Chip Cluster RTL Co-Simulation Testbench executing compiler-generated 144-bit VLIW ROMs (`w1_rom.svh`, `w2_rom.svh`, `w3_rom.svh`).
- `compiler/test_compiler_and_rtl_cosim.py`: Automated end-to-end verification & negative hazard injection test suite.
- `compiler/compiler_verification.log` & `compiler/out/compiler_verification_summary.json`: Complete verification log and JSON telemetry summary.
- `reports/STAGE15_DETERMINISTIC_COMPILER_REPORT.md`: Stage 15 technical report.
