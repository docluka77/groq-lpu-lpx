// =============================================================================
// File: formal/tb_stage23_c2c_kv_quant.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 23 Self-Checking Testbench for groq_c2c_kv_quant_rx_engine
//              Verifies all 4 quantization modes (BF16->MXFP8, FP16->MXFP8,
//              BF16->NVFP4, RAW128 Bypass), zero/NaN/Inf handling, E_max tree,
//              and 1,000 randomized + directed KV-cache disaggregation beats.
// =============================================================================
`timescale 1ns/1ps

module tb_stage23_c2c_kv_quant;

  logic         clk;
  logic         rst_n;
  logic         valid_i;
  logic [1:0]   quant_mode_i;
  logic [127:0] kv_in_lo_i;
  logic [127:0] kv_in_hi_i;
  logic [1:0]   target_sram_bank_i;
  logic [15:0]  target_sram_addr_i;

  logic         valid_o;
  logic [127:0] quant_vec_o;
  logic [7:0]   scale_e8m0_o;
  logic         sram_wr_en_o;
  logic [1:0]   sram_wr_bank_o;
  logic [15:0]  sram_wr_addr_o;
  logic [4:0]   zero_lanes_cnt_o;
  logic         nan_inf_clamped_o;
  logic [1:0]   compression_ratio_code_o;

  groq_c2c_kv_quant_rx_engine dut (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .valid_i                  (valid_i),
    .quant_mode_i             (quant_mode_i),
    .kv_in_lo_i               (kv_in_lo_i),
    .kv_in_hi_i               (kv_in_hi_i),
    .target_sram_bank_i       (target_sram_bank_i),
    .target_sram_addr_i       (target_sram_addr_i),
    .valid_o                  (valid_o),
    .quant_vec_o              (quant_vec_o),
    .scale_e8m0_o             (scale_e8m0_o),
    .sram_wr_en_o             (sram_wr_en_o),
    .sram_wr_bank_o           (sram_wr_bank_o),
    .sram_wr_addr_o           (sram_wr_addr_o),
    .zero_lanes_cnt_o         (zero_lanes_cnt_o),
    .nan_inf_clamped_o        (nan_inf_clamped_o),
    .compression_ratio_code_o (compression_ratio_code_o)
  );

  initial clk = 1'b0;
  always #2.5 clk = ~clk;

  // Golden reference model function
  function automatic void compute_golden(
    input  logic [1:0]   mode,
    input  logic [127:0] lo,
    input  logic [127:0] hi,
    output logic [127:0] exp_vec,
    output logic [7:0]   exp_scale,
    output logic [4:0]   exp_zeros,
    output logic         exp_clamped,
    output logic [1:0]   exp_comp_code
  );
    logic [255:0] full_in;
    logic         sgn     [0:15];
    logic [7:0]   e8      [0:15];
    logic [6:0]   f7      [0:15];
    logic         is_z    [0:15];
    logic         is_ni   [0:15];
    logic         any_fnz;
    logic [7:0]   emax;
    logic [7:0]   rexp;
    logic [127:0] mxfp8_v;
    logic [63:0]  nvfp4_v;

    full_in     = {hi, lo};
    any_fnz     = 1'b0;
    emax        = 8'd0;
    exp_zeros   = 5'd0;
    exp_clamped = 1'b0;

    for (int i = 0; i < 16; i++) begin
      logic [15:0] w;
      w      = full_in[i*16 +: 16];
      sgn[i] = w[15];
      if (mode == 2'd1) begin
        if (w[14:10] == 5'd0)       e8[i] = 8'd0;
        else if (w[14:10] == 5'd31) e8[i] = 8'd255;
        else                        e8[i] = {3'd0, w[14:10]} + 8'd112;
        f7[i] = w[9:3];
      end else begin
        e8[i] = w[14:7];
        f7[i] = w[6:0];
      end
      is_z[i]  = (e8[i] == 8'd0);
      is_ni[i] = (e8[i] == 8'd255);
      if (is_z[i]) exp_zeros = exp_zeros + 5'd1;
      if (is_ni[i] && (mode != 2'd3)) exp_clamped = 1'b1;
      if (!is_z[i] && !is_ni[i]) begin
        any_fnz = 1'b1;
        if (e8[i] > emax) emax = e8[i];
      end
    end
    if (!any_fnz) emax = 8'd127;

    if (mode == 2'd0 || mode == 2'd1) begin
      exp_scale     = (emax > 8'd7) ? (emax - 8'd7) : 8'd0;
      exp_comp_code = 2'd2;
    end else if (mode == 2'd2) begin
      exp_scale     = (emax > 8'd2) ? (emax - 8'd2) : 8'd0;
      exp_comp_code = 2'd3;
    end else begin
      exp_scale     = 8'd127;
      exp_comp_code = 2'd1;
    end

    for (int i = 0; i < 16; i++) begin
      rexp = e8[i] - exp_scale;
      if (is_z[i])                 mxfp8_v[i*8 +: 8] = {sgn[i], 7'd0};
      else if (is_ni[i])           mxfp8_v[i*8 +: 8] = {sgn[i], 4'd14, 3'd7};
      else if (e8[i] <= exp_scale) mxfp8_v[i*8 +: 8] = {sgn[i], 7'd0};
      else if (rexp >= 8'd14)      mxfp8_v[i*8 +: 8] = {sgn[i], 4'd14, 3'd7};
      else                         mxfp8_v[i*8 +: 8] = {sgn[i], rexp[3:0], f7[i][6:4]};

      if (is_z[i])                 nvfp4_v[i*4 +: 4] = {sgn[i], 3'd0};
      else if (is_ni[i])           nvfp4_v[i*4 +: 4] = {sgn[i], 2'd3, 1'b1};
      else if (e8[i] <= exp_scale) nvfp4_v[i*4 +: 4] = {sgn[i], 3'd0};
      else if (rexp >= 8'd3)       nvfp4_v[i*4 +: 4] = {sgn[i], 2'd3, 1'b1};
      else                         nvfp4_v[i*4 +: 4] = {sgn[i], rexp[1:0], f7[i][6]};
    end

    if (mode == 2'd0 || mode == 2'd1) exp_vec = mxfp8_v;
    else if (mode == 2'd2)            exp_vec = {nvfp4_v, nvfp4_v};
    else                              exp_vec = lo;
  endfunction

  int err_cnt = 0;
  int test_cnt = 0;

  task automatic run_beat(
    input logic [1:0]   mode,
    input logic [127:0] lo,
    input logic [127:0] hi,
    input logic [1:0]   bank,
    input logic [15:0]  addr
  );
    logic [127:0] exp_vec;
    logic [7:0]   exp_scale;
    logic [4:0]   exp_zeros;
    logic         exp_clamped;
    logic [1:0]   exp_comp;

    compute_golden(mode, lo, hi, exp_vec, exp_scale, exp_zeros, exp_clamped, exp_comp);

    @(negedge clk);
    valid_i            = 1'b1;
    quant_mode_i       = mode;
    kv_in_lo_i         = lo;
    kv_in_hi_i         = hi;
    target_sram_bank_i = bank;
    target_sram_addr_i = addr;

    @(posedge clk);
    #1;
    test_cnt++;
    if (valid_o !== 1'b1 || sram_wr_en_o !== 1'b1 ||
        sram_wr_bank_o !== bank || sram_wr_addr_o !== addr ||
        quant_vec_o !== exp_vec || scale_e8m0_o !== exp_scale ||
        zero_lanes_cnt_o !== exp_zeros || nan_inf_clamped_o !== exp_clamped ||
        compression_ratio_code_o !== exp_comp) begin
      $display("[ERROR] Test %0d mode=%0d got vec=%h scale=%0d zeros=%0d clamp=%b comp=%0d | exp vec=%h scale=%0d zeros=%0d clamp=%b comp=%0d",
               test_cnt, mode, quant_vec_o, scale_e8m0_o, zero_lanes_cnt_o, nan_inf_clamped_o, compression_ratio_code_o,
               exp_vec, exp_scale, exp_zeros, exp_clamped, exp_comp);
      err_cnt++;
    end
  endtask

  logic [63:0] lfsr = 64'hCAFE_BABE_1337_BEEF;
  function automatic logic [63:0] next_rand();
    lfsr = {lfsr[62:0], lfsr[63] ^ lfsr[61] ^ lfsr[60] ^ lfsr[58]};
    return lfsr;
  endfunction

  initial begin
    rst_n = 1'b0; valid_i = 1'b0; quant_mode_i = 2'd0;
    kv_in_lo_i = '0; kv_in_hi_i = '0;
    target_sram_bank_i = 2'd0; target_sram_addr_i = 16'd0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    // 1. All-zero vectors across all 4 modes
    for (int m = 0; m < 4; m++) begin
      run_beat(m[1:0], 128'd0, 128'd0, m[1:0], 16'h1000 + 16'(m));
    end
    // 2. All-NaN/Inf vectors across all 4 modes
    for (int m = 0; m < 4; m++) begin
      run_beat(m[1:0], {8{16'h7F80}}, {8{16'hFF80}}, m[1:0], 16'h2000 + 16'(m));
    end
    // 3. 1,000 pseudo-random vectors across all 4 modes
    for (int t = 0; t < 1000; t++) begin
      logic [127:0] r_lo, r_hi;
      r_lo = {next_rand(), next_rand()};
      r_hi = {next_rand(), next_rand()};
      run_beat(t[1:0], r_lo, r_hi, t[1:0], 16'(t));
    end

    $display("STAGE 23 C2C KV QUANT SIM COMPLETE: %0d beats verified, %0d errors (0 errors expected)", test_cnt, err_cnt);
    if (err_cnt == 0) $display("PASS: ALL STAGE 23 TESTS PASSED (0 ERRORS)");
    else $fatal(1, "STAGE 23 FAILED");
    $finish;
  end

endmodule
