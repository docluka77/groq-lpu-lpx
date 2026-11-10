// =============================================================================
// File: compiler/tb_compiler_rtl_cosim.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 15 Verilator 5.054 RTL Co-Simulation Testbench executing
//              compiler-generated 144-bit VLIW schedules (W1, W2, W3) on
//              groq_lpu_cluster_top (2 x 8-Slice groq_lpu_top + Dragonfly C2C)
//              and dumping post-execution SRAM results for bit-exact check.
// =============================================================================
`ifndef TB_COMPILER_RTL_COSIM_SV
`define TB_COMPILER_RTL_COSIM_SV

`include "groq_pkg.sv"
`include "w1_rom.svh"
`include "w2_rom.svh"
`include "w3_rom.svh"

module tb_compiler_rtl_cosim;
  import groq_pkg::*;

  logic                                       clk;
  logic                                       rst_n;
  logic                                       chip0_icu_enable;
  logic [7:0][143:0]                          chip0_imem_vliw_bundle;
  logic [7:0][15:0]                           chip0_pc_slice;
  logic [7:0]                                 chip0_slice_halted;

  logic                                       chip1_icu_enable;
  logic [7:0][143:0]                          chip1_imem_vliw_bundle;
  logic [7:0][15:0]                           chip1_pc_slice;
  logic [7:0]                                 chip1_slice_halted;

  logic                                       chip0_host_mem_w_wr_en;
  logic [1:0]                                 chip0_host_mem_w_bank;
  logic [9:0]                                 chip0_host_mem_w_addr;
  logic [127:0]                               chip0_host_mem_w_data;

  logic                                       chip1_host_mem_w_wr_en;
  logic [1:0]                                 chip1_host_mem_w_bank;
  logic [9:0]                                 chip1_host_mem_w_addr;
  logic [127:0]                               chip1_host_mem_w_data;

  logic                                       chip0_host_mem_e_wr_en;
  logic [1:0]                                 chip0_host_mem_e_bank;
  logic [9:0]                                 chip0_host_mem_e_addr;
  logic [127:0]                               chip0_host_mem_e_data;

  logic                                       chip1_host_mem_e_wr_en;
  logic [1:0]                                 chip1_host_mem_e_bank;
  logic [9:0]                                 chip1_host_mem_e_addr;
  logic [127:0]                               chip1_host_mem_e_data;

  logic [1:0]                                 c2c_link_delay_sel;
  logic [15:0]                                expected_flight_cycles;
  logic                                       chip1_realsync_adj_en;
  logic signed [15:0]                         chip1_realsync_adj_val;

  logic [7:0][15:0]                           chip0_stream_valid_east;
  logic [7:0][15:0][127:0]                    chip0_stream_data_east;
  logic [7:0][15:0]                           chip1_stream_valid_east;
  logic [7:0][15:0][127:0]                    chip1_stream_data_east;

  logic                                       chip0_c2c_tx_valid;
  logic                                       chip1_c2c_tx_valid;
  logic                                       chip0_deskew_release_valid;
  logic                                       chip1_deskew_release_valid;
  logic signed [15:0]                         chip0_measured_skew;
  logic signed [15:0]                         chip1_measured_skew;
  logic                                       cluster_collision_fault;
  logic                                       cluster_c2c_crc_err;
  logic [15:0]                                chip0_gated_hop_count;
  logic [15:0]                                chip1_gated_hop_count;

  int unsigned total_rtl_cycles = 0;
  int unsigned runtime_faults   = 0;

  // Clock generation (1 GHz equivalent)
  initial begin
    clk = 1'b0;
    forever #500ps clk = ~clk;
  end

  groq_lpu_cluster_top u_dut (
    .clk                          (clk),
    .rst_n                        (rst_n),
    .chip0_icu_enable_i           (chip0_icu_enable),
    .chip0_imem_vliw_bundle_i     (chip0_imem_vliw_bundle),
    .chip0_pc_slice_o             (chip0_pc_slice),
    .chip0_slice_halted_o         (chip0_slice_halted),
    .chip1_icu_enable_i           (chip1_icu_enable),
    .chip1_imem_vliw_bundle_i     (chip1_imem_vliw_bundle),
    .chip1_pc_slice_o             (chip1_pc_slice),
    .chip1_slice_halted_o         (chip1_slice_halted),
    .chip0_host_mem_w_wr_en_i     (chip0_host_mem_w_wr_en),
    .chip0_host_mem_w_bank_i      (chip0_host_mem_w_bank),
    .chip0_host_mem_w_addr_i      (chip0_host_mem_w_addr),
    .chip0_host_mem_w_data_i      (chip0_host_mem_w_data),
    .chip1_host_mem_w_wr_en_i     (chip1_host_mem_w_wr_en),
    .chip1_host_mem_w_bank_i      (chip1_host_mem_w_bank),
    .chip1_host_mem_w_addr_i      (chip1_host_mem_w_addr),
    .chip1_host_mem_w_data_i      (chip1_host_mem_w_data),
    .chip0_host_mem_e_wr_en_i     (chip0_host_mem_e_wr_en),
    .chip0_host_mem_e_bank_i      (chip0_host_mem_e_bank),
    .chip0_host_mem_e_addr_i      (chip0_host_mem_e_addr),
    .chip0_host_mem_e_data_i      (chip0_host_mem_e_data),
    .chip1_host_mem_e_wr_en_i     (chip1_host_mem_e_wr_en),
    .chip1_host_mem_e_bank_i      (chip1_host_mem_e_bank),
    .chip1_host_mem_e_addr_i      (chip1_host_mem_e_addr),
    .chip1_host_mem_e_data_i      (chip1_host_mem_e_data),
    .chip0_mem_err_inject_en_i    (1'b0),
    .chip0_mem_err_inject_mask_i  ('0),
    .chip1_mem_err_inject_en_i    (1'b0),
    .chip1_mem_err_inject_mask_i  ('0),
    .c2c_link_delay_sel_i         (c2c_link_delay_sel),
    .expected_flight_cycles_i     (expected_flight_cycles),
    .chip1_realsync_adj_en_i      (chip1_realsync_adj_en),
    .chip1_realsync_adj_val_i     (chip1_realsync_adj_val),
    .chip0_stream_valid_east_o    (chip0_stream_valid_east),
    .chip0_stream_data_east_o     (chip0_stream_data_east),
    .chip1_stream_valid_east_o    (chip1_stream_valid_east),
    .chip1_stream_data_east_o     (chip1_stream_data_east),
    .chip0_c2c_tx_valid_o         (chip0_c2c_tx_valid),
    .chip1_c2c_tx_valid_o         (chip1_c2c_tx_valid),
    .chip0_deskew_release_valid_o (chip0_deskew_release_valid),
    .chip1_deskew_release_valid_o (chip1_deskew_release_valid),
    .chip0_measured_skew_o        (chip0_measured_skew),
    .chip1_measured_skew_o        (chip1_measured_skew),
    .cluster_collision_fault_o    (cluster_collision_fault),
    .cluster_c2c_crc_err_o        (cluster_c2c_crc_err),
    .chip0_gated_hop_count_o      (chip0_gated_hop_count),
    .chip1_gated_hop_count_o      (chip1_gated_hop_count)
  );

  task step_clk();
    @(posedge clk);
    #1ps;
    total_rtl_cycles++;
    if (cluster_collision_fault || cluster_c2c_crc_err) begin
      $display("[RTL-COSIM-ERR] Cycle %0d hardware fault: collision=%0b crc_err=%0b",
               total_rtl_cycles, cluster_collision_fault, cluster_c2c_crc_err);
      runtime_faults++;
    end
  endtask

  task reset_and_preload();
    logic [127:0] vec0, vec1;
    groq_vliw_instr_t instr;

    rst_n                  = 1'b0;
    chip0_icu_enable       = 1'b0;
    chip1_icu_enable       = 1'b0;
    chip0_imem_vliw_bundle = '0;
    chip1_imem_vliw_bundle = '0;
    chip0_host_mem_w_wr_en = 1'b0;
    chip1_host_mem_w_wr_en = 1'b0;
    chip0_host_mem_e_wr_en = 1'b0;
    chip1_host_mem_e_wr_en = 1'b0;
    c2c_link_delay_sel     = 2'd0;
    expected_flight_cycles = 16'd5;
    chip1_realsync_adj_en  = 1'b0;
    chip1_realsync_adj_val = 16'sd0;
    repeat (5) @(posedge clk);
    #1ps;

    // Preload 4 banks x 16 rows on Chip 0 & Chip 1 West and East SRAMs while rst_n=1
    rst_n = 1'b1;
    step_clk();
    for (int b = 0; b < 4; b++) begin
      for (int a = 0; a < 16; a++) begin
        for (int l = 0; l < 16; l++) begin
          vec0[l*8 +: 8] = 8'(((b * 17 + a * 5 + l * 3 + 1) & 8'h3F) - 16);
          vec1[l*8 +: 8] = 8'(((b * 13 + a * 7 + l * 5 + 3) & 8'h3F) - 16);
        end
        chip0_host_mem_w_wr_en = 1'b1;
        chip0_host_mem_w_bank  = 2'(b);
        chip0_host_mem_w_addr  = 10'(a);
        chip0_host_mem_w_data  = vec0;
        chip0_host_mem_e_wr_en = 1'b1;
        chip0_host_mem_e_bank  = 2'(b);
        chip0_host_mem_e_addr  = 10'(a);
        chip0_host_mem_e_data  = vec0;

        chip1_host_mem_w_wr_en = 1'b1;
        chip1_host_mem_w_bank  = 2'(b);
        chip1_host_mem_w_addr  = 10'(a);
        chip1_host_mem_w_data  = vec1;
        chip1_host_mem_e_wr_en = 1'b1;
        chip1_host_mem_e_bank  = 2'(b);
        chip1_host_mem_e_addr  = 10'(a);
        chip1_host_mem_e_data  = vec1;
        step_clk();
      end
    end
    chip0_host_mem_w_wr_en = 1'b0;
    chip0_host_mem_e_wr_en = 1'b0;
    chip1_host_mem_w_wr_en = 1'b0;
    chip1_host_mem_e_wr_en = 1'b0;
    chip0_icu_enable       = 1'b1;
    chip1_icu_enable       = 1'b1;
    step_clk();

    // Stage 16x16 Weights from Bank 0 Rows 0..15 into MXM_W (Hop 4) & MXM_E (Hop 6)
    for (int r = 0; r < 16; r++) begin
      chip0_imem_vliw_bundle = '0;
      chip1_imem_vliw_bundle = '0;
      instr               = '0;
      instr.target_slice  = 4'(SLICE_MEM_W);
      instr.mem_op        = MEM_READ_EAST;
      instr.dst_stream    = 5'd0;
      instr.mem_base_addr = {6'd0, 10'(r)};
      chip0_imem_vliw_bundle[SLICE_MEM_W] = instr;
      chip1_imem_vliw_bundle[SLICE_MEM_W] = instr;
      step_clk();
      chip0_imem_vliw_bundle = '0;
      chip1_imem_vliw_bundle = '0;
      repeat (3) step_clk();

      instr               = '0;
      instr.target_slice  = 4'(SLICE_MXM_W);
      instr.mxm_op        = MXM_LOAD_WEIGHT_B0;
      instr.src_stream_b  = 5'd0;
      instr.imm16         = 16'(r);
      chip0_imem_vliw_bundle[SLICE_MXM_W] = instr;
      chip1_imem_vliw_bundle[SLICE_MXM_W] = instr;
      step_clk();
      chip0_imem_vliw_bundle = '0;
      chip1_imem_vliw_bundle = '0;
      step_clk();

      instr               = '0;
      instr.target_slice  = 4'(SLICE_MXM_E);
      instr.mxm_op        = MXM_LOAD_WEIGHT_B0;
      instr.src_stream_b  = 5'd0;
      instr.imm16         = 16'(r);
      chip0_imem_vliw_bundle[SLICE_MXM_E] = instr;
      chip1_imem_vliw_bundle[SLICE_MXM_E] = instr;
      step_clk();
      chip0_imem_vliw_bundle = '0;
      chip1_imem_vliw_bundle = '0;
      step_clk();
    end

    // Reset ICU RealSync counters cleanly while preserving SRAM & MXM weight buffers!
    // Wait: rst_n resets MXM weight buffers too, so instead of asserting rst_n,
    // we simply align Chip 1's RealSync counter with Chip 0 (both had identical cycle counts!).
  endtask

  task automatic readback_sram_row(
    input  int           chip,
    input  int           is_east,
    input  int           bank,
    input  int           addr,
    output logic [127:0] rdata
  );
    groq_vliw_instr_t instr;
    chip0_imem_vliw_bundle = '0;
    chip1_imem_vliw_bundle = '0;
    instr = '0;
    if (!is_east) begin
      // Read from SLICE_MEM_W (Hop 1) -> East Stream 0 -> arrives at Hop 2 (SLICE_SXM) after 2 cycles
      instr.target_slice  = 4'(SLICE_MEM_W);
      instr.mem_op        = MEM_READ_EAST;
      instr.dst_stream    = 5'd0;
      instr.dst_dir_west  = 1'b0;
      instr.mem_base_addr = {4'd0, 2'(bank), 10'(addr)};
      if (chip == 0) chip0_imem_vliw_bundle[SLICE_MEM_W] = instr;
      else           chip1_imem_vliw_bundle[SLICE_MEM_W] = instr;
      step_clk();
      chip0_imem_vliw_bundle = '0;
      chip1_imem_vliw_bundle = '0;
      step_clk();
      rdata = (chip == 0) ? chip0_stream_data_east[SLICE_SXM][0]
                          : chip1_stream_data_east[SLICE_SXM][0];
      repeat (6) step_clk(); // drain stream
    end else begin
      // Read from SLICE_MEM_E (Hop 7) -> West Stream 0 -> arrives at Hop 6 (SLICE_MXM_E) after 2 cycles
      instr.target_slice  = 4'(SLICE_MEM_E);
      instr.mem_op        = MEM_READ_WEST;
      instr.dst_stream    = 5'd0;
      instr.dst_dir_west  = 1'b1;
      instr.mem_base_addr = {4'd0, 2'(bank), 10'(addr)};
      if (chip == 0) chip0_imem_vliw_bundle[SLICE_MEM_E] = instr;
      else           chip1_imem_vliw_bundle[SLICE_MEM_E] = instr;
      step_clk();
      chip0_imem_vliw_bundle = '0;
      chip1_imem_vliw_bundle = '0;
      step_clk();
      rdata = (chip == 0) ? u_dut.u_lpu_chip0.stream_data_west_o[SLICE_MXM_E][0]
                          : u_dut.u_lpu_chip1.stream_data_west_o[SLICE_MXM_E][0];
      repeat (6) step_clk(); // drain stream
    end
  endtask

  initial begin
    int fd;
    logic [127:0] rvec;

    fd = $fopen("rtl_cosim_results.txt", "w");
    if (fd == 0) begin
      $display("[RTL-COSIM-FATAL] Failed to open rtl_cosim_results.txt");
      $finish(1);
    end

    // -------------------------------------------------------------------------
    // Workload 1: Multi-Stage Attention + RoPE + KV-Ring Cache Kernel
    // -------------------------------------------------------------------------
    reset_and_preload();
    for (int t = 0; t < W1_TOTAL_CYCLES - 1; t++) begin
      chip0_imem_vliw_bundle = W1_CHIP0_ROM[t];
      chip1_imem_vliw_bundle = '0;
      step_clk();
    end
    readback_sram_row(0, 1, 0, 8,  rvec); $fdisplay(fd, "W1_C0_E_B0_R8  %032x", rvec);
    readback_sram_row(0, 1, 1, 9,  rvec); $fdisplay(fd, "W1_C0_E_B1_R9  %032x", rvec);
    readback_sram_row(0, 0, 2, 10, rvec); $fdisplay(fd, "W1_C0_W_B2_R10 %032x", rvec);
    chip0_imem_vliw_bundle = W1_CHIP0_ROM[W1_TOTAL_CYCLES - 1];
    step_clk();
    if (chip0_slice_halted != 8'hFF) runtime_faults++;

    // -------------------------------------------------------------------------
    // Workload 2: Fused SwiGLU MLP + Dynamic FP8 Quant + Multi-Chip AllReduce
    // -------------------------------------------------------------------------
    reset_and_preload();
    for (int t = 0; t < W2_TOTAL_CYCLES - 1; t++) begin
      chip0_imem_vliw_bundle = W2_CHIP0_ROM[t];
      chip1_imem_vliw_bundle = W2_CHIP1_ROM[t];
      step_clk();
    end
    readback_sram_row(0, 1, 0, 11, rvec); $fdisplay(fd, "W2_C0_E_B0_R11 %032x", rvec);
    readback_sram_row(0, 0, 3, 12, rvec); $fdisplay(fd, "W2_C0_W_B3_R12 %032x", rvec);
    readback_sram_row(1, 1, 2, 12, rvec); $fdisplay(fd, "W2_C1_E_B2_R12 %032x", rvec);
    chip0_imem_vliw_bundle = W2_CHIP0_ROM[W2_TOTAL_CYCLES - 1];
    chip1_imem_vliw_bundle = W2_CHIP1_ROM[W2_TOTAL_CYCLES - 1];
    step_clk();
    if (chip0_slice_halted != 8'hFF || chip1_slice_halted != 8'hFF) runtime_faults++;

    // -------------------------------------------------------------------------
    // Workload 3: DeepSeek-V3/R1 MLA Latent Compression + Routed MoE Dispatch
    // -------------------------------------------------------------------------
    reset_and_preload();
    for (int t = 0; t < W3_TOTAL_CYCLES - 1; t++) begin
      chip0_imem_vliw_bundle = W3_CHIP0_ROM[t];
      chip1_imem_vliw_bundle = W3_CHIP1_ROM[t];
      step_clk();
    end
    readback_sram_row(0, 1, 2, 13, rvec); $fdisplay(fd, "W3_C0_E_B2_R13 %032x", rvec);
    readback_sram_row(0, 1, 3, 14, rvec); $fdisplay(fd, "W3_C0_E_B3_R14 %032x", rvec);
    readback_sram_row(1, 1, 3, 15, rvec); $fdisplay(fd, "W3_C1_E_B3_R15 %032x", rvec);
    chip0_imem_vliw_bundle = W3_CHIP0_ROM[W3_TOTAL_CYCLES - 1];
    chip1_imem_vliw_bundle = W3_CHIP1_ROM[W3_TOTAL_CYCLES - 1];
    step_clk();
    if (chip0_slice_halted != 8'hFF || chip1_slice_halted != 8'hFF) runtime_faults++;

    $fdisplay(fd, "RUNTIME_FAULTS %0d", runtime_faults);
    $fdisplay(fd, "TOTAL_RTL_CYCLES %0d", total_rtl_cycles);
    $fclose(fd);
    $display("[RTL-COSIM-DONE] total_rtl_cycles=%0d runtime_faults=%0d", total_rtl_cycles, runtime_faults);
    $finish;
  end
endmodule : tb_compiler_rtl_cosim
`endif // TB_COMPILER_RTL_COSIM_SV
