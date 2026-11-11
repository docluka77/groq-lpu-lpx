# Yosys 0.60 Formal Verification, Gate Equivalence & 50-Mutant Qualification (`formal/`)

This directory contains **21 Yosys 0.60 formal SAT/induction & gate-level equivalence scripts (`prove_*.ys`)**, **8 adversarial & endurance SystemVerilog testbenches (`tb_*.sv`)**, and the **50-Mutant Hardware Formal Mutation Testing Campaign (`mutation_testing/`)**.

### Key Verification Campaigns
1. **Unbounded SAT & Temporal Induction Proofs (`prove_*.ys`)**:
   - Proves 175+ safety, liveness, numerical rounding (`PREC_INT8_RNE`, `NVFP4_E4M3_SCALE`), `Hamming(72,64)` SECDED, `RealSync` `±4`-cycle deskew, and Dragonfly deadlock-freedom invariants (`0` counterexamples).
2. **Post-Synthesis Gate-Level Equivalence Proofs (`prove_*_gate_equiv.ys`)**:
   - Proves 100% cycle-accurate functional equivalence between SystemVerilog RTL and synthesized **ASAP7 7nm** standard-cell netlists (`SUCCESS! Q.E.D.`).
3. **50-Mutant Formal Mutation Campaign ([`mutation_testing/run_formal_mutation_campaign.py`](mutation_testing/run_formal_mutation_campaign.py))**:
   - Injects **50 hardware bugs (`MUT-001`–`MUT-050`)** across all 17 leaf & subsystem modules: **`50 / 50 KILLED (100.0% kill rate, 0 survived, 0 vacuous assertions)`**.
