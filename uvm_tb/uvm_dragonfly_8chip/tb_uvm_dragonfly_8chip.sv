// =============================================================================
// File: uvm_tb/uvm_dragonfly_8chip/tb_uvm_dragonfly_8chip.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-level Accellera IEEE 1800.2-2020 UVM Testbench Module for
//              groq_dragonfly_8chip_cluster (8-Chip Dragonfly Scale-Out Cluster).
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"
`include "dragonfly_8chip_if.sv"
`include "uvm_dragonfly_8chip_pkg.sv"

module tb_uvm_dragonfly_8chip;
  import uvm_pkg::*;
  import groq_pkg::*;
  import uvm_dragonfly_8chip_pkg::*;

  bit clk = 1'b0;
  always #5ns clk = ~clk;

  dragonfly_8chip_if       bus(clk);
  dragonfly_8chip_dut_wrap u_dut(bus);

  initial begin
    int inj_val = 0;
    if ($value$plusargs("INJECT_FAULT=%d", inj_val)) begin
      bus.inject_fault = (inj_val != 0);
    end else if ($test$plusargs("INJECT_FAULT")) begin
      bus.inject_fault = 1'b1;
    end else begin
      bus.inject_fault = 1'b0;
    end
    uvm_config_db#(virtual dragonfly_8chip_if)::set(null, "uvm_test_top.env.agent.*", "vif", bus);
    run_test("dragonfly_8chip_test");
  end

  initial begin
    #1000us;
    $fatal(1, "UVM_DRAGONFLY_8CHIP_TIMEOUT: bounded simulation expired");
  end
endmodule : tb_uvm_dragonfly_8chip
