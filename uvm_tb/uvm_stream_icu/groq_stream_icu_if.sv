// =============================================================================
// File: uvm_tb/uvm_stream_icu/groq_stream_icu_if.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: SystemVerilog Interface & Fault-Injectable Wrapper connecting
//              Accellera IEEE 1800.2-2020 UVM environment to groq_stream_fabric
//              and groq_icu_slice. Supports +INJECT_STREAM_FAULT and
//              +INJECT_BARRIER_FAULT for non-vacuous scoreboard qualification.
// =============================================================================
`ifndef GROQ_STREAM_ICU_IF_SV
`define GROQ_STREAM_ICU_IF_SV

`timescale 1ns/1ps
`include "groq_pkg.sv"

interface groq_stream_icu_if (input logic clk);
  import groq_pkg::*;

  logic rst_n = 1'b0;
  logic cycle_valid = 1'b0;
  int unsigned cycle_id = 0;

  // Fault injection controls
  logic inject_stream_fault  = 1'b0;
  logic inject_barrier_fault = 1'b0;

  // ---------------------------------------------------------------------------
  // groq_stream_fabric Signals (8 Slices x 16 East + 16 West x 128-bit)
  // ---------------------------------------------------------------------------
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   east_inject_en_i = '0;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   east_overwrite_allow_i = '0;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   east_consume_en_i = '0;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] east_inject_data_i = '0;

  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   stream_valid_east_o;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] stream_data_east_o;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   collision_fault_east_o;

  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0]                   west_inject_en_i = '0;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0]                   west_overwrite_allow_i = '0;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0]                   west_consume_en_i = '0;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0][STREAM_WIDTH-1:0] west_inject_data_i = '0;

  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0]                   stream_valid_west_o;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0][STREAM_WIDTH-1:0] stream_data_west_o;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0]                   collision_fault_west_o;

  logic        collision_fault_o;
  logic        collision_sticky_o;
  logic [15:0] gated_hop_count_o;

  // ---------------------------------------------------------------------------
  // groq_icu_slice Signals (8 Slices x 144-bit VLIW + Barrier + RealSync)
  // ---------------------------------------------------------------------------
  logic                                       icu_enable_i = 1'b0;
  logic [NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] imem_vliw_bundle_i = '0;
  logic [NUM_SLICES-1:0]                      imem_fetch_en_o;
  logic [NUM_SLICES-1:0][15:0]                pc_slice_o;

  logic [NUM_SLICES-1:0]                      slice_vliw_valid_o;
  logic [NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] slice_vliw_bundle_o;
  logic [NUM_SLICES-1:0][15:0]                slice_nop_timer_o;
  logic [NUM_SLICES-1:0]                      slice_halted_o;

  logic [NUM_SLICES-1:0]                      slice_notify_ready_i = '0;
  logic [NUM_SLICES-1:0]                      barrier_waiting_o;
  logic [NUM_SLICES-1:0]                      barrier_ready_mask_o;
  logic                                       barrier_release_pulse_o;
  logic [15:0]                                barrier_release_cnt_o;

  logic                                       realsync_ext_adj_en_i = 1'b0;
  logic signed [15:0]                         realsync_ext_adj_val_i = 16'sd0;
  logic [63:0]                                realsync_cycle_cnt_o;
  logic signed [15:0]                         realsync_deskew_offset_o;
  logic [63:0]                                realsync_aligned_time_o;
  logic                                       realsync_drift_fault_o;
endinterface : groq_stream_icu_if

module groq_stream_icu_dut_wrap (
  groq_stream_icu_if bus
);
  import groq_pkg::*;

  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] raw_stream_data_east;
  logic                                                          raw_barrier_release_pulse;

  groq_stream_fabric #(
    .P_NUM_SLICES       (NUM_SLICES),
    .P_NUM_EAST_STREAMS (NUM_EAST_STREAMS),
    .P_NUM_WEST_STREAMS (NUM_WEST_STREAMS),
    .P_STREAM_WIDTH     (STREAM_WIDTH)
  ) u_stream_fabric (
    .clk                    (bus.clk),
    .rst_n                  (bus.rst_n),
    .east_inject_en_i       (bus.east_inject_en_i),
    .east_overwrite_allow_i (bus.east_overwrite_allow_i),
    .east_consume_en_i      (bus.east_consume_en_i),
    .east_inject_data_i     (bus.east_inject_data_i),
    .stream_valid_east_o    (bus.stream_valid_east_o),
    .stream_data_east_o     (raw_stream_data_east),
    .collision_fault_east_o (bus.collision_fault_east_o),
    .west_inject_en_i       (bus.west_inject_en_i),
    .west_overwrite_allow_i (bus.west_overwrite_allow_i),
    .west_consume_en_i      (bus.west_consume_en_i),
    .west_inject_data_i     (bus.west_inject_data_i),
    .stream_valid_west_o    (bus.stream_valid_west_o),
    .stream_data_west_o     (bus.stream_data_west_o),
    .collision_fault_west_o (bus.collision_fault_west_o),
    .collision_fault_o      (bus.collision_fault_o),
    .collision_sticky_o     (bus.collision_sticky_o),
    .gated_hop_count_o      (bus.gated_hop_count_o)
  );

  groq_icu_slice #(
    .P_NUM_SLICES    (NUM_SLICES),
    .P_PC_WIDTH      (16),
    .P_MAX_DRIFT_CYC (64)
  ) u_icu_slice (
    .clk                      (bus.clk),
    .rst_n                    (bus.rst_n),
    .icu_enable_i             (bus.icu_enable_i),
    .imem_vliw_bundle_i       (bus.imem_vliw_bundle_i),
    .imem_fetch_en_o          (bus.imem_fetch_en_o),
    .pc_slice_o               (bus.pc_slice_o),
    .slice_vliw_valid_o       (bus.slice_vliw_valid_o),
    .slice_vliw_bundle_o      (bus.slice_vliw_bundle_o),
    .slice_nop_timer_o        (bus.slice_nop_timer_o),
    .slice_halted_o           (bus.slice_halted_o),
    .slice_notify_ready_i     (bus.slice_notify_ready_i),
    .barrier_waiting_o        (bus.barrier_waiting_o),
    .barrier_ready_mask_o     (bus.barrier_ready_mask_o),
    .barrier_release_pulse_o  (raw_barrier_release_pulse),
    .barrier_release_cnt_o    (bus.barrier_release_cnt_o),
    .realsync_ext_adj_en_i    (bus.realsync_ext_adj_en_i),
    .realsync_ext_adj_val_i   (bus.realsync_ext_adj_val_i),
    .realsync_cycle_cnt_o     (bus.realsync_cycle_cnt_o),
    .realsync_deskew_offset_o (bus.realsync_deskew_offset_o),
    .realsync_aligned_time_o  (bus.realsync_aligned_time_o),
    .realsync_drift_fault_o    (bus.realsync_drift_fault_o)
  );

  // Fault-injection hooks for non-vacuous UVM scoreboard qualification
  always_comb begin
    bus.stream_data_east_o = raw_stream_data_east;
    if (bus.inject_stream_fault && bus.stream_valid_east_o[1][0]) begin
      bus.stream_data_east_o[1][0][0] = ~raw_stream_data_east[1][0][0];
    end
    bus.barrier_release_pulse_o = raw_barrier_release_pulse ^
                                  (bus.inject_barrier_fault & (|bus.barrier_waiting_o));
  end

endmodule : groq_stream_icu_dut_wrap

`endif // GROQ_STREAM_ICU_IF_SV
