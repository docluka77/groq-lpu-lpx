// =============================================================================
// File: uvm_tb/uvm_mxm_sxm/groq_mxm_sxm_uvm_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Accellera IEEE 1800.2-2020 UVM Verification Package for
//              groq_mxm_slice (Matrix Execution Module) and groq_sxm_slice
//              (Switch / Transpose / Permute Execution Module).
// =============================================================================
`ifndef GROQ_MXM_SXM_UVM_PKG_SV
`define GROQ_MXM_SXM_UVM_PKG_SV

`include "uvm_macros.svh"
`include "groq_pkg.sv"

package groq_mxm_sxm_uvm_pkg;
  import uvm_pkg::*;
  import groq_pkg::*;

  // ---------------------------------------------------------------------------
  // 1. C++17 DPI-C Reference Model Imports
  // ---------------------------------------------------------------------------
  import "DPI-C" function void dpi_mxm_sxm_reset();
  import "DPI-C" function int unsigned dpi_get_calls();
  import "DPI-C" function void dpi_set_status(input int status);
  import "DPI-C" function void dpi_mxm_sxm_step(
    input  int unsigned   mxm_op_i,
    input  int unsigned   prec_mode_i,
    input  int unsigned   weight_row_idx_i,
    input  int unsigned   act_zero_gate_en_i,
    input  int unsigned   accum_clear_i,
    input  int unsigned   accum_preload_en_i,
    input  int unsigned   bg_wt_load_en_i,
    input  int unsigned   bg_wt_row_idx_i,
    input  bit [127:0]    bg_wt_data_i,
    input  int unsigned   stream_act_valid_i,
    input  bit [127:0]    stream_act_data_i,
    input  int unsigned   stream_wt_valid_i,
    input  bit [127:0]    stream_wt_data_i,
    input  bit [511:0]    accum_preload_data_i,
    input  int unsigned   sxm_op_i,
    input  int unsigned   shift_amt_i,
    input  int unsigned   src_lane_i,
    input  int unsigned   butterfly_mask_i,
    input  int unsigned   transpose_idx_i,
    input  int unsigned   rope_neg_even_en_i,
    input  int unsigned   sxm_in_valid_i,
    input  bit [127:0]    sxm_in_data_i,
    output int unsigned   exp_mxm_active_bank,
    output int unsigned   exp_zero_skip_mask,
    output int unsigned   exp_zero_skip_count,
    output int unsigned   exp_mxm_out_valid,
    output bit [127:0]    exp_mxm_stream_out,
    output bit [511:0]    exp_mxm_accum_vec,
    output int unsigned   exp_sxm_out_valid,
    output bit [127:0]    exp_sxm_out_data,
    output bit [127:0]    exp_sxm_perm_comb
  );

  // ---------------------------------------------------------------------------
  // 2. UVM Sequence Item & Sequencer
  // ---------------------------------------------------------------------------
  class mxm_sxm_seq_item extends uvm_sequence_item;
    `uvm_object_utils(mxm_sxm_seq_item)

    int unsigned tx_id;
    int unsigned phase_id;

    // MXM stimulus
    bit [3:0]    mxm_op;
    bit [3:0]    prec_mode;
    bit [3:0]    weight_row_idx;
    bit          act_zero_gate_en;
    bit          accum_clear;
    bit          accum_preload_en;
    bit          bg_wt_load_en;
    bit [3:0]    bg_wt_row_idx;
    bit [127:0]  bg_wt_data;
    bit          stream_act_valid;
    bit [127:0]  stream_act_data;
    bit          stream_wt_valid;
    bit [127:0]  stream_wt_data;
    bit [511:0]  accum_preload_data;

    // SXM stimulus
    bit [3:0]    sxm_op;
    bit [3:0]    shift_amt;
    bit [3:0]    src_lane;
    bit [3:0]    butterfly_mask;
    bit [3:0]    transpose_idx;
    bit          rope_neg_even_en;
    bit          sxm_in_valid;
    bit [127:0]  sxm_in_data;

    // Observed DUT outputs
    logic        act_mxm_active_bank;
    logic [15:0] act_zero_skip_mask;
    logic [4:0]  act_zero_skip_count;
    logic        act_mxm_out_valid;
    logic [127:0] act_mxm_stream_out;
    logic [511:0] act_mxm_accum_vec;
    logic        act_sxm_out_valid;
    logic [127:0] act_sxm_out_data;
    logic [127:0] act_sxm_perm_comb;

    function new(string name = "mxm_sxm_seq_item");
      super.new(name);
    endfunction
  endclass : mxm_sxm_seq_item

  typedef uvm_sequencer #(mxm_sxm_seq_item) mxm_sxm_sequencer;

  // ---------------------------------------------------------------------------
  // 3. Comprehensive 3,200-Transaction Stimulus Sequence
  // ---------------------------------------------------------------------------
  class mxm_sxm_sequence extends uvm_sequence #(mxm_sxm_seq_item);
    `uvm_object_utils(mxm_sxm_sequence)

    int unsigned next_id = 0;

    function new(string name = "mxm_sxm_sequence");
      super.new(name);
    endfunction

    function automatic bit [127:0] make_vec128(int unsigned seed);
      bit [127:0] v;
      for (int i = 0; i < 16; i++) begin
        bit [7:0] b = 8'((seed * 37 + i * 29 + 11) ^ (seed >> 3));
        if (b == 8'h00) b = 8'h01;
        v[i*8 +: 8] = b;
      end
      return v;
    endfunction

    function automatic bit [127:0] make_zskip_vec(int unsigned zero_lanes, bit [3:0] mode, int unsigned seed);
      bit [127:0] v = make_vec128(seed);
      if ((mode == PREC_FP16) || (mode == PREC_BF16)) begin
        int pairs_to_zero = zero_lanes / 2;
        for (int k = 0; k < 8; k++) begin
          if (k < pairs_to_zero) begin
            v[(2*k)*8 +: 16] = 16'h0000;
          end else if ((k == pairs_to_zero) && (seed[0] == 1'b1)) begin
            // Directed half-zero 16b operand (low byte 0, high byte non-zero) for BUG-MXM-001
            v[(2*k)*8 +: 8]   = 8'h00;
            v[(2*k+1)*8 +: 8] = 8'h03;
          end
        end
      end else begin
        for (int r = 0; r < 16; r++) begin
          if (r < zero_lanes) begin
            if (((mode == PREC_FP8_E4M3) || (mode == PREC_FP8_E5M2)) && (r[0] == 1'b1))
              v[r*8 +: 8] = 8'h80; // FP8 negative zero (-0.0)
            else
              v[r*8 +: 8] = 8'h00;
          end
        end
      end
      return v;
    endfunction

    task body();
      mxm_sxm_seq_item item;
      bit [3:0] prec_list[5] = '{PREC_INT8, PREC_FP8_E4M3, PREC_FP8_E5M2, PREC_FP16, PREC_BF16};
      bit [3:0] sxm_list[13] = '{
        SXM_NOP, SXM_PASSTHROUGH, SXM_BARREL_ROTATE, SXM_TRANSPOSE_4X4,
        SXM_BIT_REVERSE, SXM_BROADCAST_LANE, SXM_INTERLEAVE, SXM_ROTATE_LEFT,
        SXM_ROTATE_RIGHT, SXM_REVERSE, SXM_TRANSPOSE_LOAD, SXM_TRANSPOSE_READ,
        SXM_BUTTERFLY_SWAP
      };

      // Phase 0 (64 cycles): Dual Ping-Pong Weight Bank Initialization + SXM 16x16 Transpose Load/Read
      for (int i = 0; i < 64; i++) begin
        item = mxm_sxm_seq_item::type_id::create("item");
        start_item(item);
        item.tx_id              = next_id++;
        item.phase_id           = 0;
        item.prec_mode          = PREC_INT8;
        item.weight_row_idx     = 4'(i & 15);
        item.act_zero_gate_en   = 1'b0;
        item.accum_clear        = (i == 32);
        item.accum_preload_en   = (i == 33);
        item.bg_wt_load_en      = (i >= 36 && i < 52);
        item.bg_wt_row_idx      = 4'((i - 36) & 15);
        item.bg_wt_data         = make_vec128(i + 200);
        item.stream_act_valid   = 1'b1;
        item.stream_act_data    = make_vec128(i + 10);
        item.stream_wt_valid    = 1'b1;
        item.stream_wt_data     = make_vec128(i + 100);
        item.accum_preload_data = {16{32'h0000_0100 + i}};

        if (i < 16)       item.mxm_op = MXM_LOAD_WEIGHT_B0;
        else if (i < 32)  item.mxm_op = MXM_LOAD_WEIGHT_B1;
        else if (i == 32) item.mxm_op = MXM_ACCUM_CLEAR;
        else if (i == 33) item.mxm_op = MXM_ACCUM_PRELOAD;
        else if (i == 34) item.mxm_op = MXM_SWAP_WEIGHT;
        else if (i == 35) item.mxm_op = MXM_ACCUM_FLUSH;
        else if (i == 52) item.mxm_op = MXM_SWAP_WEIGHT;
        else              item.mxm_op = MXM_SYSTOLIC_EXEC;

        item.sxm_op           = (i < 16) ? SXM_TRANSPOSE_LOAD :
                                (i < 32) ? SXM_TRANSPOSE_READ : SXM_PASSTHROUGH;
        item.shift_amt        = 4'(i & 15);
        item.src_lane         = 4'(i & 15);
        item.butterfly_mask   = 4'(i & 15);
        item.transpose_idx    = 4'(i & 15);
        item.rope_neg_even_en = i[0];
        item.sxm_in_valid     = 1'b1;
        item.sxm_in_data      = make_vec128(i + 300);
        finish_item(item);
      end

      // Phase 1 (510 cycles): Multi-Precision MXM Sweep x Zero-Skip Counts (0..16) x Gate En x Bank Swap
      for (int p = 0; p < 5; p++) begin
        for (int z = 0; z <= 16; z++) begin
          for (int g = 0; g < 2; g++) begin
            for (int b = 0; b < 3; b++) begin
              int idx = ((p * 17 + z) * 2 + g) * 3 + b;
              item = mxm_sxm_seq_item::type_id::create("item");
              start_item(item);
              item.tx_id              = next_id++;
              item.phase_id           = 1;
              item.mxm_op             = (b == 2 && (z & 3) == 0) ? MXM_SWAP_WEIGHT : MXM_SYSTOLIC_EXEC;
              item.prec_mode          = prec_list[p];
              item.weight_row_idx     = 4'(idx & 15);
              item.act_zero_gate_en   = g[0];
              item.accum_clear        = (z == 0 && g == 0 && b == 0);
              item.accum_preload_en   = (z == 8 && g == 1 && b == 2);
              item.bg_wt_load_en      = b[0];
              item.bg_wt_row_idx      = 4'((idx + 5) & 15);
              item.bg_wt_data         = make_vec128(idx + 500);
              item.stream_act_valid   = 1'b1;
              item.stream_act_data    = make_zskip_vec(z, prec_list[p], idx + 700);
              item.stream_wt_valid    = b[1];
              item.stream_wt_data     = make_vec128(idx + 900);
              item.accum_preload_data = {16{32'h0001_0000 ^ idx}};

              item.sxm_op             = sxm_list[idx % 13];
              item.shift_amt          = 4'(idx & 15);
              item.src_lane           = 4'((idx >> 1) & 15);
              item.butterfly_mask     = 4'((idx >> 2) & 15);
              item.transpose_idx      = 4'(idx & 15);
              item.rope_neg_even_en   = b[0];
              item.sxm_in_valid       = 1'b1;
              item.sxm_in_data        = make_vec128(idx + 1100);
              finish_item(item);
            end
          end
        end
      end

      // Phase 2 (416 cycles): Exhaustive SXM Opcode (13) x Shift/Lane/Mask/TransposeIdx (16) x RoPE (2)
      for (int op_idx = 0; op_idx < 13; op_idx++) begin
        for (int sh = 0; sh < 16; sh++) begin
          for (int rp = 0; rp < 2; rp++) begin
            int idx = (op_idx * 16 + sh) * 2 + rp;
            item = mxm_sxm_seq_item::type_id::create("item");
            start_item(item);
            item.tx_id              = next_id++;
            item.phase_id           = 2;
            item.mxm_op             = (idx % 8 == 0) ? MXM_NOP :
                                      (idx % 8 == 1) ? MXM_LOAD_WEIGHT_B0 :
                                      (idx % 8 == 2) ? MXM_LOAD_WEIGHT_B1 :
                                      (idx % 8 == 3) ? MXM_SWAP_WEIGHT :
                                      (idx % 8 == 5) ? MXM_ACCUM_FLUSH :
                                      (idx % 8 == 6) ? MXM_ACCUM_CLEAR :
                                      (idx % 8 == 7) ? MXM_ACCUM_PRELOAD : MXM_SYSTOLIC_EXEC;
            item.prec_mode          = prec_list[idx % 5];
            item.weight_row_idx     = 4'(sh);
            item.act_zero_gate_en   = rp[0];
            item.accum_clear        = 1'b0;
            item.accum_preload_en   = 1'b0;
            item.bg_wt_load_en      = rp[0];
            item.bg_wt_row_idx      = 4'(15 - sh);
            item.bg_wt_data         = make_vec128(idx + 2000);
            item.stream_act_valid   = 1'b1;
            item.stream_act_data    = make_zskip_vec(sh, prec_list[idx % 5], idx + 2100);
            item.stream_wt_valid    = rp[0];
            item.stream_wt_data     = make_vec128(idx + 2200);
            item.accum_preload_data = {16{32'hA5A5_0000 + idx}};

            item.sxm_op             = sxm_list[op_idx];
            item.shift_amt          = 4'(sh);
            item.src_lane           = 4'(sh);
            item.butterfly_mask     = 4'(sh);
            item.transpose_idx      = 4'(sh);
            item.rope_neg_even_en   = rp[0];
            item.sxm_in_valid       = 1'b1;
            item.sxm_in_data        = (rp == 0) ? ~make_vec128(idx + 2300) : make_vec128(idx + 2300);
            finish_item(item);
          end
        end
      end

      // Phase 3 (2,210 cycles -> Total = 3,200 transactions): High-Entropy Full-Toggle Stress
      for (int k = 0; k < 2210; k++) begin
        bit [127:0] toggle_pat = (k[0]) ? {4{32'hAAAA_5555 ^ (k * 32'h0101_0101)}}
                                        : {4{32'h5555_AAAA ^ (k * 32'h1020_3040)}};
        item = mxm_sxm_seq_item::type_id::create("item");
        start_item(item);
        item.tx_id              = next_id++;
        item.phase_id           = 3;
        item.mxm_op             = (k % 19 == 0) ? MXM_SWAP_WEIGHT :
                                  (k % 23 == 0) ? MXM_LOAD_WEIGHT_B0 :
                                  (k % 29 == 0) ? MXM_LOAD_WEIGHT_B1 :
                                  (k % 31 == 0) ? MXM_ACCUM_CLEAR :
                                  (k % 37 == 0) ? MXM_ACCUM_PRELOAD : MXM_SYSTOLIC_EXEC;
        item.prec_mode          = prec_list[k % 5];
        item.weight_row_idx     = 4'(k & 15);
        item.act_zero_gate_en   = k[0];
        item.accum_clear        = (k % 97 == 0);
        item.accum_preload_en   = (k % 89 == 0);
        item.bg_wt_load_en      = k[1];
        item.bg_wt_row_idx      = 4'((k >> 2) & 15);
        item.bg_wt_data         = toggle_pat ^ make_vec128(k + 4000);
        item.stream_act_valid   = (k % 41 != 0);
        item.stream_act_data    = (k % 3 == 0) ? make_zskip_vec(k % 17, prec_list[k % 5], k + 5000) : toggle_pat;
        item.stream_wt_valid    = k[2];
        item.stream_wt_data     = ~toggle_pat;
        item.accum_preload_data = {16{toggle_pat[31:0]}};

        item.sxm_op             = sxm_list[(k % 12) + 1];
        item.shift_amt          = 4'(k & 15);
        item.src_lane           = 4'((k >> 1) & 15);
        item.butterfly_mask     = 4'((k >> 2) & 15);
        item.transpose_idx      = 4'((k >> 3) & 15);
        item.rope_neg_even_en   = k[0];
        item.sxm_in_valid       = (k % 43 != 0);
        item.sxm_in_data        = toggle_pat;
        finish_item(item);
      end
    endtask
  endclass : mxm_sxm_sequence

  // ---------------------------------------------------------------------------
  // 4. UVM Driver
  // ---------------------------------------------------------------------------
  class mxm_sxm_driver extends uvm_driver #(mxm_sxm_seq_item);
    `uvm_component_utils(mxm_sxm_driver)

    virtual groq_mxm_sxm_if vif;
    int unsigned driven = 0;

    function new(string name = "mxm_sxm_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual groq_mxm_sxm_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface groq_mxm_sxm_if missing in mxm_sxm_driver")
      end
    endfunction

    task run_phase(uvm_phase phase);
      mxm_sxm_seq_item item;
      vif.rst_n     = 1'b0;
      vif.sample_en = 1'b0;
      repeat (4) @(negedge vif.clk);

      forever begin
        seq_item_port.get_next_item(item);
        vif.rst_n                = 1'b1;
        vif.sample_en            = 1'b1;
        vif.tx_id                = item.tx_id;
        vif.phase_id             = item.phase_id;
        vif.mxm_op_i             = item.mxm_op;
        vif.prec_mode_i          = item.prec_mode;
        vif.weight_row_idx_i     = item.weight_row_idx;
        vif.act_zero_gate_en_i   = item.act_zero_gate_en;
        vif.accum_clear_i        = item.accum_clear;
        vif.accum_preload_en_i   = item.accum_preload_en;
        vif.bg_wt_load_en_i      = item.bg_wt_load_en;
        vif.bg_wt_row_idx_i      = item.bg_wt_row_idx;
        vif.bg_wt_data_i         = item.bg_wt_data;
        vif.stream_act_valid_i   = item.stream_act_valid;
        vif.stream_act_data_i    = item.stream_act_data;
        vif.stream_wt_valid_i    = item.stream_wt_valid;
        vif.stream_wt_data_i     = item.stream_wt_data;
        vif.accum_preload_data_i = item.accum_preload_data;

        vif.sxm_op_i             = item.sxm_op;
        vif.shift_amt_i          = item.shift_amt;
        vif.src_lane_i           = item.src_lane;
        vif.butterfly_mask_i     = item.butterfly_mask;
        vif.transpose_idx_i      = item.transpose_idx;
        vif.rope_neg_even_en_i   = item.rope_neg_even_en;
        vif.sxm_in_valid_i       = item.sxm_in_valid;
        vif.sxm_in_data_i        = item.sxm_in_data;

        @(negedge vif.clk);
        vif.sample_en            = 1'b0;
        driven++;
        seq_item_port.item_done();
      end
    endtask
  endclass : mxm_sxm_driver

  // ---------------------------------------------------------------------------
  // 5. UVM Monitor & Functional Covergroup
  // ---------------------------------------------------------------------------
  class mxm_sxm_monitor extends uvm_monitor;
    `uvm_component_utils(mxm_sxm_monitor)

    virtual groq_mxm_sxm_if vif;
    uvm_analysis_port #(mxm_sxm_seq_item) ap;
    int unsigned seen = 0;

    covergroup mxm_sxm_cg with function sample(
      bit [3:0] mxm_op,
      bit [3:0] prec_mode,
      bit       active_bank,
      bit       bg_preload,
      bit       zero_gate,
      bit [4:0] zero_skip_cnt,
      bit [3:0] sxm_op,
      bit [3:0] sxm_shamt,
      bit       rope_neg
    );
      option.per_instance = 1;
      cp_mxm_op: coverpoint mxm_op {
        bins op_nop        = {MXM_NOP};
        bins op_load_b0    = {MXM_LOAD_WEIGHT_B0};
        bins op_load_b1    = {MXM_LOAD_WEIGHT_B1};
        bins op_swap       = {MXM_SWAP_WEIGHT};
        bins op_exec       = {MXM_SYSTOLIC_EXEC};
        bins op_flush      = {MXM_ACCUM_FLUSH};
        bins op_clear      = {MXM_ACCUM_CLEAR};
        bins op_preload    = {MXM_ACCUM_PRELOAD};
      }
      cp_prec_mode: coverpoint prec_mode {
        bins m_int8     = {PREC_INT8};
        bins m_fp8_e4m3 = {PREC_FP8_E4M3};
        bins m_fp8_e5m2 = {PREC_FP8_E5M2};
        bins m_fp16     = {PREC_FP16};
        bins m_bf16     = {PREC_BF16};
      }
      cp_active_bank: coverpoint active_bank {
        bins bank0 = {1'b0};
        bins bank1 = {1'b1};
      }
      cp_bg_preload: coverpoint bg_preload {
        bins bg_off = {1'b0};
        bins bg_on  = {1'b1};
      }
      cp_zero_gate: coverpoint zero_gate {
        bins gate_off = {1'b0};
        bins gate_on  = {1'b1};
      }
      cp_zero_skip_cnt: coverpoint zero_skip_cnt {
        bins z_0    = {5'd0};
        bins z_low  = {[5'd1:5'd7]};
        bins z_mid  = {5'd8};
        bins z_high = {[5'd9:5'd15]};
        bins z_all  = {5'd16};
      }
      cp_sxm_op: coverpoint sxm_op {
        bins s_nop      = {SXM_NOP};
        bins s_pass     = {SXM_PASSTHROUGH};
        bins s_brotate  = {SXM_BARREL_ROTATE};
        bins s_t4x4     = {SXM_TRANSPOSE_4X4};
        bins s_bitrev   = {SXM_BIT_REVERSE};
        bins s_bcast    = {SXM_BROADCAST_LANE};
        bins s_interlv  = {SXM_INTERLEAVE};
        bins s_rot_l    = {SXM_ROTATE_LEFT};
        bins s_rot_r    = {SXM_ROTATE_RIGHT};
        bins s_rev      = {SXM_REVERSE};
        bins s_tload    = {SXM_TRANSPOSE_LOAD};
        bins s_tread    = {SXM_TRANSPOSE_READ};
        bins s_bfly     = {SXM_BUTTERFLY_SWAP};
      }
      cp_sxm_shamt: coverpoint sxm_shamt {
        bins sh_all[] = {[4'd0:4'd15]};
      }
      cp_rope_neg: coverpoint rope_neg {
        bins rp_off = {1'b0};
        bins rp_on  = {1'b1};
      }
    endgroup

    function new(string name = "mxm_sxm_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
      mxm_sxm_cg = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual groq_mxm_sxm_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("NO_VIF", "Virtual interface groq_mxm_sxm_if missing in mxm_sxm_monitor")
      end
    endfunction

    task run_phase(uvm_phase phase);
      forever begin
        @(posedge vif.clk);
        #1ps;
        if (vif.rst_n && vif.sample_en) begin
          mxm_sxm_seq_item item = mxm_sxm_seq_item::type_id::create("obs_item");
          item.tx_id               = vif.tx_id;
          item.phase_id            = vif.phase_id;
          item.mxm_op              = vif.mxm_op_i;
          item.prec_mode           = vif.prec_mode_i;
          item.weight_row_idx      = vif.weight_row_idx_i;
          item.act_zero_gate_en    = vif.act_zero_gate_en_i;
          item.accum_clear         = vif.accum_clear_i;
          item.accum_preload_en    = vif.accum_preload_en_i;
          item.bg_wt_load_en       = vif.bg_wt_load_en_i;
          item.bg_wt_row_idx       = vif.bg_wt_row_idx_i;
          item.bg_wt_data          = vif.bg_wt_data_i;
          item.stream_act_valid    = vif.stream_act_valid_i;
          item.stream_act_data     = vif.stream_act_data_i;
          item.stream_wt_valid     = vif.stream_wt_valid_i;
          item.stream_wt_data      = vif.stream_wt_data_i;
          item.accum_preload_data  = vif.accum_preload_data_i;

          item.sxm_op              = vif.sxm_op_i;
          item.shift_amt           = vif.shift_amt_i;
          item.src_lane            = vif.src_lane_i;
          item.butterfly_mask      = vif.butterfly_mask_i;
          item.transpose_idx       = vif.transpose_idx_i;
          item.rope_neg_even_en    = vif.rope_neg_even_en_i;
          item.sxm_in_valid        = vif.sxm_in_valid_i;
          item.sxm_in_data         = vif.sxm_in_data_i;

          item.act_mxm_active_bank = vif.mxm_active_bank_o;
          item.act_zero_skip_mask  = vif.mxm_zero_skip_mask_o;
          item.act_zero_skip_count = vif.mxm_zero_skip_count_o;
          item.act_mxm_out_valid   = vif.mxm_out_valid_o;
          item.act_mxm_stream_out  = vif.mxm_stream_out_data_o;
          item.act_mxm_accum_vec   = vif.mxm_accum_vec_o;
          item.act_sxm_out_valid   = vif.sxm_out_valid_o;
          item.act_sxm_out_data    = vif.sxm_out_data_o;
          item.act_sxm_perm_comb   = vif.sxm_perm_comb_o;

          mxm_sxm_cg.sample(
            item.mxm_op,
            item.prec_mode,
            bit'(item.act_mxm_active_bank),
            item.bg_wt_load_en,
            item.act_zero_gate_en,
            5'(item.act_zero_skip_count),
            item.sxm_op,
            item.shift_amt,
            item.rope_neg_even_en
          );
          seen++;
          ap.write(item);
        end
      end
    endtask
  endclass : mxm_sxm_monitor

  // ---------------------------------------------------------------------------
  // 6. UVM Scoreboard with C++17 DPI-C Bit-Exact Reference Check
  // ---------------------------------------------------------------------------
  class mxm_sxm_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(mxm_sxm_scoreboard)

    uvm_analysis_imp #(mxm_sxm_seq_item, mxm_sxm_scoreboard) imp;
    int unsigned checked_cycles = 0;
    int unsigned mxm_checks     = 0;
    int unsigned sxm_checks     = 0;
    int unsigned zskip_events   = 0;
    int unsigned bank_swaps     = 0;
    int unsigned mismatches     = 0;

    function new(string name = "mxm_sxm_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      imp = new("imp", this);
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
      super.start_of_simulation_phase(phase);
      dpi_mxm_sxm_reset();
    endfunction

    function void write(mxm_sxm_seq_item item);
      int unsigned exp_active_bank;
      int unsigned exp_zmask;
      int unsigned exp_zcnt;
      int unsigned exp_mxm_valid;
      bit [127:0]  exp_mxm_stream_out;
      bit [511:0]  exp_mxm_accum_vec;
      int unsigned exp_sxm_valid;
      bit [127:0]  exp_sxm_out_data;
      bit [127:0]  exp_sxm_perm_comb;

      dpi_mxm_sxm_step(
        int'(item.mxm_op),
        int'(item.prec_mode),
        int'(item.weight_row_idx),
        int'(item.act_zero_gate_en),
        int'(item.accum_clear),
        int'(item.accum_preload_en),
        int'(item.bg_wt_load_en),
        int'(item.bg_wt_row_idx),
        item.bg_wt_data,
        int'(item.stream_act_valid),
        item.stream_act_data,
        int'(item.stream_wt_valid),
        item.stream_wt_data,
        item.accum_preload_data,
        int'(item.sxm_op),
        int'(item.shift_amt),
        int'(item.src_lane),
        int'(item.butterfly_mask),
        int'(item.transpose_idx),
        int'(item.rope_neg_even_en),
        int'(item.sxm_in_valid),
        item.sxm_in_data,
        exp_active_bank,
        exp_zmask,
        exp_zcnt,
        exp_mxm_valid,
        exp_mxm_stream_out,
        exp_mxm_accum_vec,
        exp_sxm_valid,
        exp_sxm_out_data,
        exp_sxm_perm_comb
      );

      checked_cycles++;
      mxm_checks++;
      sxm_checks++;
      if (exp_zcnt > 0) zskip_events++;
      if (item.mxm_op == MXM_SWAP_WEIGHT) bank_swaps++;

      if ((item.act_mxm_active_bank !== 1'(exp_active_bank)) ||
          (item.act_zero_skip_mask  !== 16'(exp_zmask)) ||
          (item.act_zero_skip_count !== 5'(exp_zcnt)) ||
          (item.act_mxm_out_valid   !== 1'(exp_mxm_valid)) ||
          (item.act_mxm_stream_out  !== exp_mxm_stream_out) ||
          (item.act_mxm_accum_vec   !== exp_mxm_accum_vec)) begin
        mismatches++;
        `uvm_error("MXM_MISMATCH", $sformatf(
          "tx=%0d op=%0d mode=%0d exp_accum[31:0]=%08x act_accum[31:0]=%08x exp_zcnt=%0d act_zcnt=%0d",
          item.tx_id, item.mxm_op, item.prec_mode,
          exp_mxm_accum_vec[31:0], item.act_mxm_accum_vec[31:0],
          exp_zcnt, item.act_zero_skip_count))
      end

      if ((item.act_sxm_out_valid !== 1'(exp_sxm_valid)) ||
          (item.act_sxm_out_data  !== exp_sxm_out_data) ||
          (item.act_sxm_perm_comb !== exp_sxm_perm_comb)) begin
        mismatches++;
        `uvm_error("SXM_MISMATCH", $sformatf(
          "tx=%0d sxm_op=%0d sh=%0d exp_out=%032x act_out=%032x",
          item.tx_id, item.sxm_op, item.shift_amt,
          exp_sxm_out_data, item.act_sxm_out_data))
      end
    endfunction
  endclass : mxm_sxm_scoreboard

  // ---------------------------------------------------------------------------
  // 7. UVM Environment & Top-Level Test
  // ---------------------------------------------------------------------------
  class mxm_sxm_env extends uvm_env;
    `uvm_component_utils(mxm_sxm_env)

    mxm_sxm_sequencer  sequencer;
    mxm_sxm_driver     driver;
    mxm_sxm_monitor    monitor;
    mxm_sxm_scoreboard scoreboard;

    function new(string name = "mxm_sxm_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer  = mxm_sxm_sequencer::type_id::create("sequencer", this);
      driver     = mxm_sxm_driver::type_id::create("driver", this);
      monitor    = mxm_sxm_monitor::type_id::create("monitor", this);
      scoreboard = mxm_sxm_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
      monitor.ap.connect(scoreboard.imp);
    endfunction
  endclass : mxm_sxm_env

  class mxm_sxm_test extends uvm_test;
    `uvm_component_utils(mxm_sxm_test)

    mxm_sxm_env env;

    function new(string name = "mxm_sxm_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = mxm_sxm_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      mxm_sxm_sequence seq = mxm_sxm_sequence::type_id::create("seq");
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
      func_cov  = env.monitor.mxm_sxm_cg.get_inst_coverage();
      pass_gate = (env.driver.driven >= 3000) &&
                  (env.monitor.seen == env.driver.driven) &&
                  (env.scoreboard.checked_cycles == env.driver.driven) &&
                  (dpi_calls == env.driver.driven) &&
                  (env.scoreboard.mismatches == 0) &&
                  (env.scoreboard.zskip_events > 0) &&
                  (env.scoreboard.bank_swaps > 0) &&
                  (func_cov == 100.0);

      fd = $fopen("mxm_sxm_summary.json", "w");
      if (fd == 0) `uvm_fatal("JSON_OPEN", "Cannot open mxm_sxm_summary.json")
      $fdisplay(fd, "{");
      $fdisplay(fd, "  \"suite\": \"uvm_mxm_sxm\",");
      $fdisplay(fd, "  \"dut\": [\"groq_mxm_slice\", \"groq_sxm_slice\"],");
      $fdisplay(fd, "  \"driven_cycles\": %0d,", env.driver.driven);
      $fdisplay(fd, "  \"observed_cycles\": %0d,", env.monitor.seen);
      $fdisplay(fd, "  \"checked_cycles\": %0d,", env.scoreboard.checked_cycles);
      $fdisplay(fd, "  \"dpi_calls\": %0d,", dpi_calls);
      $fdisplay(fd, "  \"mxm_slice_checks\": %0d,", env.scoreboard.mxm_checks);
      $fdisplay(fd, "  \"sxm_slice_checks\": %0d,", env.scoreboard.sxm_checks);
      $fdisplay(fd, "  \"zero_skip_events\": %0d,", env.scoreboard.zskip_events);
      $fdisplay(fd, "  \"ping_pong_swaps\": %0d,", env.scoreboard.bank_swaps);
      $fdisplay(fd, "  \"mismatches\": %0d,", env.scoreboard.mismatches);
      $fdisplay(fd, "  \"functional_coverage_pct\": %0.2f,", func_cov);
      $fdisplay(fd, "  \"pass\": %0d", pass_gate);
      $fdisplay(fd, "}");
      $fclose(fd);

      dpi_set_status(pass_gate ? 0 : 1);
      if (!pass_gate) begin
        `uvm_fatal("UVM_MXM_SXM_FAIL", $sformatf(
          "Gate failed: driven=%0d checked=%0d mismatches=%0d cov=%0.2f%%",
          env.driver.driven, env.scoreboard.checked_cycles,
          env.scoreboard.mismatches, func_cov))
      end else begin
        `uvm_info("UVM_MXM_SXM_PASS", $sformatf(
          "PASS: %0d transactions checked via C++17 DPI-C reference, 0 mismatches, 100.00%% functional coverage",
          env.scoreboard.checked_cycles), UVM_LOW)
      end
    endfunction
  endclass : mxm_sxm_test

endpackage : groq_mxm_sxm_uvm_pkg

`endif // GROQ_MXM_SXM_UVM_PKG_SV
