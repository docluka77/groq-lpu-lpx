// =============================================================================
// File: uvm_tb/uvm_spec_power_scrub/tb_uvm_spec_power_scrub.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-level Accellera IEEE 1800.2-2020 UVM Testbench Module for
//              groq_spec_decode_tree_sampler, groq_power_droop_controller, and
//              groq_sram_controller_scrubber.
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"
`include "spec_power_scrub_if.sv"
`include "uvm_spec_power_scrub_pkg.sv"

module tb_uvm_spec_power_scrub;
  import uvm_pkg::*;
  import groq_pkg::*;
  import uvm_spec_power_scrub_pkg::*;

  bit clk = 1'b0;
  always #5ns clk = ~clk;

  spec_power_scrub_if       bus(clk);
  spec_power_scrub_dut_wrap u_dut(bus);

  initial begin
    int inj_val = 0;
    if ($value$plusargs("INJECT_FAULT=%d", inj_val)) begin
      bus.inject_fault = (inj_val != 0);
    end else if ($test$plusargs("INJECT_FAULT")) begin
      bus.inject_fault = 1'b1;
    end else begin
      bus.inject_fault = 1'b0;
    end
    uvm_config_db#(virtual spec_power_scrub_if)::set(null, "uvm_test_top.env.agent.*", "vif", bus);
    run_test("spec_power_scrub_test");
  end

  initial begin
    #1000us;
    $fatal(1, "UVM_SPEC_POWER_SCRUB_TIMEOUT: bounded simulation expired");
  end
endmodule : tb_uvm_spec_power_scrub
