// =============================================================================
// File: formal/tb_stage13_dragonfly_8chip_smoke.sv
// Description: Stage 13 Verilator 5.054 8-Chip Dragonfly Group Scale-Out Cluster
//              Cycle-Accurate Smoke Verification Testbench.
// =============================================================================
/* verilator lint_off WIDTHCONCAT */
/* verilator lint_off UNUSEDSIGNAL */
`include "groq_pkg.sv"

module tb_stage13_dragonfly_8chip_smoke;
  import groq_pkg::*;

  localparam int P_NUM_CHIPS = 8;

  logic clk;
  logic rst_n;
  always #1 clk = ~clk;

  logic [15:0] global_cycle_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) global_cycle_q <= 16'd0;
    else        global_cycle_q <= global_cycle_q + 16'd1;
  end

  logic [P_NUM_CHIPS-1:0]                                   chip_icu_en;
  logic [P_NUM_CHIPS-1:0][NUM_SLICES-1:0][VLIW_INSTR_BITS-1:0] chip_vliw;
  logic [P_NUM_CHIPS-1:0][NUM_SLICES-1:0][15:0]             chip_pc;
  logic [P_NUM_CHIPS-1:0][NUM_SLICES-1:0]                   chip_halted;

  logic [2:0]              dma_target_chip;
  logic                    dma_bcast_all;
  logic                    dma_vliw_busy;
  logic                    dma_desc_valid, dma_desc_ready;
  logic [127:0]            dma_desc_data;
  logic                    dma_pay_valid,  dma_pay_ready;
  logic [STREAM_WIDTH-1:0] dma_pay_data;
  logic [15:0]             dma_pay_parity;
  logic                    dma_busy, dma_stall, dma_perr, dma_irq;
  logic [7:0]              dma_desc_cnt;
  logic [15:0]             dma_beats_cnt;

  logic [1:0]              route_mode;
  logic                    ring_west;
  logic [P_NUM_CHIPS-1:0]  congestion_mask;
  logic [2:0]              butterfly_stage;

  logic                    pcs_link_en, pcs_scram_en;
  logic                    pcs_ts1, pcs_ts2, pcs_dsk_done, pcs_retrain;
  logic [P_NUM_CHIPS-1:0]  link_delay_en;
  logic [15:0]             expected_flight;
  logic [P_NUM_CHIPS-1:0]  pcs_err_inj_en;
  logic [15:0]             pcs_err_inj_mask;

  logic                    all_halted, any_barrier;
  logic [P_NUM_CHIPS-1:0]  pcs_link_up, crc16_err, realsync_err, ecc_s_err, ecc_d_err;
  logic [P_NUM_CHIPS-1:0]  c2c_tx_valid, deskew_release;
  logic [P_NUM_CHIPS-1:0][2:0] routed_dst;
  logic [P_NUM_CHIPS-1:0][STREAM_WIDTH-1:0] nim_rx_data;

  groq_dragonfly_8chip_cluster u_dut (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .chip_icu_enable_i        (chip_icu_en),
    .chip_imem_vliw_bundle_i  (chip_vliw),
    .chip_pc_slice_o          (chip_pc),
    .chip_slice_halted_o      (chip_halted),
    .global_cycle_i           (global_cycle_q),
    .dma_target_chip_i        (dma_target_chip),
    .dma_bcast_all_chips_i    (dma_bcast_all),
    .dma_vliw_sram_busy_i     (dma_vliw_busy),
    .dma_desc_push_valid_i    (dma_desc_valid),
    .dma_desc_push_data_i     (dma_desc_data),
    .dma_desc_push_ready_o    (dma_desc_ready),
    .dma_payload_valid_i      (dma_pay_valid),
    .dma_payload_data_i       (dma_pay_data),
    .dma_payload_parity_i     (dma_pay_parity),
    .dma_payload_ready_o      (dma_pay_ready),
    .dma_busy_o               (dma_busy),
    .dma_window_stall_o       (dma_stall),
    .dma_parity_err_o         (dma_perr),
    .dma_done_irq_o           (dma_irq),
    .dma_completed_desc_cnt_o (dma_desc_cnt),
    .dma_beats_transferred_o  (dma_beats_cnt),
    .cluster_route_mode_i     (route_mode),
    .ring_dir_west_i          (ring_west),
    .congestion_mask_i        (congestion_mask),
    .butterfly_stage_i        (butterfly_stage),
    .pcs_link_enable_i        (pcs_link_en),
    .pcs_scramble_en_i        (pcs_scram_en),
    .pcs_rx_ts1_seen_i        (pcs_ts1),
    .pcs_rx_ts2_seen_i        (pcs_ts2),
    .pcs_deskew_done_i        (pcs_dsk_done),
    .pcs_retrain_req_i        (pcs_retrain),
    .link_delay_en_i          (link_delay_en),
    .expected_flight_cycles_i (expected_flight),
    .pcs_err_inject_en_i      (pcs_err_inj_en),
    .pcs_err_inject_mask_i    (pcs_err_inj_mask),
    .cluster_all_halted_o     (all_halted),
    .cluster_any_barrier_o    (any_barrier),
    .cluster_pcs_link_up_o    (pcs_link_up),
    .cluster_crc16_err_o      (crc16_err),
    .cluster_realsync_err_o   (realsync_err),
    .cluster_ecc_single_err_o (ecc_s_err),
    .cluster_ecc_double_err_o (ecc_d_err),
    .cluster_c2c_tx_valid_o   (c2c_tx_valid),
    .cluster_deskew_release_o (deskew_release),
    .cluster_routed_dst_o     (routed_dst),
    .cluster_nim_rx_data_o    (nim_rx_data)
  );

  task automatic step_cycle();
    @(posedge clk);
    #1;
  endtask

  function automatic logic [15:0] calc_parity16(input logic [127:0] d);
    logic [15:0] p;
    for (int i = 0; i < 16; i++) p[i] = ^d[i*8 +: 8];
    return p;
  endfunction

  task automatic dma_write_word(
    input logic        bcast,
    input logic [2:0]  tgt_chip,
    input logic [1:0]  dma_tgt,
    input logic [2:0]  slice_or_bank,
    input logic [15:0] base_addr,
    input logic [127:0] payload
  );
    dma_bcast_all   = bcast;
    dma_target_chip = tgt_chip;
    dma_desc_valid  = 1'b1;
    dma_desc_data   = {56'd0, 16'd0, 16'd0, 8'd1, 8'd1, base_addr, 3'd0, slice_or_bank, dma_tgt};
    step_cycle();
    dma_desc_valid  = 1'b0;
    step_cycle();
    dma_pay_valid   = 1'b1;
    dma_pay_data    = payload;
    dma_pay_parity  = calc_parity16(payload);
    step_cycle();
    dma_pay_valid   = 1'b0;
    step_cycle();
  endtask

  groq_vliw_instr_t instr;
  int err_cnt = 0;

  initial begin
    clk = 1'b0; rst_n = 1'b0;
    chip_icu_en = '0; chip_vliw = '0;
    dma_target_chip = '0; dma_bcast_all = 1'b0; dma_vliw_busy = 1'b0;
    dma_desc_valid = 1'b0; dma_desc_data = '0;
    dma_pay_valid = 1'b0; dma_pay_data = '0; dma_pay_parity = '0;
    route_mode = 2'b00; ring_west = 1'b0; congestion_mask = '0; butterfly_stage = 3'd1;
    pcs_link_en = 1'b0; pcs_scram_en = 1'b1;
    pcs_ts1 = 1'b0; pcs_ts2 = 1'b0; pcs_dsk_done = 1'b0; pcs_retrain = 1'b0;
    link_delay_en = 8'h00; expected_flight = 16'd2;
    pcs_err_inj_en = 8'h00; pcs_err_inj_mask = 16'h0000;

    repeat (4) step_cycle();
    rst_n = 1'b1;
    step_cycle();

    // 1. Host DMA Broadcast & Per-Chip Unicast Preload across all 8 Chips
    dma_write_word(1'b1, 3'd0, 2'b01, 3'd0, 16'd1, 128'h0101_0101_0101_0101_0101_0101_0101_0101);
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      dma_write_word(1'b0, 3'(c), 2'b01, 3'd0, 16'd0, {16{8'(c + 1)}});
    end
    if (dma_perr !== 1'b0 || dma_desc_cnt !== 8'd9) begin
      $display("ERR: DMA preload failed perr=%b cnt=%0d", dma_perr, dma_desc_cnt);
      err_cnt++;
    end

    // 2. PCS 64B/66B Link Training to LINK_ACTIVE across all 8 Chips
    pcs_link_en = 1'b1; step_cycle();
    pcs_ts1     = 1'b1; step_cycle();
    pcs_ts2     = 1'b1; step_cycle();
    pcs_dsk_done= 1'b1; step_cycle();
    step_cycle();
    if (pcs_link_up !== 8'hFF) begin
      $display("ERR: PCS link training failed pcs_link_up=%b", pcs_link_up);
      err_cnt++;
    end
    chip_icu_en = 8'hFF;

    // 3. Mode 00: Direct Crossbar 8-Chip Full-Mesh Transfer (dst = (c + 3) % 8)
    route_mode = 2'b00;
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      instr = '0; instr.target_slice = 4'(SLICE_MEM_W); instr.mem_op = MEM_READ_WEST;
      instr.dst_stream = 5'd0; instr.mem_base_addr = 16'd0;
      chip_vliw[c][SLICE_MEM_W] = instr;
    end
    step_cycle(); chip_vliw = '0; step_cycle();
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      instr = '0; instr.target_slice = 4'(SLICE_NIM); instr.nim_op = NIM_SEND;
      instr.src_stream_a = 5'b10000; instr.imm16 = {12'd0, 4'((c + 3) % 8)};
      chip_vliw[c][SLICE_NIM] = instr;
    end
    step_cycle(); chip_vliw = '0;
    #1;
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      if (routed_dst[c] !== 3'((c + 3) % 8) || nim_rx_data[(c + 3) % 8] !== {16{8'(c + 1)}}) begin
        $display("ERR: Crossbar chip %0d -> %0d rx=%h", c, routed_dst[c], nim_rx_data[(c+3)%8]);
        err_cnt++;
      end
    end
    repeat (3) step_cycle();

    // 4. Mode 01: 8-Chip Bidirectional Ring AllReduce (Eastward dst = (c + 1) % 8)
    route_mode = 2'b01; ring_west = 1'b0;
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      instr = '0; instr.target_slice = 4'(SLICE_MEM_W); instr.mem_op = MEM_READ_WEST;
      instr.dst_stream = 5'd0; instr.mem_base_addr = 16'd0;
      chip_vliw[c][SLICE_MEM_W] = instr;
    end
    step_cycle(); chip_vliw = '0; step_cycle();
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      instr = '0; instr.target_slice = 4'(SLICE_NIM); instr.nim_op = NIM_SEND;
      instr.src_stream_a = 5'b10000; instr.imm16 = {12'd0, 4'((c + 1) % 8)};
      chip_vliw[c][SLICE_NIM] = instr;
    end
    step_cycle(); chip_vliw = '0;
    #1;
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      if (routed_dst[c] !== 3'((c + 1) % 8) || nim_rx_data[(c + 1) % 8] !== {16{8'(c + 1)}}) begin
        $display("ERR: Ring chip %0d -> %0d rx=%h", c, routed_dst[c], nim_rx_data[(c+1)%8]);
        err_cnt++;
      end
    end
    repeat (3) step_cycle();

    // 5. Mode 10 (UGAL Adaptive under Congestion) & Mode 11 (MoE Butterfly AllToAll)
    route_mode = 2'b10; congestion_mask = 8'b0000_1111;
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      instr = '0; instr.target_slice = 4'(SLICE_MEM_W); instr.mem_op = MEM_READ_WEST;
      instr.dst_stream = 5'd0; instr.mem_base_addr = 16'd0;
      chip_vliw[c][SLICE_MEM_W] = instr;
    end
    step_cycle(); chip_vliw = '0; step_cycle();
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      instr = '0; instr.target_slice = 4'(SLICE_NIM); instr.nim_op = NIM_SEND;
      instr.src_stream_a = 5'b10000; instr.imm16 = {12'd0, 4'(c ^ 4)};
      chip_vliw[c][SLICE_NIM] = instr;
    end
    step_cycle(); chip_vliw = '0;
    for (int c = 0; c < P_NUM_CHIPS; c++) begin
      if (routed_dst[c] !== (3'(c) ^ 3'd4) || nim_rx_data[c ^ 4] !== {16{8'(c + 1)}}) err_cnt++;
    end
    repeat (3) step_cycle();

    // 6. Mode 11: MoE AllToAll Butterfly Permutation across stages 1, 2, 4
    route_mode = 2'b11; congestion_mask = 8'h00;
    for (int stg = 1; stg <= 4; stg *= 2) begin
      butterfly_stage = 3'(stg);
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        instr = '0; instr.target_slice = 4'(SLICE_MEM_W); instr.mem_op = MEM_READ_WEST;
        instr.dst_stream = 5'd0; instr.mem_base_addr = 16'd0;
        chip_vliw[c][SLICE_MEM_W] = instr;
      end
      step_cycle(); chip_vliw = '0; step_cycle();
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        instr = '0; instr.target_slice = 4'(SLICE_NIM); instr.nim_op = NIM_SEND;
        instr.src_stream_a = 5'b10000; instr.imm16 = {12'd0, 4'(c ^ stg)};
        chip_vliw[c][SLICE_NIM] = instr;
      end
      step_cycle(); chip_vliw = '0;
      for (int c = 0; c < P_NUM_CHIPS; c++) begin
        if (routed_dst[c] !== (3'(c) ^ 3'(stg)) || nim_rx_data[c ^ stg] !== {16{8'(c + 1)}}) err_cnt++;
      end
      repeat (3) step_cycle();
    end

    if (err_cnt == 0 && crc16_err == 8'h00 && realsync_err == 8'h00) begin
      $display("STAGE 13 8-CHIP DRAGONFLY CLUSTER SMOKE TEST PASSED: 0 ERRORS, link_up=%h dma_cnt=%0d",
               pcs_link_up, dma_desc_cnt);
      $finish(0);
    end else begin
      $display("STAGE 13 SMOKE TEST FAILED: err_cnt=%0d crc16=%h rs=%h", err_cnt, crc16_err, realsync_err);
      $finish(1);
    end
  end
endmodule
