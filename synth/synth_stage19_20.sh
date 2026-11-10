#!/usr/bin/env bash
set -euo pipefail
cd /nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106

YOSYS=/usr/local/bin/yosys
LIB_ASAP7=/nfs/share/home/chenpei/hyr/latentcore_mla_dsa_20261103/synth/asap7_rvt_ff.lib
LIB_SKY130=/nfs/share/home/chenpei/hyr/dac2027_llm_dsa_marathon/synth/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

echo "=== Synthesizing groq_power_droop_controller (ASAP7 7nm) ==="
$YOSYS -p "
    read_verilog -sv -Irtl rtl/groq_power_droop_controller.sv;
    chformal -remove;
    synth -top groq_power_droop_controller -noabc;
    dfflibmap -liberty ${LIB_ASAP7};
    abc -fast -liberty ${LIB_ASAP7};
    stat -liberty ${LIB_ASAP7};
    write_verilog -noattr synth/groq_power_droop_controller_asap7_netlist.v
" > synth/synth_groq_power_droop_controller_asap7.log 2>&1

echo "=== Synthesizing groq_power_droop_controller (Sky130 130nm) ==="
$YOSYS -p "
    read_verilog -sv -Irtl rtl/groq_power_droop_controller.sv;
    chformal -remove;
    synth -top groq_power_droop_controller -noabc;
    dfflibmap -liberty ${LIB_SKY130};
    abc -fast -liberty ${LIB_SKY130};
    stat -liberty ${LIB_SKY130};
    write_verilog -noattr synth/groq_power_droop_controller_sky130_netlist.v
" > synth/synth_groq_power_droop_controller_sky130.log 2>&1

echo "=== Synthesizing groq_sram_controller_scrubber (ASAP7 7nm) ==="
$YOSYS -p "
    read_verilog -sv -Irtl -Isram_ip sram_ip/groq_sram_ecc_secded.sv sram_ip/groq_sram_controller_scrubber.sv;
    chparam -set P_ADDR_W 2 groq_sram_controller_scrubber;
    chformal -remove;
    synth -top groq_sram_controller_scrubber -noabc;
    dfflibmap -liberty ${LIB_ASAP7};
    abc -fast -liberty ${LIB_ASAP7};
    stat -liberty ${LIB_ASAP7};
    write_verilog -noattr synth/groq_sram_controller_scrubber_asap7_netlist.v
" > synth/synth_groq_sram_controller_scrubber_asap7.log 2>&1

echo "=== Synthesizing groq_sram_controller_scrubber (Sky130 130nm) ==="
$YOSYS -p "
    read_verilog -sv -Irtl -Isram_ip sram_ip/groq_sram_ecc_secded.sv sram_ip/groq_sram_controller_scrubber.sv;
    chparam -set P_ADDR_W 2 groq_sram_controller_scrubber;
    chformal -remove;
    synth -top groq_sram_controller_scrubber -noabc;
    dfflibmap -liberty ${LIB_SKY130};
    abc -fast -liberty ${LIB_SKY130};
    stat -liberty ${LIB_SKY130};
    write_verilog -noattr synth/groq_sram_controller_scrubber_sky130_netlist.v
" > synth/synth_groq_sram_controller_scrubber_sky130.log 2>&1

echo "STAGE_19_20_SYNTH_DONE"

