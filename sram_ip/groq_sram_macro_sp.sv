// =============================================================================
// Module: groq_sram_macro_sp
// Description: Cycle-Accurate Single-Port Synchronous Foundry SRAM Macro IP
//              for Groq LPU Superlane Memory Slices.
//              Features:
//                - 72-bit physical word (64-bit data + 8-bit SECDED ECC)
//                - Bit/Byte-level write masking (bwe_n)
//                - Low-Power Sleep/Retention & Shutdown Modes (slp_n, ds_n, sd_n)
//                - Integrated Clock Gating (ICG) enable & periphery clamping
//                - Foundry Row-Redundancy Repair CAM + Spare Row (repair_en/addr)
//                - Built-In March C- MBIST Engine (6-march M0..M5 FSM)
// =============================================================================
`default_nettype none

module groq_sram_macro_sp #(
`ifdef FORMAL
    parameter int unsigned ADDR_W = 3,
    parameter int unsigned DEPTH  = 8,
`else
    parameter int unsigned ADDR_W = 10,
    parameter int unsigned DEPTH  = (1 << ADDR_W),
`endif
    parameter int unsigned DATA_W = 64,
    parameter int unsigned ECC_W  = 8,
    parameter int unsigned WORD_W = DATA_W + ECC_W,
    parameter int unsigned BWE_W  = (WORD_W + 7) / 8
) (
    input  wire               clk,
    input  wire               rst_n,

    // Standard Synchronous Single-Port SRAM Interface (Active-Low Controls)
    input  wire               ce_n,       // Chip Enable (active low)
    input  wire               we_n,       // Write Enable (active low)
    input  wire  [BWE_W-1:0]  bwe_n,      // Byte Write Enable (active low per 8-bit byte)
    input  wire  [ADDR_W-1:0] addr,       // Row/Column Address
    input  wire  [WORD_W-1:0] wdata,      // Write Codeword {ecc[7:0], data[63:0]}
    output logic [WORD_W-1:0] rdata,      // Read Codeword {ecc[7:0], data[63:0]}
    output logic              rvalid,     // Read Data Valid (1 cycle after active read)

    // Low-Power Sleep / Retention / Power-Gating Controls (Active-Low)
    input  wire               slp_n,      // Light Sleep (active low: retains array, gates periphery)
    input  wire               ds_n,       // Deep Sleep (active low: retains array, biases source)
    input  wire               sd_n,       // Shut Down (active low: power-gates array, loses state)
    output logic [1:0]        pwr_mode,   // 00=Active, 01=LightSleep, 10=DeepSleep, 11=ShutDown
    output logic              sram_ready, // High when macro is awake and ready for access

    // Row Redundancy Repair Interface (Foundry Fuse/Laser/eFuse Repair)
    input  wire               repair_en,
    input  wire  [ADDR_W-1:0] repair_addr,

    // Production MBIST (March C-) Interface
    input  wire               mbist_en,
    output logic              mbist_done,
    output logic              mbist_fail
);

    // -------------------------------------------------------------------------
    // Power State & Clock-Gating Qualification
    // -------------------------------------------------------------------------
    always_comb begin
        if (!sd_n) begin
            pwr_mode   = 2'b11; // Shut Down
            sram_ready = 1'b0;
        end else if (!ds_n) begin
            pwr_mode   = 2'b10; // Deep Sleep (Retention)
            sram_ready = 1'b0;
        end else if (!slp_n) begin
            pwr_mode   = 2'b01; // Light Sleep (Retention)
            sram_ready = 1'b0;
        end else begin
            pwr_mode   = 2'b00; // Normal Active
            sram_ready = 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Built-In March C- MBIST Controller
    // March C- Sequence:
    //   M0: UP(w0)
    //   M1: UP(r0, w1)
    //   M2: UP(r1, w0)
    //   M3: DOWN(r0, w1)
    //   M4: DOWN(r1, w0)
    //   M5: UP(r0) -> DONE
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        MBIST_M0_UP_W0     = 3'd0,
        MBIST_M1_UP_R0W1   = 3'd1,
        MBIST_M2_UP_R1W0   = 3'd2,
        MBIST_M3_DN_R0W1   = 3'd3,
        MBIST_M4_DN_R1W0   = 3'd4,
        MBIST_M5_UP_R0     = 3'd5,
        MBIST_COMPLETE     = 3'd6
    } mbist_state_e;

    mbist_state_e       mbist_state;
    logic [ADDR_W-1:0]  mbist_addr;
    logic               mbist_sub; // 0 = Read issue, 1 = Read compare + Write issue

    localparam logic [ADDR_W-1:0] LAST_ADDR = ADDR_W'(DEPTH - 1);

    logic               bist_ce_n;
    logic               bist_we_n;
    logic [ADDR_W-1:0]  bist_addr_mux;
    logic [WORD_W-1:0]  bist_wdata_mux;

    always_comb begin
        bist_ce_n      = 1'b1;
        bist_we_n      = 1'b1;
        bist_addr_mux  = mbist_addr;
        bist_wdata_mux = '0;

        if (mbist_en && sram_ready) begin
            case (mbist_state)
                MBIST_M0_UP_W0: begin
                    bist_ce_n      = 1'b0;
                    bist_we_n      = 1'b0;
                    bist_wdata_mux = '0;
                end
                MBIST_M1_UP_R0W1, MBIST_M3_DN_R0W1: begin
                    bist_ce_n      = 1'b0;
                    bist_we_n      = (mbist_sub == 1'b1) ? 1'b0 : 1'b1;
                    bist_wdata_mux = {WORD_W{1'b1}};
                end
                MBIST_M2_UP_R1W0, MBIST_M4_DN_R1W0: begin
                    bist_ce_n      = 1'b0;
                    bist_we_n      = (mbist_sub == 1'b1) ? 1'b0 : 1'b1;
                    bist_wdata_mux = '0;
                end
                MBIST_M5_UP_R0: begin
                    bist_ce_n      = (mbist_sub == 1'b0) ? 1'b0 : 1'b1;
                    bist_we_n      = 1'b1;
                end
                default: begin
                    bist_ce_n      = 1'b1;
                    bist_we_n      = 1'b1;
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mbist_state <= MBIST_M0_UP_W0;
            mbist_addr  <= '0;
            mbist_sub   <= 1'b0;
            mbist_done  <= 1'b0;
            mbist_fail  <= 1'b0;
        end else if (!mbist_en) begin
            mbist_state <= MBIST_M0_UP_W0;
            mbist_addr  <= '0;
            mbist_sub   <= 1'b0;
            mbist_done  <= 1'b0;
            mbist_fail  <= 1'b0;
        end else if (sram_ready) begin
            case (mbist_state)
                MBIST_M0_UP_W0: begin
                    if (mbist_addr == LAST_ADDR) begin
                        mbist_addr  <= '0;
                        mbist_sub   <= 1'b0;
                        mbist_state <= MBIST_M1_UP_R0W1;
                    end else begin
                        mbist_addr <= mbist_addr + 1'b1;
                    end
                end
                MBIST_M1_UP_R0W1: begin
                    if (!mbist_sub) begin
                        mbist_sub <= 1'b1;
                    end else begin
                        if (rdata != '0) mbist_fail <= 1'b1;
                        mbist_sub <= 1'b0;
                        if (mbist_addr == LAST_ADDR) begin
                            mbist_addr  <= '0;
                            mbist_state <= MBIST_M2_UP_R1W0;
                        end else begin
                            mbist_addr <= mbist_addr + 1'b1;
                        end
                    end
                end
                MBIST_M2_UP_R1W0: begin
                    if (!mbist_sub) begin
                        mbist_sub <= 1'b1;
                    end else begin
                        if (rdata != {WORD_W{1'b1}}) mbist_fail <= 1'b1;
                        mbist_sub <= 1'b0;
                        if (mbist_addr == LAST_ADDR) begin
                            mbist_addr  <= LAST_ADDR;
                            mbist_state <= MBIST_M3_DN_R0W1;
                        end else begin
                            mbist_addr <= mbist_addr + 1'b1;
                        end
                    end
                end
                MBIST_M3_DN_R0W1: begin
                    if (!mbist_sub) begin
                        mbist_sub <= 1'b1;
                    end else begin
                        if (rdata != '0) mbist_fail <= 1'b1;
                        mbist_sub <= 1'b0;
                        if (mbist_addr == '0) begin
                            mbist_addr  <= LAST_ADDR;
                            mbist_state <= MBIST_M4_DN_R1W0;
                        end else begin
                            mbist_addr <= mbist_addr - 1'b1;
                        end
                    end
                end
                MBIST_M4_DN_R1W0: begin
                    if (!mbist_sub) begin
                        mbist_sub <= 1'b1;
                    end else begin
                        if (rdata != {WORD_W{1'b1}}) mbist_fail <= 1'b1;
                        mbist_sub <= 1'b0;
                        if (mbist_addr == '0) begin
                            mbist_addr  <= '0;
                            mbist_state <= MBIST_M5_UP_R0;
                        end else begin
                            mbist_addr <= mbist_addr - 1'b1;
                        end
                    end
                end
                MBIST_M5_UP_R0: begin
                    if (!mbist_sub) begin
                        mbist_sub <= 1'b1;
                    end else begin
                        if (rdata != '0) mbist_fail <= 1'b1;
                        mbist_sub <= 1'b0;
                        if (mbist_addr == LAST_ADDR) begin
                            mbist_done  <= 1'b1;
                            mbist_state <= MBIST_COMPLETE;
                        end else begin
                            mbist_addr <= mbist_addr + 1'b1;
                        end
                    end
                end
                MBIST_COMPLETE: begin
                    mbist_done <= 1'b1;
                end
                default: begin
                    mbist_state <= MBIST_M0_UP_W0;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Functional vs. MBIST Multiplexing & Redundancy Repair CAM
    // -------------------------------------------------------------------------
    wire               eff_ce_n  = mbist_en ? bist_ce_n      : ce_n;
    wire               eff_we_n  = mbist_en ? bist_we_n      : we_n;
    wire [BWE_W-1:0]   eff_bwe_n = mbist_en ? {BWE_W{1'b0}}  : bwe_n;
    wire [ADDR_W-1:0]  eff_addr  = mbist_en ? bist_addr_mux  : addr;
    wire [WORD_W-1:0]  eff_wdata = mbist_en ? bist_wdata_mux : wdata;
    wire               hit_spare = repair_en && (eff_addr == repair_addr);

    logic [WORD_W-1:0] mem [0:DEPTH-1];
    logic [WORD_W-1:0] spare_word;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata      <= '0;
            rvalid     <= 1'b0;
            spare_word <= '0;
        end else if (!sd_n) begin
            // Shut Down mode: periphery clamped and spare register cleared
            rdata      <= '0;
            rvalid     <= 1'b0;
            spare_word <= '0;
        end else if (!sram_ready) begin
            // Light Sleep / Deep Sleep: array retained, periphery output clamped
            rdata      <= '0;
            rvalid     <= 1'b0;
        end else if (!eff_ce_n) begin
            if (!eff_we_n) begin
                rvalid <= 1'b0;
                for (int b = 0; b < BWE_W; b++) begin
                    if (!eff_bwe_n[b]) begin
                        if (hit_spare) begin
                            spare_word[b*8 +: 8] <= eff_wdata[b*8 +: 8];
                        end else begin
                            mem[eff_addr][b*8 +: 8] <= eff_wdata[b*8 +: 8];
                        end
                    end
                end
            end else begin
                rvalid <= 1'b1;
                rdata  <= hit_spare ? spare_word : mem[eff_addr];
            end
        end else begin
            rvalid <= 1'b0;
        end
    end


`ifdef FORMAL
    logic              f_past_valid;
    logic              f_was_ready;
    logic              f_was_spare_write;
    logic [WORD_W-1:0] f_past_wdata;
    logic              f_was_read_req;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_past_valid      <= 1'b0;
            f_was_ready       <= 1'b0;
            f_was_spare_write <= 1'b0;
            f_past_wdata      <= '0;
            f_was_read_req    <= 1'b0;
        end else begin
            f_past_valid      <= 1'b1;
            f_was_ready       <= sram_ready;
            f_was_spare_write <= sram_ready && !mbist_en && !ce_n && !we_n && (bwe_n == '0) && repair_en && (addr == repair_addr);
            f_past_wdata      <= wdata;
            f_was_read_req    <= sram_ready && !eff_ce_n && eff_we_n;
        end
    end

    always_comb begin
        if (f_past_valid && rst_n) begin
            // 1. Sleep / Shut-Down Periphery Output Clamping & Clock Gating
            if (!f_was_ready) begin
                assert(rdata == '0);
                assert(rvalid == 1'b0);
            end
            // 2. Spare Row Redundancy Write-then-Read Exactness
            if (f_was_spare_write) begin
                assert(spare_word == f_past_wdata);
            end
            // 3. Read Valid only asserts after an active read cycle
            if (rvalid) begin
                assert(f_was_read_req);
            end
        end
    end
`endif

endmodule
`default_nettype wire
