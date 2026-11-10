// =============================================================================
// File: gate_sim/tb_gate_vs_rtl_cosim.sv
// Stage 17: Post-Synthesis Gate-Level Netlist vs. Golden RTL Lockstep Co-Sim
//           & Toggle-Accurate VCD Activity Dump (ASAP7 7nm Standard Cells)
// =============================================================================
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHTRUNC */
`timescale 1ns/1ps
`include "groq_pkg.sv"

module tb_gate_vs_rtl_cosim;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  int unsigned cycle_cnt = 0;
  int unsigned sim_phase = 0; // 0=reset, 1=active_llm_inference, 2=zero_skip_idle_gated
  int unsigned total_checks = 0;
  int unsigned mismatch_cnt = 0;
  int unsigned mod_checks [0:11];
  int unsigned mod_mismatches [0:11];

  always #0.5 clk = ~clk; // 1.0 GHz reference clock (1ns period)

  // ---------------------------------------------------------------------------
  // 1. groq_sram_ecc_secded (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic        ecc_valid_in;
  logic [63:0] ecc_data_in;
  logic [71:0] ecc_codeword_in;
  logic [7:0]  gold_ecc_out, gate_ecc_out;
  logic [71:0] gold_codeword_out, gate_codeword_out;
  logic        gold_ecc_valid_out, gate_ecc_valid_out;
  logic [63:0] gold_data_corrected, gate_data_corrected;
  logic [7:0]  gold_syndrome, gate_syndrome;
  logic        gold_sec_err, gate_sec_err;
  logic        gold_ded_err, gate_ded_err;

  groq_sram_ecc_secded gold_sram_ecc_secded (
    .clk(clk), .rst_n(rst_n), .valid_in(ecc_valid_in), .data_in(ecc_data_in),
    .ecc_out(gold_ecc_out), .codeword_out(gold_codeword_out), .codeword_in(ecc_codeword_in),
    .valid_out(gold_ecc_valid_out), .data_corrected(gold_data_corrected),
    .syndrome(gold_syndrome), .single_err_detected(gold_sec_err), .double_err_detected(gold_ded_err)
  );
  groq_sram_ecc_secded_gate gate_sram_ecc_secded (
    .clk(clk), .rst_n(rst_n), .valid_in(ecc_valid_in), .data_in(ecc_data_in),
    .ecc_out(gate_ecc_out), .codeword_out(gate_codeword_out), .codeword_in(ecc_codeword_in),
    .valid_out(gate_ecc_valid_out), .data_corrected(gate_data_corrected),
    .syndrome(gate_syndrome), .single_err_detected(gate_sec_err), .double_err_detected(gate_ded_err)
  );

  // ---------------------------------------------------------------------------
  // 2. groq_mem_agu (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic       agu_cfg_load, agu_step_en;
  logic [1:0] agu_cfg_mode;
  logic [9:0] agu_base_addr, agu_stride_0, agu_stride_1, agu_count_0, agu_count_1, agu_gather_off;
  logic [9:0] gold_agu_addr, gate_agu_addr, gold_agu_idx0, gate_agu_idx0, gold_agu_idx1, gate_agu_idx1;
  logic       gold_agu_valid, gate_agu_valid, gold_agu_wrap, gate_agu_wrap;
  logic       gold_agu_done, gate_agu_done, gold_agu_busy, gate_agu_busy;

  groq_mem_agu gold_mem_agu (
    .clk(clk), .rst_n(rst_n), .cfg_load(agu_cfg_load), .cfg_mode(agu_cfg_mode),
    .base_addr(agu_base_addr), .stride_0(agu_stride_0), .stride_1(agu_stride_1),
    .count_0(agu_count_0), .count_1(agu_count_1), .step_en(agu_step_en),
    .gather_offset_in(agu_gather_off), .addr_out(gold_agu_addr), .addr_valid(gold_agu_valid),
    .idx_0_out(gold_agu_idx0), .idx_1_out(gold_agu_idx1), .inner_wrap(gold_agu_wrap),
    .tile_done(gold_agu_done), .agu_busy(gold_agu_busy)
  );
  groq_mem_agu_gate gate_mem_agu (
    .clk(clk), .rst_n(rst_n), .cfg_load(agu_cfg_load), .cfg_mode(agu_cfg_mode),
    .base_addr(agu_base_addr), .stride_0(agu_stride_0), .stride_1(agu_stride_1),
    .count_0(agu_count_0), .count_1(agu_count_1), .step_en(agu_step_en),
    .gather_offset_in(agu_gather_off), .addr_out(gate_agu_addr), .addr_valid(gate_agu_valid),
    .idx_0_out(gate_agu_idx0), .idx_1_out(gate_agu_idx1), .inner_wrap(gate_agu_wrap),
    .tile_done(gate_agu_done), .agu_busy(gate_agu_busy)
  );

  // ---------------------------------------------------------------------------
  // 3. groq_icu_slice (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic              icu_en, icu_adj_en;
  logic [8*144-1:0]  icu_imem_bundle;
  logic [7:0]        icu_notify_ready;
  logic signed [15:0] icu_adj_val;
  logic [7:0]        gold_icu_fetch, gate_icu_fetch, gold_icu_valid, gate_icu_valid;
  logic [8*16-1:0]   gold_icu_pc, gate_icu_pc, gold_icu_nop, gate_icu_nop;
  logic [8*144-1:0]  gold_icu_bundle, gate_icu_bundle;
  logic [7:0]        gold_icu_halt, gate_icu_halt, gold_icu_bwait, gate_icu_bwait, gold_icu_bmask, gate_icu_bmask;
  logic              gold_icu_brel, gate_icu_brel, gold_icu_fault, gate_icu_fault;
  logic [15:0]       gold_icu_bcnt, gate_icu_bcnt;
  logic [63:0]       gold_icu_cyc, gate_icu_cyc, gold_icu_atime, gate_icu_atime;
  logic signed [15:0] gold_icu_doff, gate_icu_doff;

  groq_icu_slice gold_icu_slice (
    .clk(clk), .rst_n(rst_n), .icu_enable_i(icu_en), .imem_vliw_bundle_i(icu_imem_bundle),
    .imem_fetch_en_o(gold_icu_fetch), .pc_slice_o(gold_icu_pc), .slice_vliw_valid_o(gold_icu_valid),
    .slice_vliw_bundle_o(gold_icu_bundle), .slice_nop_timer_o(gold_icu_nop), .slice_halted_o(gold_icu_halt),
    .slice_notify_ready_i(icu_notify_ready), .barrier_waiting_o(gold_icu_bwait), .barrier_ready_mask_o(gold_icu_bmask),
    .barrier_release_pulse_o(gold_icu_brel), .barrier_release_cnt_o(gold_icu_bcnt),
    .realsync_ext_adj_en_i(icu_adj_en), .realsync_ext_adj_val_i(icu_adj_val),
    .realsync_cycle_cnt_o(gold_icu_cyc), .realsync_deskew_offset_o(gold_icu_doff),
    .realsync_aligned_time_o(gold_icu_atime), .realsync_drift_fault_o(gold_icu_fault)
  );
  groq_icu_slice_gate gate_icu_slice (
    .clk(clk), .rst_n(rst_n), .icu_enable_i(icu_en), .imem_vliw_bundle_i(icu_imem_bundle),
    .imem_fetch_en_o(gate_icu_fetch), .pc_slice_o(gate_icu_pc), .slice_vliw_valid_o(gate_icu_valid),
    .slice_vliw_bundle_o(gate_icu_bundle), .slice_nop_timer_o(gate_icu_nop), .slice_halted_o(gate_icu_halt),
    .slice_notify_ready_i(icu_notify_ready), .barrier_waiting_o(gate_icu_bwait), .barrier_ready_mask_o(gate_icu_bmask),
    .barrier_release_pulse_o(gate_icu_brel), .barrier_release_cnt_o(gate_icu_bcnt),
    .realsync_ext_adj_en_i(icu_adj_en), .realsync_ext_adj_val_i(icu_adj_val),
    .realsync_cycle_cnt_o(gate_icu_cyc), .realsync_deskew_offset_o(gate_icu_doff),
    .realsync_aligned_time_o(gate_icu_atime), .realsync_drift_fault_o(gate_icu_fault)
  );

  // ---------------------------------------------------------------------------
  // 4. groq_c2c_serdes_pcs (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic         pcs_link_en, pcs_scram_en, pcs_ts1, pcs_ts2, pcs_deskew, pcs_retrain;
  logic [7:0]   pcs_local_ts, pcs_rx_beacon;
  logic         pcs_tx_valid, pcs_nack_req, pcs_rx_valid;
  logic [127:0] pcs_tx_data;
  logic [3:0]   pcs_tx_dst, pcs_tx_hop, pcs_tx_op;
  logic [1:0]   pcs_nack_seq;
  logic [161:0] pcs_rx_frame;
  logic         gold_pcs_tx_rdy, gate_pcs_tx_rdy, gold_pcs_tx_val, gate_pcs_tx_val;
  logic [161:0] gold_pcs_tx_frm, gate_pcs_tx_frm;
  logic [1:0]   gold_pcs_shdr, gate_pcs_shdr, gold_pcs_nseq, gate_pcs_nseq;
  logic [15:0]  gold_pcs_crc, gate_pcs_crc, gold_pcs_meta, gate_pcs_meta;
  logic [127:0] gold_pcs_spay, gate_pcs_spay, gold_pcs_rx_dat, gate_pcs_rx_dat;
  logic         gold_pcs_rep, gate_pcs_rep, gold_pcs_rx_val, gate_pcs_rx_val;
  logic [3:0]   gold_pcs_tseq, gate_pcs_tseq, gold_pcs_rdst, gate_pcs_rdst, gold_pcs_rhop, gate_pcs_rhop;
  logic [3:0]   gold_pcs_rop, gate_pcs_rop, gold_pcs_rseq, gate_pcs_rseq;
  logic         gold_pcs_cerr, gate_pcs_cerr, gold_pcs_serr, gate_pcs_serr, gold_pcs_nreq, gate_pcs_nreq, gold_pcs_up, gate_pcs_up;
  logic [2:0]   gold_pcs_st, gate_pcs_st;
  logic [7:0]   gold_pcs_skew, gate_pcs_skew;

  groq_c2c_serdes_pcs gold_c2c_serdes_pcs (
    .clk(clk), .rst_n(rst_n), .link_enable_i(pcs_link_en), .scramble_en_i(pcs_scram_en),
    .rx_ts1_seen_i(pcs_ts1), .rx_ts2_seen_i(pcs_ts2), .deskew_done_i(pcs_deskew), .retrain_req_i(pcs_retrain),
    .local_realsync_cnt_i(pcs_local_ts), .rx_beacon_ts_i(pcs_rx_beacon),
    .tx_flit_valid_i(pcs_tx_valid), .tx_flit_data_i(pcs_tx_data), .tx_dst_chip_i(pcs_tx_dst),
    .tx_hop_cnt_i(pcs_tx_hop), .tx_opcode_i(pcs_tx_op), .tx_ready_o(gold_pcs_tx_rdy),
    .nack_req_i(pcs_nack_req), .nack_seq_i(pcs_nack_seq),
    .phy_tx_valid_o(gold_pcs_tx_val), .phy_tx_frame_o(gold_pcs_tx_frm), .tx_sync_hdr_o(gold_pcs_shdr),
    .tx_crc16_o(gold_pcs_crc), .tx_meta_o(gold_pcs_meta), .tx_scrambled_payload_o(gold_pcs_spay),
    .replay_active_o(gold_pcs_rep), .tx_seq_num_o(gold_pcs_tseq),
    .phy_rx_valid_i(pcs_rx_valid), .phy_rx_frame_i(pcs_rx_frame),
    .rx_flit_valid_o(gold_pcs_rx_val), .rx_flit_data_o(gold_pcs_rx_dat), .rx_dst_chip_o(gold_pcs_rdst),
    .rx_hop_cnt_o(gold_pcs_rhop), .rx_opcode_o(gold_pcs_rop), .rx_seq_num_o(gold_pcs_rseq),
    .rx_crc16_err_o(gold_pcs_cerr), .rx_sync_err_o(gold_pcs_serr), .nack_req_o(gold_pcs_nreq),
    .nack_seq_o(gold_pcs_nseq), .link_state_o(gold_pcs_st), .link_up_o(gold_pcs_up), .measured_skew_o(gold_pcs_skew)
  );
  groq_c2c_serdes_pcs_gate gate_c2c_serdes_pcs (
    .clk(clk), .rst_n(rst_n), .link_enable_i(pcs_link_en), .scramble_en_i(pcs_scram_en),
    .rx_ts1_seen_i(pcs_ts1), .rx_ts2_seen_i(pcs_ts2), .deskew_done_i(pcs_deskew), .retrain_req_i(pcs_retrain),
    .local_realsync_cnt_i(pcs_local_ts), .rx_beacon_ts_i(pcs_rx_beacon),
    .tx_flit_valid_i(pcs_tx_valid), .tx_flit_data_i(pcs_tx_data), .tx_dst_chip_i(pcs_tx_dst),
    .tx_hop_cnt_i(pcs_tx_hop), .tx_opcode_i(pcs_tx_op), .tx_ready_o(gate_pcs_tx_rdy),
    .nack_req_i(pcs_nack_req), .nack_seq_i(pcs_nack_seq),
    .phy_tx_valid_o(gate_pcs_tx_val), .phy_tx_frame_o(gate_pcs_tx_frm), .tx_sync_hdr_o(gate_pcs_shdr),
    .tx_crc16_o(gate_pcs_crc), .tx_meta_o(gate_pcs_meta), .tx_scrambled_payload_o(gate_pcs_spay),
    .replay_active_o(gate_pcs_rep), .tx_seq_num_o(gate_pcs_tseq),
    .phy_rx_valid_i(pcs_rx_valid), .phy_rx_frame_i(pcs_rx_frame),
    .rx_flit_valid_o(gate_pcs_rx_val), .rx_flit_data_o(gate_pcs_rx_dat), .rx_dst_chip_o(gate_pcs_rdst),
    .rx_hop_cnt_o(gate_pcs_rhop), .rx_opcode_o(gate_pcs_rop), .rx_seq_num_o(gate_pcs_rseq),
    .rx_crc16_err_o(gate_pcs_cerr), .rx_sync_err_o(gate_pcs_serr), .nack_req_o(gate_pcs_nreq),
    .nack_seq_o(gate_pcs_nseq), .link_state_o(gate_pcs_st), .link_up_o(gate_pcs_up), .measured_skew_o(gate_pcs_skew)
  );

  // ---------------------------------------------------------------------------
  // 5. groq_pcie_c2c_dma (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic [15:0]  dma_gcyc, dma_pay_par;
  logic         dma_vwin, dma_sbusy, dma_wbusy, dma_ebusy, dma_dval, dma_pval;
  logic [127:0] dma_ddat, dma_pdat;
  logic         gold_dma_drdy, gate_dma_drdy, gold_dma_full, gate_dma_full, gold_dma_emp, gate_dma_emp;
  logic [1:0]   gold_dma_hptr, gate_dma_hptr, gold_dma_tptr, gate_dma_tptr, gold_dma_wbk, gate_dma_wbk, gold_dma_ebk, gate_dma_ebk;
  logic [2:0]   gold_dma_dcnt, gate_dma_dcnt, gold_dma_islc, gate_dma_islc;
  logic         gold_dma_prdy, gate_dma_prdy, gold_dma_iwen, gate_dma_iwen, gold_dma_wwen, gate_dma_wwen, gold_dma_ewen, gate_dma_ewen;
  logic [15:0]  gold_dma_iadr, gate_dma_iadr, gold_dma_wadr, gate_dma_wadr, gold_dma_eadr, gate_dma_eadr, gold_dma_btr, gate_dma_btr;
  logic [143:0] gold_dma_idat, gate_dma_idat;
  logic [127:0] gold_dma_wdat, gate_dma_wdat, gold_dma_edat, gate_dma_edat;
  logic         gold_dma_bsy, gate_dma_bsy, gold_dma_stl, gate_dma_stl, gold_dma_perr, gate_dma_perr, gold_dma_irq, gate_dma_irq;
  logic [7:0]   gold_dma_cdsc, gate_dma_cdsc;

  groq_pcie_c2c_dma gold_pcie_c2c_dma (
    .clk(clk), .rst_n(rst_n), .global_cycle_i(dma_gcyc), .vliw_active_window_i(dma_vwin),
    .vliw_sram_busy_i(dma_sbusy), .vliw_sram_w_busy_i(dma_wbusy), .vliw_sram_e_busy_i(dma_ebusy),
    .desc_push_valid_i(dma_dval), .desc_push_data_i(dma_ddat), .desc_push_ready_o(gold_dma_drdy),
    .full_o(gold_dma_full), .empty_o(gold_dma_emp), .head_ptr_o(gold_dma_hptr), .tail_ptr_o(gold_dma_tptr),
    .desc_count_o(gold_dma_dcnt), .dma_payload_valid_i(dma_pval), .dma_payload_data_i(dma_pdat),
    .dma_payload_parity_i(dma_pay_par), .dma_payload_ready_o(gold_dma_prdy),
    .imem_wr_en_o(gold_dma_iwen), .imem_wr_slice_o(gold_dma_islc), .imem_wr_addr_o(gold_dma_iadr), .imem_wr_data_o(gold_dma_idat),
    .host_mem_w_wr_en_o(gold_dma_wwen), .host_mem_w_bank_o(gold_dma_wbk), .host_mem_w_addr_o(gold_dma_wadr), .host_mem_w_data_o(gold_dma_wdat),
    .host_mem_e_wr_en_o(gold_dma_ewen), .host_mem_e_bank_o(gold_dma_ebk), .host_mem_e_addr_o(gold_dma_eadr), .host_mem_e_data_o(gold_dma_edat),
    .dma_busy_o(gold_dma_bsy), .dma_window_stall_o(gold_dma_stl), .payload_parity_err_o(gold_dma_perr),
    .dma_done_irq_o(gold_dma_irq), .completed_desc_cnt_o(gold_dma_cdsc), .beats_transferred_o(gold_dma_btr)
  );
  groq_pcie_c2c_dma_gate gate_pcie_c2c_dma (
    .clk(clk), .rst_n(rst_n), .global_cycle_i(dma_gcyc), .vliw_active_window_i(dma_vwin),
    .vliw_sram_busy_i(dma_sbusy), .vliw_sram_w_busy_i(dma_wbusy), .vliw_sram_e_busy_i(dma_ebusy),
    .desc_push_valid_i(dma_dval), .desc_push_data_i(dma_ddat), .desc_push_ready_o(gate_dma_drdy),
    .full_o(gate_dma_full), .empty_o(gate_dma_emp), .head_ptr_o(gate_dma_hptr), .tail_ptr_o(gate_dma_tptr),
    .desc_count_o(gate_dma_dcnt), .dma_payload_valid_i(dma_pval), .dma_payload_data_i(dma_pdat),
    .dma_payload_parity_i(dma_pay_par), .dma_payload_ready_o(gate_dma_prdy),
    .imem_wr_en_o(gate_dma_iwen), .imem_wr_slice_o(gate_dma_islc), .imem_wr_addr_o(gate_dma_iadr), .imem_wr_data_o(gate_dma_idat),
    .host_mem_w_wr_en_o(gate_dma_wwen), .host_mem_w_bank_o(gate_dma_wbk), .host_mem_w_addr_o(gate_dma_wadr), .host_mem_w_data_o(gate_dma_wdat),
    .host_mem_e_wr_en_o(gate_dma_ewen), .host_mem_e_bank_o(gate_dma_ebk), .host_mem_e_addr_o(gate_dma_eadr), .host_mem_e_data_o(gate_dma_edat),
    .dma_busy_o(gate_dma_bsy), .dma_window_stall_o(gate_dma_stl), .payload_parity_err_o(gate_dma_perr),
    .dma_done_irq_o(gate_dma_irq), .completed_desc_cnt_o(gate_dma_cdsc), .beats_transferred_o(gate_dma_btr)
  );

  // ---------------------------------------------------------------------------
  // 6. groq_mxfp8_nvfp4_dot_engine (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic         dot_val, dot_zskip, dot_acc_en, dot_acc_clr;
  logic [2:0]   dot_mode;
  logic [7:0]   dot_ascale, dot_wscale;
  logic [127:0] dot_act, dot_wt;
  logic         gold_dot_val, gate_dot_val, gold_dot_bzero, gate_dot_bzero, gold_dot_nan, gate_dot_nan;
  logic signed [31:0] gold_dot_unacc, gate_dot_unacc, gold_dot_acc, gate_dot_acc;
  logic [31:0]  gold_dot_fp32, gate_dot_fp32;
  logic [5:0]   gold_dot_zlanes, gate_dot_zlanes;

  groq_mxfp8_nvfp4_dot_engine gold_mxfp8_nvfp4_dot_engine (
    .clk(clk), .rst_n(rst_n), .valid_i(dot_val), .mode_i(dot_mode), .zero_skip_en_i(dot_zskip),
    .accum_en_i(dot_acc_en), .accum_clear_i(dot_acc_clr), .act_scale_e8m0_i(dot_ascale), .wt_scale_e8m0_i(dot_wscale),
    .act_stream_i(dot_act), .wt_stream_i(dot_wt), .valid_o(gold_dot_val), .unaccum_dot_o(gold_dot_unacc),
    .dot_accum_o(gold_dot_acc), .dot_fp32_o(gold_dot_fp32), .zero_skip_lanes_o(gold_dot_zlanes),
    .block_zero_skipped_o(gold_dot_bzero), .nan_inf_flag_o(gold_dot_nan)
  );
  groq_mxfp8_nvfp4_dot_engine_gate gate_mxfp8_nvfp4_dot_engine (
    .clk(clk), .rst_n(rst_n), .valid_i(dot_val), .mode_i(dot_mode), .zero_skip_en_i(dot_zskip),
    .accum_en_i(dot_acc_en), .accum_clear_i(dot_acc_clr), .act_scale_e8m0_i(dot_ascale), .wt_scale_e8m0_i(dot_wscale),
    .act_stream_i(dot_act), .wt_stream_i(dot_wt), .valid_o(gate_dot_val), .unaccum_dot_o(gate_dot_unacc),
    .dot_accum_o(gate_dot_acc), .dot_fp32_o(gate_dot_fp32), .zero_skip_lanes_o(gate_dot_zlanes),
    .block_zero_skipped_o(gate_dot_bzero), .nan_inf_flag_o(gate_dot_nan)
  );

  // ---------------------------------------------------------------------------
  // 7. groq_sxm_slice (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic [3:0]   sxm_op, sxm_shf, sxm_src, sxm_bfly, sxm_trp;
  logic         sxm_rope, sxm_in_val;
  logic [127:0] sxm_in_dat;
  logic         gold_sxm_oval, gate_sxm_oval;
  logic [127:0] gold_sxm_odat, gate_sxm_odat, gold_sxm_pcomb, gate_sxm_pcomb;

  groq_sxm_slice gold_sxm_slice (
    .clk(clk), .rst_n(rst_n), .sxm_op_i(sxm_op), .shift_amt_i(sxm_shf), .src_lane_i(sxm_src),
    .butterfly_mask_i(sxm_bfly), .transpose_idx_i(sxm_trp), .rope_neg_even_en_i(sxm_rope),
    .stream_in_valid_i(sxm_in_val), .stream_in_data_i(sxm_in_dat),
    .stream_out_valid_o(gold_sxm_oval), .stream_out_data_o(gold_sxm_odat), .perm_comb_data_o(gold_sxm_pcomb)
  );
  groq_sxm_slice_gate gate_sxm_slice (
    .clk(clk), .rst_n(rst_n), .sxm_op_i(sxm_op), .shift_amt_i(sxm_shf), .src_lane_i(sxm_src),
    .butterfly_mask_i(sxm_bfly), .transpose_idx_i(sxm_trp), .rope_neg_even_en_i(sxm_rope),
    .stream_in_valid_i(sxm_in_val), .stream_in_data_i(sxm_in_dat),
    .stream_out_valid_o(gate_sxm_oval), .stream_out_data_o(gate_sxm_odat), .perm_comb_data_o(gate_sxm_pcomb)
  );

  // ---------------------------------------------------------------------------
  // 8. groq_nim_realsync (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic         nim_val, nim_ugal, nim_cong, nim_lin_val, nim_rx_val;
  logic [3:0]   nim_op, nim_lchip, nim_tdst, nim_rx_dst;
  logic [15:0]  nim_atime, nim_flight, nim_rx_ts;
  logic [127:0] nim_lin_dat, nim_rx_dat;
  logic [7:0]   nim_rx_crc;
  logic         gold_nim_lout_val, gate_nim_lout_val, gold_nim_tx_val, gate_nim_tx_val;
  logic [127:0] gold_nim_lout_dat, gate_nim_lout_dat, gold_nim_tx_dat, gate_nim_tx_dat;
  logic [15:0]  gold_nim_tx_ts, gate_nim_tx_ts, gold_nim_drel_cyc, gate_nim_drel_cyc;
  logic [3:0]   gold_nim_tx_dst, gate_nim_tx_dst;
  logic [7:0]   gold_nim_tx_crc, gate_nim_tx_crc;
  logic [1:0]   gold_nim_tx_psel, gate_nim_tx_psel;
  logic         gold_nim_drel_val, gate_nim_drel_val, gold_nim_pack, gate_nim_pack, gold_nim_cerr, gate_nim_cerr;
  logic signed [15:0] gold_nim_skew, gate_nim_skew;

  groq_nim_realsync gold_nim_realsync (
    .clk(clk), .rst_n(rst_n), .op_valid_i(nim_val), .nim_op_i(nim_op),
    .realsync_aligned_time_i(nim_atime), .expected_flight_cycles_i(nim_flight),
    .local_chip_id_i(nim_lchip), .tx_dst_chip_i(nim_tdst), .ugal_nonminimal_en_i(nim_ugal), .link_congested_i(nim_cong),
    .local_stream_in_valid_i(nim_lin_val), .local_stream_in_data_i(nim_lin_dat),
    .local_stream_out_valid_o(gold_nim_lout_val), .local_stream_out_data_o(gold_nim_lout_dat),
    .c2c_rx_valid_i(nim_rx_val), .c2c_rx_data_i(nim_rx_dat), .c2c_rx_tx_timestamp_i(nim_rx_ts),
    .c2c_rx_dst_chip_i(nim_rx_dst), .c2c_rx_crc8_i(nim_rx_crc),
    .c2c_tx_valid_o(gold_nim_tx_val), .c2c_tx_data_o(gold_nim_tx_dat), .c2c_tx_timestamp_o(gold_nim_tx_ts),
    .c2c_tx_dst_chip_o(gold_nim_tx_dst), .c2c_tx_crc8_o(gold_nim_tx_crc), .c2c_tx_port_sel_o(gold_nim_tx_psel),
    .deskew_release_valid_o(gold_nim_drel_val), .deskew_released_target_cycle_o(gold_nim_drel_cyc),
    .realsync_ping_ack_o(gold_nim_pack), .measured_skew_o(gold_nim_skew), .crc_err_o(gold_nim_cerr)
  );
  groq_nim_realsync_gate gate_nim_realsync (
    .clk(clk), .rst_n(rst_n), .op_valid_i(nim_val), .nim_op_i(nim_op),
    .realsync_aligned_time_i(nim_atime), .expected_flight_cycles_i(nim_flight),
    .local_chip_id_i(nim_lchip), .tx_dst_chip_i(nim_tdst), .ugal_nonminimal_en_i(nim_ugal), .link_congested_i(nim_cong),
    .local_stream_in_valid_i(nim_lin_val), .local_stream_in_data_i(nim_lin_dat),
    .local_stream_out_valid_o(gate_nim_lout_val), .local_stream_out_data_o(gate_nim_lout_dat),
    .c2c_rx_valid_i(nim_rx_val), .c2c_rx_data_i(nim_rx_dat), .c2c_rx_tx_timestamp_i(nim_rx_ts),
    .c2c_rx_dst_chip_i(nim_rx_dst), .c2c_rx_crc8_i(nim_rx_crc),
    .c2c_tx_valid_o(gate_nim_tx_val), .c2c_tx_data_o(gate_nim_tx_dat), .c2c_tx_timestamp_o(gate_nim_tx_ts),
    .c2c_tx_dst_chip_o(gate_nim_tx_dst), .c2c_tx_crc8_o(gate_nim_tx_crc), .c2c_tx_port_sel_o(gate_nim_tx_psel),
    .deskew_release_valid_o(gate_nim_drel_val), .deskew_released_target_cycle_o(gate_nim_drel_cyc),
    .realsync_ping_ack_o(gate_nim_pack), .measured_skew_o(gate_nim_skew), .crc_err_o(gate_nim_cerr)
  );

  // ---------------------------------------------------------------------------
  // 9. groq_spec_decode_tree_sampler (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic         sdt_val, sdt_rng_step;
  logic [1:0]   sdt_mode;
  logic [127:0] sdt_logits, sdt_tok_ids;
  logic [3:0]   sdt_top_k;
  logic [7:0]   sdt_inv_temp, sdt_rng_th, sdt_bonus_tok;
  logic [15:0]  sdt_top_p;
  logic [23:0]  sdt_tree_pidx;
  logic [63:0]  sdt_tree_dprob, sdt_tree_tprob, sdt_tree_rand, sdt_tree_dtok;
  logic         gold_sdt_oval, gate_sdt_oval;
  logic [7:0]   gold_sdt_stok, gate_sdt_stok, gold_sdt_slog, gate_sdt_slog, gold_sdt_amask, gate_sdt_amask;
  logic [127:0] gold_sdt_slogits, gate_sdt_slogits, gold_sdt_stokens, gate_sdt_stokens;
  logic [15:0]  gold_sdt_nmask, gate_sdt_nmask;
  logic [2:0]   gold_sdt_bleaf, gate_sdt_bleaf, gold_sdt_alen, gate_sdt_alen, gold_sdt_temit, gate_sdt_temit, gold_sdt_kvadv, gate_sdt_kvadv;
  logic [39:0]  gold_sdt_ctoks, gate_sdt_ctoks;
  logic [31:0]  gold_sdt_prng, gate_sdt_prng;

  groq_spec_decode_tree_sampler gold_spec_decode_tree_sampler (
    .clk(clk), .rst_n(rst_n), .valid_i(sdt_val), .op_mode_i(sdt_mode),
    .logits_i(sdt_logits), .token_ids_i(sdt_tok_ids), .top_k_i(sdt_top_k),
    .inv_temp_i(sdt_inv_temp), .top_p_thresh_i(sdt_top_p), .rng_seed_step_i(sdt_rng_step), .rng_threshold_i(sdt_rng_th),
    .tree_parent_idx_i(sdt_tree_pidx), .tree_draft_prob_i(sdt_tree_dprob), .tree_target_prob_i(sdt_tree_tprob),
    .tree_rand_u_i(sdt_tree_rand), .tree_draft_tok_i(sdt_tree_dtok), .bonus_tok_i(sdt_bonus_tok),
    .valid_o(gold_sdt_oval), .selected_token_o(gold_sdt_stok), .selected_logit_o(gold_sdt_slog),
    .sorted_logits_o(gold_sdt_slogits), .sorted_tokens_o(gold_sdt_stokens), .nucleus_mask_o(gold_sdt_nmask),
    .accepted_node_mask_o(gold_sdt_amask), .best_leaf_idx_o(gold_sdt_bleaf), .accepted_draft_len_o(gold_sdt_alen),
    .total_emitted_tokens_o(gold_sdt_temit), .committed_tokens_o(gold_sdt_ctoks), .kv_ring_advance_o(gold_sdt_kvadv), .prng_state_o(gold_sdt_prng)
  );
  groq_spec_decode_tree_sampler_gate gate_spec_decode_tree_sampler (
    .clk(clk), .rst_n(rst_n), .valid_i(sdt_val), .op_mode_i(sdt_mode),
    .logits_i(sdt_logits), .token_ids_i(sdt_tok_ids), .top_k_i(sdt_top_k),
    .inv_temp_i(sdt_inv_temp), .top_p_thresh_i(sdt_top_p), .rng_seed_step_i(sdt_rng_step), .rng_threshold_i(sdt_rng_th),
    .tree_parent_idx_i(sdt_tree_pidx), .tree_draft_prob_i(sdt_tree_dprob), .tree_target_prob_i(sdt_tree_tprob),
    .tree_rand_u_i(sdt_tree_rand), .tree_draft_tok_i(sdt_tree_dtok), .bonus_tok_i(sdt_bonus_tok),
    .valid_o(gate_sdt_oval), .selected_token_o(gate_sdt_stok), .selected_logit_o(gate_sdt_slog),
    .sorted_logits_o(gate_sdt_slogits), .sorted_tokens_o(gate_sdt_stokens), .nucleus_mask_o(gate_sdt_nmask),
    .accepted_node_mask_o(gate_sdt_amask), .best_leaf_idx_o(gate_sdt_bleaf), .accepted_draft_len_o(gate_sdt_alen),
    .total_emitted_tokens_o(gate_sdt_temit), .committed_tokens_o(gate_sdt_ctoks), .kv_ring_advance_o(gate_sdt_kvadv), .prng_state_o(gate_sdt_prng)
  );

  // ---------------------------------------------------------------------------
  // 10. groq_power_droop_controller (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic        droop_en, droop_prewarm;
  logic [7:0]  droop_slice_act, droop_pw_target, droop_max_step;
  logic [5:0]  droop_zskip_cnt;
  logic [11:0] droop_vdd_nom, droop_emerg_th;
  logic [7:0]  gold_drp_raw, gate_drp_raw, gold_drp_eff, gate_drp_eff, gold_drp_bleed, gate_drp_bleed, gold_drp_bmask, gate_drp_bmask, gold_drp_temp, gate_drp_temp;
  logic signed [8:0] gold_drp_didt, gate_drp_didt;
  logic [11:0] gold_drp_vdd, gate_drp_vdd;
  logic        gold_drp_throt, gate_drp_throt;
  logic [15:0] gold_drp_evts, gate_drp_evts;

  groq_power_droop_controller gold_power_droop_controller (
    .clk(clk), .rst_n(rst_n), .enable_i(droop_en), .slice_active_i(droop_slice_act), .mxm_zero_skip_cnt_i(droop_zskip_cnt),
    .prewarm_hint_i(droop_prewarm), .prewarm_target_level_i(droop_pw_target), .max_didt_step_i(droop_max_step),
    .vdd_nominal_mv_i(droop_vdd_nom), .droop_emerg_thresh_mv_i(droop_emerg_th),
    .raw_demand_o(gold_drp_raw), .eff_current_o(gold_drp_eff), .dummy_bleed_current_o(gold_drp_bleed),
    .dummy_bleed_mask_o(gold_drp_bmask), .didt_signed_o(gold_drp_didt), .vdd_est_mv_o(gold_drp_vdd),
    .thermal_temp_c_o(gold_drp_temp), .emerg_throttle_o(gold_drp_throt), .droop_mitigated_events_o(gold_drp_evts)
  );
  groq_power_droop_controller_gate gate_power_droop_controller (
    .clk(clk), .rst_n(rst_n), .enable_i(droop_en), .slice_active_i(droop_slice_act), .mxm_zero_skip_cnt_i(droop_zskip_cnt),
    .prewarm_hint_i(droop_prewarm), .prewarm_target_level_i(droop_pw_target), .max_didt_step_i(droop_max_step),
    .vdd_nominal_mv_i(droop_vdd_nom), .droop_emerg_thresh_mv_i(droop_emerg_th),
    .raw_demand_o(gate_drp_raw), .eff_current_o(gate_drp_eff), .dummy_bleed_current_o(gate_drp_bleed),
    .dummy_bleed_mask_o(gate_drp_bmask), .didt_signed_o(gate_drp_didt), .vdd_est_mv_o(gate_drp_vdd),
    .thermal_temp_c_o(gate_drp_temp), .emerg_throttle_o(gate_drp_throt), .droop_mitigated_events_o(gate_drp_evts)
  );

  // ---------------------------------------------------------------------------
  // 11. groq_sram_controller_scrubber (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic         scb_efuse_req, scb_vliw_ren, scb_vliw_wen, scb_dma_wen, scb_scrub_en, scb_ser_en;
  logic [1:0]   scb_efuse_bank, scb_efuse_addr, scb_vliw_rbank, scb_vliw_raddr, scb_vliw_wbank, scb_vliw_waddr, scb_dma_wbank, scb_dma_waddr, scb_ser_bank, scb_ser_addr;
  logic [127:0] scb_vliw_wdata, scb_dma_wdata;
  logic [143:0] scb_ser_mask;
  logic [3:0]   gold_scb_repen, gate_scb_repen;
  logic [7:0]   gold_scb_repadr, gate_scb_repadr;
  logic         gold_scb_efack, gate_scb_efack, gold_scb_rval, gate_scb_rval, gold_scb_rsec, gate_scb_rsec, gold_scb_rded, gate_scb_rded, gold_scb_rhit, gate_scb_rhit;
  logic [127:0] gold_scb_rdat, gate_scb_rdat;
  logic         gold_scb_rdfire, gate_scb_rdfire, gold_scb_wbfire, gate_scb_wbfire, gold_scb_dedal, gate_scb_dedal;
  logic [1:0]   gold_scb_abank, gate_scb_abank, gold_scb_aaddr, gate_scb_aaddr, gold_scb_fbank, gate_scb_fbank, gold_scb_faddr, gate_scb_faddr;
  logic [15:0]  gold_scb_ccnt, gate_scb_ccnt;

  groq_sram_controller_scrubber #(.P_ADDR_W(2)) gold_sram_controller_scrubber (
    .clk(clk), .rst_n(rst_n), .efuse_load_req_i(scb_efuse_req), .efuse_bank_i(scb_efuse_bank), .efuse_bad_addr_i(scb_efuse_addr),
    .bank_repair_en_o(gold_scb_repen), .bank_repair_addr_o(gold_scb_repadr), .efuse_load_ack_o(gold_scb_efack),
    .vliw_rd_en_i(scb_vliw_ren), .vliw_rd_bank_i(scb_vliw_rbank), .vliw_rd_addr_i(scb_vliw_raddr),
    .vliw_rd_valid_o(gold_scb_rval), .vliw_rd_data_o(gold_scb_rdat), .vliw_rd_sec_err_o(gold_scb_rsec),
    .vliw_rd_ded_err_o(gold_scb_rded), .vliw_rd_repaired_row_hit_o(gold_scb_rhit),
    .vliw_wr_en_i(scb_vliw_wen), .vliw_wr_bank_i(scb_vliw_wbank), .vliw_wr_addr_i(scb_vliw_waddr), .vliw_wr_data_i(scb_vliw_wdata),
    .dma_wr_en_i(scb_dma_wen), .dma_wr_bank_i(scb_dma_wbank), .dma_wr_addr_i(scb_dma_waddr), .dma_wr_data_i(scb_dma_wdata),
    .scrub_enable_i(scb_scrub_en), .scrub_rd_fire_o(gold_scb_rdfire), .scrub_wb_fire_o(gold_scb_wbfire),
    .scrub_active_bank_o(gold_scb_abank), .scrub_active_addr_o(gold_scb_aaddr), .scrub_corrected_cnt_o(gold_scb_ccnt),
    .scrub_ded_alert_o(gold_scb_dedal), .first_ded_bank_o(gold_scb_fbank), .first_ded_addr_o(gold_scb_faddr),
    .ser_inject_en_i(scb_ser_en), .ser_inject_bank_i(scb_ser_bank), .ser_inject_addr_i(scb_ser_addr), .ser_inject_mask_i(scb_ser_mask)
  );
  groq_sram_controller_scrubber_gate gate_sram_controller_scrubber (
    .clk(clk), .rst_n(rst_n), .efuse_load_req_i(scb_efuse_req), .efuse_bank_i(scb_efuse_bank), .efuse_bad_addr_i(scb_efuse_addr),
    .bank_repair_en_o(gate_scb_repen), .bank_repair_addr_o(gate_scb_repadr), .efuse_load_ack_o(gate_scb_efack),
    .vliw_rd_en_i(scb_vliw_ren), .vliw_rd_bank_i(scb_vliw_rbank), .vliw_rd_addr_i(scb_vliw_raddr),
    .vliw_rd_valid_o(gate_scb_rval), .vliw_rd_data_o(gate_scb_rdat), .vliw_rd_sec_err_o(gate_scb_rsec),
    .vliw_rd_ded_err_o(gate_scb_rded), .vliw_rd_repaired_row_hit_o(gate_scb_rhit),
    .vliw_wr_en_i(scb_vliw_wen), .vliw_wr_bank_i(scb_vliw_wbank), .vliw_wr_addr_i(scb_vliw_waddr), .vliw_wr_data_i(scb_vliw_wdata),
    .dma_wr_en_i(scb_dma_wen), .dma_wr_bank_i(scb_dma_wbank), .dma_wr_addr_i(scb_dma_waddr), .dma_wr_data_i(scb_dma_wdata),
    .scrub_enable_i(scb_scrub_en), .scrub_rd_fire_o(gate_scb_rdfire), .scrub_wb_fire_o(gate_scb_wbfire),
    .scrub_active_bank_o(gate_scb_abank), .scrub_active_addr_o(gate_scb_aaddr), .scrub_corrected_cnt_o(gate_scb_ccnt),
    .scrub_ded_alert_o(gate_scb_dedal), .first_ded_bank_o(gate_scb_fbank), .first_ded_addr_o(gate_scb_faddr),
    .ser_inject_en_i(scb_ser_en), .ser_inject_bank_i(scb_ser_bank), .ser_inject_addr_i(scb_ser_addr), .ser_inject_mask_i(scb_ser_mask)
  );

  // ---------------------------------------------------------------------------
  // 12. groq_c2c_kv_quant_rx_engine (Golden RTL vs. ASAP7 Gate-Level Netlist)
  // ---------------------------------------------------------------------------
  logic         kvq_val;
  logic [1:0]   kvq_mode, kvq_bank;
  logic [127:0] kvq_lo, kvq_hi;
  logic [15:0]  kvq_addr;
  logic         gold_kvq_oval, gate_kvq_oval, gold_kvq_wren, gate_kvq_wren, gold_kvq_nan, gate_kvq_nan;
  logic [127:0] gold_kvq_vec, gate_kvq_vec;
  logic [7:0]   gold_kvq_scale, gate_kvq_scale;
  logic [1:0]   gold_kvq_wbank, gate_kvq_wbank, gold_kvq_crat, gate_kvq_crat;
  logic [15:0]  gold_kvq_waddr, gate_kvq_waddr;
  logic [4:0]   gold_kvq_zcnt, gate_kvq_zcnt;

  groq_c2c_kv_quant_rx_engine gold_c2c_kv_quant_rx_engine (
    .clk(clk), .rst_n(rst_n), .valid_i(kvq_val), .quant_mode_i(kvq_mode),
    .kv_in_lo_i(kvq_lo), .kv_in_hi_i(kvq_hi), .target_sram_bank_i(kvq_bank), .target_sram_addr_i(kvq_addr),
    .valid_o(gold_kvq_oval), .quant_vec_o(gold_kvq_vec), .scale_e8m0_o(gold_kvq_scale),
    .sram_wr_en_o(gold_kvq_wren), .sram_wr_bank_o(gold_kvq_wbank), .sram_wr_addr_o(gold_kvq_waddr),
    .zero_lanes_cnt_o(gold_kvq_zcnt), .nan_inf_clamped_o(gold_kvq_nan), .compression_ratio_code_o(gold_kvq_crat)
  );
  groq_c2c_kv_quant_rx_engine_gate gate_c2c_kv_quant_rx_engine (
    .clk(clk), .rst_n(rst_n), .valid_i(kvq_val), .quant_mode_i(kvq_mode),
    .kv_in_lo_i(kvq_lo), .kv_in_hi_i(kvq_hi), .target_sram_bank_i(kvq_bank), .target_sram_addr_i(kvq_addr),
    .valid_o(gate_kvq_oval), .quant_vec_o(gate_kvq_vec), .scale_e8m0_o(gate_kvq_scale),
    .sram_wr_en_o(gate_kvq_wren), .sram_wr_bank_o(gate_kvq_wbank), .sram_wr_addr_o(gate_kvq_waddr),
    .zero_lanes_cnt_o(gate_kvq_zcnt), .nan_inf_clamped_o(gate_kvq_nan), .compression_ratio_code_o(gate_kvq_crat)
  );



  // ---------------------------------------------------------------------------
  // Deterministic PRNG Helper & Stimulus Driver (5,220 Cycles Total)
  // ---------------------------------------------------------------------------
  logic [63:0] lfsr = 64'hCAFE_BABE_1337_BEEF;
  function automatic logic [63:0] next_rng(input logic [63:0] s);
    logic [63:0] x = s;
    x ^= (x << 13);
    x ^= (x >> 7);
    x ^= (x << 17);
    return x;
  endfunction

  always_ff @(posedge clk) begin
    cycle_cnt <= cycle_cnt + 1;
    if (cycle_cnt < 20) begin
      rst_n     <= 1'b0;
      sim_phase <= 0;
      ecc_valid_in <= 1'b0; ecc_data_in <= '0; ecc_codeword_in <= '0;
      agu_cfg_load <= 1'b0; agu_cfg_mode <= '0; agu_base_addr <= '0;
      agu_stride_0 <= '0; agu_stride_1 <= '0; agu_count_0 <= '0; agu_count_1 <= '0;
      agu_step_en  <= 1'b0; agu_gather_off <= '0;
      icu_en <= 1'b0; icu_imem_bundle <= '0; icu_notify_ready <= '0;
      icu_adj_en <= 1'b0; icu_adj_val <= '0;
      pcs_link_en <= 1'b0; pcs_scram_en <= 1'b0; pcs_ts1 <= 1'b0; pcs_ts2 <= 1'b0;
      pcs_deskew <= 1'b0; pcs_retrain <= 1'b0; pcs_local_ts <= '0; pcs_rx_beacon <= '0;
      pcs_tx_valid <= 1'b0; pcs_tx_data <= '0; pcs_tx_dst <= '0; pcs_tx_hop <= '0; pcs_tx_op <= '0;
      pcs_nack_req <= 1'b0; pcs_nack_seq <= '0; pcs_rx_valid <= 1'b0; pcs_rx_frame <= '0;
      dma_gcyc <= '0; dma_vwin <= 1'b0; dma_sbusy <= 1'b0; dma_wbusy <= 1'b0; dma_ebusy <= 1'b0;
      dma_dval <= 1'b0; dma_ddat <= '0; dma_pval <= 1'b0; dma_pdat <= '0; dma_pay_par <= '0;
      dot_val <= 1'b0; dot_mode <= '0; dot_zskip <= 1'b0; dot_acc_en <= 1'b0; dot_acc_clr <= 1'b0;
      dot_ascale <= 8'h7F; dot_wscale <= 8'h7F; dot_act <= '0; dot_wt <= '0;
      sxm_op <= '0; sxm_shf <= '0; sxm_src <= '0; sxm_bfly <= '0; sxm_trp <= '0;
      sxm_rope <= 1'b0; sxm_in_val <= 1'b0; sxm_in_dat <= '0;
      nim_val <= 1'b0; nim_op <= '0; nim_atime <= '0; nim_flight <= 16'd4;
      nim_lchip <= 4'd1; nim_tdst <= 4'd2; nim_ugal <= 1'b0; nim_cong <= 1'b0;
      nim_lin_val <= 1'b0; nim_lin_dat <= '0; nim_rx_val <= 1'b0; nim_rx_dat <= '0;
      nim_rx_ts <= '0; nim_rx_dst <= '0; nim_rx_crc <= '0;
      sdt_val <= 1'b0; sdt_mode <= '0; sdt_logits <= '0; sdt_tok_ids <= '0;
      sdt_top_k <= 4'd4; sdt_inv_temp <= 8'd16; sdt_top_p <= 16'h8000; sdt_rng_step <= 1'b0; sdt_rng_th <= '0;
      sdt_tree_pidx <= '0; sdt_tree_dprob <= '0; sdt_tree_tprob <= '0; sdt_tree_rand <= '0; sdt_tree_dtok <= '0; sdt_bonus_tok <= '0;
      droop_en <= 1'b0; droop_slice_act <= '0; droop_zskip_cnt <= '0; droop_prewarm <= 1'b0;
      droop_pw_target <= 8'd160; droop_max_step <= 8'd16; droop_vdd_nom <= 12'd800; droop_emerg_th <= 12'd720;
      scb_efuse_req <= 1'b0; scb_efuse_bank <= '0; scb_efuse_addr <= '0;
      scb_vliw_ren <= 1'b0; scb_vliw_rbank <= '0; scb_vliw_raddr <= '0;
      scb_vliw_wen <= 1'b0; scb_vliw_wbank <= '0; scb_vliw_waddr <= '0; scb_vliw_wdata <= '0;
      scb_dma_wen <= 1'b0; scb_dma_wbank <= '0; scb_dma_waddr <= '0; scb_dma_wdata <= '0;
      scb_scrub_en <= 1'b0; scb_ser_en <= 1'b0; scb_ser_bank <= '0; scb_ser_addr <= '0; scb_ser_mask <= '0;
      kvq_val <= 1'b0; kvq_mode <= '0; kvq_lo <= '0; kvq_hi <= '0; kvq_bank <= '0; kvq_addr <= '0;
    end else if (cycle_cnt < 3220) begin
      // PHASE 1 (3,000 cycles): Active LLM Inference & Randomized Stress Workload
      rst_n     <= 1'b1;
      sim_phase <= 1;
      lfsr      <= next_rng(lfsr);
      // 1. ECC SECDED: active encode + single/double bit flip injection
      ecc_valid_in    <= 1'b1;
      ecc_data_in     <= lfsr ^ {32'hA5A5_5A5A, cycle_cnt};
      ecc_codeword_in <= gold_codeword_out ^ ((cycle_cnt % 3 == 0) ? (72'd1 << (cycle_cnt % 72)) :
                         ((cycle_cnt % 7 == 0) ? ((72'd1 << (cycle_cnt % 70)) | (72'd1 << ((cycle_cnt + 11) % 70))) : 72'd0));
      // 2. AGU: periodic descriptor load + continuous step_en
      agu_cfg_load   <= (cycle_cnt % 40 == 20);
      agu_cfg_mode   <= cycle_cnt[7:6];
      agu_base_addr  <= lfsr[9:0];
      agu_stride_0   <= {6'd0, lfsr[13:10]} | 10'd1;
      agu_stride_1   <= {5'd0, lfsr[18:14]} | 10'd4;
      agu_count_0    <= 10'd6;
      agu_count_1    <= 10'd5;
      agu_step_en    <= (cycle_cnt % 40 != 20);
      agu_gather_off <= lfsr[28:19];
      // 3. ICU: active VLIW bundle dispatch, periodic SYNC/NOTIFY & RealSync adjust
      icu_en           <= 1'b1;
      icu_imem_bundle  <= {8{{4'd0, 16'd0, lfsr[63:0], lfsr[59:0]}}};
      icu_notify_ready <= lfsr[7:0] | 8'hFF;
      icu_adj_en       <= (cycle_cnt % 100 == 50);
      icu_adj_val      <= $signed(lfsr[19:4]) >>> 11;
      // 4. C2C SerDes PCS: link up training + continuous 64B/66B scrambled loopback
      pcs_link_en   <= 1'b1;
      pcs_scram_en  <= 1'b1;
      pcs_ts1       <= (cycle_cnt >= 22);
      pcs_ts2       <= (cycle_cnt >= 26);
      pcs_deskew    <= (cycle_cnt >= 30);
      pcs_retrain   <= (cycle_cnt == 1500);
      pcs_local_ts  <= cycle_cnt[7:0];
      pcs_rx_beacon <= cycle_cnt[7:0] - 8'd3;
      pcs_tx_valid  <= (cycle_cnt >= 35) && (cycle_cnt % 5 != 0);
      pcs_tx_data   <= {lfsr, ~lfsr};
      pcs_tx_dst    <= lfsr[3:0];
      pcs_tx_hop    <= lfsr[7:4];
      pcs_tx_op     <= lfsr[11:8];
      pcs_nack_req  <= (cycle_cnt % 250 == 120);
      pcs_nack_seq  <= lfsr[1:0];
      pcs_rx_valid  <= gold_pcs_tx_val;
      pcs_rx_frame  <= gold_pcs_tx_frm;
      // 5. PCIe/C2C DMA: active descriptor ring push & streaming payload beats
      dma_gcyc    <= cycle_cnt[15:0];
      dma_vwin    <= (cycle_cnt % 16 == 0);
      dma_sbusy   <= 1'b0; dma_wbusy <= 1'b0; dma_ebusy <= 1'b0;
      dma_dval    <= (cycle_cnt % 12 == 25 % 12);
      dma_ddat    <= {56'h1234_5678_9ABC_DE, lfsr[15:0], 16'd0, 8'd2, 8'd1, lfsr[31:16], 3'd0, lfsr[4:2], lfsr[1:0]};
      dma_pval    <= (cycle_cnt % 2 == 0);
      dma_pdat    <= {~lfsr, lfsr};
      dma_pay_par <= 16'h0000;
      // 6. MXFP8/NVFP4 Dot Engine: dense FP8/NVFP4/INT8/W4A8 microscaling dot products
      dot_val     <= 1'b1;
      dot_mode    <= (cycle_cnt % 5);
      dot_zskip   <= 1'b1;
      dot_acc_en  <= 1'b1;
      dot_acc_clr <= (cycle_cnt % 32 == 0);
      dot_ascale  <= 8'd127 + lfsr[2:0];
      dot_wscale  <= 8'd127 - lfsr[5:3];
      dot_act     <= {lfsr ^ 64'h1122_3344_5566_7788, lfsr};
      dot_wt      <= {~lfsr, lfsr ^ 64'h8877_6655_4433_2211};
      // 7. SXM Slice: active spatial shifts, butterfly, transpose & RoPE
      sxm_op      <= (cycle_cnt % 9);
      sxm_shf     <= lfsr[3:0];
      sxm_src     <= lfsr[7:4];
      sxm_bfly    <= lfsr[11:8];
      sxm_trp     <= cycle_cnt[3:0];
      sxm_rope    <= cycle_cnt[0];
      sxm_in_val  <= 1'b1;
      sxm_in_dat  <= {lfsr, lfsr ^ 64'hDEAD_BEEF_CAFE_F00D};
      // 8. NIM RealSync: active C2C send/recv/allreduce & RealSync deskew release
      nim_val     <= 1'b1;
      nim_op      <= (cycle_cnt % 5) + 4'd1;
      nim_atime   <= cycle_cnt[15:0];
      nim_flight  <= 16'd4;
      nim_lchip   <= 4'd1;
      nim_tdst    <= lfsr[3:0] ^ 4'd2;
      nim_ugal    <= lfsr[4];
      nim_cong    <= lfsr[5];
      nim_lin_val <= 1'b1;
      nim_lin_dat <= {lfsr ^ 64'h5555_AAAA_5555_AAAA, lfsr};
      nim_rx_val  <= gold_nim_tx_val;
      nim_rx_dat  <= gold_nim_tx_dat;
      nim_rx_ts   <= gold_nim_tx_ts;
      nim_rx_dst  <= 4'd1;
      nim_rx_crc  <= gold_nim_tx_crc;
      // 9. Speculative Decode Tree Sampler: active greedy/top-k/top-p & Medusa tree verify
      sdt_val        <= 1'b1;
      sdt_mode       <= (cycle_cnt % 3);
      sdt_logits     <= {lfsr ^ 64'hFEDC_BA98_7654_3210, ~lfsr};
      sdt_tok_ids    <= {~lfsr ^ 64'h0123_4567_89AB_CDEF, lfsr};
      sdt_top_k      <= (lfsr[3:0] == 4'd0) ? 4'd4 : lfsr[3:0];
      sdt_inv_temp   <= (lfsr[7:0] == 8'd0) ? 8'd16 : lfsr[7:0];
      sdt_top_p      <= 16'h4000 | {2'b00, lfsr[13:0]};
      sdt_rng_step   <= 1'b1;
      sdt_rng_th     <= lfsr[15:8];
      sdt_tree_pidx  <= {3'd6, 3'd5, 3'd3, 3'd2, 3'd1, 3'd1, 3'd0, 3'd0};
      sdt_tree_dprob <= lfsr ^ 64'h3355_7799_BBDD_FF11;
      sdt_tree_tprob <= ~lfsr ^ 64'h88AA_CCEE_2244_6600;
      sdt_tree_rand  <= {lfsr[31:0], lfsr[63:32]};
      sdt_tree_dtok  <= lfsr ^ 64'h1020_3040_5060_7080;
      sdt_bonus_tok  <= lfsr[23:16];
      // 10. Power Droop Controller: active slice burst + pre-warm + bleeder ramp
      droop_en        <= 1'b1;
      droop_slice_act <= (cycle_cnt % 40 < 25) ? (lfsr[7:0] | 8'h51) : 8'h03;
      droop_zskip_cnt <= lfsr[5:0];
      droop_prewarm   <= (cycle_cnt % 40 >= 32);
      droop_pw_target <= 8'd160;
      droop_max_step  <= 8'd16;
      droop_vdd_nom   <= 12'd800;
      droop_emerg_th  <= 12'd720;
      // 11. SRAM Controller & Scrubber: foreground VLIW/DMA R/W + SER injection + scrubbing
      scb_efuse_req  <= (cycle_cnt == 25);
      scb_efuse_bank <= 2'd1;
      scb_efuse_addr <= 2'd2;
      scb_vliw_ren   <= (cycle_cnt % 3 == 0);
      scb_vliw_rbank <= cycle_cnt[1:0];
      scb_vliw_raddr <= cycle_cnt[3:2];
      scb_vliw_wen   <= (cycle_cnt % 4 == 1);
      scb_vliw_wbank <= lfsr[1:0];
      scb_vliw_waddr <= lfsr[3:2];
      scb_vliw_wdata <= {lfsr, ~lfsr};
      scb_dma_wen    <= (cycle_cnt % 7 == 2);
      scb_dma_wbank  <= lfsr[5:4];
      scb_dma_waddr  <= lfsr[7:6];
      scb_dma_wdata  <= {~lfsr, lfsr ^ 64'hA5A5_5A5A_F0F0_0F0F};
      scb_scrub_en   <= 1'b1;
      scb_ser_en     <= (cycle_cnt % 25 == 10);
      scb_ser_bank   <= cycle_cnt[1:0];
      scb_ser_addr   <= cycle_cnt[3:2];
      scb_ser_mask   <= (144'd1 << (cycle_cnt % 144));
      // 12. C2C KV Quant RX Engine: active BF16/FP16 -> MXFP8/NVFP4 block quantization
      kvq_val  <= 1'b1;
      kvq_mode <= cycle_cnt[1:0];
      kvq_lo   <= {lfsr ^ 64'h3F80_4000_4040_4080, ~lfsr};
      kvq_hi   <= {~lfsr ^ 64'hC000_C040_3C00_3E00, lfsr};
      kvq_bank <= lfsr[1:0];
      kvq_addr <= lfsr[17:2];
    end else begin
      // PHASE 2 (2,000 cycles: 3220..5219): Zero-Skip Operand Isolation & Clock-Gated Idle Window
      rst_n     <= 1'b1;
      sim_phase <= 2;
      ecc_valid_in <= 1'b0; ecc_data_in <= '0; ecc_codeword_in <= '0;
      agu_cfg_load <= 1'b0; agu_step_en <= 1'b0;
      // ICU executing NOP_DELAY stall / gated fetch window
      icu_en <= 1'b0; icu_adj_en <= 1'b0;
      // PCS link idle keepalive
      pcs_tx_valid <= 1'b0; pcs_nack_req <= 1'b0;
      pcs_rx_valid <= gold_pcs_tx_val; pcs_rx_frame <= gold_pcs_tx_frm;
      // DMA stalled/idle during VLIW active SRAM window
      dma_gcyc <= cycle_cnt[15:0]; dma_vwin <= 1'b1; dma_sbusy <= 1'b1;
      dma_dval <= 1'b0; dma_pval <= 1'b0;
      // MXFP8/NVFP4 Dot Engine with zero-skip block/lane isolation active on sparse zeros
      dot_val     <= 1'b1;
      dot_mode    <= 3'd1; // MXFP8_E4M3
      dot_zskip   <= 1'b1;
      dot_acc_en  <= 1'b0;
      dot_acc_clr <= 1'b0;
      dot_ascale  <= 8'h00; // E8M0 block scale = 0 -> hardware block zero-skip!
      dot_wscale  <= 8'h7F;
      dot_act     <= 128'd0;
      dot_wt      <= 128'd0;
      // SXM & NIM idle stream windows
      sxm_in_val  <= 1'b0; sxm_op <= 4'd0;
      nim_val     <= 1'b0; nim_op <= 4'd0; nim_lin_val <= 1'b0; nim_rx_val <= 1'b0;
      nim_atime   <= cycle_cnt[15:0];
      // Modules 9..12 clock-gated / quiescent idle window
      sdt_val      <= 1'b0; sdt_rng_step <= 1'b0;
      droop_en     <= 1'b0; droop_slice_act <= 8'd0; droop_zskip_cnt <= 6'd32; droop_prewarm <= 1'b0;
      scb_efuse_req <= 1'b0; scb_vliw_ren <= 1'b0; scb_vliw_wen <= 1'b0;
      scb_dma_wen  <= 1'b0; scb_scrub_en <= 1'b0; scb_ser_en <= 1'b0;
      kvq_val      <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Cycle-by-Cycle Lockstep Output Equivalence Checker (Sampled at negedge clk)
  // ---------------------------------------------------------------------------
  always @(negedge clk) begin
    if (rst_n && cycle_cnt >= 21) begin
      total_checks++;

      // 1. groq_sram_ecc_secded
      mod_checks[0]++;
      if ({gate_ecc_out, gate_codeword_out, gate_ecc_valid_out, gate_data_corrected, gate_syndrome, gate_sec_err, gate_ded_err} !==
          {gold_ecc_out, gold_codeword_out, gold_ecc_valid_out, gold_data_corrected, gold_syndrome, gold_sec_err, gold_ded_err}) begin
        mod_mismatches[0]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_sram_ecc_secded", cycle_cnt);
      end

      // 2. groq_mem_agu
      mod_checks[1]++;
      if ({gate_agu_addr, gate_agu_valid, gate_agu_idx0, gate_agu_idx1, gate_agu_wrap, gate_agu_done, gate_agu_busy} !==
          {gold_agu_addr, gold_agu_valid, gold_agu_idx0, gold_agu_idx1, gold_agu_wrap, gold_agu_done, gold_agu_busy}) begin
        mod_mismatches[1]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_mem_agu", cycle_cnt);
      end

      // 3. groq_icu_slice
      mod_checks[2]++;
      if ({gate_icu_fetch, gate_icu_pc, gate_icu_valid, gate_icu_bundle, gate_icu_nop, gate_icu_halt,
           gate_icu_bwait, gate_icu_bmask, gate_icu_brel, gate_icu_bcnt, gate_icu_cyc, gate_icu_doff, gate_icu_atime, gate_icu_fault} !==
          {gold_icu_fetch, gold_icu_pc, gold_icu_valid, gold_icu_bundle, gold_icu_nop, gold_icu_halt,
           gold_icu_bwait, gold_icu_bmask, gold_icu_brel, gold_icu_bcnt, gold_icu_cyc, gold_icu_doff, gold_icu_atime, gold_icu_fault}) begin
        mod_mismatches[2]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_icu_slice", cycle_cnt);
      end

      // 4. groq_c2c_serdes_pcs
      mod_checks[3]++;
      if ({gate_pcs_tx_rdy, gate_pcs_tx_val, gate_pcs_tx_frm, gate_pcs_shdr, gate_pcs_crc, gate_pcs_meta,
           gate_pcs_spay, gate_pcs_rep, gate_pcs_tseq, gate_pcs_rx_val, gate_pcs_rx_dat, gate_pcs_rdst,
           gate_pcs_rhop, gate_pcs_rop, gate_pcs_rseq, gate_pcs_cerr, gate_pcs_serr, gate_pcs_nreq,
           gate_pcs_nseq, gate_pcs_st, gate_pcs_up, gate_pcs_skew} !==
          {gold_pcs_tx_rdy, gold_pcs_tx_val, gold_pcs_tx_frm, gold_pcs_shdr, gold_pcs_crc, gold_pcs_meta,
           gold_pcs_spay, gold_pcs_rep, gold_pcs_tseq, gold_pcs_rx_val, gold_pcs_rx_dat, gold_pcs_rdst,
           gold_pcs_rhop, gold_pcs_rop, gold_pcs_rseq, gold_pcs_cerr, gold_pcs_serr, gold_pcs_nreq,
           gold_pcs_nseq, gold_pcs_st, gold_pcs_up, gold_pcs_skew}) begin
        mod_mismatches[3]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_c2c_serdes_pcs", cycle_cnt);
      end

      // 5. groq_pcie_c2c_dma
      mod_checks[4]++;
      if ({gate_dma_drdy, gate_dma_full, gate_dma_emp, gate_dma_hptr, gate_dma_tptr, gate_dma_dcnt,
           gate_dma_prdy, gate_dma_iwen, gate_dma_islc, gate_dma_iadr, gate_dma_idat,
           gate_dma_wwen, gate_dma_wbk, gate_dma_wadr, gate_dma_wdat,
           gate_dma_ewen, gate_dma_ebk, gate_dma_eadr, gate_dma_edat,
           gate_dma_bsy, gate_dma_stl, gate_dma_perr, gate_dma_irq, gate_dma_cdsc, gate_dma_btr} !==
          {gold_dma_drdy, gold_dma_full, gold_dma_emp, gold_dma_hptr, gold_dma_tptr, gold_dma_dcnt,
           gold_dma_prdy, gold_dma_iwen, gold_dma_islc, gold_dma_iadr, gold_dma_idat,
           gold_dma_wwen, gold_dma_wbk, gold_dma_wadr, gold_dma_wdat,
           gold_dma_ewen, gold_dma_ebk, gold_dma_eadr, gold_dma_edat,
           gold_dma_bsy, gold_dma_stl, gold_dma_perr, gold_dma_irq, gold_dma_cdsc, gold_dma_btr}) begin
        mod_mismatches[4]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_pcie_c2c_dma", cycle_cnt);
      end

      // 6. groq_mxfp8_nvfp4_dot_engine
      mod_checks[5]++;
      if ({gate_dot_val, gate_dot_unacc, gate_dot_acc, gate_dot_fp32, gate_dot_zlanes, gate_dot_bzero, gate_dot_nan} !==
          {gold_dot_val, gold_dot_unacc, gold_dot_acc, gold_dot_fp32, gold_dot_zlanes, gold_dot_bzero, gold_dot_nan}) begin
        mod_mismatches[5]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_mxfp8_nvfp4_dot_engine", cycle_cnt);
      end

      // 7. groq_sxm_slice
      mod_checks[6]++;
      if ({gate_sxm_oval, gate_sxm_odat, gate_sxm_pcomb} !==
          {gold_sxm_oval, gold_sxm_odat, gold_sxm_pcomb}) begin
        mod_mismatches[6]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_sxm_slice", cycle_cnt);
      end

      // 8. groq_nim_realsync
      mod_checks[7]++;
      if ({gate_nim_lout_val, gate_nim_lout_dat, gate_nim_tx_val, gate_nim_tx_dat, gate_nim_tx_ts,
           gate_nim_tx_dst, gate_nim_tx_crc, gate_nim_tx_psel, gate_nim_drel_val, gate_nim_drel_cyc,
           gate_nim_pack, gate_nim_skew, gate_nim_cerr} !==
          {gold_nim_lout_val, gold_nim_lout_dat, gold_nim_tx_val, gold_nim_tx_dat, gold_nim_tx_ts,
           gold_nim_tx_dst, gold_nim_tx_crc, gold_nim_tx_psel, gold_nim_drel_val, gold_nim_drel_cyc,
           gold_nim_pack, gold_nim_skew, gold_nim_cerr}) begin
        mod_mismatches[7]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_nim_realsync", cycle_cnt);
      end

      // 9. groq_spec_decode_tree_sampler
      mod_checks[8]++;
      if ({gate_sdt_oval, gate_sdt_stok, gate_sdt_slog, gate_sdt_slogits, gate_sdt_stokens,
           gate_sdt_nmask, gate_sdt_amask, gate_sdt_bleaf, gate_sdt_alen, gate_sdt_temit,
           gate_sdt_ctoks, gate_sdt_kvadv, gate_sdt_prng} !==
          {gold_sdt_oval, gold_sdt_stok, gold_sdt_slog, gold_sdt_slogits, gold_sdt_stokens,
           gold_sdt_nmask, gold_sdt_amask, gold_sdt_bleaf, gold_sdt_alen, gold_sdt_temit,
           gold_sdt_ctoks, gold_sdt_kvadv, gold_sdt_prng}) begin
        mod_mismatches[8]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_spec_decode_tree_sampler", cycle_cnt);
      end

      // 10. groq_power_droop_controller
      mod_checks[9]++;
      if ({gate_drp_raw, gate_drp_eff, gate_drp_bleed, gate_drp_bmask, gate_drp_didt,
           gate_drp_vdd, gate_drp_temp, gate_drp_throt, gate_drp_evts} !==
          {gold_drp_raw, gold_drp_eff, gold_drp_bleed, gold_drp_bmask, gold_drp_didt,
           gold_drp_vdd, gold_drp_temp, gold_drp_throt, gold_drp_evts}) begin
        mod_mismatches[9]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_power_droop_controller", cycle_cnt);
      end

      // 11. groq_sram_controller_scrubber
      mod_checks[10]++;
      if ({gate_scb_repen, gate_scb_repadr, gate_scb_efack, gate_scb_rval, gate_scb_rdat,
           gate_scb_rsec, gate_scb_rded, gate_scb_rhit, gate_scb_rdfire, gate_scb_wbfire,
           gate_scb_abank, gate_scb_aaddr, gate_scb_ccnt, gate_scb_dedal, gate_scb_fbank, gate_scb_faddr} !==
          {gold_scb_repen, gold_scb_repadr, gold_scb_efack, gold_scb_rval, gold_scb_rdat,
           gold_scb_rsec, gold_scb_rded, gold_scb_rhit, gold_scb_rdfire, gold_scb_wbfire,
           gold_scb_abank, gold_scb_aaddr, gold_scb_ccnt, gold_scb_dedal, gold_scb_fbank, gold_scb_faddr}) begin
        mod_mismatches[10]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_sram_controller_scrubber", cycle_cnt);
      end

      // 12. groq_c2c_kv_quant_rx_engine
      mod_checks[11]++;
      if ({gate_kvq_oval, gate_kvq_vec, gate_kvq_scale, gate_kvq_wren, gate_kvq_wbank,
           gate_kvq_waddr, gate_kvq_zcnt, gate_kvq_nan, gate_kvq_crat} !==
          {gold_kvq_oval, gold_kvq_vec, gold_kvq_scale, gold_kvq_wren, gold_kvq_wbank,
           gold_kvq_waddr, gold_kvq_zcnt, gold_kvq_nan, gold_kvq_crat}) begin
        mod_mismatches[11]++; mismatch_cnt++;
        $display("[MISMATCH] cyc=%0d groq_c2c_kv_quant_rx_engine", cycle_cnt);
      end
    end

    if (cycle_cnt == 5220) begin
      $display("========================================================================");
      $display("STAGE 17 POST-SYNTHESIS GATE-LEVEL vs. RTL CO-SIMULATION SUMMARY");
      $display("  Total Clock Cycles Simulated : %0d (Active: 3000, Zero-Skip/Idle: 2000)", cycle_cnt);
      $display("  Post-Reset Lockstep Cycles   : %0d", total_checks);
      $display("  Total Output Comparisons     : %0d (12 Modules x %0d Cycles)", total_checks * 12, total_checks);
      $display("  Total Gate-vs-RTL Mismatches : %0d", mismatch_cnt);
      $display("========================================================================");
      if (mismatch_cnt == 0)
        $display("STAGE17_GATE_COSIM_PASS: 100.0%% CYCLE-ACCURATE EQUIVALENCE VERIFIED!");
      else
        $fatal(1, "STAGE17_GATE_COSIM_FAIL: %0d mismatches detected!", mismatch_cnt);
      $finish;
    end
  end

  initial begin
    for (int i = 0; i < 12; i++) begin
      mod_checks[i] = 0;
      mod_mismatches[i] = 0;
    end
    $dumpfile("gate_sim/gate_netlist_activity.vcd");
    $dumpvars(0, tb_gate_vs_rtl_cosim);
  end
endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on UNUSEDSIGNAL */
