// =============================================================================
// File: rtl/groq_sxm_slice.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Switch / Shift / Transpose / Permute Execution Module (SXM)
//              Spatial data rearrangement unit across 16 superlane lanes:
//              - SXM_PASS / SXM_PASSTHROUGH: Identity pass-through
//              - SXM_ROTATE_LEFT / SXM_BARREL_ROTATE: Barrel left rotation
//              - SXM_ROTATE_RIGHT: Barrel right rotation
//              - SXM_BROADCAST / SXM_BROADCAST_LANE: Lane broadcast
//              - SXM_REVERSE: Full 16-lane reversal (lane[15 - i])
//              - SXM_BIT_REVERSE: Bit-reversed lane index permutation
//              - SXM_INTERLEAVE: Even/odd lane interleave
//              - SXM_TRANSPOSE_4X4: Single-cycle 4x4 sub-tile transpose
//              - SXM_TRANSPOSE_LOAD / SXM_TRANSPOSE_READ: 16x16 byte matrix
//                transpose buffer (row write, column read with zero stall)
//              - SXM_BUTTERFLY_SWAP: XOR butterfly permutation (i ^ mask)
//                with optional RoPE odd/even sign negation
// =============================================================================
`ifndef GROQ_SXM_SLICE_SV
`define GROQ_SXM_SLICE_SV

`include "groq_pkg.sv"

module groq_sxm_slice #(
  parameter int P_LANES        = groq_pkg::SUPERLANE_LANES, // 16 lanes
  parameter int P_ELEM_BITS    = groq_pkg::ELEM_BITS,       // 8-bit element
  parameter int P_STREAM_WIDTH = groq_pkg::STREAM_WIDTH     // 128-bit stream
) (
  input  logic                        clk,
  input  logic                        rst_n,

  // VLIW Opcode & Permutation Control Inputs
  input  logic [3:0]                  sxm_op_i,
  input  logic [3:0]                  shift_amt_i,
  input  logic [3:0]                  src_lane_i,
  input  logic [3:0]                  butterfly_mask_i,
  input  logic [3:0]                  transpose_idx_i,
  input  logic                        rope_neg_even_en_i,

  // Spatial Stream Input & Output (16 lanes x 8-bit = 128-bit)
  input  logic                        stream_in_valid_i,
  input  logic [P_STREAM_WIDTH-1:0]   stream_in_data_i,
  output logic                        stream_out_valid_o,
  output logic [P_STREAM_WIDTH-1:0]   stream_out_data_o,

  // Combinational Immediate Permuted Vector (for 0-latency inspection/cascading)
  output logic [P_STREAM_WIDTH-1:0]   perm_comb_data_o
);

  // ---------------------------------------------------------------------------
  // 1. Unpack 16 Input Lanes & Helper Permuter Function
  // ---------------------------------------------------------------------------
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] in_lane;
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] out_lane_comb;
  logic [P_LANES-1:0][P_ELEM_BITS-1:0] transpose_buf [0:P_LANES-1];

  always_comb begin
    for (int i = 0; i < P_LANES; i++) begin
      in_lane[i] = stream_in_data_i[i*P_ELEM_BITS +: P_ELEM_BITS];
    end
  end

  // Pure combinational spatial permutation function (reusable for involution proof)
  function automatic logic [P_STREAM_WIDTH-1:0] apply_sxm_perm(
    input logic [P_STREAM_WIDTH-1:0] vec_in,
    input logic [3:0]                op,
    input logic [3:0]                shamt,
    input logic [3:0]                bcast_idx,
    input logic [3:0]                bfly_mask,
    input logic                      rope_neg
  );
    logic [P_LANES-1:0][P_ELEM_BITS-1:0] src;
    logic [P_LANES-1:0][P_ELEM_BITS-1:0] dst;
    logic [P_STREAM_WIDTH-1:0]           vec_out;
    logic [3:0]                          idx_rot_l, idx_rot_r, idx_bitrev, idx_bfly, idx_t4;
    begin
      for (int k = 0; k < P_LANES; k++) begin
        src[k] = vec_in[k*P_ELEM_BITS +: P_ELEM_BITS];
      end
      for (int i = 0; i < P_LANES; i++) begin
        idx_rot_l  = 4'(i) - shamt;
        idx_rot_r  = 4'(i) + shamt;
        idx_bitrev = {i[0], i[1], i[2], i[3]};
        idx_bfly   = 4'(i) ^ bfly_mask;
        idx_t4     = {i[1:0], i[3:2]};
        unique case (op)
          groq_pkg::SXM_PASSTHROUGH:    dst[i] = src[i];
          groq_pkg::SXM_BARREL_ROTATE,
          groq_pkg::SXM_ROTATE_LEFT:    dst[i] = src[idx_rot_l];
          groq_pkg::SXM_ROTATE_RIGHT:   dst[i] = src[idx_rot_r];
          groq_pkg::SXM_BROADCAST_LANE: dst[i] = src[bcast_idx];
          groq_pkg::SXM_REVERSE:        dst[i] = src[P_LANES - 1 - i];
          groq_pkg::SXM_BIT_REVERSE:    dst[i] = src[idx_bitrev];
          groq_pkg::SXM_TRANSPOSE_4X4:  dst[i] = src[idx_t4];
          groq_pkg::SXM_INTERLEAVE:     dst[i] = (i < 8) ? src[2*i] : src[2*(i-8)+1];
          groq_pkg::SXM_BUTTERFLY_SWAP: begin
            if (rope_neg && (i[0] == 1'b0)) begin
              dst[i] = (src[idx_bfly] == 8'h80) ? 8'h7F : -src[idx_bfly];
            end else begin
              dst[i] = src[idx_bfly];
            end
          end
          default:                      dst[i] = src[i];
        endcase
        vec_out[i*P_ELEM_BITS +: P_ELEM_BITS] = dst[i];
      end
      apply_sxm_perm = vec_out;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // 2. Combinational Permutation & 16x16 Transpose Buffer Read Mux
  // ---------------------------------------------------------------------------
  logic [P_STREAM_WIDTH-1:0] perm_vec_w;
  assign perm_vec_w = apply_sxm_perm(
    stream_in_data_i,
    sxm_op_i,
    shift_amt_i,
    src_lane_i,
    butterfly_mask_i,
    rope_neg_even_en_i
  );

  always_comb begin
    for (int i = 0; i < P_LANES; i++) begin
      if (sxm_op_i == groq_pkg::SXM_TRANSPOSE_READ) begin
        // Read column transpose_idx_i across all 16 rows (transposed readout)
        out_lane_comb[i] = transpose_buf[i][transpose_idx_i];
      end else begin
        out_lane_comb[i] = perm_vec_w[i*P_ELEM_BITS +: P_ELEM_BITS];
      end
      perm_comb_data_o[i*P_ELEM_BITS +: P_ELEM_BITS] = out_lane_comb[i];
    end
  end

  // ---------------------------------------------------------------------------
  // 3. 16x16 Byte Matrix Transpose Buffer & Deterministic 1-Cycle Stream Reg
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stream_out_valid_o <= 1'b0;
      stream_out_data_o  <= '0;
      for (int r = 0; r < P_LANES; r++) begin
        transpose_buf[r] <= '0;
      end
    end else begin
      if ((sxm_op_i == groq_pkg::SXM_TRANSPOSE_LOAD) && stream_in_valid_i) begin
        for (int c = 0; c < P_LANES; c++) begin
          transpose_buf[transpose_idx_i][c] <= in_lane[c];
        end
      end
      stream_out_valid_o <= stream_in_valid_i && (sxm_op_i != groq_pkg::SXM_NOP);
      if (stream_in_valid_i && (sxm_op_i != groq_pkg::SXM_NOP)) begin
        stream_out_data_o <= perm_comb_data_o;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 4. Formal Verification Assertions (Bijective Sum/XOR, Broadcast, Involution)
  // ---------------------------------------------------------------------------
`ifdef FORMAL
  /* verilator lint_off SYNCASYNCNET */
  logic [P_ELEM_BITS-1:0]    f_xor_in, f_xor_out;
  logic [P_ELEM_BITS-1:0]    f_or_in,  f_or_out;
  logic [P_ELEM_BITS-1:0]    f_and_in, f_and_out;
  logic [12:0]               f_sum_in, f_sum_out;
  logic [P_STREAM_WIDTH-1:0] f_twice_perm;
  logic                      f_is_bijective_op;
  logic                      f_is_involution_op;

  // Balanced binary reduction tree for fast SAT structural isomorphism
  always_comb begin
    f_xor_in  = '0;
    f_xor_out = '0;
    f_or_in   = '0;
    f_or_out  = '0;
    f_and_in  = '1;
    f_and_out = '1;
    for (int i = 0; i < P_LANES; i++) begin
      f_xor_in  = f_xor_in  ^ in_lane[i];
      f_xor_out = f_xor_out ^ out_lane_comb[i];
      f_or_in   = f_or_in   | in_lane[i];
      f_or_out  = f_or_out  | out_lane_comb[i];
      f_and_in  = f_and_in  & in_lane[i];
      f_and_out = f_and_out & out_lane_comb[i];
    end

    f_sum_in = (({5'd0, in_lane[0]}  + {5'd0, in_lane[15]}) +
                ({5'd0, in_lane[1]}  + {5'd0, in_lane[14]})) +
               (({5'd0, in_lane[2]}  + {5'd0, in_lane[13]}) +
                ({5'd0, in_lane[3]}  + {5'd0, in_lane[12]})) +
               (({5'd0, in_lane[4]}  + {5'd0, in_lane[11]}) +
                ({5'd0, in_lane[5]}  + {5'd0, in_lane[10]})) +
               (({5'd0, in_lane[6]}  + {5'd0, in_lane[9]})  +
                ({5'd0, in_lane[7]}  + {5'd0, in_lane[8]}));

    f_sum_out = (({5'd0, out_lane_comb[0]}  + {5'd0, out_lane_comb[15]}) +
                 ({5'd0, out_lane_comb[1]}  + {5'd0, out_lane_comb[14]})) +
                (({5'd0, out_lane_comb[2]}  + {5'd0, out_lane_comb[13]}) +
                 ({5'd0, out_lane_comb[3]}  + {5'd0, out_lane_comb[12]})) +
                (({5'd0, out_lane_comb[4]}  + {5'd0, out_lane_comb[11]}) +
                 ({5'd0, out_lane_comb[5]}  + {5'd0, out_lane_comb[10]})) +
                (({5'd0, out_lane_comb[6]}  + {5'd0, out_lane_comb[9]})  +
                 ({5'd0, out_lane_comb[7]}  + {5'd0, out_lane_comb[8]}));

    f_twice_perm = apply_sxm_perm(
      perm_vec_w,
      sxm_op_i,
      shift_amt_i,
      src_lane_i,
      butterfly_mask_i,
      rope_neg_even_en_i
    );

    f_is_bijective_op = (sxm_op_i == groq_pkg::SXM_PASSTHROUGH)   ||
                        (sxm_op_i == groq_pkg::SXM_BARREL_ROTATE) ||
                        (sxm_op_i == groq_pkg::SXM_ROTATE_LEFT)   ||
                        (sxm_op_i == groq_pkg::SXM_ROTATE_RIGHT)  ||
                        (sxm_op_i == groq_pkg::SXM_REVERSE)       ||
                        (sxm_op_i == groq_pkg::SXM_BIT_REVERSE)   ||
                        (sxm_op_i == groq_pkg::SXM_TRANSPOSE_4X4) ||
                        (sxm_op_i == groq_pkg::SXM_INTERLEAVE)    ||
                        ((sxm_op_i == groq_pkg::SXM_BUTTERFLY_SWAP) && !rope_neg_even_en_i);

    f_is_involution_op = (sxm_op_i == groq_pkg::SXM_PASSTHROUGH)   ||
                         (sxm_op_i == groq_pkg::SXM_REVERSE)       ||
                         (sxm_op_i == groq_pkg::SXM_BIT_REVERSE)   ||
                         (sxm_op_i == groq_pkg::SXM_TRANSPOSE_4X4) ||
                         ((sxm_op_i == groq_pkg::SXM_BUTTERFLY_SWAP) && !rope_neg_even_en_i);
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      // Property 1a: Bijective Lane XOR / OR / AND Conservation across all permute modes
      if (f_is_bijective_op) begin
        assert (f_xor_out == f_xor_in);
        assert (f_or_out  == f_or_in);
        assert (f_and_out == f_and_in);
      end
      // Property 1b: Exact 16-Lane Arithmetic Sum Invariant (Pass, Reverse, Butterfly-15)
      if ((sxm_op_i == groq_pkg::SXM_PASSTHROUGH) ||
          (sxm_op_i == groq_pkg::SXM_REVERSE)     ||
          ((sxm_op_i == groq_pkg::SXM_BUTTERFLY_SWAP) && !rope_neg_even_en_i && (butterfly_mask_i == 4'hF))) begin
        assert (f_sum_out == f_sum_in);
      end
      // Property 2: Broadcast Uniformity across all 16 lanes
      if (sxm_op_i == groq_pkg::SXM_BROADCAST_LANE) begin
        for (int i = 0; i < P_LANES; i++) begin
          assert (out_lane_comb[i] == in_lane[src_lane_i]);
        end
      end
      // Property 3: Exact Involution Property (Perm(Perm(x)) == x)
      if (f_is_involution_op) begin
        assert (f_twice_perm == stream_in_data_i);
      end
      // Property 4 (BUG-LIT-001): RoPE Even-Lane Saturating INT8 Negation (-128 -> +127)
      if ((sxm_op_i == groq_pkg::SXM_BUTTERFLY_SWAP) && rope_neg_even_en_i) begin
        for (int k = 0; k < P_LANES; k += 2) begin
          assert ($signed(out_lane_comb[k]) != -8'sd128);
        end
      end
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule : groq_sxm_slice

`endif // GROQ_SXM_SLICE_SV
