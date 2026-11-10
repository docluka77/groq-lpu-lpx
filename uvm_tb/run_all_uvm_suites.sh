#!/usr/bin/env bash
# =============================================================================
# File: uvm_tb/run_all_uvm_suites.sh
# Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
# Description: Master Runner for all 10 Accellera IEEE 1800.2-2020 UVM
#              Verification Suites (Verilator 5.054 + UVM 2020.3.1)
# =============================================================================
set -euo pipefail

UVM_ROOT="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb"

echo "=== Running Suite 1: uvm_stream_icu ==="
bash "${UVM_ROOT}/uvm_stream_icu/run_uvm_stream_icu.sh"

echo "=== Running Suite 2: uvm_sram_mem ==="
python3 "${UVM_ROOT}/uvm_sram_mem/run_uvm_sram_mem.py"

echo "=== Running Suite 3: uvm_mxm_sxm ==="
bash "${UVM_ROOT}/uvm_mxm_sxm/run_uvm_mxm_sxm.sh"

echo "=== Running Suite 4: uvm_vxm_nim ==="
bash "${UVM_ROOT}/uvm_vxm_nim/run_uvm_vxm_nim.sh"

echo "=== Running Suite 5: uvm_full_chip ==="
bash "${UVM_ROOT}/uvm_full_chip/run_uvm_full_chip.sh"

echo "=== Running Suite 6: uvm_lpx_mxfp8_dma ==="
bash "${UVM_ROOT}/uvm_lpx_mxfp8_dma/run_uvm_lpx_mxfp8_dma.sh"

echo "=== Running Suite 7: uvm_dragonfly_8chip ==="
bash "${UVM_ROOT}/uvm_dragonfly_8chip/run_uvm_dragonfly_8chip.sh"

echo "=== Running Suite 8: uvm_spec_power_scrub ==="
bash "${UVM_ROOT}/uvm_spec_power_scrub/run_uvm_spec_power_scrub.sh"

echo "=== Running Suite 9: uvm_c2c_kv_quant ==="
bash "${UVM_ROOT}/uvm_c2c_kv_quant/run_uvm.sh"

echo "=== ALL 9 ACCELLERA IEEE 1800.2-2020 UVM SUITES PASSED ==="

echo "=== Running Suite 10: uvm_high_intensity_cross_ref ==="
bash "${UVM_ROOT}/uvm_high_intensity_cross_ref/run_uvm_high_intensity_cross_ref.sh"

echo "=== ALL 10 ACCELLERA IEEE 1800.2-2020 UVM SUITES PASSED ==="
