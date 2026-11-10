# Stage 14B: Accellera IEEE 1800.2-2020 UVM Verification Report ??8-Chip Dragonfly Cluster (`groq_dragonfly_8chip_cluster`)

## 1. Executive Summary
- **DUT**: `groq_dragonfly_8chip_cluster` (8 ? `groq_lpu_top` + 8 ? `groq_c2c_serdes_pcs` + 1 ? `groq_pcie_c2c_dma` + 8?8 Dragonfly Switch Matrix)
- **UVM Library**: Accellera IEEE 1800.2-2020 (`uvm-core-2020.3.1`) + Verilator 5.054 (`--timing --coverage`) + C++17 DPI-C Reference Model (`dpi_dragonfly_8chip_ref.cpp`)
- **Clean Run Result (`results/clean/uvm_clean.log` & `dragonfly_8chip_summary.json`)**:
  - **Simulation Cycles**: `3,102` cycles (`3,102` DPI-C reference invocations)
  - **C2C Payload End-to-End Checks**: `2,145` flits across all 8 chips and all 4 collective routing modes (`ROUTE_DIRECT_CROSSBAR`, `ROUTE_BIDIR_RING`, `ROUTE_UGAL_ADAPTIVE`, `ROUTE_MOE_ALLTOALL_BUTTERFLY`)
  - **Host DMA & VLIW Admission Window Stalls**: `31` deterministic admission stalls, `11` parity error rejections
  - **64B/66B PCS CRC-16 Faults & Go-Back-N Replay Recoveries**: `92` CRC-16 link errors injected, `288` Go-Back-N replay flits recovered with `0` dropped packets
  - **Plesiochronous RealSync Deskew & SRAM SECDED ECC**: `314` deskew release events, `75` single-bit ECC corrections, `75` double-bit ECC detections across all 8 chips
  - **Scoreboard Mismatches**: `0` (`UVM_ERROR : 0`, `UVM_FATAL : 0`)
  - **Functional Coverage**: `100.00%` (15/15 coverpoints and crosses at 100%)
- **Fault-Injection Qualification (`fault_injection_qual.log`, `+INJECT_FAULT=1`)**:
  - **Exit Code**: `1` (`6,476` `UVM_ERROR`s caught by the DPI-C scoreboard)

## 2. Verilator LCOV Structural Coverage Summary
```text
=== Stage 14B 8-Chip Dragonfly Cluster RTL LCOV Coverage Summary ===
groq_c2c_serdes_pcs.sv             | Line:  166/ 186 ( 89.25%) | Toggle/Branch: 2681/2846 ( 94.20%)
groq_dragonfly_8chip_cluster.sv    | Line:  212/ 224 ( 94.64%) | Toggle/Branch: 14516/23725 ( 61.18%)
groq_icu_slice.sv                  | Line:   68/ 133 ( 51.13%) | Toggle/Branch:  534/2680 ( 19.93%)
groq_lpu_top.sv                    | Line:  139/ 184 ( 75.54%) | Toggle/Branch: 3311/11464 ( 28.88%)
groq_mxm_slice.sv                  | Line:   83/ 160 ( 51.88%) | Toggle/Branch:   74/2522 (  2.93%)
groq_nim_realsync.sv               | Line:  138/ 183 ( 75.41%) | Toggle/Branch: 2094/2308 ( 90.73%)
groq_pcie_c2c_dma.sv               | Line:  107/ 119 ( 89.92%) | Toggle/Branch: 1419/2160 ( 65.69%)
groq_stream_fabric.sv              | Line:   56/  63 ( 88.89%) | Toggle/Branch:  291/3658 (  7.96%)
groq_sxm_slice.sv                  | Line:   39/  70 ( 55.71%) | Toggle/Branch:   19/1608 (  1.18%)
groq_vxm_slice.sv                  | Line:   55/ 231 ( 23.81%) | Toggle/Branch:   22/4686 (  0.47%)
groq_mem_agu.sv                    | Line:   39/  98 ( 39.80%) | Toggle/Branch:   41/ 498 (  8.23%)
groq_mem_slice.sv                  | Line:   50/  86 ( 58.14%) | Toggle/Branch: 1604/2664 ( 60.21%)
groq_sram_ecc_secded.sv            | Line:   55/  55 (100.00%) | Toggle/Branch: 1023/1072 ( 95.43%)
groq_sram_macro_sp.sv              | Line:   60/ 178 ( 33.71%) | Toggle/Branch:  413/ 952 ( 43.38%)
TOTAL (8-Chip Dragonfly Cluster)   | Line: 1267/1970 ( 64.31%) | Toggle/Branch: 28042/62843 ( 44.62%)

```
