// =============================================================================
// File: uvm_tb/uvm_vxm_nim/groq_vxm_nim_uvm_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Accellera IEEE 1800.2-2020 UVM Verification Package for
//              groq_vxm_slice (Vector Execution Module) and groq_nim_realsync
//              (Network Interface & RealSync Plesiochronous Router).
// =============================================================================
`ifndef GROQ_VXM_NIM_UVM_PKG_SV
`define GROQ_VXM_NIM_UVM_PKG_SV

`include "uvm_macros.svh"
`include "groq_pkg.sv"

package groq_vxm_nim_uvm_pkg;
  import uvm_pkg::*;
  import groq_pkg::*;

  // ---------------------------------------------------------------------------
  // 1. C++17 DPI-C Reference Model Imports
  // ---------------------------------------------------------------------------
  import "DPI-C" function void dpi_vxm_nim_reset();
  import "DPI-C" function int unsigned dpi_get_calls();
  import "DPI-C" function void dpi_set_status(input int status);
  import "DPI-C" function void dpi_vxm_nim_step(
    input  int unsigned   vxm_op_valid_i,
    input  int unsigned   vxm_op_i,
    input  int unsigned   prec_mode_i,
    input  int unsigned   quant_shift_i,
    input  int unsigned   use_accum_32b_i,
    input  bit [127:0]    stream_a_i,
    input  bit [127:0]    stream_b_i,
    input  bit [127:0]    stream_c_i,
    input  bit [511:0]    accum_32b_in_i,
    input  int unsigned   nim_op_valid_i,
    input  int unsigned   nim_op_i,
    input  int unsigned   realsync_aligned_time_i,
    input  int unsigned   expected_flight_cycles_i,
    input  int unsigned   local_chip_id_i,
    input  int unsigned   tx_dst_chip_i,
    input  int unsigned   ugal_nonminimal_en_i,
    input  int unsigned   link_congested_i,
    input  int unsigned   local_stream_in_valid_i,
    input  bit [127:0]    local_stream_in_data_i,
    input  int unsigned   c2c_rx_valid_i,
    input  bit [127:0]    c2c_rx_data_i,
    input  int unsigned   c2c_rx_tx_timestamp_i,
    input  int unsigned   c2c_rx_dst_chip_i,
    input  int unsigned   c2c_rx_crc8_i,
    output int unsigned   exp_vxm_out_valid,
    output bit [127:0]    exp_vxm_out_data,
    output bit [511:0]    exp_vxm_accum_out,
    output bit [127:0]    exp_vxm_comb_data,
    output int            exp_vxm_reduce_sum,
    output int            exp_vxm_reduce_max,
    output int unsigned   exp_vxm_mul_gate,
    output int unsigned   exp_vxm_lut_gate,
    output int unsigned   exp_nim_local_out_valid,
    output bit [127:0]    exp_nim_local_out_data,
    output int unsigned   exp_c2c_tx_valid,
    output bit [127:0]    exp_c2c_tx_data,
    output int unsigned   exp_c2c_tx_ts,
    output int unsigned   exp_c2c_tx_dst,
    output int unsigned   exp_c2c_tx_crc8,
    output int unsigned   exp_c2c_tx_port,
    output int unsigned   exp_deskew_rel_valid,
    output int unsigned   exp_deskew_rel_target,
    output int unsigned   exp_ping_ack,
    output int            exp_measured_skew,
    output int unsigned   exp_crc_err
  );

  // ---------------------------------------------------------------------------
  // 2. UVM Sequence Item & Sequencer
  // ---------------------------------------------------------------------------
  class vxm_nim_seq_item extends uvm_sequence_item;
    `uvm_object_utils(vxm_nim_seq_item)

    int unsigned tx_id;
    int unsigned phase_id;

    // VXM stimulus
    bit          vxm_op_valid;
    bit [3:0]    vxm_op;
    bit [3:0]    prec_mode;
    bit [2:0]    quant_shift;
    bit          use_accum_32b;
    bit [127:0]  stream_a;
    bit [127:0]  stream_b;
    bit [127:0]  stream_c;
    bit [511:0]  accum_32b_in;

    // NIM stimulus
    bit          nim_op_valid;
    bit [3:0]    nim_op;
    bit [15:0]   realsync_aligned_time;
    bit [15:0]   expected_flight_cycles;
    bit [3:0]    local_chip_id;
    bit [3:0]    tx_dst_chip;
    bit          ugal_nonminimal_en;
    bit          link_congested;
    bit          local_stream_in_valid;
    bit [127:0]  local_stream_in_data;
    bit          c2c_rx_valid;
    bit [127:0]  c2c_rx_data;
    bit [15:0]   c2c_rx_tx_timestamp;
    bit [3:0]    c2c_rx_dst_chip;
    bit [7:0]    c2c_rx_crc8;

    // Observed VXM outputs
    logic        act_vxm_out_valid;
    logic [127:0] act_vxm_out_data;
    logic [511:0] act_vxm_accum_out;
    logic [127:0] act_vxm_comb_data;
    logic signed [15:0] act_vxm_reduce_sum;
    logic signed [7:0]  act_vxm_reduce_max;
    logic        act_vxm_mul_gate;
    logic        act_vxm_lut_gate;

    // Observed NIM outputs
    logic        act_nim_local_out_valid;
    logic [127:0] act_nim_local_out_data;
    logic        act_c2c_tx_valid;
    logic [127:0] act_c2c_tx_data;
    logic [15:0] act_c2c_tx_ts;
    logic [3:0]  act_c2c_tx_dst;
    logic [7:0]  act_c2c_tx_crc8;
    logic [1:0]  act_c2c_tx_port;
    logic        act_deskew_rel_valid;
    logic [15:0] act_deskew_rel_target;
    logic        act_ping_ack;
    logic signed [15:0] act_measured_skew;
    logic        act_crc_err;

    function new(string name = "vxm_nim_seq_item");
      super.new(name);
    endfunction
  endclass : vxm_nim_seq_item

  typedef uvm_sequencer #(vxm_nim_seq_item) vxm_nim_sequencer;

  // ---------------------------------------------------------------------------
  // 3. Comprehensive 3,200-Transaction Stimulus Sequence
  // ---------------------------------------------------------------------------
  class vxm_nim_sequence extends uvm_sequence #(vxm_nim_seq_item);
    `uvm_object_utils(vxm_nim_sequence)

    int unsigned next_id = 0;

    function new(string name = "vxm_nim_sequence");
      super.new(name);
    endfunction

    function automatic bit [7:0] crc8_byte_step_sv(bit [7:0] crc_in, bit [7:0] data_byte);
      bit [7:0] c = crc_in ^ data_byte;
      for (int b = 0; b < 8; b++) begin
        if (c[7]) c = (c << 1) ^ 8'h07;
        else      c = (c << 1);
      end
      return c;
    endfunction

    function automatic bit [7:0] calc_crc8_sv(bit [127:0] payload, bit [15:0] ts);
      bit [7:0] crc = 8'hFF;
      for (int i = 0; i < 16; i++) begin
        crc = crc8_byte_step_sv(crc, payload[i*8 +: 8]);
      end
      crc = crc8_byte_step_sv(crc, ts[7:0]);
      crc = crc8_byte_step_sv(crc, ts[15:8]);
      return crc;
    endfunction

    function automatic bit [127:0] make_vec128(int unsigned seed);
      bit [127:0] v;
      for (int i = 0; i < 16; i++) begin
        v[i*8 +: 8] = 8'((seed * 41 + i * 29 + 17) ^ (seed >> 3));
      end
      return v;
    endfunction

    function automatic bit [127:0] make_boundary_vec128(int unsigned pat);
      bit [127:0] v;
      bit [7:0] vals[8];
      vals[0] = 8'h80; // -128
      vals[1] = 8'h7F; // +127
      vals[2] = 8'h00; // 0
      vals[3] = 8'h01; // +1
      vals[4] = 8'hFF; // -1
      vals[5] = 8'hC0; // -64
      vals[6] = 8'h20; // +32
      vals[7] = 8'h40; // +64
      for (int i = 0; i < 16; i++) begin
        v[i*8 +: 8] = vals[(pat + i) & 7];
      end
      return v;
    endfunction

    function automatic bit [511:0] make_acc512(int unsigned seed);
      bit [511:0] acc;
      for (int i = 0; i < 16; i++) begin
        if (((seed + i) & 15) == 0)      acc[i*32 +: 32] = 32'h7FFF_FFF0;
        else if (((seed + i) & 15) == 1) acc[i*32 +: 32] = 32'h8000_0010;
        else                             acc[i*32 +: 32] = 32'(int'((seed * 19 + i * 23) % 1024) - 512);
      end
      return acc;
    endfunction

    task send_tx(vxm_nim_seq_item item);
      start_item(item);
      finish_item(item);
    endtask

    task body();
      vxm_nim_seq_item item;

      // Phase 1 (640 cycles): Directed sweep of all 16 VXM opcodes + saturation
      // boundaries (-128, +127, 0, +-1, INT32_MAX rounding) & all 8 NIM opcodes
      for (int k = 0; k < 640; k++) begin
        item = vxm_nim_seq_item::type_id::create($sformatf("p1_%0d", k));
        item.tx_id                  = next_id++;
        item.phase_id               = 1;
        item.vxm_op_valid           = ((k & 31) == 31) ? 1'b0 : 1'b1;
        item.vxm_op                 = 4'(k & 15);
        item.prec_mode              = ((k >> 4) & 1) ? PREC_FP8_E4M3 : PREC_INT8;
        item.quant_shift            = 3'((k >> 4) & 7);
        item.use_accum_32b          = bit'((k >> 5) & 1);
        item.stream_a               = (k < 320) ? make_boundary_vec128(k) : make_vec128(k);
        item.stream_b               = (k < 320) ? make_boundary_vec128(k + 3) : make_vec128(k + 100);
        item.stream_c               = make_boundary_vec128(k + 5);
        item.accum_32b_in           = make_acc512(k);

        item.nim_op_valid           = 1'b1;
        item.nim_op                 = 4'(k & 7);
        item.realsync_aligned_time  = 16'(100 + k);
        item.expected_flight_cycles = 16'((k & 3) + 1);
        item.local_chip_id          = 4'd1;
        item.tx_dst_chip            = ((k & 3) == 0) ? 4'd2 : (((k & 3) == 1) ? 4'd6 : 4'd9);
        item.ugal_nonminimal_en     = ((k & 3) == 2);
        item.link_congested         = ((k & 3) == 2);
        item.local_stream_in_valid  = 1'b1;
        item.local_stream_in_data   = make_vec128(k + 500);
        item.c2c_rx_valid           = ((k & 1) == 0);
        item.c2c_rx_data            = make_vec128(k + 700);
        item.c2c_rx_tx_timestamp    = 16'(100 + k);
        item.c2c_rx_dst_chip        = 4'((k + 2) & 15);
        item.c2c_rx_crc8            = calc_crc8_sv(item.c2c_rx_data, item.c2c_rx_tx_timestamp);
        send_tx(item);
      end

      // Phase 2 (640 cycles): Plesiochronous RealSync elastic deskew stress across
      // varying flight delays (0..4 cycles) & full-duplex concurrent TX/RX release
      for (int k = 0; k < 640; k++) begin
        item = vxm_nim_seq_item::type_id::create($sformatf("p2_%0d", k));
        item.tx_id                  = next_id++;
        item.phase_id               = 2;
        item.vxm_op_valid           = 1'b1;
        item.vxm_op                 = 4'((k * 3 + 1) & 15);
        item.prec_mode              = (k & 1) ? PREC_FP8_E4M3 : PREC_INT8;
        item.quant_shift            = 3'(k & 7);
        item.use_accum_32b          = bit'((k >> 1) & 1);
        item.stream_a               = make_vec128(1000 + k);
        item.stream_b               = make_vec128(2000 + k);
        item.stream_c               = make_vec128(3000 + k);
        item.accum_32b_in           = make_acc512(1000 + k);

        item.nim_op_valid           = ((k & 7) != 7);
        item.nim_op                 = 4'((k >> 1) & 7);
        item.realsync_aligned_time  = 16'(2000 + k);
        item.expected_flight_cycles = 16'(k % 4);
        item.local_chip_id          = 4'(k & 3);
        item.tx_dst_chip            = 4'((k + 4) & 15);
        item.ugal_nonminimal_en     = bit'(k & 1);
        item.link_congested         = bit'((k >> 1) & 1);
        item.local_stream_in_valid  = 1'b1;
        item.local_stream_in_data   = make_boundary_vec128(k);
        item.c2c_rx_valid           = ((k % 3) != 2);
        item.c2c_rx_data            = make_boundary_vec128(k + 2);
        item.c2c_rx_tx_timestamp    = 16'(2000 + k);
        item.c2c_rx_dst_chip        = 4'((k + 5) & 15);
        item.c2c_rx_crc8            = calc_crc8_sv(item.c2c_rx_data, item.c2c_rx_tx_timestamp);
        send_tx(item);
      end

      // Phase 3 (640 cycles): CRC-8 single-bit/multi-bit fault injection & operand gating
      for (int k = 0; k < 640; k++) begin
        bit [7:0] good_crc;
        item = vxm_nim_seq_item::type_id::create($sformatf("p3_%0d", k));
        item.tx_id                  = next_id++;
        item.phase_id               = 3;
        item.vxm_op_valid           = 1'b1;
        item.vxm_op                 = 4'((k + 5) & 15);
        item.prec_mode              = ((k & 2) != 0) ? PREC_FP8_E4M3 : PREC_INT8;
        item.quant_shift            = 3'((k * 3) & 7);
        item.use_accum_32b          = bit'(k & 1);
        item.stream_a               = make_boundary_vec128(k * 3);
        item.stream_b               = make_boundary_vec128(k * 5 + 1);
        item.stream_c               = make_vec128(4000 + k);
        item.accum_32b_in           = make_acc512(4000 + k);

        item.nim_op_valid           = 1'b1;
        item.nim_op                 = 4'(k & 7);
        item.realsync_aligned_time  = 16'(4000 + k);
        item.expected_flight_cycles = 16'((k & 1) + 1);
        item.local_chip_id          = 4'((k >> 2) & 15);
        item.tx_dst_chip            = 4'((k + 3) & 15);
        item.ugal_nonminimal_en     = bit'((k >> 1) & 1);
        item.link_congested         = bit'((k >> 2) & 1);
        item.local_stream_in_valid  = 1'b1;
        item.local_stream_in_data   = make_vec128(5000 + k);
        item.c2c_rx_valid           = 1'b1;
        item.c2c_rx_data            = make_vec128(6000 + k);
        item.c2c_rx_tx_timestamp    = 16'(4000 + k);
        item.c2c_rx_dst_chip        = 4'((k + 7) & 15);
        good_crc                    = calc_crc8_sv(item.c2c_rx_data, item.c2c_rx_tx_timestamp);
        item.c2c_rx_crc8            = (k & 1) ? (good_crc ^ 8'(1 << (k & 7))) : good_crc;
        send_tx(item);
      end

      // Phase 4 (1,280 cycles): Concurrent full-chip stress across all opcodes
      for (int k = 0; k < 1280; k++) begin
        bit [7:0] good_crc;
        item = vxm_nim_seq_item::type_id::create($sformatf("p4_%0d", k));
        item.tx_id                  = next_id++;
        item.phase_id               = 4;
        item.vxm_op_valid           = ((k % 19) != 0);
        item.vxm_op                 = 4'((k * 7 + 3) & 15);
        item.prec_mode              = ((k * 5) & 1) ? PREC_FP8_E4M3 : PREC_INT8;
        item.quant_shift            = 3'((k * 5 + 1) & 7);
        item.use_accum_32b          = bit'((k * 3) & 1);
        item.stream_a               = make_vec128(7000 + k);
        item.stream_b               = make_vec128(8000 + k);
        item.stream_c               = make_vec128(9000 + k);
        item.accum_32b_in           = make_acc512(7000 + k);

        item.nim_op_valid           = ((k % 17) != 0);
        item.nim_op                 = 4'((k * 3 + 2) & 7);
        item.realsync_aligned_time  = 16'(8000 + k);
        item.expected_flight_cycles = 16'(k & 3);
        item.local_chip_id          = 4'((k * 3) & 15);
        item.tx_dst_chip            = 4'((k * 7 + 1) & 15);
        item.ugal_nonminimal_en     = bit'((k >> 1) & 1);
        item.link_congested         = bit'((k >> 2) & 1);
        item.local_stream_in_valid  = ((k % 11) != 0);
        item.local_stream_in_data   = make_vec128(10000 + k);
        item.c2c_rx_valid           = ((k % 5) != 0);
        item.c2c_rx_data            = make_vec128(11000 + k);
        item.c2c_rx_tx_timestamp    = 16'(8000 + k);
        item.c2c_rx_dst_chip        = 4'((k * 5 + 2) & 15);
        good_crc                    = calc_crc8_sv(item.c2c_rx_data, item.c2c_rx_tx_timestamp);
        item.c2c_rx_crc8            = ((k % 7) == 0) ? (good_crc ^ 8'hA5) : good_crc;
        send_tx(item);
      end
    endtask
  endclass : vxm_nim_sequence

  // ---------------------------------------------------------------------------
  // 4. UVM Driver
  // ---------------------------------------------------------------------------
  class vxm_nim_driver extends uvm_driver #(vxm_nim_seq_item);
    `uvm_component_utils(vxm_nim_driver)

    virtual groq_vxm_nim_if vif;
    int unsigned driven = 0;

    function new(string name = "vxm_nim_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual groq_vxm_nim_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface groq_vxm_nim_if missing in vxm_nim_driver")
      end
    endfunction

    task run_phase(uvm_phase phase);
      vxm_nim_seq_item item;
      vif.rst_n     = 1'b0;
      vif.sample_en = 1'b0;
      repeat (4) @(negedge vif.clk);

      forever begin
        seq_item_port.get_next_item(item);
        vif.rst_n                    = 1'b1;
        vif.sample_en                = 1'b1;
        vif.tx_id                    = item.tx_id;
        vif.phase_id                 = item.phase_id;
        vif.vxm_op_valid_i           = item.vxm_op_valid;
        vif.vxm_op_i                 = item.vxm_op;
        vif.prec_mode_i              = item.prec_mode;
        vif.quant_shift_i            = item.quant_shift;
        vif.use_accum_32b_i          = item.use_accum_32b;
        vif.stream_a_i               = item.stream_a;
        vif.stream_b_i               = item.stream_b;
        vif.stream_c_i               = item.stream_c;
        vif.accum_32b_in_i           = item.accum_32b_in;

        vif.nim_op_valid_i           = item.nim_op_valid;
        vif.nim_op_i                 = item.nim_op;
        vif.realsync_aligned_time_i  = item.realsync_aligned_time;
        vif.expected_flight_cycles_i = item.expected_flight_cycles;
        vif.local_chip_id_i          = item.local_chip_id;
        vif.tx_dst_chip_i            = item.tx_dst_chip;
        vif.ugal_nonminimal_en_i     = item.ugal_nonminimal_en;
        vif.link_congested_i         = item.link_congested;
        vif.local_stream_in_valid_i  = item.local_stream_in_valid;
        vif.local_stream_in_data_i   = item.local_stream_in_data;
        vif.c2c_rx_valid_i           = item.c2c_rx_valid;
        vif.c2c_rx_data_i            = item.c2c_rx_data;
        vif.c2c_rx_tx_timestamp_i    = item.c2c_rx_tx_timestamp;
        vif.c2c_rx_dst_chip_i        = item.c2c_rx_dst_chip;
        vif.c2c_rx_crc8_i            = item.c2c_rx_crc8;

        @(negedge vif.clk);
        vif.sample_en                = 1'b0;
        driven++;
        seq_item_port.item_done();
      end
    endtask
  endclass : vxm_nim_driver

  // ---------------------------------------------------------------------------
  // 5. UVM Monitor & Functional Covergroup
  // ---------------------------------------------------------------------------
  class vxm_nim_monitor extends uvm_monitor;
    `uvm_component_utils(vxm_nim_monitor)

    virtual groq_vxm_nim_if vif;
    uvm_analysis_port #(vxm_nim_seq_item) ap;
    int unsigned seen = 0;

    covergroup vxm_nim_cg with function sample(
      bit [3:0] vxm_op,
      bit [3:0] prec_mode,
      bit [2:0] quant_shift,
      bit       use_acc32,
      bit       mul_gate,
      bit       lut_gate,
      bit [3:0] nim_op,
      bit [1:0] tx_port,
      bit       deskew_rel,
      bit       crc_err
    );
      option.per_instance = 1;
      cp_vxm_op: coverpoint vxm_op {
        bins v_nop        = {VXM_NOP};
        bins v_add        = {VXM_ADD};
        bins v_mul        = {VXM_MUL};
        bins v_fma        = {VXM_FMA};
        bins v_silu       = {VXM_SILU};
        bins v_gelu       = {VXM_GELU};
        bins v_rsqrt      = {VXM_RSQRT_LUT};
        bins v_exp        = {VXM_EXP_LUT};
        bins v_swiglu     = {VXM_SWIGLU};
        bins v_quant      = {VXM_QUANT_SCALE};
        bins v_sub        = {VXM_SUB};
        bins v_max_elem   = {VXM_MAX_ELEM};
        bins v_min_elem   = {VXM_MIN_ELEM};
        bins v_relu       = {VXM_RELU};
        bins v_red_sum    = {VXM_REDUCE_SUM};
        bins v_red_max    = {VXM_REDUCE_MAX};
      }
      cp_prec_mode: coverpoint prec_mode {
        bins p_int8     = {PREC_INT8};
        bins p_fp8_e4m3 = {PREC_FP8_E4M3};
      }
      cp_quant_shift: coverpoint quant_shift {
        bins q_sh[] = {[3'd0:3'd7]};
      }
      cp_use_acc32: coverpoint use_acc32 {
        bins acc_off = {1'b0};
        bins acc_on  = {1'b1};
      }
      cp_mul_gate: coverpoint mul_gate {
        bins mg_active   = {1'b0};
        bins mg_isolated = {1'b1};
      }
      cp_lut_gate: coverpoint lut_gate {
        bins lg_active   = {1'b0};
        bins lg_isolated = {1'b1};
      }
      cp_nim_op: coverpoint nim_op {
        bins n_nop       = {NIM_NOP};
        bins n_send      = {NIM_SEND};
        bins n_recv      = {NIM_RECV};
        bins n_beacon    = {NIM_SYNC_BEACON};
        bins n_forward   = {NIM_FORWARD};
        bins n_allreduce = {NIM_ALLREDUCE_ADD};
        bins n_deskew    = {NIM_DESKEW_CAL};
        bins n_loopback  = {NIM_LOOPBACK};
      }
      cp_tx_port: coverpoint tx_port {
        bins p_local_min  = {2'd0};
        bins p_global_min = {2'd1};
        bins p_ugal_proxy = {2'd2};
      }
      cp_deskew_rel: coverpoint deskew_rel {
        bins d_idle    = {1'b0};
        bins d_release = {1'b1};
      }
      cp_crc_err: coverpoint crc_err {
        bins c_clean = {1'b0};
        bins c_fault = {1'b1};
      }
    endgroup

    function new(string name = "vxm_nim_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
      vxm_nim_cg = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual groq_vxm_nim_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface groq_vxm_nim_if missing in vxm_nim_monitor")
      end
    endfunction

    task run_phase(uvm_phase phase);
      forever begin
        @(posedge vif.clk);
        #1ps;
        if (vif.rst_n && vif.sample_en) begin
          vxm_nim_seq_item item = vxm_nim_seq_item::type_id::create("obs_item");
          item.tx_id                   = vif.tx_id;
          item.phase_id                = vif.phase_id;
          item.vxm_op_valid            = vif.vxm_op_valid_i;
          item.vxm_op                  = vif.vxm_op_i;
          item.prec_mode               = vif.prec_mode_i;
          item.quant_shift             = vif.quant_shift_i;
          item.use_accum_32b           = vif.use_accum_32b_i;
          item.stream_a                = vif.stream_a_i;
          item.stream_b                = vif.stream_b_i;
          item.stream_c                = vif.stream_c_i;
          item.accum_32b_in            = vif.accum_32b_in_i;

          item.nim_op_valid            = vif.nim_op_valid_i;
          item.nim_op                  = vif.nim_op_i;
          item.realsync_aligned_time   = vif.realsync_aligned_time_i;
          item.expected_flight_cycles  = vif.expected_flight_cycles_i;
          item.local_chip_id           = vif.local_chip_id_i;
          item.tx_dst_chip             = vif.tx_dst_chip_i;
          item.ugal_nonminimal_en      = vif.ugal_nonminimal_en_i;
          item.link_congested          = vif.link_congested_i;
          item.local_stream_in_valid   = vif.local_stream_in_valid_i;
          item.local_stream_in_data    = vif.local_stream_in_data_i;
          item.c2c_rx_valid            = vif.c2c_rx_valid_i;
          item.c2c_rx_data             = vif.c2c_rx_data_i;
          item.c2c_rx_tx_timestamp     = vif.c2c_rx_tx_timestamp_i;
          item.c2c_rx_dst_chip         = vif.c2c_rx_dst_chip_i;
          item.c2c_rx_crc8             = vif.c2c_rx_crc8_i;

          item.act_vxm_out_valid       = vif.vxm_out_valid_o;
          item.act_vxm_out_data        = vif.vxm_out_data_o;
          item.act_vxm_accum_out       = vif.vxm_accum_32b_out_o;
          item.act_vxm_comb_data       = vif.vxm_comb_data_o;
          item.act_vxm_reduce_sum      = vif.vxm_reduce_sum_o;
          item.act_vxm_reduce_max      = vif.vxm_reduce_max_o;
          item.act_vxm_mul_gate        = vif.vxm_mul_gate_active_o;
          item.act_vxm_lut_gate        = vif.vxm_lut_gate_active_o;

          item.act_nim_local_out_valid = vif.nim_local_out_valid_o;
          item.act_nim_local_out_data  = vif.nim_local_out_data_o;
          item.act_c2c_tx_valid        = vif.c2c_tx_valid_o;
          item.act_c2c_tx_data         = vif.c2c_tx_data_o;
          item.act_c2c_tx_ts           = vif.c2c_tx_timestamp_o;
          item.act_c2c_tx_dst          = vif.c2c_tx_dst_chip_o;
          item.act_c2c_tx_crc8         = vif.c2c_tx_crc8_o;
          item.act_c2c_tx_port         = vif.c2c_tx_port_sel_o;
          item.act_deskew_rel_valid    = vif.deskew_release_valid_o;
          item.act_deskew_rel_target   = vif.deskew_released_target_cycle_o;
          item.act_ping_ack            = vif.realsync_ping_ack_o;
          item.act_measured_skew       = vif.measured_skew_o;
          item.act_crc_err             = vif.crc_err_o;

          vxm_nim_cg.sample(
            item.vxm_op,
            item.prec_mode,
            item.quant_shift,
            item.use_accum_32b,
            bit'(item.act_vxm_mul_gate),
            bit'(item.act_vxm_lut_gate),
            item.nim_op,
            2'(item.act_c2c_tx_port),
            bit'(item.act_deskew_rel_valid),
            bit'(item.act_crc_err)
          );
          seen++;
          ap.write(item);
        end
      end
    endtask
  endclass : vxm_nim_monitor

  // ---------------------------------------------------------------------------
  // 6. UVM Scoreboard with C++17 DPI-C Bit-Exact Reference Check
  // ---------------------------------------------------------------------------
  class vxm_nim_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(vxm_nim_scoreboard)

    uvm_analysis_imp #(vxm_nim_seq_item, vxm_nim_scoreboard) imp;
    int unsigned checked_cycles = 0;
    int unsigned vxm_checks     = 0;
    int unsigned nim_checks     = 0;
    int unsigned deskew_events  = 0;
    int unsigned crc_err_events = 0;
    int unsigned mismatches     = 0;

    function new(string name = "vxm_nim_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      imp = new("imp", this);
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
      super.start_of_simulation_phase(phase);
      dpi_vxm_nim_reset();
    endfunction

    function void write(vxm_nim_seq_item item);
      int unsigned exp_vxm_out_valid;
      bit [127:0]  exp_vxm_out_data;
      bit [511:0]  exp_vxm_accum_out;
      bit [127:0]  exp_vxm_comb_data;
      int          exp_vxm_reduce_sum;
      int          exp_vxm_reduce_max;
      int unsigned exp_vxm_mul_gate;
      int unsigned exp_vxm_lut_gate;
      int unsigned exp_nim_local_out_valid;
      bit [127:0]  exp_nim_local_out_data;
      int unsigned exp_c2c_tx_valid;
      bit [127:0]  exp_c2c_tx_data;
      int unsigned exp_c2c_tx_ts;
      int unsigned exp_c2c_tx_dst;
      int unsigned exp_c2c_tx_crc8;
      int unsigned exp_c2c_tx_port;
      int unsigned exp_deskew_rel_valid;
      int unsigned exp_deskew_rel_target;
      int unsigned exp_ping_ack;
      int          exp_measured_skew;
      int unsigned exp_crc_err;

      dpi_vxm_nim_step(
        int'(item.vxm_op_valid),
        int'(item.vxm_op),
        int'(item.prec_mode),
        int'(item.quant_shift),
        int'(item.use_accum_32b),
        item.stream_a,
        item.stream_b,
        item.stream_c,
        item.accum_32b_in,
        int'(item.nim_op_valid),
        int'(item.nim_op),
        int'(item.realsync_aligned_time),
        int'(item.expected_flight_cycles),
        int'(item.local_chip_id),
        int'(item.tx_dst_chip),
        int'(item.ugal_nonminimal_en),
        int'(item.link_congested),
        int'(item.local_stream_in_valid),
        item.local_stream_in_data,
        int'(item.c2c_rx_valid),
        item.c2c_rx_data,
        int'(item.c2c_rx_tx_timestamp),
        int'(item.c2c_rx_dst_chip),
        int'(item.c2c_rx_crc8),
        exp_vxm_out_valid,
        exp_vxm_out_data,
        exp_vxm_accum_out,
        exp_vxm_comb_data,
        exp_vxm_reduce_sum,
        exp_vxm_reduce_max,
        exp_vxm_mul_gate,
        exp_vxm_lut_gate,
        exp_nim_local_out_valid,
        exp_nim_local_out_data,
        exp_c2c_tx_valid,
        exp_c2c_tx_data,
        exp_c2c_tx_ts,
        exp_c2c_tx_dst,
        exp_c2c_tx_crc8,
        exp_c2c_tx_port,
        exp_deskew_rel_valid,
        exp_deskew_rel_target,
        exp_ping_ack,
        exp_measured_skew,
        exp_crc_err
      );

      checked_cycles++;
      vxm_checks++;
      nim_checks++;
      if (item.act_deskew_rel_valid || item.act_nim_local_out_valid) deskew_events++;
      if (item.act_crc_err) crc_err_events++;

      if ((item.act_vxm_out_valid  !== 1'(exp_vxm_out_valid)) ||
          (item.act_vxm_out_data   !== exp_vxm_out_data) ||
          (item.act_vxm_accum_out  !== exp_vxm_accum_out) ||
          (item.act_vxm_comb_data  !== exp_vxm_comb_data) ||
          (int'(item.act_vxm_reduce_sum) !== exp_vxm_reduce_sum) ||
          (int'(item.act_vxm_reduce_max) !== exp_vxm_reduce_max) ||
          (item.act_vxm_mul_gate   !== 1'(exp_vxm_mul_gate)) ||
          (item.act_vxm_lut_gate   !== 1'(exp_vxm_lut_gate))) begin
        mismatches++;
        `uvm_error("VXM_MISMATCH", $sformatf(
          "tx=%0d vxm_op=%0d exp_comb=%032x act_comb=%032x exp_out=%032x act_out=%032x",
          item.tx_id, item.vxm_op, exp_vxm_comb_data, item.act_vxm_comb_data,
          exp_vxm_out_data, item.act_vxm_out_data))
      end

      if ((item.act_nim_local_out_valid !== 1'(exp_nim_local_out_valid)) ||
          (item.act_nim_local_out_data  !== exp_nim_local_out_data) ||
          (item.act_c2c_tx_valid        !== 1'(exp_c2c_tx_valid)) ||
          (item.act_c2c_tx_data         !== exp_c2c_tx_data) ||
          (item.act_c2c_tx_ts           !== 16'(exp_c2c_tx_ts)) ||
          (item.act_c2c_tx_dst          !== 4'(exp_c2c_tx_dst)) ||
          (item.act_c2c_tx_crc8         !== 8'(exp_c2c_tx_crc8)) ||
          (item.act_c2c_tx_port         !== 2'(exp_c2c_tx_port)) ||
          (item.act_deskew_rel_valid    !== 1'(exp_deskew_rel_valid)) ||
          (item.act_deskew_rel_target   !== 16'(exp_deskew_rel_target)) ||
          (item.act_ping_ack            !== 1'(exp_ping_ack)) ||
          (int'(item.act_measured_skew) !== exp_measured_skew) ||
          (item.act_crc_err             !== 1'(exp_crc_err))) begin
        mismatches++;
        `uvm_error("NIM_MISMATCH", $sformatf(
          "tx=%0d nim_op=%0d exp_loc_v=%0d act_loc_v=%0d exp_tx_v=%0d act_tx_v=%0d exp_crc_err=%0d act_crc_err=%0d",
          item.tx_id, item.nim_op, exp_nim_local_out_valid, item.act_nim_local_out_valid,
          exp_c2c_tx_valid, item.act_c2c_tx_valid, exp_crc_err, item.act_crc_err))
      end
    endfunction
  endclass : vxm_nim_scoreboard

  // ---------------------------------------------------------------------------
  // 7. UVM Environment & Top-Level Test
  // ---------------------------------------------------------------------------
  class vxm_nim_env extends uvm_env;
    `uvm_component_utils(vxm_nim_env)

    vxm_nim_sequencer  sequencer;
    vxm_nim_driver     driver;
    vxm_nim_monitor    monitor;
    vxm_nim_scoreboard scoreboard;

    function new(string name = "vxm_nim_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer  = vxm_nim_sequencer::type_id::create("sequencer", this);
      driver     = vxm_nim_driver::type_id::create("driver", this);
      monitor    = vxm_nim_monitor::type_id::create("monitor", this);
      scoreboard = vxm_nim_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
      monitor.ap.connect(scoreboard.imp);
    endfunction
  endclass : vxm_nim_env

  class vxm_nim_test extends uvm_test;
    `uvm_component_utils(vxm_nim_test)

    vxm_nim_env env;

    function new(string name = "vxm_nim_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = vxm_nim_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      vxm_nim_sequence seq = vxm_nim_sequence::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.sequencer);
      repeat (2) @(negedge env.driver.vif.clk);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      int unsigned dpi_calls;
      real func_cov;
      bit pass_gate;
      int fd;
      super.report_phase(phase);

      dpi_calls = dpi_get_calls();
      func_cov  = env.monitor.vxm_nim_cg.get_inst_coverage();
      pass_gate = (env.driver.driven >= 3000) &&
                  (env.monitor.seen == env.driver.driven) &&
                  (env.scoreboard.checked_cycles == env.driver.driven) &&
                  (dpi_calls == env.driver.driven) &&
                  (env.scoreboard.mismatches == 0) &&
                  (env.scoreboard.deskew_events > 0) &&
                  (env.scoreboard.crc_err_events > 0) &&
                  (func_cov == 100.0);

      fd = $fopen("vxm_nim_summary.json", "w");
      if (fd == 0) `uvm_fatal("JSON_OPEN", "Cannot open vxm_nim_summary.json")
      $fdisplay(fd, "{");
      $fdisplay(fd, "  \"suite\": \"uvm_vxm_nim\",");
      $fdisplay(fd, "  \"dut\": [\"groq_vxm_slice\", \"groq_nim_realsync\"],");
      $fdisplay(fd, "  \"driven_cycles\": %0d,", env.driver.driven);
      $fdisplay(fd, "  \"observed_cycles\": %0d,", env.monitor.seen);
      $fdisplay(fd, "  \"checked_cycles\": %0d,", env.scoreboard.checked_cycles);
      $fdisplay(fd, "  \"dpi_calls\": %0d,", dpi_calls);
      $fdisplay(fd, "  \"vxm_slice_checks\": %0d,", env.scoreboard.vxm_checks);
      $fdisplay(fd, "  \"nim_realsync_checks\": %0d,", env.scoreboard.nim_checks);
      $fdisplay(fd, "  \"deskew_release_events\": %0d,", env.scoreboard.deskew_events);
      $fdisplay(fd, "  \"crc_fault_detections\": %0d,", env.scoreboard.crc_err_events);
      $fdisplay(fd, "  \"mismatches\": %0d,", env.scoreboard.mismatches);
      $fdisplay(fd, "  \"functional_coverage_pct\": %0.2f,", func_cov);
      $fdisplay(fd, "  \"pass\": %0d", pass_gate);
      $fdisplay(fd, "}");
      $fclose(fd);

      dpi_set_status(pass_gate ? 0 : 1);
      if (!pass_gate) begin
        `uvm_fatal("UVM_VXM_NIM_FAIL", $sformatf(
          "Gate failed: driven=%0d checked=%0d mismatches=%0d cov=%0.2f%%",
          env.driver.driven, env.scoreboard.checked_cycles,
          env.scoreboard.mismatches, func_cov))
      end else begin
        `uvm_info("UVM_VXM_NIM_PASS", $sformatf(
          "PASS: %0d transactions checked via C++17 DPI-C reference, 0 mismatches, 100.00%% functional coverage",
          env.scoreboard.checked_cycles), UVM_LOW)
      end
    endfunction
  endclass : vxm_nim_test

endpackage : groq_vxm_nim_uvm_pkg

`endif // GROQ_VXM_NIM_UVM_PKG_SV
