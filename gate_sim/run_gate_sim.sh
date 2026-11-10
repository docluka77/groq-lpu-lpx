#!/usr/bin/env bash
set -euo pipefail

ROOT="/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106"
GDIR="${ROOT}/gate_sim"
TC="/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain"
export VERILATOR_ROOT="${TC}/verilator-5.054"
VERILATOR="${VERILATOR_ROOT}/bin/verilator"

cd "${ROOT}"
mkdir -p "${GDIR}/build"

echo "[1/4] Generating ASAP7 7nm Standard-Cell Behavioral Primitives & Gate Co-Sim Netlists..."
python3 "${GDIR}/gen_asap7_sim_lib.py"

echo "[2/4] Compiling RTL vs. ASAP7 Gate-Level Netlist Lockstep Co-Simulation in Verilator 5.054..."
"${VERILATOR}" --binary --trace --timing \
  -j 8 -Wno-fatal -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC \
  --top-module tb_gate_vs_rtl_cosim \
  --Mdir "${GDIR}/build" \
  +incdir+"${ROOT}/rtl" \
  +incdir+"${ROOT}/sram_ip" \
  "${ROOT}/rtl/groq_pkg.sv" \
  "${GDIR}/asap7_stdcell_sim_primitives.v" \
  "${ROOT}/sram_ip/groq_sram_ecc_secded.sv" \
  "${ROOT}/sram_ip/groq_mem_agu.sv" \
  "${ROOT}/rtl/groq_icu_slice.sv" \
  "${ROOT}/rtl/groq_c2c_serdes_pcs.sv" \
  "${ROOT}/rtl/groq_pcie_c2c_dma.sv" \
  "${ROOT}/rtl/groq_mxfp8_nvfp4_dot_engine.sv" \
  "${ROOT}/rtl/groq_sxm_slice.sv" \
  "${ROOT}/rtl/groq_nim_realsync.sv" \
  "${ROOT}/rtl/groq_spec_decode_tree_sampler.sv" \
  "${ROOT}/rtl/groq_power_droop_controller.sv" \
  "${ROOT}/sram_ip/groq_sram_controller_scrubber.sv" \
  "${ROOT}/rtl/groq_c2c_kv_quant_rx_engine.sv" \
  "${GDIR}/netlists/groq_sram_ecc_secded_gate.v" \
  "${GDIR}/netlists/groq_mem_agu_gate.v" \
  "${GDIR}/netlists/groq_icu_slice_gate.v" \
  "${GDIR}/netlists/groq_c2c_serdes_pcs_gate.v" \
  "${GDIR}/netlists/groq_pcie_c2c_dma_gate.v" \
  "${GDIR}/netlists/groq_mxfp8_nvfp4_dot_engine_gate.v" \
  "${GDIR}/netlists/groq_sxm_slice_gate.v" \
  "${GDIR}/netlists/groq_nim_realsync_gate.v" \
  "${GDIR}/netlists/groq_spec_decode_tree_sampler_gate.v" \
  "${GDIR}/netlists/groq_power_droop_controller_gate.v" \
  "${GDIR}/netlists/groq_sram_controller_scrubber_gate.v" \
  "${GDIR}/netlists/groq_c2c_kv_quant_rx_engine_gate.v" \
  "${GDIR}/tb_gate_vs_rtl_cosim.sv" \
  -CFLAGS "-O1" \
  -o gate_vs_rtl_cosim_bin > "${GDIR}/compile.log" 2>&1

echo "[3/4] Running 5,220-Cycle RTL vs. Gate-Level Co-Simulation & Dumping VCD..."
"${GDIR}/build/gate_vs_rtl_cosim_bin" | tee "${GDIR}/cosim.log" "${GDIR}/gate_cosim_verilator.log"

echo "[4/4] Extracting Post-Synthesis Gate-Level VCD Toggle Activity & Power Signoff..."
if [ -f "${GDIR}/extract_gate_vcd_power.py" ]; then
  python3 "${GDIR}/extract_gate_vcd_power.py" | tee "${GDIR}/power_extract.log"
fi
