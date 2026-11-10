// =============================================================================
// File: compiler/sim_compiler_cosim.cpp
// Description: Verilator 5.054 C++17 main wrapper for Stage 15 RTL Co-Sim.
// =============================================================================
#include <memory>
#include "verilated.h"
#include "Vtb_compiler_rtl_cosim.h"

int main(int argc, char** argv) {
  const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
  contextp->commandArgs(argc, argv);
  const std::unique_ptr<Vtb_compiler_rtl_cosim> top{new Vtb_compiler_rtl_cosim{contextp.get()}};

  while (!contextp->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    contextp->time(top->nextTimeSlot());
  }
  top->final();
  return 0;
}
