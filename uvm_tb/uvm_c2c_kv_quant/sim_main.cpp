// =============================================================================
// File: uvm_tb/uvm_c2c_kv_quant/sim_main.cpp
// Description: Verilator 5.054 C++ main entry point for Accellera UVM 2020.3.1
//              groq_c2c_kv_quant_rx_engine + groq_mxfp8_nvfp4_dot_engine suite
// =============================================================================
#include "Vtb_uvm_c2c_kv_quant.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

static int g_sim_status = 0;
extern "C" void dpi_set_status(int status) { g_sim_status = status; }
extern "C" int dpi_get_status() { return g_sim_status; }

int main(int argc, char** argv) {
  auto context = std::make_unique<VerilatedContext>();
  context->commandArgs(argc, argv);
  auto top = std::make_unique<Vtb_uvm_c2c_kv_quant>(context.get());
  while (!context->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    context->time(top->nextTimeSlot());
  }
  top->final();
  context->coveragep()->write("coverage.dat");
  return dpi_get_status();
}
