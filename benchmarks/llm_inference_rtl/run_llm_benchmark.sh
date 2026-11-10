#!/usr/bin/env bash
set -euo pipefail

DIR="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/benchmarks/llm_inference_rtl"
ROOT="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106"
TC="/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain"
export VERILATOR_ROOT="${TC}/verilator-5.054"
VERILATOR="${VERILATOR_ROOT}/bin/verilator"

python3 -c '
for fn in ["/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_lpu_top.sv", "/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl/groq_lpu_cluster_top.sv"]:
    s = open(fn).read()
    s = s.replace("\nifdef FORMAL", "\n`ifdef FORMAL").replace("\nendif\n", "\n`endif\n")
    open(fn, "w").write(s)
'

cd "${DIR}"
python3 gen_llm_schedule_and_golden.py

"${VERILATOR}" --cc --exe --build --timing --trace \
  -j 8 -Wno-fatal \
  --top-module tb_llm_inference_cluster \
  --Mdir "${DIR}/build" \
  +incdir+"${ROOT}/rtl" \
  +incdir+"${ROOT}/sram_ip" \
  "${ROOT}/rtl/groq_pkg.sv" \
  "${ROOT}/sram_ip/groq_sram_ecc_secded.sv" \
  "${ROOT}/sram_ip/groq_sram_macro_sp.sv" \
  "${ROOT}/sram_ip/groq_mem_agu.sv" \
  "${ROOT}/sram_ip/groq_mem_slice.sv" \
  "${ROOT}/rtl/groq_icu_slice.sv" \
  "${ROOT}/rtl/groq_stream_fabric.sv" \
  "${ROOT}/rtl/groq_sxm_slice.sv" \
  "${ROOT}/rtl/groq_vxm_slice.sv" \
  "${ROOT}/rtl/groq_mxm_slice.sv" \
  "${ROOT}/rtl/groq_nim_realsync.sv" \
  "${ROOT}/rtl/groq_lpu_top.sv" \
  "${ROOT}/rtl/groq_lpu_cluster_top.sv" \
  "${DIR}/tb_llm_inference_cluster.sv" \
  "${DIR}/sim_llm_main.cpp" \
  -CFLAGS "-O2 -std=c++17" \
  -o llm_cluster_sim > "${DIR}/compile.log" 2>&1

"${DIR}/build/llm_cluster_sim"
cat "${DIR}/rtl_execution_trace.json"
python3 "${DIR}/verify_llm_rtl_vs_golden.py"
