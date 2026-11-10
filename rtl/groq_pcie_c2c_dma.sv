// =============================================================================
// File: rtl/groq_pcie_c2c_dma.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 12 NVLink-C2C / PCIe Gen5 Scatter-Gather Descriptor Ring
//              DMA Engine & Cycle-Exact Deterministic Admission Controller IP:
//              - 4-Entry 128-Bit Circular Descriptor Ring Queue (head/tail/cnt)
//              - Targets: 00=IMEM, 01=SRAM_WEST, 10=SRAM_EAST, 11=BCAST_BOTH
//              - Hardware Deterministic Admission Window Controller:
//                Zero VLIW SRAM contention invariant (pauses DMA beats when
//                vliw_sram_busy_i or vliw_active_window_i is asserted)
//              - Strided Burst Address Generator (addr_q + stride_q)
//              - End-to-End Payload Parity/ECC Verification & IRQ Telemetry
// =============================================================================
`ifndef GROQ_PCIE_C2C_DMA_SV
`define GROQ_PCIE_C2C_DMA_SV

`include "groq_pkg.sv"

module groq_pcie_c2c_dma #(
  parameter int P_STREAM_WIDTH  = groq_pkg::STREAM_WIDTH,     // 128-bit beat
  parameter int P_VLIW_BITS     = groq_pkg::VLIW_INSTR_BITS,  // 144-bit IMEM bundle
  parameter int P_RING_DEPTH    = 4,                          // 4-Entry Descriptor Ring
  parameter int P_BANK_ID_W     = 2,
  parameter int P_MEM_ADDR_W    = 16
) (
  input  logic                        clk,
  input  logic                        rst_n,

  // Global Deterministic Cycle Reference & VLIW SRAM Busy Window Signals
  input  logic [15:0]                 global_cycle_i,
  input  logic                        vliw_active_window_i,
  input  logic                        vliw_sram_busy_i,
  input  logic                        vliw_sram_w_busy_i,
  input  logic                        vliw_sram_e_busy_i,

  // Scatter-Gather 128-Bit Descriptor Ring Push Interface
  // Descriptor layout:
  //   [1:0]   dma_target            (00=IMEM, 01=SRAM_WEST, 10=SRAM_EAST, 11=BCAST_BOTH_SRAM)
  //   [4:2]   slice_or_bank_sel     (target slice 0..7 for IMEM, bank 0..3 for SRAM)
  //   [7:5]   reserved_flags
  //   [23:8]  base_addr             (16-bit starting address)
  //   [31:24] stride                (8-bit address stride per beat)
  //   [39:32] burst_len             (8-bit burst beat count, >=1)
  //   [55:40] scheduled_start_cycle (16-bit earliest admission cycle)
  //   [71:56] imem_upper_16b        (upper 16 bits [143:128] when writing 144b IMEM)
  //   [127:72] desc_tag_meta
  input  logic                        desc_push_valid_i,
  input  logic [127:0]                desc_push_data_i,
  output logic                        desc_push_ready_o,
  output logic                        full_o,
  output logic                        empty_o,
  output logic [1:0]                  head_ptr_o,
  output logic [1:0]                  tail_ptr_o,
  output logic [2:0]                  desc_count_o,

  // Host C2C / PCIe Gen5 Streaming Payload Beat Input + 16-Bit Byte Parity/ECC
  input  logic                        dma_payload_valid_i,
  input  logic [P_STREAM_WIDTH-1:0]   dma_payload_data_i,
  input  logic [15:0]                 dma_payload_parity_i,
  output logic                        dma_payload_ready_o,

  // Instruction Memory (IMEM) Write Port
  output logic                        imem_wr_en_o,
  output logic [2:0]                  imem_wr_slice_o,
  output logic [15:0]                 imem_wr_addr_o,
  output logic [P_VLIW_BITS-1:0]      imem_wr_data_o,

  // West Hemisphere Superlane SRAM Write Port
  output logic                        host_mem_w_wr_en_o,
  output logic [P_BANK_ID_W-1:0]      host_mem_w_bank_o,
  output logic [P_MEM_ADDR_W-1:0]     host_mem_w_addr_o,
  output logic [P_STREAM_WIDTH-1:0]   host_mem_w_data_o,

  // East Hemisphere Superlane SRAM Write Port
  output logic                        host_mem_e_wr_en_o,
  output logic [P_BANK_ID_W-1:0]      host_mem_e_bank_o,
  output logic [P_MEM_ADDR_W-1:0]     host_mem_e_addr_o,
  output logic [P_STREAM_WIDTH-1:0]   host_mem_e_data_o,

  // Admission Telemetry, Error Status & Completion Interrupts
  output logic                        dma_busy_o,
  output logic                        dma_window_stall_o,
  output logic                        payload_parity_err_o,
  output logic                        dma_done_irq_o,
  output logic [7:0]                  completed_desc_cnt_o,
  output logic [15:0]                 beats_transferred_o
);


  // ---------------------------------------------------------------------------
  // 1. DMA Target Encodings & 16-Bit Byte-Wise Payload Parity Helper
  // ---------------------------------------------------------------------------
  localparam logic [1:0] DMA_TGT_IMEM       = 2'b00;
  localparam logic [1:0] DMA_TGT_SRAM_W     = 2'b01;
  localparam logic [1:0] DMA_TGT_SRAM_E     = 2'b10;
  localparam logic [1:0] DMA_TGT_BCAST_BOTH = 2'b11;

  function automatic logic [15:0] calc_payload_parity16(
    input logic [P_STREAM_WIDTH-1:0] data_in
  );
    logic [15:0] p;
    begin
      for (int i = 0; i < 16; i++) begin
        p[i] = ^data_in[i*8 +: 8];
      end
      calc_payload_parity16 = p;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // 2. 4-Entry Circular Descriptor Ring Queue (desc_ring_q[0:3])
  // ---------------------------------------------------------------------------
  logic [127:0] desc_ring_q [0:P_RING_DEPTH-1];
  logic [1:0]   head_ptr_q;
  logic [1:0]   tail_ptr_q;
  logic [2:0]   desc_count_q;

  assign full_o            = (desc_count_q == 3'd4);
  assign empty_o           = (desc_count_q == 3'd0);
  assign desc_push_ready_o = !full_o;
  assign head_ptr_o        = head_ptr_q;
  assign tail_ptr_o        = tail_ptr_q;
  assign desc_count_o      = desc_count_q;

  // Head descriptor field extraction
  logic [127:0] head_desc;
  logic [1:0]   head_target;
  logic [2:0]   head_sel;
  logic [15:0]  head_base_addr;
  logic [7:0]   head_stride;
  logic [7:0]   head_burst_len;
  logic [15:0]  head_sched_cycle;
  logic [15:0]  head_imem_upper;
  logic         head_schedule_ready;

  assign head_desc           = desc_ring_q[head_ptr_q];
  assign head_target         = head_desc[1:0];
  assign head_sel            = head_desc[4:2];
  assign head_base_addr      = head_desc[23:8];
  assign head_stride         = head_desc[31:24];
  assign head_burst_len      = (head_desc[39:32] == 8'd0) ? 8'd1 : head_desc[39:32];
  assign head_sched_cycle    = head_desc[55:40];
  assign head_imem_upper     = head_desc[71:56];
  wire _unused_head_desc = &{1'b0, head_desc[127:72], head_desc[7:5]};
  assign head_schedule_ready = !empty_o && (global_cycle_i >= head_sched_cycle);

  // ---------------------------------------------------------------------------
  // 3. Active Burst Engine & Deterministic VLIW Admission Window Controller
  // ---------------------------------------------------------------------------
  logic         dma_active_q;
  logic [1:0]   dma_target_q;
  logic [2:0]   dma_sel_q;
  logic [15:0]  addr_q;
  logic [7:0]   stride_q;
  logic [7:0]   rem_beats_q;
  logic [15:0]  imem_upper_q;

  logic         do_push;
  logic         do_pop;
  logic         target_is_west_sram;
  logic         target_is_east_sram;
  logic         west_window_blocked;
  logic         east_window_blocked;
  logic         sram_window_blocked;
  logic         beat_fire;

  assign do_push = desc_push_valid_i && !full_o;
  assign do_pop  = !dma_active_q && head_schedule_ready;

  assign target_is_west_sram = (dma_target_q == DMA_TGT_SRAM_W) || (dma_target_q == DMA_TGT_BCAST_BOTH);
  assign target_is_east_sram = (dma_target_q == DMA_TGT_SRAM_E) || (dma_target_q == DMA_TGT_BCAST_BOTH);

  // Zero VLIW Contention Invariant: block SRAM writes whenever VLIW SRAM window is busy
  assign west_window_blocked = target_is_west_sram && (vliw_sram_busy_i || vliw_sram_w_busy_i || vliw_active_window_i);
  assign east_window_blocked = target_is_east_sram && (vliw_sram_busy_i || vliw_sram_e_busy_i || vliw_active_window_i);
  assign sram_window_blocked = west_window_blocked || east_window_blocked;


  assign payload_parity_err_o = dma_payload_valid_i &&
                                (calc_payload_parity16(dma_payload_data_i) != dma_payload_parity_i);

  assign dma_busy_o          = dma_active_q;
  assign dma_window_stall_o  = dma_active_q && dma_payload_valid_i && sram_window_blocked;
  assign dma_payload_ready_o = dma_active_q && !sram_window_blocked;
  assign beat_fire           = dma_active_q && dma_payload_valid_i && !sram_window_blocked && !payload_parity_err_o;

  // IMEM Write Port (active only when dma_target_q == DMA_TGT_IMEM)
  assign imem_wr_en_o        = beat_fire && (dma_target_q == DMA_TGT_IMEM);
  assign imem_wr_slice_o     = dma_sel_q;
  assign imem_wr_addr_o      = addr_q;
  assign imem_wr_data_o      = {imem_upper_q, dma_payload_data_i};

  // West SRAM Write Port (strictly gated off during VLIW SRAM busy window)
  assign host_mem_w_wr_en_o  = beat_fire && target_is_west_sram && !west_window_blocked;
  assign host_mem_w_bank_o   = dma_sel_q[P_BANK_ID_W-1:0];
  assign host_mem_w_addr_o   = addr_q[P_MEM_ADDR_W-1:0];
  assign host_mem_w_data_o   = dma_payload_data_i;

  // East SRAM Write Port (strictly gated off during VLIW SRAM busy window)
  assign host_mem_e_wr_en_o  = beat_fire && target_is_east_sram && !east_window_blocked;
  assign host_mem_e_bank_o   = dma_sel_q[P_BANK_ID_W-1:0];
  assign host_mem_e_addr_o   = addr_q[P_MEM_ADDR_W-1:0];
  assign host_mem_e_data_o   = dma_payload_data_i;

  // ---------------------------------------------------------------------------
  // 4. Sequential Ring Queue, Strided Burst Engine & Telemetry Counters
  // ---------------------------------------------------------------------------
  logic        dma_done_irq_q;
  logic [7:0]  completed_desc_cnt_q;
  logic [15:0] beats_transferred_q;

  assign dma_done_irq_o       = dma_done_irq_q;
  assign completed_desc_cnt_o = completed_desc_cnt_q;
  assign beats_transferred_o  = beats_transferred_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head_ptr_q           <= 2'd0;
      tail_ptr_q           <= 2'd0;
      desc_count_q         <= 3'd0;
      dma_active_q         <= 1'b0;
      dma_target_q         <= 2'd0;
      dma_sel_q            <= 3'd0;
      addr_q               <= 16'd0;
      stride_q             <= 8'd0;
      rem_beats_q          <= 8'd0;
      imem_upper_q         <= 16'd0;
      dma_done_irq_q       <= 1'b0;
      completed_desc_cnt_q <= 8'd0;
      beats_transferred_q  <= 16'd0;
      for (int i = 0; i < P_RING_DEPTH; i++) begin
        desc_ring_q[i] <= 128'd0;
      end
    end else begin
      dma_done_irq_q <= 1'b0;

      // Descriptor Ring Push / Pop Updates
      if (do_push) begin
        desc_ring_q[tail_ptr_q] <= desc_push_data_i;
        tail_ptr_q              <= tail_ptr_q + 2'd1;
      end
      if (do_pop) begin
        head_ptr_q <= head_ptr_q + 2'd1;
      end
      unique case ({do_push, do_pop})
        2'b10: desc_count_q <= desc_count_q + 3'd1;
        2'b01: desc_count_q <= desc_count_q - 3'd1;
        default: desc_count_q <= desc_count_q;
      endcase

      // Burst Engine State & Strided Address Progression
      if (do_pop) begin
        dma_active_q <= 1'b1;
        dma_target_q <= head_target;
        dma_sel_q    <= head_sel;
        addr_q       <= head_base_addr;
        stride_q     <= head_stride;
        rem_beats_q  <= head_burst_len;
        imem_upper_q <= head_imem_upper;
      end else if (beat_fire) begin
        beats_transferred_q <= beats_transferred_q + 16'd1;
        if (rem_beats_q <= 8'd1) begin
          dma_active_q         <= 1'b0;
          rem_beats_q          <= 8'd0;
          dma_done_irq_q       <= 1'b1;
          completed_desc_cnt_q <= completed_desc_cnt_q + 8'd1;
        end else begin
          addr_q      <= addr_q + {8'd0, stride_q};
          rem_beats_q <= rem_beats_q - 8'd1;
        end
      end
    end
  end


`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // 5. Formal Verification Proofs (Ring Pointers, Zero VLIW Contention, Stride)
  // ---------------------------------------------------------------------------
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);

  always @(posedge clk) begin
    if (rst_n) begin
      // 1) Descriptor Ring FIFO Pointer & Count Invariants
      assert (desc_count_o <= 3'd4);
      assert (full_o  == (desc_count_o == 3'd4));
      assert (empty_o == (desc_count_o == 3'd0));
      assert (((head_ptr_o + desc_count_o[1:0]) & 2'b11) == tail_ptr_o);
      if (full_o)  assert (!do_push && !desc_push_ready_o);
      if (empty_o) assert (!do_pop);

      // 2) Zero VLIW Contention Invariant (Cycle-Exact Admission Guarantee)
      if (vliw_sram_busy_i || vliw_sram_w_busy_i || vliw_active_window_i) begin
        assert (host_mem_w_wr_en_o == 1'b0);
      end
      if (vliw_sram_busy_i || vliw_sram_e_busy_i || vliw_active_window_i) begin
        assert (host_mem_e_wr_en_o == 1'b0);
      end
      if (dma_active_q && dma_payload_valid_i && sram_window_blocked) begin
        assert (dma_window_stall_o == 1'b1);
        assert (host_mem_w_wr_en_o == 1'b0);
        assert (host_mem_e_wr_en_o == 1'b0);
      end

      // 3) Payload Parity Error Gating
      if (payload_parity_err_o) begin
        assert (!imem_wr_en_o && !host_mem_w_wr_en_o && !host_mem_e_wr_en_o);
      end
    end

    // 4) Exact Strided Address Progression & Stall Hold Invariant
    if (f_past_valid && rst_n && $past(rst_n)) begin
      if ($past(beat_fire) && ($past(rem_beats_q) > 8'd1)) begin
        assert (addr_q == ($past(addr_q) + {8'd0, $past(stride_q)}));
        assert (rem_beats_q == ($past(rem_beats_q) - 8'd1));
      end
      if ($past(dma_active_q) && !$past(beat_fire)) begin
        assert (addr_q == $past(addr_q));
        assert (rem_beats_q == $past(rem_beats_q));
      end
      if ($past(full_o) && !$past(do_pop)) begin
        assert (desc_count_o == 3'd4);
      end
      if ($past(empty_o) && !$past(do_push)) begin
        assert (desc_count_o == 3'd0);
      end
    end
  end
`endif

endmodule
`endif // GROQ_PCIE_C2C_DMA_SV

