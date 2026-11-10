#!/usr/bin/env bash
set -euo pipefail

DIR="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_full_chip"
RTL="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl"
SRAM_IP="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/sram_ip"
TC="/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain"
export VERILATOR_ROOT="${TC}/verilator-5.054"
VERILATOR="${VERILATOR_ROOT}/bin/verilator"
VERILATOR_COV="${VERILATOR_ROOT}/bin/verilator_coverage"
UVM_SRC="${TC}/uvm-core-2020.3.1/src"

cd "${DIR}"
mkdir -p build results/clean results/dut_bug

echo "[1/3] Compiling Accellera IEEE 1800.2-2020 Full-Chip & Cluster UVM + Verilator 5.054 binary..."
"${VERILATOR}" --cc --exe --build --timing \
  --coverage-line --coverage-toggle --coverage-user \
  -j 8 -Wno-fatal \
  --top-module tb_full_chip_top \
  --Mdir "${DIR}/build" \
  +define+UVM_NO_DPI \
  +incdir+"${UVM_SRC}" \
  +incdir+"${RTL}" \
  +incdir+"${SRAM_IP}" \
  +incdir+"${DIR}" \
  "${UVM_SRC}/uvm_pkg.sv" \
  "${RTL}/groq_pkg.sv" \
  "${SRAM_IP}/groq_sram_macro_sp.sv" \
  "${SRAM_IP}/groq_sram_ecc_secded.sv" \
  "${SRAM_IP}/groq_mem_agu.sv" \
  "${SRAM_IP}/groq_mem_slice.sv" \
  "${RTL}/groq_stream_fabric.sv" \
  "${RTL}/groq_icu_slice.sv" \
  "${RTL}/groq_nim_realsync.sv" \
  "${RTL}/groq_sxm_slice.sv" \
  "${RTL}/groq_vxm_slice.sv" \
  "${RTL}/groq_mxm_slice.sv" \
  "${RTL}/groq_lpu_top.sv" \
  "${RTL}/groq_lpu_cluster_top.sv" \
  "${DIR}/groq_full_chip_if.sv" \
  "${DIR}/groq_full_chip_uvm_pkg.sv" \
  "${DIR}/tb_full_chip_top.sv" \
  "${DIR}/dpi_full_chip_ref.cpp" \
  "${DIR}/sim_main.cpp" \
  -CFLAGS "-O1 -std=c++17" \
  -o uvm_full_chip_sim > "${DIR}/compile.log" 2>&1

echo "[2/3] Running Clean Full-Chip & 2-Chip Cluster UVM Suite (3,000+ cycles)..."
cd "${DIR}/results/clean"
"${DIR}/build/uvm_full_chip_sim" +UVM_VERBOSITY=UVM_LOW > uvm_clean.log 2>&1
CLEAN_RC=$?
echo "Clean run exit code: ${CLEAN_RC}"
cp -f full_chip_summary.json "${DIR}/full_chip_summary.json" || true
"${VERILATOR_COV}" --write-info coverage_clean.info coverage.dat
"${VERILATOR_COV}" --annotate annotated_cov coverage.dat > cov_annotate.log 2>&1 || true

echo "[3/3] Running Fault-Injection Qualification (+INJECT_FULL_CHIP_BUG)..."
cd "${DIR}/results/dut_bug"
set +e
"${DIR}/build/uvm_full_chip_sim" +UVM_VERBOSITY=UVM_LOW +INJECT_FULL_CHIP_BUG > uvm_dut_bug.log 2>&1
BUG_RC=$?
set -e
echo "Fault-injection (+INJECT_FULL_CHIP_BUG) exit code: ${BUG_RC} (expected non-zero)"
if [ "${BUG_RC}" -eq 0 ]; then
  echo "ERROR: +INJECT_FULL_CHIP_BUG was not caught by scoreboard!"
  exit 1
fi
"${VERILATOR_COV}" --write-info coverage_dut_bug.info coverage.dat

echo "ALL UVM_FULL_CHIP RUNS COMPLETED SUCCESSFULLY!"
