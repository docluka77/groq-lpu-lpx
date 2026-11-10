// =============================================================================
// File: groq_sram_mem_if.sv
// Description: SystemVerilog Verification Interface for Groq LPU Superlane
//              Memory Slice IP (groq_mem_slice) under Accellera IEEE 1800.2-2020 UVM
// =============================================================================
`timescale 1ns/1ps

interface groq_sram_mem_if #(
    parameter int unsigned NUM_BANKS   = 4,
    parameter int unsigned BANK_ID_W   = 2,
    parameter int unsigned BANK_ADDR_W = 10,
    parameter int unsigned DATA_W      = 128,
    parameter int unsigned CODE_W      = 144,
    parameter int unsigned BWE_W       = 16
) (
    input logic clk
);
    logic                   rst_n = 1'b0;

    // Read AGU Configuration & Step Control
    logic                   rd_agu_cfg_load = 1'b0;
    logic [1:0]             rd_agu_mode     = 2'b00;
    logic [BANK_ADDR_W-1:0] rd_agu_base     = '0;
    logic [BANK_ADDR_W-1:0] rd_agu_stride0  = '0;
    logic [BANK_ADDR_W-1:0] rd_agu_stride1  = '0;
    logic [BANK_ADDR_W-1:0] rd_agu_count0   = '0;
    logic [BANK_ADDR_W-1:0] rd_agu_count1   = '0;
    logic                   rd_agu_use      = 1'b0;

    // Write AGU Configuration & Step Control
    logic                   wr_agu_cfg_load = 1'b0;
    logic [1:0]             wr_agu_mode     = 2'b00;
    logic [BANK_ADDR_W-1:0] wr_agu_base     = '0;
    logic [BANK_ADDR_W-1:0] wr_agu_stride0  = '0;
    logic [BANK_ADDR_W-1:0] wr_agu_stride1  = '0;
    logic [BANK_ADDR_W-1:0] wr_agu_count0   = '0;
    logic [BANK_ADDR_W-1:0] wr_agu_count1   = '0;
    logic                   wr_agu_use      = 1'b0;

    // Stream Write Port
    logic                   stream_in_valid = 1'b0;
    logic [BANK_ID_W-1:0]   stream_in_bank  = '0;
    logic [BANK_ADDR_W-1:0] stream_in_addr  = '0;
    logic [DATA_W-1:0]      stream_in_data  = '0;
    logic [BWE_W-1:0]       stream_in_bwe_n = '0;

    // Stream Read Request & Output Port
    logic                   rd_req_valid    = 1'b0;
    logic [BANK_ID_W-1:0]   rd_req_bank     = '0;
    logic [BANK_ADDR_W-1:0] rd_req_addr     = '0;
    logic                   stream_out_valid;
    logic [DATA_W-1:0]      stream_out_data;

    // Per-Bank Power Management, Redundancy Repair & MBIST Controls
    logic [NUM_BANKS-1:0]   bank_slp_n       = {NUM_BANKS{1'b1}};
    logic [NUM_BANKS-1:0]   bank_ds_n        = {NUM_BANKS{1'b1}};
    logic [NUM_BANKS-1:0]   bank_sd_n        = {NUM_BANKS{1'b1}};
    logic [NUM_BANKS-1:0]   bank_repair_en   = '0;
    logic [BANK_ADDR_W-1:0] bank_repair_addr = '0;
    logic                   mbist_en         = 1'b0;
    logic                   mbist_done;
    logic                   mbist_fail;

    // Fault Injection & Schedule / ECC Telemetry Outputs
    logic                   err_inject_en    = 1'b0;
    logic [CODE_W-1:0]      err_inject_mask  = '0;
    logic                   bank_conflict_error;
    logic                   ecc_single_err;
    logic                   ecc_double_err;
    logic [15:0]            ecc_syndrome;
    logic                   rd_tile_done;
    logic                   wr_tile_done;

    // Verification Metadata for Cycle-Accurate Monitor & Scoreboard Tracking
    logic                   tx_sample        = 1'b0;
    int unsigned            tx_id            = 0;
    int unsigned            tx_phase         = 0;

endinterface
