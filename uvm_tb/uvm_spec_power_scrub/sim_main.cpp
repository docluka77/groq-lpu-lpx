// =============================================================================
// File: uvm_tb/uvm_spec_power_scrub/sim_main.cpp
// Description: Verilator 5.054 C++ main entry point for Accellera UVM 2020.3.1
//              groq_spec_decode_tree_sampler + groq_power_droop_controller +
//              groq_sram_controller_scrubber verification suite.
// =============================================================================
#include "Vtb_uvm_spec_power_scrub.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

extern "C" int dpi_get_status();

int main(int argc, char** argv) {
  auto context = std::make_unique<VerilatedContext>();
  context->commandArgs(argc, argv);
  auto top = std::make_unique<Vtb_uvm_spec_power_scrub>(context.get());
  while (!context->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    context->time(top->nextTimeSlot());
  }
  top->final();
  context->coveragep()->write("coverage.dat");
  return dpi_get_status();
}
