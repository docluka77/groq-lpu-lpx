// =============================================================================
// File: uvm_tb/uvm_lpx_mxfp8_dma/sim_main.cpp
// Description: Verilator 5.054 C++ main entry point for Accellera UVM 2020.3.1
//              groq_mxfp8_nvfp4_dot_engine + groq_c2c_serdes_pcs +
//              groq_pcie_c2c_dma verification suite.
// =============================================================================
#include "Vtb_uvm_lpx_mxfp8_dma.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

extern "C" int dpi_get_status();

int main(int argc, char** argv) {
  auto context = std::make_unique<VerilatedContext>();
  context->commandArgs(argc, argv);
  auto top = std::make_unique<Vtb_uvm_lpx_mxfp8_dma>(context.get());
  while (!context->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    context->time(top->nextTimeSlot());
  }
  top->final();
  context->coveragep()->write("coverage.dat");
  return dpi_get_status();
}
