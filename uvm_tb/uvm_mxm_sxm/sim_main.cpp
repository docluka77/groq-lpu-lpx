// =============================================================================
// File: uvm_tb/uvm_mxm_sxm/sim_main.cpp
// Description: Verilator 5.054 C++ main entry point for Accellera UVM 2020.3.1
//              groq_mxm_slice + groq_sxm_slice verification suite.
// =============================================================================
#include "Vtb_mxm_sxm_top.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

extern "C" int dpi_get_status();

int main(int argc, char** argv) {
  auto context = std::make_unique<VerilatedContext>();
  context->commandArgs(argc, argv);
  auto top = std::make_unique<Vtb_mxm_sxm_top>(context.get());
  while (!context->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    context->time(top->nextTimeSlot());
  }
  top->final();
  context->coveragep()->write("coverage.dat");
  return dpi_get_status();
}
