#!/usr/bin/env bash
set -euo pipefail
cd /nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106

YOSYS=/usr/local/bin/yosys
LIB_ASAP7=/nfs/share/home/chenpei/hyr/latentcore_mla_dsa_20261103/synth/asap7_rvt_ff.lib
LIB_SKY130=/nfs/share/home/chenpei/hyr/dac2027_llm_dsa_marathon/synth/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

synth_mod() {
    local mod=$1
    local files=$2
    local extra_pre=$3

    echo "=== Synthesizing ${mod} (ASAP7 7nm) ==="
    $YOSYS -p "
        read_verilog -sv -Irtl -Isram_ip ${files};
        ${extra_pre}
        chformal -remove;
        synth -top ${mod} -noabc;
        dfflibmap -liberty ${LIB_ASAP7};
        abc -fast -liberty ${LIB_ASAP7};
        stat -liberty ${LIB_ASAP7};
        write_verilog -noattr synth/${mod}_asap7_netlist.v
    " > synth/synth_${mod}_asap7.log 2>&1

    echo "=== Synthesizing ${mod} (Sky130 130nm) ==="
    $YOSYS -p "
        read_verilog -sv -Irtl -Isram_ip ${files};
        ${extra_pre}
        chformal -remove;
        synth -top ${mod} -noabc;
        dfflibmap -liberty ${LIB_SKY130};
        abc -fast -liberty ${LIB_SKY130};
        stat -liberty ${LIB_SKY130};
        write_verilog -noattr synth/${mod}_sky130_netlist.v
    " > synth/synth_${mod}_sky130.log 2>&1
}

synth_mod groq_sram_ecc_secded "sram_ip/groq_sram_ecc_secded.sv" ""
synth_mod groq_mem_agu         "sram_ip/groq_mem_agu.sv" ""
synth_mod groq_sram_macro_sp   "sram_ip/groq_sram_macro_sp.sv" "chparam -set ADDR_W 4 -set DEPTH 16 groq_sram_macro_sp;"
synth_mod groq_mem_slice       "sram_ip/groq_sram_ecc_secded.sv sram_ip/groq_mem_agu.sv sram_ip/groq_sram_macro_sp.sv sram_ip/groq_mem_slice.sv" "chparam -set BANK_ADDR_W 4 -set BANK_DEPTH 16 groq_mem_slice;"
synth_mod groq_stream_fabric   "rtl/groq_pkg.sv rtl/groq_stream_fabric.sv" ""
synth_mod groq_icu_slice       "rtl/groq_icu_slice.sv" ""
synth_mod groq_mxm_slice       "rtl/groq_mxm_slice.sv" ""
synth_mod groq_sxm_slice       "rtl/groq_sxm_slice.sv" ""
synth_mod groq_vxm_slice       "rtl/groq_vxm_slice.sv" ""
synth_mod groq_nim_realsync    "rtl/groq_nim_realsync.sv" ""

echo "ALL_SYNTH_DONE"
