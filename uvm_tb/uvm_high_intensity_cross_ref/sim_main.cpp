#include <memory>
#include "verilated.h"
#include "verilated_cov.h"
#include "Vtb_uvm_high_intensity_cross_ref.h"

extern "C" int dpi_get_status();

int main(int argc, char** argv) {
  const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
  contextp->commandArgs(argc, argv);
  const std::unique_ptr<Vtb_uvm_high_intensity_cross_ref> top{
      new Vtb_uvm_high_intensity_cross_ref{contextp.get(), "TOP"}};
  while (!contextp->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    contextp->time(top->nextTimeSlot());
  }
  top->final();
  VerilatedCov::write("coverage.dat");
  return dpi_get_status();
}
