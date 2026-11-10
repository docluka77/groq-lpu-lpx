# Dual-PDK Gate-Level Synthesis & Joules/Token PPA Analyzer (`synth/`)

Contains **Yosys 0.60** synthesis scripts, module synthesis logs across **ASAP7 (7nm FinFET)** and **SkyWater Sky130 (130nm)** standard-cell libraries, and the silicon-calibrated area/power/energy analyzer ([`analyze_groq_ppa_efficiency.py`](analyze_groq_ppa_efficiency.py)).

| File | Description |
| :--- | :--- |
| [`run_synth_all.sh`](run_synth_all.sh) | Synthesizes core LPU slice & SRAM IP modules in ASAP7 7nm and Sky130 130nm |
| [`synth_stage19_20.sh`](synth_stage19_20.sh) | Synthesizes Groq 3 LPX power droop controller & background SRAM scrubber |
| [`analyze_groq_ppa_efficiency.py`](analyze_groq_ppa_efficiency.py) | Parses all 17 module synthesis logs and computes Groq LPU v1 (14nm, `725.02 mm²`) & NVIDIA Groq 3 LPX (4nm, `614.03 mm²`) PPA + `Llama-3 8B/70B` Joules/token efficiency |
| [`ppa_summary.json`](ppa_summary.json) | Machine-readable synthesis cell counts, area breakdown, 4 low-power hardware mechanisms & Joules/token results |
