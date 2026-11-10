// =============================================================================
// File: formal/tb_stage8_adversarial_stress.sv
// Description: Stage 8 High-Intensity 100,000-Cycle Adversarial Corner-Case
//              Stress & Self-Healing Audit Testbench (Verilator 5.054).
//              Stresses MXM, SXM, VXM, NIM, MEM/SECDED, and Full-Chip LPU Top
//              across 100,000 back-to-back adversarial cycles with self-checking
//              assertions and zero-failure invariant monitoring.
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"

module tb_stage8_adversarial_stress;
  import groq_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #0.5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // 1. Standalone Adversarial Stress Instance: groq_mxm_slice
  // ---------------------------------------------------------------------------
  logic [3:0]              mxm_op, mxm_prec, mxm_wt_row, mxm_bg_row;
  logic                    mxm_zgate_en, mxm_acc_clr, mxm_acc_pre, mxm_bg_en;
  logic                    mxm_act_val, mxm_wt_val;
  logic [127:0]            mxm_act_dat, mxm_wt_dat, mxm_bg_dat, mxm_out_dat;
  logic [511:0]            mxm_pre_dat, mxm_acc_vec;
  logic                    mxm_act_bank, mxm_out_val;
  logic [15:0]             mxm_zmask;
  logic [4:0]              mxm_zcnt;

  groq_mxm_slice u_stress_mxm (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .mxm_op_i              (mxm_op),
    .prec_mode_i           (mxm_prec),
    .weight_row_idx_i      (mxm_wt_row),
    .act_zero_gate_en_i    (mxm_zgate_en),
    .accum_clear_i         (mxm_acc_clr),
    .accum_preload_en_i    (mxm_acc_pre),
    .bg_wt_load_en_i       (mxm_bg_en),
    .bg_wt_row_idx_i       (mxm_bg_row),
    .bg_wt_data_i          (mxm_bg_dat),
    .stream_act_valid_i    (mxm_act_val),
    .stream_act_data_i     (mxm_act_dat),
    .stream_wt_valid_i     (mxm_wt_val),
    .stream_wt_data_i      (mxm_wt_dat),
    .accum_preload_data_i  (mxm_pre_dat),
    .active_bank_o         (mxm_act_bank),
    .zero_skip_gate_mask_o (mxm_zmask),
    .zero_skip_count_o     (mxm_zcnt),
    .out_valid_o           (mxm_out_val),
    .stream_out_data_o     (mxm_out_dat),
    .accum_vec_o           (mxm_acc_vec)
  );

  // ---------------------------------------------------------------------------
  // 2. Standalone Adversarial Stress Instance: groq_sxm_slice
  // ---------------------------------------------------------------------------
  logic [3:0]   sxm_op, sxm_shamt, sxm_slane, sxm_bfly, sxm_tidx;
  logic         sxm_rope_neg, sxm_in_val, sxm_out_val;
  logic [127:0] sxm_in_dat, sxm_out_dat, sxm_comb_dat;

  groq_sxm_slice u_stress_sxm (
    .clk                (clk),
    .rst_n              (rst_n),
    .sxm_op_i           (sxm_op),
    .shift_amt_i        (sxm_shamt),
    .src_lane_i         (sxm_slane),
    .butterfly_mask_i   (sxm_bfly),
    .transpose_idx_i    (sxm_tidx),
    .rope_neg_even_en_i (sxm_rope_neg),
    .stream_in_valid_i  (sxm_in_val),
    .stream_in_data_i   (sxm_in_dat),
    .stream_out_valid_o (sxm_out_val),
    .stream_out_data_o  (sxm_out_dat),
    .perm_comb_data_o   (sxm_comb_dat)
  );

  // ---------------------------------------------------------------------------
  // 3. Standalone Adversarial Stress Instance: groq_vxm_slice
  // ---------------------------------------------------------------------------
  logic               vxm_val, vxm_use_acc, vxm_out_val, vxm_mgate, vxm_lgate;
  logic [3:0]         vxm_op, vxm_prec;
  logic [2:0]         vxm_qshift;
  logic [127:0]       vxm_sa, vxm_sb, vxm_sc, vxm_out_dat, vxm_comb_dat;
  logic [511:0]       vxm_acc_in, vxm_acc_out;
  logic signed [15:0] vxm_rsum;
  logic signed [7:0]  vxm_rmax;

  groq_vxm_slice u_stress_vxm (
    .clk                 (clk),
    .rst_n               (rst_n),
    .op_valid_i          (vxm_val),
    .vxm_op_i            (vxm_op),
    .prec_mode_i         (vxm_prec),
    .quant_shift_i       (vxm_qshift),
    .use_accum_32b_i     (vxm_use_acc),
    .stream_a_i          (vxm_sa),
    .stream_b_i          (vxm_sb),
    .stream_c_i          (vxm_sc),
    .accum_32b_in_i      (vxm_acc_in),
    .stream_out_valid_o  (vxm_out_val),
    .stream_out_data_o   (vxm_out_dat),
    .accum_32b_out_o     (vxm_acc_out),
    .vxm_comb_data_o     (vxm_comb_dat),
    .reduce_sum_scalar_o (vxm_rsum),
    .reduce_max_scalar_o (vxm_rmax),
    .mul_gate_active_o   (vxm_mgate),
    .lut_gate_active_o   (vxm_lgate)
  );

  // ---------------------------------------------------------------------------
  // 4. Standalone Adversarial Stress Instance: groq_nim_realsync
  // ---------------------------------------------------------------------------
  logic               nim_val, nim_ugal, nim_cong, nim_lin_val, nim_lout_val;
  logic               nim_rx_val, nim_tx_val, nim_dsk_val, nim_ping_ack, nim_crc_err;
  logic [3:0]         nim_op, nim_chip_id, nim_tx_dst, nim_rx_dst, nim_tx_dst_out;
  logic [15:0]        nim_rs_time, nim_exp_flt, nim_rx_ts, nim_tx_ts, nim_dsk_tgt;
  logic [127:0]       nim_lin_dat, nim_lout_dat, nim_rx_dat, nim_tx_dat;
  logic [7:0]         nim_rx_crc, nim_tx_crc;
  logic [1:0]         nim_tx_port;
  logic signed [15:0] nim_skew;

  groq_nim_realsync u_stress_nim (
    .clk                            (clk),
    .rst_n                          (rst_n),
    .op_valid_i                     (nim_val),
    .nim_op_i                       (nim_op),
    .realsync_aligned_time_i        (nim_rs_time),
    .expected_flight_cycles_i       (nim_exp_flt),
    .local_chip_id_i                (nim_chip_id),
    .tx_dst_chip_i                  (nim_tx_dst),
    .ugal_nonminimal_en_i           (nim_ugal),
    .link_congested_i               (nim_cong),
    .local_stream_in_valid_i        (nim_lin_val),
    .local_stream_in_data_i         (nim_lin_dat),
    .local_stream_out_valid_o       (nim_lout_val),
    .local_stream_out_data_o        (nim_lout_dat),
    .c2c_rx_valid_i                 (nim_rx_val),
    .c2c_rx_data_i                  (nim_rx_dat),
    .c2c_rx_tx_timestamp_i          (nim_rx_ts),
    .c2c_rx_dst_chip_i              (nim_rx_dst),
    .c2c_rx_crc8_i                  (nim_rx_crc),
    .c2c_tx_valid_o                 (nim_tx_val),
    .c2c_tx_data_o                  (nim_tx_dat),
    .c2c_tx_timestamp_o             (nim_tx_ts),
    .c2c_tx_dst_chip_o              (nim_tx_dst_out),
    .c2c_tx_crc8_o                  (nim_tx_crc),
    .c2c_tx_port_sel_o              (nim_tx_port),
    .deskew_release_valid_o         (nim_dsk_val),
    .deskew_released_target_cycle_o (nim_dsk_tgt),
    .realsync_ping_ack_o            (nim_ping_ack),
    .measured_skew_o                (nim_skew),
    .crc_err_o                      (nim_crc_err)
  );

  // ---------------------------------------------------------------------------
  // 5. Full-Chip Adversarial Stress Instance: groq_lpu_top
  // ---------------------------------------------------------------------------
  logic                                         lpu_icu_en, lpu_ovw_allow;
  logic [NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0]   lpu_imem_bundle, lpu_slice_bundle;
  logic [NUM_SLICES-1:0]                        lpu_fetch_en, lpu_slice_val, lpu_halted, lpu_bwait;
  logic [NUM_SLICES-1:0][15:0]                  lpu_pc;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]  lpu_einj_en, lpu_eval;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] lpu_einj_dat, lpu_edat;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0]  lpu_winj_en, lpu_wval;
  logic [NUM_SLICES-1:0][NUM_WEST_STREAMS-1:0][STREAM_WIDTH-1:0] lpu_winj_dat, lpu_wdat;
  logic                                         lpu_mw_en, lpu_me_en, lpu_err_en;
  logic [1:0]                                   lpu_mw_bank, lpu_me_bank, lpu_ecc1, lpu_ecc2, lpu_bconf;
  logic [9:0]                                   lpu_mw_addr, lpu_me_addr;
  logic [127:0]                                 lpu_mw_dat, lpu_me_dat, lpu_c2c_rx_dat, lpu_c2c_tx_dat;
  logic [143:0]                                 lpu_err_mask;
  logic                                         lpu_c2c_rx_val, lpu_c2c_tx_val, lpu_coll, lpu_coll_stk;
  logic                                         lpu_brel, lpu_drift, lpu_dsk_val, lpu_crc_err;
  logic                                         lpu_mgate, lpu_lgate;
  logic [15:0]                                  lpu_bcnt, lpu_gated, lpu_c2c_tx_ts;
  logic [63:0]                                  lpu_rstime;
  logic signed [15:0]                           lpu_skew, lpu_rsum;
  logic signed [7:0]                            lpu_rmax;
  logic [4:0]                                   lpu_zsw, lpu_zse;
  logic [3:0]                                   lpu_c2c_tx_dst;
  logic [7:0]                                   lpu_c2c_tx_crc;
  logic [1:0]                                   lpu_c2c_tx_port;

  groq_lpu_top u_stress_lpu (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .icu_enable_i             (lpu_icu_en),
    .imem_vliw_bundle_i       (lpu_imem_bundle),
    .imem_fetch_en_o          (lpu_fetch_en),
    .pc_slice_o               (lpu_pc),
    .slice_vliw_valid_o       (lpu_slice_val),
    .slice_vliw_bundle_o      (lpu_slice_bundle),
    .slice_halted_o           (lpu_halted),
    .ext_east_inject_en_i     (lpu_einj_en),
    .ext_east_inject_data_i   (lpu_einj_dat),
    .ext_west_inject_en_i     (lpu_winj_en),
    .ext_west_inject_data_i   (lpu_winj_dat),
    .ext_overwrite_allow_i    (lpu_ovw_allow),
    .stream_valid_east_o      (lpu_eval),
    .stream_data_east_o       (lpu_edat),
    .stream_valid_west_o      (lpu_wval),
    .stream_data_west_o       (lpu_wdat),
    .host_mem_w_wr_en_i       (lpu_mw_en),
    .host_mem_w_bank_i        (lpu_mw_bank),
    .host_mem_w_addr_i        (lpu_mw_addr),
    .host_mem_w_data_i        (lpu_mw_dat),
    .host_mem_e_wr_en_i       (lpu_me_en),
    .host_mem_e_bank_i        (lpu_me_bank),
    .host_mem_e_addr_i        (lpu_me_addr),
    .host_mem_e_data_i        (lpu_me_dat),
    .mem_err_inject_en_i      (lpu_err_en),
    .mem_err_inject_mask_i    (lpu_err_mask),
    .local_chip_id_i          (4'd0),
    .expected_flight_cycles_i (16'd2),
    .realsync_ext_adj_en_i    (1'b0),
    .realsync_ext_adj_val_i   (16'sd0),
    .c2c_rx_valid_i           (lpu_c2c_rx_val),
    .c2c_rx_data_i            (lpu_c2c_rx_dat),
    .c2c_rx_tx_timestamp_i    (16'd0),
    .c2c_rx_dst_chip_i        (4'd0),
    .c2c_rx_crc8_i            (8'h00),
    .c2c_tx_valid_o           (lpu_c2c_tx_val),
    .c2c_tx_data_o            (lpu_c2c_tx_dat),
    .c2c_tx_timestamp_o       (lpu_c2c_tx_ts),
    .c2c_tx_dst_chip_o        (lpu_c2c_tx_dst),
    .c2c_tx_crc8_o            (lpu_c2c_tx_crc),
    .c2c_tx_port_sel_o        (lpu_c2c_tx_port),
    .collision_fault_o        (lpu_coll),
    .collision_sticky_o       (lpu_coll_stk),
    .barrier_waiting_o        (lpu_bwait),
    .barrier_release_pulse_o  (lpu_brel),
    .barrier_release_cnt_o    (lpu_bcnt),
    .realsync_aligned_time_o  (lpu_rstime),
    .realsync_drift_fault_o   (lpu_drift),
    .deskew_release_valid_o   (lpu_dsk_val),
    .measured_skew_o          (lpu_skew),
    .c2c_crc_err_o            (lpu_crc_err),
    .ecc_single_err_o         (lpu_ecc1),
    .ecc_double_err_o         (lpu_ecc2),
    .bank_conflict_err_o      (lpu_bconf),
    .gated_hop_count_o        (lpu_gated),
    .zero_skip_count_w_o      (lpu_zsw),
    .zero_skip_count_e_o      (lpu_zse),
    .mul_gate_active_o        (lpu_mgate),
    .lut_gate_active_o        (lpu_lgate),
    .vxm_reduce_sum_o         (lpu_rsum),
    .vxm_reduce_max_o         (lpu_rmax)
  );

  // ---------------------------------------------------------------------------
  // 6. Golden Reference Functions & Continuous Self-Checking Monitors
  // ---------------------------------------------------------------------------
  function automatic logic [7:0] crc8_ref(
    input logic [127:0] payload,
    input logic [15:0]  ts
  );
    logic [143:0] frame;
    logic [7:0]   crc;
    logic         fb;
    begin
      frame = {ts, payload};
      crc   = 8'hFF;
      for (int b = 143; b >= 0; b--) begin
        fb  = crc[7] ^ frame[b];
        crc = {crc[6:0], 1'b0} ^ (fb ? 8'h07 : 8'h00);
      end
      crc8_ref = crc;
    end
  endfunction

  logic [15:0][7:0] ref_sxm_tbuf [0:15];
  logic             mxm_exec_d1, mxm_exec_d2;
  logic             sxm_exp_val_d1;
  logic [3:0]       sxm_op_d1, sxm_tidx_d1;
  logic [15:0]      nim_rs_d1;
  int unsigned      err_cnt = 0;
  int unsigned      mxm_checks = 0, sxm_checks = 0, vxm_checks = 0, nim_checks = 0, lpu_checks = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mxm_exec_d1    <= 1'b0;
      mxm_exec_d2    <= 1'b0;
      sxm_exp_val_d1 <= 1'b0;
      sxm_op_d1      <= 4'd0;
      sxm_tidx_d1    <= 4'd0;
      nim_rs_d1      <= 16'd0;
      for (int r = 0; r < 16; r++) ref_sxm_tbuf[r] <= '0;
    end else begin
      mxm_exec_d1    <= mxm_act_val && (mxm_op == MXM_SYSTOLIC_EXEC);
      mxm_exec_d2    <= mxm_exec_d1;
      sxm_exp_val_d1 <= sxm_in_val && (sxm_op != SXM_NOP);
      sxm_op_d1      <= sxm_op;
      sxm_tidx_d1    <= sxm_tidx;
      nim_rs_d1      <= nim_rs_time;

      if (sxm_in_val && (sxm_op == SXM_TRANSPOSE_LOAD)) begin
        for (int c = 0; c < 16; c++) begin
          ref_sxm_tbuf[sxm_tidx][c] <= sxm_in_dat[c*8 +: 8];
        end
      end

      // Continuous MXM Checks
      if (mxm_out_val !== mxm_exec_d2 || mxm_zcnt > 5'd16) begin
        $display("ERROR [MXM] out_val=%b exp=%b zcnt=%0d", mxm_out_val, mxm_exec_d2, mxm_zcnt);
        err_cnt++;
      end
      if ((mxm_prec == PREC_FP16 || mxm_prec == PREC_BF16) && mxm_zgate_en) begin
        if ((mxm_act_dat[15:0] == 16'h0300) && (mxm_zmask[1:0] != 2'b00)) begin
          $display("ERROR [MXM] BUG-MXM-001 regression: half-zero FP16 gated zmask=%b", mxm_zmask[1:0]);
          err_cnt++;
        end
      end
      mxm_checks++;

      // Continuous SXM Checks (1-cycle latency + exact 16x16 transpose readback)
      if (sxm_out_val !== sxm_exp_val_d1) begin
        $display("ERROR [SXM] out_val=%b exp=%b", sxm_out_val, sxm_exp_val_d1);
        err_cnt++;
      end
      if (sxm_out_val && (sxm_op_d1 == SXM_TRANSPOSE_READ)) begin
        for (int i = 0; i < 16; i++) begin
          if (sxm_out_dat[i*8 +: 8] !== ref_sxm_tbuf[i][sxm_tidx_d1]) begin
            $display("ERROR [SXM] Transpose mismatch lane %0d got=%02x exp=%02x",
                     i, sxm_out_dat[i*8 +: 8], ref_sxm_tbuf[i][sxm_tidx_d1]);
            err_cnt++;
          end
        end
      end
      sxm_checks++;

      // Continuous VXM Reduction Tree Golden Check
      begin
        logic signed [15:0] exp_sum;
        logic signed [7:0]  exp_max, lane_v;
        exp_sum = 16'sd0;
        exp_max = -8'sd128;
        for (int i = 0; i < 16; i++) begin
          lane_v  = $signed(vxm_sa[i*8 +: 8]);
          exp_sum = exp_sum + {{8{lane_v[7]}}, lane_v};
          if (i == 0 || lane_v > exp_max) exp_max = lane_v;
        end
        if (vxm_rsum !== exp_sum || vxm_rmax !== exp_max) begin
          $display("ERROR [VXM] Reduce mismatch rsum=%0d(exp %0d) rmax=%0d(exp %0d)",
                   vxm_rsum, exp_sum, vxm_rmax, exp_max);
          err_cnt++;
        end
        vxm_checks++;
      end

      // Continuous NIM Deskew Exact Target Release Check
      if (nim_dsk_val && (nim_dsk_tgt !== nim_rs_time)) begin
        $display("ERROR [NIM] Deskew release target=%0d != rs_time=%0d", nim_dsk_tgt, nim_rs_time);
        err_cnt++;
      end
      nim_checks++;

      // Continuous Full-Chip LPU Top Invariant Check
      if (lpu_ecc2 != 2'b00 || lpu_zsw > 5'd16 || lpu_zse > 5'd16) begin
        $display("ERROR [LPU_TOP] ecc2=%b zsw=%0d zse=%0d", lpu_ecc2, lpu_zsw, lpu_zse);
        err_cnt++;
      end
      lpu_checks++;
    end
  end

  // ---------------------------------------------------------------------------
  // 7. 100,000-Cycle Back-to-Back Adversarial Corner-Case Stimulus Generator
  // ---------------------------------------------------------------------------
  logic [127:0] adv_vec;
  groq_vliw_instr_t vliw_w, vliw_s, vliw_v, vliw_m;

  initial begin
    mxm_op = MXM_NOP; mxm_prec = PREC_INT8; mxm_wt_row = 4'd0; mxm_bg_row = 4'd0;
    mxm_zgate_en = 1'b1; mxm_acc_clr = 1'b0; mxm_acc_pre = 1'b0; mxm_bg_en = 1'b0;
    mxm_act_val = 1'b0; mxm_wt_val = 1'b0; mxm_act_dat = '0; mxm_wt_dat = '0;
    mxm_bg_dat = '0; mxm_pre_dat = '0;

    sxm_op = SXM_NOP; sxm_shamt = 4'd0; sxm_slane = 4'd0; sxm_bfly = 4'd0;
    sxm_tidx = 4'd0; sxm_rope_neg = 1'b0; sxm_in_val = 1'b0; sxm_in_dat = '0;

    vxm_val = 1'b0; vxm_op = VXM_NOP; vxm_prec = PREC_INT8; vxm_qshift = 3'd0;
    vxm_use_acc = 1'b0; vxm_sa = '0; vxm_sb = '0; vxm_sc = '0; vxm_acc_in = '0;

    nim_val = 1'b0; nim_op = NIM_NOP; nim_rs_time = 16'd0; nim_exp_flt = 16'd4;
    nim_chip_id = 4'd0; nim_tx_dst = 4'd1; nim_ugal = 1'b0; nim_cong = 1'b0;
    nim_lin_val = 1'b0; nim_lin_dat = '0; nim_rx_val = 1'b0; nim_rx_dat = '0;
    nim_rx_ts = 16'd0; nim_rx_dst = 4'd0; nim_rx_crc = 8'h00;

    lpu_icu_en = 1'b0; lpu_ovw_allow = 1'b1; lpu_imem_bundle = '0;
    lpu_einj_en = '0; lpu_einj_dat = '0; lpu_winj_en = '0; lpu_winj_dat = '0;
    lpu_mw_en = 1'b0; lpu_mw_bank = 2'd0; lpu_mw_addr = 10'd0; lpu_mw_dat = '0;
    lpu_me_en = 1'b0; lpu_me_bank = 2'd0; lpu_me_addr = 10'd0; lpu_me_dat = '0;
    lpu_err_en = 1'b0; lpu_err_mask = '0; lpu_c2c_rx_val = 1'b0; lpu_c2c_rx_dat = '0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // Preload West & East SRAM rows 0..15 in Full-Chip LPU Top
    for (int r = 0; r < 16; r++) begin
      lpu_mw_en = 1'b1; lpu_mw_bank = r[1:0]; lpu_mw_addr = 10'(r);
      lpu_mw_dat = {16{8'(8'h80 + r)}};
      lpu_me_en = 1'b1; lpu_me_bank = r[1:0]; lpu_me_addr = 10'(r);
      lpu_me_dat = {8{16'h0300 ^ 16'(r)}};
      @(posedge clk);
    end
    lpu_mw_en = 1'b0; lpu_me_en = 1'b0; lpu_icu_en = 1'b1;

    // Execute 100,000 back-to-back adversarial cycles
    for (int cyc = 0; cyc < 100000; cyc++) begin
      case (cyc & 7)
        0: adv_vec = {16{8'h80}};                          // All -128 min boundary
        1: adv_vec = {16{8'h7F}};                          // All +127 max boundary
        2: adv_vec = {8{8'h7F, 8'h80}};                    // Alternating +127 / -128
        3: adv_vec = {4{8'hFF, 8'h7F, 8'h01, 8'h81}};      // FP8 E4M3 NaN / subnormal / max
        4: adv_vec = {8{16'h0300}};                        // FP16 half-zero byte (BUG-MXM-001)
        5: adv_vec = {8{16'h007F}};                        // FP16 upper-zero byte
        6: adv_vec = 128'h0000_0000_0000_0000_0000_0000_0000_0000;
        default: adv_vec = {4{32'(cyc * 32'h9E3779B9)}};
      endcase

      // (A) MXM Stress: Simultaneous MXM_SWAP_WEIGHTS + bg_wt_load + MXM_SYSTOLIC_EXEC
      mxm_bg_en   = 1'b1;
      mxm_bg_row  = cyc[3:0];
      mxm_bg_dat  = adv_vec ^ {16{8'h80}};
      mxm_prec    = (cyc % 3 == 0) ? PREC_INT8 : ((cyc % 3 == 1) ? PREC_FP8_E4M3 : PREC_FP16);
      mxm_op      = ((cyc & 15) == 0) ? MXM_SWAP_WEIGHT : MXM_SYSTOLIC_EXEC;
      mxm_act_val = ((cyc & 15) != 0);
      mxm_act_dat = adv_vec;
      mxm_acc_clr = ((cyc & 31) == 31);

      // (B) SXM Stress: Interleaved TRANSPOSE_LOAD, TRANSPOSE_READ & BUTTERFLY_SWAP (RoPE)
      sxm_in_val   = 1'b1;
      sxm_in_dat   = adv_vec;
      sxm_tidx     = cyc[3:0];
      sxm_bfly     = cyc[3:0] ^ 4'h5;
      sxm_rope_neg = cyc[0];
      sxm_op       = (cyc % 3 == 0) ? SXM_TRANSPOSE_LOAD :
                     ((cyc % 3 == 1) ? SXM_TRANSPOSE_READ : SXM_BUTTERFLY_SWAP);

      // (C) VXM Stress: Extreme boundaries across SWIGLU, EXP_LUT, RSQRT_LUT, REDUCE_SUM/MAX
      vxm_val = 1'b1;
      vxm_sa  = adv_vec;
      vxm_sb  = ~adv_vec;
      vxm_sc  = {16{8'(cyc[7:0])}};
      case (cyc % 5)
        0: vxm_op = VXM_SWIGLU;
        1: vxm_op = VXM_EXP_LUT;
        2: vxm_op = VXM_RSQRT_LUT;
        3: vxm_op = VXM_REDUCE_SUM;
        default: vxm_op = VXM_REDUCE_MAX;
      endcase

      // (D) NIM Stress: 4-slot out-of-order deskew saturation + CRC-8 error bursts
      nim_rs_time = 16'(cyc);
      nim_val     = 1'b1;
      nim_op      = NIM_RECV;
      if ((cyc & 7) < 4) begin
        // Out-of-order target cycles: slot 0->+7, slot 1->+5, slot 2->+3, slot 3->+1
        nim_rx_val  = 1'b1;
        nim_rx_dat  = adv_vec;
        nim_rx_ts   = 16'(cyc);
        nim_exp_flt = 16'(7 - 2 * (cyc & 3));
        // Inject single/multi-bit CRC-8 error burst on every 64th cycle
        nim_rx_crc  = crc8_ref(adv_vec, 16'(cyc)) ^ ((cyc % 64 == 0) ? 8'hA5 : 8'h00);
      end else begin
        nim_rx_val  = 1'b0;
      end

      // (E) Full-Chip LPU Top Stress: Single-bit SECDED fault containment + VLIW dispatch
      lpu_err_en   = 1'b1;
      lpu_err_mask = (144'd1 << (cyc % 144));
      vliw_w = '0; vliw_w.mem_op = MEM_READ_EAST; vliw_w.dst_stream = 5'd0; vliw_w.mem_base_addr = 16'(cyc & 15);
      vliw_s = '0; vliw_s.sxm_op = SXM_BUTTERFLY_SWAP; vliw_s.src_stream_a = 5'd0; vliw_s.dst_stream = 5'd1;
      vliw_v = '0; vliw_v.vxm_op = VXM_SWIGLU; vliw_v.src_stream_a = 5'd1; vliw_v.dst_stream = 5'd2;
      vliw_m = '0; vliw_m.mxm_op = MXM_SYSTOLIC_EXEC; vliw_m.src_stream_a = 5'd2; vliw_m.dst_stream = 5'd3;
      lpu_imem_bundle[SLICE_MEM_W] = vliw_w;
      lpu_imem_bundle[SLICE_SXM]   = vliw_s;
      lpu_imem_bundle[SLICE_VXM]   = vliw_v;
      lpu_imem_bundle[SLICE_MXM_W] = vliw_m;

      @(posedge clk);
    end

    if (err_cnt != 0) begin
      $display("STAGE 8 ADVERSARIAL STRESS FAILED with %0d errors", err_cnt);
      $finish(1);
    end
    $display("STAGE 8 100,000-CYCLE ADVERSARIAL STRESS PASSED: 0 errors (mxm=%0d sxm=%0d vxm=%0d nim=%0d lpu=%0d)",
             mxm_checks, sxm_checks, vxm_checks, nim_checks, lpu_checks);
    $finish(0);
  end
endmodule

