# Post-Synthesis Gate-Level Lockstep Co-Simulation & VCD Power Signoff (`gate_sim/`)

Verifies **12 synthesized ASAP7 7nm gate-level netlists (`200,670` standard cells)** in cycle-accurate lockstep against golden SystemVerilog RTL over **5,220 clock cycles (`62,400` module comparisons, `0` mismatches)** and extracts real VCD toggle rates (`67.30%` dynamic power reduction).

| File | Description |
| :--- | :--- |
| [`run_gate_sim.sh`](run_gate_sim.sh) | End-to-end 4-step script: primitive generation, Verilator gate-vs-RTL compilation, 5,220-cycle simulation & VCD power extraction |
| [`gen_asap7_sim_lib.py`](gen_asap7_sim_lib.py) | Auto-generates Verilator-compatible behavioral standard-cell primitives from `asap7_rvt_ff.lib` |
| [`tb_gate_vs_rtl_cosim.sv`](tb_gate_vs_rtl_cosim.sv) | 12-module lockstep RTL vs. ASAP7 gate-level netlist co-simulation testbench |
| [`extract_gate_vcd_power.py`](extract_gate_vcd_power.py) | Parses post-synthesis VCD toggle activity (`alpha_act = 0.1492`, `alpha_idle = 0.00020`) and computes dynamic power savings |
| [`gate_power_summary.json`](gate_power_summary.json) | Complete module-by-module gate-level cell count, toggle rate, and power signoff receipt |
