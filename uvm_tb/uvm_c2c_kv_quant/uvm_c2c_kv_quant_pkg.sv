// =============================================================================
// File: uvm_tb/uvm_c2c_kv_quant/uvm_c2c_kv_quant_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 24 Accellera IEEE 1800.2-2020 UVM Verification Package for
//              groq_c2c_kv_quant_rx_engine & Closed-Loop groq_mxfp8_nvfp4_dot_engine
// =============================================================================
`ifndef UVM_C2C_KV_QUANT_PKG_SV
`define UVM_C2C_KV_QUANT_PKG_SV

`include "uvm_macros.svh"
`include "groq_pkg.sv"

package uvm_c2c_kv_quant_pkg;
  import uvm_pkg::*;
  import groq_pkg::*;

  import "DPI-C" function void dpi_set_status(input int status);

  // ---------------------------------------------------------------------------
  // 1. UVM Sequence Item (Transaction)
  // ---------------------------------------------------------------------------
  class c2c_kv_quant_seq_item extends uvm_sequence_item;
    `uvm_object_utils(c2c_kv_quant_seq_item)

    int unsigned tx_id;
    int unsigned phase_id;

    // DUT 1 (groq_c2c_kv_quant_rx_engine) Inputs
    bit          quant_valid;
    bit [1:0]    quant_mode;
    bit [127:0]  kv_in_lo;
    bit [127:0]  kv_in_hi;
    bit [1:0]    target_sram_bank;
    bit [15:0]   target_sram_addr;

    // DUT 2 (groq_mxfp8_nvfp4_dot_engine) Streaming Query Inputs
    bit          dot_valid;
    bit [2:0]    dot_mode;
    bit          dot_zero_skip_en;
    bit          dot_accum_en;
    bit          dot_accum_clear;
    bit [7:0]    dot_wt_scale;
    bit [127:0]  dot_wt_stream;

    // Observed DUT 1 Outputs (1-Cycle Registered)
    bit          act_quant_valid;
    bit [127:0]  act_quant_vec;
    bit [7:0]    act_scale_e8m0;
    bit          act_sram_wr_en;
    bit [1:0]    act_sram_wr_bank;
    bit [15:0]   act_sram_wr_addr;
    bit [4:0]    act_zero_lanes_cnt;
    bit          act_nan_inf_clamped;
    bit [1:0]    act_comp_ratio_code;

    // Observed DUT 2 Outputs (2-Cycle Pipelined Closed-Loop)
    bit                act_dot_valid;
    bit signed [31:0]  act_unaccum_dot;
    bit signed [31:0]  act_int32_sum;
    bit [31:0]         act_fp32_sum;
    bit [5:0]          act_zero_skip_cnt;
    bit                act_block_zero_skipped;
    bit                act_nan_inf_flag;

    function new(string name = "c2c_kv_quant_seq_item");
      super.new(name);
    endfunction
  endclass : c2c_kv_quant_seq_item

  typedef uvm_sequencer #(c2c_kv_quant_seq_item) c2c_kv_quant_sequencer;

  // ---------------------------------------------------------------------------
  // 2. UVM Sequence (3,600 Cycles Directed + High-Entropy Closed-Loop Stimulus)
  // ---------------------------------------------------------------------------
  class c2c_kv_quant_sequence extends uvm_sequence #(c2c_kv_quant_seq_item);
    `uvm_object_utils(c2c_kv_quant_sequence)

    int unsigned next_tx_id = 0;

    function new(string name = "c2c_kv_quant_sequence");
      super.new(name);
    endfunction

    function automatic bit [127:0] gen_entropy_128(input int c, input int salt);
      bit [31:0] w0, w1, w2, w3;
      w0 = 32'(c * 32'h9E37_79B9 + salt * 32'h85EB_CA6B + 32'h1234_5678);
      w1 = 32'((w0 ^ (w0 >> 13)) * 32'hC2B2_AE35 ^ (c << 7));
      w2 = 32'((w1 ^ (w1 >> 15)) * 32'h27D4_EB2F ^ (salt << 11));
      w3 = 32'((w2 ^ (w2 >> 16)) * 32'h1656_67B1 ^ w0);
      return {w3, w2, w1, w0};
    endfunction

    function automatic bit [15:0] make_bf16(input bit s, input bit [7:0] e8, input bit [6:0] m7);
      return {s, e8, m7};
    endfunction

    function automatic bit [15:0] make_fp16(input bit s, input bit [4:0] e5, input bit [9:0] m10);
      return {s, e5, m10};
    endfunction

    function automatic void apply_stimulus(ref c2c_kv_quant_seq_item it, input int c);
      bit [255:0] full_kv;
      full_kv = {gen_entropy_128(c, 2), gen_entropy_128(c, 1)};

      it.quant_valid      = (c % 37 != 36);
      it.quant_mode       = 2'(c % 4);
      it.target_sram_bank = 2'(c % 4);
      it.target_sram_addr = (c == 0) ? 16'h0000 :
                            (c == 1) ? 16'hFFFF :
                            (c == 2) ? 16'hAAAA :
                            (c == 3) ? 16'h5555 :
                            (c < 20) ? (16'd1 << (c - 4)) :
                            16'((c * 257) ^ (c >> 2));

      if (c < 64) begin
        // Phase 0A: All-zero vectors & partial zero lane counts (0..16 zero lanes) across all 4 modes
        int num_zeros = (c / 4);
        it.quant_valid = 1'b1;
        it.quant_mode  = 2'(c % 4);
        for (int i = 0; i < 16; i++) begin
          bit s = i[0] ^ c[0];
          if (i < num_zeros || c >= 60) begin
            full_kv[i*16 +: 16] = {s, 15'd0};
          end else if (it.quant_mode == 2'd1) begin
            full_kv[i*16 +: 16] = make_fp16(s, 5'(10 + (i % 10)), 10'h3FF);
          end else begin
            full_kv[i*16 +: 16] = make_bf16(s, 8'(120 + i), 7'h7F);
          end
        end
      end else if (c < 192) begin
        // Phase 0B: Single-hot lanes (0..15) with alternating signs & tree comparator exercise
        int hot_lane = ((c - 64) / 4) % 16;
        bit rev_order = ((c - 64) >= 64);
        it.quant_valid = 1'b1;
        it.quant_mode  = 2'(c % 4);
        for (int i = 0; i < 16; i++) begin
          bit s = (i == hot_lane) ? c[0] : ~c[0];
          if (i == hot_lane) begin
            if (it.quant_mode == 2'd1)
              full_kv[i*16 +: 16] = make_fp16(s, 5'd24, 10'(i * 63));
            else
              full_kv[i*16 +: 16] = make_bf16(s, 8'd140, 7'(i * 9));
          end else if (rev_order) begin
            full_kv[i*16 +: 16] = {s, 15'd0};
          end else begin
            bit [7:0] e_ramp = c[1] ? 8'(100 + i) : 8'(115 - i);
            if (it.quant_mode == 2'd1)
              full_kv[i*16 +: 16] = make_fp16(s, 5'(1 + (c[1] ? i : (15 - i))), 10'h2A8);
            else
              full_kv[i*16 +: 16] = make_bf16(s, e_ramp, 7'h55);
          end
        end
      end else if (c < 1216) begin
        // Phase 1: Full-range shared exponent E_max sweep [1..254] across all 4 modes
        // Plus subnormal/underflow relative exponents (exp8 <= scale_e8m0) and NaN/Inf clamping
        int step_idx = c - 192;
        bit [7:0] target_emax = 8'(1 + (step_idx % 254));
        it.quant_valid = 1'b1;
        it.quant_mode  = 2'((step_idx / 254) % 4);
        if (it.quant_mode == 2'd1 && (step_idx % 3 == 0)) begin
          bit [4:0] fp16_e5 = 5'(1 + (step_idx % 30));
          for (int i = 0; i < 16; i++) begin
            bit s = i[0] ^ step_idx[0];
            if (i == (step_idx % 16))
              full_kv[i*16 +: 16] = make_fp16(s, fp16_e5, 10'h3FF);
            else if (i == ((step_idx + 1) % 16) && (step_idx % 5 == 0))
              full_kv[i*16 +: 16] = make_fp16(s, 5'd31, 10'h2AA);
            else if (i == ((step_idx + 2) % 16))
              full_kv[i*16 +: 16] = make_fp16(s, 5'd0, 10'h155);
            else begin
              bit [4:0] sub_e5 = (fp16_e5 > 5'(i % 9)) ? 5'(fp16_e5 - (i % 9)) : 5'd1;
              full_kv[i*16 +: 16] = make_fp16(s, sub_e5, 10'(i * 57));
            end
          end
        end else begin
          if (it.quant_mode == 2'd1) it.quant_mode = (step_idx[0]) ? 2'd0 : 2'd2;
          for (int i = 0; i < 16; i++) begin
            bit s = i[0] ^ step_idx[0];
            if (i == (step_idx % 16)) begin
              full_kv[i*16 +: 16] = make_bf16(s, target_emax, 7'h7F);
            end else if (i == ((step_idx + 3) % 16) && (step_idx % 4 == 0)) begin
              full_kv[i*16 +: 16] = make_bf16(s, 8'd255, 7'h55);
            end else if (i == ((step_idx + 5) % 16)) begin
              bit [7:0] uf_exp = (target_emax > 8'd10) ? 8'(target_emax - 8'd9) : 8'd1;
              full_kv[i*16 +: 16] = make_bf16(s, uf_exp, 7'h3F);
            end else begin
              bit [7:0] lane_e = (target_emax > 8'(i % 8)) ? 8'(target_emax - (i % 8)) : target_emax;
              full_kv[i*16 +: 16] = make_bf16(s, lane_e, 7'((i * 19 + step_idx) & 7'h7F));
            end
          end
        end
      end else if (c < 1350) begin
        // Phase 2: All-NaN/Inf vectors, Bypass High-Exponent (rel_exp >= 14), and Bit-Toggle Sweeps
        int sub = c - 1216;
        it.quant_valid = 1'b1;
        if (sub < 32) begin
          it.quant_mode = 2'(sub % 4);
          for (int i = 0; i < 16; i++) begin
            if (it.quant_mode == 2'd1)
              full_kv[i*16 +: 16] = make_fp16(i[0] ^ sub[0], 5'd31, 10'h3FF);
            else
              full_kv[i*16 +: 16] = make_bf16(i[0] ^ sub[0], 8'd255, 7'h7F);
          end
        end else if (sub < 64) begin
          it.quant_mode = 2'd3;
          for (int i = 0; i < 16; i++) begin
            full_kv[i*16 +: 16] = make_bf16(sub[0] ^ i[0], 8'(150 + i * 5), 7'(sub * 3 + i));
          end
        end else begin
          it.quant_mode = 2'(sub % 4);
          full_kv = (sub[1:0] == 2'd0) ? {8{32'hAAAA_5555}} :
                    (sub[1:0] == 2'd1) ? {8{32'h5555_AAAA}} :
                    (sub[1:0] == 2'd2) ? {8{32'hFFFF_FFFF}} : 256'd0;
        end
      end

      it.kv_in_lo = full_kv[127:0];
      it.kv_in_hi = full_kv[255:128];

      it.dot_valid        = (c % 41 != 40);
      it.dot_zero_skip_en = (c % 5 != 0);
      it.dot_accum_en     = (c % 4 != 0);
      it.dot_accum_clear  = (c % 32 == 0);
      if (c < 2400) begin
        bit [1:0] prev_qmode = 2'((c > 0 ? (c - 1) : 0) % 4);
        it.dot_mode = (prev_qmode == 2'd2) ? 3'd3 : 3'd1;
      end else begin
        it.dot_mode = 3'(c % 5);
      end
      it.dot_wt_scale  = (c % 29 == 0) ? 8'h00 : 8'(118 + (c % 20));
      it.dot_wt_stream = (c % 31 == 0) ? 128'd0 : gen_entropy_128(c, 99);
    endfunction

    task body();
      for (int c = 0; c < 3600; c++) begin
        c2c_kv_quant_seq_item it = c2c_kv_quant_seq_item::type_id::create("it");
        start_item(it);
        it.tx_id    = next_tx_id++;
        it.phase_id = (c < 192) ? 0 : (c < 1216) ? 1 : (c < 2400) ? 2 : 3;
        apply_stimulus(it, c);
        finish_item(it);
      end
    endtask
  endclass : c2c_kv_quant_sequence

  // ---------------------------------------------------------------------------
  // 3. UVM Driver, Monitor & Agent
  // ---------------------------------------------------------------------------
  class c2c_kv_quant_driver extends uvm_driver #(c2c_kv_quant_seq_item);
    `uvm_component_utils(c2c_kv_quant_driver)

    virtual c2c_kv_quant_if vif;
    int unsigned driven = 0;

    function new(string name = "c2c_kv_quant_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual c2c_kv_quant_if)::get(this, "", "vif", vif))
        `uvm_fatal("NO_VIF", "Virtual interface c2c_kv_quant_if missing in driver")
    endfunction

    task run_phase(uvm_phase phase);
      c2c_kv_quant_seq_item item;
      vif.sample_en = 1'b0;
      vif.rst_n     = 1'b0;
      @(negedge vif.clk);
      vif.rst_n     = 1'b1;
      @(negedge vif.clk);
      vif.rst_n     = 1'b0;
      repeat (2) @(negedge vif.clk);

      forever begin
        seq_item_port.get_next_item(item);
        vif.rst_n              = 1'b1;
        vif.sample_en          = 1'b1;
        vif.tx_id              = item.tx_id;
        vif.phase_id           = item.phase_id;

        vif.quant_valid_i      = item.quant_valid;
        vif.quant_mode_i       = item.quant_mode;
        vif.kv_in_lo_i         = item.kv_in_lo;
        vif.kv_in_hi_i         = item.kv_in_hi;
        vif.target_sram_bank_i = item.target_sram_bank;
        vif.target_sram_addr_i = item.target_sram_addr;

        vif.dot_valid_i        = item.dot_valid;
        vif.dot_mode_i         = item.dot_mode;
        vif.dot_zero_skip_en_i = item.dot_zero_skip_en;
        vif.dot_accum_en_i     = item.dot_accum_en;
        vif.dot_accum_clear_i  = item.dot_accum_clear;
        vif.dot_wt_scale_i     = item.dot_wt_scale;
        vif.dot_wt_stream_i    = item.dot_wt_stream;

        @(negedge vif.clk);
        vif.sample_en = 1'b0;
        driven++;
        seq_item_port.item_done();
      end
    endtask
  endclass : c2c_kv_quant_driver

  class c2c_kv_quant_monitor extends uvm_monitor;
    `uvm_component_utils(c2c_kv_quant_monitor)

    virtual c2c_kv_quant_if vif;
    uvm_analysis_port #(c2c_kv_quant_seq_item) ap;
    int unsigned seen = 0;

    function new(string name = "c2c_kv_quant_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual c2c_kv_quant_if)::get(this, "", "vif", vif))
        `uvm_fatal("NO_VIF", "Virtual interface c2c_kv_quant_if missing in monitor")
    endfunction

    task run_phase(uvm_phase phase);
      forever begin
        @(negedge vif.clk);
        #1ns;
        if (vif.rst_n && vif.sample_en) begin
          c2c_kv_quant_seq_item item = c2c_kv_quant_seq_item::type_id::create("obs_item");
          item.tx_id            = vif.tx_id;
          item.phase_id         = vif.phase_id;
          item.quant_valid      = vif.quant_valid_i;
          item.quant_mode       = vif.quant_mode_i;
          item.kv_in_lo         = vif.kv_in_lo_i;
          item.kv_in_hi         = vif.kv_in_hi_i;
          item.target_sram_bank = vif.target_sram_bank_i;
          item.target_sram_addr = vif.target_sram_addr_i;

          item.dot_valid        = vif.dot_valid_i;
          item.dot_mode         = vif.dot_mode_i;
          item.dot_zero_skip_en = vif.dot_zero_skip_en_i;
          item.dot_accum_en     = vif.dot_accum_en_i;
          item.dot_accum_clear  = vif.dot_accum_clear_i;
          item.dot_wt_scale     = vif.dot_wt_scale_i;
          item.dot_wt_stream    = vif.dot_wt_stream_i;

          @(posedge vif.clk);
          #1ps;
          item.act_quant_valid          = vif.quant_valid_o;
          item.act_quant_vec            = vif.quant_vec_o;
          item.act_scale_e8m0           = vif.scale_e8m0_o;
          item.act_sram_wr_en           = vif.sram_wr_en_o;
          item.act_sram_wr_bank         = vif.sram_wr_bank_o;
          item.act_sram_wr_addr         = vif.sram_wr_addr_o;
          item.act_zero_lanes_cnt       = vif.zero_lanes_cnt_o;
          item.act_nan_inf_clamped      = vif.nan_inf_clamped_o;
          item.act_comp_ratio_code      = vif.compression_ratio_code_o;

          item.act_dot_valid            = vif.dot_valid_o;
          item.act_unaccum_dot          = vif.unaccum_dot_o;
          item.act_int32_sum            = vif.int32_sum_o;
          item.act_fp32_sum             = vif.fp32_sum_o;
          item.act_zero_skip_cnt        = vif.zero_skip_cnt_o;
          item.act_block_zero_skipped   = vif.block_zero_skipped_o;
          item.act_nan_inf_flag         = vif.nan_inf_flag_o;

          seen++;
          ap.write(item);
        end
      end
    endtask
  endclass : c2c_kv_quant_monitor

  class c2c_kv_quant_agent extends uvm_agent;
    `uvm_component_utils(c2c_kv_quant_agent)

    c2c_kv_quant_sequencer sequencer;
    c2c_kv_quant_driver    driver;
    c2c_kv_quant_monitor   monitor;

    function new(string name = "c2c_kv_quant_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = c2c_kv_quant_sequencer::type_id::create("sequencer", this);
      driver    = c2c_kv_quant_driver::type_id::create("driver", this);
      monitor   = c2c_kv_quant_monitor::type_id::create("monitor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass : c2c_kv_quant_agent

  // ---------------------------------------------------------------------------
  // 4. UVM Functional Coverage Subscriber (uvm_subscriber)
  // ---------------------------------------------------------------------------
  class c2c_kv_quant_cov_subscriber extends uvm_subscriber #(c2c_kv_quant_seq_item);
    `uvm_component_utils(c2c_kv_quant_cov_subscriber)

    covergroup c2c_kv_quant_cg with function sample(
      bit [1:0] qmode,
      bit       qvalid,
      bit [1:0] sram_bank,
      bit [4:0] zero_cnt,
      bit       nan_clamped,
      bit [1:0] comp_ratio,
      bit [7:0] scale_e8m0,
      bit [2:0] dot_mode,
      bit       dot_accum_en,
      bit       dot_blk_zero
    );
      option.per_instance = 1;

      cp_qmode: coverpoint qmode {
        bins bf16_mxfp8 = {2'd0};
        bins fp16_mxfp8 = {2'd1};
        bins bf16_nvfp4 = {2'd2};
        bins raw_bypass = {2'd3};
      }
      cp_qvalid: coverpoint qvalid {
        bins inv = {1'b0};
        bins val = {1'b1};
      }
      cp_sram_bank: coverpoint sram_bank {
        bins bank[] = {[2'd0:2'd3]};
      }
      cp_zero_cnt: coverpoint zero_cnt {
        bins none_zero = {5'd0};
        bins one_hot   = {5'd15};
        bins partial   = {[5'd1:5'd14]};
        bins all_zero  = {5'd16};
      }
      cp_nan_clamped: coverpoint nan_clamped {
        bins clean   = {1'b0};
        bins clamped = {1'b1};
      }
      cp_comp_ratio: coverpoint comp_ratio {
        bins ratio_1x = {2'd1};
        bins ratio_2x = {2'd2};
        bins ratio_4x = {2'd3};
      }
      cp_scale_e8m0: coverpoint scale_e8m0 {
        bins zero_scale = {8'd0};
        bins sub_low    = {[8'd1:8'd63]};
        bins mid_low    = {[8'd64:8'd119]};
        bins nominal    = {[8'd120:8'd135]};
        bins mid_high   = {[8'd136:8'd199]};
        bins high_scale = {[8'd200:8'd252]};
      }
      cp_dot_mode: coverpoint dot_mode {
        bins int8_sym   = {3'd0};
        bins mxfp8_e4m3 = {3'd1};
        bins mxfp8_e5m2 = {3'd2};
        bins nvfp4_e2m1 = {3'd3};
        bins w4a8_mixed = {3'd4};
      }
      cp_dot_accum: coverpoint dot_accum_en {
        bins no_acc = {1'b0};
        bins do_acc = {1'b1};
      }
      cp_dot_blk_zero: coverpoint dot_blk_zero {
        bins active_blk  = {1'b0};
        bins skipped_blk = {1'b1};
      }
      cx_qmode_bank: cross cp_qmode, cp_sram_bank;
    endgroup

    function new(string name = "c2c_kv_quant_cov_subscriber", uvm_component parent = null);
      super.new(name, parent);
      c2c_kv_quant_cg = new();
    endfunction

    function void write(c2c_kv_quant_seq_item t);
      c2c_kv_quant_cg.sample(
        t.quant_mode, t.act_quant_valid, t.act_sram_wr_bank,
        t.act_zero_lanes_cnt, t.act_nan_inf_clamped, t.act_comp_ratio_code,
        t.act_scale_e8m0, t.dot_mode, t.dot_accum_en, t.act_block_zero_skipped
      );
    endfunction
  endclass : c2c_kv_quant_cov_subscriber

  // ---------------------------------------------------------------------------
  // 5. UVM Scoreboard with Bit-Exact Closed-Loop SystemVerilog Golden Predictor
  // ---------------------------------------------------------------------------
  class c2c_kv_quant_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(c2c_kv_quant_scoreboard)

    uvm_analysis_imp #(c2c_kv_quant_seq_item, c2c_kv_quant_scoreboard) imp;

    // Architectural Pipeline State: DUT 1 (1-cycle registered)
    bit                q_valid          = 1'b0;
    bit [127:0]        q_quant_vec      = 128'd0;
    bit [7:0]          q_scale_e8m0     = 8'd0;
    bit                q_sram_wr_en     = 1'b0;
    bit [1:0]          q_sram_wr_bank   = 2'd0;
    bit [15:0]         q_sram_wr_addr   = 16'd0;
    bit [4:0]          q_zero_lanes_cnt = 5'd0;
    bit                q_nan_inf_clamp  = 1'b0;
    bit [1:0]          q_comp_ratio     = 2'd1;

    // Architectural Pipeline State: DUT 2 Stage 1 & Stage 2 (2-cycle registered)
    bit                s1_valid_q       = 1'b0;
    bit                s1_accum_en_q    = 1'b0;
    bit                s1_accum_clear_q = 1'b0;
    bit [7:0]          s1_act_scale_q   = 8'd0;
    bit [7:0]          s1_wt_scale_q    = 8'd0;
    int signed         s1_tree_sum_q    = 32'sd0;
    bit [5:0]          s1_zero_skip_q   = 6'd0;
    bit                s1_blk_zero_q    = 1'b0;
    bit                s1_nan_inf_q     = 1'b0;

    bit                s2_valid_q       = 1'b0;
    int signed         s2_unaccum_q     = 32'sd0;
    int signed         s2_accum_q       = 32'sd0;
    bit [31:0]         s2_fp32_q        = 32'h0000_0000;
    bit [5:0]          s2_zero_skip_q   = 6'd0;
    bit                s2_blk_zero_q    = 1'b0;
    bit                s2_nan_inf_q     = 1'b0;

    int unsigned       checked_cycles       = 0;
    int unsigned       quant_checks         = 0;
    int unsigned       dot_checks           = 0;
    int unsigned       quant_mismatches     = 0;
    int unsigned       dot_mismatches       = 0;
    int unsigned       mismatches           = 0;
    int unsigned       nan_clamped_events   = 0;
    int unsigned       all_zero_vec_events  = 0;
    int unsigned       closed_loop_dots     = 0;

    function new(string name = "c2c_kv_quant_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      imp = new("imp", this);
    endfunction

    function automatic bit [3:0] fn_nvfp4_mag_2x(input bit [2:0] em);
      case (em)
        3'b000:  return 4'd0;
        3'b001:  return 4'd1;
        3'b010:  return 4'd2;
        3'b011:  return 4'd3;
        3'b100:  return 4'd4;
        3'b101:  return 4'd6;
        3'b110:  return 4'd8;
        default: return 4'd12;
      endcase
    endfunction

    function automatic void predict_kv_quant(
      input  c2c_kv_quant_seq_item item,
      output bit [127:0]           nxt_quant_vec,
      output bit [7:0]             nxt_scale_e8m0,
      output bit [4:0]             nxt_zero_cnt,
      output bit                   nxt_nan_clamp,
      output bit [1:0]             nxt_comp_ratio
    );
      bit [255:0] full_in = {item.kv_in_hi, item.kv_in_lo};
      bit         sign_l [0:15];
      bit [7:0]   exp8_l [0:15];
      bit [6:0]   frac7_l[0:15];
      bit [15:0]  is_zero_l, is_nan_l, is_fin_nz_l;
      bit [7:0]   e_max;
      bit [127:0] mxfp8_pack;
      bit [63:0]  nvfp4_pack;

      e_max = 8'd0;
      for (int i = 0; i < 16; i++) begin
        bit [15:0] r16 = full_in[i*16 +: 16];
        sign_l[i] = r16[15];
        if (item.quant_mode == 2'd1) begin
          if (r16[14:10] == 5'd0)       exp8_l[i] = 8'd0;
          else if (r16[14:10] == 5'd31) exp8_l[i] = 8'd255;
          else                          exp8_l[i] = {3'd0, r16[14:10]} + 8'd112;
          frac7_l[i] = r16[9:3];
        end else begin
          exp8_l[i]  = r16[14:7];
          frac7_l[i] = r16[6:0];
        end
        is_zero_l[i]   = (exp8_l[i] == 8'd0);
        is_nan_l[i]    = (exp8_l[i] == 8'd255);
        is_fin_nz_l[i] = (exp8_l[i] != 8'd0) && (exp8_l[i] != 8'd255);
        if (is_fin_nz_l[i] && (exp8_l[i] >= e_max)) e_max = exp8_l[i];
      end
      if (is_fin_nz_l == 16'd0) e_max = 8'd127;

      case (item.quant_mode)
        2'd0, 2'd1: nxt_scale_e8m0 = (e_max > 8'd7) ? (e_max - 8'd7) : 8'd0;
        2'd2:       nxt_scale_e8m0 = (e_max > 8'd2) ? (e_max - 8'd2) : 8'd0;
        default:    nxt_scale_e8m0 = 8'd127;
      endcase

      nxt_zero_cnt = 5'd0;
      for (int i = 0; i < 16; i++) begin
        bit [7:0] rel_e = exp8_l[i] - nxt_scale_e8m0;
        bit [7:0] mxfp8_b;
        bit [3:0] nvfp4_n;
        nxt_zero_cnt = nxt_zero_cnt + {4'd0, is_zero_l[i]};

        if (is_zero_l[i])                     mxfp8_b = {sign_l[i], 7'd0};
        else if (is_nan_l[i])                 mxfp8_b = {sign_l[i], 4'd14, 3'd7};
        else if (exp8_l[i] <= nxt_scale_e8m0) mxfp8_b = {sign_l[i], 7'd0};
        else if (rel_e >= 8'd14)              mxfp8_b = {sign_l[i], 4'd14, 3'd7};
        else                                  mxfp8_b = {sign_l[i], rel_e[3:0], frac7_l[i][6:4]};

        if (is_zero_l[i])                     nvfp4_n = {sign_l[i], 3'd0};
        else if (is_nan_l[i])                 nvfp4_n = {sign_l[i], 2'd3, 1'b1};
        else if (exp8_l[i] <= nxt_scale_e8m0) nvfp4_n = {sign_l[i], 3'd0};
        else if (rel_e >= 8'd3)               nvfp4_n = {sign_l[i], 2'd3, 1'b1};
        else                                  nvfp4_n = {sign_l[i], rel_e[1:0], frac7_l[i][6]};

        mxfp8_pack[i*8 +: 8] = mxfp8_b;
        nvfp4_pack[i*4 +: 4] = nvfp4_n;
      end

      case (item.quant_mode)
        2'd0, 2'd1: begin
          nxt_quant_vec  = mxfp8_pack;
          nxt_nan_clamp  = |is_nan_l;
          nxt_comp_ratio = 2'd2;
        end
        2'd2: begin
          nxt_quant_vec  = {nvfp4_pack, nvfp4_pack};
          nxt_nan_clamp  = |is_nan_l;
          nxt_comp_ratio = 2'd3;
        end
        default: begin
          nxt_quant_vec  = item.kv_in_lo;
          nxt_nan_clamp  = 1'b0;
          nxt_comp_ratio = 2'd1;
        end
      endcase
    endfunction

    function automatic void predict_dot_s1(
      input  c2c_kv_quant_seq_item item,
      input  bit [127:0]           act_vec,
      input  bit [7:0]             act_scale,
      output int signed            nxt_s1_tree_sum,
      output bit [5:0]             nxt_s1_zero_skip,
      output bit                   nxt_s1_blk_zero,
      output bit                   nxt_s1_nan_inf
    );
      bit signed [13:0] nvfp4_sum_s14 = 14'sd0;
      int signed        nvfp4_sum_32  = 32'sd0;
      int signed        lane16_sum_32 = 32'sd0;
      bit [31:0]        sub32_zero    = 32'd0;
      bit [15:0]        lane16_zero   = 16'd0;
      bit [15:0]        lane16_nan    = 16'd0;
      bit [5:0]         zcnt16 = 6'd0, zcnt32 = 6'd0;

      nxt_s1_blk_zero = (act_scale == 8'h00) || (item.dot_wt_scale == 8'h00);

      for (int k = 0; k < 32; k++) begin
        bit [3:0] a_n = act_vec[k*4 +: 4];
        bit [3:0] w_n = item.dot_wt_stream[k*4 +: 4];
        bit [3:0] am  = fn_nvfp4_mag_2x(a_n[2:0]);
        bit [3:0] wm  = fn_nvfp4_mag_2x(w_n[2:0]);
        bit [7:0] pm;
        int signed s_val;
        sub32_zero[k] = nxt_s1_blk_zero || (a_n[2:0] == 3'b000) || (w_n[2:0] == 3'b000);
        pm            = sub32_zero[k] ? 8'd0 : (am * wm);
        if (pm == 8'd0)            s_val = 32'sd0;
        else if (a_n[3] ^ w_n[3])  s_val = -$signed({24'd0, pm});
        else                       s_val = $signed({24'd0, pm});
        nvfp4_sum_s14 = nvfp4_sum_s14 + s_val[13:0];
        zcnt32        = zcnt32 + {5'd0, sub32_zero[k]};
      end
      nvfp4_sum_32 = $signed({{18{nvfp4_sum_s14[13]}}, nvfp4_sum_s14});

      for (int i = 0; i < 16; i++) begin
        bit [7:0] a_b = act_vec[i*8 +: 8];
        bit [7:0] w_b = item.dot_wt_stream[i*8 +: 8];
        bit [3:0] w_n = item.dot_wt_stream[i*4 +: 4];
        bit [7:0] a_iso, w_iso, sig_prod8;
        bit       a_s, w_s, p_s;
        bit [3:0] a_e4, w_e4, a_ee4, w_ee4, a_sig4, w_sig4, a_sig5, w_sig5, w_fp4_m, esh4, esh5;
        bit [4:0] a_e5, w_e5, a_ee5, w_ee5;
        bit [15:0] int8_m16;
        bit [23:0] aln_m24;
        int signed l_val;

        case (item.dot_mode)
          3'd0:    lane16_zero[i] = nxt_s1_blk_zero || (a_b == 8'h00) || (w_b == 8'h00);
          3'd4:    lane16_zero[i] = nxt_s1_blk_zero || (a_b[6:0] == 7'd0) || (w_n[2:0] == 3'd0);
          default: lane16_zero[i] = nxt_s1_blk_zero || (a_b[6:0] == 7'd0) || (w_b[6:0] == 7'd0);
        endcase
        a_iso   = (item.dot_zero_skip_en && lane16_zero[i]) ? 8'h00 : a_b;
        w_iso   = (item.dot_zero_skip_en && lane16_zero[i]) ? 8'h00 : w_b;
        a_s     = a_iso[7];
        w_s     = (item.dot_mode == 3'd4) ? w_n[3] : w_iso[7];
        p_s     = a_s ^ w_s;
        a_e4    = a_iso[6:3]; w_e4 = w_iso[6:3];
        a_ee4   = (a_e4 == 4'd0) ? 4'd1 : a_e4;
        w_ee4   = (w_e4 == 4'd0) ? 4'd1 : w_e4;
        a_sig4  = (a_e4 == 4'd0) ? {1'b0, a_iso[2:0]} : {1'b1, a_iso[2:0]};
        w_sig4  = (w_e4 == 4'd0) ? {1'b0, w_iso[2:0]} : {1'b1, w_iso[2:0]};
        esh4    = {1'b0, a_ee4[3:1]} + {1'b0, w_ee4[3:1]} + {3'd0, a_ee4[0] & w_ee4[0]};
        a_e5    = a_iso[6:2]; w_e5 = w_iso[6:2];
        a_ee5   = (a_e5 == 5'd0) ? 5'd1 : a_e5;
        w_ee5   = (w_e5 == 5'd0) ? 5'd1 : w_e5;
        a_sig5  = (a_e5 == 5'd0) ? {1'b0, a_iso[1:0], 1'b0} : {1'b1, a_iso[1:0], 1'b0};
        w_sig5  = (w_e5 == 5'd0) ? {1'b0, w_iso[1:0], 1'b0} : {1'b1, w_iso[1:0], 1'b0};
        esh5    = {1'b0, a_ee5[4:2]} + {1'b0, w_ee5[4:2]} + {3'd0, |(a_ee5[1:0] & w_ee5[1:0])};
        w_fp4_m = fn_nvfp4_mag_2x(w_n[2:0]);

        case (item.dot_mode)
          3'd1:    lane16_nan[i] = (a_b[6:0] == 7'h7F) || (w_b[6:0] == 7'h7F);
          3'd2:    lane16_nan[i] = (a_b[6:2] == 5'h1F) || (w_b[6:2] == 5'h1F);
          3'd4:    lane16_nan[i] = (a_b[6:0] == 7'h7F);
          default: lane16_nan[i] = 1'b0;
        endcase

        if (lane16_zero[i]) begin
          l_val = 32'sd0;
        end else begin
          case (item.dot_mode)
            3'd0: begin
              bit [7:0] am8 = a_s ? (-a_iso) : a_iso;
              bit [7:0] wm8 = w_s ? (-w_iso) : w_iso;
              int8_m16 = {8'd0, am8} * {8'd0, wm8};
              aln_m24  = {8'd0, int8_m16};
              l_val    = p_s ? -$signed({8'd0, aln_m24}) : $signed({8'd0, aln_m24});
            end
            3'd1: begin
              sig_prod8 = a_sig4 * w_sig4;
              aln_m24   = {16'd0, sig_prod8} << esh4;
              l_val     = p_s ? -$signed({8'd0, aln_m24}) : $signed({8'd0, aln_m24});
            end
            3'd2: begin
              sig_prod8 = a_sig5 * w_sig5;
              aln_m24   = {16'd0, sig_prod8} << esh5;
              l_val     = p_s ? -$signed({8'd0, aln_m24}) : $signed({8'd0, aln_m24});
            end
            default: begin
              sig_prod8 = a_sig4 * w_fp4_m;
              aln_m24   = {16'd0, sig_prod8} << a_ee4;
              l_val     = p_s ? -$signed({8'd0, aln_m24}) : $signed({8'd0, aln_m24});
            end
          endcase
        end
        lane16_sum_32 = lane16_sum_32 + l_val;
        zcnt16        = zcnt16 + {5'd0, lane16_zero[i]};
      end

      nxt_s1_zero_skip = (item.dot_mode == 3'd3) ? zcnt32 : zcnt16;
      nxt_s1_nan_inf   = (item.dot_mode == 3'd3 || item.dot_mode == 3'd0) ? 1'b0 : (|lane16_nan);
      nxt_s1_tree_sum  = nxt_s1_blk_zero ? 32'sd0 :
                         ((item.dot_mode == 3'd3) ? ((&sub32_zero)  ? 32'sd0 : nvfp4_sum_32) :
                                                    ((&lane16_zero) ? 32'sd0 : lane16_sum_32));
    endfunction

    function automatic void predict_dot_s2(
      output int signed nxt_s2_unaccum,
      output int signed nxt_s2_accum,
      output bit [31:0] nxt_s2_fp32
    );
      bit               s2_sign      = s1_tree_sum_q[31];
      bit [31:0]        s2_abs_mag   = s2_sign ? (~$unsigned(s1_tree_sum_q) + 32'd1) : $unsigned(s1_tree_sum_q);
      bit [8:0]         s2_scale_sum = {1'b0, s1_act_scale_q} + {1'b0, s1_wt_scale_q};
      bit [8:0]         diff_pos     = s2_scale_sum - 9'd254;
      bit [8:0]         diff_neg     = 9'd254 - s2_scale_sum;
      bit [2:0]         lsh, rsh;
      bit [38:0]        shifted_mag;
      bit [30:0]        sat_mag;
      int signed        base_acc;
      bit signed [32:0] acc_ext;
      bit [4:0]         msb_idx;
      bit [31:0]        norm_shift;
      bit [9:0]         fp32_exp_w;

      if (s2_scale_sum >= 9'd254) begin
        lsh         = (diff_pos > 9'd7) ? 3'd7 : diff_pos[2:0];
        shifted_mag = {7'd0, s2_abs_mag} << lsh;
      end else begin
        rsh         = (diff_neg > 9'd7) ? 3'd7 : diff_neg[2:0];
        shifted_mag = {7'd0, s2_abs_mag >> rsh};
      end

      if (s1_blk_zero_q || (s1_tree_sum_q == 32'sd0) || (shifted_mag == 39'd0)) begin
        sat_mag        = 31'd0;
        nxt_s2_unaccum = 32'sd0;
      end else begin
        sat_mag        = (|shifted_mag[38:31]) ? 31'h7FFF_FFFF : shifted_mag[30:0];
        nxt_s2_unaccum = s2_sign ? -$signed({1'b0, sat_mag}) : $signed({1'b0, sat_mag});
      end

      base_acc = s1_accum_clear_q ? 32'sd0 : s2_accum_q;
      acc_ext  = {base_acc[31], base_acc} + {nxt_s2_unaccum[31], nxt_s2_unaccum};
      if (!s1_accum_en_q) begin
        nxt_s2_accum = s1_accum_clear_q ? 32'sd0 : nxt_s2_unaccum;
      end else if (acc_ext[32] != acc_ext[31]) begin
        nxt_s2_accum = acc_ext[32] ? -32'sd2147483647 : 32'sd2147483647;
      end else begin
        nxt_s2_accum = acc_ext[31:0];
      end

      msb_idx = 5'd0;
      for (int b = 0; b < 31; b++) begin
        if (s2_abs_mag[b]) msb_idx = 5'(b);
      end
      norm_shift = s2_abs_mag << (5'd31 - msb_idx);
      fp32_exp_w = {1'b0, s2_scale_sum} + {5'd0, msb_idx} - 10'd127;

      if (s1_nan_inf_q)                                nxt_s2_fp32 = 32'h7FC0_0000;
      else if (s1_blk_zero_q || (s2_abs_mag == 32'd0)) nxt_s2_fp32 = 32'h0000_0000;
      else if (fp32_exp_w[9] || (fp32_exp_w == 10'd0)) nxt_s2_fp32 = {s2_sign, 31'd0};
      else if (fp32_exp_w >= 10'd255)                  nxt_s2_fp32 = {s2_sign, 8'hFF, 23'd0};
      else                                             nxt_s2_fp32 = {s2_sign, fp32_exp_w[7:0], norm_shift[30:8]};
    endfunction

    function void write(c2c_kv_quant_seq_item item);
      bit [127:0] nxt_q_vec;
      bit [7:0]   nxt_q_scale;
      bit [4:0]   nxt_q_zcnt;
      bit         nxt_q_nan;
      bit [1:0]   nxt_q_comp;

      int signed  nxt_s1_tree_sum;
      bit [5:0]   nxt_s1_zero_skip;
      bit         nxt_s1_blk_zero;
      bit         nxt_s1_nan_inf;

      int signed  nxt_s2_unaccum;
      int signed  nxt_s2_accum;
      bit [31:0]  nxt_s2_fp32;

      // 1. Evaluate Stage-2 of Dot Engine from prior Stage-1 registers (s1_*_q)
      predict_dot_s2(nxt_s2_unaccum, nxt_s2_accum, nxt_s2_fp32);

      // 2. Evaluate Stage-1 of Dot Engine from prior KV Quantizer registers (q_quant_vec, q_scale_e8m0)
      predict_dot_s1(
        item, q_quant_vec, q_scale_e8m0,
        nxt_s1_tree_sum, nxt_s1_zero_skip, nxt_s1_blk_zero, nxt_s1_nan_inf
      );

      // 3. Evaluate KV Quantizer from current cycle inputs
      predict_kv_quant(
        item, nxt_q_vec, nxt_q_scale, nxt_q_zcnt, nxt_q_nan, nxt_q_comp
      );

      // 4. Advance all pipeline registers at posedge clk
      s2_valid_q     = s1_valid_q;
      s2_unaccum_q   = nxt_s2_unaccum;
      s2_accum_q     = nxt_s2_accum;
      s2_fp32_q      = nxt_s2_fp32;
      s2_zero_skip_q = s1_zero_skip_q;
      s2_blk_zero_q  = s1_blk_zero_q;
      s2_nan_inf_q   = s1_nan_inf_q;

      s1_valid_q       = item.dot_valid;
      s1_accum_en_q    = item.dot_accum_en;
      s1_accum_clear_q = item.dot_accum_clear;
      s1_act_scale_q   = q_scale_e8m0;
      s1_wt_scale_q    = item.dot_wt_scale;
      s1_tree_sum_q    = nxt_s1_tree_sum;
      s1_zero_skip_q   = nxt_s1_zero_skip;
      s1_blk_zero_q    = nxt_s1_blk_zero;
      s1_nan_inf_q     = nxt_s1_nan_inf;

      q_valid          = item.quant_valid;
      q_quant_vec      = nxt_q_vec;
      q_scale_e8m0     = nxt_q_scale;
      q_sram_wr_en     = item.quant_valid;
      q_sram_wr_bank   = item.target_sram_bank;
      q_sram_wr_addr   = item.target_sram_addr;
      q_zero_lanes_cnt = nxt_q_zcnt;
      q_nan_inf_clamp  = nxt_q_nan;
      q_comp_ratio     = nxt_q_comp;

      checked_cycles++;
      quant_checks++;
      dot_checks++;
      if (q_nan_inf_clamp) nan_clamped_events++;
      if (q_zero_lanes_cnt == 5'd16) all_zero_vec_events++;
      if (s2_valid_q && (s2_unaccum_q != 0)) closed_loop_dots++;

      // 5. Bit-exact checks for DUT 1 (groq_c2c_kv_quant_rx_engine)
      if ((item.act_quant_valid     !== q_valid)          ||
          (item.act_quant_vec       !== q_quant_vec)      ||
          (item.act_scale_e8m0      !== q_scale_e8m0)     ||
          (item.act_sram_wr_en      !== q_sram_wr_en)     ||
          (item.act_sram_wr_bank    !== q_sram_wr_bank)   ||
          (item.act_sram_wr_addr    !== q_sram_wr_addr)   ||
          (item.act_zero_lanes_cnt  !== q_zero_lanes_cnt) ||
          (item.act_nan_inf_clamped !== q_nan_inf_clamp)  ||
          (item.act_comp_ratio_code !== q_comp_ratio)) begin
        quant_mismatches++;
        mismatches++;
        if (mismatches <= 10) begin
          `uvm_error("KV_QUANT_MISMATCH", $sformatf(
            "tx=%0d mode=%0d act_vec=%h exp_vec=%h act_scale=%h exp_scale=%h act_zcnt=%0d exp_zcnt=%0d",
            item.tx_id, item.quant_mode, item.act_quant_vec, q_quant_vec,
            item.act_scale_e8m0, q_scale_e8m0, item.act_zero_lanes_cnt, q_zero_lanes_cnt))
        end
      end

      // 6. Bit-exact checks for DUT 2 (groq_mxfp8_nvfp4_dot_engine closed-loop)
      if ((item.act_dot_valid          !== s2_valid_q)     ||
          (item.act_unaccum_dot        !== s2_unaccum_q)   ||
          (item.act_int32_sum          !== s2_accum_q)     ||
          (item.act_fp32_sum           !== s2_fp32_q)      ||
          (item.act_zero_skip_cnt      !== s2_zero_skip_q) ||
          (item.act_block_zero_skipped !== s2_blk_zero_q)  ||
          (item.act_nan_inf_flag       !== s2_nan_inf_q)) begin
        dot_mismatches++;
        mismatches++;
        if (mismatches <= 10) begin
          `uvm_error("DOT_ROUNDTRIP_MISMATCH", $sformatf(
            "tx=%0d act_fp32=%h exp_fp32=%h act_int32=%0d exp_int32=%0d act_zskip=%0d exp_zskip=%0d",
            item.tx_id, item.act_fp32_sum, s2_fp32_q, item.act_int32_sum, s2_accum_q,
            item.act_zero_skip_cnt, s2_zero_skip_q))
        end
      end
    endfunction
  endclass : c2c_kv_quant_scoreboard

  // ---------------------------------------------------------------------------
  // 6. UVM Environment & UVM Test
  // ---------------------------------------------------------------------------
  class c2c_kv_quant_env extends uvm_env;
    `uvm_component_utils(c2c_kv_quant_env)

    c2c_kv_quant_agent          agent;
    c2c_kv_quant_cov_subscriber cov_sub;
    c2c_kv_quant_scoreboard     scoreboard;

    function new(string name = "c2c_kv_quant_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = c2c_kv_quant_agent::type_id::create("agent", this);
      cov_sub    = c2c_kv_quant_cov_subscriber::type_id::create("cov_sub", this);
      scoreboard = c2c_kv_quant_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.monitor.ap.connect(cov_sub.analysis_export);
      agent.monitor.ap.connect(scoreboard.imp);
    endfunction
  endclass : c2c_kv_quant_env

  class c2c_kv_quant_test extends uvm_test;
    `uvm_component_utils(c2c_kv_quant_test)

    c2c_kv_quant_env env;

    function new(string name = "c2c_kv_quant_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = c2c_kv_quant_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      c2c_kv_quant_sequence seq = c2c_kv_quant_sequence::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.agent.sequencer);
      repeat (2) @(negedge env.agent.driver.vif.clk);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      real func_cov;
      bit  pass_gate;
      int  fd;
      super.report_phase(phase);

      func_cov  = env.cov_sub.c2c_kv_quant_cg.get_inst_coverage();
      pass_gate = (env.agent.driver.driven == 3600) &&
                  (env.agent.monitor.seen == env.agent.driver.driven) &&
                  (env.scoreboard.checked_cycles == env.agent.driver.driven) &&
                  (env.scoreboard.mismatches == 0) &&
                  (env.scoreboard.nan_clamped_events > 0) &&
                  (env.scoreboard.all_zero_vec_events > 0) &&
                  (env.scoreboard.closed_loop_dots > 0) &&
                  (func_cov == 100.0);

      fd = $fopen("c2c_kv_quant_summary.json", "w");
      if (fd == 0) `uvm_fatal("JSON_OPEN", "Cannot open c2c_kv_quant_summary.json")
      $fdisplay(fd, "{");
      $fdisplay(fd, "  \"suite\": \"uvm_c2c_kv_quant\",");
      $fdisplay(fd, "  \"dut\": [\"groq_c2c_kv_quant_rx_engine\", \"groq_mxfp8_nvfp4_dot_engine\"],");
      $fdisplay(fd, "  \"driven_cycles\": %0d,", env.agent.driver.driven);
      $fdisplay(fd, "  \"observed_cycles\": %0d,", env.agent.monitor.seen);
      $fdisplay(fd, "  \"checked_cycles\": %0d,", env.scoreboard.checked_cycles);
      $fdisplay(fd, "  \"quant_checks\": %0d,", env.scoreboard.quant_checks);
      $fdisplay(fd, "  \"dot_checks\": %0d,", env.scoreboard.dot_checks);
      $fdisplay(fd, "  \"nan_clamped_events\": %0d,", env.scoreboard.nan_clamped_events);
      $fdisplay(fd, "  \"all_zero_vec_events\": %0d,", env.scoreboard.all_zero_vec_events);
      $fdisplay(fd, "  \"closed_loop_dots\": %0d,", env.scoreboard.closed_loop_dots);
      $fdisplay(fd, "  \"quant_mismatches\": %0d,", env.scoreboard.quant_mismatches);
      $fdisplay(fd, "  \"dot_mismatches\": %0d,", env.scoreboard.dot_mismatches);
      $fdisplay(fd, "  \"mismatches\": %0d,", env.scoreboard.mismatches);
      $fdisplay(fd, "  \"functional_coverage_pct\": %0.2f,", func_cov);
      $fdisplay(fd, "  \"pass\": %0d", pass_gate);
      $fdisplay(fd, "}");
      $fclose(fd);

      dpi_set_status(pass_gate ? 0 : 1);
      if (!pass_gate) begin
        `uvm_fatal("UVM_C2C_KV_QUANT_FAIL", $sformatf(
          "Gate failed: driven=%0d checked=%0d mismatches=%0d (quant=%0d dot=%0d) cov=%0.2f%%",
          env.agent.driver.driven, env.scoreboard.checked_cycles,
          env.scoreboard.mismatches, env.scoreboard.quant_mismatches,
          env.scoreboard.dot_mismatches, func_cov))
      end else begin
        `uvm_info("UVM_C2C_KV_QUANT_PASS", $sformatf(
          "PASS: %0d transactions checked in closed-loop round-trip, 0 mismatches, 100.00%% functional coverage",
          env.scoreboard.checked_cycles), UVM_LOW)
      end
    endfunction
  endclass : c2c_kv_quant_test

endpackage : uvm_c2c_kv_quant_pkg

`endif // UVM_C2C_KV_QUANT_PKG_SV
