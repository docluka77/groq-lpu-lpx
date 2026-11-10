# Multi-Chip RTL & 256-LPX Rack-Scale LLM Inference Benchmarks (`benchmarks/`)

This directory contains **4 end-to-end LLM inference & rack-scale benchmarks** spanning 2-chip `RealSync` RTL clusters, 8-chip Dragonfly RTL groups, and 256-chip NVIDIA Groq 3 LPX MGX racks:

| Subdirectory | Workload & Hardware Scope | Key Verification & Performance Result |
| :--- | :--- | :--- |
| [`llm_inference_rtl/`](llm_inference_rtl/) | **Llama-3 & DeepSeek Decode on 2-Chip `RealSync` LPU Cluster (`groq_lpu_cluster_top`)** | `272` cycles, `21` tensors verified bit-exact (`0` bit errors), `0` `RealSync` skew/CRC faults |
| [`deepseek_mla_moe_8chip/`](deepseek_mla_moe_8chip/) | **DeepSeek-V3/R1 Multi-Head Latent Attention (MLA) + MoE on 8-Chip Dragonfly RTL Cluster** | `100%` bit-exact match vs. Python golden reference across 8-chip Radix-2 XOR butterfly `AllReduce` |
| [`disagg_prefill_decode_8chip/`](disagg_prefill_decode_8chip/) | **NVIDIA Vera Rubin GPU Prefill $\rightarrow$ NVLink-C2C KV Quantizer $\rightarrow$ 8-Chip LPX Decode + EAGLE-2** | `100%` bit-exact end-to-end closed-loop execution (`FP16` KV $\rightarrow$ `MXFP8`/`NVFP4` $\rightarrow$ Dot Engine $\rightarrow$ Speculative Tree) |
| [`lpx_rack_and_spec_decode/`](lpx_rack_and_spec_decode/) | **256-Chip NVIDIA Groq 3 LPX MGX Rack Simulator (`Llama-3.1 405B` & `DeepSeek-V3/R1 671B`)** | `Llama-3.1 405B`: **`0.52 J/tok`** (`59,925 tok/s` Full-Fabric EAGLE-2); `DeepSeek-V3 671B`: **`0.43 J/tok`** (`144,981 tok/s`) |
