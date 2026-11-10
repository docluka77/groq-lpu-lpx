# Deterministic 144-Bit VLIW Spatial Compiler (`compiler/`)

Implements Groq's **Software-Scheduled Network & Deterministic VLIW Compiler** ([`groq_deterministic_compiler.py`](groq_deterministic_compiler.py)), static Software Aligned Counter (`SAC`) flight-delay scheduler, hazard detector, and RTL co-simulation harness ([`test_compiler_and_rtl_cosim.py`](test_compiler_and_rtl_cosim.py)).

| File | Description |
| :--- | :--- |
| [`groq_deterministic_compiler.py`](groq_deterministic_compiler.py) | Compiles high-level tensor graphs (`GEMV`, `RMSNorm`, `RoPE`, `SwiGLU`, `AllReduce`) into cycle-exact 144-bit VLIW bundles with static stream routing & `NOP_DELAY` compression |
| [`tb_compiler_rtl_cosim.sv`](tb_compiler_rtl_cosim.sv) | SystemVerilog RTL co-simulation testbench executing compiler-emitted 144-bit VLIW programs on `groq_lpu_top` |
| [`sim_compiler_cosim.cpp`](sim_compiler_cosim.cpp) | Verilator C++ driver for compiler-to-RTL cycle-accurate verification |
| [`test_compiler_and_rtl_cosim.py`](test_compiler_and_rtl_cosim.py) | Automated compiler test suite verifying zero stream collisions and 100% bit-exact RTL vs. Golden Model match |
