// =============================================================================
// File: rtl/groq_nim_realsync.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Network Interface Module (NIM) & RealSync Plesiochronous Router
//              (ISCA 2022 TSP Scale-Out & Groq 3 LPX 640 TB/s C2C Interconnect)
//              - Plesiochronous RealSync Elastic Deskew Buffer:
//                Releases incoming C2C flits at exact target cycle
//                (release_cycle == tx_timestamp + expected_flight_cycles),
//                eliminating +-Delta_max plesiochronous link jitter/drift.
//              - High-Radix Dragonfly Deterministic & UGAL Router:
//                NIM_SEND (TX), NIM_RECV (RX), NIM_FORWARD (Transit Bypass),
//                NIM_REALSYNC_PING (Deskew Calibration), and
//                NIM_ALLREDUCE_ADD (In-Network 16-Lane Vector Summation).
//              - Hardware CRC-8 Link Integrity Generator & Checker (Poly 0x07).
// =============================================================================
`ifndef GROQ_NIM_REALSYNC_SV
`define GROQ_NIM_REALSYNC_SV

`include "groq_pkg.sv"

module groq_nim_realsync #(
  parameter int P_LANES        = groq_pkg::SUPERLANE_LANES, // 16 lanes
  parameter int P_ELEM_BITS    = groq_pkg::ELEM_BITS,       // 8-bit element
  parameter int P_STREAM_WIDTH = groq_pkg::STREAM_WIDTH,    // 128-bit superlane
  parameter int P_DESKEW_DEPTH = 4                          // 4-slot elastic deskew buffer
) (
  input  logic                        clk,
  input  logic                        rst_n,

  // VLIW NIM Control & RealSync Plesiochronous Timing Reference
  input  logic                        op_valid_i,
  input  logic [3:0]                  nim_op_i,
  input  logic [15:0]                 realsync_aligned_time_i,
  input  logic [15:0]                 expected_flight_cycles_i,

  // Dragonfly Topology Node & Routing Control
  input  logic [3:0]                  local_chip_id_i,
  input  logic [3:0]                  tx_dst_chip_i,
  input  logic                        ugal_nonminimal_en_i,
  input  logic                        link_congested_i,

  // Local Spatial Stream Interface (Hop 0 West Edge)
  input  logic                        local_stream_in_valid_i,
  input  logic [P_STREAM_WIDTH-1:0]   local_stream_in_data_i,
  output logic                        local_stream_out_valid_o,
  output logic [P_STREAM_WIDTH-1:0]   local_stream_out_data_o,

  // Incoming Chip-to-Chip (C2C) Plesiochronous Link Flit
  input  logic                        c2c_rx_valid_i,
  input  logic [P_STREAM_WIDTH-1:0]   c2c_rx_data_i,
  input  logic [15:0]                 c2c_rx_tx_timestamp_i,
  input  logic [3:0]                  c2c_rx_dst_chip_i,
  input  logic [7:0]                  c2c_rx_crc8_i,

  // Outgoing Chip-to-Chip (C2C) Link Flit & Dragonfly Port Select
  output logic                        c2c_tx_valid_o,
  output logic [P_STREAM_WIDTH-1:0]   c2c_tx_data_o,
  output logic [15:0]                 c2c_tx_timestamp_o,
  output logic [3:0]                  c2c_tx_dst_chip_o,
  output logic [7:0]                  c2c_tx_crc8_o,
  output logic [1:0]                  c2c_tx_port_sel_o,

  // RealSync Deskew & Link Integrity Telemetry
  output logic                        deskew_release_valid_o,
  output logic [15:0]                 deskew_released_target_cycle_o,
  output logic                        realsync_ping_ack_o,
  output logic signed [15:0]          measured_skew_o,
  output logic                        crc_err_o
);

  // Dragonfly Output Port Encodings
  localparam logic [1:0] PORT_LOCAL_MIN  = 2'd0; // Intra-group minimal electrical link
  localparam logic [1:0] PORT_GLOBAL_MIN = 2'd1; // Inter-group minimal optical link
  localparam logic [1:0] PORT_UGAL_PROXY = 2'd2; // Non-minimal Valiant/UGAL proxy link

  // ---------------------------------------------------------------------------
  // 1. Helper Functions: CRC-8 (0x07), In-Network All-Reduce & Dragonfly Route
  // ---------------------------------------------------------------------------
  function automatic logic [7:0] crc8_byte_step(
    input logic [7:0] crc_in,
    input logic [7:0] data_byte
  );
    logic [7:0] c;
    begin
      c = crc_in ^ data_byte;
      for (int b = 0; b < 8; b++) begin
        if (c[7]) c = (c << 1) ^ 8'h07;
        else      c = (c << 1);
      end
      crc8_byte_step = c;
    end
  endfunction

  function automatic logic [7:0] crc8_calc(
    input logic [P_STREAM_WIDTH-1:0] payload,
    input logic [15:0]               ts
  );
    logic [7:0] crc;
    begin
      crc = 8'hFF;
      for (int i = 0; i < P_LANES; i++) begin
        crc = crc8_byte_step(crc, payload[i*8 +: 8]);
      end
      crc = crc8_byte_step(crc, ts[7:0]);
      crc = crc8_byte_step(crc, ts[15:8]);
      crc8_calc = crc;
    end
  endfunction

  function automatic logic crc8_check(
    input logic [P_STREAM_WIDTH-1:0] payload,
    input logic [15:0]               ts,
    input logic [7:0]                rx_crc
  );
    begin
      crc8_check = (crc8_calc(payload, ts) != rx_crc);
    end
  endfunction

  function automatic logic signed [7:0] sat_add_int8(
    input logic signed [7:0] a,
    input logic signed [7:0] b
  );
    logic signed [15:0] s;
    begin
      s = {{8{a[7]}}, a} + {{8{b[7]}}, b};
      if (s > 16'sd127)       sat_add_int8 = 8'sd127;
      else if (s < -16'sd128) sat_add_int8 = -8'sd128;
      else                    sat_add_int8 = $signed(s[7:0]);
    end
  endfunction

  function automatic logic [P_STREAM_WIDTH-1:0] allreduce_vec_add(
    input logic [P_STREAM_WIDTH-1:0] vec_a,
    input logic [P_STREAM_WIDTH-1:0] vec_b
  );
    logic [P_STREAM_WIDTH-1:0] res;
    begin
      for (int i = 0; i < P_LANES; i++) begin
        res[i*P_ELEM_BITS +: P_ELEM_BITS] = sat_add_int8(
          $signed(vec_a[i*P_ELEM_BITS +: P_ELEM_BITS]),
          $signed(vec_b[i*P_ELEM_BITS +: P_ELEM_BITS])
        );
      end
      allreduce_vec_add = res;
    end
  endfunction

  function automatic logic [1:0] dragonfly_route(
    input logic [3:0] src_chip,
    input logic [3:0] dst_chip,
    input logic       ugal_en,
    input logic       congested
  );
    begin
      if (ugal_en && congested && (src_chip != dst_chip)) begin
        dragonfly_route = PORT_UGAL_PROXY;
      end else if (src_chip[3:2] != dst_chip[3:2]) begin
        dragonfly_route = PORT_GLOBAL_MIN;
      end else begin
        dragonfly_route = PORT_LOCAL_MIN;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // 2. Link CRC-8 Verification & Plesiochronous RealSync Elastic Deskew Buffer
  // ---------------------------------------------------------------------------
  logic rx_crc_err;
  assign rx_crc_err = c2c_rx_valid_i && crc8_check(c2c_rx_data_i, c2c_rx_tx_timestamp_i, c2c_rx_crc8_i);
  assign crc_err_o  = rx_crc_err;

  logic [P_DESKEW_DEPTH-1:0]       buf_valid;
  logic [P_STREAM_WIDTH-1:0]       buf_data         [0:P_DESKEW_DEPTH-1];
  logic [15:0]                     buf_target_cycle [0:P_DESKEW_DEPTH-1];
  logic [$clog2(P_DESKEW_DEPTH)-1:0] wr_ptr;

  logic                            slot_match_valid;
  logic [$clog2(P_DESKEW_DEPTH)-1:0] slot_match_idx;
  logic [P_STREAM_WIDTH-1:0]       deskew_released_data;
  logic [15:0]                     incoming_target_cycle;

  assign incoming_target_cycle = c2c_rx_tx_timestamp_i + expected_flight_cycles_i;

  // Search elastic deskew buffer for a flit whose target release cycle == realsync_aligned_time_i
  always_comb begin
    slot_match_valid               = 1'b0;
    slot_match_idx                 = '0;
    deskew_released_data           = '0;
    deskew_released_target_cycle_o = '0;
    for (int s = 0; s < P_DESKEW_DEPTH; s++) begin
      if (!slot_match_valid && buf_valid[s] && (buf_target_cycle[s] == realsync_aligned_time_i)) begin
        slot_match_valid               = 1'b1;
        slot_match_idx                 = s[$clog2(P_DESKEW_DEPTH)-1:0];
        deskew_released_data           = buf_data[s];
        deskew_released_target_cycle_o = buf_target_cycle[s];
      end
    end
  end

  assign deskew_release_valid_o = slot_match_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buf_valid <= '0;
      wr_ptr    <= '0;
      for (int s = 0; s < P_DESKEW_DEPTH; s++) begin
        buf_data[s]         <= '0;
        buf_target_cycle[s] <= '0;
      end
    end else begin
      // Release matched slot at exact scheduled cycle
      if (slot_match_valid) begin
        buf_valid[slot_match_idx] <= 1'b0;
      end
      // Enqueue valid error-free incoming C2C flit into elastic deskew buffer
      if (c2c_rx_valid_i && !rx_crc_err && !(op_valid_i && (nim_op_i == groq_pkg::NIM_FORWARD))) begin
        buf_valid[wr_ptr]        <= 1'b1;
        buf_data[wr_ptr]         <= c2c_rx_data_i;
        buf_target_cycle[wr_ptr] <= incoming_target_cycle;
        wr_ptr                   <= wr_ptr + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 3. Dragonfly High-Radix Router & In-Network All-Reduce Datapath
  // ---------------------------------------------------------------------------
  logic [P_STREAM_WIDTH-1:0] remote_allreduce_operand;
  logic [P_STREAM_WIDTH-1:0] allreduce_sum_comb;
  // BUG-LIT-003: ISCA 2022 Hardware-Aligned Counter (HAC) Consensus Deskew State
  logic [15:0]               hac_counter_q;
  logic                      hac_deskew_locked_q;

  assign remote_allreduce_operand = slot_match_valid ? deskew_released_data : c2c_rx_data_i;
  assign allreduce_sum_comb       = allreduce_vec_add(local_stream_in_data_i, remote_allreduce_operand);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      local_stream_out_valid_o <= 1'b0;
      local_stream_out_data_o  <= '0;
      c2c_tx_valid_o           <= 1'b0;
      c2c_tx_data_o            <= '0;
      c2c_tx_timestamp_o       <= '0;
      c2c_tx_dst_chip_o        <= '0;
      c2c_tx_crc8_o            <= '0;
      c2c_tx_port_sel_o        <= PORT_LOCAL_MIN;
      realsync_ping_ack_o      <= 1'b0;
      measured_skew_o          <= '0;
      hac_counter_q            <= 16'd0;
      hac_deskew_locked_q      <= 1'b0;
    end else begin
      local_stream_out_valid_o <= 1'b0;
      c2c_tx_valid_o           <= 1'b0;
      realsync_ping_ack_o      <= 1'b0;
      hac_counter_q            <= hac_counter_q + 16'd1;

      // Automatic local ejection when a deskewed flit reaches its exact target cycle
      if (slot_match_valid) begin
        local_stream_out_valid_o <= 1'b1;
        local_stream_out_data_o  <= deskew_released_data;
      end

      if (op_valid_i) begin
        unique case (nim_op_i)
          groq_pkg::NIM_NOP: begin
            // Idle or background deskew release handled above
          end
          groq_pkg::NIM_SEND: begin
            if (local_stream_in_valid_i) begin
              c2c_tx_valid_o     <= 1'b1;
              c2c_tx_data_o      <= local_stream_in_data_i;
              c2c_tx_timestamp_o <= realsync_aligned_time_i;
              c2c_tx_dst_chip_o  <= tx_dst_chip_i;
              c2c_tx_crc8_o      <= crc8_calc(local_stream_in_data_i, realsync_aligned_time_i);
              c2c_tx_port_sel_o  <= dragonfly_route(
                local_chip_id_i, tx_dst_chip_i, ugal_nonminimal_en_i, link_congested_i
              );
            end
          end
          groq_pkg::NIM_RECV: begin
            if (slot_match_valid) begin
              local_stream_out_valid_o <= 1'b1;
              local_stream_out_data_o  <= deskew_released_data;
            end
          end
          groq_pkg::NIM_REALSYNC_PING: begin
            if (c2c_rx_valid_i && !rx_crc_err) begin
              realsync_ping_ack_o <= 1'b1;
              measured_skew_o     <= $signed(realsync_aligned_time_i) - $signed(incoming_target_cycle);
            end
          end
          groq_pkg::NIM_DESKEW_CAL: begin
            if (c2c_rx_valid_i && !rx_crc_err) begin
              realsync_ping_ack_o <= 1'b1;
              measured_skew_o     <= $signed(realsync_aligned_time_i) - $signed(incoming_target_cycle);
              hac_counter_q       <= incoming_target_cycle + 16'd1;
              hac_deskew_locked_q <= 1'b1;
            end
          end
          groq_pkg::NIM_LOOPBACK: begin
            if (local_stream_in_valid_i) begin
              local_stream_out_valid_o <= 1'b1;
              local_stream_out_data_o  <= local_stream_in_data_i;
              c2c_tx_valid_o           <= 1'b1;
              c2c_tx_data_o            <= local_stream_in_data_i;
              c2c_tx_timestamp_o       <= realsync_aligned_time_i;
              c2c_tx_dst_chip_o        <= local_chip_id_i;
              c2c_tx_crc8_o            <= crc8_calc(local_stream_in_data_i, realsync_aligned_time_i);
              c2c_tx_port_sel_o        <= PORT_LOCAL_MIN;
            end
          end
          groq_pkg::NIM_FORWARD: begin
            if (c2c_rx_valid_i && !rx_crc_err) begin
              c2c_tx_valid_o     <= 1'b1;
              c2c_tx_data_o      <= c2c_rx_data_i;
              c2c_tx_timestamp_o <= realsync_aligned_time_i;
              c2c_tx_dst_chip_o  <= c2c_rx_dst_chip_i;
              c2c_tx_crc8_o      <= crc8_calc(c2c_rx_data_i, realsync_aligned_time_i);
              c2c_tx_port_sel_o  <= dragonfly_route(
                local_chip_id_i, c2c_rx_dst_chip_i, ugal_nonminimal_en_i, link_congested_i
              );
            end
          end
          groq_pkg::NIM_ALLREDUCE_ADD: begin
            if (local_stream_in_valid_i && (slot_match_valid || (c2c_rx_valid_i && !rx_crc_err))) begin
              local_stream_out_valid_o <= 1'b1;
              local_stream_out_data_o  <= allreduce_sum_comb;
              c2c_tx_valid_o           <= 1'b1;
              c2c_tx_data_o            <= allreduce_sum_comb;
              c2c_tx_timestamp_o       <= realsync_aligned_time_i;
              c2c_tx_dst_chip_o        <= tx_dst_chip_i;
              c2c_tx_crc8_o            <= crc8_calc(allreduce_sum_comb, realsync_aligned_time_i);
              c2c_tx_port_sel_o        <= dragonfly_route(
                local_chip_id_i, tx_dst_chip_i, ugal_nonminimal_en_i, link_congested_i
              );
            end
          end
          default: ;
        endcase
      end
    end
  end

  // ===========================================================================
  // 4. Formal Verification Proofs (Yosys 0.60 Bounded Model Check)
  // ===========================================================================
`ifdef FORMAL
  logic [7:0]  formal_tx_crc;
  logic        f_past_valid;
  logic        f_cal_hit_d1;
  logic [15:0] f_target_d1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_past_valid <= 1'b0;
      f_cal_hit_d1 <= 1'b0;
      f_target_d1  <= 16'd0;
    end else begin
      f_past_valid <= 1'b1;
      f_cal_hit_d1 <= op_valid_i && (nim_op_i == groq_pkg::NIM_DESKEW_CAL) && c2c_rx_valid_i && !rx_crc_err;
      f_target_d1  <= incoming_target_cycle;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && f_past_valid && f_cal_hit_d1) begin
      assert (hac_deskew_locked_q == 1'b1);
      assert (hac_counter_q == (f_target_d1 + 16'd1));
    end
  end

  always_comb begin
    // Proof 1: Exact RealSync Plesiochronous Deskew Release Invariant
    // A buffered flit is released ONLY when realsync_aligned_time_i == target_release_cycle
    if (deskew_release_valid_o) begin
      assert (realsync_aligned_time_i == deskew_released_target_cycle_o);
      assert (buf_valid[slot_match_idx] == 1'b1);
      assert (buf_target_cycle[slot_match_idx] == realsync_aligned_time_i);
    end

    // Proof 2: In-Network All-Reduce Vector Summation Commutativity
    // NIM_ALLREDUCE_ADD(a, b) == NIM_ALLREDUCE_ADD(b, a) across all 16 lanes
    assert (
      allreduce_vec_add(local_stream_in_data_i, remote_allreduce_operand) ==
      allreduce_vec_add(remote_allreduce_operand, local_stream_in_data_i)
    );

    // Proof 3: CRC-8 Zero-Error Pass & Corruption Detection Theorem
    formal_tx_crc = crc8_calc(local_stream_in_data_i, realsync_aligned_time_i);
    assert (crc8_check(local_stream_in_data_i, realsync_aligned_time_i, formal_tx_crc) == 1'b0);
    assert (crc8_check(local_stream_in_data_i, realsync_aligned_time_i, formal_tx_crc ^ 8'h01) == 1'b1);
    if (c2c_rx_valid_i && (c2c_rx_crc8_i == crc8_calc(c2c_rx_data_i, c2c_rx_tx_timestamp_i))) begin
      assert (crc_err_o == 1'b0);
    end

    // Proof 4: Dragonfly High-Radix Routing Determinism
    if (ugal_nonminimal_en_i && link_congested_i && (local_chip_id_i != tx_dst_chip_i)) begin
      assert (dragonfly_route(local_chip_id_i, tx_dst_chip_i, ugal_nonminimal_en_i, link_congested_i) == PORT_UGAL_PROXY);
    end else if (local_chip_id_i[3:2] != tx_dst_chip_i[3:2]) begin
      assert (dragonfly_route(local_chip_id_i, tx_dst_chip_i, ugal_nonminimal_en_i, link_congested_i) == PORT_GLOBAL_MIN);
    end else begin
      assert (dragonfly_route(local_chip_id_i, tx_dst_chip_i, ugal_nonminimal_en_i, link_congested_i) == PORT_LOCAL_MIN);
    end
  end
`endif

endmodule : groq_nim_realsync

`endif // GROQ_NIM_REALSYNC_SV
