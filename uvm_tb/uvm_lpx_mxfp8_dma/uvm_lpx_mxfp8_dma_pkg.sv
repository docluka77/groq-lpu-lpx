// =============================================================================
// File: uvm_tb/uvm_lpx_mxfp8_dma/uvm_lpx_mxfp8_dma_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Accellera IEEE 1800.2-2020 UVM Verification Package for
//              groq_mxfp8_nvfp4_dot_engine, groq_c2c_serdes_pcs, and
//              groq_pcie_c2c_dma.
// =============================================================================
`ifndef UVM_LPX_MXFP8_DMA_PKG_SV
`define UVM_LPX_MXFP8_DMA_PKG_SV

`include "uvm_macros.svh"
`include "groq_pkg.sv"

package uvm_lpx_mxfp8_dma_pkg;
 import uvm_pkg::*;
 import groq_pkg::*;

 // ---------------------------------------------------------------------------
 // 1. C++17 DPI-C Reference Model Imports
 // ---------------------------------------------------------------------------
 import "DPI-C" function void dpi_lpx_mxfp8_dma_reset();
 import "DPI-C" function int unsigned dpi_get_calls();
 import "DPI-C" function void dpi_set_status(input int status);

 import "DPI-C" function void dpi_dot_engine_step(
 input int unsigned valid_i,
 input int unsigned mode_i,
 input int unsigned zero_skip_en_i,
 input int unsigned accum_en_i,
 input int unsigned accum_clear_i,
 input int unsigned act_scale_e8m0_i,
 input int unsigned wt_scale_e8m0_i,
 input bit [127:0] act_stream_i,
 input bit [127:0] wt_stream_i,
 output int unsigned exp_valid_o,
 output int exp_unaccum_dot_o,
 output int exp_dot_accum_o,
 output int unsigned exp_dot_fp32_o,
 output int unsigned exp_zero_skip_lanes_o,
 output int unsigned exp_block_zero_skipped_o,
 output int unsigned exp_nan_inf_flag_o
 );

 import "DPI-C" function void dpi_serdes_pcs_step(
 input int unsigned link_enable_i,
 input int unsigned scramble_en_i,
 input int unsigned rx_ts1_seen_i,
 input int unsigned rx_ts2_seen_i,
 input int unsigned deskew_done_i,
 input int unsigned retrain_req_i,
 input int unsigned local_realsync_cnt_i,
 input int unsigned rx_beacon_ts_i,
 input int unsigned tx_flit_valid_i,
 input bit [127:0] tx_flit_data_i,
 input int unsigned tx_dst_chip_i,
 input int unsigned tx_hop_cnt_i,
 input int unsigned tx_opcode_i,
 input int unsigned nack_req_i,
 input int unsigned nack_seq_i,
 input int unsigned phy_rx_valid_i,
 input int unsigned phy_rx_sync_hdr_i,
 input int unsigned phy_rx_crc16_i,
 input int unsigned phy_rx_meta_i,
 input bit [127:0] phy_rx_payload_i,
 output int unsigned exp_tx_ready_o,
 output int unsigned exp_phy_tx_valid_o,
 output int unsigned exp_tx_sync_hdr_o,
 output int unsigned exp_tx_crc16_o,
 output int unsigned exp_tx_meta_o,
 output bit [127:0] exp_tx_scrambled_payload_o,
 output int unsigned exp_tx_seq_num_o,
 output int unsigned exp_rx_flit_valid_o,
 output bit [127:0] exp_rx_flit_data_o,
 output int unsigned exp_rx_dst_chip_o,
 output int unsigned exp_rx_hop_cnt_o,
 output int unsigned exp_rx_opcode_o,
 output int unsigned exp_rx_seq_num_o,
 output int unsigned exp_rx_crc16_err_o,
 output int unsigned exp_rx_sync_err_o,
 output int unsigned exp_nack_req_o,
 output int unsigned exp_nack_seq_o,
 output int unsigned exp_replay_active_o,
 output int unsigned exp_link_state_o,
 output int unsigned exp_link_up_o,
 output int unsigned exp_measured_skew_o
 );

 import "DPI-C" function void dpi_pcie_dma_step(
 input int unsigned global_cycle_i,
 input int unsigned vliw_active_window_i,
 input int unsigned vliw_sram_busy_i,
 input int unsigned vliw_sram_w_busy_i,
 input int unsigned vliw_sram_e_busy_i,
 input int unsigned desc_push_valid_i,
 input bit [127:0] desc_push_data_i,
 input int unsigned dma_payload_valid_i,
 input bit [127:0] dma_payload_data_i,
 input int unsigned dma_payload_parity_i,
 output int unsigned exp_desc_push_ready_o,
 output int unsigned exp_dma_payload_ready_o,
 output int unsigned exp_imem_wr_en_o,
 output int unsigned exp_imem_wr_slice_o,
 output int unsigned exp_imem_wr_addr_o,
 output int unsigned exp_imem_wr_upper_o,
 output bit [127:0] exp_imem_wr_payload_o,
 output int unsigned exp_host_mem_w_wr_en_o,
 output int unsigned exp_host_mem_w_bank_o,
 output int unsigned exp_host_mem_w_addr_o,
 output bit [127:0] exp_host_mem_w_data_o,
 output int unsigned exp_host_mem_e_wr_en_o,
 output int unsigned exp_host_mem_e_bank_o,
 output int unsigned exp_host_mem_e_addr_o,
 output bit [127:0] exp_host_mem_e_data_o,
 output int unsigned exp_dma_window_stall_o,
 output int unsigned exp_payload_parity_err_o,
 output int unsigned exp_full_o,
 output int unsigned exp_empty_o,
 output int unsigned exp_head_ptr_o,
 output int unsigned exp_tail_ptr_o,
 output int unsigned exp_desc_count_o,
 output int unsigned exp_dma_busy_o,
 output int unsigned exp_dma_done_irq_o,
 output int unsigned exp_completed_desc_cnt_o,
 output int unsigned exp_beats_transferred_o
 );

  // ---------------------------------------------------------------------------
  // 2. Stimulus Helper Functions (64B/66B Scrambler, CRC-16-CCITT, DMA Parity)
  // ---------------------------------------------------------------------------
  function automatic bit [15:0] tb_lfsr16_next(input bit [15:0] s_in);
    bit [15:0] s = s_in;
    for (int i = 0; i < 16; i++) begin
      bit fb = s[15] ^ s[13] ^ s[12] ^ s[10];
      s = {s[14:0], fb};
    end
    return s;
  endfunction

  function automatic bit [127:0] tb_apply_scrambler(
    input bit [127:0] data_in,
    input bit [15:0]  seed,
    input bit         en
  );
    bit [15:0]  s = seed;
    bit [127:0] mask;
    if (!en) return data_in;
    for (int b = 0; b < 128; b++) begin
      bit fb  = s[15] ^ s[13] ^ s[12] ^ s[10];
      mask[b] = fb;
      s       = {s[14:0], fb};
    end
    return data_in ^ mask;
  endfunction

  function automatic bit [15:0] tb_crc16_ccitt(
    input bit [15:0]  meta,
    input bit [127:0] payload
  );
    bit [15:0] c = 16'hFFFF;
    for (int i = 0; i < 16; i++) begin
      c = c ^ {payload[i*8 +: 8], 8'h00};
      for (int b = 0; b < 8; b++) begin
        if (c[15]) c = (c << 1) ^ 16'h1021;
        else       c = (c << 1);
      end
    end
    c = c ^ {meta[7:0], 8'h00};
    for (int b = 0; b < 8; b++) begin
      if (c[15]) c = (c << 1) ^ 16'h1021;
      else       c = (c << 1);
    end
    c = c ^ {meta[15:8], 8'h00};
    for (int b = 0; b < 8; b++) begin
      if (c[15]) c = (c << 1) ^ 16'h1021;
      else       c = (c << 1);
    end
    return c;
  endfunction

  function automatic bit [15:0] tb_calc_parity16(input bit [127:0] data_in);
    bit [15:0] p;
    for (int i = 0; i < 16; i++) begin
      p[i] = ^data_in[i*8 +: 8];
    end
    return p;
  endfunction

  // ---------------------------------------------------------------------------
  // 3. UVM Sequence Item & Sequencer
  // ---------------------------------------------------------------------------
  class lpx_mxfp8_dma_seq_item extends uvm_sequence_item;
    `uvm_object_utils(lpx_mxfp8_dma_seq_item)

    int unsigned tx_id;
    int unsigned phase_id;

    // 1) groq_mxfp8_nvfp4_dot_engine Stimulus
    bit          dot_valid;
    bit [2:0]    dot_mode;
    bit          dot_zero_skip_en;
    bit          dot_accum_en;
    bit          dot_accum_clear;
    bit [7:0]    dot_act_scale;
    bit [7:0]    dot_wt_scale;
    bit [127:0]  dot_act_stream;
    bit [127:0]  dot_wt_stream;

    // 2) groq_c2c_serdes_pcs Stimulus
    bit          pcs_link_enable;
    bit          pcs_scramble_en;
    bit          pcs_rx_ts1_seen;
    bit          pcs_rx_ts2_seen;
    bit          pcs_deskew_done;
    bit          pcs_retrain_req;
    bit [7:0]    pcs_local_realsync_cnt;
    bit [7:0]    pcs_rx_beacon_ts;
    bit          pcs_tx_flit_valid;
    bit [127:0]  pcs_tx_flit_data;
    bit [3:0]    pcs_tx_dst_chip;
    bit [3:0]    pcs_tx_hop_cnt;
    bit [3:0]    pcs_tx_opcode;
    bit          pcs_nack_req;
    bit [1:0]    pcs_nack_seq;
    bit          pcs_phy_rx_valid;
    bit [161:0]  pcs_phy_rx_frame;

    // 3) groq_pcie_c2c_dma Stimulus
    bit [15:0]   dma_global_cycle;
    bit          dma_vliw_active_window;
    bit          dma_vliw_sram_busy;
    bit          dma_vliw_sram_w_busy;
    bit          dma_vliw_sram_e_busy;
    bit          dma_desc_push_valid;
    bit [127:0]  dma_desc_push_data;
    bit          dma_payload_valid;
    bit [127:0]  dma_payload_data;
    bit [15:0]   dma_payload_parity;

    // Observed DUT Outputs: groq_mxfp8_nvfp4_dot_engine
    logic               act_dot_valid;
    logic signed [31:0] act_dot_unaccum;
    logic signed [31:0] act_dot_accum;
    logic [31:0]        act_dot_fp32;
    logic [5:0]         act_dot_zero_skip_lanes;
    logic               act_dot_block_zero_skipped;
    logic               act_dot_nan_inf_flag;

    // Observed DUT Outputs: groq_c2c_serdes_pcs
    logic               act_pcs_tx_ready;
    logic               act_pcs_phy_tx_valid;
    logic [161:0]       act_pcs_phy_tx_frame;
    logic [1:0]         act_pcs_tx_sync_hdr;
    logic [15:0]        act_pcs_tx_crc16;
    logic [15:0]        act_pcs_tx_meta;
    logic [127:0]       act_pcs_tx_scrambled_payload;
    logic               act_pcs_replay_active;
    logic [3:0]         act_pcs_tx_seq_num;
    logic               act_pcs_rx_flit_valid;
    logic [127:0]       act_pcs_rx_flit_data;
    logic [3:0]         act_pcs_rx_dst_chip;
    logic [3:0]         act_pcs_rx_hop_cnt;
    logic [3:0]         act_pcs_rx_opcode;
    logic [3:0]         act_pcs_rx_seq_num;
    logic               act_pcs_rx_crc16_err;
    logic               act_pcs_rx_sync_err;
    logic               act_pcs_nack_req;
    logic [1:0]         act_pcs_nack_seq;
    logic [2:0]         act_pcs_link_state;
    logic               act_pcs_link_up;
    logic [7:0]         act_pcs_measured_skew;

    // Observed DUT Outputs: groq_pcie_c2c_dma
    logic               act_dma_desc_push_ready;
    logic               act_dma_full;
    logic               act_dma_empty;
    logic [1:0]         act_dma_head_ptr;
    logic [1:0]         act_dma_tail_ptr;
    logic [2:0]         act_dma_desc_count;
    logic               act_dma_payload_ready;
    logic               act_dma_imem_wr_en;
    logic [2:0]         act_dma_imem_wr_slice;
    logic [15:0]        act_dma_imem_wr_addr;
    logic [143:0]       act_dma_imem_wr_data;
    logic               act_dma_host_mem_w_wr_en;
    logic [1:0]         act_dma_host_mem_w_bank;
    logic [15:0]        act_dma_host_mem_w_addr;
    logic [127:0]       act_dma_host_mem_w_data;
    logic               act_dma_host_mem_e_wr_en;
    logic [1:0]         act_dma_host_mem_e_bank;
    logic [15:0]        act_dma_host_mem_e_addr;
    logic [127:0]       act_dma_host_mem_e_data;
    logic               act_dma_busy;
    logic               act_dma_window_stall;
    logic               act_dma_payload_parity_err;
    logic               act_dma_done_irq;
    logic [7:0]         act_dma_completed_desc_cnt;
    logic [15:0]        act_dma_beats_transferred;

    function new(string name = "lpx_mxfp8_dma_seq_item");
      super.new(name);
    endfunction
  endclass : lpx_mxfp8_dma_seq_item

  typedef uvm_sequencer #(lpx_mxfp8_dma_seq_item) lpx_mxfp8_dma_sequencer;

  // ---------------------------------------------------------------------------
  // 4. Comprehensive 3,600-Cycle Directed + Constrained-Random UVM Sequence
  // ---------------------------------------------------------------------------
  class lpx_mxfp8_dma_sequence extends uvm_sequence #(lpx_mxfp8_dma_seq_item);
    `uvm_object_utils(lpx_mxfp8_dma_sequence)

    int unsigned next_id       = 0;
    bit [15:0]   seq_rx_lfsr   = 16'hACE1;
    bit [2:0]    seq_link_st   = 3'd0;

    function new(string name = "lpx_mxfp8_dma_sequence");
      super.new(name);
    endfunction

    function automatic bit [127:0] gen_entropy_128(input int unsigned seed, input int unsigned salt);
      bit [127:0] v;
      for (int w = 0; w < 4; w++) begin
        int unsigned x = (seed * 32'h9E37_79B9) ^ ((salt + w) * 32'h85EB_CA6B) ^ 32'hC2B2_AE35;
        x ^= (x >> 16);
        x *= 32'h7FEB_352D;
        x ^= (x >> 15);
        v[w*32 +: 32] = x;
      end
      return v;
    endfunction

    function automatic bit [161:0] build_rx_frame(
      input bit [1:0]   sync_hdr,
      input bit [15:0]  meta,
      input bit [127:0] raw_payload,
      input bit         scram_en,
      input bit [15:0]  crc_xor_mask
    );
      bit [15:0]  crc16 = tb_crc16_ccitt(meta, raw_payload) ^ crc_xor_mask;
      bit [127:0] pay   = tb_apply_scrambler(raw_payload, seq_rx_lfsr, scram_en && (sync_hdr == 2'b01));
      return {sync_hdr, crc16, meta, pay};
    endfunction

    function automatic bit [127:0] build_dma_desc(
      input bit [1:0]  tgt,
      input bit [2:0]  sel,
      input bit [2:0]  rsvd,
      input bit [15:0] base_addr,
      input bit [7:0]  stride,
      input bit [7:0]  burst_len,
      input bit [15:0] sched_cycle,
      input bit [15:0] imem_upper,
      input bit [55:0] tag_meta
    );
      return {tag_meta, imem_upper, sched_cycle, burst_len, stride, base_addr, rsvd, sel, tgt};
    endfunction

    task emit_item(lpx_mxfp8_dma_seq_item item);
      bit link_up_pre = (seq_link_st == 3'd4);
      bit [1:0] rx_sh = item.pcs_phy_rx_frame[161:160];
      bit [15:0] rx_crc_in = item.pcs_phy_rx_frame[159:144];
      bit [15:0] rx_meta_in = item.pcs_phy_rx_frame[143:128];
      bit [127:0] rx_pay_in = item.pcs_phy_rx_frame[127:0];
      bit rx_is_data = item.pcs_phy_rx_valid && (rx_sh == 2'b01);
      bit [127:0] rx_descram = tb_apply_scrambler(rx_pay_in, seq_rx_lfsr, item.pcs_scramble_en && rx_is_data);
      bit rx_crc_err = rx_is_data && (tb_crc16_ccitt(rx_meta_in, rx_descram) != rx_crc_in);

      item.tx_id = next_id++;
      start_item(item);
      finish_item(item);

      // Update sequence's shadow of PCS link_state_q and rx_lfsr_q
      if (!link_up_pre) begin
        seq_rx_lfsr = 16'hACE1;
      end else if (rx_is_data && !rx_crc_err && item.pcs_scramble_en) begin
        seq_rx_lfsr = tb_lfsr16_next(seq_rx_lfsr);
      end

      if (!item.pcs_link_enable) begin
        seq_link_st = 3'd0;
      end else begin
        case (seq_link_st)
          3'd0: seq_link_st = 3'd1;
          3'd1: if (item.pcs_rx_ts1_seen) seq_link_st = 3'd2;
          3'd2: if (item.pcs_rx_ts2_seen) seq_link_st = 3'd3;
          3'd3: if (item.pcs_deskew_done) seq_link_st = 3'd4;
          3'd4: if (item.pcs_retrain_req) seq_link_st = 3'd5;
          3'd5: seq_link_st = 3'd1;
          default: seq_link_st = 3'd0;
        endcase
      end
    endtask

    task body();
      // =======================================================================
      // PHASE 0 (800 cycles: 0..799):
      //   - Exhaustive MXFP8/NVFP4/INT8/W4A8 mode & scale & zero-skip & NaN/Inf
      //   - PCS Link Training FSM (RESET->TS1->TS2->LOCK->ACTIVE->RETRAIN->...)
      //   - DMA Ring Fill-to-Full (count=4), All 4 Targets, VLIW Window Stalls
      // =======================================================================
      for (int c = 0; c < 800; c++) begin
        lpx_mxfp8_dma_seq_item it = lpx_mxfp8_dma_seq_item::type_id::create("it_p0");
        it.phase_id = 0;

        // --- 1. Dot Engine Directed Sweep ---
        it.dot_valid        = (c % 19 != 18);
        it.dot_mode         = 3'(c % 6);
        it.dot_zero_skip_en = c[0];
        it.dot_accum_en     = (c % 3 != 0);
        it.dot_accum_clear  = (c % 25 == 0);
        if (c < 40) begin
          // Block zero-skip & scale boundary cases
          it.dot_act_scale = (c < 10) ? 8'h00 : (c < 20) ? 8'd127 : (c < 30) ? 8'd250 : 8'd2;
          it.dot_wt_scale  = (c >= 10 && c < 15) ? 8'h00 : (c < 20) ? 8'd127 : (c < 30) ? 8'd250 : 8'd2;
        end else begin
          // Sweep scale_sum across <254 (rshift 0..7, >7), ==254, >254 (lshift 0..7, >7)
          int sc_idx = (c - 40) % 24;
          it.dot_act_scale = 8'(115 + sc_idx);
          it.dot_wt_scale  = 8'(127 + (sc_idx / 2));
        end

        it.dot_act_stream = gen_entropy_128(c, 1);
        it.dot_wt_stream  = gen_entropy_128(c, 2);

        if (c >= 40 && c < 210) begin
          // Zero-skip lane count sweep (0..16 for 16-lane modes, 0..32 for NVFP4_E2M1)
          int z_target = (c - 40) % 33;
          if (it.dot_mode == 3'd3 || it.dot_mode == 3'd5) begin
            for (int k = 0; k < 32; k++) begin
              if (k < z_target) begin
                it.dot_act_stream[k*4 +: 4] = (k[0]) ? 4'b1000 : 4'b0000;
              end else begin
                it.dot_act_stream[k*4 +: 4] = {k[0], 3'(1 + (k % 7))};
                it.dot_wt_stream[k*4 +: 4]  = {k[1], 3'(1 + ((k + c) % 7))};
              end
            end
          end else begin
            int z16 = z_target % 17;
            for (int i = 0; i < 16; i++) begin
              if (i < z16) begin
                it.dot_act_stream[i*8 +: 8] = (it.dot_mode == 3'd0) ? 8'h00 : (i[0] ? 8'h80 : 8'h00);
              end else begin
                it.dot_act_stream[i*8 +: 8] = {i[0], 7'(1 + ((i + c) % 120))};
                it.dot_wt_stream[i*8 +: 8]  = {i[1], 7'(1 + ((i * 3 + c) % 120))};
                it.dot_wt_stream[i*4 +: 4]  = {i[1], 3'(1 + (i % 7))};
              end
            end
          end
        end else if (c >= 210 && c < 280) begin
          // Subnormal & NaN/Inf injection across E4M3, E5M2, W4A8
          for (int i = 0; i < 16; i++) begin
            if (c < 245) begin
              // Subnormals (exp == 0, mant != 0)
              it.dot_act_stream[i*8 +: 8] = {i[0], 4'd0, 3'(1 + (i % 7))};
              it.dot_wt_stream[i*8 +: 8]  = {i[1], 5'd0, 2'(1 + (i % 3))};
            end else begin
              // NaN / Inf (0x7F / 0xFF for E4M3/W4A8, exp=0x1F for E5M2)
              it.dot_act_stream[i*8 +: 8] = (i == (c % 16)) ? 8'h7F : 8'h3C;
              it.dot_wt_stream[i*8 +: 8]  = (i == ((c + 3) % 16)) ? 8'hFC : 8'h38;
            end
          end
        end else if (c >= 280 && c < 360) begin
          // Positive & Negative Saturation (s2_shifted_mag overflow & accum saturation)
          it.dot_mode        = (c < 320) ? 3'd1 : 3'd2;
          it.dot_accum_en    = 1'b1;
          it.dot_accum_clear = (c == 280 || c == 320);
          it.dot_act_scale   = 8'd140;
          it.dot_wt_scale    = 8'd140;
          for (int i = 0; i < 16; i++) begin
            it.dot_act_stream[i*8 +: 8] = (c < 320) ? 8'h7E : 8'hFE; // +max vs -max
            it.dot_wt_stream[i*8 +: 8]  = 8'h7B;
          end
        end

        // --- 2. PCS Link Training, Scrambler, CRC-16 Error & Go-Back-N Replay ---
        it.pcs_link_enable        = (c != 5 && c != 400);
        it.pcs_scramble_en        = (c >= 120) ? c[2] : 1'b1;
        it.pcs_rx_ts1_seen        = (seq_link_st == 3'd1) && (c % 3 == 0);
        it.pcs_rx_ts2_seen        = (seq_link_st == 3'd2) && (c % 3 == 1);
        it.pcs_deskew_done        = (seq_link_st == 3'd3) && (c % 3 == 2);
        it.pcs_retrain_req        = (c == 250 || c == 550);
        it.pcs_local_realsync_cnt = 8'(c * 5 + 17);
        it.pcs_rx_beacon_ts       = 8'(c * 3 + 9);

        if (seq_link_st == 3'd4) begin
          // Replay trigger every 32 cycles after filling 4 replay slots
          if ((c % 32 == 20) && (c >= 60)) begin
            it.pcs_nack_req = 1'b1;
            it.pcs_nack_seq = 2'((c / 32) % 4);
          end else if (c % 5 != 4) begin
            it.pcs_tx_flit_valid = 1'b1;
            it.pcs_tx_flit_data  = gen_entropy_128(c, 10);
            it.pcs_tx_dst_chip   = 4'(c % 16);
            it.pcs_tx_hop_cnt    = 4'((c / 2) % 16);
            it.pcs_tx_opcode     = 4'((c / 3) % 16);
          end

          // RX frames: valid data, control, 1-bit CRC err, multi-bit CRC err, sync err
          it.pcs_phy_rx_valid = (c % 6 != 5);
          if (c % 24 == 10) begin
            // 1-bit CRC-16 error
            it.pcs_phy_rx_frame = build_rx_frame(2'b01, {4'(c), 4'd2, 4'd1, 4'(c)}, gen_entropy_128(c, 20), it.pcs_scramble_en, (16'h0001 << (c % 16)));
          end else if (c % 24 == 14) begin
            // Multi-bit CRC-16 error
            it.pcs_phy_rx_frame = build_rx_frame(2'b01, {4'(c), 4'd3, 4'd2, 4'(c)}, gen_entropy_128(c, 21), it.pcs_scramble_en, 16'hA55A);
          end else if (c % 24 == 18) begin
            // Sync header error (2'b00 or 2'b11)
            it.pcs_phy_rx_frame = build_rx_frame(c[0] ? 2'b11 : 2'b00, 16'h1234, gen_entropy_128(c, 22), it.pcs_scramble_en, 16'h0000);
          end else if (c % 24 == 22) begin
            // Valid Control Ordered Set (SYNC_CTRL = 2'b10)
            it.pcs_phy_rx_frame = build_rx_frame(2'b10, 16'h0040, {16{8'h4A}}, it.pcs_scramble_en, 16'h0000);
          end else begin
            // Valid Data Frame (SYNC_DATA = 2'b01)
            it.pcs_phy_rx_frame = build_rx_frame(2'b01, {4'(c), 4'(c >> 2), 4'(c >> 4), 4'(c)}, gen_entropy_128(c, 23), it.pcs_scramble_en, 16'h0000);
          end
        end

        // --- 3. DMA Ring Fill-to-Full, Targets, VLIW Window Stalls & Parity ---
        it.dma_global_cycle = 16'(c);
        if (c < 10) begin
          // Push 5 consecutive descriptors with future scheduled_start_cycle=16'd12
          // so the 4-entry ring fills to full_o==1 (desc_count==4) and rejects 5th!
          it.dma_desc_push_valid = (c < 6);
          it.dma_desc_push_data  = build_dma_desc(
            2'(c % 4), 3'(c % 8), 3'(c), 16'(16'h0100 + c * 16), 8'(c + 1),
            8'((c == 0) ? 0 : 2), 16'd12, 16'(16'hA000 + c), 56'(c * 99)
          );
          it.dma_payload_valid  = 1'b0;
        end else begin
          it.dma_vliw_active_window = (c % 29 == 10);
          it.dma_vliw_sram_busy     = (c % 29 == 11);
          it.dma_vliw_sram_w_busy   = (c % 29 == 12);
          it.dma_vliw_sram_e_busy   = (c % 29 == 13);
          it.dma_desc_push_valid    = (c % 5 == 0);
          it.dma_desc_push_data     = build_dma_desc(
            2'((c / 5) % 4), 3'((c / 5) % 8), 3'(c),
            16'(c * 37), 8'(1 + (c % 15)), 8'(1 + ((c / 5) % 4)),
            16'(c), 16'(c * 257), 56'(c * 12345)
          );
          it.dma_payload_valid  = (c % 7 != 6);
          it.dma_payload_data   = gen_entropy_128(c, 30);
          if (c % 31 == 15) begin
            // Inject payload parity error
            it.dma_payload_parity = tb_calc_parity16(it.dma_payload_data) ^ (16'h0001 << (c % 16));
          end else begin
            it.dma_payload_parity = tb_calc_parity16(it.dma_payload_data);
          end
        end

        emit_item(it);
      end

      // =======================================================================
      // PHASE 1 (800 cycles: 800..1599):
      //   Intensive PCS Scrambled/Unscrambled Streaming, Multi-Entry Replay,
      //   Deskew Skew Calibration, and MXFP8/NVFP4 Mixed Precision Contraction
      // =======================================================================
      for (int c = 800; c < 1600; c++) begin
        lpx_mxfp8_dma_seq_item it = lpx_mxfp8_dma_seq_item::type_id::create("it_p1");
        it.phase_id = 1;

        it.dot_valid        = 1'b1;
        it.dot_mode         = 3'((c / 2) % 6);
        it.dot_zero_skip_en = (c % 4 != 0);
        it.dot_accum_en     = (c % 5 != 0);
        it.dot_accum_clear  = (c % 16 == 0);
        it.dot_act_scale    = (c % 40 == 0) ? 8'h00 : 8'(64 + (c % 160));
        it.dot_wt_scale     = (c % 40 == 20) ? 8'h00 : 8'(64 + ((c * 3) % 160));
        it.dot_act_stream   = (c[0]) ? ~gen_entropy_128(c, 41) : gen_entropy_128(c, 41);
        it.dot_wt_stream    = (c[1]) ? ~gen_entropy_128(c, 42) : gen_entropy_128(c, 42);

        it.pcs_link_enable        = (c != 1200);
        it.pcs_scramble_en        = ((c / 16) % 2 == 0);
        it.pcs_rx_ts1_seen        = 1'b1;
        it.pcs_rx_ts2_seen        = 1'b1;
        it.pcs_deskew_done        = 1'b1;
        it.pcs_retrain_req        = (c % 160 == 150);
        it.pcs_local_realsync_cnt = (c[0]) ? 8'hFF : 8'h00;
        it.pcs_rx_beacon_ts       = (c[1]) ? 8'hAA : 8'h55;

        if (seq_link_st == 3'd4) begin
          if (c % 20 == 12) begin
            it.pcs_nack_req = 1'b1;
            it.pcs_nack_seq = 2'(c % 4);
          end else begin
            it.pcs_tx_flit_valid = (c % 9 != 8);
            it.pcs_tx_flit_data  = (c % 8 == 0) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF :
                                   (c % 8 == 1) ? 128'h0000_0000_0000_0000_0000_0000_0000_0000 :
                                                  gen_entropy_128(c, 50);
            it.pcs_tx_dst_chip   = 4'(c);
            it.pcs_tx_hop_cnt    = 4'(~c);
            it.pcs_tx_opcode     = 4'(c ^ (c >> 2));
          end

          it.pcs_phy_rx_valid = 1'b1;
          if (c % 18 == 7) begin
            it.pcs_phy_rx_frame = build_rx_frame(2'b01, {4'(c), 4'(~c), 4'(c>>1), 4'(c)}, gen_entropy_128(c, 51), it.pcs_scramble_en, (16'h0001 << (c % 16)));
          end else if (c % 18 == 13) begin
            it.pcs_phy_rx_frame = build_rx_frame(2'b00, 16'hFFFF, 128'h0, it.pcs_scramble_en, 16'h0000);
          end else begin
            it.pcs_phy_rx_frame = build_rx_frame(2'b01, {4'(c), 4'(~c), 4'(c>>1), 4'(c)}, gen_entropy_128(c, 52), it.pcs_scramble_en, 16'h0000);
          end
        end

        it.dma_global_cycle       = 16'(c);
        it.dma_desc_push_valid    = (c % 4 == 0);
        it.dma_desc_push_data     = build_dma_desc(2'(c % 4), 3'(c), 3'(~c), 16'(c * 19), 8'(c), 8'(1 + (c % 3)), 16'(c), 16'(~c), 56'(c));
        it.dma_payload_valid      = 1'b1;
        it.dma_payload_data       = gen_entropy_128(c, 53);
        it.dma_payload_parity     = tb_calc_parity16(it.dma_payload_data);

        emit_item(it);
      end

      // =======================================================================
      // PHASE 2 (800 cycles: 1600..2399):
      //   Intensive DMA Scatter-Gather Ring + VLIW Contention Stall + Strided
      //   Multi-Beat Bursts across IMEM / SRAM_WEST / SRAM_EAST / BCAST_BOTH
      // =======================================================================
      for (int c = 1600; c < 2400; c++) begin
        lpx_mxfp8_dma_seq_item it = lpx_mxfp8_dma_seq_item::type_id::create("it_p2");
        it.phase_id = 2;

        it.dot_valid        = 1'b1;
        it.dot_mode         = 3'(c % 6);
        it.dot_zero_skip_en = c[1];
        it.dot_accum_en     = c[0];
        it.dot_accum_clear  = (c % 20 == 0);
        it.dot_act_scale    = 8'(c);
        it.dot_wt_scale     = 8'(~c);
        it.dot_act_stream   = gen_entropy_128(c, 60);
        it.dot_wt_stream    = gen_entropy_128(c, 61);

        it.pcs_link_enable        = 1'b1;
        it.pcs_scramble_en        = 1'b1;
        it.pcs_rx_ts1_seen        = 1'b1;
        it.pcs_rx_ts2_seen        = 1'b1;
        it.pcs_deskew_done        = 1'b1;
        it.pcs_retrain_req        = 1'b0;
        it.pcs_local_realsync_cnt = 8'(c);
        it.pcs_rx_beacon_ts       = 8'(c >> 1);
        it.pcs_tx_flit_valid      = 1'b1;
        it.pcs_tx_flit_data       = gen_entropy_128(c, 62);
        it.pcs_tx_dst_chip        = 4'(c);
        it.pcs_tx_hop_cnt         = 4'(c >> 1);
        it.pcs_tx_opcode          = 4'(c >> 2);
        it.pcs_phy_rx_valid       = 1'b1;
        it.pcs_phy_rx_frame       = build_rx_frame(2'b01, {4'(c), 4'd1, 4'd2, 4'(c)}, gen_entropy_128(c, 63), 1'b1, 16'h0000);

        it.dma_global_cycle       = (c[0]) ? 16'hFFFF : 16'h0000;
        it.dma_vliw_active_window = (c % 16 == 4);
        it.dma_vliw_sram_busy     = (c % 16 == 5);
        it.dma_vliw_sram_w_busy   = (c % 16 == 6);
        it.dma_vliw_sram_e_busy   = (c % 16 == 7);

        it.dma_desc_push_valid    = (c % 3 != 2);
        if (c % 8 == 0) begin
          it.dma_desc_push_data   = 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
        end else if (c % 8 == 1) begin
          it.dma_desc_push_data   = 128'h0000_0000_0000_0000_0000_0000_0000_0000;
        end else begin
          it.dma_desc_push_data   = build_dma_desc(
            2'((c / 3) % 4), 3'(c), 3'(c >> 3),
            16'(c * 257), 8'(c * 17), 8'(1 + (c % 4)),
            16'd0, 16'(c * 513), 56'(gen_entropy_128(c, 64))
          );
        end

        it.dma_payload_valid  = 1'b1;
        it.dma_payload_data   = (c % 6 == 0) ? 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF :
                                (c % 6 == 1) ? 128'h0000_0000_0000_0000_0000_0000_0000_0000 :
                                               gen_entropy_128(c, 65);
        if (c % 19 == 9) begin
          it.dma_payload_parity = ~tb_calc_parity16(it.dma_payload_data);
        end else begin
          it.dma_payload_parity = tb_calc_parity16(it.dma_payload_data);
        end

        emit_item(it);
      end

      // =======================================================================
      // PHASE 3 (1,200 cycles: 2400..3599):
      //   High-Entropy Constrained-Random Full-Toggle Stress across all 3 IPs
      // =======================================================================
      for (int c = 2400; c < 3600; c++) begin
        lpx_mxfp8_dma_seq_item it = lpx_mxfp8_dma_seq_item::type_id::create("it_p3");
        it.phase_id = 3;

        it.dot_valid        = (c % 23 != 22);
        it.dot_mode         = 3'(c % 6);
        it.dot_zero_skip_en = c[0];
        it.dot_accum_en     = (c % 4 != 0);
        it.dot_accum_clear  = (c % 17 == 0);
        it.dot_act_scale    = (c % 50 == 0) ? 8'h00 : 8'(100 + (c % 60));
        it.dot_wt_scale     = (c % 50 == 25) ? 8'h00 : 8'(100 + ((c * 7) % 60));
        it.dot_act_stream   = (c % 4 == 0) ? 128'hAAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA :
                              (c % 4 == 1) ? 128'h5555_5555_5555_5555_5555_5555_5555_5555 :
                                             gen_entropy_128(c, 70);
        it.dot_wt_stream    = (c % 4 == 0) ? 128'h5555_5555_5555_5555_5555_5555_5555_5555 :
                              (c % 4 == 1) ? 128'hAAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA :
                                             gen_entropy_128(c, 71);

        it.pcs_link_enable        = 1'b1;
        it.pcs_scramble_en        = c[3];
        it.pcs_rx_ts1_seen        = 1'b1;
        it.pcs_rx_ts2_seen        = 1'b1;
        it.pcs_deskew_done        = 1'b1;
        it.pcs_retrain_req        = (c == 3000);
        it.pcs_local_realsync_cnt = 8'(c * 13);
        it.pcs_rx_beacon_ts       = 8'(c * 7);
        it.pcs_nack_req           = (seq_link_st == 3'd4) && (c % 25 == 19);
        it.pcs_nack_seq           = 2'(c >> 2);
        it.pcs_tx_flit_valid      = (seq_link_st == 3'd4) && !it.pcs_nack_req;
        it.pcs_tx_flit_data       = gen_entropy_128(c, 72);
        it.pcs_tx_dst_chip        = 4'(c);
        it.pcs_tx_hop_cnt         = 4'(c >> 1);
        it.pcs_tx_opcode          = 4'(c >> 2);
        it.pcs_phy_rx_valid       = (seq_link_st == 3'd4);
        it.pcs_phy_rx_frame       = build_rx_frame(2'b01, {4'(c), 4'(c>>1), 4'(c>>2), 4'(c)}, gen_entropy_128(c, 73), it.pcs_scramble_en, (c % 29 == 14) ? 16'h0001 : 16'h0000);

        it.dma_global_cycle       = 16'(c);
        it.dma_vliw_active_window = (c % 33 == 10);
        it.dma_vliw_sram_busy     = (c % 33 == 11);
        it.dma_vliw_sram_w_busy   = (c % 33 == 12);
        it.dma_vliw_sram_e_busy   = (c % 33 == 13);
        it.dma_desc_push_valid    = (c % 2 == 0);
        it.dma_desc_push_data     = build_dma_desc(2'(c >> 1), 3'(c >> 2), 3'(c), 16'(c * 43), 8'(1 + (c % 7)), 8'(1 + (c % 2)), 16'(c), 16'(c * 11), 56'(c));
        it.dma_payload_valid      = 1'b1;
        it.dma_payload_data       = gen_entropy_128(c, 74);
        it.dma_payload_parity     = (c % 37 == 18) ? (tb_calc_parity16(it.dma_payload_data) ^ 16'h0001) : tb_calc_parity16(it.dma_payload_data);

        emit_item(it);
      end
    endtask
  endclass : lpx_mxfp8_dma_sequence

  // ---------------------------------------------------------------------------
  // 5. UVM Driver
  // ---------------------------------------------------------------------------
  class lpx_mxfp8_dma_driver extends uvm_driver #(lpx_mxfp8_dma_seq_item);
    `uvm_component_utils(lpx_mxfp8_dma_driver)

    virtual lpx_mxfp8_dma_if vif;
    int unsigned driven = 0;

    function new(string name = "lpx_mxfp8_dma_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual lpx_mxfp8_dma_if)::get(this, "", "vif", vif)) begin
 `uvm_fatal("NO_VIF", "Virtual interface lpx_mxfp8_dma_if missing in lpx_mxfp8_dma_driver")
 end
 endfunction

 task run_phase(uvm_phase phase);
 lpx_mxfp8_dma_seq_item item;
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

 vif.dot_valid_i = item.dot_valid;
 vif.dot_mode_i = item.dot_mode;
 vif.dot_zero_skip_en_i = item.dot_zero_skip_en;
 vif.dot_accum_en_i = item.dot_accum_en;
 vif.dot_accum_clear_i = item.dot_accum_clear;
 vif.dot_act_scale_i = item.dot_act_scale;
 vif.dot_wt_scale_i = item.dot_wt_scale;
 vif.dot_act_stream_i = item.dot_act_stream;
 vif.dot_wt_stream_i = item.dot_wt_stream;

 vif.pcs_link_enable_i = item.pcs_link_enable;
 vif.pcs_scramble_en_i = item.pcs_scramble_en;
 vif.pcs_rx_ts1_seen_i = item.pcs_rx_ts1_seen;
 vif.pcs_rx_ts2_seen_i = item.pcs_rx_ts2_seen;
 vif.pcs_deskew_done_i = item.pcs_deskew_done;
 vif.pcs_retrain_req_i = item.pcs_retrain_req;
 vif.pcs_local_realsync_cnt_i = item.pcs_local_realsync_cnt;
 vif.pcs_rx_beacon_ts_i = item.pcs_rx_beacon_ts;
 vif.pcs_tx_flit_valid_i = item.pcs_tx_flit_valid;
 vif.pcs_tx_flit_data_i = item.pcs_tx_flit_data;
 vif.pcs_tx_dst_chip_i = item.pcs_tx_dst_chip;
 vif.pcs_tx_hop_cnt_i = item.pcs_tx_hop_cnt;
 vif.pcs_tx_opcode_i = item.pcs_tx_opcode;
 vif.pcs_nack_req_i = item.pcs_nack_req;
 vif.pcs_nack_seq_i = item.pcs_nack_seq;
 vif.pcs_phy_rx_valid_i = item.pcs_phy_rx_valid;
 vif.pcs_phy_rx_frame_i = item.pcs_phy_rx_frame;

 vif.dma_global_cycle_i = item.dma_global_cycle;
 vif.dma_vliw_active_window_i = item.dma_vliw_active_window;
 vif.dma_vliw_sram_busy_i = item.dma_vliw_sram_busy;
 vif.dma_vliw_sram_w_busy_i = item.dma_vliw_sram_w_busy;
 vif.dma_vliw_sram_e_busy_i = item.dma_vliw_sram_e_busy;
 vif.dma_desc_push_valid_i = item.dma_desc_push_valid;
 vif.dma_desc_push_data_i = item.dma_desc_push_data;
 vif.dma_payload_valid_i = item.dma_payload_valid;
 vif.dma_payload_data_i = item.dma_payload_data;
 vif.dma_payload_parity_i = item.dma_payload_parity;

 @(negedge vif.clk);
 vif.sample_en = 1'b0;
 driven++;
 seq_item_port.item_done();
 end
 endtask
 endclass : lpx_mxfp8_dma_driver

  // ---------------------------------------------------------------------------
  // 6. UVM Monitor & UVM Agent
  // ---------------------------------------------------------------------------
  class lpx_mxfp8_dma_monitor extends uvm_monitor;
    `uvm_component_utils(lpx_mxfp8_dma_monitor)

    virtual lpx_mxfp8_dma_if vif;
    uvm_analysis_port #(lpx_mxfp8_dma_seq_item) ap;
    int unsigned seen = 0;

    function new(string name = "lpx_mxfp8_dma_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual lpx_mxfp8_dma_if)::get(this, "", "vif", vif)) begin
 `uvm_fatal("NO_VIF", "Virtual interface lpx_mxfp8_dma_if missing in lpx_mxfp8_dma_monitor")
 end
 endfunction

 task run_phase(uvm_phase phase);
 forever begin
 @(negedge vif.clk);
 #1ns;
 if (vif.rst_n && vif.sample_en) begin
 lpx_mxfp8_dma_seq_item item = lpx_mxfp8_dma_seq_item::type_id::create("obs_item");
 item.tx_id = vif.tx_id;
 item.phase_id = vif.phase_id;

 // Sample stimulus inputs
 item.dot_valid = vif.dot_valid_i;
 item.dot_mode = vif.dot_mode_i;
 item.dot_zero_skip_en = vif.dot_zero_skip_en_i;
 item.dot_accum_en = vif.dot_accum_en_i;
 item.dot_accum_clear = vif.dot_accum_clear_i;
 item.dot_act_scale = vif.dot_act_scale_i;
 item.dot_wt_scale = vif.dot_wt_scale_i;
 item.dot_act_stream = vif.dot_act_stream_i;
 item.dot_wt_stream = vif.dot_wt_stream_i;

 item.pcs_link_enable = vif.pcs_link_enable_i;
 item.pcs_scramble_en = vif.pcs_scramble_en_i;
 item.pcs_rx_ts1_seen = vif.pcs_rx_ts1_seen_i;
 item.pcs_rx_ts2_seen = vif.pcs_rx_ts2_seen_i;
 item.pcs_deskew_done = vif.pcs_deskew_done_i;
 item.pcs_retrain_req = vif.pcs_retrain_req_i;
 item.pcs_local_realsync_cnt = vif.pcs_local_realsync_cnt_i;
 item.pcs_rx_beacon_ts = vif.pcs_rx_beacon_ts_i;
 item.pcs_tx_flit_valid = vif.pcs_tx_flit_valid_i;
 item.pcs_tx_flit_data = vif.pcs_tx_flit_data_i;
 item.pcs_tx_dst_chip = vif.pcs_tx_dst_chip_i;
 item.pcs_tx_hop_cnt = vif.pcs_tx_hop_cnt_i;
 item.pcs_tx_opcode = vif.pcs_tx_opcode_i;
 item.pcs_nack_req = vif.pcs_nack_req_i;
 item.pcs_nack_seq = vif.pcs_nack_seq_i;
 item.pcs_phy_rx_valid = vif.pcs_phy_rx_valid_i;
 item.pcs_phy_rx_frame = vif.pcs_phy_rx_frame_i;

 item.dma_global_cycle = vif.dma_global_cycle_i;
 item.dma_vliw_active_window = vif.dma_vliw_active_window_i;
 item.dma_vliw_sram_busy = vif.dma_vliw_sram_busy_i;
 item.dma_vliw_sram_w_busy = vif.dma_vliw_sram_w_busy_i;
 item.dma_vliw_sram_e_busy = vif.dma_vliw_sram_e_busy_i;
 item.dma_desc_push_valid = vif.dma_desc_push_valid_i;
 item.dma_desc_push_data = vif.dma_desc_push_data_i;
 item.dma_payload_valid = vif.dma_payload_valid_i;
 item.dma_payload_data = vif.dma_payload_data_i;
 item.dma_payload_parity = vif.dma_payload_parity_i;

 // Sample pre-posedge combinational outputs (4ns setup window before posedge clk)
 item.act_pcs_tx_ready = vif.pcs_tx_ready_o;
 item.act_pcs_phy_tx_valid = vif.pcs_phy_tx_valid_o;
 item.act_pcs_phy_tx_frame = vif.pcs_phy_tx_frame_o;
 item.act_pcs_tx_sync_hdr = vif.pcs_tx_sync_hdr_o;
 item.act_pcs_tx_crc16 = vif.pcs_tx_crc16_o;
 item.act_pcs_tx_meta = vif.pcs_tx_meta_o;
 item.act_pcs_tx_scrambled_payload = vif.pcs_tx_scrambled_payload_o;
 item.act_pcs_tx_seq_num = vif.pcs_tx_seq_num_o;
 item.act_pcs_rx_flit_valid = vif.pcs_rx_flit_valid_o;
 item.act_pcs_rx_flit_data = vif.pcs_rx_flit_data_o;
 item.act_pcs_rx_dst_chip = vif.pcs_rx_dst_chip_o;
 item.act_pcs_rx_hop_cnt = vif.pcs_rx_hop_cnt_o;
 item.act_pcs_rx_opcode = vif.pcs_rx_opcode_o;
 item.act_pcs_rx_seq_num = vif.pcs_rx_seq_num_o;
 item.act_pcs_rx_crc16_err = vif.pcs_rx_crc16_err_o;
 item.act_pcs_rx_sync_err = vif.pcs_rx_sync_err_o;
 item.act_pcs_nack_req = vif.pcs_nack_req_o;
 item.act_pcs_nack_seq = vif.pcs_nack_seq_o;

 item.act_dma_desc_push_ready = vif.dma_desc_push_ready_o;
 item.act_dma_payload_ready = vif.dma_payload_ready_o;
 item.act_dma_imem_wr_en = vif.dma_imem_wr_en_o;
 item.act_dma_imem_wr_slice = vif.dma_imem_wr_slice_o;
 item.act_dma_imem_wr_addr = vif.dma_imem_wr_addr_o;
 item.act_dma_imem_wr_data = vif.dma_imem_wr_data_o;
 item.act_dma_host_mem_w_wr_en = vif.dma_host_mem_w_wr_en_o;
 item.act_dma_host_mem_w_bank = vif.dma_host_mem_w_bank_o;
 item.act_dma_host_mem_w_addr = vif.dma_host_mem_w_addr_o;
 item.act_dma_host_mem_w_data = vif.dma_host_mem_w_data_o;
 item.act_dma_host_mem_e_wr_en = vif.dma_host_mem_e_wr_en_o;
 item.act_dma_host_mem_e_bank = vif.dma_host_mem_e_bank_o;
 item.act_dma_host_mem_e_addr = vif.dma_host_mem_e_addr_o;
 item.act_dma_host_mem_e_data = vif.dma_host_mem_e_data_o;
 item.act_dma_window_stall = vif.dma_window_stall_o;
 item.act_dma_payload_parity_err = vif.dma_payload_parity_err_o;

 // Wait for posedge clk and sample post-posedge registered outputs
 @(posedge vif.clk);
 #1ps;
 item.act_dot_valid = vif.dot_valid_o;
 item.act_dot_unaccum = vif.dot_unaccum_o;
 item.act_dot_accum = vif.dot_accum_o;
 item.act_dot_fp32 = vif.dot_fp32_o;
 item.act_dot_zero_skip_lanes = vif.dot_zero_skip_lanes_o;
 item.act_dot_block_zero_skipped = vif.dot_block_zero_skipped_o;
 item.act_dot_nan_inf_flag = vif.dot_nan_inf_flag_o;

 item.act_pcs_replay_active = vif.pcs_replay_active_o;
 item.act_pcs_link_state = vif.pcs_link_state_o;
 item.act_pcs_link_up = vif.pcs_link_up_o;
 item.act_pcs_measured_skew = vif.pcs_measured_skew_o;

 item.act_dma_full = vif.dma_full_o;
 item.act_dma_empty = vif.dma_empty_o;
 item.act_dma_head_ptr = vif.dma_head_ptr_o;
 item.act_dma_tail_ptr = vif.dma_tail_ptr_o;
 item.act_dma_desc_count = vif.dma_desc_count_o;
 item.act_dma_busy = vif.dma_busy_o;
 item.act_dma_done_irq = vif.dma_done_irq_o;
 item.act_dma_completed_desc_cnt = vif.dma_completed_desc_cnt_o;
 item.act_dma_beats_transferred = vif.dma_beats_transferred_o;

 seen++;
 ap.write(item);
 end
 end
 endtask
 endclass : lpx_mxfp8_dma_monitor

  class lpx_mxfp8_dma_agent extends uvm_agent;
    `uvm_component_utils(lpx_mxfp8_dma_agent)

    lpx_mxfp8_dma_sequencer sequencer;
    lpx_mxfp8_dma_driver    driver;
    lpx_mxfp8_dma_monitor   monitor;

    function new(string name = "lpx_mxfp8_dma_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = lpx_mxfp8_dma_sequencer::type_id::create("sequencer", this);
      driver    = lpx_mxfp8_dma_driver::type_id::create("driver", this);
      monitor   = lpx_mxfp8_dma_monitor::type_id::create("monitor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass : lpx_mxfp8_dma_agent

  // ---------------------------------------------------------------------------
  // 7. UVM Functional Coverage Subscriber (uvm_subscriber)
  // ---------------------------------------------------------------------------
  class lpx_mxfp8_dma_cov_subscriber extends uvm_subscriber #(lpx_mxfp8_dma_seq_item);
    `uvm_component_utils(lpx_mxfp8_dma_cov_subscriber)

    covergroup lpx_mxfp8_dma_cg with function sample(
      bit [2:0] dot_mode,
      bit       dot_zskip_en,
      bit       dot_blk_zskip,
      bit       dot_nan_inf,
      bit [5:0] dot_zlanes,
      bit [2:0] pcs_state,
      bit       pcs_scram,
      bit       pcs_crc_err,
      bit       pcs_sync_err,
      bit       pcs_nack,
      bit       pcs_replay,
      bit [2:0] dma_cnt,
      bit [1:0] dma_tgt,
      bit       dma_stall,
      bit       dma_par_err,
      bit       dma_imem_wr,
      bit       dma_w_wr,
      bit       dma_e_wr
    );
      option.per_instance = 1;

      cp_dot_mode: coverpoint dot_mode {
        bins m_int8_sym   = {3'd0};
        bins m_mxfp8_e4m3 = {3'd1};
        bins m_mxfp8_e5m2 = {3'd2};
        bins m_nvfp4_e2m1       = {3'd3};
        bins m_w4a8_mixed       = {3'd4};
        bins m_nvfp4_e4m3_scale = {3'd5};
      }
      cp_dot_zskip_en: coverpoint dot_zskip_en {
        bins off = {1'b0};
        bins on  = {1'b1};
      }
      cp_dot_blk_zskip: coverpoint dot_blk_zskip {
        bins normal = {1'b0};
        bins bzero  = {1'b1};
      }
      cp_dot_nan_inf: coverpoint dot_nan_inf {
        bins finite  = {1'b0};
        bins nan_inf = {1'b1};
      }
      cp_dot_zlanes: coverpoint dot_zlanes {
        bins z_none  = {6'd0};
        bins z_low   = {[6'd1:6'd7]};
        bins z_mid   = {[6'd8:6'd15]};
        bins z_all16 = {6'd16};
        bins z_nvfp4 = {[6'd17:6'd31]};
        bins z_all32 = {6'd32};
      }
      cp_pcs_state: coverpoint pcs_state {
        bins st_reset   = {3'd0};
        bins st_ts1     = {3'd1};
        bins st_ts2     = {3'd2};
        bins st_lock    = {3'd3};
        bins st_active  = {3'd4};
        bins st_retrain = {3'd5};
      }
      cp_pcs_scram: coverpoint pcs_scram {
        bins unscrambled = {1'b0};
        bins scrambled   = {1'b1};
      }
      cp_pcs_crc_err: coverpoint pcs_crc_err {
        bins ok  = {1'b0};
        bins err = {1'b1};
      }
      cp_pcs_sync_err: coverpoint pcs_sync_err {
        bins ok  = {1'b0};
        bins err = {1'b1};
      }
      cp_pcs_nack: coverpoint pcs_nack {
        bins no_nack = {1'b0};
        bins nack    = {1'b1};
      }
      cp_pcs_replay: coverpoint pcs_replay {
        bins idle   = {1'b0};
        bins active = {1'b1};
      }
      cp_dma_cnt: coverpoint dma_cnt {
        bins c0   = {3'd0};
        bins c1   = {3'd1};
        bins c2   = {3'd2};
        bins c3   = {3'd3};
        bins full = {3'd4};
      }
      cp_dma_tgt: coverpoint dma_tgt {
        bins tgt_imem   = {2'd0};
        bins tgt_sram_w = {2'd1};
        bins tgt_sram_e = {2'd2};
        bins tgt_bcast  = {2'd3};
      }
      cp_dma_stall: coverpoint dma_stall {
        bins no_stall = {1'b0};
        bins stalled  = {1'b1};
      }
      cp_dma_par_err: coverpoint dma_par_err {
        bins ok  = {1'b0};
        bins err = {1'b1};
      }
      cp_dma_imem_wr: coverpoint dma_imem_wr { bins b0 = {1'b0}; bins b1 = {1'b1}; }
      cp_dma_w_wr:    coverpoint dma_w_wr    { bins b0 = {1'b0}; bins b1 = {1'b1}; }
      cp_dma_e_wr:    coverpoint dma_e_wr    { bins b0 = {1'b0}; bins b1 = {1'b1}; }
    endgroup

    function new(string name = "lpx_mxfp8_dma_cov_subscriber", uvm_component parent = null);
      super.new(name, parent);
      lpx_mxfp8_dma_cg = new();
    endfunction

    function void write(lpx_mxfp8_dma_seq_item t);
      lpx_mxfp8_dma_cg.sample(
        t.dot_mode,
        t.dot_zero_skip_en,
        bit'(t.act_dot_block_zero_skipped),
        bit'(t.act_dot_nan_inf_flag),
        6'(t.act_dot_zero_skip_lanes),
        3'(t.act_pcs_link_state),
        t.pcs_scramble_en,
        bit'(t.act_pcs_rx_crc16_err),
        bit'(t.act_pcs_rx_sync_err),
        bit'(t.act_pcs_nack_req),
        bit'(t.act_pcs_replay_active),
        3'(t.act_dma_desc_count),
        t.dma_desc_push_data[1:0],
        bit'(t.act_dma_window_stall),
        bit'(t.act_dma_payload_parity_err),
        bit'(t.act_dma_imem_wr_en),
        bit'(t.act_dma_host_mem_w_wr_en),
        bit'(t.act_dma_host_mem_e_wr_en)
      );
    endfunction
  endclass : lpx_mxfp8_dma_cov_subscriber

  // ---------------------------------------------------------------------------
  // 8. UVM Scoreboard with Bit-Exact C++17 DPI-C Reference Model Comparison
  // ---------------------------------------------------------------------------
  class lpx_mxfp8_dma_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(lpx_mxfp8_dma_scoreboard)

    uvm_analysis_imp #(lpx_mxfp8_dma_seq_item, lpx_mxfp8_dma_scoreboard) imp;

    int unsigned checked_cycles       = 0;
    int unsigned dot_checks           = 0;
    int unsigned pcs_checks           = 0;
    int unsigned dma_checks           = 0;
    int unsigned dot_mismatches       = 0;
    int unsigned pcs_mismatches       = 0;
    int unsigned dma_mismatches       = 0;
    int unsigned mismatches           = 0;
    int unsigned dot_zskip_events     = 0;
    int unsigned dot_nan_inf_events   = 0;
    int unsigned pcs_replay_events    = 0;
    int unsigned pcs_crc_err_events   = 0;
    int unsigned dma_stall_events     = 0;
    int unsigned dma_parity_err_events = 0;

    function new(string name = "lpx_mxfp8_dma_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      imp = new("imp", this);
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
      super.start_of_simulation_phase(phase);
      dpi_lpx_mxfp8_dma_reset();
    endfunction

    function void write(lpx_mxfp8_dma_seq_item item);
      // 1) Dot Engine Reference Step
      int unsigned exp_dot_valid;
      int          exp_dot_unaccum;
      int          exp_dot_accum;
      int unsigned exp_dot_fp32;
      int unsigned exp_dot_zlanes;
      int unsigned exp_dot_blk_zskip;
      int unsigned exp_dot_nan_inf;

      // 2) SerDes PCS Reference Step
      int unsigned exp_pcs_tx_ready;
      int unsigned exp_pcs_phy_tx_valid;
      int unsigned exp_pcs_tx_sync_hdr;
      int unsigned exp_pcs_tx_crc16;
      int unsigned exp_pcs_tx_meta;
      bit [127:0]  exp_pcs_tx_scram_pay;
      int unsigned exp_pcs_tx_seq_num;
      int unsigned exp_pcs_rx_flit_valid;
      bit [127:0]  exp_pcs_rx_flit_data;
      int unsigned exp_pcs_rx_dst_chip;
      int unsigned exp_pcs_rx_hop_cnt;
      int unsigned exp_pcs_rx_opcode;
      int unsigned exp_pcs_rx_seq_num;
      int unsigned exp_pcs_rx_crc16_err;
      int unsigned exp_pcs_rx_sync_err;
      int unsigned exp_pcs_nack_req;
      int unsigned exp_pcs_nack_seq;
      int unsigned exp_pcs_replay_active;
      int unsigned exp_pcs_link_state;
      int unsigned exp_pcs_link_up;
      int unsigned exp_pcs_measured_skew;
      bit [161:0]  exp_pcs_phy_tx_frame;

      // 3) PCIe/C2C DMA Reference Step
      int unsigned exp_dma_desc_push_ready;
      int unsigned exp_dma_payload_ready;
      int unsigned exp_dma_imem_wr_en;
      int unsigned exp_dma_imem_wr_slice;
      int unsigned exp_dma_imem_wr_addr;
      int unsigned exp_dma_imem_wr_upper;
      bit [127:0]  exp_dma_imem_wr_pay;
      int unsigned exp_dma_w_wr_en;
      int unsigned exp_dma_w_bank;
      int unsigned exp_dma_w_addr;
      bit [127:0]  exp_dma_w_data;
      int unsigned exp_dma_e_wr_en;
      int unsigned exp_dma_e_bank;
      int unsigned exp_dma_e_addr;
      bit [127:0]  exp_dma_e_data;
      int unsigned exp_dma_window_stall;
      int unsigned exp_dma_parity_err;
      int unsigned exp_dma_full;
      int unsigned exp_dma_empty;
      int unsigned exp_dma_head_ptr;
      int unsigned exp_dma_tail_ptr;
      int unsigned exp_dma_desc_count;
      int unsigned exp_dma_busy;
      int unsigned exp_dma_done_irq;
      int unsigned exp_dma_completed_cnt;
      int unsigned exp_dma_beats_xferred;

      dpi_dot_engine_step(
        int'(item.dot_valid),
        int'(item.dot_mode),
        int'(item.dot_zero_skip_en),
        int'(item.dot_accum_en),
        int'(item.dot_accum_clear),
        int'(item.dot_act_scale),
        int'(item.dot_wt_scale),
        item.dot_act_stream,
        item.dot_wt_stream,
        exp_dot_valid,
        exp_dot_unaccum,
        exp_dot_accum,
        exp_dot_fp32,
        exp_dot_zlanes,
        exp_dot_blk_zskip,
        exp_dot_nan_inf
      );

      dpi_serdes_pcs_step(
        int'(item.pcs_link_enable),
        int'(item.pcs_scramble_en),
        int'(item.pcs_rx_ts1_seen),
        int'(item.pcs_rx_ts2_seen),
        int'(item.pcs_deskew_done),
        int'(item.pcs_retrain_req),
        int'(item.pcs_local_realsync_cnt),
        int'(item.pcs_rx_beacon_ts),
        int'(item.pcs_tx_flit_valid),
        item.pcs_tx_flit_data,
        int'(item.pcs_tx_dst_chip),
        int'(item.pcs_tx_hop_cnt),
        int'(item.pcs_tx_opcode),
        int'(item.pcs_nack_req),
        int'(item.pcs_nack_seq),
        int'(item.pcs_phy_rx_valid),
        int'(item.pcs_phy_rx_frame[161:160]),
        int'(item.pcs_phy_rx_frame[159:144]),
        int'(item.pcs_phy_rx_frame[143:128]),
        item.pcs_phy_rx_frame[127:0],
        exp_pcs_tx_ready,
        exp_pcs_phy_tx_valid,
        exp_pcs_tx_sync_hdr,
        exp_pcs_tx_crc16,
        exp_pcs_tx_meta,
        exp_pcs_tx_scram_pay,
        exp_pcs_tx_seq_num,
        exp_pcs_rx_flit_valid,
        exp_pcs_rx_flit_data,
        exp_pcs_rx_dst_chip,
        exp_pcs_rx_hop_cnt,
        exp_pcs_rx_opcode,
        exp_pcs_rx_seq_num,
        exp_pcs_rx_crc16_err,
        exp_pcs_rx_sync_err,
        exp_pcs_nack_req,
        exp_pcs_nack_seq,
        exp_pcs_replay_active,
        exp_pcs_link_state,
        exp_pcs_link_up,
        exp_pcs_measured_skew
      );

      dpi_pcie_dma_step(
        int'(item.dma_global_cycle),
        int'(item.dma_vliw_active_window),
        int'(item.dma_vliw_sram_busy),
        int'(item.dma_vliw_sram_w_busy),
        int'(item.dma_vliw_sram_e_busy),
        int'(item.dma_desc_push_valid),
        item.dma_desc_push_data,
        int'(item.dma_payload_valid),
        item.dma_payload_data,
        int'(item.dma_payload_parity),
        exp_dma_desc_push_ready,
        exp_dma_payload_ready,
        exp_dma_imem_wr_en,
        exp_dma_imem_wr_slice,
        exp_dma_imem_wr_addr,
        exp_dma_imem_wr_upper,
        exp_dma_imem_wr_pay,
        exp_dma_w_wr_en,
        exp_dma_w_bank,
        exp_dma_w_addr,
        exp_dma_w_data,
        exp_dma_e_wr_en,
        exp_dma_e_bank,
        exp_dma_e_addr,
        exp_dma_e_data,
        exp_dma_window_stall,
        exp_dma_parity_err,
        exp_dma_full,
        exp_dma_empty,
        exp_dma_head_ptr,
        exp_dma_tail_ptr,
        exp_dma_desc_count,
        exp_dma_busy,
        exp_dma_done_irq,
        exp_dma_completed_cnt,
        exp_dma_beats_xferred
      );

      checked_cycles++;
      dot_checks++;
      pcs_checks++;
      dma_checks++;

      if (exp_dot_zlanes > 0 || exp_dot_blk_zskip != 0) dot_zskip_events++;
      if (exp_dot_nan_inf != 0)                         dot_nan_inf_events++;
      if (exp_pcs_replay_active != 0)                   pcs_replay_events++;
      if (exp_pcs_rx_crc16_err != 0)                    pcs_crc_err_events++;
      if (exp_dma_window_stall != 0)                    dma_stall_events++;
      if (exp_dma_parity_err != 0)                      dma_parity_err_events++;

      // Check 1: groq_mxfp8_nvfp4_dot_engine
      if ((item.act_dot_valid              !== 1'(exp_dot_valid))     ||
          (item.act_dot_unaccum            !== 32'(exp_dot_unaccum))  ||
          (item.act_dot_accum              !== 32'(exp_dot_accum))    ||
          (item.act_dot_fp32               !== 32'(exp_dot_fp32))     ||
          (item.act_dot_zero_skip_lanes    !== 6'(exp_dot_zlanes))    ||
          (item.act_dot_block_zero_skipped !== 1'(exp_dot_blk_zskip)) ||
          (item.act_dot_nan_inf_flag       !== 1'(exp_dot_nan_inf))) begin
        dot_mismatches++;
        mismatches++;
        `uvm_error("DOT_MISMATCH", $sformatf(
          "tx=%0d mode=%0d exp_unacc=%08x act_unacc=%08x exp_acc=%08x act_acc=%08x exp_fp32=%08x act_fp32=%08x exp_z=%0d act_z=%0d",
          item.tx_id, item.dot_mode,
          exp_dot_unaccum, item.act_dot_unaccum,
          exp_dot_accum, item.act_dot_accum,
          exp_dot_fp32, item.act_dot_fp32,
          exp_dot_zlanes, item.act_dot_zero_skip_lanes))
      end

      // Check 2: groq_c2c_serdes_pcs
      exp_pcs_phy_tx_frame = {2'(exp_pcs_tx_sync_hdr), 16'(exp_pcs_tx_crc16), 16'(exp_pcs_tx_meta), exp_pcs_tx_scram_pay};
      if ((item.act_pcs_tx_ready             !== 1'(exp_pcs_tx_ready))      ||
          (item.act_pcs_phy_tx_valid         !== 1'(exp_pcs_phy_tx_valid))  ||
          (item.act_pcs_phy_tx_frame         !== exp_pcs_phy_tx_frame)      ||
          (item.act_pcs_tx_sync_hdr          !== 2'(exp_pcs_tx_sync_hdr))   ||
          (item.act_pcs_tx_crc16             !== 16'(exp_pcs_tx_crc16))     ||
          (item.act_pcs_tx_meta              !== 16'(exp_pcs_tx_meta))      ||
          (item.act_pcs_tx_scrambled_payload !== exp_pcs_tx_scram_pay)      ||
          (item.act_pcs_tx_seq_num           !== 4'(exp_pcs_tx_seq_num))    ||
          (item.act_pcs_rx_flit_valid        !== 1'(exp_pcs_rx_flit_valid)) ||
          (item.act_pcs_rx_flit_data         !== exp_pcs_rx_flit_data)      ||
          (item.act_pcs_rx_dst_chip          !== 4'(exp_pcs_rx_dst_chip))   ||
          (item.act_pcs_rx_hop_cnt           !== 4'(exp_pcs_rx_hop_cnt))    ||
          (item.act_pcs_rx_opcode            !== 4'(exp_pcs_rx_opcode))     ||
          (item.act_pcs_rx_seq_num           !== 4'(exp_pcs_rx_seq_num))    ||
          (item.act_pcs_rx_crc16_err         !== 1'(exp_pcs_rx_crc16_err))  ||
          (item.act_pcs_rx_sync_err          !== 1'(exp_pcs_rx_sync_err))   ||
          (item.act_pcs_nack_req             !== 1'(exp_pcs_nack_req))      ||
          (item.act_pcs_nack_seq             !== 2'(exp_pcs_nack_seq))      ||
          (item.act_pcs_replay_active        !== 1'(exp_pcs_replay_active)) ||
          (item.act_pcs_link_state           !== 3'(exp_pcs_link_state))    ||
          (item.act_pcs_link_up              !== 1'(exp_pcs_link_up))       ||
          (item.act_pcs_measured_skew        !== 8'(exp_pcs_measured_skew))) begin
        pcs_mismatches++;
        mismatches++;
        `uvm_error("PCS_MISMATCH", $sformatf(
          "tx=%0d exp_st=%0d act_st=%0d exp_crc=%04x act_crc=%04x exp_rx_v=%0d act_rx_v=%0d",
          item.tx_id, exp_pcs_link_state, item.act_pcs_link_state,
          exp_pcs_tx_crc16, item.act_pcs_tx_crc16,
          exp_pcs_rx_flit_valid, item.act_pcs_rx_flit_valid))
      end

      // Check 3: groq_pcie_c2c_dma
      if ((item.act_dma_desc_push_ready    !== 1'(exp_dma_desc_push_ready)) ||
          (item.act_dma_payload_ready      !== 1'(exp_dma_payload_ready))   ||
          (item.act_dma_imem_wr_en         !== 1'(exp_dma_imem_wr_en))      ||
          (item.act_dma_imem_wr_slice      !== 3'(exp_dma_imem_wr_slice))   ||
          (item.act_dma_imem_wr_addr       !== 16'(exp_dma_imem_wr_addr))   ||
          (item.act_dma_imem_wr_data       !== {16'(exp_dma_imem_wr_upper), exp_dma_imem_wr_pay}) ||
          (item.act_dma_host_mem_w_wr_en   !== 1'(exp_dma_w_wr_en))         ||
          (item.act_dma_host_mem_w_bank    !== 2'(exp_dma_w_bank))          ||
          (item.act_dma_host_mem_w_addr    !== 16'(exp_dma_w_addr))         ||
          (item.act_dma_host_mem_w_data    !== exp_dma_w_data)              ||
          (item.act_dma_host_mem_e_wr_en   !== 1'(exp_dma_e_wr_en))         ||
          (item.act_dma_host_mem_e_bank    !== 2'(exp_dma_e_bank))          ||
          (item.act_dma_host_mem_e_addr    !== 16'(exp_dma_e_addr))         ||
          (item.act_dma_host_mem_e_data    !== exp_dma_e_data)              ||
          (item.act_dma_window_stall       !== 1'(exp_dma_window_stall))    ||
          (item.act_dma_payload_parity_err !== 1'(exp_dma_parity_err))      ||
          (item.act_dma_full               !== 1'(exp_dma_full))            ||
          (item.act_dma_empty              !== 1'(exp_dma_empty))           ||
          (item.act_dma_head_ptr           !== 2'(exp_dma_head_ptr))        ||
          (item.act_dma_tail_ptr           !== 2'(exp_dma_tail_ptr))        ||
          (item.act_dma_desc_count         !== 3'(exp_dma_desc_count))      ||
          (item.act_dma_busy               !== 1'(exp_dma_busy))            ||
          (item.act_dma_done_irq           !== 1'(exp_dma_done_irq))        ||
          (item.act_dma_completed_desc_cnt !== 8'(exp_dma_completed_cnt))   ||
          (item.act_dma_beats_transferred  !== 16'(exp_dma_beats_xferred))) begin
        dma_mismatches++;
        mismatches++;
        `uvm_error("DMA_MISMATCH", $sformatf(
          "tx=%0d exp_cnt=%0d act_cnt=%0d exp_beats=%0d act_beats=%0d exp_w_en=%0d act_w_en=%0d",
          item.tx_id, exp_dma_desc_count, item.act_dma_desc_count,
          exp_dma_beats_xferred, item.act_dma_beats_transferred,
          exp_dma_w_wr_en, item.act_dma_host_mem_w_wr_en))
      end
    endfunction
  endclass : lpx_mxfp8_dma_scoreboard

  // ---------------------------------------------------------------------------
  // 9. UVM Environment & UVM Test
  // ---------------------------------------------------------------------------
  class lpx_mxfp8_dma_env extends uvm_env;
    `uvm_component_utils(lpx_mxfp8_dma_env)

    lpx_mxfp8_dma_agent          agent;
    lpx_mxfp8_dma_cov_subscriber cov_sub;
    lpx_mxfp8_dma_scoreboard     scoreboard;

    function new(string name = "lpx_mxfp8_dma_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = lpx_mxfp8_dma_agent::type_id::create("agent", this);
      cov_sub    = lpx_mxfp8_dma_cov_subscriber::type_id::create("cov_sub", this);
      scoreboard = lpx_mxfp8_dma_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.monitor.ap.connect(cov_sub.analysis_export);
      agent.monitor.ap.connect(scoreboard.imp);
    endfunction
  endclass : lpx_mxfp8_dma_env

  class lpx_mxfp8_dma_test extends uvm_test;
    `uvm_component_utils(lpx_mxfp8_dma_test)

    lpx_mxfp8_dma_env env;

    function new(string name = "lpx_mxfp8_dma_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = lpx_mxfp8_dma_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      lpx_mxfp8_dma_sequence seq = lpx_mxfp8_dma_sequence::type_id::create("seq");
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
      func_cov  = env.cov_sub.lpx_mxfp8_dma_cg.get_inst_coverage();
      pass_gate = (env.agent.driver.driven >= 3500) &&
                  (env.agent.monitor.seen == env.agent.driver.driven) &&
                  (env.scoreboard.checked_cycles == env.agent.driver.driven) &&
                  (dpi_calls == env.agent.driver.driven) &&
                  (env.scoreboard.mismatches == 0) &&
                  (env.scoreboard.dot_zskip_events > 0) &&
                  (env.scoreboard.dot_nan_inf_events > 0) &&
                  (env.scoreboard.pcs_replay_events > 0) &&
                  (env.scoreboard.pcs_crc_err_events > 0) &&
                  (env.scoreboard.dma_stall_events > 0) &&
                  (env.scoreboard.dma_parity_err_events > 0) &&
                  (func_cov == 100.0);

      fd = $fopen("lpx_mxfp8_dma_summary.json", "w");
      if (fd == 0) `uvm_fatal("JSON_OPEN", "Cannot open lpx_mxfp8_dma_summary.json")
      $fdisplay(fd, "{");
      $fdisplay(fd, "  \"suite\": \"uvm_lpx_mxfp8_dma\",");
      $fdisplay(fd, "  \"dut\": [\"groq_mxfp8_nvfp4_dot_engine\", \"groq_c2c_serdes_pcs\", \"groq_pcie_c2c_dma\"],");
      $fdisplay(fd, "  \"driven_cycles\": %0d,", env.agent.driver.driven);
      $fdisplay(fd, "  \"observed_cycles\": %0d,", env.agent.monitor.seen);
      $fdisplay(fd, "  \"checked_cycles\": %0d,", env.scoreboard.checked_cycles);
      $fdisplay(fd, "  \"dpi_calls\": %0d,", dpi_calls);
      $fdisplay(fd, "  \"dot_engine_checks\": %0d,", env.scoreboard.dot_checks);
      $fdisplay(fd, "  \"serdes_pcs_checks\": %0d,", env.scoreboard.pcs_checks);
      $fdisplay(fd, "  \"pcie_dma_checks\": %0d,", env.scoreboard.dma_checks);
      $fdisplay(fd, "  \"dot_zero_skip_events\": %0d,", env.scoreboard.dot_zskip_events);
      $fdisplay(fd, "  \"dot_nan_inf_events\": %0d,", env.scoreboard.dot_nan_inf_events);
      $fdisplay(fd, "  \"pcs_replay_events\": %0d,", env.scoreboard.pcs_replay_events);
      $fdisplay(fd, "  \"pcs_crc_err_events\": %0d,", env.scoreboard.pcs_crc_err_events);
      $fdisplay(fd, "  \"dma_window_stall_events\": %0d,", env.scoreboard.dma_stall_events);
      $fdisplay(fd, "  \"dma_parity_err_events\": %0d,", env.scoreboard.dma_parity_err_events);
      $fdisplay(fd, "  \"dot_mismatches\": %0d,", env.scoreboard.dot_mismatches);
      $fdisplay(fd, "  \"pcs_mismatches\": %0d,", env.scoreboard.pcs_mismatches);
      $fdisplay(fd, "  \"dma_mismatches\": %0d,", env.scoreboard.dma_mismatches);
      $fdisplay(fd, "  \"mismatches\": %0d,", env.scoreboard.mismatches);
      $fdisplay(fd, "  \"functional_coverage_pct\": %0.2f,", func_cov);
      $fdisplay(fd, "  \"pass\": %0d", pass_gate);
      $fdisplay(fd, "}");
      $fclose(fd);

      dpi_set_status(pass_gate ? 0 : 1);
      if (!pass_gate) begin
        `uvm_fatal("UVM_LPX_MXFP8_DMA_FAIL", $sformatf(
          "Gate failed: driven=%0d checked=%0d mismatches=%0d (dot=%0d pcs=%0d dma=%0d) cov=%0.2f%%",
          env.agent.driver.driven, env.scoreboard.checked_cycles,
          env.scoreboard.mismatches, env.scoreboard.dot_mismatches,
          env.scoreboard.pcs_mismatches, env.scoreboard.dma_mismatches, func_cov))
      end else begin
        `uvm_info("UVM_LPX_MXFP8_DMA_PASS", $sformatf(
          "PASS: %0d transactions checked via C++17 DPI-C reference, 0 mismatches, 100.00%% functional coverage",
          env.scoreboard.checked_cycles), UVM_LOW)
      end
    endfunction
  endclass : lpx_mxfp8_dma_test

endpackage : uvm_lpx_mxfp8_dma_pkg

`endif // UVM_LPX_MXFP8_DMA_PKG_SV
