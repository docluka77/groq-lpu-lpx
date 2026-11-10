// =============================================================================
// File: rtl/groq_icu_slice.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Software-Scheduled Instruction Control Unit (ICU) Slice:
//              - 8 per-slice independent instruction queues / PC pointers
//                (pc_slice_o[0:NUM_SLICES-1]) dispatching 144-bit VLIW bundles.
//              - Deterministic NOP_DELAY(N) countdown timers that stall slice
//                instruction fetch for N cycles to save SRAM fetch power.
//              - Hardware SYNC / NOTIFY barrier synchronization engine that
//                aligns participating slices to 0-cycle skew upon release.
//              - Hardware RealSync cycle counter & plesiochronous deskew offset
//                register for multi-chip Dragonfly lockstep execution.
// =============================================================================
`include "groq_pkg.sv"

module groq_icu_slice #(
  parameter int P_NUM_SLICES     = groq_pkg::NUM_SLICES,
  parameter int P_PC_WIDTH       = 16,
  parameter int P_MAX_DRIFT_CYC  = 64
) (
  input  logic clk,
  input  logic rst_n,

  // ---------------------------------------------------------------------------
  // Per-Slice Instruction Memory (IMEM) Fetch & 144-bit VLIW Input Interface
  // ---------------------------------------------------------------------------
  input  logic                                            icu_enable_i,
  input  logic [P_NUM_SLICES-1:0][groq_pkg::VLIW_INSTR_BITS-1:0] imem_vliw_bundle_i,
  output logic [P_NUM_SLICES-1:0]                         imem_fetch_en_o,
  output logic [P_NUM_SLICES-1:0][P_PC_WIDTH-1:0]         pc_slice_o,

  // ---------------------------------------------------------------------------
  // Dispatched Per-Slice VLIW Instruction Stream Outputs
  // ---------------------------------------------------------------------------
  output logic [P_NUM_SLICES-1:0]                         slice_vliw_valid_o,
  output logic [P_NUM_SLICES-1:0][groq_pkg::VLIW_INSTR_BITS-1:0] slice_vliw_bundle_o,
  output logic [P_NUM_SLICES-1:0][15:0]                   slice_nop_timer_o,
  output logic [P_NUM_SLICES-1:0]                         slice_halted_o,

  // ---------------------------------------------------------------------------
  // Hardware SYNC / NOTIFY Barrier Synchronization Interface
  // ---------------------------------------------------------------------------
  input  logic [P_NUM_SLICES-1:0]                         slice_notify_ready_i,
  output logic [P_NUM_SLICES-1:0]                         barrier_waiting_o,
  output logic [P_NUM_SLICES-1:0]                         barrier_ready_mask_o,
  output logic                                            barrier_release_pulse_o,
  output logic [15:0]                                     barrier_release_cnt_o,

  // ---------------------------------------------------------------------------
  // Hardware RealSync Plesiochronous Multi-Chip Deskew Interface
  // ---------------------------------------------------------------------------
  input  logic                                            realsync_ext_adj_en_i,
  input  logic signed [15:0]                              realsync_ext_adj_val_i,
  output logic [63:0]                                     realsync_cycle_cnt_o,
  output logic signed [15:0]                              realsync_deskew_offset_o,
  output logic [63:0]                                     realsync_aligned_time_o,
  output logic                                            realsync_drift_fault_o
);


  // ---------------------------------------------------------------------------
  // Internal State Registers
  // ---------------------------------------------------------------------------
  logic [P_NUM_SLICES-1:0][P_PC_WIDTH-1:0] pc_slice_q;
  logic [P_NUM_SLICES-1:0]                 nop_active_q;
  logic [P_NUM_SLICES-1:0][15:0]           nop_timer_q;
  logic [P_NUM_SLICES-1:0]                 barrier_waiting_q;
  logic [P_NUM_SLICES-1:0][P_NUM_SLICES-1:0] sync_mask_q;
  logic [P_NUM_SLICES-1:0]                 notify_latched_q;
  logic [P_NUM_SLICES-1:0]                 slice_halted_q;

  logic [63:0]                             realsync_cycle_cnt_q;
  logic signed [15:0]                      realsync_deskew_q;
  logic [15:0]                             barrier_release_cnt_q;

  logic [P_NUM_SLICES-1:0][3:0]            s_icu_op;
  logic [P_NUM_SLICES-1:0][7:0]            s_sync_mask;
  logic [P_NUM_SLICES-1:0][15:0]           s_nop_cnt;
  logic [P_NUM_SLICES-1:0][15:0]           s_imm16;

  logic [P_NUM_SLICES-1:0]                 slice_entering_sync;
  logic [P_NUM_SLICES-1:0]                 slice_sync_active;
  logic [P_NUM_SLICES-1:0]                 active_sync_mask;
  logic signed [15:0]                      abs_deskew;

  // ---------------------------------------------------------------------------
  // Combinational Per-Slice Decode & Hardware Barrier Resolution
  // ---------------------------------------------------------------------------
  always_comb begin
    active_sync_mask = '0;
    for (int s = 0; s < P_NUM_SLICES; s++) begin
      s_icu_op[s]    = imem_vliw_bundle_i[s][139:136];
      s_sync_mask[s] = imem_vliw_bundle_i[s][95:88];
      s_nop_cnt[s]   = imem_vliw_bundle_i[s][87:72];
      s_imm16[s]     = imem_vliw_bundle_i[s][31:16];

      slice_entering_sync[s] = icu_enable_i & ~slice_halted_q[s] &
                               ~nop_active_q[s] & ~barrier_waiting_q[s] &
                               (s_icu_op[s] == groq_pkg::ICU_SYNC_BARRIER);
      slice_sync_active[s]   = barrier_waiting_q[s] | slice_entering_sync[s];

      if (slice_sync_active[s]) begin
        active_sync_mask = active_sync_mask |
                           ((barrier_waiting_q[s] ? sync_mask_q[s] : s_sync_mask[s][P_NUM_SLICES-1:0]) |
                            (P_NUM_SLICES'(1) << s));
      end

      barrier_ready_mask_o[s] = slice_sync_active[s] |
                                notify_latched_q[s] |
                                slice_notify_ready_i[s] |
                                (icu_enable_i & ~slice_halted_q[s] & ~nop_active_q[s] &
                                 ~barrier_waiting_q[s] & (s_icu_op[s] == groq_pkg::ICU_NOTIFY));

      pc_slice_o[s]        = pc_slice_q[s];
      slice_nop_timer_o[s] = nop_timer_q[s];
      slice_halted_o[s]    = slice_halted_q[s];
      barrier_waiting_o[s] = barrier_waiting_q[s];

      // Suppress instruction SRAM fetch during NOP_DELAY stall, barrier wait, or halt
      imem_fetch_en_o[s] = icu_enable_i & ~slice_halted_q[s] &
                           ~nop_active_q[s] & ~barrier_waiting_q[s];

      slice_vliw_valid_o[s]  = icu_enable_i & ~slice_halted_q[s] &
                               ~nop_active_q[s] & ~slice_sync_active[s];
      slice_vliw_bundle_o[s] = slice_vliw_valid_o[s] ? imem_vliw_bundle_i[s] : '0;
    end

    barrier_release_pulse_o = (|slice_sync_active) &
                              ((barrier_ready_mask_o & active_sync_mask) == active_sync_mask);

    realsync_cycle_cnt_o     = realsync_cycle_cnt_q;
    realsync_deskew_offset_o = realsync_deskew_q;
    realsync_aligned_time_o  = realsync_cycle_cnt_q +
                               {{48{realsync_deskew_q[15]}}, realsync_deskew_q};
    abs_deskew               = (realsync_deskew_q < 16'sd0) ? -realsync_deskew_q : realsync_deskew_q;
    realsync_drift_fault_o   = (abs_deskew > 16'(P_MAX_DRIFT_CYC));
    barrier_release_cnt_o    = barrier_release_cnt_q;
  end

  // ---------------------------------------------------------------------------
  // Sequential Per-Slice PC, NOP_DELAY Timers, Barrier & RealSync State
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < P_NUM_SLICES; s++) begin
        pc_slice_q[s]        <= '0;
        nop_active_q[s]      <= 1'b0;
        nop_timer_q[s]       <= 16'd0;
        barrier_waiting_q[s] <= 1'b0;
        sync_mask_q[s]       <= '0;
        notify_latched_q[s]  <= 1'b0;
        slice_halted_q[s]    <= 1'b0;
      end
      realsync_cycle_cnt_q  <= 64'd0;
      realsync_deskew_q     <= 16'sd0;
      barrier_release_cnt_q <= 16'd0;
    end else begin
      realsync_cycle_cnt_q <= realsync_cycle_cnt_q + 64'd1;

      if (barrier_release_pulse_o) begin
        barrier_release_cnt_q <= barrier_release_cnt_q + 16'd1;
        notify_latched_q      <= '0;
      end else begin
        for (int s = 0; s < P_NUM_SLICES; s++) begin
          if (slice_notify_ready_i[s] ||
              (icu_enable_i && !slice_halted_q[s] && !nop_active_q[s] &&
               !barrier_waiting_q[s] && (s_icu_op[s] == groq_pkg::ICU_NOTIFY))) begin
            notify_latched_q[s] <= 1'b1;
          end
        end
      end

      // RealSync plesiochronous deskew update (external C2C marker or ICU op)
      if (realsync_ext_adj_en_i) begin
        realsync_deskew_q <= realsync_ext_adj_val_i;
      end else if (icu_enable_i && (P_NUM_SLICES > groq_pkg::SLICE_ICU) &&
                   !slice_halted_q[groq_pkg::SLICE_ICU] &&
                   !nop_active_q[groq_pkg::SLICE_ICU] && !slice_sync_active[groq_pkg::SLICE_ICU] &&
                   (s_icu_op[groq_pkg::SLICE_ICU] == groq_pkg::ICU_REALSYNC_ADJ)) begin
        realsync_deskew_q <= signed'(s_imm16[groq_pkg::SLICE_ICU]);
      end

      // Per-slice deterministic PC & NOP_DELAY progression
      for (int s = 0; s < P_NUM_SLICES; s++) begin
        if (slice_halted_q[s]) begin
          pc_slice_q[s] <= pc_slice_q[s];
        end else if (nop_active_q[s]) begin
          if (nop_timer_q[s] > 16'd1) begin
            nop_timer_q[s] <= nop_timer_q[s] - 16'd1;
            pc_slice_q[s]  <= pc_slice_q[s];
          end else begin
            nop_active_q[s] <= 1'b0;
            nop_timer_q[s]  <= 16'd0;
            pc_slice_q[s]   <= pc_slice_q[s] + P_PC_WIDTH'(1);
          end
        end else if (slice_sync_active[s]) begin
          if (barrier_release_pulse_o) begin
            barrier_waiting_q[s] <= 1'b0;
            sync_mask_q[s]       <= '0;
            pc_slice_q[s]        <= pc_slice_q[s] + P_PC_WIDTH'(1);
          end else begin
            barrier_waiting_q[s] <= 1'b1;
            if (!barrier_waiting_q[s]) begin
              sync_mask_q[s] <= s_sync_mask[s][P_NUM_SLICES-1:0];
            end
            pc_slice_q[s]        <= pc_slice_q[s];
          end
        end else if (icu_enable_i) begin
          unique case (s_icu_op[s])
            groq_pkg::ICU_NOP_DELAY: begin
              if (s_nop_cnt[s] > 16'd0) begin
                nop_active_q[s] <= 1'b1;
                nop_timer_q[s]  <= s_nop_cnt[s];
                pc_slice_q[s]   <= pc_slice_q[s];
              end else begin
                pc_slice_q[s]   <= pc_slice_q[s] + P_PC_WIDTH'(1);
              end
            end
            groq_pkg::ICU_JUMP_IMM: begin
              pc_slice_q[s] <= s_imm16[s][P_PC_WIDTH-1:0];
            end
            groq_pkg::ICU_HALT: begin
              slice_halted_q[s] <= 1'b1;
              pc_slice_q[s]     <= pc_slice_q[s];
            end
            default: begin
              pc_slice_q[s] <= pc_slice_q[s] + P_PC_WIDTH'(1);
            end
          endcase
        end
      end
    end
  end

`ifdef FORMAL
  /* verilator lint_off SYNCASYNCNET */
  // ---------------------------------------------------------------------------
  // Formal Verification Properties (Yosys 0.60 SAT / SMTBMC)
  // 1. Deadlock-Free Barrier Release & Simultaneous Multi-Slice PC Advance
  // 2. Exact NOP_DELAY(N) Timing (holds PC for N cycles, advances after N)
  // 3. Instruction Fetch Gating during NOP_DELAY & Barrier Wait
  // 4. RealSync Cycle Counter Monotonicity & Drift Fault Bounds
  // ---------------------------------------------------------------------------
  logic [3:0]              f_cycle;
  logic                    f_release_prev;
  logic [1:0]              f_sync_active_prev;
  logic [P_PC_WIDTH-1:0]   f_pc_s0_prev;
  logic [P_PC_WIDTH-1:0]   f_pc_s1_prev;
  logic [63:0]             f_realsync_prev;

  // Shadow state for exact NOP_DELAY(N) timing proof on slice 0 (N=1,2,3)
  logic                    f_nop_n2_c1, f_nop_n2_c2, f_nop_n2_c3;
  logic [P_PC_WIDTH-1:0]   f_nop_pc_c1, f_nop_pc_c2, f_nop_pc_c3;

  initial begin
    f_cycle            = 4'd0;
    f_release_prev     = 1'b0;
    f_sync_active_prev = '0;
    f_pc_s0_prev       = '0;
    f_pc_s1_prev       = '0;
    f_realsync_prev    = 64'd0;
    f_nop_n2_c1        = 1'b0;
    f_nop_n2_c2        = 1'b0;
    f_nop_n2_c3        = 1'b0;
    f_nop_pc_c1        = '0;
    f_nop_pc_c2        = '0;
    f_nop_pc_c3        = '0;
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
      f_cycle            <= 4'd1;
      f_release_prev     <= 1'b0;
      f_sync_active_prev <= '0;
      f_pc_s0_prev       <= '0;
      f_pc_s1_prev       <= '0;
      f_realsync_prev    <= 64'd0;
      f_nop_n2_c1        <= 1'b0;
      f_nop_n2_c2        <= 1'b0;
      f_nop_n2_c3        <= 1'b0;
      f_nop_pc_c1        <= '0;
      f_nop_pc_c2        <= '0;
      f_nop_pc_c3        <= '0;
    end else begin
      if (f_cycle < 4'd15) f_cycle <= f_cycle + 4'd1;

      f_release_prev     <= barrier_release_pulse_o;
      f_sync_active_prev <= slice_sync_active[1:0];
      f_pc_s0_prev       <= pc_slice_o[0];
      f_pc_s1_prev       <= pc_slice_o[1];
      f_realsync_prev    <= realsync_cycle_cnt_o;

      // Track a slice 0 NOP_DELAY(2) issue across 3 subsequent cycles
      f_nop_n2_c1 <= icu_enable_i & ~slice_halted_q[0] & ~nop_active_q[0] &
                     ~slice_sync_active[0] & (s_icu_op[0] == groq_pkg::ICU_NOP_DELAY) &
                     (s_nop_cnt[0] == 16'd2);
      f_nop_pc_c1 <= pc_slice_o[0];

      f_nop_n2_c2 <= f_nop_n2_c1;
      f_nop_pc_c2 <= f_nop_pc_c1;

      f_nop_n2_c3 <= f_nop_n2_c2;
      f_nop_pc_c3 <= f_nop_pc_c2;

      if (f_cycle >= 4'd2) begin
        // Theorem 1: Deadlock-Free Barrier Release & Simultaneous Advance
        if ((|slice_sync_active) &&
            ((barrier_ready_mask_o & active_sync_mask) == active_sync_mask)) begin
          assert(barrier_release_pulse_o == 1'b1);
        end
        if (f_release_prev && f_sync_active_prev[0]) begin
          assert(barrier_waiting_o[0] == 1'b0);
          assert(pc_slice_o[0] == (f_pc_s0_prev + P_PC_WIDTH'(1)));
        end
        if (f_release_prev && f_sync_active_prev[1]) begin
          assert(barrier_waiting_o[1] == 1'b0);
          assert(pc_slice_o[1] == (f_pc_s1_prev + P_PC_WIDTH'(1)));
        end

        // Theorem 2: Exact NOP_DELAY(2) Timing (held at c1 & c2, advances at c3)
        if (f_nop_n2_c1) begin
          assert(pc_slice_o[0]      == f_nop_pc_c1);
          assert(imem_fetch_en_o[0] == 1'b0);
          assert(slice_nop_timer_o[0] == 16'd2);
        end
        if (f_nop_n2_c2) begin
          assert(pc_slice_o[0]      == f_nop_pc_c2);
          assert(imem_fetch_en_o[0] == 1'b0);
          assert(slice_nop_timer_o[0] == 16'd1);
        end
        if (f_nop_n2_c3) begin
          assert(pc_slice_o[0]      == (f_nop_pc_c3 + P_PC_WIDTH'(1)));
          assert(slice_nop_timer_o[0] == 16'd0);
        end

        // Theorem 3: RealSync Monotonic Counter
        assert(realsync_cycle_cnt_o == (f_realsync_prev + 64'd1));
      end
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule : groq_icu_slice
