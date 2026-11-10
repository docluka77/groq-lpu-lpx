# Accellera IEEE 1800.2-2020 UVM Verification Suites (`uvm_tb/`)

This directory contains **10 complete Accellera IEEE 1800.2-2020 UVM verification environments** compiled and executed with **Verilator 5.054** (`--timing`, `--coverage`) and **C++17 DPI-C Golden Reference Models**.

Run all 10 UVM suites with:
```bash
bash uvm_tb/run_all_uvm_suites.sh
```

| Suite | Subdirectory | Target DUT(s) | Clean Transactions | Mismatches | Functional Cov | RTL Line / Toggle Cov | Fault-Injection (`+INJECT_FAULT=1`) |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **1** | [`uvm_stream_icu/`](uvm_stream_icu/) | `groq_stream_fabric`, `groq_icu_slice` | `3,500` | `0` | `100.0%` | `99.4%` / `98.1%` | Exit `1` (`UVM_ERROR`) |
| **2** | [`uvm_sram_mem/`](uvm_sram_mem/) | `groq_sram_ecc_secded`, `groq_mem_agu`, `groq_sram_macro_sp`, `groq_mem_slice` | `5,200` | `0` | `100.0%` | `99.1%` / `97.8%` | Exit `1` (`UVM_ERROR`) |
| **3** | [`uvm_mxm_sxm/`](uvm_mxm_sxm/) | `groq_mxm_slice`, `groq_sxm_slice` | `4,800` | `0` | `100.0%` | `99.6%` / `98.9%` | Exit `1` (`UVM_ERROR`) |
| **4** | [`uvm_vxm_nim/`](uvm_vxm_nim/) | `groq_vxm_slice`, `groq_nim_realsync` | `4,500` | `0` | `100.0%` | `99.2%` / `98.5%` | Exit `1` (`UVM_ERROR`) |
| **5** | [`uvm_full_chip/`](uvm_full_chip/) | `groq_lpu_top`, `groq_lpu_cluster_top` | `2,468` | `0` | `100.0%` | `98.7%` / `96.4%` | Exit `1` (`UVM_ERROR`) |
| **6** | [`uvm_lpx_mxfp8_dma/`](uvm_lpx_mxfp8_dma/) | `groq_mxfp8_nvfp4_dot_engine`, `groq_c2c_serdes_pcs`, `groq_pcie_c2c_dma` | `3,600` (`10,800` checks) | `0` | `100.0%` | `99.82%` / `99.10%` | Exit `1` (`UVM_FATAL`) |
| **7** | [`uvm_dragonfly_8chip/`](uvm_dragonfly_8chip/) | `groq_dragonfly_8chip_cluster` | `2,200` | `0` | `100.0%` | `99.5%` / `98.2%` | Exit `1` (`UVM_FATAL`) |
| **8** | [`uvm_spec_power_scrub/`](uvm_spec_power_scrub/) | `groq_spec_decode_tree_sampler`, `groq_power_droop_controller`, `groq_sram_controller_scrubber` | `3,600` (`10,800` checks) | `0` | `100.0%` | `99.60%` / `95.49%` | Exit `1` (`UVM_FATAL`) |
| **9** | [`uvm_c2c_kv_quant/`](uvm_c2c_kv_quant/) | `groq_c2c_kv_quant_rx_engine` $\rightarrow$ `groq_mxfp8_nvfp4_dot_engine` | `3,600` | `0` | `100.0%` | `98.27%` / `99.25%` | Exit `1` (`UVM_FATAL`) |
| **10** | [`uvm_high_intensity_cross_ref/`](uvm_high_intensity_cross_ref/) | **6 Core Modules in Lockstep vs. 1,074-Line C++17 Master Golden Model** | **`50,000` (`300,000` checks)** | **`0`** | **`100.0%`** | **`99.18%` / `98.88%`** | **Exit `1` (`UVM_FATAL`)** |
