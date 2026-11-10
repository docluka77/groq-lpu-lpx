#!/usr/bin/env bash
set -euo pipefail

DIR="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_stream_icu"
RTL="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl"
TC="/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain"
export VERILATOR_ROOT="${TC}/verilator-5.054"
VERILATOR="${VERILATOR_ROOT}/bin/verilator"
VERILATOR_COV="${VERILATOR_ROOT}/bin/verilator_coverage"
UVM_SRC="${TC}/uvm-core-2020.3.1/src"

cd "${DIR}"
mkdir -p build results/clean results/fault_stream results/fault_barrier

echo "[1/4] Compiling Accellera IEEE 1800.2-2020 UVM + Verilator 5.054 binary..."
"${VERILATOR}" --cc --exe --build --timing \
  --coverage-line --coverage-toggle --coverage-user \
  -j 8 -Wno-fatal \
  --top-module tb_stream_icu_top \
  --Mdir "${DIR}/build" \
  +define+UVM_NO_DPI \
  +incdir+"${UVM_SRC}" \
  +incdir+"${RTL}" \
  +incdir+"${DIR}" \
  "${UVM_SRC}/uvm_pkg.sv" \
  "${RTL}/groq_pkg.sv" \
  "${RTL}/groq_stream_fabric.sv" \
  "${RTL}/groq_icu_slice.sv" \
  "${DIR}/groq_stream_icu_if.sv" \
  "${DIR}/groq_stream_icu_uvm_pkg.sv" \
  "${DIR}/tb_stream_icu_top.sv" \
  "${DIR}/dpi_stream_icu_ref.cpp" \
  "${DIR}/sim_main.cpp" \
  -CFLAGS "-O1 -std=c++17" \
  -o uvm_stream_icu_sim > "${DIR}/compile.log" 2>&1

echo "[2/4] Running Clean UVM Verification Suite (2,200 cycles)..."
cd "${DIR}/results/clean"
"${DIR}/build/uvm_stream_icu_sim" > uvm_clean.log 2>&1
CLEAN_RC=$?
echo "Clean run exit code: ${CLEAN_RC}"
"${VERILATOR_COV}" --write-info coverage_clean.info coverage.dat
"${VERILATOR_COV}" --annotate annotated_cov coverage.dat > cov_annotate.log 2>&1 || true

echo "[3/4] Running Fault-Injection Qualification (+INJECT_STREAM_FAULT)..."
cd "${DIR}/results/fault_stream"
set +e
"${DIR}/build/uvm_stream_icu_sim" +INJECT_STREAM_FAULT > uvm_fault_stream.log 2>&1
FAULT_STREAM_RC=$?
set -e
echo "Stream fault-injection exit code: ${FAULT_STREAM_RC} (expected non-zero)"
if [ "${FAULT_STREAM_RC}" -eq 0 ]; then
  echo "ERROR: +INJECT_STREAM_FAULT was not caught by scoreboard!"
  exit 1
fi

echo "[4/4] Running Fault-Injection Qualification (+INJECT_BARRIER_FAULT)..."
cd "${DIR}/results/fault_barrier"
set +e
"${DIR}/build/uvm_stream_icu_sim" +INJECT_BARRIER_FAULT > uvm_fault_barrier.log 2>&1
FAULT_BARRIER_RC=$?
set -e
echo "Barrier fault-injection exit code: ${FAULT_BARRIER_RC} (expected non-zero)"
if [ "${FAULT_BARRIER_RC}" -eq 0 ]; then
  echo "ERROR: +INJECT_BARRIER_FAULT was not caught by scoreboard!"
  exit 1
fi

echo "ALL UVM_STREAM_ICU RUNS COMPLETED SUCCESSFULLY!"
