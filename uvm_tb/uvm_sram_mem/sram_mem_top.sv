// =============================================================================
// File: sram_mem_top.sv
// Description: Top-Level UVM Testbench Harness for Groq LPU Superlane Memory
//              Slice IP (groq_mem_slice) with +INJECT_DUT_BUG Qualification Mode
// =============================================================================
`timescale 1ns/1ps

module sram_mem_top;
    import uvm_pkg::*;
    import groq_sram_mem_uvm_pkg::*;

    bit clk = 1'b0;
    bit inject_dut_bug = 1'b0;

    groq_sram_mem_if vif(clk);

    logic [127:0] raw_stream_out_data;

    groq_mem_slice #(
        .NUM_BANKS   (4),
        .BANK_ID_W   (2),
        .BANK_ADDR_W (10),
        .BANK_DEPTH  (1024),
        .LANES       (16),
        .ELEM_W      (8)
    ) dut (
        .clk                 (clk),
        .rst_n               (vif.rst_n),
        .rd_agu_cfg_load     (vif.rd_agu_cfg_load),
        .rd_agu_mode         (vif.rd_agu_mode),
        .rd_agu_base         (vif.rd_agu_base),
        .rd_agu_stride0      (vif.rd_agu_stride0),
        .rd_agu_stride1      (vif.rd_agu_stride1),
        .rd_agu_count0       (vif.rd_agu_count0),
        .rd_agu_count1       (vif.rd_agu_count1),
        .rd_agu_use          (vif.rd_agu_use),
        .wr_agu_cfg_load     (vif.wr_agu_cfg_load),
        .wr_agu_mode         (vif.wr_agu_mode),
        .wr_agu_base         (vif.wr_agu_base),
        .wr_agu_stride0      (vif.wr_agu_stride0),
        .wr_agu_stride1      (vif.wr_agu_stride1),
        .wr_agu_count0       (vif.wr_agu_count0),
        .wr_agu_count1       (vif.wr_agu_count1),
        .wr_agu_use          (vif.wr_agu_use),
        .stream_in_valid     (vif.stream_in_valid),
        .stream_in_bank      (vif.stream_in_bank),
        .stream_in_addr      (vif.stream_in_addr),
        .stream_in_data      (vif.stream_in_data),
        .stream_in_bwe_n     (vif.stream_in_bwe_n),
        .rd_req_valid        (vif.rd_req_valid),
        .rd_req_bank         (vif.rd_req_bank),
        .rd_req_addr         (vif.rd_req_addr),
        .stream_out_valid    (vif.stream_out_valid),
        .stream_out_data     (raw_stream_out_data),
        .bank_slp_n          (vif.bank_slp_n),
        .bank_ds_n           (vif.bank_ds_n),
        .bank_sd_n           (vif.bank_sd_n),
        .bank_repair_en      (vif.bank_repair_en),
        .bank_repair_addr    (vif.bank_repair_addr),
        .mbist_en            (vif.mbist_en),
        .mbist_done          (vif.mbist_done),
        .mbist_fail          (vif.mbist_fail),
        .err_inject_en       (vif.err_inject_en),
        .err_inject_mask     (vif.err_inject_mask),
        .bank_conflict_error (vif.bank_conflict_error),
        .ecc_single_err      (vif.ecc_single_err),
        .ecc_double_err      (vif.ecc_double_err),
        .ecc_syndrome        (vif.ecc_syndrome),
        .rd_tile_done        (vif.rd_tile_done),
        .wr_tile_done        (vif.wr_tile_done)
    );

    // Fault-Injection Qualification Mode (+INJECT_DUT_BUG):
    // Corrupts post-ECC stream_out_data on valid read transactions to prove
    // that the UVM scoreboard + C++ DPI-C golden model catches real DUT bugs.
    assign vif.stream_out_data = (inject_dut_bug && vif.stream_out_valid && (vif.tx_id >= 32'd64 && vif.tx_id < 32'd80))
                               ? (raw_stream_out_data ^ 128'h0000_0000_0000_DEAD_0000_0000_0000_BEEF)
                               : raw_stream_out_data;

    always #5ns clk = ~clk;

    initial begin
        inject_dut_bug = $test$plusargs("INJECT_DUT_BUG");
        repeat (4) @(negedge clk);
        vif.rst_n = 1'b1;
    end

    initial begin
        uvm_config_db#(virtual groq_sram_mem_if)::set(null, "uvm_test_top.env.*", "vif", vif);
        run_test("sram_mem_test");
    end

    initial begin
        #500us;
        $fatal(1, "UVM_SRAM_TIMEOUT: bounded simulation expired");
    end

endmodule
