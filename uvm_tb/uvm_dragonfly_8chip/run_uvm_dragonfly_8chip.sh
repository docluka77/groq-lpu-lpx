#!/usr/bin/env bash
set -euo pipefail

DIR="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/uvm_tb/uvm_dragonfly_8chip"
RTL="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/rtl"
SRAM_IP="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/sram_ip"
TC="/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain"
export VERILATOR_ROOT="${TC}/verilator-5.054"
VERILATOR="${VERILATOR_ROOT}/bin/verilator"
VERILATOR_COV="${VERILATOR_ROOT}/bin/verilator_coverage"
UVM_SRC="${TC}/uvm-core-2020.3.1/src"

cd "${DIR}"
mkdir -p build results/clean results/dut_bug

echo "[1/3] Compiling Accellera IEEE 1800.2-2020 8-Chip Dragonfly UVM + Verilator 5.054 binary..."
"${VERILATOR}" --cc --exe --build --timing \
  --coverage-line --coverage-toggle --coverage-user \
  -j 8 -Wno-fatal \
  --top-module tb_uvm_dragonfly_8chip \
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
  "${RTL}/groq_c2c_serdes_pcs.sv" \
  "${RTL}/groq_pcie_c2c_dma.sv" \
  "${RTL}/groq_dragonfly_8chip_cluster.sv" \
  "${DIR}/dragonfly_8chip_if.sv" \
  "${DIR}/uvm_dragonfly_8chip_pkg.sv" \
  "${DIR}/tb_uvm_dragonfly_8chip.sv" \
  "${DIR}/dpi_dragonfly_8chip_ref.cpp" \
  "${DIR}/sim_main.cpp" \
  -CFLAGS "-O1 -std=c++17" \
  -o uvm_dragonfly_8chip_sim > "${DIR}/compile.log" 2>&1

echo "[2/3] Running Clean 8-Chip Dragonfly UVM Suite (3,000+ cycles)..."
cd "${DIR}/results/clean"
"${DIR}/build/uvm_dragonfly_8chip_sim" +UVM_VERBOSITY=UVM_LOW > uvm_clean.log 2>&1
CLEAN_RC=$?
echo "Clean run exit code: ${CLEAN_RC}"
cp -f uvm_clean.log "${DIR}/uvm_dragonfly_8chip.log"
cp -f coverage.dat "${DIR}/coverage.dat"
cp -f dragonfly_8chip_summary.json "${DIR}/dragonfly_8chip_summary.json"
"${VERILATOR_COV}" --write-info coverage_clean.info coverage.dat
cp -f coverage_clean.info "${DIR}/coverage.info"
"${VERILATOR_COV}" --annotate annotated_cov coverage.dat > cov_annotate.log 2>&1 || true

python3 - "${DIR}/coverage.info" "${DIR}/lcov_summary.txt" << 'PYEOF'
import sys
info_path, out_path = sys.argv[1], sys.argv[2]
records = {}
cur = None
for line in open(info_path):
    line = line.strip()
    if line.startswith("SF:"):
        cur = line[3:]
        if cur not in records:
            records[cur] = {"da_f": 0, "da_h": 0, "br_f": 0, "br_h": 0}
    elif cur and line.startswith("DA:"):
        cnt = int(line.split(",")[1])
        records[cur]["da_f"] += 1
        if cnt > 0:
            records[cur]["da_h"] += 1
    elif cur and line.startswith("BRDA:"):
        cnt_s = line.split(",")[-1]
        cnt = 0 if cnt_s == "-" else int(cnt_s)
        records[cur]["br_f"] += 1
        if cnt > 0:
            records[cur]["br_h"] += 1
lines_out = ["=== Stage 14B 8-Chip Dragonfly Cluster RTL LCOV Coverage Summary ==="]
t_df = t_dh = t_bf = t_bh = 0
for sf, d in sorted(records.items()):
    if "/rtl/groq_" in sf or "/sram_ip/groq_" in sf:
        lp = 100.0 * d["da_h"] / d["da_f"] if d["da_f"] else 100.0
        bp = 100.0 * d["br_h"] / d["br_f"] if d["br_f"] else 100.0
        t_df += d["da_f"]; t_dh += d["da_h"]; t_bf += d["br_f"]; t_bh += d["br_h"]
        lines_out.append(f"{sf.split('/')[-1]:34s} | Line: {d['da_h']:4d}/{d['da_f']:4d} ({lp:6.2f}%) | Toggle/Branch: {d['br_h']:4d}/{d['br_f']:4d} ({bp:6.2f}%)")
tlp = 100.0 * t_dh / t_df if t_df else 100.0
tbp = 100.0 * t_bh / t_bf if t_bf else 100.0
lines_out.append(f"{'TOTAL (8-Chip Dragonfly Cluster)':34s} | Line: {t_dh:4d}/{t_df:4d} ({tlp:6.2f}%) | Toggle/Branch: {t_bh:4d}/{t_bf:4d} ({tbp:6.2f}%)")
txt = "\n".join(lines_out) + "\n"
open(out_path, "w").write(txt)
print(txt)
PYEOF

echo "[3/3] Running Fault-Injection Qualification (+INJECT_FAULT=1)..."
cd "${DIR}/results/dut_bug"
set +e
"${DIR}/build/uvm_dragonfly_8chip_sim" +UVM_VERBOSITY=UVM_LOW +INJECT_FAULT=1 > uvm_dut_bug.log 2>&1
BUG_RC=$?
set -e
cp -f uvm_dut_bug.log "${DIR}/fault_injection_qual.log"
echo "Fault-injection (+INJECT_FAULT=1) exit code: ${BUG_RC} (expected non-zero)"
if [ "${BUG_RC}" -eq 0 ]; then
  echo "ERROR: +INJECT_FAULT=1 was not caught by scoreboard!"
  exit 1
fi
"${VERILATOR_COV}" --write-info coverage_dut_bug.info coverage.dat
echo "ALL UVM_DRAGONFLY_8CHIP RUNS COMPLETED SUCCESSFULLY!"
