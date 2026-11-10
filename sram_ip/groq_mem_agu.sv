// =============================================================================
// Module: groq_mem_agu
// Description: Deterministic Tensor Address Generation Unit (AGU) for Groq LPU
//              Superlane Memory Slices.
//              Supports 4 compiler-scheduled addressing modes:
//                - 2'b00 (AGU_LINEAR_STRIDE): 1D strided stream access
//                - 2'b01 (AGU_2D_TILE):       2D nested tensor tile walk
//                - 2'b10 (AGU_KV_RING):       Circular KV-cache ring buffer
//                - 2'b11 (AGU_GATHER_SCATTER):Indexed gather/scatter offset
// =============================================================================
`default_nettype none

module groq_mem_agu #(
`ifdef FORMAL
    parameter int unsigned ADDR_W  = 4,
    parameter int unsigned COUNT_W = 4
`else
    parameter int unsigned ADDR_W  = 10,
    parameter int unsigned COUNT_W = 10
`endif
) (
    input  wire                clk,
    input  wire                rst_n,

    // Compiler-Scheduled Descriptor Load & Step Control
    input  wire                cfg_load,
    input  wire  [1:0]         cfg_mode,
    input  wire  [ADDR_W-1:0]  base_addr,
    input  wire  [ADDR_W-1:0]  stride_0,
    input  wire  [ADDR_W-1:0]  stride_1,
    input  wire  [COUNT_W-1:0] count_0,
    input  wire  [COUNT_W-1:0] count_1,

    // Execution Step & Gather/Scatter Index Input
    input  wire                step_en,
    input  wire  [ADDR_W-1:0]  gather_offset_in,

    // Generated Address & Deterministic Schedule Status Outputs
    output logic [ADDR_W-1:0]  addr_out,
    output logic               addr_valid,
    output logic [COUNT_W-1:0] idx_0_out,
    output logic [COUNT_W-1:0] idx_1_out,
    output logic               inner_wrap,
    output logic               tile_done,
    output logic               agu_busy
);

    localparam logic [1:0] AGU_LINEAR_STRIDE  = 2'b00;
    localparam logic [1:0] AGU_2D_TILE        = 2'b01;
    localparam logic [1:0] AGU_KV_RING        = 2'b10;
    localparam logic [1:0] AGU_GATHER_SCATTER = 2'b11;

    // Latched Descriptor Registers
    logic [1:0]         mode_q;
    logic [ADDR_W-1:0]  base_q;
    logic [ADDR_W-1:0]  stride0_q;
    logic [ADDR_W-1:0]  stride1_q;
    logic [COUNT_W-1:0] count0_q;
    logic [COUNT_W-1:0] count1_q;

    // Running Loop Counters & Accumulators
    logic [COUNT_W-1:0] idx0_q;
    logic [COUNT_W-1:0] idx1_q;
    logic [ADDR_W-1:0]  accum0_q;
    logic [ADDR_W-1:0]  accum1_q;
    logic               busy_q;

    // Guard against zero count descriptors (minimum bound = 1)
    wire [COUNT_W-1:0] eff_count_0 = (count_0 == '0) ? COUNT_W'(1) : count_0;
    wire [COUNT_W-1:0] eff_count_1 = (count_1 == '0) ? COUNT_W'(1) : count_1;
    wire [COUNT_W-1:0] safe_count0 = (count0_q == '0) ? COUNT_W'(1) : count0_q;
    wire [COUNT_W-1:0] safe_count1 = (count1_q == '0) ? COUNT_W'(1) : count1_q;

    wire last_0 = (idx0_q == (safe_count0 - 1'b1));
    wire last_1 = (mode_q == AGU_2D_TILE) ? (idx1_q == (safe_count1 - 1'b1)) : 1'b1;

    // Ring-buffer power-of-two mask derived from stride_1 in KV_RING mode (0 -> full mask)
    wire [ADDR_W-1:0] ring_mask = (stride1_q == '0) ? {ADDR_W{1'b1}} : stride1_q;

    // -------------------------------------------------------------------------
    // Combinational Address Generation (Zero-Stall Single-Cycle AGU Output)
    // -------------------------------------------------------------------------
    always_comb begin
        idx_0_out  = idx0_q;
        idx_1_out  = idx1_q;
        agu_busy   = busy_q;
        addr_valid = busy_q && step_en;
        inner_wrap = busy_q && step_en && last_0;
        tile_done  = busy_q && step_en && last_0 && last_1;

        case (mode_q)
            AGU_LINEAR_STRIDE: begin
                addr_out = base_q + accum0_q;
            end
            AGU_2D_TILE: begin
                addr_out = base_q + accum0_q + accum1_q;
            end
            AGU_KV_RING: begin
                addr_out = base_q + (accum0_q & ring_mask);
            end
            AGU_GATHER_SCATTER: begin
                addr_out = base_q + gather_offset_in;
            end
            default: begin
                addr_out = base_q;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Deterministic Loop Progression Registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_q    <= AGU_LINEAR_STRIDE;
            base_q    <= '0;
            stride0_q <= '0;
            stride1_q <= '0;
            count0_q  <= COUNT_W'(1);
            count1_q  <= COUNT_W'(1);
            idx0_q    <= '0;
            idx1_q    <= '0;
            accum0_q  <= '0;
            accum1_q  <= '0;
            busy_q    <= 1'b0;
        end else if (cfg_load) begin
            mode_q    <= cfg_mode;
            base_q    <= base_addr;
            stride0_q <= stride_0;
            stride1_q <= stride_1;
            count0_q  <= eff_count_0;
            count1_q  <= eff_count_1;
            idx0_q    <= '0;
            idx1_q    <= '0;
            accum0_q  <= '0;
            accum1_q  <= '0;
            busy_q    <= 1'b1;
        end else if (busy_q && step_en) begin
            if (last_0) begin
                idx0_q   <= '0;
                accum0_q <= '0;
                if (mode_q == AGU_2D_TILE) begin
                    if (last_1) begin
                        idx1_q   <= '0;
                        accum1_q <= '0;
                        busy_q   <= 1'b0;
                    end else begin
                        idx1_q   <= idx1_q + 1'b1;
                        accum1_q <= accum1_q + stride1_q;
                    end
                end else if (mode_q == AGU_KV_RING) begin
                    // Circular KV-cache ring buffer wraps continuously until reconfigured
                    busy_q <= 1'b1;
                end else begin
                    busy_q <= 1'b0;
                end
            end else begin
                idx0_q   <= idx0_q + 1'b1;
                accum0_q <= accum0_q + stride0_q;
            end
        end
    end

`ifdef FORMAL
    logic              f_past_valid;
    logic              f_was_cfg_load;
    logic [ADDR_W-1:0] f_past_base;
    logic              f_was_linear_step;
    logic [ADDR_W-1:0] f_past_addr;
    logic [ADDR_W-1:0] f_past_stride0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_past_valid      <= 1'b0;
            f_was_cfg_load    <= 1'b0;
            f_past_base       <= '0;
            f_was_linear_step <= 1'b0;
            f_past_addr       <= '0;
            f_past_stride0    <= '0;
        end else begin
            f_past_valid      <= 1'b1;
            f_was_cfg_load    <= cfg_load;
            f_past_base       <= base_addr;
            f_was_linear_step <= !cfg_load && busy_q && step_en && !last_0 &&
                                 ((mode_q == AGU_LINEAR_STRIDE) || (mode_q == AGU_2D_TILE));
            f_past_addr       <= addr_out;
            f_past_stride0    <= stride0_q;
        end
    end

    always_comb begin
        // 1. Loop count registers are strictly positive (>= 1)
        assert(safe_count0 >= COUNT_W'(1));
        assert(safe_count1 >= COUNT_W'(1));
        // 2. Coordinate indices never exceed configured bounds
        assert(idx0_q < safe_count0);
        assert(idx1_q < safe_count1);
        // 3. tile_done implies inner_wrap and addr_valid
        if (tile_done) begin
            assert(inner_wrap);
            assert(addr_valid);
        end
        if (f_past_valid && rst_n) begin
            // 4. After cfg_load, indices reset to 0 and linear/2D/ring address starts at base_addr
            if (f_was_cfg_load) begin
                assert(idx0_q == '0);
                assert(idx1_q == '0);
                assert(busy_q == 1'b1);
                if (mode_q != AGU_GATHER_SCATTER) begin
                    assert(addr_out == f_past_base);
                end
            end
            // 5. Non-wrapping inner step in Linear/2D mode advances address by exact stride_0
            if (f_was_linear_step) begin
                assert(addr_out == (f_past_addr + f_past_stride0));
            end
        end
    end
`endif

endmodule
`default_nettype wire
