`timescale 1ns/1ps
module tb_stage11_mxfp8_nvfp4_dot;
  logic         clk;
  logic         rst_n;
  logic         valid_i;
  logic [2:0]   mode_i;
  logic         zero_skip_en_i;
  logic         accum_en_i;
  logic         accum_clear_i;
  logic [7:0]   act_scale_e8m0_i;
  logic [7:0]   wt_scale_e8m0_i;
  logic [127:0] act_stream_i;
  logic [127:0] wt_stream_i;

  logic               valid_o;
  logic signed [31:0] unaccum_dot_o;
  logic signed [31:0] dot_accum_o;
  logic [31:0]        dot_fp32_o;
  logic [5:0]         zero_skip_lanes_o;
  logic               block_zero_skipped_o;
  logic               nan_inf_flag_o;

  always #2.5 clk = ~clk;

  groq_mxfp8_nvfp4_dot_engine #(.P_LANES(16)) dut (.*);

  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic check_cond(input bit cond, input string msg);
    if (cond) pass_cnt++;
    else begin
      fail_cnt++;
      $display("FAIL: %s", msg);
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    valid_i          = 1'b0;
    mode_i           = 3'd0;
    zero_skip_en_i   = 1'b1;
    accum_en_i       = 1'b0;
    accum_clear_i    = 1'b1;
    act_scale_e8m0_i = 8'd127;
    wt_scale_e8m0_i  = 8'd127;
    act_stream_i     = '0;
    wt_stream_i      = '0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;

    // Test 1: MODE_NVFP4_E2M1 (32x 4-bit E2M1: 32 lanes of +6.0 * +6.0 -> 32 * 144 = 4608)
    valid_i          = 1'b1;
    mode_i           = 3'd3; // MODE_NVFP4_E2M1
    accum_clear_i    = 1'b0;
    act_scale_e8m0_i = 8'd127;
    wt_scale_e8m0_i  = 8'd127;
    act_stream_i     = {32{4'b0111}}; // +6.0 in all 32 sub-lanes
    wt_stream_i      = {32{4'b0111}}; // +6.0 in all 32 sub-lanes
    @(posedge clk);
    #1;
    // Test 2: Sign-flipped NVFP4 (-6.0 * +6.0 -> -4608)
    act_stream_i     = {32{4'b1111}}; // -6.0 in all 32 sub-lanes
    @(posedge clk);
    #1;
    check_cond(valid_o == 1'b1, "NVFP4 valid_o");
    check_cond(unaccum_dot_o == 32'sd4608, "NVFP4 +6.0*+6.0*32 == 4608");
    check_cond(zero_skip_lanes_o == 6'd0, "NVFP4 zero_skip_lanes_o == 0");

    // Test 3: Block-Scale Zero Gate (act_scale_e8m0_i == 0x00)
    act_scale_e8m0_i = 8'h00;
    @(posedge clk);
    #1;
    check_cond(unaccum_dot_o == -32'sd4608, "NVFP4 sign-symmetry -4608");

    // Test 4: MODE_MXFP8_E4M3 with NaN (0x7F)
    act_scale_e8m0_i = 8'd127;
    mode_i           = 3'd1; // MODE_MXFP8_E4M3
    act_stream_i     = {120'd0, 8'h7F}; // NaN in lane 0
    wt_stream_i      = {16{8'h38}};     // 1.0 in E4M3
    @(posedge clk);
    #1;
    check_cond(block_zero_skipped_o == 1'b1, "Block zero skip flag");
    check_cond(unaccum_dot_o == 32'sd0, "Block zero skip unaccum_dot == 0");
    check_cond(zero_skip_lanes_o == 6'd32, "Block zero skip 32 lanes");

    // Test 5: MODE_W4A8_MIXED (16x E4M3 act * 16x E2M1 wt)
    mode_i           = 3'd4; // MODE_W4A8_MIXED
    act_stream_i     = {16{8'h38}}; // E4M3 exp=7, mant=0 -> sig=8, ee=7
    wt_stream_i      = {16{8'h22}}; // E2M1 nib=0010 -> mag_2x=2
    @(posedge clk);
    #1;
    check_cond(nan_inf_flag_o == 1'b1, "MXFP8_E4M3 NaN flag");
    check_cond(dot_fp32_o == 32'h7FC0_0000, "MXFP8_E4M3 FP32 Canonical QNaN");

    @(posedge clk);
    #1;
    check_cond(valid_o == 1'b1 && unaccum_dot_o > 32'sd0 && dot_accum_o == unaccum_dot_o, "W4A8_MIXED positive output & accum");
    $display("STAGE 11 SIM SUMMARY: PASS=%0d FAIL=%0d", pass_cnt, fail_cnt);
    $finish;
  end
endmodule
