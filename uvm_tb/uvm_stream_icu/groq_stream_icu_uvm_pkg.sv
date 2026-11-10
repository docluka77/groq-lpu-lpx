// =============================================================================
// File: uvm_tb/uvm_stream_icu/groq_stream_icu_uvm_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Accellera IEEE 1800.2-2020 UVM Verification Package for
//              groq_stream_fabric and groq_icu_slice (Sequence Item, Sequence,
//              Sequencer, Driver, Monitor with Covergroup, DPI-C Scoreboard,
//              Environment, and Test).
// =============================================================================
`ifndef GROQ_STREAM_ICU_UVM_PKG_SV
`define GROQ_STREAM_ICU_UVM_PKG_SV

`timescale 1ns/1ps
`include "uvm_macros.svh"
`include "groq_pkg.sv"

package groq_stream_icu_uvm_pkg;
  import uvm_pkg::*;
  import groq_pkg::*;

  // ---------------------------------------------------------------------------
  // DPI-C Cycle-Accurate Reference Model Imports
  // ---------------------------------------------------------------------------
  import "DPI-C" function void dpi_set_status(int status);
  import "DPI-C" function int  dpi_get_status();
  import "DPI-C" function int unsigned dpi_get_calls();
  import "DPI-C" function void dpi_ref_reset();
  import "DPI-C" function void dpi_ref_set_global_inputs(
    int unsigned icu_en,
    int unsigned notify_ready_mask,
    int unsigned realsync_ext_en,
    int realsync_ext_val
  );
  import "DPI-C" function void dpi_ref_set_slice_inputs(
    int s,
    int unsigned icu_op,
    int unsigned sync_mask,
    int unsigned nop_cnt,
    int unsigned imm16,
    int unsigned east_inj_en,
    int unsigned east_ovw_en,
    int unsigned east_con_en,
    longint unsigned east_seed,
    int unsigned west_inj_en,
    int unsigned west_ovw_en,
    int unsigned west_con_en,
    longint unsigned west_seed
  );
  import "DPI-C" function void dpi_ref_eval_comb();
  import "DPI-C" function void dpi_ref_step_seq();

  import "DPI-C" function int unsigned dpi_exp_east_valid(int s);
  import "DPI-C" function int unsigned dpi_exp_west_valid(int s);
  import "DPI-C" function longint unsigned dpi_exp_east_data_lo(int s, int c);
  import "DPI-C" function longint unsigned dpi_exp_east_data_hi(int s, int c);
  import "DPI-C" function longint unsigned dpi_exp_west_data_lo(int s, int c);
  import "DPI-C" function longint unsigned dpi_exp_west_data_hi(int s, int c);
  import "DPI-C" function int unsigned dpi_exp_collision_east(int s);
  import "DPI-C" function int unsigned dpi_exp_collision_west(int s);
  import "DPI-C" function int unsigned dpi_exp_collision_any();
  import "DPI-C" function int unsigned dpi_exp_collision_sticky();
  import "DPI-C" function int unsigned dpi_exp_gated_hop_count();
  import "DPI-C" function int unsigned dpi_exp_pc_slice(int s);
  import "DPI-C" function int unsigned dpi_exp_nop_timer(int s);
  import "DPI-C" function int unsigned dpi_exp_slice_halted(int s);
  import "DPI-C" function int unsigned dpi_exp_barrier_waiting(int s);
  import "DPI-C" function int unsigned dpi_exp_imem_fetch_en();
  import "DPI-C" function int unsigned dpi_exp_slice_vliw_valid();
  import "DPI-C" function int unsigned dpi_exp_barrier_ready_mask();
  import "DPI-C" function int unsigned dpi_exp_barrier_release_pulse();
  import "DPI-C" function int unsigned dpi_exp_barrier_release_cnt();
  import "DPI-C" function longint unsigned dpi_exp_realsync_cycle_cnt();
  import "DPI-C" function int dpi_exp_realsync_deskew();
  import "DPI-C" function longint unsigned dpi_exp_realsync_aligned_time();
  import "DPI-C" function int unsigned dpi_exp_realsync_drift_fault();

  // ---------------------------------------------------------------------------
  // 1. UVM Sequence Item: stream_icu_seq_item
  // ---------------------------------------------------------------------------
  class stream_icu_seq_item extends uvm_sequence_item;
    `uvm_object_utils(stream_icu_seq_item)

    int unsigned     cycle_id;
    bit              icu_enable;
    bit [7:0]        slice_notify_ready;
    bit              realsync_ext_adj_en;
    shortint         realsync_ext_adj_val;

    bit [3:0]        icu_op [NUM_SLICES];
    bit [7:0]        sync_mask [NUM_SLICES];
    bit [15:0]       nop_cnt [NUM_SLICES];
    bit [15:0]       imm16 [NUM_SLICES];

    bit [15:0]       east_inj_en [NUM_SLICES];
    bit [15:0]       east_ovw_en [NUM_SLICES];
    bit [15:0]       east_con_en [NUM_SLICES];
    longint unsigned east_seed   [NUM_SLICES];

    bit [15:0]       west_inj_en [NUM_SLICES];
    bit [15:0]       west_ovw_en [NUM_SLICES];
    bit [15:0]       west_con_en [NUM_SLICES];
    longint unsigned west_seed   [NUM_SLICES];
    // Observed DUT response fields sampled by stream_icu_monitor
    logic [15:0] act_east_valid   [NUM_SLICES];
    logic [63:0] act_east_data_lo [NUM_SLICES][NUM_EAST_STREAMS];
    logic [63:0] act_east_data_hi [NUM_SLICES][NUM_EAST_STREAMS];
    logic [15:0] act_collision_east [NUM_SLICES];

    logic [15:0] act_west_valid   [NUM_SLICES];
    logic [63:0] act_west_data_lo [NUM_SLICES][NUM_WEST_STREAMS];
    logic [63:0] act_west_data_hi [NUM_SLICES][NUM_WEST_STREAMS];
    logic [15:0] act_collision_west [NUM_SLICES];

    logic        act_collision_any;
    logic        act_collision_sticky;
    logic [15:0] act_gated_hop_count;

    logic [7:0]  act_imem_fetch_en;
    logic [15:0] act_pc_slice [NUM_SLICES];
    logic [7:0]  act_slice_vliw_valid;
    logic [15:0] act_nop_timer [NUM_SLICES];
    logic [7:0]  act_slice_halted;
    logic [7:0]  act_barrier_waiting;
    logic [7:0]  act_barrier_ready_mask;
    logic        act_barrier_release_pulse;
    logic [15:0] act_barrier_release_cnt;
    logic [63:0] act_realsync_cycle_cnt;
    shortint     act_realsync_deskew;
    logic [63:0] act_realsync_aligned_time;
    logic        act_realsync_drift_fault;

    function new(string name = "stream_icu_seq_item");
      super.new(name);
    endfunction
  endclass : stream_icu_seq_item

  // ---------------------------------------------------------------------------
  // 2. UVM Sequencer: stream_icu_sequencer
  // ---------------------------------------------------------------------------
  class stream_icu_sequencer extends uvm_sequencer #(stream_icu_seq_item);
    `uvm_component_utils(stream_icu_sequencer)
    function new(string name = "stream_icu_sequencer", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass : stream_icu_sequencer

  // ---------------------------------------------------------------------------
  // 3. UVM Sequence: stream_icu_sequence (2,200 Directed + Random Cycles)
  // ---------------------------------------------------------------------------
  class stream_icu_sequence extends uvm_sequence #(stream_icu_seq_item);
    `uvm_object_utils(stream_icu_sequence)

    int unsigned num_cycles = 2200;
    longint unsigned prng_state = 64'hCAFE_BABE_1337_BEEF;

    function new(string name = "stream_icu_sequence");
      super.new(name);
    endfunction

    function longint unsigned next_rand64();
      prng_state ^= (prng_state << 13);
      prng_state ^= (prng_state >> 7);
      prng_state ^= (prng_state << 17);
      return prng_state;
    endfunction

    task body();
      for (int unsigned cyc = 0; cyc < num_cycles; cyc++) begin
        stream_icu_seq_item item = stream_icu_seq_item::type_id::create("item");
        start_item(item);
        item.cycle_id            = cyc;
        item.icu_enable          = (cyc % 47 == 46) ? 1'b0 : 1'b1;
        item.slice_notify_ready  = 8'h00;
        item.realsync_ext_adj_en = 1'b0;
        item.realsync_ext_adj_val= 16'sd0;

        for (int s = 0; s < NUM_SLICES; s++) begin
          item.icu_op[s]      = ICU_NOP;
          item.sync_mask[s]   = 8'h00;
          item.nop_cnt[s]     = 16'd0;
          item.imm16[s]       = 16'd0;
          item.east_inj_en[s] = 16'h0000;
          item.east_ovw_en[s] = 16'h0000;
          item.east_con_en[s] = 16'h0000;
          item.east_seed[s]   = next_rand64();
          item.west_inj_en[s] = 16'h0000;
          item.west_ovw_en[s] = 16'h0000;
          item.west_con_en[s] = 16'h0000;
          item.west_seed[s]   = next_rand64();
        end
        // Phase A (0..199): Directed East/West stream propagation, collisions,
        // legal overwrites, consumption, and NOP_DELAY / JUMP_IMM / REALSYNC_ADJ
        if (cyc < 200) begin
          int s_act = cyc % NUM_SLICES;
          item.east_inj_en[s_act] = (cyc[0]) ? 16'hFFFF : 16'h5555;
          item.west_inj_en[s_act] = (cyc[0]) ? 16'hAAAA : 16'hFFFF;
          // Trigger deliberate East/West write collisions on adjacent hop
          if ((cyc % 10) == 3) begin
            item.east_inj_en[(s_act + 1) % NUM_SLICES] = 16'hFFFF;
            item.east_ovw_en[(s_act + 1) % NUM_SLICES] = 16'h0000;
            item.west_inj_en[(s_act + NUM_SLICES - 1) % NUM_SLICES] = 16'hFFFF;
            item.west_ovw_en[(s_act + NUM_SLICES - 1) % NUM_SLICES] = 16'h0000;
          end else if ((cyc % 10) == 5) begin
            // Legal overwrite with overwrite_allow = 1
            item.east_inj_en[(s_act + 1) % NUM_SLICES] = 16'hFFFF;
            item.east_ovw_en[(s_act + 1) % NUM_SLICES] = 16'hFFFF;
            item.west_inj_en[(s_act + NUM_SLICES - 1) % NUM_SLICES] = 16'hFFFF;
            item.west_ovw_en[(s_act + NUM_SLICES - 1) % NUM_SLICES] = 16'hFFFF;
          end else if ((cyc % 10) == 7) begin
            // Consume incoming stream tokens
            item.east_con_en[(s_act + 1) % NUM_SLICES] = 16'hFFFF;
            item.west_con_en[(s_act + NUM_SLICES - 1) % NUM_SLICES] = 16'hFFFF;
          end

          if ((cyc % 16) == 2) begin
            item.icu_op[s_act]  = ICU_NOP_DELAY;
            item.nop_cnt[s_act] = 16'(1 + (cyc % 4));
          end else if ((cyc % 16) == 8) begin
            item.icu_op[s_act]  = ICU_JUMP_IMM;
            item.imm16[s_act]   = 16'h0100 + 16'(cyc);
          end else if ((cyc % 16) == 12) begin
            item.icu_op[SLICE_ICU] = ICU_REALSYNC_ADJ;
            item.imm16[SLICE_ICU]  = (cyc < 100) ? 16'(cyc - 40) : 16'd80; // includes >64 drift fault
          end else if ((cyc % 16) == 14) begin
            item.realsync_ext_adj_en  = 1'b1;
            item.realsync_ext_adj_val = -16'sd12;
          end
        end
        // Phase B (200..399): Multi-slice SYNC_BARRIER & staggered NOTIFY sweep
        else if (cyc < 400) begin
          int phase_step = (cyc - 200) % 10;
          item.icu_enable = 1'b1;
          if (phase_step == 0) begin
            // Slice 0 & 1 enter barrier waiting for all 8 slices (0xFF)
            item.icu_op[0]    = ICU_SYNC_BARRIER;
            item.sync_mask[0] = 8'hFF;
            item.icu_op[1]    = ICU_SYNC_BARRIER;
            item.sync_mask[1] = 8'h0F;
          end else if (phase_step >= 1 && phase_step <= 6) begin
            int notify_s = phase_step + 1;
            item.icu_op[notify_s] = ICU_NOTIFY;
          end else if (phase_step == 7) begin
            item.slice_notify_ready = 8'hFF;
          end
          // Keep streams active during barrier waits
          item.east_inj_en[cyc % NUM_SLICES] = 16'h0F0F;
          item.west_inj_en[(cyc + 3) % NUM_SLICES] = 16'hF0F0;
        end
        // Phase C (400..2179): Constrained-Random Full-Fabric + ICU Stress
        else if (cyc < 2180) begin
          longint unsigned r = next_rand64();
          for (int s = 0; s < NUM_SLICES; s++) begin
            longint unsigned rs = next_rand64();
            item.east_inj_en[s] = rs[15:0];
            item.east_ovw_en[s] = rs[31:16];
            item.east_con_en[s] = rs[47:32];
            item.west_inj_en[s] = rs[63:48];
            rs = next_rand64();
            item.west_ovw_en[s] = rs[15:0];
            item.west_con_en[s] = rs[31:16];

            if ((cyc % 20) == 0 && s == (cyc / 20) % NUM_SLICES) begin
              item.icu_op[s]    = ICU_SYNC_BARRIER;
              item.sync_mask[s] = (rs[39:32] == 8'h00) ? 8'h03 : rs[39:32];
            end else if ((cyc % 20) >= 4 && (cyc % 20) <= 6) begin
              item.icu_op[s]         = ICU_NOTIFY;
              item.slice_notify_ready= 8'hFF;
            end else begin
              case (rs[43:40] % 5)
                0: item.icu_op[s] = ICU_NOP;
                1: begin
                  item.icu_op[s]  = ICU_NOP_DELAY;
                  item.nop_cnt[s] = 16'(rs[45:44]); // 0..3 cycle delay
                end
                2: item.icu_op[s] = ICU_NOTIFY;
                3: begin
                  item.icu_op[s]  = ICU_JUMP_IMM;
                  item.imm16[s]   = rs[63:48];
                end
                default: begin
                  item.icu_op[s]  = (s == SLICE_ICU) ? ICU_REALSYNC_ADJ : ICU_NOP;
                  item.imm16[s]   = { {9{rs[54]}}, rs[54:48] };
                end
              endcase
            end
          end
          if ((r % 29) == 0) begin
            item.realsync_ext_adj_en  = 1'b1;
            item.realsync_ext_adj_val = shortint'(r[22:16]) - 16'sd64;
          end
        end
        // Phase D (2180..2199): Directed ICU_HALT verification across all 8 slices
        else begin
          item.icu_enable = 1'b1;
          for (int s = 0; s < NUM_SLICES; s++) begin
            if (cyc == 2180 + s) begin
              item.icu_op[s] = ICU_HALT;
            end else begin
              item.icu_op[s] = ICU_NOP;
            end
            item.east_inj_en[s] = 16'hFFFF;
            item.west_inj_en[s] = 16'hFFFF;
          end
        end

        finish_item(item);
      end
    endtask
  endclass : stream_icu_sequence
  // ---------------------------------------------------------------------------
  // 4. UVM Driver: stream_icu_driver
  // ---------------------------------------------------------------------------
  class stream_icu_driver extends uvm_driver #(stream_icu_seq_item);
    `uvm_component_utils(stream_icu_driver)

    virtual groq_stream_icu_if vif;
    int unsigned driven = 0;

    function new(string name = "stream_icu_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual groq_stream_icu_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface groq_stream_icu_if missing in stream_icu_driver")
      end
    endfunction

    task run_phase(uvm_phase phase);
      stream_icu_seq_item item;
      vif.rst_n       = 1'b0;
      vif.cycle_valid = 1'b0;
      repeat (3) @(negedge vif.clk);

      forever begin
        seq_item_port.get_next_item(item);
        vif.rst_n                = 1'b1;
        vif.cycle_id             = item.cycle_id;
        vif.icu_enable_i         = item.icu_enable;
        vif.slice_notify_ready_i = item.slice_notify_ready;
        vif.realsync_ext_adj_en_i  = item.realsync_ext_adj_en;
        vif.realsync_ext_adj_val_i = item.realsync_ext_adj_val;

        for (int s = 0; s < NUM_SLICES; s++) begin
          groq_vliw_instr_t bundle;
          bundle               = '0;
          bundle.target_slice  = 4'(s);
          bundle.icu_op        = icu_op_e'(item.icu_op[s]);
          bundle.sync_mask     = item.sync_mask[s];
          bundle.nop_delay_cnt = item.nop_cnt[s];
          bundle.imm16         = item.imm16[s];
          bundle.trace_tag     = 16'(item.cycle_id);
          vif.imem_vliw_bundle_i[s] = bundle;

          vif.east_inject_en_i[s]       = item.east_inj_en[s];
          vif.east_overwrite_allow_i[s] = item.east_ovw_en[s];
          vif.east_consume_en_i[s]      = item.east_con_en[s];
          for (int c = 0; c < NUM_EAST_STREAMS; c++) begin
            logic [63:0] d_lo, d_hi;
            d_lo = item.east_seed[s] + 64'(c);
            d_hi = item.east_seed[s] ^ (64'(c) * 64'h0101_0101_0101_0101);
            vif.east_inject_data_i[s][c] = {d_hi, d_lo};
          end

          vif.west_inject_en_i[s]       = item.west_inj_en[s];
          vif.west_overwrite_allow_i[s] = item.west_ovw_en[s];
          vif.west_consume_en_i[s]      = item.west_con_en[s];
          for (int c = 0; c < NUM_WEST_STREAMS; c++) begin
            logic [63:0] d_lo, d_hi;
            d_lo = item.west_seed[s] + 64'(c);
            d_hi = item.west_seed[s] ^ (64'(c) * 64'h0202_0202_0202_0202);
            vif.west_inject_data_i[s][c] = {d_hi, d_lo};
          end
        end

        vif.cycle_valid = 1'b1;
        @(posedge vif.clk);
        #1ns;
        vif.cycle_valid = 1'b0;
        driven++;
        @(negedge vif.clk);
        seq_item_port.item_done();
      end
    endtask
  endclass : stream_icu_driver
  // ---------------------------------------------------------------------------
  // 5. UVM Monitor: stream_icu_monitor (with Functional Covergroup)
  // ---------------------------------------------------------------------------
  class stream_icu_monitor extends uvm_monitor;
    `uvm_component_utils(stream_icu_monitor)

    virtual groq_stream_icu_if vif;
    uvm_analysis_port #(stream_icu_seq_item) ap;
    int unsigned seen = 0;

    covergroup stream_icu_cg with function sample(
      bit [3:0] icu_op,
      int       slice_id,
      bit [1:0] dir_mask,
      bit       collision_flag,
      bit [1:0] barrier_cat,
      bit       barrier_rel
    );
      option.per_instance = 1;
      cp_icu_op: coverpoint icu_op {
        bins op_nop          = {ICU_NOP};
        bins op_nop_delay    = {ICU_NOP_DELAY};
        bins op_sync_barrier = {ICU_SYNC_BARRIER};
        bins op_notify       = {ICU_NOTIFY};
        bins op_jump_imm     = {ICU_JUMP_IMM};
        bins op_realsync_adj = {ICU_REALSYNC_ADJ};
        bins op_halt         = {ICU_HALT};
      }
      cp_slice_hop: coverpoint slice_id {
        bins slice_0 = {0};
        bins slice_1 = {1};
        bins slice_2 = {2};
        bins slice_3 = {3};
        bins slice_4 = {4};
        bins slice_5 = {5};
        bins slice_6 = {6};
        bins slice_7 = {7};
      }
      cp_stream_dir: coverpoint dir_mask {
        bins dir_idle = {2'b00};
        bins dir_east = {2'b01};
        bins dir_west = {2'b10};
        bins dir_both = {2'b11};
      }
      cp_collision: coverpoint collision_flag {
        bins no_collision  = {1'b0};
        bins hit_collision = {1'b1};
      }
      cp_barrier_mask: coverpoint barrier_cat {
        bins b_none    = {2'd0};
        bins b_partial = {2'd1};
        bins b_all8    = {2'd2};
      }
      cp_barrier_rel: coverpoint barrier_rel {
        bins rel_0 = {1'b0};
        bins rel_1 = {1'b1};
      }
    endgroup

    function new(string name = "stream_icu_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
      stream_icu_cg = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual groq_stream_icu_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface groq_stream_icu_if missing in stream_icu_monitor")
      end
    endfunction

    task run_phase(uvm_phase phase);
      forever begin
        @(negedge vif.clk);
        #1ns;
        if (vif.rst_n && vif.cycle_valid) begin
          stream_icu_seq_item item = stream_icu_seq_item::type_id::create("obs_item");
          item.cycle_id             = vif.cycle_id;
          item.icu_enable           = vif.icu_enable_i;
          item.slice_notify_ready   = vif.slice_notify_ready_i;
          item.realsync_ext_adj_en  = vif.realsync_ext_adj_en_i;
          item.realsync_ext_adj_val = vif.realsync_ext_adj_val_i;

          for (int s = 0; s < NUM_SLICES; s++) begin
            bit [1:0] dir_m;
            bit [1:0] b_cat;
            item.icu_op[s]      = vif.imem_vliw_bundle_i[s][139:136];
            item.sync_mask[s]   = vif.imem_vliw_bundle_i[s][95:88];
            item.nop_cnt[s]     = vif.imem_vliw_bundle_i[s][87:72];
            item.imm16[s]       = vif.imem_vliw_bundle_i[s][31:16];

            item.east_inj_en[s] = vif.east_inject_en_i[s];
            item.east_ovw_en[s] = vif.east_overwrite_allow_i[s];
            item.east_con_en[s] = vif.east_consume_en_i[s];
            item.east_seed[s]   = vif.east_inject_data_i[s][0][63:0];

            item.west_inj_en[s] = vif.west_inject_en_i[s];
            item.west_ovw_en[s] = vif.west_overwrite_allow_i[s];
            item.west_con_en[s] = vif.west_consume_en_i[s];
            item.west_seed[s]   = vif.west_inject_data_i[s][0][63:0];

            item.act_east_valid[s]     = vif.stream_valid_east_o[s];
            item.act_collision_east[s] = vif.collision_fault_east_o[s];
            for (int c = 0; c < NUM_EAST_STREAMS; c++) begin
              item.act_east_data_lo[s][c] = vif.stream_data_east_o[s][c][63:0];
              item.act_east_data_hi[s][c] = vif.stream_data_east_o[s][c][127:64];
            end
            item.act_west_valid[s]     = vif.stream_valid_west_o[s];
            item.act_collision_west[s] = vif.collision_fault_west_o[s];
            for (int c = 0; c < NUM_WEST_STREAMS; c++) begin
              item.act_west_data_lo[s][c] = vif.stream_data_west_o[s][c][63:0];
              item.act_west_data_hi[s][c] = vif.stream_data_west_o[s][c][127:64];
            end

            item.act_pc_slice[s]  = vif.pc_slice_o[s];
            item.act_nop_timer[s] = vif.slice_nop_timer_o[s];

            dir_m = {(vif.stream_valid_west_o[s] != 16'h0000),
                     (vif.stream_valid_east_o[s] != 16'h0000)};
            if (item.sync_mask[s] == 8'h00) b_cat = 2'd0;
            else if (item.sync_mask[s] == 8'hFF) b_cat = 2'd2;
            else b_cat = 2'd1;

            stream_icu_cg.sample(
              item.icu_op[s],
              s,
              dir_m,
              vif.collision_fault_o,
              b_cat,
              vif.barrier_release_pulse_o
            );
          end

          item.act_collision_any         = vif.collision_fault_o;
          item.act_collision_sticky      = vif.collision_sticky_o;
          item.act_gated_hop_count       = vif.gated_hop_count_o;
          item.act_imem_fetch_en         = vif.imem_fetch_en_o;
          item.act_slice_vliw_valid      = vif.slice_vliw_valid_o;
          item.act_slice_halted          = vif.slice_halted_o;
          item.act_barrier_waiting       = vif.barrier_waiting_o;
          item.act_barrier_ready_mask    = vif.barrier_ready_mask_o;
          item.act_barrier_release_pulse = vif.barrier_release_pulse_o;
          item.act_barrier_release_cnt   = vif.barrier_release_cnt_o;
          item.act_realsync_cycle_cnt    = vif.realsync_cycle_cnt_o;
          item.act_realsync_deskew       = vif.realsync_deskew_offset_o;
          item.act_realsync_aligned_time = vif.realsync_aligned_time_o;
          item.act_realsync_drift_fault  = vif.realsync_drift_fault_o;

          seen++;
          ap.write(item);
        end
      end
    endtask
  endclass : stream_icu_monitor

  // ---------------------------------------------------------------------------
  // 6. UVM Scoreboard: stream_icu_scoreboard (Cycle-Accurate DPI-C Checker)
  // ---------------------------------------------------------------------------
  class stream_icu_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(stream_icu_scoreboard)

    uvm_analysis_imp #(stream_icu_seq_item, stream_icu_scoreboard) analysis_export;

    int unsigned checked_cycles       = 0;
    int unsigned mismatches           = 0;
    int unsigned stream_checks        = 0;
    int unsigned icu_checks           = 0;
    int unsigned collision_events     = 0;
    int unsigned barrier_releases     = 0;
    int unsigned realsync_drift_events= 0;

    function new(string name = "stream_icu_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      analysis_export = new("analysis_export", this);
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
      super.start_of_simulation_phase(phase);
      dpi_ref_reset();
    endfunction

    function void write(stream_icu_seq_item item);
      bit cyc_err = 1'b0;
      dpi_ref_set_global_inputs(
        int'(item.icu_enable),
        int'(item.slice_notify_ready),
        int'(item.realsync_ext_adj_en),
        int'(item.realsync_ext_adj_val)
      );
      for (int s = 0; s < NUM_SLICES; s++) begin
        dpi_ref_set_slice_inputs(
          s,
          int'(item.icu_op[s]),
          int'(item.sync_mask[s]),
          int'(item.nop_cnt[s]),
          int'(item.imm16[s]),
          int'(item.east_inj_en[s]),
          int'(item.east_ovw_en[s]),
          int'(item.east_con_en[s]),
          item.east_seed[s],
          int'(item.west_inj_en[s]),
          int'(item.west_ovw_en[s]),
          int'(item.west_con_en[s]),
          item.west_seed[s]
        );
      end
      dpi_ref_eval_comb();
      // Compare all 8 slices' East/West stream valids, 128-bit payloads, collisions,
      // PCs, NOP_DELAY timers, halted flags, and barrier wait flags
      for (int s = 0; s < NUM_SLICES; s++) begin
        int unsigned exp_ev = dpi_exp_east_valid(s);
        int unsigned exp_wv = dpi_exp_west_valid(s);
        int unsigned exp_ec = dpi_exp_collision_east(s);
        int unsigned exp_wc = dpi_exp_collision_west(s);
        int unsigned exp_pc = dpi_exp_pc_slice(s);
        int unsigned exp_nt = dpi_exp_nop_timer(s);

        stream_checks += 2;
        icu_checks    += 2;

        if (item.act_east_valid[s] !== 16'(exp_ev) ||
            item.act_west_valid[s] !== 16'(exp_wv) ||
            item.act_collision_east[s] !== 16'(exp_ec) ||
            item.act_collision_west[s] !== 16'(exp_wc)) begin
          cyc_err = 1'b1;
          `uvm_error("STREAM_MISMATCH", $sformatf(
            "cyc=%0d s=%0d ev=%04x/%04x wv=%04x/%04x ec=%04x/%04x wc=%04x/%04x",
            item.cycle_id, s, item.act_east_valid[s], exp_ev,
            item.act_west_valid[s], exp_wv, item.act_collision_east[s], exp_ec,
            item.act_collision_west[s], exp_wc))
        end

        for (int c = 0; c < NUM_EAST_STREAMS; c++) begin
          longint unsigned elo = dpi_exp_east_data_lo(s, c);
          longint unsigned ehi = dpi_exp_east_data_hi(s, c);
          longint unsigned wlo = dpi_exp_west_data_lo(s, c);
          longint unsigned whi = dpi_exp_west_data_hi(s, c);
          if (item.act_east_data_lo[s][c] !== elo || item.act_east_data_hi[s][c] !== ehi ||
              item.act_west_data_lo[s][c] !== wlo || item.act_west_data_hi[s][c] !== whi) begin
            cyc_err = 1'b1;
            `uvm_error("STREAM_DATA_MISMATCH", $sformatf(
              "cyc=%0d s=%0d c=%0d E_act=%016x_%016x E_exp=%016x_%016x W_act=%016x_%016x W_exp=%016x_%016x",
              item.cycle_id, s, c, item.act_east_data_hi[s][c], item.act_east_data_lo[s][c],
              ehi, elo, item.act_west_data_hi[s][c], item.act_west_data_lo[s][c], whi, wlo))
          end
        end

        if (item.act_pc_slice[s] !== 16'(exp_pc) || item.act_nop_timer[s] !== 16'(exp_nt)) begin
          cyc_err = 1'b1;
          `uvm_error("ICU_PC_NOP_MISMATCH", $sformatf(
            "cyc=%0d s=%0d pc=%04x/%04x nop_timer=%04x/%04x",
            item.cycle_id, s, item.act_pc_slice[s], exp_pc, item.act_nop_timer[s], exp_nt))
        end
      end

      if (item.act_collision_any !== 1'(dpi_exp_collision_any()) ||
          item.act_collision_sticky !== 1'(dpi_exp_collision_sticky()) ||
          item.act_gated_hop_count !== 16'(dpi_exp_gated_hop_count()) ||
          item.act_imem_fetch_en !== 8'(dpi_exp_imem_fetch_en()) ||
          item.act_slice_vliw_valid !== 8'(dpi_exp_slice_vliw_valid()) ||
          item.act_barrier_ready_mask !== 8'(dpi_exp_barrier_ready_mask()) ||
          item.act_barrier_release_pulse !== 1'(dpi_exp_barrier_release_pulse()) ||
          item.act_barrier_release_cnt !== 16'(dpi_exp_barrier_release_cnt()) ||
          item.act_realsync_cycle_cnt !== dpi_exp_realsync_cycle_cnt() ||
          item.act_realsync_deskew !== shortint'(dpi_exp_realsync_deskew()) ||
          item.act_realsync_aligned_time !== dpi_exp_realsync_aligned_time() ||
          item.act_realsync_drift_fault !== 1'(dpi_exp_realsync_drift_fault())) begin
        cyc_err = 1'b1;
        `uvm_error("GLOBAL_ICU_STREAM_MISMATCH", $sformatf(
          "cyc=%0d rel_pulse=%0b/%0b rel_cnt=%0d/%0d rdy_mask=%02x/%02x fetch_en=%02x/%02x aligned_t=%0d/%0d",
          item.cycle_id, item.act_barrier_release_pulse, dpi_exp_barrier_release_pulse(),
          item.act_barrier_release_cnt, dpi_exp_barrier_release_cnt(),
          item.act_barrier_ready_mask, dpi_exp_barrier_ready_mask(),
          item.act_imem_fetch_en, dpi_exp_imem_fetch_en(),
          item.act_realsync_aligned_time, dpi_exp_realsync_aligned_time()))
      end

      if (item.act_collision_any) collision_events++;
      if (item.act_barrier_release_pulse) barrier_releases++;
      if (item.act_realsync_drift_fault) realsync_drift_events++;
      if (cyc_err) mismatches++;
      checked_cycles++;

      dpi_ref_step_seq();
    endfunction
  endclass : stream_icu_scoreboard
  // ---------------------------------------------------------------------------
  // 7. UVM Environment: stream_icu_env
  // ---------------------------------------------------------------------------
  class stream_icu_env extends uvm_env;
    `uvm_component_utils(stream_icu_env)

    stream_icu_sequencer  sequencer;
    stream_icu_driver     driver;
    stream_icu_monitor    monitor;
    stream_icu_scoreboard scoreboard;

    function new(string name = "stream_icu_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer  = stream_icu_sequencer::type_id::create("sequencer", this);
      driver     = stream_icu_driver::type_id::create("driver", this);
      monitor    = stream_icu_monitor::type_id::create("monitor", this);
      scoreboard = stream_icu_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
      monitor.ap.connect(scoreboard.analysis_export);
    endfunction
  endclass : stream_icu_env

  // ---------------------------------------------------------------------------
  // 8. UVM Test: stream_icu_test
  // ---------------------------------------------------------------------------
  class stream_icu_test extends uvm_test;
    `uvm_component_utils(stream_icu_test)

    stream_icu_env env;

    function new(string name = "stream_icu_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = stream_icu_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      stream_icu_sequence seq = stream_icu_sequence::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.sequencer);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      int unsigned dpi_calls;
      real func_cov;
      bit pass_gate;
      int fd;
      super.report_phase(phase);

      dpi_calls = dpi_get_calls();
      func_cov  = env.monitor.stream_icu_cg.get_inst_coverage();
      pass_gate = (env.driver.driven >= 2000) &&
                  (env.monitor.seen == env.driver.driven) &&
                  (env.scoreboard.checked_cycles == env.driver.driven) &&
                  (dpi_calls == env.driver.driven) &&
                  (env.scoreboard.mismatches == 0) &&
                  (env.scoreboard.collision_events > 0) &&
                  (env.scoreboard.barrier_releases > 0) &&
                  (env.scoreboard.realsync_drift_events > 0) &&
                  (func_cov == 100.0);

      fd = $fopen("stream_icu_summary.json", "w");
      if (fd == 0) `uvm_fatal("JSON_OPEN", "Cannot open stream_icu_summary.json")
      $fdisplay(fd, "{");
      $fdisplay(fd, "  \"suite\": \"uvm_stream_icu\",");
      $fdisplay(fd, "  \"dut\": [\"groq_stream_fabric\", \"groq_icu_slice\"],");
      $fdisplay(fd, "  \"driven_cycles\": %0d,", env.driver.driven);
      $fdisplay(fd, "  \"observed_cycles\": %0d,", env.monitor.seen);
      $fdisplay(fd, "  \"checked_cycles\": %0d,", env.scoreboard.checked_cycles);
      $fdisplay(fd, "  \"dpi_calls\": %0d,", dpi_calls);
      $fdisplay(fd, "  \"stream_slice_checks\": %0d,", env.scoreboard.stream_checks);
      $fdisplay(fd, "  \"icu_slice_checks\": %0d,", env.scoreboard.icu_checks);
      $fdisplay(fd, "  \"collision_events\": %0d,", env.scoreboard.collision_events);
      $fdisplay(fd, "  \"barrier_releases\": %0d,", env.scoreboard.barrier_releases);
      $fdisplay(fd, "  \"realsync_drift_events\": %0d,", env.scoreboard.realsync_drift_events);
      $fdisplay(fd, "  \"mismatches\": %0d,", env.scoreboard.mismatches);
      $fdisplay(fd, "  \"functional_coverage_pct\": %0.2f,", func_cov);
      $fdisplay(fd, "  \"pass\": %0d", pass_gate);
      $fdisplay(fd, "}");
      $fclose(fd);

      dpi_set_status(pass_gate ? 0 : 1);
      if (!pass_gate) begin
        `uvm_fatal("UVM_STREAM_ICU_FAIL", $sformatf(
          "Gate failed: driven=%0d checked=%0d mismatches=%0d cov=%0.2f%%",
          env.driver.driven, env.scoreboard.checked_cycles,
          env.scoreboard.mismatches, func_cov))
      end else begin
        `uvm_info("UVM_STREAM_ICU_PASS", $sformatf(
          "PASS: %0d cycles checked via C++17 DPI-C reference, 0 mismatches, 100.00%% functional coverage",
          env.scoreboard.checked_cycles), UVM_LOW)
      end
    endfunction
  endclass : stream_icu_test

endpackage : groq_stream_icu_uvm_pkg

`endif // GROQ_STREAM_ICU_UVM_PKG_SV
