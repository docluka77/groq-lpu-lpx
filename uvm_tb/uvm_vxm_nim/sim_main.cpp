// =============================================================================
// File: uvm_tb/uvm_vxm_nim/sim_main.cpp
// Description: Verilator 5.054 C++ main entry point for Accellera UVM 2020.3.1
//              groq_vxm_slice + groq_nim_realsync verification suite.
// =============================================================================
#include "Vtb_vxm_nim_top.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

extern "C" int dpi_get_status();

int main(int argc, char** argv) {
  auto context = std::make_unique<VerilatedContext>();
  context->commandArgs(argc, argv);
  auto top = std::make_unique<Vtb_vxm_nim_top>(context.get());
  while (!context->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    context->time(top->nextTimeSlot());
  }
  top->final();
  context->coveragep()->write("coverage.dat");
  return dpi_get_status();
}
