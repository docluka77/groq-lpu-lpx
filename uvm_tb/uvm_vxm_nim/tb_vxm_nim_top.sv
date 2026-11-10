// =============================================================================
// File: uvm_tb/uvm_vxm_nim/tb_vxm_nim_top.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-level Accellera IEEE 1800.2-2020 UVM Testbench Module for
//              groq_vxm_slice and groq_nim_realsync.
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"
`include "groq_vxm_nim_if.sv"
`include "groq_vxm_nim_uvm_pkg.sv"

module tb_vxm_nim_top;
  import uvm_pkg::*;
  import groq_pkg::*;
  import groq_vxm_nim_uvm_pkg::*;

  bit clk = 1'b0;
  always #5ns clk = ~clk;

  groq_vxm_nim_if bus(clk);
  groq_vxm_nim_dut_wrap u_dut(bus);

  initial begin
    bus.inject_dut_bug = $test$plusargs("INJECT_DUT_BUG");
    uvm_config_db#(virtual groq_vxm_nim_if)::set(null, "uvm_test_top.env.*", "vif", bus);
    run_test("vxm_nim_test");
  end

  initial begin
    #1000us;
    $fatal(1, "UVM_VXM_NIM_TIMEOUT: bounded simulation expired");
  end
endmodule : tb_vxm_nim_top
