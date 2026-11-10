// =============================================================================
// File: uvm_tb/uvm_stream_icu/tb_stream_icu_top.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-level Accellera IEEE 1800.2-2020 UVM Testbench Module for
//              groq_stream_fabric and groq_icu_slice.
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"
`include "groq_stream_icu_if.sv"
`include "groq_stream_icu_uvm_pkg.sv"

module tb_stream_icu_top;
  import uvm_pkg::*;
  import groq_pkg::*;
  import groq_stream_icu_uvm_pkg::*;

  bit clk = 1'b0;
  always #5ns clk = ~clk;

  groq_stream_icu_if bus(clk);
  groq_stream_icu_dut_wrap u_dut(bus);

  initial begin
    bus.inject_stream_fault  = $test$plusargs("INJECT_STREAM_FAULT");
    bus.inject_barrier_fault = $test$plusargs("INJECT_BARRIER_FAULT");
    uvm_config_db#(virtual groq_stream_icu_if)::set(null, "uvm_test_top.env.*", "vif", bus);
    run_test("stream_icu_test");
  end

  initial begin
    #1000us;
    $fatal(1, "UVM_STREAM_ICU_TIMEOUT: bounded simulation expired");
  end
endmodule : tb_stream_icu_top
