// =============================================================================
// File: uvm_tb/uvm_full_chip/sim_main.cpp
// Description: Verilator 5.054 C++ main entry point for Accellera UVM 2020.3.1
//              Full-Chip & 2-Chip Cluster (groq_lpu_cluster_top) verification.
// =============================================================================
#include "Vtb_full_chip_top.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

extern "C" int dpi_get_status();

int main(int argc, char** argv) {
  auto context = std::make_unique<VerilatedContext>();
  context->commandArgs(argc, argv);
  auto top = std::make_unique<Vtb_full_chip_top>(context.get());
  while (!context->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    context->time(top->nextTimeSlot());
  }
  top->final();
  context->coveragep()->write("coverage.dat");
  return dpi_get_status();
}
