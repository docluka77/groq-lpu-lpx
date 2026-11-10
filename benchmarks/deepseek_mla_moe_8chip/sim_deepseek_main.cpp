#include "Vtb_deepseek_mla_moe_8chip.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <iostream>

int main(int argc, char** argv) {
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    contextp->traceEverOn(true);

    Vtb_deepseek_mla_moe_8chip* top = new Vtb_deepseek_mla_moe_8chip{contextp};
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 2);
    tfp->open("deepseek_mla_moe_8chip.vcd");

    top->clk = 0;
    top->rst_n = 0;

    uint64_t sim_time = 0;
    while (!contextp->gotFinish() && sim_time < 250000) {
        if (sim_time == 20) {
            top->rst_n = 1;
        }
        top->clk = !top->clk;
        top->eval();
        if (sim_time >= 46000) {
            tfp->dump(sim_time);
        }
        sim_time += 5;
    }

    tfp->close();
    delete tfp;
    delete top;
    delete contextp;
    return 0;
}
