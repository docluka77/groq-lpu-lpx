// =============================================================================
// Module: groq_mem_slice
// Description: Groq LPU Superlane Memory Slice IP (Scalable up to 44 Banks).
//              Integrates:
//                - Dual Deterministic Tensor AGUs (Read AGU & Write AGU)
//                - Dual-Subword SECDED Hamming(72,64) Encoders & Decoders
//                  (128-bit Superlane Data + 16-bit ECC = 144-bit Physical Word)
//                - Multi-Banked Single-Port SRAM Macros (groq_sram_macro_sp)
//                  allowing simultaneous 1R + 1W across distinct banks
//                - Deterministic Compiler Schedule Bank-Conflict Detector
//                - Per-Bank Sleep/Retention Gating & MBIST Broadcast Controller
// =============================================================================
`default_nettype none

module groq_mem_slice #(
`ifdef FORMAL
    parameter int unsigned NUM_BANKS   = 4,
    parameter int unsigned BANK_ID_W   = 2,
    parameter int unsigned BANK_ADDR_W = 3,
    parameter int unsigned BANK_DEPTH  = 8,
`else
    parameter int unsigned NUM_BANKS   = 4,
    parameter int unsigned BANK_ID_W   = 2,
    parameter int unsigned BANK_ADDR_W = 10,
    parameter int unsigned BANK_DEPTH  = (1 << BANK_ADDR_W),
`endif
    parameter int unsigned LANES       = 16,
    parameter int unsigned ELEM_W      = 8,
    parameter int unsigned DATA_W      = LANES * ELEM_W, // 128-bit superlane slice
    parameter int unsigned SUBWORDS    = DATA_W / 64,    // 2 x 64b SECDED lanes
    parameter int unsigned CODE_W      = SUBWORDS * 72,  // 144-bit physical word
    parameter int unsigned BWE_W       = DATA_W / 8      // 16 byte-write enables
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // Read AGU Configuration & Step Control
    input  wire                        rd_agu_cfg_load,
    input  wire  [1:0]                 rd_agu_mode,
    input  wire  [BANK_ADDR_W-1:0]     rd_agu_base,
    input  wire  [BANK_ADDR_W-1:0]     rd_agu_stride0,
    input  wire  [BANK_ADDR_W-1:0]     rd_agu_stride1,
    input  wire  [BANK_ADDR_W-1:0]     rd_agu_count0,
    input  wire  [BANK_ADDR_W-1:0]     rd_agu_count1,
    input  wire                        rd_agu_use,

    // Write AGU Configuration & Step Control
    input  wire                        wr_agu_cfg_load,
    input  wire  [1:0]                 wr_agu_mode,
    input  wire  [BANK_ADDR_W-1:0]     wr_agu_base,
    input  wire  [BANK_ADDR_W-1:0]     wr_agu_stride0,
    input  wire  [BANK_ADDR_W-1:0]     wr_agu_stride1,
    input  wire  [BANK_ADDR_W-1:0]     wr_agu_count0,
    input  wire  [BANK_ADDR_W-1:0]     wr_agu_count1,
    input  wire                        wr_agu_use,

    // Stream Write Port (Stream Register File -> SRAM Slice)
    input  wire                        stream_in_valid,
    input  wire  [BANK_ID_W-1:0]       stream_in_bank,
    input  wire  [BANK_ADDR_W-1:0]     stream_in_addr,
    input  wire  [DATA_W-1:0]          stream_in_data,
    input  wire  [BWE_W-1:0]           stream_in_bwe_n,

    // Stream Read Request & Output Port (SRAM Slice -> Stream Register File)
    input  wire                        rd_req_valid,
    input  wire  [BANK_ID_W-1:0]       rd_req_bank,
    input  wire  [BANK_ADDR_W-1:0]     rd_req_addr,
    output logic                       stream_out_valid,
    output logic [DATA_W-1:0]          stream_out_data,

    // Per-Bank Power Management, Redundancy Repair & MBIST Controls
    input  wire  [NUM_BANKS-1:0]       bank_slp_n,
    input  wire  [NUM_BANKS-1:0]       bank_ds_n,
    input  wire  [NUM_BANKS-1:0]       bank_sd_n,
    input  wire  [NUM_BANKS-1:0]       bank_repair_en,
    input  wire  [BANK_ADDR_W-1:0]     bank_repair_addr,
    input  wire                        mbist_en,
    output logic                       mbist_done,
    output logic                       mbist_fail,

    // Fault Injection & Telemetry / Schedule Diagnostic Outputs
    input  wire                        err_inject_en,
    input  wire  [CODE_W-1:0]          err_inject_mask,
    output logic                       bank_conflict_error,
    output logic                       ecc_single_err,
    output logic                       ecc_double_err,
    output logic [15:0]                ecc_syndrome,
    output logic                       rd_tile_done,
    output logic                       wr_tile_done
);

    // -------------------------------------------------------------------------
    // Dual Deterministic Tensor AGUs (Read Stream & Write Stream)
    // -------------------------------------------------------------------------
    logic [BANK_ADDR_W-1:0] rd_agu_addr_out;
    logic                   rd_agu_addr_valid;
    logic [BANK_ADDR_W-1:0] rd_agu_idx0, rd_agu_idx1;
    logic                   rd_agu_wrap, rd_agu_busy;

    groq_mem_agu #(
        .ADDR_W  (BANK_ADDR_W),
        .COUNT_W (BANK_ADDR_W)
    ) u_rd_agu (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_load         (rd_agu_cfg_load),
        .cfg_mode         (rd_agu_mode),
        .base_addr        (rd_agu_base),
        .stride_0         (rd_agu_stride0),
        .stride_1         (rd_agu_stride1),
        .count_0          (rd_agu_count0),
        .count_1          (rd_agu_count1),
        .step_en          (rd_req_valid && rd_agu_use),
        .gather_offset_in (rd_req_addr),
        .addr_out         (rd_agu_addr_out),
        .addr_valid       (rd_agu_addr_valid),
        .idx_0_out        (rd_agu_idx0),
        .idx_1_out        (rd_agu_idx1),
        .inner_wrap       (rd_agu_wrap),
        .tile_done        (rd_tile_done),
        .agu_busy         (rd_agu_busy)
    );

    logic [BANK_ADDR_W-1:0] wr_agu_addr_out;
    logic                   wr_agu_addr_valid;
    logic [BANK_ADDR_W-1:0] wr_agu_idx0, wr_agu_idx1;
    logic                   wr_agu_wrap, wr_agu_busy;

    groq_mem_agu #(
        .ADDR_W  (BANK_ADDR_W),
        .COUNT_W (BANK_ADDR_W)
    ) u_wr_agu (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_load         (wr_agu_cfg_load),
        .cfg_mode         (wr_agu_mode),
        .base_addr        (wr_agu_base),
        .stride_0         (wr_agu_stride0),
        .stride_1         (wr_agu_stride1),
        .count_0          (wr_agu_count0),
        .count_1          (wr_agu_count1),
        .step_en          (stream_in_valid && wr_agu_use),
        .gather_offset_in (stream_in_addr),
        .addr_out         (wr_agu_addr_out),
        .addr_valid       (wr_agu_addr_valid),
        .idx_0_out        (wr_agu_idx0),
        .idx_1_out        (wr_agu_idx1),
        .inner_wrap       (wr_agu_wrap),
        .tile_done        (wr_tile_done),
        .agu_busy         (wr_agu_busy)
    );

    wire _unused_agu = &{1'b0, rd_agu_addr_valid, rd_agu_idx0, rd_agu_idx1, rd_agu_wrap, rd_agu_busy,
                               wr_agu_addr_valid, wr_agu_idx0, wr_agu_idx1, wr_agu_wrap, wr_agu_busy};

    wire [BANK_ADDR_W-1:0] eff_rd_addr = rd_agu_use ? rd_agu_addr_out : rd_req_addr;
    wire [BANK_ADDR_W-1:0] eff_wr_addr = wr_agu_use ? wr_agu_addr_out : stream_in_addr;

    // -------------------------------------------------------------------------
    // Deterministic Compiler Schedule Bank-Conflict Detector
    // Simultaneous Read and Write to the SAME single-port bank is flagged
    // -------------------------------------------------------------------------
    always_comb begin
        bank_conflict_error = rd_req_valid && stream_in_valid && (rd_req_bank == stream_in_bank);
    end

    // Track read bank and read validity (1-cycle synchronous SRAM read pipeline)
    logic                 rd_pipe_valid_q;
    logic [BANK_ID_W-1:0] rd_pipe_bank_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pipe_valid_q <= 1'b0;
            rd_pipe_bank_q  <= '0;
        end else begin
            // On bank conflict, Write takes priority and conflicting Read is suppressed
            rd_pipe_valid_q <= rd_req_valid && !bank_conflict_error && !mbist_en &&
                               bank_slp_n[rd_req_bank] && bank_ds_n[rd_req_bank] && bank_sd_n[rd_req_bank];
            rd_pipe_bank_q  <= rd_req_bank;
        end
    end

    // -------------------------------------------------------------------------
    // Dual-Subword SECDED Hamming(72,64) Encoders & Decoders (2 x 64b = 128b)
    // -------------------------------------------------------------------------
    logic [CODE_W-1:0] wr_codeword;
    logic [CODE_W-1:0] rd_codeword_mux;
    logic [CODE_W-1:0] rd_codeword_injected;
    logic [1:0]        sub_single_err;
    logic [1:0]        sub_double_err;

    assign rd_codeword_injected = err_inject_en ? (rd_codeword_mux ^ err_inject_mask) : rd_codeword_mux;

    genvar s;
    generate
        for (s = 0; s < SUBWORDS; s++) begin : gen_secded
            logic [7:0]  unused_ecc_out;
            logic        unused_val_out;
            groq_sram_ecc_secded #(
                .PIPELINE (1'b0)
            ) u_secded (
                .clk                 (clk),
                .rst_n               (rst_n),
                .valid_in            (rd_pipe_valid_q),
                .data_in             (stream_in_data[s*64 +: 64]),
                .ecc_out             (unused_ecc_out),
                .codeword_out        (wr_codeword[s*72 +: 72]),
                .codeword_in         (rd_codeword_injected[s*72 +: 72]),
                .valid_out           (unused_val_out),
                .data_corrected      (stream_out_data[s*64 +: 64]),
                .syndrome            (ecc_syndrome[s*8 +: 8]),
                .single_err_detected (sub_single_err[s]),
                .double_err_detected (sub_double_err[s])
            );
            wire _unused_ecc = &{1'b0, unused_ecc_out, unused_val_out};
        end
    endgenerate

    assign stream_out_valid = rd_pipe_valid_q;
    assign ecc_single_err   = rd_pipe_valid_q && (|sub_single_err);
    assign ecc_double_err   = rd_pipe_valid_q && (|sub_double_err);

    // -------------------------------------------------------------------------
    // Multi-Bank Single-Port SRAM Array (NUM_BANKS x SUBWORDS x 72b Macros)
    // -------------------------------------------------------------------------
    logic [CODE_W-1:0]    bank_rdata      [0:NUM_BANKS-1];
    logic [NUM_BANKS-1:0] bank_mbist_done;
    logic [NUM_BANKS-1:0] bank_mbist_fail;

    genvar b, w;
    generate
        for (b = 0; b < NUM_BANKS; b++) begin : gen_banks
            wire is_wr_bank = stream_in_valid && (stream_in_bank == BANK_ID_W'(b));
            wire is_rd_bank = rd_req_valid    && (rd_req_bank    == BANK_ID_W'(b)) && !is_wr_bank;
            wire bank_ce_n  = ~(is_wr_bank || is_rd_bank);
            wire bank_we_n  = ~is_wr_bank;
            wire [BANK_ADDR_W-1:0] bank_addr = is_wr_bank ? eff_wr_addr : eff_rd_addr;

            logic [SUBWORDS-1:0] sub_bist_done;
            logic [SUBWORDS-1:0] sub_bist_fail;

            for (w = 0; w < SUBWORDS; w++) begin : gen_sub_macro
                logic       unused_rval;
                logic [1:0] unused_pwr;
                logic       unused_rdy;
                // Replicate 8-bit data byte-write enable + 1-bit ECC write enable
                wire [8:0] sub_bwe_n = {(&stream_in_bwe_n[w*8 +: 8]), stream_in_bwe_n[w*8 +: 8]};

                groq_sram_macro_sp #(
                    .ADDR_W (BANK_ADDR_W),
                    .DEPTH  (BANK_DEPTH),
                    .DATA_W (64),
                    .ECC_W  (8)
                ) u_sram_macro (
                    .clk         (clk),
                    .rst_n       (rst_n),
                    .ce_n        (bank_ce_n),
                    .we_n        (bank_we_n),
                    .bwe_n       (sub_bwe_n),
                    .addr        (bank_addr),
                    .wdata       (wr_codeword[w*72 +: 72]),
                    .rdata       (bank_rdata[b][w*72 +: 72]),
                    .rvalid      (unused_rval),
                    .slp_n       (bank_slp_n[b]),
                    .ds_n        (bank_ds_n[b]),
                    .sd_n        (bank_sd_n[b]),
                    .pwr_mode    (unused_pwr),
                    .sram_ready  (unused_rdy),
                    .repair_en   (bank_repair_en[b]),
                    .repair_addr (bank_repair_addr),
                    .mbist_en    (mbist_en),
                    .mbist_done  (sub_bist_done[w]),
                    .mbist_fail  (sub_bist_fail[w])
                );
                wire _unused_macro = &{1'b0, unused_rval, unused_pwr, unused_rdy};
            end
            assign bank_mbist_done[b] = &sub_bist_done;
            assign bank_mbist_fail[b] = |sub_bist_fail;
        end
    endgenerate

    assign rd_codeword_mux = bank_rdata[rd_pipe_bank_q];
    assign mbist_done      = &bank_mbist_done;
    assign mbist_fail      = |bank_mbist_fail;

`ifdef FORMAL
    logic f_past_valid;
    logic f_was_conflict_free_read;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_past_valid             <= 1'b0;
            f_was_conflict_free_read <= 1'b0;
        end else begin
            f_past_valid             <= 1'b1;
            f_was_conflict_free_read <= rd_req_valid && !bank_conflict_error && !mbist_en &&
                                        bank_slp_n[rd_req_bank] && bank_ds_n[rd_req_bank] && bank_sd_n[rd_req_bank];
        end
    end

    always_comb begin
        // 1. Bank conflict detector exact equivalence
        assert(bank_conflict_error == (rd_req_valid && stream_in_valid && (rd_req_bank == stream_in_bank)));
        // 2. Simultaneous 1R + 1W across distinct banks never triggers bank conflict
        if (rd_req_valid && stream_in_valid && (rd_req_bank != stream_in_bank)) begin
            assert(!bank_conflict_error);
        end
        // 3. Deterministic 1-cycle read pipeline latency
        if (f_past_valid && rst_n) begin
            assert(stream_out_valid == f_was_conflict_free_read);
        end
    end
`endif

endmodule
`default_nettype wire
