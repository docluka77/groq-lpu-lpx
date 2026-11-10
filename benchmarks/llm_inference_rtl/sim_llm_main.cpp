#include "Vtb_llm_inference_cluster.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <iostream>

int main(int argc, char** argv) {
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    contextp->traceEverOn(true);

    Vtb_llm_inference_cluster* top = new Vtb_llm_inference_cluster{contextp};
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("llm_decode_cluster.vcd");

    top->clk = 0;
    top->rst_n = 0;

    uint64_t sim_time = 0;
    while (!contextp->gotFinish() && sim_time < 50000) {
        if (sim_time == 20) {
            top->rst_n = 1;
        }
        top->clk = !top->clk;
        top->eval();
        tfp->dump(sim_time);
        sim_time += 5;
    }

    tfp->close();
    delete tfp;
    delete top;
    delete contextp;
    return 0;
}
