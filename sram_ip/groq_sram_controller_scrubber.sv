// =============================================================================
// Module: groq_sram_controller_scrubber
// Description: Stage 20 Multi-Bank SRAM Controller with Cycle-Stealing
//              Background Dual-SECDED Scrubber & eFuse Row-Repair Loader.
//              Protects a 4-bank x 144-bit (128b data + 16b Hamming(72,64)x2)
//              SRAM subsystem with 100% zero-stall VLIW/DMA foreground priority,
//              background single-bit soft-error healing, and DED capture.
// =============================================================================
`default_nettype none

module groq_sram_controller_scrubber #(
    parameter int unsigned P_NUM_BANKS = 4,
    parameter int unsigned P_BANK_W    = 2,
    parameter int unsigned P_ADDR_W    = 6
) (
    input  wire                                  clk,
    input  wire                                  rst_n,

    // Boot eFuse Row-Repair Loader FSM Interface
    input  wire                                  efuse_load_req_i,
    input  wire  [P_BANK_W-1:0]                  efuse_bank_i,
    input  wire  [P_ADDR_W-1:0]                  efuse_bad_addr_i,
    output logic [P_NUM_BANKS-1:0]               bank_repair_en_o,
    output logic [P_NUM_BANKS-1:0][P_ADDR_W-1:0] bank_repair_addr_o,
    output logic                                 efuse_load_ack_o,

    // Foreground Deterministic VLIW Read Port (100% Priority, 0 Stall)
    input  wire                                  vliw_rd_en_i,
    input  wire  [P_BANK_W-1:0]                  vliw_rd_bank_i,
    input  wire  [P_ADDR_W-1:0]                  vliw_rd_addr_i,
    output logic                                 vliw_rd_valid_o,
    output logic [127:0]                         vliw_rd_data_o,
    output logic                                 vliw_rd_sec_err_o,
    output logic                                 vliw_rd_ded_err_o,
    output logic                                 vliw_rd_repaired_row_hit_o,

    // Foreground Deterministic VLIW Write Port (100% Priority, 0 Stall)
    input  wire                                  vliw_wr_en_i,
    input  wire  [P_BANK_W-1:0]                  vliw_wr_bank_i,
    input  wire  [P_ADDR_W-1:0]                  vliw_wr_addr_i,
    input  wire  [127:0]                         vliw_wr_data_i,

    // Host DMA Write Port (Foreground Priority over Scrubber)
    input  wire                                  dma_wr_en_i,
    input  wire  [P_BANK_W-1:0]                  dma_wr_bank_i,
    input  wire  [P_ADDR_W-1:0]                  dma_wr_addr_i,
    input  wire  [127:0]                         dma_wr_data_i,

    // Cycle-Stealing Background SECDED Scrubber Control & Telemetry
    input  wire                                  scrub_enable_i,
    output logic                                 scrub_rd_fire_o,
    output logic                                 scrub_wb_fire_o,
    output logic [P_BANK_W-1:0]                  scrub_active_bank_o,
    output logic [P_ADDR_W-1:0]                  scrub_active_addr_o,
    output logic [15:0]                          scrub_corrected_cnt_o,
    output logic                                 scrub_ded_alert_o,
    output logic [P_BANK_W-1:0]                  first_ded_bank_o,
    output logic [P_ADDR_W-1:0]                  first_ded_addr_o,

    // Live Soft-Error Radiation (SER) Fault Injection Port
    input  wire                                  ser_inject_en_i,
    input  wire  [P_BANK_W-1:0]                  ser_inject_bank_i,
    input  wire  [P_ADDR_W-1:0]                  ser_inject_addr_i,
    input  wire  [143:0]                         ser_inject_mask_i
);

    localparam int unsigned DEPTH = (1 << P_ADDR_W);

    // 4-Bank x DEPTH x 144-bit Physical SECDED Codeword Storage Array
    logic [143:0] mem_q [0:P_NUM_BANKS-1][0:DEPTH-1];

    // -------------------------------------------------------------------------
    // 1. Boot eFuse Row-Repair Loader FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_repair_en_o   <= '0;
            bank_repair_addr_o <= '0;
            efuse_load_ack_o   <= 1'b0;
        end else begin
            efuse_load_ack_o <= efuse_load_req_i;
            if (efuse_load_req_i) begin
                bank_repair_en_o[efuse_bank_i]   <= 1'b1;
                bank_repair_addr_o[efuse_bank_i] <= efuse_bad_addr_i;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. Dual-Subword Hamming(72,64) SECDED Encoders & Decoders
    // -------------------------------------------------------------------------
    logic [71:0]  vliw_wr_cw_lo_c, vliw_wr_cw_hi_c;
    logic [71:0]  dma_wr_cw_lo_c,  dma_wr_cw_hi_c;
    logic [143:0] vliw_wr_cw_c,    dma_wr_cw_c;

    logic [143:0] vliw_rd_raw_cw_q;
    logic [63:0]  vliw_rd_corr_lo_c, vliw_rd_corr_hi_c;
    logic         vliw_sec_lo_c, vliw_sec_hi_c;
    logic         vliw_ded_lo_c, vliw_ded_hi_c;

    logic [143:0] scrub_raw_cw_c;
    logic [63:0]  scrub_corr_lo_c, scrub_corr_hi_c;
    logic [71:0]  scrub_clean_lo_c, scrub_clean_hi_c;
    logic         scrub_sec_lo_c, scrub_sec_hi_c;
    logic         scrub_ded_lo_c, scrub_ded_hi_c;

    logic [7:0]   unused_ecc_0, unused_ecc_1, unused_ecc_2, unused_ecc_3, unused_ecc_4, unused_ecc_5;
    logic [7:0]   unused_syn_0, unused_syn_1, unused_syn_2, unused_syn_3, unused_syn_4, unused_syn_5;
    logic         unused_val_0, unused_val_1, unused_val_2, unused_val_3, unused_val_4, unused_val_5;
    logic [63:0]  unused_dat_4, unused_dat_5;
    logic         unused_sec_4, unused_sec_5, unused_ded_4, unused_ded_5;

    // Pair A: VLIW Write Encode + VLIW Read Decode
    groq_sram_ecc_secded #(.PIPELINE(1'b0)) u_ecc_vliw_lo (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_in            (1'b1),
        .data_in             (vliw_wr_data_i[63:0]),
        .ecc_out             (unused_ecc_0),
        .codeword_out        (vliw_wr_cw_lo_c),
        .codeword_in         (vliw_rd_raw_cw_q[71:0]),
        .valid_out           (unused_val_0),
        .data_corrected      (vliw_rd_corr_lo_c),
        .syndrome            (unused_syn_0),
        .single_err_detected (vliw_sec_lo_c),
        .double_err_detected (vliw_ded_lo_c)
    );

    groq_sram_ecc_secded #(.PIPELINE(1'b0)) u_ecc_vliw_hi (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_in            (1'b1),
        .data_in             (vliw_wr_data_i[127:64]),
        .ecc_out             (unused_ecc_1),
        .codeword_out        (vliw_wr_cw_hi_c),
        .codeword_in         (vliw_rd_raw_cw_q[143:72]),
        .valid_out           (unused_val_1),
        .data_corrected      (vliw_rd_corr_hi_c),
        .syndrome            (unused_syn_1),
        .single_err_detected (vliw_sec_hi_c),
        .double_err_detected (vliw_ded_hi_c)
    );

    // Pair B: DMA Write Encode + Background Scrubber Read Decode
    groq_sram_ecc_secded #(.PIPELINE(1'b0)) u_ecc_scrub_lo (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_in            (1'b1),
        .data_in             (dma_wr_data_i[63:0]),
        .ecc_out             (unused_ecc_2),
        .codeword_out        (dma_wr_cw_lo_c),
        .codeword_in         (scrub_raw_cw_c[71:0]),
        .valid_out           (unused_val_2),
        .data_corrected      (scrub_corr_lo_c),
        .syndrome            (unused_syn_2),
        .single_err_detected (scrub_sec_lo_c),
        .double_err_detected (scrub_ded_lo_c)
    );

    groq_sram_ecc_secded #(.PIPELINE(1'b0)) u_ecc_scrub_hi (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_in            (1'b1),
        .data_in             (dma_wr_data_i[127:64]),
        .ecc_out             (unused_ecc_3),
        .codeword_out        (dma_wr_cw_hi_c),
        .codeword_in         (scrub_raw_cw_c[143:72]),
        .valid_out           (unused_val_3),
        .data_corrected      (scrub_corr_hi_c),
        .syndrome            (unused_syn_3),
        .single_err_detected (scrub_sec_hi_c),
        .double_err_detected (scrub_ded_hi_c)
    );

    // Pair C: Scrubber Corrected Data Re-Encoder (heals both Data & ECC parity bits)
    groq_sram_ecc_secded #(.PIPELINE(1'b0)) u_ecc_reenc_lo (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_in            (1'b1),
        .data_in             (scrub_corr_lo_c),
        .ecc_out             (unused_ecc_4),
        .codeword_out        (scrub_clean_lo_c),
        .codeword_in         (72'd0),
        .valid_out           (unused_val_4),
        .data_corrected      (unused_dat_4),
        .syndrome            (unused_syn_4),
        .single_err_detected (unused_sec_4),
        .double_err_detected (unused_ded_4)
    );

    groq_sram_ecc_secded #(.PIPELINE(1'b0)) u_ecc_reenc_hi (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_in            (1'b1),
        .data_in             (scrub_corr_hi_c),
        .ecc_out             (unused_ecc_5),
        .codeword_out        (scrub_clean_hi_c),
        .codeword_in         (72'd0),
        .valid_out           (unused_val_5),
        .data_corrected      (unused_dat_5),
        .syndrome            (unused_syn_5),
        .single_err_detected (unused_sec_5),
        .double_err_detected (unused_ded_5)
    );

    wire _unused_ecc_sigs = &{1'b0,
        unused_ecc_0, unused_ecc_1, unused_ecc_2, unused_ecc_3, unused_ecc_4, unused_ecc_5,
        unused_syn_0, unused_syn_1, unused_syn_2, unused_syn_3, unused_syn_4, unused_syn_5,
        unused_val_0, unused_val_1, unused_val_2, unused_val_3, unused_val_4, unused_val_5,
        unused_dat_4, unused_dat_5, unused_sec_4, unused_sec_5, unused_ded_4, unused_ded_5};

    // -------------------------------------------------------------------------
    // 3. Zero-Contention Bank Arbitration & Cycle-Stealing Background Scrubber
    // -------------------------------------------------------------------------
    logic [P_BANK_W-1:0] scrub_bank_q;
    logic [P_ADDR_W-1:0] scrub_addr_q;
    logic                wb_pending_q;
    logic [P_BANK_W-1:0] wb_bank_q;
    logic [P_ADDR_W-1:0] wb_addr_q;
    logic [143:0]        wb_clean_codeword_q;

    logic [P_NUM_BANKS-1:0] fg_bank_busy_c;
    logic                   fg_overwrites_wb_c;
    logic                   scrub_sec_any_c, scrub_ded_any_c;

    always_comb begin
        vliw_wr_cw_c = {vliw_wr_cw_hi_c, vliw_wr_cw_lo_c};
        dma_wr_cw_c  = {dma_wr_cw_hi_c,  dma_wr_cw_lo_c};

        for (int b = 0; b < P_NUM_BANKS; b++) begin
            fg_bank_busy_c[b] = (vliw_rd_en_i && (vliw_rd_bank_i == P_BANK_W'(b))) ||
                                (vliw_wr_en_i && (vliw_wr_bank_i == P_BANK_W'(b))) ||
                                (dma_wr_en_i  && (dma_wr_bank_i  == P_BANK_W'(b)));
        end

        fg_overwrites_wb_c = (vliw_wr_en_i && (vliw_wr_bank_i == wb_bank_q) && (vliw_wr_addr_i == wb_addr_q)) ||
                             (dma_wr_en_i  && (dma_wr_bank_i  == wb_bank_q) && (dma_wr_addr_i  == wb_addr_q)) ||
                             (ser_inject_en_i && (ser_inject_bank_i == wb_bank_q) && (ser_inject_addr_i == wb_addr_q));

        scrub_raw_cw_c  = mem_q[scrub_bank_q][scrub_addr_q];
        scrub_ded_any_c = scrub_ded_lo_c || scrub_ded_hi_c;
        scrub_sec_any_c = (scrub_sec_lo_c || scrub_sec_hi_c) && !scrub_ded_any_c;

        scrub_rd_fire_o     = 1'b0;
        scrub_wb_fire_o     = 1'b0;
        scrub_active_bank_o = scrub_bank_q;
        scrub_active_addr_o = scrub_addr_q;

        if (scrub_enable_i) begin
            if (wb_pending_q && !fg_overwrites_wb_c) begin
                scrub_active_bank_o = wb_bank_q;
                scrub_active_addr_o = wb_addr_q;
                if (!fg_bank_busy_c[wb_bank_q]) begin
                    scrub_wb_fire_o = 1'b1;
                end
            end else if (!wb_pending_q) begin
                scrub_active_bank_o = scrub_bank_q;
                scrub_active_addr_o = scrub_addr_q;
                if (!fg_bank_busy_c[scrub_bank_q]) begin
                    scrub_rd_fire_o = 1'b1;
                end
            end
        end

        vliw_rd_data_o    = {vliw_rd_corr_hi_c, vliw_rd_corr_lo_c};
        vliw_rd_sec_err_o = vliw_rd_valid_o && (vliw_sec_lo_c || vliw_sec_hi_c);
        vliw_rd_ded_err_o = vliw_rd_valid_o && (vliw_ded_lo_c || vliw_ded_hi_c);
    end

    // -------------------------------------------------------------------------
    // 4. Sequential Array Updates, Scrubber FSM & Telemetry Registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int b = 0; b < P_NUM_BANKS; b++) begin
                for (int a = 0; a < DEPTH; a++) begin
                    mem_q[b][a] <= 144'd0;
                end
            end
            vliw_rd_valid_o            <= 1'b0;
            vliw_rd_raw_cw_q           <= 144'd0;
            vliw_rd_repaired_row_hit_o <= 1'b0;

            scrub_bank_q               <= '0;
            scrub_addr_q               <= '0;
            wb_pending_q               <= 1'b0;
            wb_bank_q                  <= '0;
            wb_addr_q                  <= '0;
            wb_clean_codeword_q        <= 144'd0;
            scrub_corrected_cnt_o      <= 16'd0;
            scrub_ded_alert_o          <= 1'b0;
            first_ded_bank_o           <= '0;
            first_ded_addr_o           <= '0;
        end else begin
            // Foreground VLIW Read (100% Priority, 1-cycle registered read data)
            vliw_rd_valid_o <= vliw_rd_en_i;
            if (vliw_rd_en_i) begin
                vliw_rd_raw_cw_q           <= mem_q[vliw_rd_bank_i][vliw_rd_addr_i];
                vliw_rd_repaired_row_hit_o <= bank_repair_en_o[vliw_rd_bank_i] &&
                                              (vliw_rd_addr_i == bank_repair_addr_o[vliw_rd_bank_i]);
            end else begin
                vliw_rd_repaired_row_hit_o <= 1'b0;
            end

            // Background Cycle-Stealing Scrubber Writeback (lowest write priority)
            if (scrub_wb_fire_o) begin
                mem_q[wb_bank_q][wb_addr_q] <= wb_clean_codeword_q;
                wb_pending_q                <= 1'b0;
            end else if (fg_overwrites_wb_c) begin
                wb_pending_q                <= 1'b0;
            end

            // Background Cycle-Stealing Scrubber Read & Pointer Advance
            if (scrub_rd_fire_o) begin
                {scrub_addr_q, scrub_bank_q} <= {scrub_addr_q, scrub_bank_q} + 1'b1;
                if (scrub_ded_any_c) begin
                    scrub_ded_alert_o <= 1'b1;
                    if (!scrub_ded_alert_o) begin
                        first_ded_bank_o <= scrub_bank_q;
                        first_ded_addr_o <= scrub_addr_q;
                    end
                end else if (scrub_sec_any_c) begin
                    wb_pending_q        <= 1'b1;
                    wb_bank_q           <= scrub_bank_q;
                    wb_addr_q           <= scrub_addr_q;
                    wb_clean_codeword_q <= {scrub_clean_hi_c, scrub_clean_lo_c};
                    if (scrub_corrected_cnt_o != 16'hFFFF) begin
                        scrub_corrected_cnt_o <= scrub_corrected_cnt_o + 16'd1;
                    end
                end
            end

            // Host DMA Write (Foreground Priority over Scrubber)
            if (dma_wr_en_i) begin
                mem_q[dma_wr_bank_i][dma_wr_addr_i] <= dma_wr_cw_c;
            end

            // Foreground VLIW Write (Highest Write Priority)
            if (vliw_wr_en_i) begin
                mem_q[vliw_wr_bank_i][vliw_wr_addr_i] <= vliw_wr_cw_c;
            end

            // Live Soft-Error Radiation (SER) Bit-Flip Fault Injection
            if (ser_inject_en_i) begin
                mem_q[ser_inject_bank_i][ser_inject_addr_i] <=
                    mem_q[ser_inject_bank_i][ser_inject_addr_i] ^ ser_inject_mask_i;
            end
        end
    end

`ifdef FORMAL
    logic                f_past_valid_q;
    logic                f_wb_fired_q;
    logic [P_BANK_W-1:0] f_wb_bank_q;
    logic [P_ADDR_W-1:0] f_wb_addr_q;
    logic [143:0]        f_wb_clean_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_past_valid_q <= 1'b0;
            f_wb_fired_q   <= 1'b0;
            f_wb_bank_q    <= '0;
            f_wb_addr_q    <= '0;
            f_wb_clean_q   <= 144'd0;
        end else begin
            f_past_valid_q <= 1'b1;
            f_wb_fired_q   <= scrub_wb_fire_o && !fg_overwrites_wb_c;
            f_wb_bank_q    <= wb_bank_q;
            f_wb_addr_q    <= wb_addr_q;
            f_wb_clean_q   <= wb_clean_codeword_q;
        end
    end

    always_comb begin
        // 1. Zero VLIW/DMA Contention: Scrubber never fires on a bank accessed by VLIW or DMA
        if (vliw_rd_en_i) begin
            assert(!(scrub_rd_fire_o && (scrub_active_bank_o == vliw_rd_bank_i)));
            assert(!(scrub_wb_fire_o && (scrub_active_bank_o == vliw_rd_bank_i)));
        end
        if (vliw_wr_en_i) begin
            assert(!(scrub_rd_fire_o && (scrub_active_bank_o == vliw_wr_bank_i)));
            assert(!(scrub_wb_fire_o && (scrub_active_bank_o == vliw_wr_bank_i)));
        end
        if (dma_wr_en_i) begin
            assert(!(scrub_rd_fire_o && (scrub_active_bank_o == dma_wr_bank_i)));
            assert(!(scrub_wb_fire_o && (scrub_active_bank_o == dma_wr_bank_i)));
        end
        // 2. Mutual Exclusion of Scrub Read and Scrub Writeback
        assert(!(scrub_rd_fire_o && scrub_wb_fire_o));
        // 3. Single-Bit Soft-Error Healing & Re-Encoded Codeword Parity Invariant
        assert((^scrub_clean_lo_c) == 1'b0);
        assert((^scrub_clean_hi_c) == 1'b0);
        if (rst_n && wb_pending_q) begin
            assert((^wb_clean_codeword_q[71:0])   == 1'b0);
            assert((^wb_clean_codeword_q[143:72]) == 1'b0);
        end
        if (rst_n && f_past_valid_q && f_wb_fired_q) begin
            assert(mem_q[f_wb_bank_q][f_wb_addr_q] == f_wb_clean_q);
            assert((^mem_q[f_wb_bank_q][f_wb_addr_q][71:0])   == 1'b0);
            assert((^mem_q[f_wb_bank_q][f_wb_addr_q][143:72]) == 1'b0);
        end
    end
`endif

endmodule
`default_nettype wire

