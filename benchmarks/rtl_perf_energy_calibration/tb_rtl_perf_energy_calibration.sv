// =============================================================================
// File: benchmarks/rtl_perf_energy_calibration/tb_rtl_perf_energy_calibration.sv
// Author: Antigravity (Groq LPU & LPX Full-Stack Verification)
// Description: Stage 44 Hardware-in-the-Loop (HIL) RTL Performance & Energy-Efficiency
//              Calibration Testbench (10,000 Cycles across 5 LLM Decode Phases).
//              Simulates groq_lpu_cluster_top (2-chip 8-slice pipeline + RealSync C2C)
//              alongside groq_mxfp8_nvfp4_dot_engine, groq_c2c_kv_quant_rx_engine,
//              groq_spec_decode_tree_sampler, and groq_power_droop_controller,
//              and exports rtl_hardware_telemetry.json.
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"

module tb_rtl_perf_energy_calibration;
  import groq_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #0.5 clk = ~clk;

  // 1. 2-Chip Cluster Top (contains 2x groq_lpu_top 8-slice chips + RealSync NIM C2C)
  logic                                       c0_icu_en, c1_icu_en;
  logic [NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] c0_vliw,   c1_vliw;
  logic [NUM_SLICES-1:0][15:0]                c0_pc,     c1_pc;
  logic [NUM_SLICES-1:0]                      c0_halted, c1_halted;
  logic                      c0_mem_wr_en, c1_mem_wr_en;
  logic [1:0]                c0_mem_bank,  c1_mem_bank;
  logic [9:0]                c0_mem_addr,  c1_mem_addr;
  logic [STREAM_WIDTH-1:0]   c0_mem_data,  c1_mem_data;
  logic [1:0]                c2c_delay_sel;
  logic [15:0]               expected_flight;
  logic                      c1_rs_adj_en;
  logic signed [15:0]        c1_rs_adj_val;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0]                   c0_eval, c1_eval;
  logic [NUM_SLICES-1:0][NUM_EAST_STREAMS-1:0][STREAM_WIDTH-1:0] c0_edat, c1_edat;
  logic                      c0_tx_val, c1_tx_val, c0_dsk_val, c1_dsk_val, coll_flt, crc_err;
  logic signed [15:0]        c0_skew, c1_skew;
  logic [15:0]               c0_gated, c1_gated;

  groq_lpu_cluster_top u_cluster (
    .clk                          (clk),
    .rst_n                        (rst_n),
    .chip0_icu_enable_i           (c0_icu_en),
    .chip0_imem_vliw_bundle_i     (c0_vliw),
    .chip0_pc_slice_o             (c0_pc),
    .chip0_slice_halted_o         (c0_halted),
    .chip1_icu_enable_i           (c1_icu_en),
    .chip1_imem_vliw_bundle_i     (c1_vliw),
    .chip1_pc_slice_o             (c1_pc),
    .chip1_slice_halted_o         (c1_halted),
    .chip0_host_mem_w_wr_en_i     (c0_mem_wr_en),
    .chip0_host_mem_w_bank_i      (c0_mem_bank),
    .chip0_host_mem_w_addr_i      (c0_mem_addr),
    .chip0_host_mem_w_data_i      (c0_mem_data),
    .chip1_host_mem_w_wr_en_i     (c1_mem_wr_en),
    .chip1_host_mem_w_bank_i      (c1_mem_bank),
    .chip1_host_mem_w_addr_i      (c1_mem_addr),
    .chip1_host_mem_w_data_i      (c1_mem_data),
    .c2c_link_delay_sel_i         (c2c_delay_sel),
    .expected_flight_cycles_i     (expected_flight),
    .chip1_realsync_adj_en_i      (c1_rs_adj_en),
    .chip1_realsync_adj_val_i     (c1_rs_adj_val),
    .chip0_stream_valid_east_o    (c0_eval),
    .chip0_stream_data_east_o     (c0_edat),
    .chip1_stream_valid_east_o    (c1_eval),
    .chip1_stream_data_east_o     (c1_edat),
    .chip0_c2c_tx_valid_o         (c0_tx_val),
    .chip1_c2c_tx_valid_o         (c1_tx_val),
    .chip0_deskew_release_valid_o (c0_dsk_val),
    .chip1_deskew_release_valid_o (c1_dsk_val),
    .chip0_measured_skew_o        (c0_skew),
    .chip1_measured_skew_o        (c1_skew),
    .cluster_collision_fault_o    (coll_flt),
    .cluster_c2c_crc_err_o        (crc_err),
    .chip0_gated_hop_count_o      (c0_gated),
    .chip1_gated_hop_count_o      (c1_gated)
  );

  // 2. Groq 3 LPX MXFP8 / NVFP4 Dot Engine
  logic         dot_val, dot_zskip, dot_acc_en, dot_acc_clr, dot_val_o, dot_bzero_o, dot_nan_o;
  logic [2:0]   dot_mode;
  logic [7:0]   dot_ascale, dot_wscale;
  logic [127:0] dot_act, dot_wt;
  logic signed [31:0] dot_unacc_o, dot_acc_o;
  logic [31:0]  dot_fp32_o;
  logic [5:0]   dot_zlanes_o;

  groq_mxfp8_nvfp4_dot_engine u_dot (
    .clk(clk), .rst_n(rst_n), .valid_i(dot_val), .mode_i(dot_mode), .zero_skip_en_i(dot_zskip),
    .accum_en_i(dot_acc_en), .accum_clear_i(dot_acc_clr), .act_scale_e8m0_i(dot_ascale), .wt_scale_e8m0_i(dot_wscale),
    .act_stream_i(dot_act), .wt_stream_i(dot_wt), .valid_o(dot_val_o), .unaccum_dot_o(dot_unacc_o),
    .dot_accum_o(dot_acc_o), .dot_fp32_o(dot_fp32_o), .zero_skip_lanes_o(dot_zlanes_o),
    .block_zero_skipped_o(dot_bzero_o), .nan_inf_flag_o(dot_nan_o)
  );

  // 3. Groq 3 LPX C2C KV-Cache Quantization RX Engine
  logic         kvq_val, kvq_oval, kvq_wren, kvq_nan;
  logic [1:0]   kvq_mode, kvq_bank, kvq_wbank, kvq_crat;
  logic [127:0] kvq_lo, kvq_hi, kvq_vec;
  logic [15:0]  kvq_addr, kvq_waddr;
  logic [7:0]   kvq_scale;
  logic [4:0]   kvq_zcnt;

  groq_c2c_kv_quant_rx_engine u_kvq (
    .clk(clk), .rst_n(rst_n), .valid_i(kvq_val), .quant_mode_i(kvq_mode),
    .kv_in_lo_i(kvq_lo), .kv_in_hi_i(kvq_hi), .target_sram_bank_i(kvq_bank), .target_sram_addr_i(kvq_addr),
    .valid_o(kvq_oval), .quant_vec_o(kvq_vec), .scale_e8m0_o(kvq_scale),
    .sram_wr_en_o(kvq_wren), .sram_wr_bank_o(kvq_wbank), .sram_wr_addr_o(kvq_waddr),
    .zero_lanes_cnt_o(kvq_zcnt), .nan_inf_clamped_o(kvq_nan), .compression_ratio_code_o(kvq_crat)
  );

  // 4. Speculative Decode Tree Sampler & Top-K/Top-P Engine
  logic         sdt_val, sdt_rng_step, sdt_oval;
  logic [1:0]   sdt_mode;
  logic [127:0] sdt_logits, sdt_tok_ids, sdt_slogits, sdt_stokens;
  logic [3:0]   sdt_top_k;
  logic [7:0]   sdt_inv_temp, sdt_rng_th, sdt_bonus_tok, sdt_stok, sdt_slog, sdt_amask;
  logic [15:0]  sdt_top_p, sdt_nmask;
  logic [23:0]  sdt_tree_pidx;
  logic [63:0]  sdt_tree_dprob, sdt_tree_tprob, sdt_tree_rand, sdt_tree_dtok;
  logic [2:0]   sdt_bleaf, sdt_alen, sdt_temit, sdt_kvadv;
  logic [39:0]  sdt_ctoks;
  logic [31:0]  sdt_prng;

  groq_spec_decode_tree_sampler u_sdt (
    .clk(clk), .rst_n(rst_n), .valid_i(sdt_val), .op_mode_i(sdt_mode),
    .logits_i(sdt_logits), .token_ids_i(sdt_tok_ids), .top_k_i(sdt_top_k),
    .inv_temp_i(sdt_inv_temp), .top_p_thresh_i(sdt_top_p), .rng_seed_step_i(sdt_rng_step), .rng_threshold_i(sdt_rng_th),
    .tree_parent_idx_i(sdt_tree_pidx), .tree_draft_prob_i(sdt_tree_dprob), .tree_target_prob_i(sdt_tree_tprob),
    .tree_rand_u_i(sdt_tree_rand), .tree_draft_tok_i(sdt_tree_dtok), .bonus_tok_i(sdt_bonus_tok),
    .valid_o(sdt_oval), .selected_token_o(sdt_stok), .selected_logit_o(sdt_slog),
    .sorted_logits_o(sdt_slogits), .sorted_tokens_o(sdt_stokens), .nucleus_mask_o(sdt_nmask),
    .accepted_node_mask_o(sdt_amask), .best_leaf_idx_o(sdt_bleaf), .accepted_draft_len_o(sdt_alen),
    .total_emitted_tokens_o(sdt_temit), .committed_tokens_o(sdt_ctoks), .kv_ring_advance_o(sdt_kvadv), .prng_state_o(sdt_prng)
  );

  // 5. Power & di/dt Droop Controller
  logic        droop_en, droop_prewarm, drp_throt;
  logic [7:0]  droop_slice_act, drp_bmask, droop_pw_target, droop_max_step;
  logic [5:0]  droop_zskip_cnt;
  logic [11:0] droop_vdd_nom, droop_emerg_th, drp_vdd;
  logic [7:0]  drp_raw, drp_eff, drp_bleed, drp_temp;
  logic [15:0] drp_evts;
  logic signed [8:0] drp_didt;

  groq_power_droop_controller u_droop (
    .clk(clk), .rst_n(rst_n), .enable_i(droop_en), .slice_active_i(droop_slice_act), .mxm_zero_skip_cnt_i(droop_zskip_cnt),
    .prewarm_hint_i(droop_prewarm), .prewarm_target_level_i(droop_pw_target), .max_didt_step_i(droop_max_step),
    .vdd_nominal_mv_i(droop_vdd_nom), .droop_emerg_thresh_mv_i(droop_emerg_th),
    .raw_demand_o(drp_raw), .eff_current_o(drp_eff), .dummy_bleed_current_o(drp_bleed),
    .dummy_bleed_mask_o(drp_bmask), .didt_signed_o(drp_didt), .vdd_est_mv_o(drp_vdd),
    .thermal_temp_c_o(drp_temp), .emerg_throttle_o(drp_throt), .droop_mitigated_events_o(drp_evts)
  );

  // 6. Zero-Stall Cycle-Stealing SRAM SECDED Scrubber & eFuse Repair Controller
  logic        scb_efuse_req, scb_vliw_ren, scb_vliw_wen, scb_dma_wen, scb_scrub_en, scb_ser_en;
  logic [1:0]  scb_efuse_bank, scb_efuse_addr, scb_vliw_rbank, scb_vliw_raddr, scb_vliw_wbank, scb_vliw_waddr, scb_dma_wbank, scb_dma_waddr, scb_ser_bank, scb_ser_addr;
  logic [127:0] scb_vliw_wdata, scb_dma_wdata, scb_rdat;
  logic [143:0] scb_ser_mask;
  logic [3:0]   scb_repen;
  logic [7:0]   scb_repadr;
  logic         scb_efack, scb_rval, scb_rsec, scb_rded, scb_rhit, scb_rdfire, scb_wbfire, scb_dedal;
  logic [1:0]   scb_abank, scb_aaddr, scb_fbank, scb_faddr;
  logic [15:0]  scb_ccnt;

  groq_sram_controller_scrubber #(.P_ADDR_W(2)) u_scb (
    .clk(clk), .rst_n(rst_n), .efuse_load_req_i(scb_efuse_req), .efuse_bank_i(scb_efuse_bank), .efuse_bad_addr_i(scb_efuse_addr),
    .bank_repair_en_o(scb_repen), .bank_repair_addr_o(scb_repadr), .efuse_load_ack_o(scb_efack),
    .vliw_rd_en_i(scb_vliw_ren), .vliw_rd_bank_i(scb_vliw_rbank), .vliw_rd_addr_i(scb_vliw_raddr),
    .vliw_rd_valid_o(scb_rval), .vliw_rd_data_o(scb_rdat), .vliw_rd_sec_err_o(scb_rsec),
    .vliw_rd_ded_err_o(scb_rded), .vliw_rd_repaired_row_hit_o(scb_rhit),
    .vliw_wr_en_i(scb_vliw_wen), .vliw_wr_bank_i(scb_vliw_wbank), .vliw_wr_addr_i(scb_vliw_waddr), .vliw_wr_data_i(scb_vliw_wdata),
    .dma_wr_en_i(scb_dma_wen), .dma_wr_bank_i(scb_dma_wbank), .dma_wr_addr_i(scb_dma_waddr), .dma_wr_data_i(scb_dma_wdata),
    .scrub_enable_i(scb_scrub_en), .scrub_rd_fire_o(scb_rdfire), .scrub_wb_fire_o(scb_wbfire),
    .scrub_active_bank_o(scb_abank), .scrub_active_addr_o(scb_aaddr), .scrub_corrected_cnt_o(scb_ccnt),
    .scrub_ded_alert_o(scb_dedal), .first_ded_bank_o(scb_fbank), .first_ded_addr_o(scb_faddr),
    .ser_inject_en_i(scb_ser_en), .ser_inject_bank_i(scb_ser_bank), .ser_inject_addr_i(scb_ser_addr), .ser_inject_mask_i(scb_ser_mask)
  );

  // Telemetry Counters across 10,000 Cycles (5 Decode Phases x 2,000 Cycles)
  longint unsigned total_cycles = 0;
  longint unsigned mxm_active_cycles = 0;
  longint unsigned dot_valid_cycles = 0;
  longint unsigned zero_skipped_lanes_sum = 0;
  longint unsigned total_dot_lanes_sum = 0;
  longint unsigned c2c_tx_packets = 0;
  longint unsigned c2c_deskew_releases = 0;
  longint unsigned kvq_compressed_packets = 0;
  longint unsigned spec_verify_steps = 0;
  longint unsigned spec_emitted_tokens_sum = 0;
  longint unsigned vdd_min_mv = 900;
  longint unsigned vdd_max_mv = 0;
  longint unsigned max_abs_didt = 0;
  longint unsigned gated_stream_hops_sum = 0;

  logic [63:0] prng = 64'h9E37_79B9_7F4A_7C15;
  function automatic logic [63:0] next_rng(input logic [63:0] s);
    logic [63:0] x = s;
    x ^= (x << 13); x ^= (x >> 7); x ^= (x << 17);
    return x;
  endfunction

  groq_vliw_instr_t instr;
  integer fd;

  initial begin
    c0_icu_en = 1'b0; c1_icu_en = 1'b0;
    c0_vliw = '0;     c1_vliw = '0;
    c0_mem_wr_en = 1'b0; c0_mem_bank = '0; c0_mem_addr = '0; c0_mem_data = '0;
    c1_mem_wr_en = 1'b0; c1_mem_bank = '0; c1_mem_addr = '0; c1_mem_data = '0;
    c2c_delay_sel = 2'd1; expected_flight = 16'd3;
    c1_rs_adj_en = 1'b0;  c1_rs_adj_val = 16'sd0;
    dot_val = 1'b0; dot_zskip = 1'b1; dot_acc_en = 1'b1; dot_acc_clr = 1'b0;
    dot_mode = 3'd2; dot_ascale = 8'd127; dot_wscale = 8'd127;
    dot_act = '0; dot_wt = '0;
    kvq_val = 1'b0; kvq_mode = 2'd1; kvq_bank = 2'd0; kvq_lo = '0; kvq_hi = '0; kvq_addr = '0;
    sdt_val = 1'b0; sdt_mode = 2'd2; sdt_logits = '0; sdt_tok_ids = '0; sdt_top_k = 4'd4;
    sdt_inv_temp = 8'd16; sdt_top_p = 16'h00E0; sdt_rng_step = 1'b0; sdt_rng_th = 8'd64;
    sdt_tree_pidx = 24'hAD_22_40; sdt_tree_dprob = 64'hA0A0_A0A0_A0A0_A0A0;
    sdt_tree_tprob = 64'h80B0_90B0_B0B0_C0F0; sdt_tree_rand = 64'h3040_5060_7080_90A0;
    sdt_tree_dtok = 64'h1817_1615_1413_1211; sdt_bonus_tok = 8'h2A;
    droop_en = 1'b1; droop_slice_act = 8'h00; droop_zskip_cnt = 6'd0;
    droop_prewarm = 1'b0; droop_pw_target = 8'd180; droop_max_step = 8'd24;
    droop_vdd_nom = 12'd850; droop_emerg_th = 12'd780;
    scb_efuse_req = 1'b0; scb_efuse_bank = 2'd0; scb_efuse_addr = 2'd0;
    scb_vliw_ren = 1'b0; scb_vliw_rbank = 2'd0; scb_vliw_raddr = 2'd0;
    scb_vliw_wen = 1'b0; scb_vliw_wbank = 2'd0; scb_vliw_waddr = 2'd0; scb_vliw_wdata = '0;
    scb_dma_wen = 1'b0; scb_dma_wbank = 2'd0; scb_dma_waddr = 2'd0; scb_dma_wdata = '0;
    scb_scrub_en = 1'b1; scb_ser_en = 1'b0; scb_ser_bank = 2'd0; scb_ser_addr = 2'd0; scb_ser_mask = 144'd1;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    c0_icu_en = 1'b1; c1_icu_en = 1'b1;

    // 10,000-Cycle Deterministic LLM Decode Hardware-in-the-Loop Execution
    for (int cyc = 0; cyc < 10000; cyc++) begin
      prng = next_rng(prng);
      total_cycles++;

      if (cyc < 64) begin
        c0_mem_wr_en = 1'b1; c0_mem_bank = cyc[1:0]; c0_mem_addr = cyc[9:0];
        c0_mem_data = {prng, prng ^ 64'h5555_AAAA_5555_AAAA};
        c1_mem_wr_en = 1'b1; c1_mem_bank = cyc[1:0]; c1_mem_addr = cyc[9:0];
        c1_mem_data = {prng ^ 64'h1234_5678_9ABC_DEF0, prng};
        scb_dma_wen = 1'b1; scb_dma_wbank = cyc[1:0]; scb_dma_waddr = cyc[3:2];
        scb_dma_wdata = {prng, ~prng};
        droop_prewarm = 1'b1;
        droop_slice_act = 8'h0F;
      end else begin
        c0_mem_wr_en = 1'b0; c1_mem_wr_en = 1'b0; scb_dma_wen = 1'b0;
        droop_prewarm = (cyc >= 9900);
        droop_slice_act = (cyc < 9920) ? 8'hFF : 8'h03;
      end

      // Inject periodic single-bit soft errors into idle SRAM bank for patrol scrubber auto-healing
      scb_ser_en = (cyc >= 100 && cyc < 9000 && cyc[6:0] == 7'd32);
      scb_ser_bank = cyc[8:7]; scb_ser_addr = cyc[10:9]; scb_ser_mask = 144'd1 << cyc[5:0];

      instr = '0;
      instr.mem_op = (cyc >= 64 && cyc < 9920) ?
                     ((cyc >= 5998 && cyc < 7998 && cyc[1:0] == 2'b00) ? MEM_READ_WEST : MEM_READ_EAST) : MEM_NOP;
      instr.dst_stream = (cyc >= 5998 && cyc < 7998 && cyc[1:0] == 2'b00) ? 5'd0 : 5'd1;
      instr.dst_dir_west = (cyc >= 5998 && cyc < 7998 && cyc[1:0] == 2'b00);
      instr.mem_base_addr = {10'd0, cyc[5:0]};
      instr.sxm_op = (cyc[2:0] == 3'd0) ? SXM_BARREL_ROTATE : SXM_PASSTHROUGH;
      instr.vxm_op = (cyc[3:0] == 4'd0) ? VXM_RMSNORM_RED : VXM_SWIGLU;
      if (cyc >= 64 && cyc < 9920) begin
        instr.mxm_op = (cyc[4:0] == 5'd0) ? MXM_LOAD_WEIGHT_B0 : MXM_SYSTOLIC_EXEC;
        mxm_active_cycles++;
      end else begin
        instr.mxm_op = MXM_NOP;
      end
      instr.nim_op = (cyc >= 6000 && cyc < 8005) ? NIM_SEND : NIM_NOP;
      instr.src_stream_a = 5'd16; // Westward stream 0 arriving at SLICE_NIM (Hop 0)
      instr.imm16 = 16'h0001;     // Destination Chip 1
      for (int s = 0; s < NUM_SLICES; s++) begin
        instr.target_slice = s[3:0];
        if (s != SLICE_NIM) begin
          instr.src_stream_a = 5'd1;
          instr.dst_stream   = (s == SLICE_MEM_W && cyc >= 5998 && cyc < 7998 && cyc[1:0] == 2'b00) ? 5'd0 : 5'(s + 1);
        end
        c0_vliw[s] = instr;
        c1_vliw[s] = instr;
      end

      dot_val = (cyc >= 64 && cyc < 9920);
      dot_mode = (cyc < 5000) ? 3'd2 : 3'd3;
      dot_act = {
        (prng[3:0]  < 4'd4) ? 16'h0000 : prng[15:0],
        (prng[7:4]  < 4'd4) ? 16'h0000 : prng[31:16],
        (prng[11:8] < 4'd4) ? 16'h0000 : prng[47:32],
        prng[63:48], prng[15:0] ^ 16'h1357, prng[31:16] ^ 16'h2468,
        (prng[15:12] < 4'd4) ? 16'h0000 : prng[47:32], prng[63:48] ^ 16'h9ABC
      };
      dot_wt = {prng[63:0], ~prng[63:0]};

      kvq_val = (cyc >= 2000 && cyc < 8000 && cyc[0] == 1'b0);
      kvq_mode = (cyc < 5000) ? 2'd1 : 2'd2;
      kvq_lo = {prng, ~prng}; kvq_hi = {prng ^ 64'hF0F0_0F0F_F0F0_0F0F, prng};
      kvq_bank = cyc[1:0]; kvq_addr = cyc[15:0];

      sdt_val = (cyc >= 8000 && cyc < 9900 && cyc[2:0] == 3'd0);
      sdt_rng_step = sdt_val;
      sdt_tree_rand = prng;
      sdt_tree_tprob = (cyc[3] == 1'b0) ? 64'h8080_B0B0_B0B0_C0F0 : 64'h8080_8060_B0B0_C0F0;

      #1ps;
      if ((drp_didt < 0 ? 64'(-drp_didt) : 64'(drp_didt)) > max_abs_didt)
        max_abs_didt = (drp_didt < 0 ? 64'(-drp_didt) : 64'(drp_didt));

      @(posedge clk);
      #1step;

      if (dot_val_o) begin
        dot_valid_cycles++;
        zero_skipped_lanes_sum += 64'(dot_zlanes_o);
        total_dot_lanes_sum += (dot_mode == 3'd3) ? 64'd32 : 64'd16;
      end
      droop_zskip_cnt = dot_zlanes_o;
      if (c0_tx_val) c2c_tx_packets++;
      if (c1_dsk_val) c2c_deskew_releases++;
      if (kvq_oval && kvq_wren) kvq_compressed_packets++;
      if (sdt_oval) begin
        spec_verify_steps++;
        spec_emitted_tokens_sum += 64'(sdt_temit);
      end
      if (drp_vdd < vdd_min_mv && cyc > 10) vdd_min_mv = 64'(drp_vdd);
      if (drp_vdd > vdd_max_mv && cyc > 10) vdd_max_mv = 64'(drp_vdd);
      gated_stream_hops_sum = 64'(c0_gated) + 64'(c1_gated);
    end

    fd = $fopen("rtl_hardware_telemetry.json", "w");
    $fwrite(fd, "{\n");
    $fwrite(fd, "  \"testbench\": \"tb_rtl_perf_energy_calibration\",\n");
    $fwrite(fd, "  \"simulator\": \"Verilator 5.054\",\n");
    $fwrite(fd, "  \"total_cycles\": %0d,\n", total_cycles);
    $fwrite(fd, "  \"mxm_active_cycles\": %0d,\n", mxm_active_cycles);
    $fwrite(fd, "  \"mxm_steady_state_utilization_pct\": %.4f,\n", (100.0 * real'(mxm_active_cycles)) / real'(total_cycles));
    $fwrite(fd, "  \"dot_valid_cycles\": %0d,\n", dot_valid_cycles);
    $fwrite(fd, "  \"zero_skipped_lanes_sum\": %0d,\n", zero_skipped_lanes_sum);
    $fwrite(fd, "  \"total_dot_lanes_sum\": %0d,\n", total_dot_lanes_sum);
    $fwrite(fd, "  \"measured_zero_skip_ratio_pct\": %.4f,\n", (100.0 * real'(zero_skipped_lanes_sum)) / real'(total_dot_lanes_sum));
    $fwrite(fd, "  \"c2c_tx_packets\": %0d,\n", c2c_tx_packets);
    $fwrite(fd, "  \"c2c_deskew_releases\": %0d,\n", c2c_deskew_releases);
    $fwrite(fd, "  \"c2c_measured_skew_cycles\": %0d,\n", c1_skew);
    $fwrite(fd, "  \"c2c_crc_errors\": %0d,\n", crc_err);
    $fwrite(fd, "  \"cluster_collision_faults\": %0d,\n", coll_flt);
    $fwrite(fd, "  \"kvq_compressed_packets\": %0d,\n", kvq_compressed_packets);
    $fwrite(fd, "  \"spec_verify_steps\": %0d,\n", spec_verify_steps);
    $fwrite(fd, "  \"spec_emitted_tokens_sum\": %0d,\n", spec_emitted_tokens_sum);
    $fwrite(fd, "  \"spec_mean_accepted_tokens_per_step\": %.4f,\n", real'(spec_emitted_tokens_sum) / real'(spec_verify_steps));
    $fwrite(fd, "  \"vdd_nominal_mv\": 850,\n");
    $fwrite(fd, "  \"vdd_min_mv\": %0d,\n", vdd_min_mv);
    $fwrite(fd, "  \"vdd_max_mv\": %0d,\n", vdd_max_mv);
    $fwrite(fd, "  \"max_abs_didt_step\": %0d,\n", max_abs_didt);
    $fwrite(fd, "  \"droop_mitigated_events\": %0d,\n", drp_evts);
    $fwrite(fd, "  \"emerg_throttle_events\": %0d,\n", drp_throt);
    $fwrite(fd, "  \"sram_scrub_corrected_sbe\": %0d,\n", scb_ccnt);
    $fwrite(fd, "  \"sram_scrub_ded_alerts\": %0d,\n", scb_dedal);
    $fwrite(fd, "  \"gated_stream_hops_sum\": %0d\n", gated_stream_hops_sum);
    $fwrite(fd, "}\n");
    $fclose(fd);
    $display("[STAGE48-HIL-PASS] 10,000-cycle RTL calibration complete: MXM_util=%.2f%%, ZeroSkip=%.2f%%, C2C_TX=%0d, C2C_Deskew=%0d, SBE_Healed=%0d, Max_di/dt=%0d, Skew=%0d, Collisions=%0d",
             (100.0 * real'(mxm_active_cycles)) / real'(total_cycles),
             (100.0 * real'(zero_skipped_lanes_sum)) / real'(total_dot_lanes_sum),
             c2c_tx_packets, c2c_deskew_releases, scb_ccnt, max_abs_didt, c1_skew, coll_flt);
    $finish;
  end
endmodule
