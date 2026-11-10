// =============================================================================
// File: uvm_tb/uvm_full_chip/tb_full_chip_top.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-Level Accellera IEEE 1800.2-2020 UVM Testbench Module for
//              groq_lpu_cluster_top (2 x groq_lpu_top + Dragonfly C2C).
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"
`include "groq_full_chip_if.sv"
`include "groq_full_chip_uvm_pkg.sv"

module tb_full_chip_top;
  import uvm_pkg::*;
  import groq_pkg::*;
  import groq_full_chip_uvm_pkg::*;

  bit clk = 1'b0;
  always #5ns clk = ~clk;

  groq_full_chip_if       bus(clk);
  groq_full_chip_dut_wrap u_dut(bus);

  initial begin
    bus.inject_full_chip_bug = $test$plusargs("INJECT_FULL_CHIP_BUG") ||
                               $test$plusargs("INJECT_DUT_BUG");
    uvm_config_db#(virtual groq_full_chip_if)::set(null, "uvm_test_top.env.*", "vif", bus);
    run_test("full_chip_test");
  end

  initial begin
    #2000us;
    $fatal(1, "UVM_FULL_CHIP_TIMEOUT: bounded simulation expired");
  end
endmodule : tb_full_chip_top
