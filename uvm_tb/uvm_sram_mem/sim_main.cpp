// =============================================================================
// File: sim_main.cpp
// Description: Verilator 5.054 C++ Top-Level Entry Point for UVM SRAM Suite
// =============================================================================
#include "Vsram_mem_top.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

extern "C" int dpi_sram_get_status();

int main(int argc, char** argv) {
    auto context = std::make_unique<VerilatedContext>();
    context->commandArgs(argc, argv);
    auto top = std::make_unique<Vsram_mem_top>(context.get());
    while (!context->gotFinish()) {
        top->eval();
        if (!top->eventsPending()) break;
        context->time(top->nextTimeSlot());
    }
    top->final();
    context->coveragep()->write("coverage.dat");
    return dpi_sram_get_status();
}
