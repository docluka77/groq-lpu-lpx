#!/usr/bin/env bash
set -euo pipefail

DIR="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/benchmarks/disagg_prefill_decode_8chip"
ROOT="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106"
TC="/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain"
export VERILATOR_ROOT="${TC}/verilator-5.054"
VERILATOR="${VERILATOR_ROOT}/bin/verilator"

cd "${DIR}"

python3 "${DIR}/gen_disagg_prefill_decode_vectors.py"

"${VERILATOR}" --binary -j 8 -Wno-fatal \
  --top-module tb_disagg_prefill_decode_8chip \
  --Mdir "${DIR}/build" \
  +incdir+"${ROOT}/rtl" \
  +incdir+"${ROOT}/sram_ip" \
  "${ROOT}/rtl/groq_pkg.sv" \
  "${ROOT}/sram_ip/groq_sram_ecc_secded.sv" \
  "${ROOT}/sram_ip/groq_sram_macro_sp.sv" \
  "${ROOT}/sram_ip/groq_mem_agu.sv" \
  "${ROOT}/sram_ip/groq_mem_slice.sv" \
  "${ROOT}/sram_ip/groq_sram_controller_scrubber.sv" \
  "${ROOT}/rtl/groq_icu_slice.sv" \
  "${ROOT}/rtl/groq_stream_fabric.sv" \
  "${ROOT}/rtl/groq_sxm_slice.sv" \
  "${ROOT}/rtl/groq_vxm_slice.sv" \
  "${ROOT}/rtl/groq_mxm_slice.sv" \
  "${ROOT}/rtl/groq_nim_realsync.sv" \
  "${ROOT}/rtl/groq_lpu_top.sv" \
  "${ROOT}/rtl/groq_c2c_serdes_pcs.sv" \
  "${ROOT}/rtl/groq_pcie_c2c_dma.sv" \
  "${ROOT}/rtl/groq_c2c_kv_quant_rx_engine.sv" \
  "${ROOT}/rtl/groq_mxfp8_nvfp4_dot_engine.sv" \
  "${ROOT}/rtl/groq_dragonfly_8chip_cluster.sv" \
  "${ROOT}/rtl/groq_spec_decode_tree_sampler.sv" \
  "${ROOT}/rtl/groq_power_droop_controller.sv" \
  "${DIR}/tb_disagg_prefill_decode_8chip.sv" \
  -o disagg_prefill_decode_8chip_sim > "${DIR}/compile.log" 2>&1

"${DIR}/build/disagg_prefill_decode_8chip_sim" | tee "${DIR}/disagg_prefill_decode_rtl.log"
python3 "${DIR}/gen_disagg_prefill_decode_vectors.py" --verify
cat "${DIR}/disagg_prefill_decode_summary.json"
