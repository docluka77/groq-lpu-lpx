// =============================================================================
// File: uvm_tb/uvm_full_chip/groq_full_chip_uvm_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Accellera IEEE 1800.2-2020 Full-Chip & 2-Chip Cluster UVM Package
//              verifying groq_lpu_cluster_top (2 x groq_lpu_top + Dragonfly C2C)
//              across 3,000+ cycles of multi-slice VLIW spatial execution.
// =============================================================================
`ifndef GROQ_FULL_CHIP_UVM_PKG_SV
`define GROQ_FULL_CHIP_UVM_PKG_SV

`include "uvm_macros.svh"
`include "groq_pkg.sv"

package groq_full_chip_uvm_pkg;
  import uvm_pkg::*;
  import groq_pkg::*;

  // ---------------------------------------------------------------------------
  // DPI-C Golden Reference Model Imports
  // ---------------------------------------------------------------------------
  import "DPI-C" function void dpi_full_chip_reset();
  import "DPI-C" function void dpi_ref_dma_write(
    input int chip, input int is_east, input int bank, input int addr,
    input bit [127:0] data128
  );
  import "DPI-C" function void dpi_ref_load_mxm_weight(
    input int chip, input int is_east, input int row,
    input bit [127:0] data128
  );
  import "DPI-C" function void dpi_ref_clear_mxm_accum(
    input int chip, input int is_east
  );
  import "DPI-C" function int dpi_ref_check_pipeline(
    input int chip, input int w_bank, input int w_addr,
    input int sxm_op, input int sxm_shift, input int bfly_mask,
    input int vxm_op,
    input int e_bank, input int e_addr,
    input bit [127:0] rtl_sxm_out,
    input bit [127:0] rtl_vxm_out,
    input bit [127:0] rtl_mxm_w_out,
    input bit [127:0] rtl_mxm_e_out,
    input int rtl_ecc_single_err, input int exp_ecc_single_err
  );
  import "DPI-C" function int dpi_ref_check_e_sram_readback(
    input int chip, input int e_bank, input int e_addr,
    input bit [127:0] rtl_readback_data,
    input int rtl_ecc_single_err, input int exp_ecc_single_err
  );
  import "DPI-C" function int dpi_ref_check_barrier(
    input int chip, input int rtl_release_pulse, input int rtl_release_cnt,
    input int exp_release_cnt, input int all_notified
  );
  import "DPI-C" function int dpi_ref_check_c2c_transfer(
    input int nim_op, input int delay_sel, input int exp_flight,
    input bit [127:0] c0_tx_data,
    input bit [127:0] c1_local_data,
    input bit [127:0] rtl_c1_stream_out,
    input int rtl_deskew_cycles, input int rtl_measured_skew, input int rtl_crc_err
  );
  import "DPI-C" function int dpi_ref_check_cycle_invariants(
    input int cycle_id, input int coll_fault, input int crc_err,
    input int c0_ecc_dbl, input int c1_ecc_dbl
  );
  import "DPI-C" function int dpi_get_status();

  typedef enum int {
    TX_PIPELINE_WAVE = 0,
    TX_ECC_INJECT    = 1,
    TX_BARRIER_SYNC  = 2,
    TX_C2C_TRANSFER  = 3
  } full_chip_tx_kind_e;

  // ---------------------------------------------------------------------------
  // 1. UVM Sequence Item (full_chip_seq_item)
  // ---------------------------------------------------------------------------
  class full_chip_seq_item extends uvm_sequence_item;
    `uvm_object_utils(full_chip_seq_item)

    full_chip_tx_kind_e tx_kind = TX_PIPELINE_WAVE;
    int unsigned        tx_id   = 0;
    int unsigned        chip_id = 0;

    // Spatial Pipeline / SRAM / ECC parameters
    int unsigned        w_bank     = 0;
    int unsigned        w_addr     = 0;
    int unsigned        e_bank     = 0;
    int unsigned        e_addr     = 0;
    sxm_op_e            sxm_op     = SXM_PASSTHROUGH;
    logic [7:0]         sxm_shift  = 8'd0;
    logic [3:0]         bfly_mask  = 4'd0;
    vxm_op_e            vxm_op     = VXM_VADD;
    bit                 ecc_inj_en = 1'b0;
    int unsigned        ecc_bit_pos= 0;

    // Barrier parameters
    logic [7:0]         sync_mask  = 8'hFF;
    int unsigned        nop_stagger= 1;

    // Dragonfly C2C & RealSync parameters
    nim_op_e            nim_op         = NIM_RECV;
    logic [1:0]         c2c_delay_sel  = 2'd0;
    logic [15:0]        exp_flight_cyc = 16'd5;
    int unsigned        c1_local_bank  = 0;
    int unsigned        c1_local_addr  = 0;

    // Observed / Monitored RTL Results
    bit [127:0]         rtl_sxm_out;
    bit [127:0]         rtl_vxm_out;
    bit [127:0]         rtl_mxm_w_out;
    bit [127:0]         rtl_mxm_e_out;
    bit [127:0]         rtl_e_readback;
    int                 rtl_w_ecc_single_err;
    int                 rtl_e_ecc_single_err;
    int                 rtl_barrier_pulse;
    int                 rtl_barrier_cnt;
    int                 exp_barrier_cnt;
    bit [127:0]         c0_tx_data;
    bit [127:0]         c1_local_data;
    bit [127:0]         rtl_c1_stream_out;
    int                 rtl_deskew_cycles;
    int                 rtl_measured_skew;
    int                 rtl_crc_err;

    function new(string name = "full_chip_seq_item");
      super.new(name);
    endfunction
  endclass : full_chip_seq_item

  // ---------------------------------------------------------------------------
  // 2. UVM Sequencer (full_chip_sequencer)
  // ---------------------------------------------------------------------------
  class full_chip_sequencer extends uvm_sequencer #(full_chip_seq_item);
    `uvm_component_utils(full_chip_sequencer)
    function new(string name = "full_chip_sequencer", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass : full_chip_sequencer

  // ---------------------------------------------------------------------------
  // 3. UVM Sequence (full_chip_sequence)
  // ---------------------------------------------------------------------------
  class full_chip_sequence extends uvm_sequence #(full_chip_seq_item);
    `uvm_object_utils(full_chip_sequence)

    function new(string name = "full_chip_sequence");
      super.new(name);
    endfunction

    virtual task body();
      full_chip_seq_item req;
      int unsigned tid = 0;
      sxm_op_e sxm_ops[9] = '{
        SXM_PASSTHROUGH, SXM_ROTATE_LEFT, SXM_ROTATE_RIGHT,
        SXM_TRANSPOSE_4X4, SXM_BIT_REVERSE, SXM_BROADCAST_LANE,
        SXM_INTERLEAVE, SXM_REVERSE, SXM_BUTTERFLY_SWAP
      };
      vxm_op_e vxm_ops[8] = '{
        VXM_VADD, VXM_VMUL, VXM_SILU_LUT, VXM_GELU_LUT,
        VXM_SUB, VXM_MAX_ELEM, VXM_MIN_ELEM, VXM_RELU
      };
      nim_op_e nim_ops[3] = '{
        NIM_RECV, NIM_REALSYNC_PING, NIM_ALLREDUCE_ADD
      };

      // Phase 1: 108 End-to-End 8-Slice Spatial Pipeline Waves (~1,836 cycles)
      for (int i = 0; i < 108; i++) begin
        req = full_chip_seq_item::type_id::create($sformatf("pipe_%0d", i));
        start_item(req);
        req.tx_kind    = TX_PIPELINE_WAVE;
        req.tx_id      = tid++;
        req.chip_id    = i & 1;
        req.w_bank     = (i >> 1) & 3;
        req.w_addr     = (i % 16);
        req.e_bank     = ((i >> 1) + 1) & 3;
        req.e_addr     = (i % 16);
        req.sxm_op     = sxm_ops[i % 9];
        req.sxm_shift  = 8'(((i % 15) + 1) | (((i % 16)) << 4));
        req.bfly_mask  = 4'((i % 15) + 1);
        req.vxm_op     = vxm_ops[i % 8];
        req.ecc_inj_en = 1'b0;
        finish_item(req);
      end

      // Phase 2: 48 Single-Bit SECDED ECC Fault Injection Waves (~816 cycles)
      for (int i = 0; i < 48; i++) begin
        req = full_chip_seq_item::type_id::create($sformatf("ecc_%0d", i));
        start_item(req);
        req.tx_kind     = TX_ECC_INJECT;
        req.tx_id       = tid++;
        req.chip_id     = i & 1;
        req.w_bank      = (i >> 1) & 3;
        req.w_addr      = (i % 16);
        req.e_bank      = (i >> 1) & 3;
        req.e_addr      = (i % 16);
        req.sxm_op      = sxm_ops[i % 9];
        req.sxm_shift   = 8'((i % 7) + 1);
        req.bfly_mask   = 4'((i % 7) + 1);
        req.vxm_op      = vxm_ops[i % 8];
        req.ecc_inj_en  = 1'b1;
        req.ecc_bit_pos = (i * 3) % 144;
        finish_item(req);
      end

      // Phase 3: 36 Multi-Slice ICU_SYNC_BARRIER / ICU_NOTIFY Waves (~252 cycles)
      for (int i = 0; i < 36; i++) begin
        req = full_chip_seq_item::type_id::create($sformatf("bar_%0d", i));
        start_item(req);
        req.tx_kind     = TX_BARRIER_SYNC;
        req.tx_id       = tid++;
        req.chip_id     = i & 1;
        req.sync_mask   = 8'hFF;
        req.nop_stagger = (i % 3) + 1;
        finish_item(req);
      end

      // Phase 4: 64 Dragonfly C2C + RealSync Zero-Skew Transfers (~640 cycles)
      for (int i = 0; i < 64; i++) begin
        req = full_chip_seq_item::type_id::create($sformatf("c2c_%0d", i));
        start_item(req);
        req.tx_kind        = TX_C2C_TRANSFER;
        req.tx_id          = tid++;
        req.chip_id        = 0;
        req.w_bank         = i & 3;
        req.w_addr         = (i % 16);
        req.c1_local_bank  = (i + 1) & 3;
        req.c1_local_addr  = (i % 16);
        req.c2c_delay_sel  = 2'(i & 3);
        req.exp_flight_cyc = 16'd5;
        req.nim_op         = nim_ops[i % 3];
        finish_item(req);
      end
    endtask
  endclass : full_chip_sequence

  // ---------------------------------------------------------------------------
  // 4. UVM Driver (full_chip_driver)
  // ---------------------------------------------------------------------------
  class full_chip_driver extends uvm_driver #(full_chip_seq_item);
    `uvm_component_utils(full_chip_driver)

    virtual groq_full_chip_if vif;
    uvm_analysis_port #(full_chip_seq_item) drv_ap;
    int unsigned total_cycles = 0;
    int          exp_bar_cnt[2];
    bit [127:0]  shadow_w_sram[2][4][16];

    function new(string name = "full_chip_driver", uvm_component parent = null);
      super.new(name, parent);
      drv_ap = new("drv_ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual groq_full_chip_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface groq_full_chip_if not found")
    endfunction

    task step_cycle();
      @(posedge vif.clk);
      #1ps;
      total_cycles++;
      vif.cycle_id = total_cycles;
      void'(dpi_ref_check_cycle_invariants(
        total_cycles,
        int'(vif.cluster_collision_fault_o),
        int'(vif.cluster_c2c_crc_err_o),
        int'(|vif.chip0_ecc_double_err_o),
        int'(|vif.chip1_ecc_double_err_o)
      ));
    endtask

    task clear_vliw();
      vif.chip0_imem_vliw_bundle_i = '0;
      vif.chip1_imem_vliw_bundle_i = '0;
    endtask

    task reset_and_preload_cluster();
      bit [127:0] vec;
      groq_vliw_instr_t instr;

      dpi_full_chip_reset();
      exp_bar_cnt[0] = 0;
      exp_bar_cnt[1] = 0;

      vif.rst_n                    = 1'b0;
      vif.chip0_icu_enable_i       = 1'b0;
      vif.chip1_icu_enable_i       = 1'b0;
      vif.chip0_imem_vliw_bundle_i = '0;
      vif.chip1_imem_vliw_bundle_i = '0;
      vif.c2c_link_delay_sel_i     = 2'd0;
      vif.expected_flight_cycles_i = 16'd5;
      repeat (5) @(posedge vif.clk);
      #1ps;
      vif.rst_n = 1'b1;
      step_cycle();

      // 1. Host DMA Preload into Chip 0 & Chip 1 West & East SRAM Banks (4 banks x 16 rows)
      vif.phase_id = 0;
      for (int b = 0; b < 4; b++) begin
        for (int a = 0; a < 16; a++) begin
          for (int l = 0; l < 16; l++)
            vec[l*8 +: 8] = 8'(((b * 17 + a * 5 + l * 3 + 1) & 8'h3F) - 16);
          vif.chip0_host_mem_w_wr_en_i = 1'b1;
          vif.chip0_host_mem_w_bank_i  = 2'(b);
          vif.chip0_host_mem_w_addr_i  = 10'(a);
          vif.chip0_host_mem_w_data_i  = vec;
          vif.chip0_host_mem_e_wr_en_i = 1'b1;
          vif.chip0_host_mem_e_bank_i  = 2'(b);
          vif.chip0_host_mem_e_addr_i  = 10'(a);
          vif.chip0_host_mem_e_data_i  = vec;
          shadow_w_sram[0][b][a]       = vec;
          dpi_ref_dma_write(0, 0, b, a, vec);
          dpi_ref_dma_write(0, 1, b, a, vec);
          for (int l = 0; l < 16; l++)
            vec[l*8 +: 8] = 8'(((b * 13 + a * 7 + l * 5 + 3) & 8'h3F) - 16);
          vif.chip1_host_mem_w_wr_en_i = 1'b1;
          vif.chip1_host_mem_w_bank_i  = 2'(b);
          vif.chip1_host_mem_w_addr_i  = 10'(a);
          vif.chip1_host_mem_w_data_i  = vec;
          vif.chip1_host_mem_e_wr_en_i = 1'b1;
          vif.chip1_host_mem_e_bank_i  = 2'(b);
          vif.chip1_host_mem_e_addr_i  = 10'(a);
          vif.chip1_host_mem_e_data_i  = vec;
          shadow_w_sram[1][b][a]       = vec;
          dpi_ref_dma_write(1, 0, b, a, vec);
          dpi_ref_dma_write(1, 1, b, a, vec);
          step_cycle();
        end
      end
      vif.chip0_host_mem_w_wr_en_i = 1'b0;
      vif.chip0_host_mem_e_wr_en_i = 1'b0;
      vif.chip1_host_mem_w_wr_en_i = 1'b0;
      vif.chip1_host_mem_e_wr_en_i = 1'b0;
      vif.chip0_icu_enable_i       = 1'b1;
      vif.chip1_icu_enable_i       = 1'b1;
      step_cycle();

      // 2. Stage 16x16 Weights into Chip 0 & Chip 1 MXM_W (Hop 4) & MXM_E (Hop 6)
      for (int r = 0; r < 16; r++) begin
        clear_vliw();
        instr               = '0;
        instr.target_slice  = 4'(SLICE_MEM_W);
        instr.mem_op        = MEM_READ_EAST;
        instr.dst_stream    = 5'd0;
        instr.mem_base_addr = {6'd0, 10'(r)};
        vif.chip0_imem_vliw_bundle_i[SLICE_MEM_W] = instr;
        vif.chip1_imem_vliw_bundle_i[SLICE_MEM_W] = instr;
        step_cycle(); // Cycle 0->1
        clear_vliw();
        repeat (3) step_cycle(); // Cycle 1->4 (stream arrives at Hop 4 SLICE_MXM_W)

        instr               = '0;
        instr.target_slice  = 4'(SLICE_MXM_W);
        instr.mxm_op        = MXM_LOAD_WEIGHT_B0;
        instr.src_stream_b  = 5'd0;
        instr.imm16         = 16'(r);
        vif.chip0_imem_vliw_bundle_i[SLICE_MXM_W] = instr;
        vif.chip1_imem_vliw_bundle_i[SLICE_MXM_W] = instr;
        dpi_ref_load_mxm_weight(0, 0, r, shadow_w_sram[0][0][r]);
        dpi_ref_load_mxm_weight(1, 0, r, shadow_w_sram[1][0][r]);
        step_cycle(); // Cycle 4->5
        clear_vliw();
        step_cycle(); // Cycle 5->6 (stream arrives at Hop 6 SLICE_MXM_E)

        instr               = '0;
        instr.target_slice  = 4'(SLICE_MXM_E);
        instr.mxm_op        = MXM_LOAD_WEIGHT_B0;
        instr.src_stream_b  = 5'd0;
        instr.imm16         = 16'(r);
        vif.chip0_imem_vliw_bundle_i[SLICE_MXM_E] = instr;
        vif.chip1_imem_vliw_bundle_i[SLICE_MXM_E] = instr;
        dpi_ref_load_mxm_weight(0, 1, r, shadow_w_sram[0][0][r]);
        dpi_ref_load_mxm_weight(1, 1, r, shadow_w_sram[1][0][r]);
        step_cycle(); // Cycle 6->7
        clear_vliw();
        step_cycle();
      end
    endtask

    task set_chip_slice_instr(int chip, int slice_idx, groq_vliw_instr_t instr);
      if (chip == 0) vif.chip0_imem_vliw_bundle_i[slice_idx] = instr;
      else           vif.chip1_imem_vliw_bundle_i[slice_idx] = instr;
    endtask

    task drive_pipeline_wave(full_chip_seq_item item);
      groq_vliw_instr_t instr;
      int c = item.chip_id & 1;

      vif.phase_id   = (item.tx_kind == TX_ECC_INJECT) ? 2 : 1;
      vif.cov_sxm_op = item.sxm_op;
      vif.cov_vxm_op = item.vxm_op;
      vif.cov_mxm_op = MXM_SYSTOLIC_EXEC;
      vif.cov_mem_op = MEM_READ_EAST;

      if (item.ecc_inj_en) begin
        if (c == 0) begin
          vif.chip0_mem_err_inject_en_i   = 1'b1;
          vif.chip0_mem_err_inject_mask_i = (144'd1 << item.ecc_bit_pos);
        end else begin
          vif.chip1_mem_err_inject_en_i   = 1'b1;
          vif.chip1_mem_err_inject_mask_i = (144'd1 << item.ecc_bit_pos);
        end
      end

      // Cycle 0: SLICE_MEM_W (Hop 1) MEM_READ_EAST -> Stream 0 East
      clear_vliw();
      instr               = '0;
      instr.target_slice  = 4'(SLICE_MEM_W);
      instr.mem_op        = MEM_READ_EAST;
      instr.dst_stream    = 5'd0;
      instr.mem_base_addr = {4'd0, 2'(item.w_bank), 10'(item.w_addr)};
      set_chip_slice_instr(c, SLICE_MEM_W, instr);
      step_cycle(); // Cycle 0->1: u_mem_w outputs mem_w_out_valid & ecc_single_err_o[0]

      item.rtl_w_ecc_single_err = (c == 0) ? int'(vif.chip0_ecc_single_err_o[0])
                                           : int'(vif.chip1_ecc_single_err_o[0]);
      clear_vliw();
      step_cycle(); // Cycle 1->2: Stream 0 arrives at Hop 2 (SLICE_SXM)

      // Cycle 2: SLICE_SXM (Hop 2) permutes Stream 0 -> Stream 0 East
      instr               = '0;
      instr.target_slice  = 4'(SLICE_SXM);
      instr.sxm_op        = item.sxm_op;
      instr.src_stream_a  = 5'd0;
      instr.dst_stream    = 5'd0;
      instr.sxm_shift_amt = item.sxm_shift;
      instr.imm16         = {12'd0, item.bfly_mask};
      set_chip_slice_instr(c, SLICE_SXM, instr);
      step_cycle(); // Cycle 2->3: u_sxm outputs sxm_out_valid
      clear_vliw();
      step_cycle(); // Cycle 3->4: Stream 0 arrives at Hop 3 (SLICE_VXM)

      item.rtl_sxm_out = (c == 0) ? vif.chip0_stream_data_east_o[SLICE_VXM][0]
                                  : vif.chip1_stream_data_east_o[SLICE_VXM][0];

      // Cycle 4: SLICE_VXM (Hop 3) executes vector ALU/LUT on Stream 0 -> Stream 0 East
      instr              = '0;
      instr.target_slice = 4'(SLICE_VXM);
      instr.vxm_op       = item.vxm_op;
      instr.src_stream_a = 5'd0;
      instr.src_stream_b = 5'd0;
      instr.dst_stream   = 5'd0;
      set_chip_slice_instr(c, SLICE_VXM, instr);
      step_cycle(); // Cycle 4->5: u_vxm outputs vxm_out_valid
      clear_vliw();
      step_cycle(); // Cycle 5->6: Stream 0 arrives at Hop 4 (SLICE_MXM_W)

      item.rtl_vxm_out = (c == 0) ? vif.chip0_stream_data_east_o[SLICE_MXM_W][0]
                                  : vif.chip1_stream_data_east_o[SLICE_MXM_W][0];

      // Cycle 6: SLICE_MXM_W (Hop 4) executes systolic MAC on Stream 0 -> Stream 0 East
      instr              = '0;
      instr.target_slice = 4'(SLICE_MXM_W);
      instr.mxm_op       = MXM_SYSTOLIC_EXEC;
      instr.src_stream_a = 5'd0;
      instr.dst_stream   = 5'd0;
      set_chip_slice_instr(c, SLICE_MXM_W, instr);
      step_cycle(); // Cycle 6->7: MXM_W stage 1
      clear_vliw();
      step_cycle(); // Cycle 7->8: MXM_W stage 2 (mxm_w_out_valid=1)
      step_cycle(); // Cycle 8->9: Stream 0 arrives at Hop 5 (SLICE_ICU)

      item.rtl_mxm_w_out = (c == 0) ? vif.chip0_stream_data_east_o[SLICE_ICU][0]
                                    : vif.chip1_stream_data_east_o[SLICE_ICU][0];
      step_cycle(); // Cycle 9->10: Stream 0 arrives at Hop 6 (SLICE_MXM_E)

      // Cycle 10: SLICE_MXM_E (Hop 6) executes systolic MAC on Stream 0 -> Stream 0 East
      instr              = '0;
      instr.target_slice = 4'(SLICE_MXM_E);
      instr.mxm_op       = MXM_SYSTOLIC_EXEC;
      instr.src_stream_a = 5'd0;
      instr.dst_stream   = 5'd0;
      set_chip_slice_instr(c, SLICE_MXM_E, instr);
      step_cycle(); // Cycle 10->11: MXM_E stage 1
      clear_vliw();
      step_cycle(); // Cycle 11->12: MXM_E stage 2 (mxm_e_out_valid=1)
      step_cycle(); // Cycle 12->13: Stream 0 arrives at Hop 7 (SLICE_MEM_E)

      item.rtl_mxm_e_out = (c == 0) ? vif.chip0_stream_data_east_o[SLICE_MEM_E][0]
                                    : vif.chip1_stream_data_east_o[SLICE_MEM_E][0];

      // Cycle 13: SLICE_MEM_E (Hop 7) MEM_WRITE_EAST from Stream 0 into East SRAM
      vif.cov_mem_op      = MEM_WRITE_EAST;
      instr               = '0;
      instr.target_slice  = 4'(SLICE_MEM_E);
      instr.mem_op        = MEM_WRITE_EAST;
      instr.src_stream_a  = 5'd0;
      instr.mem_base_addr = {4'd0, 2'(item.e_bank), 10'(item.e_addr)};
      set_chip_slice_instr(c, SLICE_MEM_E, instr);
      step_cycle(); // Cycle 13->14: East SRAM written

      // Cycle 14: SLICE_MEM_E (Hop 7) MEM_READ_WEST -> West Stream 0
      vif.cov_mem_op      = MEM_READ_WEST;
      instr               = '0;
      instr.target_slice  = 4'(SLICE_MEM_E);
      instr.mem_op        = MEM_READ_WEST;
      instr.dst_stream    = 5'd0;
      instr.dst_dir_west  = 1'b1;
      instr.mem_base_addr = {4'd0, 2'(item.e_bank), 10'(item.e_addr)};
      set_chip_slice_instr(c, SLICE_MEM_E, instr);
      step_cycle(); // Cycle 14->15: u_mem_e outputs mem_e_out_valid & ecc_single_err_o[1]

      item.rtl_e_ecc_single_err = (c == 0) ? int'(vif.chip0_ecc_single_err_o[1])
                                           : int'(vif.chip1_ecc_single_err_o[1]);
      clear_vliw();
      step_cycle(); // Cycle 15->16: West Stream 0 arrives at Hop 6 (SLICE_MXM_E)

      item.rtl_e_readback = (c == 0) ? vif.chip0_stream_data_west_o[SLICE_MXM_E][0]
                                     : vif.chip1_stream_data_west_o[SLICE_MXM_E][0];

      vif.chip0_mem_err_inject_en_i   = 1'b0;
      vif.chip0_mem_err_inject_mask_i = '0;
      vif.chip1_mem_err_inject_en_i   = 1'b0;
      vif.chip1_mem_err_inject_mask_i = '0;
      vif.sample_en = 1'b1;
      step_cycle();
      vif.sample_en = 1'b0;
    endtask

    task drive_barrier_sync(full_chip_seq_item item);
      groq_vliw_instr_t instr;
      int c = item.chip_id & 1;

      vif.phase_id   = 3;
      vif.cov_icu_op = ICU_SYNC_BARRIER;
      clear_vliw();

      // Cycle 0: Slice 0 enters ICU_SYNC_BARRIER(0xFF), Slices 1..6 issue ICU_NOTIFY,
      //          Slice 7 issues ICU_NOP_DELAY(nop_stagger)
      instr              = '0;
      instr.target_slice = 4'(SLICE_NIM);
      instr.icu_op       = ICU_SYNC_BARRIER;
      instr.sync_mask    = 8'hFF;
      set_chip_slice_instr(c, SLICE_NIM, instr);

      for (int s = 1; s < 7; s++) begin
        instr              = '0;
        instr.target_slice = 4'(s);
        instr.icu_op       = ICU_NOTIFY;
        set_chip_slice_instr(c, s, instr);
      end

      instr               = '0;
      instr.target_slice  = 4'(SLICE_MEM_E);
      instr.icu_op        = ICU_NOP_DELAY;
      instr.nop_delay_cnt = 16'(item.nop_stagger);
      set_chip_slice_instr(c, SLICE_MEM_E, instr);
      step_cycle();

      // Wait for Slice 7 NOP_DELAY countdown while Slice 0 waits at barrier
      clear_vliw();
      for (int k = 0; k < item.nop_stagger; k++) begin
        step_cycle();
      end

      // Now Slice 7 issues final ICU_NOTIFY -> releases barrier across all 8 slices!
      vif.cov_icu_op     = ICU_NOTIFY;
      instr              = '0;
      instr.target_slice = 4'(SLICE_MEM_E);
      instr.icu_op       = ICU_NOTIFY;
      set_chip_slice_instr(c, SLICE_MEM_E, instr);
      #1ps;
      item.rtl_barrier_pulse = (c == 0) ? int'(vif.chip0_barrier_release_pulse_o)
                                        : int'(vif.chip1_barrier_release_pulse_o);
      step_cycle();
      clear_vliw();
      exp_bar_cnt[c]++;
      item.rtl_barrier_cnt = (c == 0) ? int'(vif.chip0_barrier_release_cnt_o)
                                      : int'(vif.chip1_barrier_release_cnt_o);
      item.exp_barrier_cnt = exp_bar_cnt[c];
      vif.sample_en = 1'b1;
      step_cycle();
      vif.sample_en = 1'b0;
    endtask

    task drive_c2c_transfer(full_chip_seq_item item);
      groq_vliw_instr_t instr;
      int observed_dsk_cyc = -1;
      int observed_skew    = 0;

      vif.phase_id                 = 4;
      vif.cov_nim_op               = item.nim_op;
      vif.c2c_link_delay_sel_i     = item.c2c_delay_sel;
      vif.expected_flight_cycles_i = item.exp_flight_cyc;

      // Cycle 0: Chip 0 SLICE_MEM_W (Hop 1) MEM_READ_WEST -> West Stream 0
      clear_vliw();
      instr               = '0;
      instr.target_slice  = 4'(SLICE_MEM_W);
      instr.mem_op        = MEM_READ_WEST;
      instr.dst_stream    = 5'd0;
      instr.dst_dir_west  = 1'b1;
      instr.mem_base_addr = {4'd0, 2'(item.w_bank), 10'(item.w_addr)};
      set_chip_slice_instr(0, SLICE_MEM_W, instr);
      step_cycle(); // Cycle 0->1: u_mem_w outputs mem_w_out_valid
      clear_vliw();
      step_cycle(); // Cycle 1->2: West Stream 0 arrives at Chip 0 Hop 0 (SLICE_NIM)

      item.c0_tx_data    = shadow_w_sram[0][item.w_bank & 3][item.w_addr & 15];
      item.c1_local_data = shadow_w_sram[1][item.c1_local_bank & 3][item.c1_local_addr & 15];

      // Cycles d = 0..6 relative to T_tx (Cycle 2)
      for (int d = 0; d < 7; d++) begin
        if (vif.chip1_deskew_release_valid_o && (observed_dsk_cyc < 0))
          observed_dsk_cyc = d;

        clear_vliw();
        if (d == 0) begin
          instr              = '0;
          instr.target_slice = 4'(SLICE_NIM);
          instr.nim_op       = NIM_SEND;
          instr.src_stream_a = 5'd16; // West Stream 0
          instr.imm16        = 16'h0001; // dst_chip = 1
          set_chip_slice_instr(0, SLICE_NIM, instr);
        end
        if ((d == (1 + int'(item.c2c_delay_sel))) && (item.nim_op == NIM_REALSYNC_PING)) begin
          instr              = '0;
          instr.target_slice = 4'(SLICE_NIM);
          instr.nim_op       = NIM_REALSYNC_PING;
          set_chip_slice_instr(1, SLICE_NIM, instr);
        end
        if ((d == 3) && (item.nim_op == NIM_ALLREDUCE_ADD)) begin
          instr               = '0;
          instr.target_slice  = 4'(SLICE_MEM_W);
          instr.mem_op        = MEM_READ_WEST;
          instr.dst_stream    = 5'd0;
          instr.dst_dir_west  = 1'b1;
          instr.mem_base_addr = {4'd0, 2'(item.c1_local_bank), 10'(item.c1_local_addr)};
          set_chip_slice_instr(1, SLICE_MEM_W, instr);
        end
        if (d == 5) begin
          instr              = '0;
          instr.target_slice = 4'(SLICE_NIM);
          instr.nim_op       = (item.nim_op == NIM_ALLREDUCE_ADD) ? NIM_ALLREDUCE_ADD : NIM_RECV;
          instr.src_stream_a = 5'd16;
          instr.dst_stream   = 5'd0;
          set_chip_slice_instr(1, SLICE_NIM, instr);
        end

        step_cycle();
        if ((d == (1 + int'(item.c2c_delay_sel))) && (item.nim_op == NIM_REALSYNC_PING))
          observed_skew = int'(vif.chip1_measured_skew_o);
      end

      clear_vliw();
      item.rtl_c1_stream_out = vif.chip1_stream_data_east_o[SLICE_MEM_W][0];
      item.rtl_deskew_cycles = observed_dsk_cyc;
      item.rtl_measured_skew = observed_skew;
      item.rtl_crc_err       = int'(vif.cluster_c2c_crc_err_o);
      vif.sample_en = 1'b1;
      step_cycle();
      vif.sample_en = 1'b0;
    endtask

    virtual task run_phase(uvm_phase phase);
      full_chip_seq_item req;
      reset_and_preload_cluster();
      forever begin
        seq_item_port.get_next_item(req);
        case (req.tx_kind)
          TX_PIPELINE_WAVE: drive_pipeline_wave(req);
          TX_ECC_INJECT:    drive_pipeline_wave(req);
          TX_BARRIER_SYNC:  drive_barrier_sync(req);
          TX_C2C_TRANSFER:  drive_c2c_transfer(req);
          default:          drive_pipeline_wave(req);
        endcase
        drv_ap.write(req);
        seq_item_port.item_done();
      end
    endtask
  endclass : full_chip_driver

  // ---------------------------------------------------------------------------
  // 5. UVM Monitor & Functional Covergroup (full_chip_monitor)
  // ---------------------------------------------------------------------------
  class full_chip_monitor extends uvm_monitor;
    `uvm_component_utils(full_chip_monitor)

    virtual groq_full_chip_if vif;
    int unsigned seen_tx = 0;

    covergroup full_chip_cg with function sample(
      bit [2:0] phase_id,
      bit [3:0] sxm_op,
      bit [3:0] vxm_op,
      bit [3:0] nim_op,
      bit [1:0] c2c_delay
    );
      option.per_instance = 1;
      cp_phase: coverpoint phase_id {
        bins ph_pipe    = {3'd1};
        bins ph_ecc     = {3'd2};
        bins ph_barrier = {3'd3};
        bins ph_c2c     = {3'd4};
      }
      cp_sxm_op: coverpoint sxm_op {
        bins s_pass    = {SXM_PASSTHROUGH};
        bins s_rot_l   = {SXM_ROTATE_LEFT};
        bins s_rot_r   = {SXM_ROTATE_RIGHT};
        bins s_t4x4    = {SXM_TRANSPOSE_4X4};
        bins s_bitrev  = {SXM_BIT_REVERSE};
        bins s_bcast   = {SXM_BROADCAST_LANE};
        bins s_interlv = {SXM_INTERLEAVE};
        bins s_rev     = {SXM_REVERSE};
        bins s_bfly    = {SXM_BUTTERFLY_SWAP};
      }
      cp_vxm_op: coverpoint vxm_op {
        bins v_add  = {VXM_VADD};
        bins v_mul  = {VXM_VMUL};
        bins v_silu = {VXM_SILU_LUT};
        bins v_gelu = {VXM_GELU_LUT};
        bins v_sub  = {VXM_SUB};
        bins v_max  = {VXM_MAX_ELEM};
        bins v_min  = {VXM_MIN_ELEM};
        bins v_relu = {VXM_RELU};
      }
      cp_nim_op: coverpoint nim_op {
        bins n_recv      = {NIM_RECV};
        bins n_ping      = {NIM_REALSYNC_PING};
        bins n_allreduce = {NIM_ALLREDUCE_ADD};
      }
      cp_c2c_delay: coverpoint c2c_delay {
        bins d_all[] = {[2'd0:2'd3]};
      }
    endgroup

    function new(string name = "full_chip_monitor", uvm_component parent = null);
      super.new(name, parent);
      full_chip_cg = new();
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual groq_full_chip_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface groq_full_chip_if missing in monitor")
    endfunction

    virtual task run_phase(uvm_phase phase);
      forever begin
        @(posedge vif.clk);
        #1ps;
        if (vif.rst_n && vif.sample_en) begin
          full_chip_cg.sample(
            3'(vif.phase_id),
            vif.cov_sxm_op,
            vif.cov_vxm_op,
            vif.cov_nim_op,
            vif.c2c_link_delay_sel_i
          );
          seen_tx++;
        end
      end
    endtask
  endclass : full_chip_monitor

  // ---------------------------------------------------------------------------
  // 6. UVM Scoreboard with C++17 DPI-C Reference Model (full_chip_scoreboard)
  // ---------------------------------------------------------------------------
  class full_chip_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(full_chip_scoreboard)

    uvm_analysis_imp #(full_chip_seq_item, full_chip_scoreboard) sb_imp;
    int unsigned total_tx      = 0;
    int unsigned pipe_tx       = 0;
    int unsigned ecc_tx        = 0;
    int unsigned barrier_tx    = 0;
    int unsigned c2c_tx        = 0;
    int unsigned mismatches    = 0;

    function new(string name = "full_chip_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      sb_imp = new("sb_imp", this);
    endfunction

    virtual function void write(full_chip_seq_item item);
      int rc1 = 0, rc2 = 0;
      total_tx++;
      case (item.tx_kind)
        TX_PIPELINE_WAVE: begin
          pipe_tx++;
          rc1 = dpi_ref_check_pipeline(
            int'(item.chip_id), int'(item.w_bank), int'(item.w_addr),
            int'(item.sxm_op), int'(item.sxm_shift), int'(item.bfly_mask),
            int'(item.vxm_op), int'(item.e_bank), int'(item.e_addr),
            item.rtl_sxm_out, item.rtl_vxm_out,
            item.rtl_mxm_w_out, item.rtl_mxm_e_out,
            item.rtl_w_ecc_single_err, 0
          );
          rc2 = dpi_ref_check_e_sram_readback(
            int'(item.chip_id), int'(item.e_bank), int'(item.e_addr),
            item.rtl_e_readback, item.rtl_e_ecc_single_err, 0
          );
        end
        TX_ECC_INJECT: begin
          ecc_tx++;
          rc1 = dpi_ref_check_pipeline(
            int'(item.chip_id), int'(item.w_bank), int'(item.w_addr),
            int'(item.sxm_op), int'(item.sxm_shift), int'(item.bfly_mask),
            int'(item.vxm_op), int'(item.e_bank), int'(item.e_addr),
            item.rtl_sxm_out, item.rtl_vxm_out,
            item.rtl_mxm_w_out, item.rtl_mxm_e_out,
            item.rtl_w_ecc_single_err, 1
          );
          rc2 = dpi_ref_check_e_sram_readback(
            int'(item.chip_id), int'(item.e_bank), int'(item.e_addr),
            item.rtl_e_readback, item.rtl_e_ecc_single_err, 1
          );
        end
        TX_BARRIER_SYNC: begin
          barrier_tx++;
          rc1 = dpi_ref_check_barrier(
            int'(item.chip_id), item.rtl_barrier_pulse,
            item.rtl_barrier_cnt, item.exp_barrier_cnt, 1
          );
        end
        TX_C2C_TRANSFER: begin
          c2c_tx++;
          rc1 = dpi_ref_check_c2c_transfer(
            int'(item.nim_op), int'(item.c2c_delay_sel), int'(item.exp_flight_cyc),
            item.c0_tx_data, item.c1_local_data, item.rtl_c1_stream_out,
            item.rtl_deskew_cycles, item.rtl_measured_skew, item.rtl_crc_err
          );
        end
      endcase
      if ((rc1 != 0) || (rc2 != 0)) begin
        mismatches++;
        `uvm_error("FULL_CHIP_SB_MISMATCH", $sformatf("Transaction %0d kind=%0d failed DPI check", item.tx_id, item.tx_kind))
      end
    endfunction
  endclass : full_chip_scoreboard

  // ---------------------------------------------------------------------------
  // 7. UVM Environment (full_chip_env) & Top-Level Test (full_chip_test)
  // ---------------------------------------------------------------------------
  class full_chip_env extends uvm_env;
    `uvm_component_utils(full_chip_env)

    full_chip_sequencer  sequencer;
    full_chip_driver     driver;
    full_chip_monitor    monitor;
    full_chip_scoreboard scoreboard;

    function new(string name = "full_chip_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer  = full_chip_sequencer::type_id::create("sequencer", this);
      driver     = full_chip_driver::type_id::create("driver", this);
      monitor    = full_chip_monitor::type_id::create("monitor", this);
      scoreboard = full_chip_scoreboard::type_id::create("scoreboard", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
      driver.drv_ap.connect(scoreboard.sb_imp);
    endfunction
  endclass : full_chip_env

  class full_chip_test extends uvm_test;
    `uvm_component_utils(full_chip_test)

    full_chip_env env;

    function new(string name = "full_chip_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = full_chip_env::type_id::create("env", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
      full_chip_sequence seq = full_chip_sequence::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.sequencer);
      repeat (4) @(posedge env.driver.vif.clk);
      phase.drop_objection(this);
    endtask

    virtual function void report_phase(uvm_phase phase);
      real func_cov;
      int  dpi_rc;
      bit  pass_gate;
      int  fd;
      super.report_phase(phase);

      func_cov  = env.monitor.full_chip_cg.get_inst_coverage();
      dpi_rc    = dpi_get_status();
      pass_gate = (env.driver.total_cycles >= 3000) &&
                  (env.scoreboard.mismatches == 0) &&
                  (dpi_rc == 0) &&
                  (func_cov == 100.0);

      fd = $fopen("full_chip_summary.json", "w");
      if (fd != 0) begin
        $fdisplay(fd, "{");
        $fdisplay(fd, "  \"suite\": \"uvm_full_chip\",");
        $fdisplay(fd, "  \"dut\": [\"groq_lpu_cluster_top\", \"groq_lpu_top\"],");
        $fdisplay(fd, "  \"total_cycles\": %0d,", env.driver.total_cycles);
        $fdisplay(fd, "  \"total_transactions\": %0d,", env.scoreboard.total_tx);
        $fdisplay(fd, "  \"pipeline_waves\": %0d,", env.scoreboard.pipe_tx);
        $fdisplay(fd, "  \"ecc_inject_waves\": %0d,", env.scoreboard.ecc_tx);
        $fdisplay(fd, "  \"barrier_sync_waves\": %0d,", env.scoreboard.barrier_tx);
        $fdisplay(fd, "  \"c2c_transfers\": %0d,", env.scoreboard.c2c_tx);
        $fdisplay(fd, "  \"mismatches\": %0d,", env.scoreboard.mismatches);
        $fdisplay(fd, "  \"functional_coverage_pct\": %0.2f,", func_cov);
        $fdisplay(fd, "  \"pass\": %0d", pass_gate);
        $fdisplay(fd, "}");
        $fclose(fd);
      end

      if (!pass_gate) begin
        `uvm_fatal("UVM_FULL_CHIP_FAIL", $sformatf(
          "Gate failed: cycles=%0d tx=%0d mismatches=%0d cov=%0.2f%% dpi_rc=%0d",
          env.driver.total_cycles, env.scoreboard.total_tx,
          env.scoreboard.mismatches, func_cov, dpi_rc))
      end else begin
        `uvm_info("UVM_FULL_CHIP_PASS", $sformatf(
          "PASS: %0d cycles (%0d waves) verified across 2-chip cluster via C++17 DPI-C reference, 0 mismatches, 100.00%% functional coverage",
          env.driver.total_cycles, env.scoreboard.total_tx), UVM_LOW)
      end
    endfunction
  endclass : full_chip_test

endpackage : groq_full_chip_uvm_pkg

`endif // GROQ_FULL_CHIP_UVM_PKG_SV
