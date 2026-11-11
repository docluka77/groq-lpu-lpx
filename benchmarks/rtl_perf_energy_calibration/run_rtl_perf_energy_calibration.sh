#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

VERILATOR_BIN="/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain/verilator-5.054/bin/verilator"

"${VERILATOR_BIN}" --binary -j 8 -Wno-fatal \
  --top-module tb_rtl_perf_energy_calibration \
  -I../../rtl -I../../sram_ip \
  ../../rtl/groq_pkg.sv \
  ../../sram_ip/groq_sram_ecc_secded.sv \
  ../../sram_ip/groq_sram_macro_sp.sv \
  ../../sram_ip/groq_mem_agu.sv \
  ../../sram_ip/groq_mem_slice.sv \
  ../../sram_ip/groq_sram_controller_scrubber.sv \
  ../../rtl/groq_icu_slice.sv \
  ../../rtl/groq_sxm_slice.sv \
  ../../rtl/groq_vxm_slice.sv \
  ../../rtl/groq_mxm_slice.sv \
  ../../rtl/groq_stream_fabric.sv \
  ../../rtl/groq_nim_realsync.sv \
  ../../rtl/groq_lpu_top.sv \
  ../../rtl/groq_lpu_cluster_top.sv \
  ../../rtl/groq_mxfp8_nvfp4_dot_engine.sv \
  ../../rtl/groq_c2c_kv_quant_rx_engine.sv \
  ../../rtl/groq_spec_decode_tree_sampler.sv \
  ../../rtl/groq_power_droop_controller.sv \
  tb_rtl_perf_energy_calibration.sv \
  -o sim_rtl_perf_energy

./obj_dir/sim_rtl_perf_energy
rm -rf obj_dir
python3 calibrate_sim_vs_reported_benchmarks.py
