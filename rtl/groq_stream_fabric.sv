// =============================================================================
// File: rtl/groq_stream_fabric.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Bidirectional East/West Spatial Stream Register Fabric.
//              - Propagates streams East (s -> s+1) and West (s -> s-1) at
//                exactly 1 spatial slice hop per clock cycle.
//              - Zero dynamic arbiters, zero FIFOs, zero backpressure stalls.
//              - Fine-grained valid-driven operand/clock gating: when a stream
//                slot is invalid (valid == 0), data flip-flops hold their prior
//                state with zero bit toggles.
//              - Hardware Spatial Write-Collision Detector (collision_fault_o)
//                verifies compiler schedule legality at runtime and in formal.
// =============================================================================
`include "groq_pkg.sv"

module groq_stream_fabric #(
 parameter int P_NUM_SLICES = groq_pkg::NUM_SLICES,
 parameter int P_NUM_EAST_STREAMS = groq_pkg::NUM_EAST_STREAMS,
 parameter int P_NUM_WEST_STREAMS = groq_pkg::NUM_WEST_STREAMS,
 parameter int P_STREAM_WIDTH = groq_pkg::STREAM_WIDTH
) (
 input logic clk,
 input logic rst_n,

 // ---------------------------------------------------------------------------
 // Eastward Stream Interface (Propagates Slice s -> Slice s+1, 1 hop/cycle)
 // ---------------------------------------------------------------------------
 input logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0] east_inject_en_i,
 input logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0] east_overwrite_allow_i,
 input logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0] east_consume_en_i,
 input logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] east_inject_data_i,

 output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0] stream_valid_east_o,
 output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] stream_data_east_o,
 output logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0] collision_fault_east_o,

 // ---------------------------------------------------------------------------
 // Westward Stream Interface (Propagates Slice s -> Slice s-1, 1 hop/cycle)
 // ---------------------------------------------------------------------------
 input logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0] west_inject_en_i,
 input logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0] west_overwrite_allow_i,
 input logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0] west_consume_en_i,
 input logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] west_inject_data_i,

 output logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0] stream_valid_west_o,
 output logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] stream_data_west_o,
 output logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0] collision_fault_west_o,

 // ---------------------------------------------------------------------------
 // Global Fault & Power-Gating Telemetry
 // ---------------------------------------------------------------------------
 output logic collision_fault_o,
 output logic collision_sticky_o,
 output logic [15:0] gated_hop_count_o
);

 // ---------------------------------------------------------------------------
 // Internal Stream Registers & Hop Link Signals
 // ---------------------------------------------------------------------------
 logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0] east_valid_q;
 logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] east_data_q;
 logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0] east_hop_valid;
 logic [P_NUM_SLICES-1:0][P_NUM_EAST_STREAMS-1:0][P_STREAM_WIDTH-1:0] east_hop_data;

 logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0] west_valid_q;
 logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] west_data_q;
 logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0] west_hop_valid;
 logic [P_NUM_SLICES-1:0][P_NUM_WEST_STREAMS-1:0][P_STREAM_WIDTH-1:0] west_hop_data;

  // ---------------------------------------------------------------------------
  // Combinational Hop Muxing & Spatial Write-Collision Detection
  // ---------------------------------------------------------------------------
  always_comb begin
    for (int s = 0; s < P_NUM_SLICES; s++) begin
      for (int c = 0; c < P_NUM_EAST_STREAMS; c++) begin
        stream_valid_east_o[s][c] = east_valid_q[s][c];
        stream_data_east_o[s][c]  = east_data_q[s][c];

        // Spatial write collision: slice s injects onto East stream c while an
        // unconsumed valid token is already present and overwrite is not allowed
        collision_fault_east_o[s][c] = east_inject_en_i[s][c] &
                                       east_valid_q[s][c] &
                                       ~east_consume_en_i[s][c] &
                                       ~east_overwrite_allow_i[s][c];

        // Outgoing Eastward link from slice s (feeds slice s+1 on next clock)
        east_hop_valid[s][c] = east_inject_en_i[s][c] |
                               (east_valid_q[s][c] & ~east_consume_en_i[s][c]);
        east_hop_data[s][c]  = east_inject_en_i[s][c] ?
                               east_inject_data_i[s][c] : east_data_q[s][c];
      end

      for (int c = 0; c < P_NUM_WEST_STREAMS; c++) begin
        stream_valid_west_o[s][c] = west_valid_q[s][c];
        stream_data_west_o[s][c]  = west_data_q[s][c];

        // Spatial write collision on Westward stream c at slice s
        collision_fault_west_o[s][c] = west_inject_en_i[s][c] &
                                       west_valid_q[s][c] &
                                       ~west_consume_en_i[s][c] &
                                       ~west_overwrite_allow_i[s][c];

        // Outgoing Westward link from slice s (feeds slice s-1 on next clock)
        west_hop_valid[s][c] = west_inject_en_i[s][c] |
                               (west_valid_q[s][c] & ~west_consume_en_i[s][c]);
        west_hop_data[s][c]  = west_inject_en_i[s][c] ?
                               west_inject_data_i[s][c] : west_data_q[s][c];
      end
    end
  end

  assign collision_fault_o = (|collision_fault_east_o) | (|collision_fault_west_o);

  // ---------------------------------------------------------------------------
  // 1-Hop/Cycle Spatial Shift Registers with Fine-Grained Valid Clock Gating
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      east_valid_q       <= '0;
      west_valid_q       <= '0;
      for (int s = 0; s < P_NUM_SLICES; s++) begin
        for (int c = 0; c < P_NUM_EAST_STREAMS; c++) east_data_q[s][c] <= '0;
        for (int c = 0; c < P_NUM_WEST_STREAMS; c++) west_data_q[s][c] <= '0;
      end
      collision_sticky_o <= 1'b0;
      gated_hop_count_o  <= 16'd0;
    end else begin
      if (collision_fault_o) begin
        collision_sticky_o <= 1'b1;
      end

      // Boundary slice 0 East ingress (West edge origin)
      for (int c = 0; c < P_NUM_EAST_STREAMS; c++) begin
        east_valid_q[0][c] <= 1'b0;
        // east_data_q[0][c] holds value (clock gated when valid == 0)
      end

      // Eastward propagation: slice s-1 -> slice s (1 slice hop per cycle)
      for (int s = 1; s < P_NUM_SLICES; s++) begin
        for (int c = 0; c < P_NUM_EAST_STREAMS; c++) begin
          east_valid_q[s][c] <= east_hop_valid[s-1][c];
          if (east_hop_valid[s-1][c]) begin
            east_data_q[s][c] <= east_hop_data[s-1][c];
          end
        end
      end

      // Boundary slice P_NUM_SLICES-1 West ingress (East edge origin)
      for (int c = 0; c < P_NUM_WEST_STREAMS; c++) begin
        west_valid_q[P_NUM_SLICES-1][c] <= 1'b0;
      end

      // Westward propagation: slice s+1 -> slice s (1 slice hop per cycle)
      for (int s = 0; s < P_NUM_SLICES - 1; s++) begin
        for (int c = 0; c < P_NUM_WEST_STREAMS; c++) begin
          west_valid_q[s][c] <= west_hop_valid[s+1][c];
          if (west_hop_valid[s+1][c]) begin
            west_data_q[s][c] <= west_hop_data[s+1][c];
          end
        end
      end

      // Count gated idle channel-0 hops for dynamic energy telemetry
      if (!east_hop_valid[0][0]) begin
        gated_hop_count_o <= gated_hop_count_o + 16'd1;
      end
    end
  end

`ifdef FORMAL
  /* verilator lint_off SYNCASYNCNET */
  // ---------------------------------------------------------------------------
  // Formal Verification Properties (Yosys 0.60 SAT / SMTBMC)
  // 1. Exact Spatial Arrival Time Theorem (1 hop/cycle for k = 1, 2, 3)
  // 2. Zero Toggle Power Gating Theorem (data registers stable when valid == 0)
  // 3. Spatial Write-Collision Detection Theorem
  // ---------------------------------------------------------------------------
  logic [3:0]                  f_cycle;
  logic [P_STREAM_WIDTH-1:0]   f_east_data_prev_s1;
  logic [P_STREAM_WIDTH-1:0]   f_west_data_prev_s1;
  logic                        f_east_hop_valid_prev_s0;
  logic                        f_west_hop_valid_prev_s2;

  // Shadow pipeline for k=1, 2, 3 hop exact arrival proof from slice 0 (East)
  logic                        f_e_v1, f_e_v2, f_e_v3;
  logic [P_STREAM_WIDTH-1:0]   f_e_d1, f_e_d2, f_e_d3;

  // Shadow pipeline for k=1, 2 hop exact arrival proof from slice 3 (West)
  logic                        f_w_v1, f_w_v2;
  logic [P_STREAM_WIDTH-1:0]   f_w_d1, f_w_d2;

  initial begin
    f_cycle                  = 4'd0;
    f_east_data_prev_s1      = '0;
    f_west_data_prev_s1      = '0;
    f_east_hop_valid_prev_s0 = 1'b0;
    f_west_hop_valid_prev_s2 = 1'b0;
    f_e_v1 = 1'b0; f_e_v2 = 1'b0; f_e_v3 = 1'b0;
    f_e_d1 = '0;   f_e_d2 = '0;   f_e_d3 = '0;
    f_w_v1 = 1'b0; f_w_v2 = 1'b0;
    f_w_d1 = '0;   f_w_d2 = '0;
  end

  always @(*) begin
    if (f_cycle == 4'd0) begin
      assume(!rst_n);
    end else begin
      assume(rst_n);
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      f_cycle                  <= 4'd1;
      f_east_data_prev_s1      <= '0;
      f_west_data_prev_s1      <= '0;
      f_east_hop_valid_prev_s0 <= 1'b0;
      f_west_hop_valid_prev_s2 <= 1'b0;
      f_e_v1 <= 1'b0; f_e_v2 <= 1'b0; f_e_v3 <= 1'b0;
      f_e_d1 <= '0;   f_e_d2 <= '0;   f_e_d3 <= '0;
      f_w_v1 <= 1'b0; f_w_v2 <= 1'b0;
      f_w_d1 <= '0;   f_w_d2 <= '0;
    end else begin
      if (f_cycle < 4'd15) f_cycle <= f_cycle + 4'd1;

      f_east_data_prev_s1      <= stream_data_east_o[1][0];
      f_west_data_prev_s1      <= stream_data_west_o[1][0];
      f_east_hop_valid_prev_s0 <= east_hop_valid[0][0];
      f_west_hop_valid_prev_s2 <= west_hop_valid[2][0];

      // Track non-overwritten Eastward injection at s0=0, c=0 across k=1,2,3
      f_e_v1 <= east_inject_en_i[0][0];
      f_e_d1 <= east_inject_data_i[0][0];
      f_e_v2 <= f_e_v1 & ~east_inject_en_i[1][0] & ~east_consume_en_i[1][0];
      f_e_d2 <= f_e_d1;
      f_e_v3 <= f_e_v2 & ~east_inject_en_i[2][0] & ~east_consume_en_i[2][0];
      f_e_d3 <= f_e_d2;

      // Track non-overwritten Westward injection at s0=3, c=0 across k=1,2
      f_w_v1 <= west_inject_en_i[3][0];
      f_w_d1 <= west_inject_data_i[3][0];
      f_w_v2 <= f_w_v1 & ~west_inject_en_i[2][0] & ~west_consume_en_i[2][0];
      f_w_d2 <= f_w_d1;

      if (f_cycle >= 4'd2) begin
        // Theorem 1A: Exact Eastward Arrival at t0+1, t0+2, t0+3 (s0+1, s0+2, s0+3)
        if (f_e_v1) begin
          assert(stream_valid_east_o[1][0] == 1'b1);
          assert(stream_data_east_o[1][0]  == f_e_d1);
        end
        if (f_e_v2) begin
          assert(stream_valid_east_o[2][0] == 1'b1);
          assert(stream_data_east_o[2][0]  == f_e_d2);
        end
        if (f_e_v3) begin
          assert(stream_valid_east_o[3][0] == 1'b1);
          assert(stream_data_east_o[3][0]  == f_e_d3);
        end

        // Theorem 1B: Exact Westward Arrival at t0+1, t0+2 (s0-1, s0-2)
        if (f_w_v1) begin
          assert(stream_valid_west_o[2][0] == 1'b1);
          assert(stream_data_west_o[2][0]  == f_w_d1);
        end
        if (f_w_v2) begin
          assert(stream_valid_west_o[1][0] == 1'b1);
          assert(stream_data_west_o[1][0]  == f_w_d2);
        end

        // Theorem 2: Zero Toggle Power Gating when incoming slot is invalid
        if (!f_east_hop_valid_prev_s0) begin
          assert(stream_valid_east_o[1][0] == 1'b0);
          assert(stream_data_east_o[1][0]  == f_east_data_prev_s1);
        end
        if (!f_west_hop_valid_prev_s2) begin
          assert(stream_valid_west_o[1][0] == 1'b0);
          assert(stream_data_west_o[1][0]  == f_west_data_prev_s1);
        end

        // Theorem 3: Deterministic Write-Collision Detection
        if (east_inject_en_i[1][0] && stream_valid_east_o[1][0] &&
            !east_consume_en_i[1][0] && !east_overwrite_allow_i[1][0]) begin
          assert(collision_fault_east_o[1][0] == 1'b1);
          assert(collision_fault_o == 1'b1);
        end
        if (west_inject_en_i[1][0] && stream_valid_west_o[1][0] &&
            !west_consume_en_i[1][0] && !west_overwrite_allow_i[1][0]) begin
          assert(collision_fault_west_o[1][0] == 1'b1);
          assert(collision_fault_o == 1'b1);
        end
      end
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule : groq_stream_fabric
