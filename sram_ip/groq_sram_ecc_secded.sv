// =============================================================================
// Module: groq_sram_ecc_secded
// Description: Extended Hamming(72,64) SECDED Encoder & Decoder/Corrector IP
//              for Groq LPU On-Chip SRAM Macro & Superlane Memory Slices.
//              Guarantees 100% single-bit error correction (SEC) and 100%
//              double-bit error detection (DED) across all 72 codeword bits.
// =============================================================================
`default_nettype none

module groq_sram_ecc_secded #(
    parameter bit PIPELINE = 1'b0
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         valid_in,
    // Encoder path: 64-bit data -> 8-bit ECC + 72-bit codeword {ecc[7:0], data[63:0]}
    input  wire  [63:0] data_in,
    output logic [7:0]  ecc_out,
    output logic [71:0] codeword_out,
    // Decoder/Corrector path: 72-bit codeword -> 64-bit corrected data + flags
    input  wire  [71:0] codeword_in,
    output logic        valid_out,
    output logic [63:0] data_corrected,
    output logic [7:0]  syndrome,
    output logic        single_err_detected,
    output logic        double_err_detected
);

    // Packed 64x7-bit table of distinct non-power-of-two syndromes (popcount >= 2)
    localparam logic [64*7-1:0] POS_MAP_PACKED = {
        7'd71, 7'd70, 7'd69, 7'd68, 7'd67, 7'd66, 7'd65, 7'd63,
        7'd62, 7'd61, 7'd60, 7'd59, 7'd58, 7'd57, 7'd56, 7'd55,
        7'd54, 7'd53, 7'd52, 7'd51, 7'd50, 7'd49, 7'd48, 7'd47,
        7'd46, 7'd45, 7'd44, 7'd43, 7'd42, 7'd41, 7'd40, 7'd39,
        7'd38, 7'd37, 7'd36, 7'd35, 7'd34, 7'd33, 7'd31, 7'd30,
        7'd29, 7'd28, 7'd27, 7'd26, 7'd25, 7'd24, 7'd23, 7'd22,
        7'd21, 7'd20, 7'd19, 7'd18, 7'd17, 7'd15, 7'd14, 7'd13,
        7'd12, 7'd11, 7'd10, 7'd9,  7'd7,  7'd6,  7'd5,  7'd3
    };

    // -------------------------------------------------------------------------
    // Combinational Encoder: data_in[63:0] -> ecc_comb[7:0], codeword_comb[71:0]
    // -------------------------------------------------------------------------
    logic [7:0]  ecc_comb;
    logic [71:0] codeword_comb;

    always_comb begin
        for (int k = 0; k < 7; k++) begin
            ecc_comb[k] = 1'b0;
            for (int i = 0; i < 64; i++) begin
                if (POS_MAP_PACKED[i*7 + k]) begin
                    ecc_comb[k] = ecc_comb[k] ^ data_in[i];
                end
            end
        end
        // Bit 7 is overall even parity across all 64 data bits + 7 Hamming bits
        ecc_comb[7]   = (^data_in) ^ (^ecc_comb[6:0]);
        codeword_comb = {ecc_comb, data_in};
    end

    // -------------------------------------------------------------------------
    // Combinational Decoder & SECDED Single-Bit Corrector
    // -------------------------------------------------------------------------
    logic [63:0] data_raw;
    logic [7:0]  ecc_raw;
    logic [6:0]  syn_low;
    logic        overall_par;
    logic [7:0]  syndrome_comb;
    logic [63:0] data_corr_comb;
    logic        single_err_comb;
    logic        double_err_comb;

    always_comb begin
        data_raw = codeword_in[63:0];
        ecc_raw  = codeword_in[71:64];

        for (int k = 0; k < 7; k++) begin
            syn_low[k] = ecc_raw[k];
            for (int i = 0; i < 64; i++) begin
                if (POS_MAP_PACKED[i*7 + k]) begin
                    syn_low[k] = syn_low[k] ^ data_raw[i];
                end
            end
        end

        overall_par     = ^codeword_in;
        syndrome_comb   = {overall_par, syn_low};
        single_err_comb = overall_par;
        double_err_comb = (~overall_par) & (|syn_low);

        for (int i = 0; i < 64; i++) begin
            if (overall_par && (syn_low == POS_MAP_PACKED[i*7 +: 7])) begin
                data_corr_comb[i] = ~data_raw[i];
            end else begin
                data_corr_comb[i] = data_raw[i];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Optional Pipeline Stage (PIPELINE=0: zero-latency combinational)
    // -------------------------------------------------------------------------
    generate
        if (PIPELINE) begin : gen_pipelined
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    ecc_out             <= 8'd0;
                    codeword_out        <= 72'd0;
                    valid_out           <= 1'b0;
                    data_corrected      <= 64'd0;
                    syndrome            <= 8'd0;
                    single_err_detected <= 1'b0;
                    double_err_detected <= 1'b0;
                end else begin
                    valid_out <= valid_in;
                    if (valid_in) begin
                        ecc_out             <= ecc_comb;
                        codeword_out        <= codeword_comb;
                        data_corrected      <= data_corr_comb;
                        syndrome            <= syndrome_comb;
                        single_err_detected <= single_err_comb;
                        double_err_detected <= double_err_comb;
                    end
                end
            end
        end else begin : gen_comb
            wire _unused_clk_rst = &{1'b0, clk, rst_n};
            always_comb begin
                ecc_out             = ecc_comb;
                codeword_out        = codeword_comb;
                valid_out           = valid_in;
                data_corrected      = data_corr_comb;
                syndrome            = syndrome_comb;
                single_err_detected = single_err_comb;
                double_err_detected = double_err_comb;
            end
        end
    endgenerate

`ifdef FORMAL
`ifndef FORMAL_SLICE_TOP
    // Formal Verification Proof Harness (Unbounded SAT across all 2^64 data & 2^72 masks)
    wire [71:0] err_mask   = codeword_in ^ codeword_comb;
    wire [71:0] err_clear1 = err_mask & (err_mask - 72'd1);
    wire [71:0] err_clear2 = err_clear1 & (err_clear1 - 72'd1);

    wire is_zero_err   = (err_mask == 72'd0);
    wire is_single_err = (err_mask != 72'd0) && (err_clear1 == 72'd0);
    wire is_double_err = (err_mask != 72'd0) && (err_clear1 != 72'd0) && (err_clear2 == 72'd0);

    always_comb begin
        // 1. Zero-error transparency
        if (is_zero_err) begin
            assert(data_corr_comb == data_in);
            assert(single_err_comb == 1'b0);
            assert(double_err_comb == 1'b0);
            assert(syndrome_comb == 8'd0);
        end
        // 2. Any 1-bit error in the 72-bit codeword is 100% detected and 100% corrected
        if (is_single_err) begin
            assert(single_err_comb == 1'b1);
            assert(double_err_comb == 1'b0);
            assert(data_corr_comb == data_in);
        end
        // 3. Any 2-bit error in the 72-bit codeword is 100% flagged as uncorrectable DED
        if (is_double_err) begin
            assert(double_err_comb == 1'b1);
            assert(single_err_comb == 1'b0);
            assert(syndrome_comb[6:0] != 7'd0);
        end
    end
`endif
`endif

endmodule
`default_nettype wire
