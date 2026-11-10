// =============================================================================
// File: uvm_tb/uvm_lpx_mxfp8_dma/tb_uvm_lpx_mxfp8_dma.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Top-level Accellera IEEE 1800.2-2020 UVM Testbench Module for
//              groq_mxfp8_nvfp4_dot_engine, groq_c2c_serdes_pcs, and
//              groq_pcie_c2c_dma.
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"
`include "lpx_mxfp8_dma_if.sv"
`include "uvm_lpx_mxfp8_dma_pkg.sv"

module tb_uvm_lpx_mxfp8_dma;
  import uvm_pkg::*;
  import groq_pkg::*;
  import uvm_lpx_mxfp8_dma_pkg::*;

  bit clk = 1'b0;
  always #5ns clk = ~clk;

  lpx_mxfp8_dma_if       bus(clk);
  lpx_mxfp8_dma_dut_wrap u_dut(bus);

  initial begin
    int inj_val = 0;
    if ($value$plusargs("INJECT_FAULT=%d", inj_val)) begin
      bus.inject_fault = (inj_val != 0);
    end else if ($test$plusargs("INJECT_FAULT")) begin
      bus.inject_fault = 1'b1;
    end else begin
      bus.inject_fault = 1'b0;
    end
    uvm_config_db#(virtual lpx_mxfp8_dma_if)::set(null, "uvm_test_top.env.agent.*", "vif", bus);
    run_test("lpx_mxfp8_dma_test");
  end

  initial begin
    #1000us;
    $fatal(1, "UVM_LPX_MXFP8_DMA_TIMEOUT: bounded simulation expired");
  end
endmodule : tb_uvm_lpx_mxfp8_dma
