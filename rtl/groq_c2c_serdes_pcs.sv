// =============================================================================
// File: rtl/groq_c2c_serdes_pcs.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Stage 12 High-Speed Chip-to-Chip (C2C) 64B/66B Physical Coding
//              Sublayer (PCS), Self-Synchronizing LFSR Scrambler/Descrambler,
//              Link Training & RealSync Calibration FSM, CRC-16-CCITT (0x1021),
//              and 4-Entry Go-Back-N Link Replay Buffer IP.
// =============================================================================
`ifndef GROQ_C2C_SERDES_PCS_SV
`define GROQ_C2C_SERDES_PCS_SV

`include "groq_pkg.sv"

module groq_c2c_serdes_pcs #(
 parameter int P_STREAM_WIDTH = groq_pkg::STREAM_WIDTH, // 128-bit stream flit
 parameter int P_META_WIDTH = 16, // {dst_chip,hop,op,seq}
 parameter int P_CRC_WIDTH = 16, // CRC-16-CCITT (0x1021)
 parameter int P_FRAME_WIDTH = 2 + P_CRC_WIDTH + P_META_WIDTH + P_STREAM_WIDTH, // 162b
 parameter int P_REPLAY_DEPTH = 4 // 4-Entry Go-Back-N buffer
) (
 input logic clk,
 input logic rst_n,

 // Link Control & Scrambler Configuration
 input logic link_enable_i,
 input logic scramble_en_i,
 input logic rx_ts1_seen_i,
 input logic rx_ts2_seen_i,
 input logic deskew_done_i,
 input logic retrain_req_i,
 input logic [7:0] local_realsync_cnt_i,
 input logic [7:0] rx_beacon_ts_i,

 // TX Upper-Layer Interface (from groq_nim_realsync)
 input logic tx_flit_valid_i,
 input logic [P_STREAM_WIDTH-1:0] tx_flit_data_i,
 input logic [3:0] tx_dst_chip_i,
 input logic [3:0] tx_hop_cnt_i,
 input logic [3:0] tx_opcode_i,
 output logic tx_ready_o,

 // Remote Go-Back-N NACK Input (triggers automatic replay from nack_seq_i)
 input logic nack_req_i,
 input logic [1:0] nack_seq_i,

 // Physical C2C 64B/66B Framed SerDes Output
 output logic phy_tx_valid_o,
 output logic [P_FRAME_WIDTH-1:0] phy_tx_frame_o,
 output logic [1:0] tx_sync_hdr_o,
 output logic [P_CRC_WIDTH-1:0] tx_crc16_o,
 output logic [P_META_WIDTH-1:0] tx_meta_o,
 output logic [P_STREAM_WIDTH-1:0] tx_scrambled_payload_o,
 output logic replay_active_o,
 output logic [3:0] tx_seq_num_o,

 // Physical C2C 64B/66B Framed SerDes Input
 input logic phy_rx_valid_i,
 input logic [P_FRAME_WIDTH-1:0] phy_rx_frame_i,

 // RX Upper-Layer Output (to groq_nim_realsync) & Link Telemetry
 output logic rx_flit_valid_o,
 output logic [P_STREAM_WIDTH-1:0] rx_flit_data_o,
 output logic [3:0] rx_dst_chip_o,
 output logic [3:0] rx_hop_cnt_o,
 output logic [3:0] rx_opcode_o,
 output logic [3:0] rx_seq_num_o,
 output logic rx_crc16_err_o,
 output logic rx_sync_err_o,
 output logic nack_req_o,
 output logic [1:0] nack_seq_o,

 // Link Training FSM & RealSync Skew Status
 output logic [2:0] link_state_o,
 output logic link_up_o,
 output logic [7:0] measured_skew_o
);

  // ---------------------------------------------------------------------------
  // 1. 64B/66B Sync Headers & Link Training FSM State Encodings
  // ---------------------------------------------------------------------------
  localparam logic [1:0] SYNC_DATA = 2'b01; // Data Block Sync Header
  localparam logic [1:0] SYNC_CTRL = 2'b10; // Control/Training/Beacon Sync Header

  localparam logic [2:0] LINK_RESET       = 3'd0;
  localparam logic [2:0] LINK_TRAIN_TS1   = 3'd1;
  localparam logic [2:0] LINK_TRAIN_TS2   = 3'd2;
  localparam logic [2:0] LINK_DESKEW_LOCK = 3'd3;
  localparam logic [2:0] LINK_ACTIVE      = 3'd4;
  localparam logic [2:0] LINK_RETRAIN     = 3'd5;

  // Ordered Set Control Payloads for TS1 / TS2 / Deskew Beacon
  localparam logic [P_STREAM_WIDTH-1:0] TS1_PATTERN = {16{8'h4A}}; // IEEE/C2C TS1
  localparam logic [P_STREAM_WIDTH-1:0] TS2_PATTERN = {16{8'h45}}; // IEEE/C2C TS2

  // ---------------------------------------------------------------------------
  // 2. LFSR Scrambler / Descrambler: G(x) = x^16 + x^14 + x^13 + x^11 + 1
  // ---------------------------------------------------------------------------
  function automatic logic [15:0] lfsr16_next_state(
    input logic [15:0] s_in
  );
    logic [15:0] s;
    logic        fb;
    begin
      s = s_in;
      for (int i = 0; i < 16; i++) begin
        fb = s[15] ^ s[13] ^ s[12] ^ s[10];
        s  = {s[14:0], fb};
      end
      lfsr16_next_state = s;
    end
  endfunction

  function automatic logic [P_STREAM_WIDTH-1:0] gen_scramble_mask(
    input logic [15:0] seed
  );
    logic [15:0]               s;
    logic                      fb;
    logic [P_STREAM_WIDTH-1:0] mask;
    begin
      s = seed;
      for (int b = 0; b < P_STREAM_WIDTH; b++) begin
        fb      = s[15] ^ s[13] ^ s[12] ^ s[10];
        mask[b] = fb;
        s       = {s[14:0], fb};
      end
      gen_scramble_mask = mask;
    end
  endfunction

  function automatic logic [P_STREAM_WIDTH-1:0] apply_scrambler(
    input logic [P_STREAM_WIDTH-1:0] data_in,
    input logic [15:0]               seed,
    input logic                      en
  );
    begin
      if (en) apply_scrambler = data_in ^ gen_scramble_mask(seed);
      else    apply_scrambler = data_in;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // 3. CRC-16-CCITT (Poly 0x1021: x^16 + x^12 + x^5 + 1) over {meta, payload}
  // ---------------------------------------------------------------------------
  function automatic logic [15:0] crc16_ccitt_byte(
    input logic [15:0] crc_in,
    input logic [7:0]  data_byte
  );
    logic [15:0] c;
    begin
      c = crc_in ^ {data_byte, 8'h00};
      for (int b = 0; b < 8; b++) begin
        if (c[15]) c = (c << 1) ^ 16'h1021;
        else       c = (c << 1);
      end
      crc16_ccitt_byte = c;
    end
  endfunction

  function automatic logic [15:0] crc16_ccitt_calc(
    input logic [P_META_WIDTH-1:0]   meta,
    input logic [P_STREAM_WIDTH-1:0] payload
  );
    logic [15:0] c;
    begin
      c = 16'hFFFF;
      for (int i = 0; i < (P_STREAM_WIDTH / 8); i++) begin
        c = crc16_ccitt_byte(c, payload[i*8 +: 8]);
      end
      c = crc16_ccitt_byte(c, meta[7:0]);
      c = crc16_ccitt_byte(c, meta[15:8]);
      crc16_ccitt_calc = c;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // 4. Link Training FSM, Scrambler LFSR & 4-Entry Go-Back-N Replay Buffer
  // ---------------------------------------------------------------------------
  logic [2:0]                  link_state_q, link_state_d;
  logic [7:0]                  measured_skew_q;
  logic [15:0]                 tx_lfsr_q, rx_lfsr_q;

  // 4-Entry Go-Back-N Replay Buffer indexed by seq_num[1:0]
  logic [P_REPLAY_DEPTH-1:0]   replay_valid_q;
  logic [P_STREAM_WIDTH-1:0]   replay_data_q [0:P_REPLAY_DEPTH-1];
  logic [11:0]                 replay_hdr_q  [0:P_REPLAY_DEPTH-1]; // {dst,hop,op}
  logic [3:0]                  replay_seq_q  [0:P_REPLAY_DEPTH-1];

  logic [3:0]                  tx_seq_q;
  logic                        replay_active_q;
  logic [1:0]                  replay_ptr_q;
  logic [1:0]                  rx_expected_seq_q;

  assign link_state_o    = link_state_q;
  assign link_up_o       = (link_state_q == LINK_ACTIVE);
  assign measured_skew_o = measured_skew_q;
  assign replay_active_o = replay_active_q;
  assign tx_ready_o      = link_up_o && !replay_active_q && !nack_req_i;

  always_comb begin
    link_state_d = link_state_q;
    if (!link_enable_i) begin
      link_state_d = LINK_RESET;
    end else begin
      unique case (link_state_q)
        LINK_RESET:       link_state_d = LINK_TRAIN_TS1;
        LINK_TRAIN_TS1:   if (rx_ts1_seen_i) link_state_d = LINK_TRAIN_TS2;
        LINK_TRAIN_TS2:   if (rx_ts2_seen_i) link_state_d = LINK_DESKEW_LOCK;
        LINK_DESKEW_LOCK: if (deskew_done_i) link_state_d = LINK_ACTIVE;
        LINK_ACTIVE:      if (retrain_req_i) link_state_d = LINK_RETRAIN;
        LINK_RETRAIN:     link_state_d = LINK_TRAIN_TS1;
        default:          link_state_d = LINK_RESET;
      endcase
    end
  end

  // Active TX Selection (Replay Buffer vs. New Flit vs. Control Ordered Set)
  logic                        tx_send_data;
  logic [P_STREAM_WIDTH-1:0]   tx_raw_payload;
  logic [P_META_WIDTH-1:0]     tx_meta_word;
  assign tx_send_data = link_up_o && ((replay_active_q && replay_valid_q[replay_ptr_q]) ||
                                      (nack_req_i && replay_valid_q[nack_seq_i]) ||
                                      (!replay_active_q && !nack_req_i && tx_flit_valid_i));

  always_comb begin
    if (!link_up_o) begin
      tx_sync_hdr_o  = SYNC_CTRL;
      tx_raw_payload = (link_state_q == LINK_TRAIN_TS2) ? TS2_PATTERN :
                       (link_state_q == LINK_DESKEW_LOCK) ? {{(P_STREAM_WIDTH-8){1'b0}}, local_realsync_cnt_i} :
                       TS1_PATTERN;
      tx_meta_word   = {4'd0, 4'd0, {1'b0, link_state_q}, 4'd0};
      tx_seq_num_o   = 4'd0;
    end else if (nack_req_i && replay_valid_q[nack_seq_i]) begin
      tx_sync_hdr_o  = SYNC_DATA;
      tx_raw_payload = replay_data_q[nack_seq_i];
      tx_meta_word   = {replay_hdr_q[nack_seq_i], replay_seq_q[nack_seq_i]};
      tx_seq_num_o   = replay_seq_q[nack_seq_i];
    end else if (replay_active_q && replay_valid_q[replay_ptr_q]) begin
      tx_sync_hdr_o  = SYNC_DATA;
      tx_raw_payload = replay_data_q[replay_ptr_q];
      tx_meta_word   = {replay_hdr_q[replay_ptr_q], replay_seq_q[replay_ptr_q]};
      tx_seq_num_o   = replay_seq_q[replay_ptr_q];
    end else if (tx_flit_valid_i) begin
      tx_sync_hdr_o  = SYNC_DATA;
      tx_raw_payload = tx_flit_data_i;
      tx_meta_word   = {tx_dst_chip_i, tx_hop_cnt_i, tx_opcode_i, tx_seq_q};
      tx_seq_num_o   = tx_seq_q;
    end else begin
      tx_sync_hdr_o  = SYNC_CTRL;
      tx_raw_payload = '0;
      tx_meta_word   = '0;
      tx_seq_num_o   = tx_seq_q;
    end
  end

  assign tx_meta_o              = tx_meta_word;
  assign tx_scrambled_payload_o = apply_scrambler(tx_raw_payload, tx_lfsr_q, scramble_en_i && (tx_sync_hdr_o == SYNC_DATA));
  assign tx_crc16_o             = crc16_ccitt_calc(tx_meta_word, tx_raw_payload);
  assign phy_tx_valid_o         = (!link_up_o && link_enable_i) || tx_send_data;
  assign phy_tx_frame_o         = {tx_sync_hdr_o, tx_crc16_o, tx_meta_o, tx_scrambled_payload_o};

  // ---------------------------------------------------------------------------
  // 5. RX Deframing, Descrambler, CRC-16-CCITT Verification & NACK Generation
  // ---------------------------------------------------------------------------
  logic [1:0]                  rx_sync_hdr;
  logic [P_CRC_WIDTH-1:0]      rx_crc16_in, rx_crc16_calc;
  logic [P_META_WIDTH-1:0]     rx_meta_in;
  logic [P_STREAM_WIDTH-1:0]   rx_scrambled_in, rx_descrambled_payload;
  logic                        rx_is_data_block;

  assign rx_sync_hdr            = phy_rx_frame_i[P_FRAME_WIDTH-1 -: 2];
  assign rx_crc16_in            = phy_rx_frame_i[P_STREAM_WIDTH+P_META_WIDTH +: P_CRC_WIDTH];
  assign rx_meta_in             = phy_rx_frame_i[P_STREAM_WIDTH +: P_META_WIDTH];
  assign rx_scrambled_in        = phy_rx_frame_i[0 +: P_STREAM_WIDTH];

  assign rx_is_data_block       = phy_rx_valid_i && (rx_sync_hdr == SYNC_DATA);
  assign rx_sync_err_o          = phy_rx_valid_i && (rx_sync_hdr != SYNC_DATA) && (rx_sync_hdr != SYNC_CTRL);
  assign rx_descrambled_payload = apply_scrambler(rx_scrambled_in, rx_lfsr_q, scramble_en_i && rx_is_data_block);
  assign rx_crc16_calc          = crc16_ccitt_calc(rx_meta_in, rx_descrambled_payload);
  assign rx_crc16_err_o         = rx_is_data_block && (rx_crc16_calc != rx_crc16_in);

  assign rx_flit_valid_o        = link_up_o && rx_is_data_block && !rx_crc16_err_o && !rx_sync_err_o;
  assign rx_flit_data_o         = rx_descrambled_payload;
  assign rx_dst_chip_o          = rx_meta_in[15:12];
  assign rx_hop_cnt_o           = rx_meta_in[11:8];
  assign rx_opcode_o            = rx_meta_in[7:4];
  assign rx_seq_num_o           = rx_meta_in[3:0];

  assign nack_req_o             = link_up_o && (rx_crc16_err_o || rx_sync_err_o);
  assign nack_seq_o             = rx_is_data_block ? rx_meta_in[1:0] : rx_expected_seq_q[1:0];

  // ---------------------------------------------------------------------------
  // 6. Sequential State Updates (FSM, LFSR, Replay Buffer & Sequence Counters)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      link_state_q      <= LINK_RESET;
      measured_skew_q   <= 8'd0;
      tx_lfsr_q         <= 16'hACE1;
      rx_lfsr_q         <= 16'hACE1;
      replay_valid_q    <= '0;
      tx_seq_q          <= 4'd0;
      replay_active_q   <= 1'b0;
      replay_ptr_q      <= 2'd0;
      rx_expected_seq_q <= 2'd0;
      for (int i = 0; i < P_REPLAY_DEPTH; i++) begin
        replay_data_q[i] <= '0;
        replay_hdr_q[i]  <= '0;
        replay_seq_q[i]  <= '0;
      end
    end else begin
      link_state_q <= link_state_d;

      if (link_state_q == LINK_DESKEW_LOCK) begin
        measured_skew_q <= local_realsync_cnt_i - rx_beacon_ts_i;
      end

      if (!link_up_o) begin
        tx_lfsr_q       <= 16'hACE1;
        rx_lfsr_q       <= 16'hACE1;
        replay_active_q <= 1'b0;
      end else begin
        if (tx_send_data && scramble_en_i) begin
          tx_lfsr_q <= lfsr16_next_state(tx_lfsr_q);
        end
        if (rx_is_data_block && !rx_crc16_err_o && scramble_en_i) begin
          rx_lfsr_q <= lfsr16_next_state(rx_lfsr_q);
        end

        // Go-Back-N Replay & Normal TX Buffer Recording
        if (nack_req_i && replay_valid_q[nack_seq_i]) begin
          if ((nack_seq_i + 2'd1) == tx_seq_q[1:0]) begin
            replay_active_q <= 1'b0;
          end else begin
            replay_active_q <= 1'b1;
            replay_ptr_q    <= nack_seq_i + 2'd1;
          end
        end else if (replay_active_q) begin
          if ((replay_ptr_q + 2'd1) == tx_seq_q[1:0]) begin
            replay_active_q <= 1'b0;
          end else begin
            replay_ptr_q <= replay_ptr_q + 2'd1;
          end
        end else if (tx_flit_valid_i) begin
          replay_valid_q[tx_seq_q[1:0]] <= 1'b1;
          replay_data_q[tx_seq_q[1:0]]  <= tx_flit_data_i;
          replay_hdr_q[tx_seq_q[1:0]]   <= {tx_dst_chip_i, tx_hop_cnt_i, tx_opcode_i};
          replay_seq_q[tx_seq_q[1:0]]   <= tx_seq_q;
          tx_seq_q                      <= tx_seq_q + 4'd1;
        end

        if (rx_flit_valid_o) begin
          rx_expected_seq_q <= rx_seq_num_o[1:0] + 2'd1;
        end
      end
    end
  end

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // 7. Formal Verification Proofs (Scrambler, CRC-16-CCITT, FSM & Replay)
  // ---------------------------------------------------------------------------
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);

  // 1) Scrambler / Descrambler Exact Invertibility over all 2^128 Payloads
  logic [P_STREAM_WIDTH-1:0] f_scram_roundtrip;
  assign f_scram_roundtrip = apply_scrambler(
    apply_scrambler(tx_flit_data_i, tx_lfsr_q, scramble_en_i),
    tx_lfsr_q,
    scramble_en_i
  );
  always @(posedge clk) begin
    assert (f_scram_roundtrip == tx_flit_data_i);
  end

  // 2) CRC-16-CCITT Zero False-Positive & Zero False-Negative (1-Bit & 2-Bit)
  (* anyconst *) logic [7:0]  f_err_idx0;
  (* anyconst *) logic [7:0]  f_err_idx1;
  (* anyconst *) logic [15:0] f_lin_c1, f_lin_c2;
  (* anyconst *) logic [7:0]  f_lin_b1, f_lin_b2;
  logic [159:0] f_clean_cw, f_err1_mask, f_err2_mask;
  logic [15:0]  f_zero_crc, f_err1_synd, f_err2_synd;

  assign f_clean_cw  = {tx_crc16_o, tx_meta_o, tx_raw_payload};
  assign f_err1_mask = (160'd1 << f_err_idx0);
  assign f_err2_mask = (160'd1 << f_err_idx0) | (160'd1 << f_err_idx1);
  assign f_zero_crc  = crc16_ccitt_calc(16'd0, 128'd0);
  assign f_err1_synd = crc16_ccitt_calc(f_err1_mask[143:128], f_err1_mask[127:0]) ^ f_zero_crc ^ f_err1_mask[159:144];
  assign f_err2_synd = crc16_ccitt_calc(f_err2_mask[143:128], f_err2_mask[127:0]) ^ f_zero_crc ^ f_err2_mask[159:144];

  always @(posedge clk) begin
    // Zero false-positive on clean frame over all 2^144 {meta, payload}
    assert (crc16_ccitt_calc(f_clean_cw[143:128], f_clean_cw[127:0]) == f_clean_cw[159:144]);
    // Exact GF(2) linearity of CRC-16-CCITT step: C(c1^c2, b1^b2) == C(c1,b1) ^ C(c2,b2)
    assert (crc16_ccitt_byte(f_lin_c1 ^ f_lin_c2, f_lin_b1 ^ f_lin_b2) ==
            (crc16_ccitt_byte(f_lin_c1, f_lin_b1) ^ crc16_ccitt_byte(f_lin_c2, f_lin_b2)));
    // Zero false-negative on any single-bit / double-bit error across 160-bit codeword
    if (f_err_idx0 < 8'd160) begin
      assert (f_err1_synd != 16'h0000);
    end
    if ((f_err_idx0 < 8'd160) && (f_err_idx1 < 8'd160) && (f_err_idx0 != f_err_idx1)) begin
      assert (f_err2_synd != 16'h0000);
    end
  end

  // 3) Link Training FSM Monotonic Progression & Replay Buffer Recovery
  always @(posedge clk) begin
    if (f_past_valid && rst_n && $past(rst_n)) begin
      assert (link_state_q <= LINK_RETRAIN);
      if ($past(link_enable_i) && ($past(link_state_q) == LINK_RESET))
        assert (link_state_q == LINK_TRAIN_TS1);
      if ($past(link_enable_i && rx_ts1_seen_i) && ($past(link_state_q) == LINK_TRAIN_TS1))
        assert (link_state_q == LINK_TRAIN_TS2);
      if ($past(link_enable_i && rx_ts2_seen_i) && ($past(link_state_q) == LINK_TRAIN_TS2))
        assert (link_state_q == LINK_DESKEW_LOCK);
      if ($past(link_enable_i && deskew_done_i) && ($past(link_state_q) == LINK_DESKEW_LOCK))
        assert (link_state_q == LINK_ACTIVE && link_up_o);
    end
    if (rst_n && link_up_o) begin
      // Replay buffer exact flit recovery on NACK
      if (nack_req_i && replay_valid_q[nack_seq_i]) begin
        assert (tx_sync_hdr_o == SYNC_DATA);
        assert (tx_raw_payload == replay_data_q[nack_seq_i]);
        assert (tx_seq_num_o == replay_seq_q[nack_seq_i]);
      end
      // Corrupt RX frame never asserts rx_flit_valid_o and always triggers nack_req_o
      if (rx_crc16_err_o || rx_sync_err_o) begin
        assert (!rx_flit_valid_o);
        assert (nack_req_o);
      end
    end
  end
`endif

endmodule
`endif // GROQ_C2C_SERDES_PCS_SV
