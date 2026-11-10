// =============================================================================
// File: uvm_tb/uvm_c2c_kv_quant/tb_uvm_c2c_kv_quant.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-level Accellera IEEE 1800.2-2020 UVM Testbench Module for
//              groq_c2c_kv_quant_rx_engine & Closed-Loop groq_mxfp8_nvfp4_dot_engine
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"
`include "c2c_kv_quant_if.sv"
`include "uvm_c2c_kv_quant_pkg.sv"

module tb_uvm_c2c_kv_quant;
  import uvm_pkg::*;
  import groq_pkg::*;
  import uvm_c2c_kv_quant_pkg::*;

  bit clk = 1'b0;
  always #5ns clk = ~clk;

  c2c_kv_quant_if       bus(clk);
  c2c_kv_quant_dut_wrap u_dut(bus);

  initial begin
    int inj_val = 0;
    if ($value$plusargs("INJECT_FAULT=%d", inj_val)) begin
      bus.inject_fault = (inj_val != 0);
    end else if ($test$plusargs("INJECT_FAULT")) begin
      bus.inject_fault = 1'b1;
    end else begin
      bus.inject_fault = 1'b0;
    end
    uvm_config_db#(virtual c2c_kv_quant_if)::set(null, "uvm_test_top.env.agent.*", "vif", bus);
    run_test("c2c_kv_quant_test");
  end

  initial begin
    #1000us;
    $fatal(1, "UVM_C2C_KV_QUANT_TIMEOUT: bounded simulation expired");
  end
endmodule : tb_uvm_c2c_kv_quant
