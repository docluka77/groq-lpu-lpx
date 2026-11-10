# Custom On-Chip 6T SRAM & Reliability IP (`sram_ip/`)

This directory contains **5 synthesizable SystemVerilog SRAM & memory subsystem IP modules (`1,852` lines)** implementing Groq's zero-HBM 44-bank superlane SRAM slices, SECDED `Hamming(72,64)` ECC, 2D strided Tensor AGU, MBIST, and background patrol scrubbing.

| File | Lines | Module Description | Literature / Patent Reference |
| :--- | :---: | :--- | :--- |
| [`groq_sram_ecc_secded.sv`](groq_sram_ecc_secded.sv) | 189 | Combinational & pipelined `Hamming(72,64)` SECDED encoder, syndrome generator, single-bit corrector & double-bit detector | `[S01]`, `[S17]` (`US11023315B2`) |
| [`groq_mem_agu.sv`](groq_mem_agu.sv) | 222 | Deterministic 4-mode Tensor Address Generation Unit (`LINEAR_1D`, `STRIDED_2D`, `RING_KV`, `GATHER_LUT`) | `[S01]`, `[S16]` (`US10949198B2`) |
| [`groq_sram_macro_sp.sv`](groq_sram_macro_sp.sv) | 356 | Foundry 72-bit single-port 6T HD SRAM macro with `icg_en` clock gating, `slp_n`/`ds_n` retention, redrow repair & March C- MBIST | `[S01]`, `[S104]` |
| [`groq_mem_slice.sv`](groq_mem_slice.sv) | 351 | 44-Bank superlane Memory Slice (`Hop 1` West / `Hop 7` East) integrating dual Tensor AGUs, SECDED ECC & unaddressed-bank sleep | `[S01]`, `[S17]` (`US11023315B2`) |
| [`groq_sram_controller_scrubber.sv`](groq_sram_controller_scrubber.sv) | 405 | Zero-stall cycle-stealing background SECDED patrol scrubber, write-back engine & eFuse spare-row remapper | `[S17]`, `[S105]` |
