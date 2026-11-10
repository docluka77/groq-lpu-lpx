# Synthesizable SystemVerilog RTL (`rtl/`)

This directory contains **16 synthesizable SystemVerilog RTL modules (`8,638` lines total)** implementing both the **Groq LPU (14nm TSP)** spatial superlane architecture and the **NVIDIA Groq 3 LPX (4nm)** rack-scale extensions.

| File | Lines | Module Description | Literature / Patent Reference |
| :--- | :---: | :--- | :--- |
| [`groq_pkg.sv`](groq_pkg.sv) | 189 | Global package: 20-field `144-bit` VLIW instruction bundle (`groq_vliw_instr_t`), slice opcodes, stream & precision types | `[S01]`, `[S13]` (`US10691459B2`) |
| [`groq_stream_fabric.sv`](groq_stream_fabric.sv) | 288 | 8-Hop × 32-Channel × 128-bit East/West bidirectional spatial stream register fabric with `valid`-driven clock gating | `[S01]`, `[S15]` (`US10831507B2`) |
| [`groq_icu_slice.sv`](groq_icu_slice.sv) | 347 | Central 144-bit VLIW Instruction Control Unit (`Hop 5`) with hardware `SYNC`/`NOTIFY` barrier and `NOP_DELAY` countdown | `[S01]`, `[S13]` (`US10691459B2`) |
| [`groq_mxm_slice.sv`](groq_mxm_slice.sv) | 380 | 16×16 weight-stationary systolic Matrix Execution Module (`Hop 4, 6`) with dual ping-pong weight buffers & zero-skip isolation | `[S01]`, `[S14]` (`US10762052B1`) |
| [`groq_sxm_slice.sv`](groq_sxm_slice.sv) | 283 | 16-Lane Crossbar Switch, 16×16 two-phase matrix transpose & saturating RoPE butterfly (`Hop 2`, `BUG-LIT-001`) | `[S01]`, `[S18]` (`US11080048B2`) |
| [`groq_vxm_slice.sv`](groq_vxm_slice.sv) | 491 | 16-Lane SIMD ALU, piecewise-linear activation LUT (`SiLU`/`GELU`/`Exp`/`Rsqrt`), tree reduction & IEEE 754-2019 `PREC_INT8_RNE` (`Hop 3`, `BUG-LIT-005`) | `[S01]`, `[S21]` (`US11263129B1`) |
| [`groq_nim_realsync.sv`](groq_nim_realsync.sv) | 396 | Network Interface Module (`Hop 0`) with `RealSync` `±4`-cycle plesiochronous deskew FIFO, autonomous HAC lock (`BUG-LIT-003`), CRC-8 & UGAL routing | `[S02]`, `[S19]` (`US11157442B2`) |
| [`groq_lpu_top.sv`](groq_lpu_top.sv) | 946 | Full single-chip Groq LPU spatial superlane top-level integrating all 8 functional slices, stream fabric, and performance counters | `[S01]`, `[S04]` |
| [`groq_lpu_cluster_top.sv`](groq_lpu_cluster_top.sv) | 479 | 2-Chip `RealSync` plesiochronous C2C cluster top with configurable link flight delay and skew injection | `[S02]`, `[S03]` |
| [`groq_mxfp8_nvfp4_dot_engine.sv`](groq_mxfp8_nvfp4_dot_engine.sv) | 561 | **Groq 3 LPX**: OCP MXFP8 (`E4M3`/`E5M2` + `E8M0`) & native `NVFP4_E4M3_SCALE` (`3'd5`, `BUG-LIT-002`) block-scaled tensor dot engine | `[S26]`, `[S43]` |
| [`groq_c2c_serdes_pcs.sv`](groq_c2c_serdes_pcs.sv) | 428 | **Groq 3 LPX**: 112G PAM4 C2C SerDes PCS (`64B/66B` scrambler, gearbox, `RS(72,64)` FEC & `RealSync` elastic deskew buffer) | `[S02]`, `[S53]` |
| [`groq_pcie_c2c_dma.sv`](groq_pcie_c2c_dma.sv) | 348 | **Groq 3 LPX**: PCIe Gen5 / NVLink-C2C scatter-gather descriptor ring DMA & deterministic weight-page preloader | `[S26]`, `[S32]` |
| [`groq_dragonfly_8chip_cluster.sv`](groq_dragonfly_8chip_cluster.sv) | 665 | **Groq 3 LPX**: 8-Chip Dragonfly group (`a=8, p=4, h=4`) with UGAL congestion sensing & Radix-2 XOR butterfly `AllReduce` | `[S02]`, `[S22]` (`US11341068B2`) |
| [`groq_spec_decode_tree_sampler.sv`](groq_spec_decode_tree_sampler.sv) | 380 | **Groq 3 LPX**: 16-Lane bitonic `Top-K`/`Top-P` nucleus sampler & 8-node EAGLE-2 speculative tree verifier with cumulative log-prob (`BUG-LIT-007`) | `[S48]`, `[S94]` |
| [`groq_power_droop_controller.sv`](groq_power_droop_controller.sv) | 206 | **Groq 3 LPX**: Deterministic VLIW pre-warm bleeder & synchronous $L \cdot di/dt$ voltage droop controller | `[S01]`, `[S98]` |
| [`groq_c2c_kv_quant_rx_engine.sv`](groq_c2c_kv_quant_rx_engine.sv) | 367 | **Groq 3 LPX**: Disaggregated prefill NVLink-C2C `FP16`/`BF16` $\rightarrow$ `MXFP8`/`NVFP4` KV-cache quantizer with dual `E8M0` + `E4M3` scale (`BUG-LIT-006`) | `[S26]`, `[S87]` |
