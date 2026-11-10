# Stage 16: Multi-Token Autoregressive Decode of DeepSeek-V3/R1 MLA + Routed MoE on 8-Chip Dragonfly RTL Report

## 1. Executive Summary

Stage 16 implements, executes, and verifies an end-to-end **4-Token Autoregressive Decode Chain (`Token 0 -> Token 1 -> Token 2 -> Token 3`)** of a **DeepSeek-V3 / DeepSeek-R1 Multi-Head Latent Attention (MLA) + Routed Mixture-of-Experts (MoE)** architecture across the cycle-accurate **8-Chip Dragonfly Group Scale-Out Cluster RTL (`groq_dragonfly_8chip_cluster`)** and **8 x `groq_mxfp8_nvfp4_dot_engine` (`W4A8_MIXED` & `NVFP4_E2M1`) Microscaling Co-Processors** using **Verilator 5.054**.

### Headline Verification Metrics

| Verification Metric | Target | Measured RTL Result | Status |
| :--- | :--- | :--- | :--- |
| **Autoregressive Decode Chain Length** | 4 chained tokens (`Token 0..3`) | **4 tokens (`x^(t+1) = y^(t)`)** | **PASS** |
| **Active LPU Chips in Dragonfly Group** | 8 chips (`Chip 0..7`) + 8 SerDes PCS + DMA | **8 LPUs + 8 PCS + 8 Dot Engines** | **PASS** |
| **On-Chip `AGU_KV_RING` Causal Cache Growth** | `seq_len: 1 -> 2 -> 3 -> 4` | **`seq_len: 1 -> 2 -> 3 -> 4` (Bank 1, Addr 16..19)** | **PASS** |
| **Total Lockstep Execution Cycles** | Deterministic VLIW schedule | **1,206 cycles (`300 cyc/token`)** | **PASS** |
| **Host NVLink-C2C / PCIe Gen5 DMA Preload** | 0 parity errors | **1,040 beats (`16.64 KB`), `0` parity errors** | **PASS** |
| **Total Tensor & Co-Processor Checks** | 32 token-chip pairs $\times$ 22 checks | **704 / 704 checks matched** | **PASS** |
| **Bit-Exact Accuracy vs. Python Golden** | `0` bit errors | **`0` bit errors (100% bit-exact)** | **PASS** |
| **Live SRAM SECDED 1-Bit ECC Upsets Injected** | Continuous across all 8 chips | **4,672 single-bit upsets corrected in-flight** | **PASS** |
| **ECC Shadow vs. Primary Cluster Stream Mismatch** | `0` mismatches | **`0` mismatches (`0` double-bit errors)** | **PASS** |
| **Live C2C PCS CRC-16 Link Bit-Flips Injected** | Inject during `AllToAll` & `AllReduce` | **64 frames corrupted (`32` Butterfly + `32` Ring)** | **PASS** |
| **Hardware Go-Back-N Link Replays Triggered** | 100% transparent recovery | **64 / 64 NACK + Go-Back-N replays (`0` slip)** | **PASS** |
| **Total C2C Flits & RealSync Deskew Releases** | 100% delivery at exact target cycle | **128 flits TX / 128 RealSync deskew releases** | **PASS** |
| **Total MXM Zero-Skip Lanes Gated** | Causal KV + sparse activation gating | **597 zero-skip lanes gated** | **PASS** |

---

## 2. 4-Stage Per-Token DeepSeek MLA + Routed MoE Hardware Pipeline (`300` Cycles/Token)

Each autoregressive token $t \in \{0, 1, 2, 3\}$ executes a deterministic 300-cycle VLIW schedule (`BASE_PC = t * 300`) in lockstep across all 8 chips (`Chip 0..7`):

1. **Stage A (`BASE_PC + 1 .. 93`) — MLA RMSNorm, Low-Rank KV Compression, Decoupled RoPE & `AGU_KV_RING` Cache Append**:
   - `SLICE_MEM_W` reads the current input token embedding $x^{(t, c)}$ from `(Bank 0, Addr 0)` (which at $t = 0$ is the initial prompt embedding $x^{(0)}$, and at $t \in \{1, 2, 3\}$ is the previous token's 8-chip AllReduced output $y^{(t-1, c)}$ written back at `BASE_PC - 20`).
   - `SLICE_VXM` and `SLICE_SXM` compute hardware **RMSNorm**:
     $$\hat{x}_t^{(c)} = \text{QuantScale}\!\left(x^{(t, c)} \odot \text{Broadcast}\!\left(\text{RSQRT\_LUT}\!\left(\sum_{i=0}^{15} (x_i^{(t, c)})^2\right)\right), \text{shamt}=3\right)$$
   - `SLICE_MXM_W` and `SLICE_MXM_E` execute parallel INT8 matrix contractions for Query $q_{\text{raw},t}^{(c)} = \hat{x}_t^{(c)} W_Q^{(c)}$, **MLA Compressed KV Latent** $c_{\text{raw},t}^{KV,(c)} = \hat{x}_t^{(c)} W_{DKV}^{(c)}$, and MoE Router Logits $r_{\text{logits},t}^{(c)} = \hat{x}_t^{(c)} W_{\text{router}}^{(c)}$.
   - `SLICE_SXM` (`SXM_BUTTERFLY_SWAP`) and `SLICE_VXM` (`VXM_FMA`) apply **Decoupled RoPE** to produce $q_{\text{rope},t}^{(c)}$ and $c_{\text{rope},t}^{KV,(c)}$.
   - `SLICE_MEM_W` appends $c_{\text{rope},t}^{KV,(c)}$ into the on-chip circular KV-Latent cache in West SRAM `(Bank 1, Addr 16 + t)` using hardware **`AGU_KV_RING` (`2'b10`, `wr_agu_use = 1`)**, growing the active causal sequence length `seq_len: 1 -> 2 -> 3 -> 4`.

2. **Stage B (`BASE_PC + 94 .. 181`) — Causal Latent Attention over Growing `AGU_KV_RING`, Softmax, Up-Projection & Residual Add**:
   - `SLICE_MEM_W` streams the 16-row causal KV-Latent cache $C_{0..t}^{KV,(c)}$ from `(Bank 1, Addr 16..31)` into `SLICE_MXM_E`, where rows $0..t$ hold the live latent vectors $c_{\text{rope},0}^{KV,(c)} \dots c_{\text{rope},t}^{KV,(c)}$ and rows $t+1..15$ are zero-masked.
   - `SLICE_MXM_E` computes causal latent attention scores $s_{\text{attn},t}^{(c)} = q_{\text{rope},t}^{(c)} (C_{0..t}^{KV,(c)})^T$.
   - `SLICE_VXM` and `SLICE_SXM` execute numerically stable hardware Softmax (`VXM_REDUCE_MAX` $\to$ `VXM_BROADCAST_LANE` $\to$ `VXM_SUB` $\to$ `VXM_EXP_LUT` $\to$ `VXM_REDUCE_SUM` $\to$ `VXM_QUANT_SCALE`) to produce $p_{\text{attn},t}^{(c)}$.
   - `SLICE_MXM_E` up-projects $o_{\text{attn},t}^{(c)} = p_{\text{attn},t}^{(c)} W_{UKV}^{(c)}$, and `SLICE_VXM` computes the residual stream connection $h_{\text{attn},t}^{(c)} = \text{sat\_int8}(\hat{x}_t^{(c)} + o_{\text{attn},t}^{(c)})$.

3. **Stage C (`BASE_PC + 182 .. 200`) — 8-Chip Dragonfly MoE Router Gate & Butterfly `AllToAll` Expert Dispatch**:
   - The 8-chip Dragonfly switch configures **`ROUTE_MOE_ALLTOALL_BUTTERFLY` (`2'b11`)** with token-dependent Radix-2/8 XOR stages (`bstage = 1, 2, 4, 3` for Tokens `0, 1, 2, 3`).
   - All 8 chips simultaneously execute `NIM_SEND` at `off = 182` (`dst = c ^ bstage`), dispatching $h_{\text{attn},t}^{(c)}$ over the 64B/66B `groq_c2c_serdes_pcs` links, and `NIM_RECV` at `off = 185` when the RealSync elastic deskew buffer releases peer chip $(c \oplus \text{bstage})$'s vector $h_{\text{attn},t}^{(c \oplus \text{bstage})}$.
   - `SLICE_VXM` evaluates the MoE Router Gate activation $g_{\text{router},t}^{(c)} = \text{SiLU}(r_{\text{logits},t}^{(c)})$, combines local + Butterfly-dispatched activations $u_{\text{moe},t}^{(c)} = h_{\text{attn},t}^{(c)} + h_{\text{attn},t}^{(c \oplus \text{bstage})}$, and normalizes $e_{\text{in},t}^{(c)} = \text{QuantScale}(u_{\text{moe},t}^{(c)}, \text{shamt}=1)$.

4. **Stage D (`BASE_PC + 201 .. 295`) — 8-Chip Parallel Expert SwiGLU FFN, `W4A8`/`NVFP4` Microscaling & Ring `AllReduce`**:
   - Each chip $c \in \{0..7\}$ executes its dedicated expert FFN: $g_{\text{ffn},t}^{(c)} = e_{\text{in},t}^{(c)} W_{\text{gate}}^{(c)}$ (`MXM_W`), $u_{\text{ffn},t}^{(c)} = e_{\text{in},t}^{(c)} W_{\text{up}}^{(c)}$ (`MXM_E`), $h_{\text{swiglu},t}^{(c)} = \text{VXM\_SWIGLU}(g_{\text{ffn},t}^{(c)}, u_{\text{ffn},t}^{(c)})$ (`VXM`), and $y_{\text{down},t}^{(c)} = h_{\text{swiglu},t}^{(c)} W_{\text{down}}^{(c)}$ (`MXM_W`).
   - Simultaneously, each chip's companion **`groq_mxfp8_nvfp4_dot_engine`** executes **2-cycle microscaling dot products** on $h_{\text{swiglu},t}^{(c)}$ in both **`MODE_W4A8_MIXED` (`3'd4`)** (`E8M0 = 127/128`) and **`MODE_NVFP4_E2M1` (`3'd3`)** (`E8M0 = 127/127`), producing accumulated INT32 and IEEE-754 FP32 outputs plus per-sublane zero-skip telemetry.
   - The Dragonfly switch transitions to **`ROUTE_BIDIR_RING` (`2'b01`)** (`c -> (c + 1) % 8`) and executes a 2-step chained hardware **`NIM_ALLREDUCE_ADD`** (`off = 272 -> 275 -> 278`), writing the final reduced token embedding $y^{(t, c)}$ directly to West SRAM `(Bank 0, Addr 0)` (`off = 280`) as $x^{(t+1, c)} = y^{(t, c)}$ and to East SRAM `(Bank 0, Addr 10 + t)` (`off = 286`).


---

## 3. 4-Token Autoregressive Decode Trace Across 8 Chips (Selected Checkpoints)

Every token $t \in \{0, 1, 2, 3\}$ deterministically feeds $y^{(t, c)} \to x^{(t+1, c)}$ on all 8 chips (`Chip 0..7`) with **0 bit errors**:

| Token $t$ | `seq_len` | Butterfly Stage | Chip ID | Input Embedding $x_{\text{in}}^{(t, c)}$ (128b Hex) | Appended Latent $c_{\text{rope},t}^{KV,(c)}$ (128b Hex) | Butterfly Peer RX $h_{\text{peer},t}^{(c \oplus \text{bstage})}$ (128b Hex) | Final Ring AllReduce $y_{\text{final}}^{(t, c)} = x_{\text{in}}^{(t+1, c)}$ (128b Hex) | `NVFP4` IEEE FP32 | Bit Errors |
| :---: | :---: | :---: | :---: | :--- | :--- | :--- | :--- | :---: | :---: |
| **Token 0** | `1` | `bstage = 1` | **Chip 0** | `ff02ff0203fe0001fe0201fd0002fe03` | `4f02fb5133e744b1b12aa024cc5fa8e2` | `1e16ed2c2b01f30ef409e1e80bf2ccff` | `29d7a918802a8019f480bc8005db017f` | `0x42de0000` | `0` |
| **Token 0** | `1` | `bstage = 1` | **Chip 1** | `ff02ff0203fe0001fe0201fd0002fe03` | `1825d81cedcf47de18ceaf31ec02d022` | `19f500f0f8eefcf70825f918180202ea` | `7f992c2280b3899b1c807f807faa8016` | `0xc2f80000` | `0` |
| **Token 0** | `1` | `bstage = 1` | **Chip 4** | `ff02ff0203fe0001fe0201fd0002fe03` | `e6c9e8f8050939b3ec3807fe1d0407f7` | `fd0ce515fdeae3c8fef3e7ff11f3f81e` | `d7800e80ef80cb808e20fe348080c89c` | `0xc2920000` | `0` |
| **Token 0** | `1` | `bstage = 1` | **Chip 7** | `ff02ff0203fe0001fe0201fd0002fe03` | `ccaae131fc14242c581828e73e0c1621` | `ff15e0f82af321d9da0c0115fc0ee81c` | `1b561a9f804c937f5680712d1db2a0bd` | `0x41900000` | `0` |
| **Token 1** | `2` | `bstage = 2` | **Chip 0** | `29d7a918802a8019f480bc8005db017f` | `3df0dded1a50edb6a680430d26c0337d` | `1d102f220ff4dffefed6c9e00c1aeef6` | `78807f7f3c1e178b6be47f29037f7f7f` | `0xc2860000` | `0` |
| **Token 1** | `2` | `bstage = 2` | **Chip 1** | `7f992c2280b3899b1c807f807faa8016` | `2040b080a03000f04040b0e0e0002010` | `00d0201030d0308000f0f020e0502050` | `1f803a7f7f4b5bbef02c7f3b80537f7f` | `0xc2860000` | `0` |
| **Token 1** | `2` | `bstage = 2` | **Chip 4** | `d7800e80ef80cb808e20fe348080c89c` | `24f08cecfa20a6e6e0b03c14e6d014aa` | `d801f3dec80b00c119a106faffe8edfe` | `8075aad17ff47f7f7f5f7f629de53b4a` | `0xc1d80000` | `0` |
| **Token 1** | `2` | `bstage = 2` | **Chip 7** | `1b561a9f804c937f5680712d1db2a0bd` | `a0c0204080f0706070804040f010b0e0` | `1f2e0ae2f4e7100c2019ec0bf3d60b22` | `07c96c46c868f30cdb807f80b22a10d1` | `0xc3690000` | `0` |
| **Token 2** | `3` | `bstage = 4` | **Chip 0** | `78807f7f3c1e178b6be47f29037f7f7f` | `1020d0e0a0e0e0f040f0500040f02060` | `f010101040e020102020e0102040f0e0` | `0f7f7fe36b63c97fbf68a38001ee7fae` | `0x426c0000` | `0` |
| **Token 2** | `3` | `bstage = 4` | **Chip 1** | `1f803a7f7f4b5bbef02c7f3b80537f7f` | `8000f0a0001060f0e0a0504080a04070` | `fb21e515dc14fa01f600e1fa0bf40b1a` | `80f049257f9f807fed7f80b1677f7f91` | `0x42fc0000` | `0` |
| **Token 2** | `3` | `bstage = 4` | **Chip 4** | `8075aad17ff47f7f7f5f7f629de53b4a` | `f0b0c060100010106030b000b0702020` | `031025fc2b0d15e30dd3f727072b16fd` | `14801c808014a783c476808cb37f017f` | `0xc31c0000` | `0` |
| **Token 2** | `3` | `bstage = 4` | **Chip 7** | `07c96c46c868f30cdb807f80b22a10d1` | `f0d0c01040f000d0f0a010f020a0c090` | `f0f0f0001010e0d020f00000f0000000` | `ff727fa2ad261f55807feab67f9b7f9a` | `0xc35c0000` | `0` |
| **Token 3** | `4` | `bstage = 3` | **Chip 0** | `0f7f7fe36b63c97fbf68a38001ee7fae` | `36907de0d39600703a5a3d803af39a70` | `e0d0001030d030802010d02000704070` | `bc807f4f28f3694b0d7f5634fb809e7f` | `0x431f0000` | `0` |
| **Token 3** | `4` | `bstage = 3` | **Chip 1** | `80f049257f9f807fed7f80b1677f7f91` | `0000f0e0e0f000500040f04040c02030` | `d82cf0d907d0b643222203e108350014` | `0dea16576fe7f325e97f32fe7f809c7f` | `0xc1000000` | `0` |
| **Token 3** | `4` | `bstage = 3` | **Chip 4** | `14801c808014a783c476808cb37f017f` | `a310cdc6362003162df02a061030ad33` | `f60fffe8d6d2f1100627eee01ff72f00` | `bc8090ba1a7f7fa080c29980fb36b87f` | `0x431a0000` | `0` |
| **Token 3** | `4` | `bstage = 3` | **Chip 7** | `ff727fa2ad261f55807feab67f9b7f9a` | `b01da616008a5a70b0d34abd00da401d` | `10dce3fd1d24e3d6f2f60df7e2362336` | `80a20e1de827a9f1a56d7f80b080807f` | `0xc3000000` | `0` |

*(Full 32-row log across all 4 tokens and all 8 chips is recorded in `benchmarks/deepseek_mla_moe_8chip/deepseek_mla_moe_8chip.log`.)*

---

## 4. Live Hardware Fault-Injection & Resilience Verification

1. **Live Single-Bit SRAM SECDED ECC Upsets (`4,672` In-Flight Corrections Across 8 Chips)**:
   - Eight shadow `groq_lpu_top` instances (`gen_shadow_and_dot[0..7]`) execute in lockstep with `mem_err_inject_en_i = 1'b1` and distinct single-bit codeword fault masks (`144'h1 << (c * 7 + 3)`), corrupting every SRAM read across `W_Q`, `W_DKV`, `W_router`, `AGU_KV_RING`, `W_UKV`, `W_gate`, `W_up`, `W_down`, and intermediate activations.
   - Across the 1,206-cycle 4-token run, **4,672** single-bit upsets were detected and corrected in-flight by the dual-subword Hamming(72,64) SECDED decoders with **0 double-bit errors** and **0 spatial stream mismatches** (`stream_mismatch_vs_ecc_dut = 0`).

2. **Live C2C PCS CRC-16 Link Bit-Flips & Go-Back-N Replay (`64` Link Errors Injected & Replayed)**:
   - During every token's **Stage C MoE Butterfly `AllToAll`** (`off = 183`, `pcs_err_inject_mask_i = 16'h0005`) and **Stage D Bidirectional Ring `AllReduce`** (`off = 273`, `pcs_err_inject_mask_i = 16'h0003`), the testbench injects live multi-bit frame errors simultaneously across all 8 SerDes PCS links (`4 tokens * 2 stages * 8 links = 64` corrupted 162-bit 64B/66B frames).
   - In all **64 / 64** cases:
     - Receiver `groq_c2c_serdes_pcs` detects `rx_crc16_err_o = 1'b1`, blocks the corrupted flit from entering `groq_nim_realsync`, and asserts `nack_req_o = 1'b1` back through the Dragonfly switch matrix.
     - Sender `groq_c2c_serdes_pcs` + companion `ts_replay_flat_q` automatically retransmit the uncorrupted frame + original RealSync timestamp from the 4-entry Go-Back-N replay buffer on the very next cycle (`T + 2`).
     - Destination `groq_nim_realsync` absorbs the 1-cycle replay latency inside its 4-slot RealSync elastic deskew buffer (`expected_flight_cycles_i = 3`), releasing all **128** C2C flits at their exact compiler-scheduled target cycle (`T + 3`) with **0 schedule slip and 0 bit errors**.

---

## 5. Artifact Inventory (`benchmarks/deepseek_mla_moe_8chip/`)

- `benchmarks/deepseek_mla_moe_8chip/gen_deepseek_mla_moe_golden.py` — Bit-exact 4-token $\times$ 8-chip DeepSeek MLA + Routed MoE compiler & golden generator.
- `benchmarks/deepseek_mla_moe_8chip/vectors/` — 64 VLIW instruction ROMs (`chip{0..7}_imem_s{0..7}.hex`), 8 SRAM preloads (`chip{0..7}_sram_preload.txt`), 8 microscaling weight files (`chip{0..7}_dot_weights.hex`), and golden check table (`golden_tokens_8chip.txt`).
- `benchmarks/deepseek_mla_moe_8chip/tb_deepseek_mla_moe_8chip.sv` & `sim_deepseek_main.cpp` — Cycle-accurate Verilator 5.054 8-chip testbench & C++ harness.
- `benchmarks/deepseek_mla_moe_8chip/run_deepseek_mla_moe_8chip.sh` — End-to-end build, simulation, and verification script.
- `benchmarks/deepseek_mla_moe_8chip/deepseek_mla_moe_8chip.log` & `rtl_execution_trace.json` — Verified execution log (`704/704` checks, `0` bit errors).
- `benchmarks/deepseek_mla_moe_8chip/deepseek_mla_moe_8chip.vcd` — Cycle-accurate waveform trace.
