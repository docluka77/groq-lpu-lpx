// =============================================================================
// File: uvm_tb/uvm_dragonfly_8chip/uvm_dragonfly_8chip_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Accellera IEEE 1800.2-2020 UVM Verification Package for
//              groq_dragonfly_8chip_cluster (8-Chip Dragonfly Scale-Out Cluster).
// =============================================================================
`ifndef UVM_DRAGONFLY_8CHIP_PKG_SV
`define UVM_DRAGONFLY_8CHIP_PKG_SV

`include "uvm_macros.svh"
`include "groq_pkg.sv"

package uvm_dragonfly_8chip_pkg;
 import uvm_pkg::*;
 import groq_pkg::*;

 localparam int P_NUM_CHIPS = 8;

 // ---------------------------------------------------------------------------
 // 1. C++17 DPI-C Golden Reference Model Imports
 // ---------------------------------------------------------------------------
 import "DPI-C" function void dpi_dragonfly_8chip_reset();
 import "DPI-C" function int unsigned dpi_get_calls();
 import "DPI-C" function void dpi_set_status(input int status);

 import "DPI-C" function void dpi_dragonfly_8chip_step(
 input int unsigned global_cycle_i,
 input int unsigned dma_target_chip_i,
 input int unsigned dma_bcast_all_chips_i,
 input int unsigned dma_vliw_sram_busy_i,
 input int unsigned vliw_mem_w_busy_mask_i,
 input int unsigned vliw_mem_e_busy_mask_i,
 input int unsigned dma_desc_push_valid_i,
 input bit [127:0] dma_desc_push_data_i,
 input int unsigned dma_payload_valid_i,
 input bit [127:0] dma_payload_data_i,
 input int unsigned dma_payload_parity_i,
 input int unsigned cluster_route_mode_i,
 input int unsigned ring_dir_west_i,
 input int unsigned congestion_mask_i,
 input int unsigned butterfly_stage_i,
 input int unsigned pcs_link_enable_i,
 input int unsigned pcs_rx_ts1_seen_i,
 input int unsigned pcs_rx_ts2_seen_i,
 input int unsigned pcs_deskew_done_i,
 input int unsigned pcs_retrain_req_i,
 input int unsigned nim_send_valid_mask_i,
 input int unsigned nim_send_dst_packed_i,
 input int unsigned mem_rd_w_mask_i,
 input int unsigned mem_rd_e_mask_i,
 input int unsigned mem_err_inject_en_i,
 input bit [143:0] mem_err_inject_mask_i,
 output int unsigned exp_dma_desc_ready_o,
 output int unsigned exp_dma_pay_ready_o,
 output int unsigned exp_dma_busy_o,
 output int unsigned exp_dma_window_stall_o,
 output int unsigned exp_dma_parity_err_o,
 output int unsigned exp_dma_done_irq_o,
 output int unsigned exp_dma_completed_desc_cnt_o,
 output int unsigned exp_dma_beats_transferred_o,
 output int unsigned exp_pcs_link_up_o,
 output int unsigned exp_routed_dst_packed_o,
 output int unsigned exp_ecc_single_err_o,
 output int unsigned exp_ecc_double_err_o
 );

 import "DPI-C" function int unsigned dpi_check_c2c_rx_from_sram(
 input int unsigned src_chip,
 input int unsigned sram_bank,
 input int unsigned sram_row,
 input bit [127:0] act_rx_data_i
 );

 // ---------------------------------------------------------------------------
 // 2. Stimulus Helper Functions (Parity, DMA Descriptor, VLIW Bundle Builders)
 // ---------------------------------------------------------------------------
 function automatic bit [15:0] tb_calc_parity16(input bit [127:0] data_in);
 bit [15:0] p;
 for (int i = 0; i < 16; i++) p[i] = ^data_in[i*8 +: 8];
 return p;
 endfunction

 function automatic bit [127:0] tb_build_dma_desc(
 input bit [1:0] tgt,
 input bit [2:0] sel,
 input bit [15:0] base_addr,
 input bit [7:0] stride,
 input bit [7:0] burst_len,
 input bit [15:0] sched_cycle
 );
 return {56'd0, 16'd0, sched_cycle, burst_len, stride, base_addr, 3'd0, sel, tgt};
 endfunction

  function automatic groq_vliw_instr_t tb_vliw_mem_read_w(input bit [15:0] addr);
    groq_vliw_instr_t ins = '0;
    ins.target_slice  = 4'(SLICE_MEM_W);
    ins.mem_op        = MEM_READ_WEST;
    ins.dst_stream    = 5'd0;
    ins.mem_base_addr = addr;
    return ins;
  endfunction

  function automatic groq_vliw_instr_t tb_vliw_mem_read_e(input bit [15:0] addr);
    groq_vliw_instr_t ins = '0;
    ins.target_slice  = 4'(SLICE_MEM_E);
    ins.mem_op        = MEM_READ_EAST;
    ins.dst_stream    = 5'd0;
    ins.mem_base_addr = addr;
    return ins;
  endfunction

  function automatic groq_vliw_instr_t tb_vliw_nim_send(input bit [2:0] dst_chip);
    groq_vliw_instr_t ins = '0;
    ins.target_slice = 4'(SLICE_NIM);
    ins.nim_op       = NIM_SEND;
    ins.src_stream_a = 5'b10000;
    ins.imm16        = {13'd0, dst_chip};
    return ins;
  endfunction

  function automatic groq_vliw_instr_t tb_vliw_nim_allreduce(input bit [2:0] dst_chip);
    groq_vliw_instr_t ins = '0;
    ins.target_slice = 4'(SLICE_NIM);
    ins.nim_op       = NIM_ALLREDUCE_ADD;
    ins.src_stream_a = 5'b10000;
    ins.imm16        = {13'd0, dst_chip};
    return ins;
  endfunction

  // ---------------------------------------------------------------------------
  // 3. UVM Sequence Item & Sequencer
  // ---------------------------------------------------------------------------
  class dragonfly_8chip_seq_item extends uvm_sequence_item;
    `uvm_object_utils(dragonfly_8chip_seq_item)

    int unsigned tx_id;
    int unsigned phase_id;
    bit [1:0]    cov_dma_target;
    bit [1:0]    cov_ecc_kind;

    // Stimulus Inputs
    bit [P_NUM_CHIPS-1:0]                                    chip_icu_enable;
    bit [P_NUM_CHIPS-1:0][NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] chip_imem_vliw_bundle;
    bit [15:0]            global_cycle;
    bit [2:0]             dma_target_chip;
    bit                   dma_bcast_all_chips;
    bit                   dma_vliw_sram_busy;
    bit                   dma_desc_push_valid;
    bit [127:0]           dma_desc_push_data;
    bit                   dma_payload_valid;
    bit [STREAM_WIDTH-1:0] dma_payload_data;
    bit [15:0]            dma_payload_parity;
    bit [1:0]             cluster_route_mode;
    bit                   ring_dir_west;
    bit [P_NUM_CHIPS-1:0] congestion_mask;
    bit [2:0]             butterfly_stage;
    bit                   pcs_link_enable;
    bit                   pcs_scramble_en;
    bit                   pcs_rx_ts1_seen;
    bit                   pcs_rx_ts2_seen;
    bit                   pcs_deskew_done;
    bit                   pcs_retrain_req;
    bit [P_NUM_CHIPS-1:0] link_delay_en;
    bit [15:0]            expected_flight_cycles;
    bit [P_NUM_CHIPS-1:0] pcs_err_inject_en;
    bit [15:0]            pcs_err_inject_mask;
    bit [P_NUM_CHIPS-1:0] mem_err_inject_en;
    bit [143:0]           mem_err_inject_mask;

    // Observed DUT Outputs
    logic                   act_dma_desc_push_ready;
    logic                   act_dma_payload_ready;
    logic                   act_dma_busy;
    logic                   act_dma_window_stall;
    logic                   act_dma_parity_err;
    logic                   act_dma_done_irq;
    logic [7:0]             act_dma_completed_desc_cnt;
    logic [15:0]            act_dma_beats_transferred;
    logic                   act_cluster_all_halted;
    logic                   act_cluster_any_barrier;
    logic [P_NUM_CHIPS-1:0] act_cluster_pcs_link_up;
    logic [P_NUM_CHIPS-1:0] act_cluster_crc16_err;
    logic [P_NUM_CHIPS-1:0] act_cluster_realsync_err;
    logic [P_NUM_CHIPS-1:0] act_cluster_ecc_single_err;
    logic [P_NUM_CHIPS-1:0] act_cluster_ecc_double_err;
    logic [P_NUM_CHIPS-1:0] act_cluster_c2c_tx_valid;
    logic [P_NUM_CHIPS-1:0] act_cluster_deskew_release;
    logic [P_NUM_CHIPS-1:0][2:0]              act_cluster_routed_dst;
    logic [P_NUM_CHIPS-1:0][STREAM_WIDTH-1:0] act_cluster_nim_rx_data;

    function new(string name = "dragonfly_8chip_seq_item");
 super.new(name);
 endfunction
 endclass : dragonfly_8chip_seq_item

 typedef uvm_sequencer #(dragonfly_8chip_seq_item) dragonfly_8chip_sequencer;

  // ---------------------------------------------------------------------------
  // 4. Comprehensive 3,400+ Cycle Directed & Constrained-Random UVM Sequence
  // ---------------------------------------------------------------------------
  class dragonfly_8chip_sequence extends uvm_sequence #(dragonfly_8chip_seq_item);
    `uvm_object_utils(dragonfly_8chip_sequence)

    int unsigned next_id = 0;

    // Persistent cluster control state across cycles
    bit [P_NUM_CHIPS-1:0] cur_icu_en       = '0;
    bit [1:0]             cur_route_mode   = 2'b00;
    bit                   cur_ring_west    = 1'b0;
    bit [P_NUM_CHIPS-1:0] cur_cong_mask    = '0;
    bit [2:0]             cur_bstage       = 3'd1;
    bit                   cur_pcs_en       = 1'b0;
    bit                   cur_pcs_scram    = 1'b1;
    bit                   cur_ts1          = 1'b0;
    bit                   cur_ts2          = 1'b0;
    bit                   cur_dsk          = 1'b0;
    bit                   cur_retrain      = 1'b0;
    bit [P_NUM_CHIPS-1:0] cur_link_dly     = '0;
    bit [15:0]            cur_flight_cyc   = 16'd4;
    bit [1:0]             cur_cov_dma_tgt  = 2'b00;
    bit [1:0]             cur_cov_ecc_kind = 2'b00;

    function new(string name = "dragonfly_8chip_sequence");
 super.new(name);
 endfunction

 function automatic dragonfly_8chip_seq_item make_base_item(input int unsigned ph);
 dragonfly_8chip_seq_item it = dragonfly_8chip_seq_item::type_id::create("it");
 it.phase_id = ph;
 it.global_cycle = 16'(next_id);
 it.chip_icu_enable = cur_icu_en;
 it.chip_imem_vliw_bundle = '0;
 it.dma_target_chip = 3'd0;
 it.dma_bcast_all_chips = 1'b0;
 it.dma_vliw_sram_busy = 1'b0;
 it.dma_desc_push_valid = 1'b0;
 it.dma_desc_push_data = '0;
 it.dma_payload_valid = 1'b0;
 it.dma_payload_data = '0;
 it.dma_payload_parity = 16'd0;
 it.cluster_route_mode = cur_route_mode;
 it.ring_dir_west = cur_ring_west;
 it.congestion_mask = cur_cong_mask;
 it.butterfly_stage = cur_bstage;
 it.pcs_link_enable = cur_pcs_en;
 it.pcs_scramble_en = cur_pcs_scram;
 it.pcs_rx_ts1_seen = cur_ts1;
 it.pcs_rx_ts2_seen = cur_ts2;
 it.pcs_deskew_done = cur_dsk;
 it.pcs_retrain_req = cur_retrain;
 it.link_delay_en = cur_link_dly;
 it.expected_flight_cycles = cur_flight_cyc;
 it.pcs_err_inject_en = '0;
 it.pcs_err_inject_mask = 16'h0000;
 it.mem_err_inject_en = '0;
 it.mem_err_inject_mask = '0;
 it.cov_dma_target = cur_cov_dma_tgt;
 it.cov_ecc_kind = cur_cov_ecc_kind;
 return it;
 endfunction

 task emit_item(dragonfly_8chip_seq_item it);
 it.tx_id = next_id;
 it.global_cycle = 16'(next_id);
 next_id++;
 start_item(it);
 finish_item(it);
 endtask

 task emit_idle_cycles(input int unsigned ph, input int count);
 for (int i = 0; i < count; i++) begin
 dragonfly_8chip_seq_item it = make_base_item(ph);
 emit_item(it);
 end
 endtask

    task dma_transfer_word(
      input int unsigned ph,
      input bit          bcast,
      input bit [2:0]    tgt_chip,
      input bit [1:0]    dma_tgt,
      input bit [2:0]    slice_or_bank,
      input bit [15:0]   base_addr,
      input bit [127:0]  payload,
      input bit          inject_stall,
      input bit          inject_perr
    );
      dragonfly_8chip_seq_item it;
      cur_cov_dma_tgt = dma_tgt;

      // Cycle 1: Push descriptor
      it = make_base_item(ph);
      it.dma_bcast_all_chips = bcast;
      it.dma_target_chip     = tgt_chip;
      it.dma_desc_push_valid = 1'b1;
      it.dma_desc_push_data  = tb_build_dma_desc(dma_tgt, slice_or_bank, base_addr, 8'd1, 8'd1, 16'd0);
      emit_item(it);

      // Cycle 2: Pop descriptor into active burst engine
      it = make_base_item(ph);
      it.dma_bcast_all_chips = bcast;
      it.dma_target_chip     = tgt_chip;
      emit_item(it);

      // Optional: VLIW SRAM busy admission window stall cycle
      if (inject_stall && (dma_tgt != 2'b00)) begin
        it = make_base_item(ph);
        it.dma_bcast_all_chips = bcast;
        it.dma_target_chip     = tgt_chip;
        it.dma_vliw_sram_busy  = 1'b1;
        it.dma_payload_valid   = 1'b1;
        it.dma_payload_data    = payload;
        it.dma_payload_parity  = tb_calc_parity16(payload);
        emit_item(it);
      end

      // Optional: Payload parity error cycle (rejected without advancing beat)
      if (inject_perr) begin
        it = make_base_item(ph);
        it.dma_bcast_all_chips = bcast;
        it.dma_target_chip     = tgt_chip;
        it.dma_payload_valid   = 1'b1;
        it.dma_payload_data    = payload;
        it.dma_payload_parity  = ~tb_calc_parity16(payload);
        emit_item(it);
      end

      // Clean payload beat fire cycle
      it = make_base_item(ph);
      it.dma_bcast_all_chips = bcast;
      it.dma_target_chip     = tgt_chip;
      it.dma_payload_valid   = 1'b1;
      it.dma_payload_data    = payload;
      it.dma_payload_parity  = tb_calc_parity16(payload);
      emit_item(it);

      // Completion IRQ observation cycle
      it = make_base_item(ph);
      it.dma_bcast_all_chips = bcast;
      it.dma_target_chip     = tgt_chip;
      emit_item(it);
    endtask

    task run_collective_wave(
      input int unsigned      ph,
      input bit [15:0]        sram_addr,
      input int               dst_offset,
      input bit [P_NUM_CHIPS-1:0] pcs_err_en,
      input bit [15:0]        pcs_err_mask,
      input bit [P_NUM_CHIPS-1:0] mem_err_en,
      input bit [143:0]       mem_err_mask,
      input bit               use_east_sram
    );
      dragonfly_8chip_seq_item it;

      // Cycle 0: Issue MEM_READ_WEST (and optional MEM_READ_EAST) across all 8 chips
      it = make_base_item(ph);
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        it.chip_imem_vliw_bundle[c][SLICE_MEM_W] = tb_vliw_mem_read_w(sram_addr);
        if (use_east_sram) begin
          it.chip_imem_vliw_bundle[c][SLICE_MEM_E] = tb_vliw_mem_read_e(sram_addr);
        end
      end
      emit_item(it);

      // Cycle 1: SRAM read pipeline outputs onto stream fabric (ECC active here!)
      it = make_base_item(ph);
      it.mem_err_inject_en   = mem_err_en;
      it.mem_err_inject_mask = mem_err_mask;
      emit_item(it);

      // Cycle 2: Issue NIM_SEND on Hop 0 across all 8 chips
      it = make_base_item(ph);
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        bit [2:0] req_d = 3'((c + dst_offset) & 7);
        it.chip_imem_vliw_bundle[c][SLICE_NIM] = tb_vliw_nim_send(req_d);
      end
      emit_item(it);

      // Cycle 3: C2C TX valid asserts on all 8 chips; inject optional PCS CRC-16 error
      it = make_base_item(ph);
      it.pcs_err_inject_en   = pcs_err_en;
      it.pcs_err_inject_mask = pcs_err_mask;
      emit_item(it);

      // Cycles 4..7: Allow 1-cycle link delay + Go-Back-N NACK & replay + RealSync deskew release
      emit_idle_cycles(ph, 4);
    endtask

    virtual task body();
      dragonfly_8chip_seq_item it;

      // =======================================================================
      // PHASE 0 (~520 cycles):
      //   Host DMA Broadcast & Unicast Preloads across all 8 chips & 4 targets
      //   (IMEM, SRAM_WEST, SRAM_EAST, BCAST_BOTH) + VLIW Stall & Parity Errors
      // =======================================================================
      cur_icu_en     = 8'h00;
      cur_pcs_en     = 1'b0;
      cur_pcs_scram  = 1'b1;
      cur_flight_cyc = 16'd4;

      // Broadcast preload across all 4 DMA targets
      dma_transfer_word(0, 1'b1, 3'd0, 2'b00, 3'd0, 16'd0, 128'h0, 1'b0, 1'b0);
      dma_transfer_word(0, 1'b1, 3'd0, 2'b01, 3'd0, 16'd8, 128'h1111_2222_3333_4444_5555_6666_7777_8888, 1'b1, 1'b1);
      dma_transfer_word(0, 1'b1, 3'd0, 2'b10, 3'd0, 16'd8, 128'h8888_7777_6666_5555_4444_3333_2222_1111, 1'b1, 1'b1);
      dma_transfer_word(0, 1'b1, 3'd0, 2'b11, 3'd0, 16'd9, 128'hCAFE_BABE_DEAD_BEEF_0123_4567_89AB_CDEF, 1'b1, 1'b1);

      // Per-chip unicast preload of rows 0..7 across all 8 chips (West, East, BcastBoth, IMEM)
      for (int row = 0; row < 8; row++) begin
        for (int c = 0; c < P_NUM_CHIPS; c++) begin
          bit [127:0] sig = {16{8'((c + 1) + (row * 16))}};
          bit [1:0]   tgt = (row < 4) ? 2'b01 :
                            (row == 4) ? 2'b10 :
                            (row == 5) ? 2'b11 :
                            (row == 6) ? 2'b00 : 2'b01;
          dma_transfer_word(0, 1'b0, 3'(c), tgt, 3'd0, 16'(row), sig, (c[0] ^ row[0]), (c == row));
        end
      end

      // Re-ensure row 0..3 in SRAM_WEST on all 8 chips hold deterministic per-chip signatures
      for (int row = 0; row < 4; row++) begin
        for (int c = 0; c < P_NUM_CHIPS; c++) begin
          bit [127:0] sig = {16{8'((c + 1) + (row * 16))}};
          dma_transfer_word(0, 1'b0, 3'(c), 2'b01, 3'd0, 16'(row), sig, 1'b0, 1'b0);
        end
      end

      // =======================================================================
      // PHASE 1 (~120 cycles):
      //   PCS 64B/66B Link Training FSM (RESET -> TS1 -> TS2 -> LOCK -> ACTIVE
      //   -> RETRAIN -> TS1 -> TS2 -> LOCK -> ACTIVE) across all 8 chips
      // =======================================================================
      for (int scram = 0; scram < 2; scram++) begin
        cur_pcs_scram = scram[0];
        cur_pcs_en = 1'b0; cur_ts1 = 1'b0; cur_ts2 = 1'b0; cur_dsk = 1'b0; cur_retrain = 1'b0;
        emit_idle_cycles(1, 6);
        cur_pcs_en = 1'b1; emit_idle_cycles(1, 6);
        cur_ts1    = 1'b1; emit_idle_cycles(1, 6);
        cur_ts2    = 1'b1; emit_idle_cycles(1, 6);
        cur_dsk    = 1'b1; emit_idle_cycles(1, 10);
        cur_retrain= 1'b1; emit_idle_cycles(1, 2);
        cur_retrain= 1'b0; emit_idle_cycles(1, 14);
      end
      cur_pcs_scram = 1'b1;
      cur_icu_en    = 8'hFF;

      // =======================================================================
      // PHASE 2 (~960 cycles):
      //   All 4 Dragonfly Collective Routing Modes across all 8 chips:
      //   00=DIRECT_CROSSBAR, 01=BIDIR_RING, 10=UGAL_ADAPTIVE, 11=MOE_BUTTERFLY
      // =======================================================================
      // 2A. Mode 00: Direct Crossbar full-mesh permutations (offsets 1..7)
      cur_route_mode = 2'b00; cur_cong_mask = 8'h00; cur_link_dly = 8'h00;
      for (int off = 1; off < 8; off++) begin
        for (int row = 0; row < 4; row++) begin
          run_collective_wave(2, 16'(row), off, 8'h00, 16'h0000, 8'h00, '0, 1'b0);
        end
      end

      // 2B. Mode 01: 8-Chip Bidirectional Ring (Eastward & Westward)
      cur_route_mode = 2'b01;
      for (int dir = 0; dir < 2; dir++) begin
        cur_ring_west = dir[0];
        for (int step = 0; step < 8; step++) begin
          run_collective_wave(2, 16'(step & 3), dir ? 7 : 1, 8'h00, 16'h0000, 8'h00, '0, 1'b0);
        end
      end

      // 2C. Mode 10: UGAL Adaptive Routing across randomized congestion_mask_i[7:0]
      cur_route_mode = 2'b10;
      for (int m = 0; m < 16; m++) begin
        cur_cong_mask = (m == 0) ? 8'h00 :
                        (m == 1) ? 8'hFF :
                        (m == 2) ? 8'h0F :
                        (m == 3) ? 8'hF0 :
                        (m == 4) ? 8'h55 :
                        (m == 5) ? 8'hAA : 8'((m * 29) ^ 8'h3C);
        run_collective_wave(2, 16'(m & 3), 4, 8'h00, 16'h0000, 8'h00, '0, 1'b0);
        run_collective_wave(2, 16'((m + 1) & 3), (m % 7) + 1, 8'h00, 16'h0000, 8'h00, '0, 1'b0);
      end

      // 2D. Mode 11: MoE AllToAll Butterfly Permutation across stages 1..7
      cur_route_mode = 2'b11; cur_cong_mask = 8'h00;
      for (int stg = 1; stg <= 7; stg++) begin
        cur_bstage = 3'(stg);
        for (int row = 0; row < 4; row++) begin
          run_collective_wave(2, 16'(row), stg, 8'h00, 16'h0000, 8'h00, '0, 1'b0);
        end
      end

      // =======================================================================
      // PHASE 3 (~960 cycles):
      //   Plesiochronous Link Skew Injection (link_delay_en_i[7:0]) &
      //   PCS CRC-16 Single/Multi-Bit Error Injection + Go-Back-N Replay Recovery
      // =======================================================================
      for (int mode = 0; mode < 4; mode++) begin
        cur_route_mode = 2'(mode);
        cur_ring_west  = mode[0];
        cur_bstage     = 3'((mode * 2) + 1);
        cur_cong_mask  = (mode == 2) ? 8'hFF : 8'h00;

        // Sweep link_delay_en_i masks (0x00, 0xFF, 0x55, 0xAA, and per-chip 1<<c)
        for (int c = 0; c < P_NUM_CHIPS; c++) begin
          cur_link_dly = (c == 0) ? 8'hFF :
                         (c == 1) ? 8'h55 :
                         (c == 2) ? 8'hAA : (8'd1 << c);
          // Single-bit CRC-16 error injection on chip c + Go-Back-N replay recovery
          run_collective_wave(3, 16'(c & 3), 3, (8'd1 << c), 16'h0001 << (c * 2), 8'h00, '0, 1'b0);
          // Multi-bit CRC-16 error injection across all 8 chips + Go-Back-N replay recovery
          run_collective_wave(3, 16'((c + 1) & 3), 5, 8'hFF, 16'h8005 ^ (16'h0101 * c), 8'h00, '0, 1'b0);
        end
      end
      cur_link_dly = 8'h00;

      // =======================================================================
      // PHASE 4 (~1,120 cycles):
      //   SRAM SECDED Single-Bit (SEC) & Double-Bit (DED) ECC Error Injection
      //   across all 8 chips + Concurrent Dragonfly Routing up to >3,500 cycles
      // =======================================================================
      for (int w = 0; w < 150; w++) begin
        int chip_sel    = w & 7;
        int bit_pos     = (w * 2) % 72;
        bit is_double   = w[0];
        bit [143:0] msk = is_double ? ((144'd1 << bit_pos) | (144'd1 << ((bit_pos + 1) % 72)))
                                    : (144'd1 << bit_pos);
        cur_cov_ecc_kind = is_double ? 2'd2 : 2'd1;
        cur_route_mode   = 2'(w & 3);
        cur_ring_west    = w[1];
        cur_bstage       = 3'(1 + (w % 7));
        cur_cong_mask    = (cur_route_mode == 2'b10) ? 8'hFF : 8'h00;
        cur_link_dly     = w[2] ? 8'hFF : 8'h00;

        run_collective_wave(4, 16'(w & 3), 1 + (w % 7), 8'h00, 16'h0000,
                            (w >= 64) ? 8'hFF : (8'd1 << chip_sel), msk, w[1]);
        cur_cov_ecc_kind = 2'd0;
      end
      emit_idle_cycles(4, 16);
    endtask
  endclass : dragonfly_8chip_sequence

  // ---------------------------------------------------------------------------
  // 5. UVM Driver
  // ---------------------------------------------------------------------------
  class dragonfly_8chip_driver extends uvm_driver #(dragonfly_8chip_seq_item);
    `uvm_component_utils(dragonfly_8chip_driver)

    virtual dragonfly_8chip_if vif;
    int unsigned driven = 0;

    function new(string name = "dragonfly_8chip_driver", uvm_component parent = null);
 super.new(name, parent);
 endfunction

 function void build_phase(uvm_phase phase);
 super.build_phase(phase);
 if (!uvm_config_db#(virtual dragonfly_8chip_if)::get(this, "", "vif", vif)) begin
 `uvm_fatal("NO_VIF", "Virtual interface dragonfly_8chip_if missing in dragonfly_8chip_driver")
 end
 endfunction

 task run_phase(uvm_phase phase);
 dragonfly_8chip_seq_item item;
 vif.sample_en = 1'b0;
 vif.rst_n = 1'b0;
 @(negedge vif.clk);
 vif.rst_n = 1'b1;
 @(negedge vif.clk);
 vif.rst_n = 1'b0;
 repeat (2) @(negedge vif.clk);

 forever begin
 seq_item_port.get_next_item(item);
 vif.rst_n = 1'b1;
 vif.sample_en = 1'b1;
 vif.tx_id = item.tx_id;
 vif.phase_id = item.phase_id;
 vif.cov_dma_target = item.cov_dma_target;
 vif.cov_ecc_kind = item.cov_ecc_kind;

 vif.chip_icu_enable_i = item.chip_icu_enable;
 vif.chip_imem_vliw_bundle_i = item.chip_imem_vliw_bundle;
 vif.global_cycle_i = item.global_cycle;
 vif.dma_target_chip_i = item.dma_target_chip;
 vif.dma_bcast_all_chips_i = item.dma_bcast_all_chips;
 vif.dma_vliw_sram_busy_i = item.dma_vliw_sram_busy;
 vif.dma_desc_push_valid_i = item.dma_desc_push_valid;
 vif.dma_desc_push_data_i = item.dma_desc_push_data;
 vif.dma_payload_valid_i = item.dma_payload_valid;
 vif.dma_payload_data_i = item.dma_payload_data;
 vif.dma_payload_parity_i = item.dma_payload_parity;
 vif.cluster_route_mode_i = item.cluster_route_mode;
 vif.ring_dir_west_i = item.ring_dir_west;
 vif.congestion_mask_i = item.congestion_mask;
 vif.butterfly_stage_i = item.butterfly_stage;
 vif.pcs_link_enable_i = item.pcs_link_enable;
 vif.pcs_scramble_en_i = item.pcs_scramble_en;
 vif.pcs_rx_ts1_seen_i = item.pcs_rx_ts1_seen;
 vif.pcs_rx_ts2_seen_i = item.pcs_rx_ts2_seen;
 vif.pcs_deskew_done_i = item.pcs_deskew_done;
 vif.pcs_retrain_req_i = item.pcs_retrain_req;
 vif.link_delay_en_i = item.link_delay_en;
 vif.expected_flight_cycles_i = item.expected_flight_cycles;
 vif.pcs_err_inject_en_i = item.pcs_err_inject_en;
 vif.pcs_err_inject_mask_i = item.pcs_err_inject_mask;
 vif.mem_err_inject_en_i = item.mem_err_inject_en;
 vif.mem_err_inject_mask_i = item.mem_err_inject_mask;

 @(negedge vif.clk);
 vif.sample_en = 1'b0;
 driven++;
 seq_item_port.item_done();
 end
 endtask
 endclass : dragonfly_8chip_driver

  // ---------------------------------------------------------------------------
  // 6. UVM Monitor & UVM Agent
  // ---------------------------------------------------------------------------
  class dragonfly_8chip_monitor extends uvm_monitor;
    `uvm_component_utils(dragonfly_8chip_monitor)

    virtual dragonfly_8chip_if vif;
    uvm_analysis_port #(dragonfly_8chip_seq_item) ap;
    int unsigned seen = 0;

    function new(string name = "dragonfly_8chip_monitor", uvm_component parent = null);
 super.new(name, parent);
 ap = new("ap", this);
 endfunction

 function void build_phase(uvm_phase phase);
 super.build_phase(phase);
 if (!uvm_config_db#(virtual dragonfly_8chip_if)::get(this, "", "vif", vif)) begin
 `uvm_fatal("NO_VIF", "Virtual interface dragonfly_8chip_if missing in dragonfly_8chip_monitor")
 end
 endfunction

 task run_phase(uvm_phase phase);
 forever begin
 @(negedge vif.clk);
 #1ns;
 if (vif.rst_n && vif.sample_en) begin
 dragonfly_8chip_seq_item item = dragonfly_8chip_seq_item::type_id::create("obs_item");
 item.tx_id = vif.tx_id;
 item.phase_id = vif.phase_id;
 item.cov_dma_target = vif.cov_dma_target;
 item.cov_ecc_kind = vif.cov_ecc_kind;

 item.chip_icu_enable = vif.chip_icu_enable_i;
 item.chip_imem_vliw_bundle = vif.chip_imem_vliw_bundle_i;
 item.global_cycle = vif.global_cycle_i;
 item.dma_target_chip = vif.dma_target_chip_i;
 item.dma_bcast_all_chips = vif.dma_bcast_all_chips_i;
 item.dma_vliw_sram_busy = vif.dma_vliw_sram_busy_i;
 item.dma_desc_push_valid = vif.dma_desc_push_valid_i;
 item.dma_desc_push_data = vif.dma_desc_push_data_i;
 item.dma_payload_valid = vif.dma_payload_valid_i;
 item.dma_payload_data = vif.dma_payload_data_i;
 item.dma_payload_parity = vif.dma_payload_parity_i;
 item.cluster_route_mode = vif.cluster_route_mode_i;
 item.ring_dir_west = vif.ring_dir_west_i;
 item.congestion_mask = vif.congestion_mask_i;
 item.butterfly_stage = vif.butterfly_stage_i;
 item.pcs_link_enable = vif.pcs_link_enable_i;
 item.pcs_scramble_en = vif.pcs_scramble_en_i;
 item.pcs_rx_ts1_seen = vif.pcs_rx_ts1_seen_i;
 item.pcs_rx_ts2_seen = vif.pcs_rx_ts2_seen_i;
 item.pcs_deskew_done = vif.pcs_deskew_done_i;
 item.pcs_retrain_req = vif.pcs_retrain_req_i;
 item.link_delay_en = vif.link_delay_en_i;
 item.expected_flight_cycles = vif.expected_flight_cycles_i;
 item.pcs_err_inject_en = vif.pcs_err_inject_en_i;
 item.pcs_err_inject_mask = vif.pcs_err_inject_mask_i;
 item.mem_err_inject_en = vif.mem_err_inject_en_i;
 item.mem_err_inject_mask = vif.mem_err_inject_mask_i;

 item.act_dma_desc_push_ready = vif.dma_desc_push_ready_o;
 item.act_dma_payload_ready = vif.dma_payload_ready_o;
 item.act_dma_busy = vif.dma_busy_o;
 item.act_dma_window_stall = vif.dma_window_stall_o;
 item.act_dma_parity_err = vif.dma_parity_err_o;
 item.act_dma_done_irq = vif.dma_done_irq_o;
 item.act_dma_completed_desc_cnt = vif.dma_completed_desc_cnt_o;
 item.act_dma_beats_transferred = vif.dma_beats_transferred_o;
 item.act_cluster_all_halted = vif.cluster_all_halted_o;
 item.act_cluster_any_barrier = vif.cluster_any_barrier_o;
 item.act_cluster_pcs_link_up = vif.cluster_pcs_link_up_o;
 item.act_cluster_crc16_err = vif.cluster_crc16_err_o;
 item.act_cluster_realsync_err = vif.cluster_realsync_err_o;
 item.act_cluster_ecc_single_err = vif.cluster_ecc_single_err_o;
 item.act_cluster_ecc_double_err = vif.cluster_ecc_double_err_o;
 item.act_cluster_c2c_tx_valid = vif.cluster_c2c_tx_valid_o;
 item.act_cluster_deskew_release = vif.cluster_deskew_release_o;
 item.act_cluster_routed_dst = vif.cluster_routed_dst_o;
 item.act_cluster_nim_rx_data = vif.cluster_nim_rx_data_o;

 seen++;
 ap.write(item);
 end
 end
 endtask
 endclass : dragonfly_8chip_monitor

 class dragonfly_8chip_agent extends uvm_agent;
 `uvm_component_utils(dragonfly_8chip_agent)
 dragonfly_8chip_sequencer sequencer;
 dragonfly_8chip_driver driver;
 dragonfly_8chip_monitor monitor;

 function new(string name = "dragonfly_8chip_agent", uvm_component parent = null);
 super.new(name, parent);
 endfunction

 function void build_phase(uvm_phase phase);
 super.build_phase(phase);
 sequencer = dragonfly_8chip_sequencer::type_id::create("sequencer", this);
 driver = dragonfly_8chip_driver::type_id::create("driver", this);
 monitor = dragonfly_8chip_monitor::type_id::create("monitor", this);
 endfunction

 function void connect_phase(uvm_phase phase);
 super.connect_phase(phase);
 driver.seq_item_port.connect(sequencer.seq_item_export);
 endfunction
 endclass : dragonfly_8chip_agent

  // ---------------------------------------------------------------------------
  // 7. Functional Coverage Subscriber (IEEE 1800.2-2020 uvm_subscriber)
  // ---------------------------------------------------------------------------
  class dragonfly_8chip_cov_subscriber extends uvm_subscriber #(dragonfly_8chip_seq_item);
    `uvm_component_utils(dragonfly_8chip_cov_subscriber)

    bit [2:0]  cg_phase;
    bit [1:0]  cg_route_mode;
    bit        cg_ring_west;
    bit [2:0]  cg_bstage;
    bit        cg_congested_any;
    bit        cg_pcs_link_up;
    bit        cg_pcs_scram;
    bit        cg_link_delay_any;
    bit        cg_crc16_err_any;
    bit        cg_ecc_sec_any;
    bit        cg_ecc_ded_any;
    bit [1:0]  cg_dma_tgt;
    bit        cg_dma_bcast;
    bit [2:0]  cg_dma_chip;
    bit        cg_dma_stall;
    bit        cg_dma_perr;

    covergroup dragonfly_8chip_cg;
      option.per_instance = 1;

      cp_phase: coverpoint cg_phase {
        bins p0_dma_preload = {3'd0};
        bins p1_pcs_train   = {3'd1};
        bins p2_dragonfly   = {3'd2};
        bins p3_skew_crc16  = {3'd3};
        bins p4_secded_ecc  = {3'd4};
      }
      cp_route_mode: coverpoint cg_route_mode {
        bins direct_crossbar = {2'b00};
        bins bidir_ring      = {2'b01};
        bins ugal_adaptive   = {2'b10};
        bins moe_butterfly   = {2'b11};
      }
      cp_ring_west: coverpoint cg_ring_west {
        bins east_ring = {1'b0};
        bins west_ring = {1'b1};
      }
      cp_bstage: coverpoint cg_bstage {
        bins stg1_7[] = {[3'd1:3'd7]};
      }
      cp_congested: coverpoint cg_congested_any {
        bins uncongested = {1'b0};
        bins congested   = {1'b1};
      }
      cp_pcs_link_up: coverpoint cg_pcs_link_up {
        bins down = {1'b0};
        bins up   = {1'b1};
      }
      cp_pcs_scram: coverpoint cg_pcs_scram {
        bins scram_off = {1'b0};
        bins scram_on  = {1'b1};
      }
      cp_link_delay: coverpoint cg_link_delay_any {
        bins zero_delay = {1'b0};
        bins dly_active = {1'b1};
      }
      cp_crc16_err: coverpoint cg_crc16_err_any {
        bins clean   = {1'b0};
        bins crc_err = {1'b1};
      }
      cp_ecc_sec: coverpoint cg_ecc_sec_any {
        bins no_sec  = {1'b0};
        bins sec_hit = {1'b1};
      }
      cp_ecc_ded: coverpoint cg_ecc_ded_any {
        bins no_ded  = {1'b0};
        bins ded_hit = {1'b1};
      }
      cp_dma_tgt: coverpoint cg_dma_tgt {
        bins imem       = {2'b00};
        bins sram_west  = {2'b01};
        bins sram_east  = {2'b10};
        bins bcast_both = {2'b11};
      }
      cp_dma_bcast: coverpoint cg_dma_bcast {
        bins unicast   = {1'b0};
        bins broadcast = {1'b1};
      }
      cp_dma_chip: coverpoint cg_dma_chip {
        bins chip0_7[] = {[3'd0:3'd7]};
      }
      cp_dma_stall: coverpoint cg_dma_stall {
        bins no_stall = {1'b0};
        bins stalled  = {1'b1};
      }
      cp_dma_perr: coverpoint cg_dma_perr {
        bins parity_ok  = {1'b0};
        bins parity_err = {1'b1};
      }

      cx_route_x_delay: cross cp_route_mode, cp_link_delay;
      cx_route_x_crc16: cross cp_route_mode, cp_crc16_err;
    endgroup

    function new(string name = "dragonfly_8chip_cov_subscriber", uvm_component parent = null);
 super.new(name, parent);
 dragonfly_8chip_cg = new();
 endfunction

 virtual function void write(dragonfly_8chip_seq_item t);
 cg_phase = t.phase_id[2:0];
 cg_route_mode = t.cluster_route_mode;
 cg_ring_west = t.ring_dir_west;
 cg_bstage = t.butterfly_stage;
 cg_congested_any = (|t.congestion_mask);
 cg_pcs_link_up = (&t.act_cluster_pcs_link_up);
 cg_pcs_scram = t.pcs_scramble_en;
 cg_link_delay_any = (|t.link_delay_en);
 cg_crc16_err_any = (|t.act_cluster_crc16_err);
 cg_ecc_sec_any = (|t.act_cluster_ecc_single_err);
 cg_ecc_ded_any = (|t.act_cluster_ecc_double_err);
 cg_dma_tgt = t.cov_dma_target;
 cg_dma_bcast = t.dma_bcast_all_chips;
 cg_dma_chip = t.dma_target_chip;
 cg_dma_stall = (t.act_dma_window_stall === 1'b1);
 cg_dma_perr = (t.act_dma_parity_err === 1'b1);
 dragonfly_8chip_cg.sample();
 endfunction
 endclass : dragonfly_8chip_cov_subscriber

  // ---------------------------------------------------------------------------
  // 8. C++17 DPI-C Cycle-Exact UVM Scoreboard
  // ---------------------------------------------------------------------------
  class dragonfly_8chip_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(dragonfly_8chip_scoreboard)

    uvm_analysis_imp #(dragonfly_8chip_seq_item, dragonfly_8chip_scoreboard) imp;

    int unsigned checked_cycles       = 0;
    int unsigned mismatches           = 0;
    int unsigned dma_checks           = 0;
    int unsigned route_checks         = 0;
    int unsigned pcs_checks           = 0;
    int unsigned ecc_checks           = 0;
    int unsigned c2c_payload_checks   = 0;
    int unsigned dma_stall_events     = 0;
    int unsigned dma_perr_events      = 0;
    int unsigned crc16_err_events     = 0;
    int unsigned gbn_replay_recoveries= 0;
    int unsigned ecc_sec_events       = 0;
    int unsigned ecc_ded_events       = 0;
    int unsigned deskew_rel_events    = 0;

    // Pipeline tracking for C2C payload & Go-Back-N replay verification
    bit [15:0]   pend_sram_row [P_NUM_CHIPS];
    bit          pend_was_ded  [P_NUM_CHIPS];
    bit [P_NUM_CHIPS-1:0] expect_dly_rx_valid;
    bit [2:0]             expect_dly_rx_dst  [P_NUM_CHIPS];
    bit [15:0]            expect_dly_rx_row  [P_NUM_CHIPS];
    bit                   expect_dly_was_ded [P_NUM_CHIPS];

    bit [P_NUM_CHIPS-1:0] expect_gbn_0dly_valid;
    bit [2:0]             expect_gbn_0dly_dst [P_NUM_CHIPS];
    bit [15:0]            expect_gbn_0dly_row [P_NUM_CHIPS];

    bit [P_NUM_CHIPS-1:0] expect_gbn_1dly_s1, expect_gbn_1dly_s2, expect_gbn_1dly_s3;
    bit [2:0]             expect_gbn_1dly_dst_s1 [P_NUM_CHIPS];
    bit [2:0]             expect_gbn_1dly_dst_s2 [P_NUM_CHIPS];
    bit [2:0]             expect_gbn_1dly_dst_s3 [P_NUM_CHIPS];
    bit [15:0]            expect_gbn_1dly_row_s1 [P_NUM_CHIPS];
    bit [15:0]            expect_gbn_1dly_row_s2 [P_NUM_CHIPS];
    bit [15:0]            expect_gbn_1dly_row_s3 [P_NUM_CHIPS];

    function new(string name = "dragonfly_8chip_scoreboard", uvm_component parent = null);
 super.new(name, parent);
 imp = new("imp", this);
 endfunction

 function void build_phase(uvm_phase phase);
 super.build_phase(phase);
 dpi_dragonfly_8chip_reset();
 expect_dly_rx_valid = '0;
 expect_gbn_0dly_valid = '0;
 expect_gbn_1dly_s1 = '0;
 expect_gbn_1dly_s2 = '0;
 expect_gbn_1dly_s3 = '0;
 for (int c = 0; c < P_NUM_CHIPS; c++) begin
 pend_sram_row[c] = 16'd0;
 pend_was_ded[c] = 1'b0;
 end
 endfunction

    virtual function void write(dragonfly_8chip_seq_item item);
      int unsigned vliw_w_busy = 0, vliw_e_busy = 0;
      int unsigned mem_rd_w = 0, mem_rd_e = 0;
      int unsigned nim_send_val = 0, nim_send_dst_packed = 0;
      int unsigned exp_dma_desc_rdy, exp_dma_pay_rdy, exp_dma_busy, exp_dma_stall;
      int unsigned exp_dma_perr, exp_dma_irq, exp_dma_desc_cnt, exp_dma_beats_cnt;
      int unsigned exp_pcs_link_up, exp_routed_packed, exp_ecc_s, exp_ecc_d;

      checked_cycles++;

      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        bit [3:0] mw_op = item.chip_imem_vliw_bundle[c][SLICE_MEM_W][135:132];
        bit [3:0] me_op = item.chip_imem_vliw_bundle[c][SLICE_MEM_E][135:132];
        bit [3:0] nm_op = item.chip_imem_vliw_bundle[c][SLICE_NIM][119:116];
        if (item.chip_icu_enable[c] && (mw_op != MEM_NOP)) begin
          vliw_w_busy |= (1 << c);
          if ((mw_op == MEM_READ_WEST) || (mw_op == MEM_READ_EAST)) begin
            mem_rd_w |= (1 << c);
            pend_sram_row[c] = item.chip_imem_vliw_bundle[c][SLICE_MEM_W][71:56];
            pend_was_ded[c]  = 1'b0;
          end
        end
        if (item.chip_icu_enable[c] && (me_op != MEM_NOP)) begin
          vliw_e_busy |= (1 << c);
          if ((me_op == MEM_READ_WEST) || (me_op == MEM_READ_EAST)) mem_rd_e |= (1 << c);
        end
        if (item.chip_icu_enable[c] && (nm_op == NIM_SEND)) begin
          nim_send_val        |= (1 << c);
          nim_send_dst_packed |= ((item.chip_imem_vliw_bundle[c][SLICE_NIM][18:16] & 3'h7) << (c * 3));
        end
      end

      dpi_dragonfly_8chip_step(
        item.global_cycle, item.dma_target_chip, item.dma_bcast_all_chips,
        item.dma_vliw_sram_busy, vliw_w_busy, vliw_e_busy,
        item.dma_desc_push_valid, item.dma_desc_push_data,
        item.dma_payload_valid, item.dma_payload_data, item.dma_payload_parity,
        item.cluster_route_mode, item.ring_dir_west, item.congestion_mask, item.butterfly_stage,
        item.pcs_link_enable, item.pcs_rx_ts1_seen, item.pcs_rx_ts2_seen,
        item.pcs_deskew_done, item.pcs_retrain_req,
        nim_send_val, nim_send_dst_packed, mem_rd_w, mem_rd_e,
        item.mem_err_inject_en, item.mem_err_inject_mask,
        exp_dma_desc_rdy, exp_dma_pay_rdy, exp_dma_busy, exp_dma_stall,
        exp_dma_perr, exp_dma_irq, exp_dma_desc_cnt, exp_dma_beats_cnt,
        exp_pcs_link_up, exp_routed_packed, exp_ecc_s, exp_ecc_d
      );

            // 1. Check Cluster Host DMA outputs
      dma_checks++;
      if ((item.act_dma_desc_push_ready    !== exp_dma_desc_rdy[0])  ||
          (item.act_dma_payload_ready      !== exp_dma_pay_rdy[0])   ||
          (item.act_dma_busy               !== exp_dma_busy[0])      ||
          (item.act_dma_window_stall       !== exp_dma_stall[0])     ||
          (item.act_dma_parity_err         !== exp_dma_perr[0])      ||
          (item.act_dma_done_irq           !== exp_dma_irq[0])       ||
          (item.act_dma_completed_desc_cnt !== exp_dma_desc_cnt[7:0])||
          (item.act_dma_beats_transferred  !== exp_dma_beats_cnt[15:0])) begin
        mismatches++;
        `uvm_error("SB_DMA_MISMATCH", $sformatf(
          "tx=%0d DMA mismatch: cnt=%0d/%0d beats=%0d/%0d stall=%b/%b perr=%b/%b",
          item.tx_id, item.act_dma_completed_desc_cnt, exp_dma_desc_cnt,
          item.act_dma_beats_transferred, exp_dma_beats_cnt,
          item.act_dma_window_stall, exp_dma_stall[0],
          item.act_dma_parity_err, exp_dma_perr[0]))
      end
      if (item.act_dma_window_stall === 1'b1) dma_stall_events++;
      if (item.act_dma_parity_err   === 1'b1) dma_perr_events++;

      // 2. Check PCS Link Training state
      pcs_checks++;
      if (item.act_cluster_pcs_link_up !== exp_pcs_link_up[7:0]) begin
        mismatches++;
        `uvm_error("SB_PCS_MISMATCH", $sformatf(
          "tx=%0d PCS link_up=%b exp=%b", item.tx_id, item.act_cluster_pcs_link_up, exp_pcs_link_up[7:0]))
      end

      // 3. Check 8-Chip Dragonfly Routed Destinations & SECDED ECC Telemetry
      route_checks++;
      ecc_checks++;
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        bit [2:0] exp_d = exp_routed_packed[c*3 +: 3];
        if (item.act_cluster_routed_dst[c] !== exp_d) begin
          mismatches++;
          `uvm_error("SB_ROUTE_MISMATCH", $sformatf(
            "tx=%0d chip=%0d mode=%0d routed_dst=%0d exp=%0d",
            item.tx_id, c, item.cluster_route_mode, item.act_cluster_routed_dst[c], exp_d))
        end
        if (exp_ecc_d[c]) pend_was_ded[c] = 1'b1;
      end

      if ((item.act_cluster_ecc_single_err !== exp_ecc_s[7:0]) ||
          (item.act_cluster_ecc_double_err !== exp_ecc_d[7:0])) begin
        mismatches++;
        `uvm_error("SB_ECC_MISMATCH", $sformatf(
          "tx=%0d ECC mismatch: sec=%b/%b ded=%b/%b",
          item.tx_id, item.act_cluster_ecc_single_err, exp_ecc_s[7:0],
          item.act_cluster_ecc_double_err, exp_ecc_d[7:0]))
      end
      if (|item.act_cluster_ecc_single_err) ecc_sec_events++;
      if (|item.act_cluster_ecc_double_err) ecc_ded_events++;
      if (|item.act_cluster_crc16_err)      crc16_err_events++;
      if (|item.act_cluster_deskew_release) deskew_rel_events++;

      // 4. Check C2C Payload Delivery (Delayed & Go-Back-N Replayed Arrivals)
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        if (expect_dly_rx_valid[c] && !expect_dly_was_ded[c]) begin
          bit [2:0] d = expect_dly_rx_dst[c];
          c2c_payload_checks++;
          if (dpi_check_c2c_rx_from_sram(c, 0, expect_dly_rx_row[c], item.act_cluster_nim_rx_data[d]) == 0) begin
            mismatches++;
            `uvm_error("SB_DLY_PAYLOAD", $sformatf("tx=%0d delayed C2C payload mismatch src=%0d dst=%0d", item.tx_id, c, d))
          end
        end
        if (expect_gbn_0dly_valid[c]) begin
          bit [2:0] d = expect_gbn_0dly_dst[c];
          c2c_payload_checks++;
          gbn_replay_recoveries++;
          if (dpi_check_c2c_rx_from_sram(c, 0, expect_gbn_0dly_row[c], item.act_cluster_nim_rx_data[d]) == 0) begin
            mismatches++;
            `uvm_error("SB_GBN0_PAYLOAD", $sformatf("tx=%0d GBN 0-dly replay mismatch src=%0d dst=%0d", item.tx_id, c, d))
          end
        end
        if (expect_gbn_1dly_s3[c]) begin
          bit [2:0] d = expect_gbn_1dly_dst_s3[c];
          c2c_payload_checks++;
          gbn_replay_recoveries++;
          if (dpi_check_c2c_rx_from_sram(c, 0, expect_gbn_1dly_row_s3[c], item.act_cluster_nim_rx_data[d]) == 0) begin
            mismatches++;
            `uvm_error("SB_GBN1_PAYLOAD", $sformatf("tx=%0d GBN 1-dly replay mismatch src=%0d dst=%0d", item.tx_id, c, d))
          end
        end
      end
      // Shift multi-cycle delay/replay expectation pipelines
      expect_gbn_1dly_s3  = expect_gbn_1dly_s2;
      expect_gbn_1dly_s2  = expect_gbn_1dly_s1;
      expect_gbn_1dly_s1  = '0;
      expect_gbn_0dly_valid = '0;
      expect_dly_rx_valid = '0;
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        expect_gbn_1dly_dst_s3[c] = expect_gbn_1dly_dst_s2[c];
        expect_gbn_1dly_row_s3[c] = expect_gbn_1dly_row_s2[c];
        expect_gbn_1dly_dst_s2[c] = expect_gbn_1dly_dst_s1[c];
        expect_gbn_1dly_row_s2[c] = expect_gbn_1dly_row_s1[c];
      end

      // Check current-cycle C2C TX events (lowest source index s wins switch port d)
      begin
        bit [P_NUM_CHIPS-1:0] dst_claimed = '0;
        for (int c = 0; c < P_NUM_CHIPS; c++) begin
          if (item.act_cluster_c2c_tx_valid[c] === 1'b1) begin
            bit [2:0] d      = exp_routed_packed[c*3 +: 3];
            bit       has_err= item.pcs_err_inject_en[c] && (item.pcs_err_inject_mask != 16'h0000);
            bit       has_dly= item.link_delay_en[c];
            bit       won_dst= !dst_claimed[d];
            if (!has_dly) dst_claimed[d] = 1'b1;
            if (!has_dly && !has_err && !pend_was_ded[c] && won_dst) begin
              c2c_payload_checks++;
              if (dpi_check_c2c_rx_from_sram(c, 0, pend_sram_row[c], item.act_cluster_nim_rx_data[d]) == 0) begin
                mismatches++;
                `uvm_error("SB_C2C_PAYLOAD", $sformatf("tx=%0d C2C payload mismatch src=%0d dst=%0d", item.tx_id, c, d))
              end
          end else if (has_dly && !has_err) begin
            expect_dly_rx_valid[c] = 1'b1;
            expect_dly_rx_dst[c]   = d;
            expect_dly_rx_row[c]   = pend_sram_row[c];
            expect_dly_was_ded[c]  = pend_was_ded[c];
          end else if (!has_dly && has_err) begin
            expect_gbn_0dly_valid[c] = 1'b1;
            expect_gbn_0dly_dst[c]   = d;
            expect_gbn_0dly_row[c]   = pend_sram_row[c];
          end else if (has_dly && has_err) begin
            expect_gbn_1dly_s1[c]     = 1'b1;
            expect_gbn_1dly_dst_s1[c] = d;
            expect_gbn_1dly_row_s1[c] = pend_sram_row[c];
          end
        end
      end
      end
    endfunction
  endclass : dragonfly_8chip_scoreboard

  // ---------------------------------------------------------------------------
  // 9. UVM Environment & UVM Test
  // ---------------------------------------------------------------------------
  class dragonfly_8chip_env extends uvm_env;
    `uvm_component_utils(dragonfly_8chip_env)

    dragonfly_8chip_agent          agent;
    dragonfly_8chip_cov_subscriber cov_sub;
    dragonfly_8chip_scoreboard     scoreboard;

    function new(string name = "dragonfly_8chip_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = dragonfly_8chip_agent::type_id::create("agent", this);
      cov_sub    = dragonfly_8chip_cov_subscriber::type_id::create("cov_sub", this);
      scoreboard = dragonfly_8chip_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.monitor.ap.connect(cov_sub.analysis_export);
      agent.monitor.ap.connect(scoreboard.imp);
    endfunction
  endclass : dragonfly_8chip_env
  class dragonfly_8chip_test extends uvm_test;
    `uvm_component_utils(dragonfly_8chip_test)

    dragonfly_8chip_env env;

    function new(string name = "dragonfly_8chip_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = dragonfly_8chip_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      dragonfly_8chip_sequence seq = dragonfly_8chip_sequence::type_id::create("seq");
      phase.raise_objection(this);
      seq.start(env.agent.sequencer);
      repeat (2) @(negedge env.agent.driver.vif.clk);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      int unsigned dpi_calls;
      real func_cov;
      bit pass_gate;
      int fd;
      super.report_phase(phase);

      dpi_calls = dpi_get_calls();
      func_cov  = env.cov_sub.dragonfly_8chip_cg.get_inst_coverage();
      pass_gate = (env.agent.driver.driven >= 3000) &&
                  (env.agent.monitor.seen == env.agent.driver.driven) &&
                  (env.scoreboard.checked_cycles == env.agent.driver.driven) &&
                  (dpi_calls == env.agent.driver.driven) &&
                  (env.scoreboard.mismatches == 0) &&
                  (env.scoreboard.dma_stall_events > 0) &&
                  (env.scoreboard.dma_perr_events > 0) &&
                  (env.scoreboard.crc16_err_events > 0) &&
                  (env.scoreboard.gbn_replay_recoveries > 0) &&
                  (env.scoreboard.ecc_sec_events > 0) &&
                  (env.scoreboard.ecc_ded_events > 0) &&
                  (func_cov == 100.0);

      fd = $fopen("dragonfly_8chip_summary.json", "w");
      if (fd == 0) `uvm_fatal("JSON_OPEN", "Cannot open dragonfly_8chip_summary.json")
      $fdisplay(fd, "{");
      $fdisplay(fd, "  \"suite\": \"uvm_dragonfly_8chip\",");
      $fdisplay(fd, "  \"dut\": \"groq_dragonfly_8chip_cluster\",");
      $fdisplay(fd, "  \"driven_cycles\": %0d,", env.agent.driver.driven);
      $fdisplay(fd, "  \"observed_cycles\": %0d,", env.agent.monitor.seen);
      $fdisplay(fd, "  \"checked_cycles\": %0d,", env.scoreboard.checked_cycles);
      $fdisplay(fd, "  \"dpi_calls\": %0d,", dpi_calls);
      $fdisplay(fd, "  \"c2c_payload_checks\": %0d,", env.scoreboard.c2c_payload_checks);
      $fdisplay(fd, "  \"dma_window_stall_events\": %0d,", env.scoreboard.dma_stall_events);
      $fdisplay(fd, "  \"dma_parity_err_events\": %0d,", env.scoreboard.dma_perr_events);
      $fdisplay(fd, "  \"crc16_err_events\": %0d,", env.scoreboard.crc16_err_events);
      $fdisplay(fd, "  \"gbn_replay_recoveries\": %0d,", env.scoreboard.gbn_replay_recoveries);
      $fdisplay(fd, "  \"ecc_sec_events\": %0d,", env.scoreboard.ecc_sec_events);
      $fdisplay(fd, "  \"ecc_ded_events\": %0d,", env.scoreboard.ecc_ded_events);
      $fdisplay(fd, "  \"deskew_release_events\": %0d,", env.scoreboard.deskew_rel_events);
      $fdisplay(fd, "  \"mismatches\": %0d,", env.scoreboard.mismatches);
      $fdisplay(fd, "  \"functional_coverage_pct\": %0.2f,", func_cov);
      $fdisplay(fd, "  \"pass\": %0d", pass_gate);
      $fdisplay(fd, "}");
      $fclose(fd);

      dpi_set_status(pass_gate ? 0 : 1);
      if (!pass_gate) begin
        `uvm_fatal("UVM_DRAGONFLY_8CHIP_FAIL", $sformatf(
          "Gate failed: driven=%0d checked=%0d mismatches=%0d cov=%0.2f%%",
          env.agent.driver.driven, env.scoreboard.checked_cycles,
          env.scoreboard.mismatches, func_cov))
      end else begin
        `uvm_info("UVM_DRAGONFLY_8CHIP_PASS", $sformatf(
          "PASS: %0d cycles checked via C++17 DPI-C reference, 0 mismatches, 100.00%% functional coverage",
          env.scoreboard.checked_cycles), UVM_LOW)
      end
    endfunction
  endclass : dragonfly_8chip_test

endpackage : uvm_dragonfly_8chip_pkg

`endif // UVM_DRAGONFLY_8CHIP_PKG_SV
