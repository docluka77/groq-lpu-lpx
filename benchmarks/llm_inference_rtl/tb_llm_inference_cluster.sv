// =============================================================================
// File: benchmarks/llm_inference_rtl/tb_llm_inference_cluster.sv
// Description: Stage 9 End-to-End LLM Token Decode Hardware Benchmark Testbench
//              on 2-Chip Groq LPU Cluster (groq_lpu_cluster_top) + Live SRAM
//              SECDED Single-Bit ECC Fault Injection Verification.
// =============================================================================
`timescale 1ns/1ps
`include "groq_pkg.sv"

module tb_llm_inference_cluster (
  input logic clk,
  input logic rst_n
);
  import groq_pkg::*;

  localparam int P_NUM_SLICES = 8;
  localparam int P_STREAM_W   = 128;
  localparam int MAX_IMEM_PC  = 276;

  // Instruction Memory ROMs for Chip 0 and Chip 1 (8 slices x 276 PCs)
  logic [143:0] chip0_imem_rom [0:P_NUM_SLICES-1][0:MAX_IMEM_PC-1];
  logic [143:0] chip1_imem_rom [0:P_NUM_SLICES-1][0:MAX_IMEM_PC-1];

  logic                                   icu_enable_q;
  logic [P_NUM_SLICES-1:0][143:0]         chip0_vliw_bundle, chip1_vliw_bundle;
  logic [P_NUM_SLICES-1:0][15:0]          chip0_pc_slice,    chip1_pc_slice;
  logic [P_NUM_SLICES-1:0]                chip0_halted,      chip1_halted;

  // Host DMA West SRAM Preload Signals
  logic         c0_dma_wr_en,   c1_dma_wr_en;
  logic [1:0]   c0_dma_bank,    c1_dma_bank;
  logic [9:0]   c0_dma_addr,    c1_dma_addr;
  logic [127:0] c0_dma_data,    c1_dma_data;

  // Cluster Telemetry & Stream Observation Outputs
  logic [P_NUM_SLICES-1:0][15:0]          c0_valid_east, c1_valid_east;
  logic [P_NUM_SLICES-1:0][15:0][127:0]   c0_data_east,  c1_data_east;
  logic         c0_c2c_tx_val, c1_c2c_tx_val;
  logic         c0_deskew_val, c1_deskew_val;
  logic signed [15:0] c0_skew, c1_skew;
  logic         cluster_coll_flt, cluster_crc_err;
  logic [15:0]  c0_gated_hops, c1_gated_hops;

  always_comb begin
    for (int s = 0; s < P_NUM_SLICES; s++) begin
      chip0_vliw_bundle[s] = chip0_imem_rom[s][(chip0_pc_slice[s] < 16'(MAX_IMEM_PC)) ? chip0_pc_slice[s] : 16'(MAX_IMEM_PC - 1)];
      chip1_vliw_bundle[s] = chip1_imem_rom[s][(chip1_pc_slice[s] < 16'(MAX_IMEM_PC)) ? chip1_pc_slice[s] : 16'(MAX_IMEM_PC - 1)];
    end
  end

  // ---------------------------------------------------------------------------
  // 1. Primary 2-Chip Groq LPU Cluster Under Test (groq_lpu_cluster_top)
  // ---------------------------------------------------------------------------
  groq_lpu_cluster_top u_cluster (
    .clk                          (clk),
    .rst_n                        (rst_n),
    .chip0_icu_enable_i           (icu_enable_q),
    .chip0_imem_vliw_bundle_i     (chip0_vliw_bundle),
    .chip0_pc_slice_o             (chip0_pc_slice),
    .chip0_slice_halted_o         (chip0_halted),
    .chip1_icu_enable_i           (icu_enable_q),
    .chip1_imem_vliw_bundle_i     (chip1_vliw_bundle),
    .chip1_pc_slice_o             (chip1_pc_slice),
    .chip1_slice_halted_o         (chip1_halted),
    .chip0_host_mem_w_wr_en_i     (c0_dma_wr_en),
    .chip0_host_mem_w_bank_i      (c0_dma_bank),
    .chip0_host_mem_w_addr_i      (c0_dma_addr),
    .chip0_host_mem_w_data_i      (c0_dma_data),
    .chip1_host_mem_w_wr_en_i     (c1_dma_wr_en),
    .chip1_host_mem_w_bank_i      (c1_dma_bank),
    .chip1_host_mem_w_addr_i      (c1_dma_addr),
    .chip1_host_mem_w_data_i      (c1_dma_data),
    .c2c_link_delay_sel_i         (2'd1),
    .expected_flight_cycles_i     (16'd3),
    .chip1_realsync_adj_en_i      (1'b0),
    .chip1_realsync_adj_val_i     (16'sd0),
    .chip0_stream_valid_east_o    (c0_valid_east),
    .chip0_stream_data_east_o     (c0_data_east),
    .chip1_stream_valid_east_o    (c1_valid_east),
    .chip1_stream_data_east_o     (c1_data_east),
    .chip0_c2c_tx_valid_o         (c0_c2c_tx_val),
    .chip1_c2c_tx_valid_o         (c1_c2c_tx_val),
    .chip0_deskew_release_valid_o (c0_deskew_val),
    .chip1_deskew_release_valid_o (c1_deskew_val),
    .chip0_measured_skew_o        (c0_skew),
    .chip1_measured_skew_o        (c1_skew),
    .cluster_collision_fault_o    (cluster_coll_flt),
    .cluster_c2c_crc_err_o        (cluster_crc_err),
    .chip0_gated_hop_count_o      (c0_gated_hops),
    .chip1_gated_hop_count_o      (c1_gated_hops)
  );

  // ---------------------------------------------------------------------------
  // 2. Shadow Chip 0 Instance with Live Single-Bit SRAM ECC Fault Injection
  //    (mem_err_inject_en_i = 1'b1 flips bit 3 of every 144-bit SRAM codeword
  //     during live KV-Cache / Weight / Embedding reads; SECDED corrects it!)
  // ---------------------------------------------------------------------------
  logic [P_NUM_SLICES-1:0]                ecc_dut_fetch_unused, ecc_dut_vval_unused, ecc_dut_halted;
  logic [P_NUM_SLICES-1:0][15:0]          ecc_dut_pc;
  logic [P_NUM_SLICES-1:0][143:0]         ecc_dut_vbun_unused;
  logic [P_NUM_SLICES-1:0][15:0]          ecc_dut_east_val, ecc_dut_west_val;
  logic [P_NUM_SLICES-1:0][15:0][127:0]   ecc_dut_east_dat, ecc_dut_west_dat;
  logic [1:0]                             ecc_dut_single_err, ecc_dut_double_err, ecc_dut_bconf;
  logic [15:0]                            ecc_dut_gated_hops;
  logic [4:0]                             ecc_dut_zsw, ecc_dut_zse;
  logic                                   ecc_dut_mg, ecc_dut_lg;
  logic signed [15:0]                     ecc_dut_rsum;
  logic signed [7:0]                      ecc_dut_rmax;
  logic                                   ecc_dut_tx_val_unused, ecc_dut_coll_flt, ecc_dut_coll_stk;
  logic [127:0]                           ecc_dut_tx_dat_unused;
  logic [15:0]                            ecc_dut_tx_ts_unused, ecc_dut_bcnt_unused;
  logic [3:0]                             ecc_dut_tx_dst_unused;
  logic [7:0]                             ecc_dut_tx_crc_unused;
  logic [1:0]                             ecc_dut_tx_port_unused;
  logic [P_NUM_SLICES-1:0]                ecc_dut_bwait_unused;
  logic                                   ecc_dut_brel_unused, ecc_dut_drift_unused, ecc_dut_deskew_val;
  logic [63:0]                            ecc_dut_rstime_unused;
  logic signed [15:0]                     ecc_dut_skew_unused;
  logic                                   ecc_dut_crc_err_unused;

  groq_lpu_top u_chip0_ecc_dut (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .icu_enable_i             (icu_enable_q),
    .imem_vliw_bundle_i       (chip0_vliw_bundle),
    .imem_fetch_en_o          (ecc_dut_fetch_unused),
    .pc_slice_o               (ecc_dut_pc),
    .slice_vliw_valid_o       (ecc_dut_vval_unused),
    .slice_vliw_bundle_o      (ecc_dut_vbun_unused),
    .slice_halted_o           (ecc_dut_halted),
    .ext_east_inject_en_i     ('0),
    .ext_east_inject_data_i   ('0),
    .ext_west_inject_en_i     ('0),
    .ext_west_inject_data_i   ('0),
    .ext_overwrite_allow_i    (1'b1),
    .stream_valid_east_o      (ecc_dut_east_val),
    .stream_data_east_o       (ecc_dut_east_dat),
    .stream_valid_west_o      (ecc_dut_west_val),
    .stream_data_west_o       (ecc_dut_west_dat),
    .host_mem_w_wr_en_i       (c0_dma_wr_en),
    .host_mem_w_bank_i        (c0_dma_bank),
    .host_mem_w_addr_i        (c0_dma_addr),
    .host_mem_w_data_i        (c0_dma_data),
    .host_mem_e_wr_en_i       (1'b0),
    .host_mem_e_bank_i        ('0),
    .host_mem_e_addr_i        ('0),
    .host_mem_e_data_i        ('0),
    .mem_err_inject_en_i      (icu_enable_q),
    .mem_err_inject_mask_i    (144'h0000_0000_0000_0000_0000_0000_0000_0000_0008),
    .local_chip_id_i          (4'd0),
    .expected_flight_cycles_i (16'd3),
    .realsync_ext_adj_en_i    (1'b0),
    .realsync_ext_adj_val_i   (16'sd0),
    .c2c_rx_valid_i           (u_cluster.c0_rx_valid),
    .c2c_rx_data_i            (u_cluster.c0_rx_data),
    .c2c_rx_tx_timestamp_i    (u_cluster.c0_rx_ts),
    .c2c_rx_dst_chip_i        (u_cluster.c0_rx_dst),
    .c2c_rx_crc8_i            (u_cluster.c0_rx_crc),
    .c2c_tx_valid_o           (ecc_dut_tx_val_unused),
    .c2c_tx_data_o            (ecc_dut_tx_dat_unused),
    .c2c_tx_timestamp_o       (ecc_dut_tx_ts_unused),
    .c2c_tx_dst_chip_o        (ecc_dut_tx_dst_unused),
    .c2c_tx_crc8_o            (ecc_dut_tx_crc_unused),
    .c2c_tx_port_sel_o        (ecc_dut_tx_port_unused),
    .collision_fault_o        (ecc_dut_coll_flt),
    .collision_sticky_o       (ecc_dut_coll_stk),
    .barrier_waiting_o        (ecc_dut_bwait_unused),
    .barrier_release_pulse_o  (ecc_dut_brel_unused),
    .barrier_release_cnt_o    (ecc_dut_bcnt_unused),
    .realsync_aligned_time_o  (ecc_dut_rstime_unused),
    .realsync_drift_fault_o   (ecc_dut_drift_unused),
    .deskew_release_valid_o   (ecc_dut_deskew_val),
    .measured_skew_o          (ecc_dut_skew_unused),
    .c2c_crc_err_o            (ecc_dut_crc_err_unused),
    .ecc_single_err_o         (ecc_dut_single_err),
    .ecc_double_err_o         (ecc_dut_double_err),
    .bank_conflict_err_o      (ecc_dut_bconf),
    .gated_hop_count_o        (ecc_dut_gated_hops),
    .zero_skip_count_w_o      (ecc_dut_zsw),
    .zero_skip_count_e_o      (ecc_dut_zse),
    .mul_gate_active_o        (ecc_dut_mg),
    .lut_gate_active_o        (ecc_dut_lg),
    .vxm_reduce_sum_o         (ecc_dut_rsum),
    .vxm_reduce_max_o         (ecc_dut_rmax)
  );

  // ---------------------------------------------------------------------------
  // 3. Cycle-Accurate Hardware Telemetry & Intermediate Tensor Capture
  // ---------------------------------------------------------------------------
  int unsigned total_exec_cycles;
  int unsigned ecc_corrected_count;
  int unsigned ecc_double_err_count;
  int unsigned stream_mismatch_vs_ecc_dut;
  int unsigned c0_deskew_events, c1_deskew_events;
  int unsigned c0_c2c_flits_tx,  c1_c2c_flits_tx;
  int unsigned total_zero_skip_lanes;
  int unsigned mul_gated_cycles, lut_gated_cycles;

  logic [127:0] cap_stage_a_x_norm;
  logic [127:0] cap_c0_q_raw, cap_c0_q_rope, cap_c0_k_rope, cap_c0_v_vec;
  logic [127:0] cap_c0_s_attn, cap_c0_p_exp, cap_c0_p_attn, cap_c0_o_attn;
  logic [127:0] cap_c0_g_ffn, cap_c0_u_ffn, cap_c0_h_swiglu, cap_c0_y_down;
  logic [127:0] cap_c1_q_rope, cap_c1_k_rope, cap_c1_o_attn, cap_c1_h_swiglu, cap_c1_y_down;
  logic [127:0] cap_c0_y_final_mem_e, cap_c1_y_final_mem_e, cap_ecc_dut_y_final_mem_e;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      total_exec_cycles          <= 0;
      ecc_corrected_count        <= 0;
      ecc_double_err_count       <= 0;
      stream_mismatch_vs_ecc_dut <= 0;
      c0_deskew_events           <= 0;
      c1_deskew_events           <= 0;
      c0_c2c_flits_tx            <= 0;
      c1_c2c_flits_tx            <= 0;
      total_zero_skip_lanes      <= 0;
      mul_gated_cycles           <= 0;
      lut_gated_cycles           <= 0;
    end else if (icu_enable_q && (chip0_halted != 8'hFF)) begin
      total_exec_cycles <= total_exec_cycles + 1;
      if (|ecc_dut_single_err) ecc_corrected_count  <= ecc_corrected_count + 1;
      if (|ecc_dut_double_err) ecc_double_err_count <= ecc_double_err_count + 1;
      if ((c0_valid_east != ecc_dut_east_val) || (c0_data_east != ecc_dut_east_dat))
        stream_mismatch_vs_ecc_dut <= stream_mismatch_vs_ecc_dut + 1;
      if (c0_deskew_val) c0_deskew_events <= c0_deskew_events + 1;
      if (c1_deskew_val) c1_deskew_events <= c1_deskew_events + 1;
      if (c0_c2c_tx_val) c0_c2c_flits_tx  <= c0_c2c_flits_tx + 1;
      if (c1_c2c_tx_val) c1_c2c_flits_tx  <= c1_c2c_flits_tx + 1;
      if (ecc_dut_mg)    mul_gated_cycles <= mul_gated_cycles + 1;
      if (ecc_dut_lg)    lut_gated_cycles <= lut_gated_cycles + 1;

      if (u_cluster.u_lpu_chip0.mxm_w_act_valid)
        total_zero_skip_lanes <= total_zero_skip_lanes + int'(ecc_dut_zsw);
      if (u_cluster.u_lpu_chip0.mxm_e_act_valid)
        total_zero_skip_lanes <= total_zero_skip_lanes + int'(ecc_dut_zse);

      // Capture exact stream & SRAM writeback tensors at scheduled deterministic PCs
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd23)  cap_stage_a_x_norm   <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd82)  cap_c0_q_raw         <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd86)  cap_c0_q_rope        <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd87)  cap_c0_k_rope        <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd93)  cap_c0_v_vec         <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd125) cap_c0_s_attn        <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd140) cap_c0_p_exp         <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd148) cap_c0_p_attn        <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd180) cap_c0_o_attn        <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd241) cap_c0_g_ffn         <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_VXM]   == 16'd242) cap_c0_u_ffn         <= u_cluster.u_lpu_chip0.vxm_stream_b;
      if (chip0_pc_slice[SLICE_MEM_W] == 16'd245) cap_c0_h_swiglu      <= u_cluster.u_lpu_chip0.mem_w_wr_data;
      if (chip0_pc_slice[SLICE_NIM]   == 16'd253) cap_c0_y_down        <= u_cluster.u_lpu_chip0.nim_stream_in_data;

      if (chip1_pc_slice[SLICE_MEM_W] == 16'd86)  cap_c1_q_rope        <= u_cluster.u_lpu_chip1.mem_w_wr_data;
      if (chip1_pc_slice[SLICE_MEM_W] == 16'd87)  cap_c1_k_rope        <= u_cluster.u_lpu_chip1.mem_w_wr_data;
      if (chip1_pc_slice[SLICE_MEM_W] == 16'd180) cap_c1_o_attn        <= u_cluster.u_lpu_chip1.mem_w_wr_data;
      if (chip1_pc_slice[SLICE_MEM_W] == 16'd245) cap_c1_h_swiglu      <= u_cluster.u_lpu_chip1.mem_w_wr_data;
      if (chip1_pc_slice[SLICE_NIM]   == 16'd256) cap_c1_y_down        <= u_cluster.u_lpu_chip1.nim_stream_in_data;

      if (chip1_pc_slice[SLICE_MEM_E] == 16'd264) cap_c1_y_final_mem_e <= u_cluster.u_lpu_chip1.mem_e_wr_data;
      if (chip0_pc_slice[SLICE_MEM_E] == 16'd267) begin
        cap_c0_y_final_mem_e      <= u_cluster.u_lpu_chip0.mem_e_wr_data;
        cap_ecc_dut_y_final_mem_e <= u_chip0_ecc_dut.mem_e_wr_data;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 4. Host DMA Preload, Execution Sequencer & JSON Telemetry Export
  // ---------------------------------------------------------------------------
  initial begin
    int fd0, fd1, r0, r1, out_fd;
    int b0, a0, b1, a1;
    logic [127:0] d0, d1;

    icu_enable_q = 1'b0;
    c0_dma_wr_en = 1'b0; c0_dma_bank = '0; c0_dma_addr = '0; c0_dma_data = '0;
    c1_dma_wr_en = 1'b0; c1_dma_bank = '0; c1_dma_addr = '0; c1_dma_data = '0;

    for (int s = 0; s < P_NUM_SLICES; s++) begin
      $readmemh($sformatf("chip0_imem_s%0d.hex", s), chip0_imem_rom[s]);
      $readmemh($sformatf("chip1_imem_s%0d.hex", s), chip1_imem_rom[s]);
    end

    @(posedge rst_n);
    @(posedge clk);

    // Preload Chip 0 and Chip 1 West SRAM Slices via Host DMA
    fd0 = $fopen("chip0_sram_preload.txt", "r");
    fd1 = $fopen("chip1_sram_preload.txt", "r");
    if ((fd0 == 0) || (fd1 == 0)) begin
      $display("FATAL: Could not open chip0/chip1_sram_preload.txt");
      $finish;
    end
    while (!$feof(fd0) && !$feof(fd1)) begin
      r0 = $fscanf(fd0, "%d %d %h\n", b0, a0, d0);
      r1 = $fscanf(fd1, "%d %d %h\n", b1, a1, d1);
      if ((r0 == 3) && (r1 == 3)) begin
        @(negedge clk);
        c0_dma_wr_en = 1'b1; c0_dma_bank = 2'(b0); c0_dma_addr = 10'(a0); c0_dma_data = d0;
        c1_dma_wr_en = 1'b1; c1_dma_bank = 2'(b1); c1_dma_addr = 10'(a1); c1_dma_data = d1;
        @(posedge clk);
      end
    end
    @(negedge clk);
    c0_dma_wr_en = 1'b0;
    c1_dma_wr_en = 1'b0;
    $fclose(fd0);
    $fclose(fd1);

    // Launch deterministic lockstep 2-Chip LLM Decode Schedule
    @(negedge clk);
    icu_enable_q = 1'b1;

    // Wait for all 8 slices on both Chip 0 and Chip 1 to reach ICU_HALT
    fork
      begin
        wait ((chip0_halted == 8'hFF) && (chip1_halted == 8'hFF));
      end
      begin
        repeat (600) @(posedge clk);
        $display("ERROR: Timeout waiting for cluster ICU_HALT!");
      end
    join_any
    disable fork;

    repeat (2) @(posedge clk);

    out_fd = $fopen("rtl_execution_trace.json", "w");
    $fwrite(out_fd, "{\n");
    $fwrite(out_fd, "  \"total_exec_cycles\": %0d,\n", total_exec_cycles);
    $fwrite(out_fd, "  \"chip0_halted_mask\": %0d,\n", chip0_halted);
    $fwrite(out_fd, "  \"chip1_halted_mask\": %0d,\n", chip1_halted);
    $fwrite(out_fd, "  \"cluster_collision_fault\": %0d,\n", cluster_coll_flt);
    $fwrite(out_fd, "  \"cluster_c2c_crc_err\": %0d,\n", cluster_crc_err);
    $fwrite(out_fd, "  \"chip0_deskew_events\": %0d,\n", c0_deskew_events);
    $fwrite(out_fd, "  \"chip1_deskew_events\": %0d,\n", c1_deskew_events);
    $fwrite(out_fd, "  \"chip0_c2c_flits_tx\": %0d,\n", c0_c2c_flits_tx);
    $fwrite(out_fd, "  \"chip1_c2c_flits_tx\": %0d,\n", c1_c2c_flits_tx);
    $fwrite(out_fd, "  \"chip0_measured_skew\": %0d,\n", c0_skew);
    $fwrite(out_fd, "  \"chip1_measured_skew\": %0d,\n", c1_skew);
    $fwrite(out_fd, "  \"chip0_gated_hops\": %0d,\n", c0_gated_hops);
    $fwrite(out_fd, "  \"chip1_gated_hops\": %0d,\n", c1_gated_hops);
    $fwrite(out_fd, "  \"ecc_single_bit_corrected_reads\": %0d,\n", ecc_corrected_count);
    $fwrite(out_fd, "  \"ecc_double_bit_errors\": %0d,\n", ecc_double_err_count);
    $fwrite(out_fd, "  \"stream_mismatch_vs_ecc_dut\": %0d,\n", stream_mismatch_vs_ecc_dut);
    $fwrite(out_fd, "  \"chip0_zero_skip_lanes\": %0d,\n", total_zero_skip_lanes);
    $fwrite(out_fd, "  \"chip0_zero_skip_macs\": %0d,\n", total_zero_skip_lanes * 16);
    $fwrite(out_fd, "  \"mul_gated_cycles\": %0d,\n", mul_gated_cycles);
    $fwrite(out_fd, "  \"lut_gated_cycles\": %0d,\n", lut_gated_cycles);
    $fwrite(out_fd, "  \"rtl_hex\": {\n");
    $fwrite(out_fd, "    \"stage_a_x_norm\": \"%032x\",\n", cap_stage_a_x_norm);
    $fwrite(out_fd, "    \"chip0_q_raw\": \"%032x\",\n", cap_c0_q_raw);
    $fwrite(out_fd, "    \"chip0_q_rope\": \"%032x\",\n", cap_c0_q_rope);
    $fwrite(out_fd, "    \"chip0_k_rope\": \"%032x\",\n", cap_c0_k_rope);
    $fwrite(out_fd, "    \"chip0_v_vec\": \"%032x\",\n", cap_c0_v_vec);
    $fwrite(out_fd, "    \"chip0_s_attn\": \"%032x\",\n", cap_c0_s_attn);
    $fwrite(out_fd, "    \"chip0_p_exp\": \"%032x\",\n", cap_c0_p_exp);
    $fwrite(out_fd, "    \"chip0_p_attn\": \"%032x\",\n", cap_c0_p_attn);
    $fwrite(out_fd, "    \"chip0_o_attn\": \"%032x\",\n", cap_c0_o_attn);
    $fwrite(out_fd, "    \"chip0_g_ffn\": \"%032x\",\n", cap_c0_g_ffn);
    $fwrite(out_fd, "    \"chip0_u_ffn\": \"%032x\",\n", cap_c0_u_ffn);
    $fwrite(out_fd, "    \"chip0_h_swiglu\": \"%032x\",\n", cap_c0_h_swiglu);
    $fwrite(out_fd, "    \"chip0_y_down\": \"%032x\",\n", cap_c0_y_down);
    $fwrite(out_fd, "    \"chip1_q_rope\": \"%032x\",\n", cap_c1_q_rope);
    $fwrite(out_fd, "    \"chip1_k_rope\": \"%032x\",\n", cap_c1_k_rope);
    $fwrite(out_fd, "    \"chip1_o_attn\": \"%032x\",\n", cap_c1_o_attn);
    $fwrite(out_fd, "    \"chip1_h_swiglu\": \"%032x\",\n", cap_c1_h_swiglu);
    $fwrite(out_fd, "    \"chip1_y_down\": \"%032x\",\n", cap_c1_y_down);
    $fwrite(out_fd, "    \"y_final_allreduce\": \"%032x\",\n", cap_c0_y_final_mem_e);
    $fwrite(out_fd, "    \"chip1_y_final_mem_e\": \"%032x\",\n", cap_c1_y_final_mem_e);
    $fwrite(out_fd, "    \"ecc_dut_y_final_mem_e\": \"%032x\"\n", cap_ecc_dut_y_final_mem_e);
    $fwrite(out_fd, "  }\n}\n");
    $fclose(out_fd);
    $display("[RTL] Completed 2-Chip LLM Token Decode in %0d cycles (ECC corrected reads=%0d)", total_exec_cycles, ecc_corrected_count);
    $finish;
  end

endmodule : tb_llm_inference_cluster
