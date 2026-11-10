#!/usr/bin/env python3
import subprocess, sys
ret = subprocess.call(["bash", "/nfs/share/home/chenpei/hyr/groq_lpu_tsp_20261106/gate_sim/run_gate_sim.sh"])
sys.exit(ret)
