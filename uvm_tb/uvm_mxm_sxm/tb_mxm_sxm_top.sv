// =============================================================================
// File: uvm_tb/uvm_mxm_sxm/tb_mxm_sxm_top.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-level Accellera IEEE 1800.2-2020 UVM Testbench Module for
//              groq_mxm_slice and groq_sxm_slice.
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"
`include "groq_mxm_sxm_if.sv"
`include "groq_mxm_sxm_uvm_pkg.sv"

module tb_mxm_sxm_top;
  import uvm_pkg::*;
  import groq_pkg::*;
  import groq_mxm_sxm_uvm_pkg::*;

  bit clk = 1'b0;
  always #5ns clk = ~clk;

  groq_mxm_sxm_if bus(clk);
  groq_mxm_sxm_dut_wrap u_dut(bus);

  initial begin
    bus.inject_dut_bug = $test$plusargs("INJECT_DUT_BUG");
    uvm_config_db#(virtual groq_mxm_sxm_if)::set(null, "uvm_test_top.env.*", "vif", bus);
    run_test("mxm_sxm_test");
  end

  initial begin
    #1000us;
    $fatal(1, "UVM_MXM_SXM_TIMEOUT: bounded simulation expired");
  end
endmodule : tb_mxm_sxm_top
