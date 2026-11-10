// =============================================================================
// File: groq_sram_mem_uvm_pkg.sv
// Description: Accellera IEEE 1800.2-2020 UVM Verification Package for
//              Groq LPU Superlane Memory Slice IP (groq_mem_slice)
// =============================================================================
`timescale 1ns/1ps
`include "uvm_macros.svh"

package groq_sram_mem_uvm_pkg;
    import uvm_pkg::*;

    import "DPI-C" function void dpi_sram_reset();
    import "DPI-C" function void dpi_sram_set_status(int status);
    import "DPI-C" function int  dpi_sram_get_status();
    import "DPI-C" function int unsigned dpi_sram_get_calls();
    import "DPI-C" function longint unsigned dpi_sram_exp_rdata_lo();
    import "DPI-C" function longint unsigned dpi_sram_exp_rdata_hi();
    import "DPI-C" function int unsigned dpi_sram_exp_flags();
    import "DPI-C" function int unsigned dpi_sram_exp_addrs();
    import "DPI-C" function void dpi_sram_step(
        int unsigned rd_agu_cfg_load, int unsigned rd_agu_mode, int unsigned rd_agu_base,
        int unsigned rd_agu_stride0,  int unsigned rd_agu_stride1,
        int unsigned rd_agu_count0,   int unsigned rd_agu_count1,  int unsigned rd_agu_use,
        int unsigned wr_agu_cfg_load, int unsigned wr_agu_mode, int unsigned wr_agu_base,
        int unsigned wr_agu_stride0,  int unsigned wr_agu_stride1,
        int unsigned wr_agu_count0,   int unsigned wr_agu_count1,  int unsigned wr_agu_use,
        int unsigned stream_in_valid, int unsigned stream_in_bank, int unsigned stream_in_addr,
        longint unsigned stream_in_data_lo, longint unsigned stream_in_data_hi,
        int unsigned stream_in_bwe_n,
        int unsigned rd_req_valid,    int unsigned rd_req_bank,    int unsigned rd_req_addr,
        int unsigned bank_slp_n,      int unsigned bank_ds_n,      int unsigned bank_sd_n,
        int unsigned bank_repair_en,  int unsigned bank_repair_addr, int unsigned mbist_en,
        int unsigned err_inject_en,
        longint unsigned err_mask_s0_data, int unsigned err_mask_s0_ecc,
        longint unsigned err_mask_s1_data, int unsigned err_mask_s1_ecc
    );

    class sram_mem_seq_item extends uvm_sequence_item;
        `uvm_object_utils(sram_mem_seq_item)

        int unsigned tx_id    = 0;
        int unsigned tx_phase = 0;

        // Read AGU Controls
        bit        rd_agu_cfg_load = 0;
        bit [1:0]  rd_agu_mode     = 0;
        bit [9:0]  rd_agu_base     = 0;
        bit [9:0]  rd_agu_stride0  = 0;
        bit [9:0]  rd_agu_stride1  = 0;
        bit [9:0]  rd_agu_count0   = 1;
        bit [9:0]  rd_agu_count1   = 1;
        bit        rd_agu_use      = 0;

        // Write AGU Controls
        bit        wr_agu_cfg_load = 0;
        bit [1:0]  wr_agu_mode     = 0;
        bit [9:0]  wr_agu_base     = 0;
        bit [9:0]  wr_agu_stride0  = 0;
        bit [9:0]  wr_agu_stride1  = 0;
        bit [9:0]  wr_agu_count0   = 1;
        bit [9:0]  wr_agu_count1   = 1;
        bit        wr_agu_use      = 0;

        // Write Stream Request
        bit         stream_in_valid = 0;
        bit [1:0]   stream_in_bank  = 0;
        bit [9:0]   stream_in_addr  = 0;
        bit [127:0] stream_in_data  = '0;
        bit [15:0]  stream_in_bwe_n = 16'h0000;

        // Read Stream Request
        bit         rd_req_valid    = 0;
        bit [1:0]   rd_req_bank     = 0;
        bit [9:0]   rd_req_addr     = 0;

        // Power, Repair, MBIST & Fault Injection Controls
        bit [3:0]   bank_slp_n       = 4'hF;
        bit [3:0]   bank_ds_n        = 4'hF;
        bit [3:0]   bank_sd_n        = 4'hF;
        bit [3:0]   bank_repair_en   = 4'h0;
        bit [9:0]   bank_repair_addr = 10'd0;
        bit         mbist_en         = 0;
        bit         err_inject_en    = 0;
        bit [143:0] err_inject_mask  = '0;

        // Observed DUT Outputs
        logic         obs_stream_out_valid;
        logic [127:0] obs_stream_out_data;
        logic         obs_bank_conflict_error;
        logic         obs_ecc_single_err;
        logic         obs_ecc_double_err;
        logic [15:0]  obs_ecc_syndrome;
        logic         obs_rd_tile_done;
        logic         obs_wr_tile_done;
        logic         obs_mbist_done;
        logic         obs_mbist_fail;

        function new(string name = "sram_mem_seq_item");
            super.new(name);
        endfunction
    endclass

    typedef uvm_sequencer #(sram_mem_seq_item) sram_mem_sequencer;

    class sram_mem_sequence extends uvm_sequence #(sram_mem_seq_item);
        `uvm_object_utils(sram_mem_sequence)

        int unsigned next_id = 0;

        function new(string name = "sram_mem_sequence");
            super.new(name);
        endfunction

        function automatic bit [127:0] gen_data(int unsigned seed);
            bit [63:0] lo = 64'h9E37_79B9_7F4A_7C15 ^ (64'(seed) * 64'hBF58_476D_1CE4_E5B9);
            bit [63:0] hi = 64'hD1B5_4A32_D192_ED03 ^ (64'(seed + 32'h1234) * 64'h94D0_49BB_1331_11EB);
            return {hi, lo};
        endfunction

        task send_item(sram_mem_seq_item item, int unsigned phase_id);
            start_item(item);
            item.tx_id    = next_id++;
            item.tx_phase = phase_id;
            finish_item(item);
        endtask

        task body();
            sram_mem_seq_item it;

            // =================================================================
            // Phase 1: Full-Bank Initialization & Concurrent 1R+1W Streaming
            //          (640 transactions across all 4 banks + byte write masks)
            // =================================================================
            for (int b = 0; b < 4; b++) begin
                for (int a = 0; a < 64; a++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.stream_in_valid = 1;
                    it.stream_in_bank  = 2'(b);
                    it.stream_in_addr  = 10'(a * 7);
                    it.stream_in_data  = gen_data(b * 256 + a);
                    it.stream_in_bwe_n = 16'h0000;
                    if (b > 0) begin
                        it.rd_req_valid = 1;
                        it.rd_req_bank  = 2'(b - 1);
                        it.rd_req_addr  = 10'(a * 7);
                    end
                    send_item(it, 1);
                end
            end
            // Simultaneous 1R + 1W across all bank pairs + byte-masked writes
            for (int k = 0; k < 384; k++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.stream_in_valid = 1;
                it.stream_in_bank  = 2'(k & 3);
                it.stream_in_addr  = 10'((k % 64) * 7);
                it.stream_in_data  = (k % 8 == 0) ? {128{1'b1}} :
                                     (k % 8 == 1) ? 128'hAAAA_5555_AAAA_5555_5555_AAAA_5555_AAAA :
                                     gen_data(1000 + k);
                it.stream_in_bwe_n = (k % 16 == 15) ? 16'hFFFF : 16'h0000;
                it.rd_req_valid    = 1;
                it.rd_req_bank     = 2'((k + 1 + ((k >> 2) & 1)) & 3);
                it.rd_req_addr     = 10'(((k + 5) % 64) * 7);
                send_item(it, 1);
            end

            // =================================================================
            // Phase 2: AGU_LINEAR_STRIDE (Mode 2'b00) Write & Read Streams
            //          (320 transactions)
            // =================================================================
            for (int b = 0; b < 4; b++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.wr_agu_cfg_load = 1; it.wr_agu_mode = 2'b00;
                it.wr_agu_base     = 10'(16 + b * 32); it.wr_agu_stride0 = 10'd3;
                it.wr_agu_count0   = 10'd39;           it.wr_agu_count1  = 10'd1;
                it.rd_agu_cfg_load = 1; it.rd_agu_mode = 2'b00;
                it.rd_agu_base     = 10'(16 + b * 32); it.rd_agu_stride0 = 10'd3;
                it.rd_agu_count0   = 10'd39;           it.rd_agu_count1  = 10'd1;
                send_item(it, 2);

                for (int s = 0; s < 39; s++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.wr_agu_use      = 1;
                    it.stream_in_valid = 1;
                    it.stream_in_bank  = 2'(b);
                    it.stream_in_data  = gen_data(2000 + b * 64 + s);
                    send_item(it, 2);
                end
                for (int s = 0; s < 40; s++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.rd_agu_use   = 1;
                    it.rd_req_valid = 1;
                    it.rd_req_bank  = 2'(b);
                    send_item(it, 2);
                end
            end

            // =================================================================
            // Phase 3: AGU_2D_TILE (Mode 2'b01) Nested 2D Tensor Tile Walk
            //          (328 transactions)
            // =================================================================
            for (int b = 0; b < 4; b++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.wr_agu_cfg_load = 1; it.wr_agu_mode = 2'b01;
                it.wr_agu_base     = 10'(256 + b * 64);
                it.wr_agu_stride0  = 10'd2;  it.wr_agu_stride1 = 10'd16;
                it.wr_agu_count0   = 10'd8;  it.wr_agu_count1  = 10'd5;
                it.rd_agu_cfg_load = 1; it.rd_agu_mode = 2'b01;
                it.rd_agu_base     = 10'(256 + b * 64);
                it.rd_agu_stride0  = 10'd2;  it.rd_agu_stride1 = 10'd16;
                it.rd_agu_count0   = 10'd8;  it.rd_agu_count1  = 10'd5;
                send_item(it, 3);

                for (int s = 0; s < 40; s++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.wr_agu_use      = 1;
                    it.stream_in_valid = 1;
                    it.stream_in_bank  = 2'(b);
                    it.stream_in_data  = gen_data(3000 + b * 64 + s);
                    send_item(it, 3);
                end
                for (int s = 0; s < 41; s++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.rd_agu_use   = 1;
                    it.rd_req_valid = 1;
                    it.rd_req_bank  = 2'(b);
                    send_item(it, 3);
                end
            end

            // =================================================================
            // Phase 4: AGU_KV_RING (Mode 2'b10) Circular KV-Cache Ring Buffer
            //          (328 transactions, including zero-count / zero-mask guard)
            // =================================================================
            for (int b = 0; b < 4; b++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.wr_agu_cfg_load = 1; it.wr_agu_mode = 2'b10;
                it.wr_agu_base     = 10'(512 + b * 32);
                it.wr_agu_stride0  = 10'd1;
                it.wr_agu_stride1  = (b == 3) ? 10'd0 : 10'h00F;
                it.wr_agu_count0   = (b == 3) ? 10'd0 : 10'd16;
                it.wr_agu_count1   = 10'd0;
                it.rd_agu_cfg_load = 1; it.rd_agu_mode = 2'b10;
                it.rd_agu_base     = 10'(512 + b * 32);
                it.rd_agu_stride0  = 10'd1;
                it.rd_agu_stride1  = (b == 3) ? 10'd0 : 10'h00F;
                it.rd_agu_count0   = (b == 3) ? 10'd0 : 10'd16;
                it.rd_agu_count1   = 10'd0;
                send_item(it, 4);

                for (int s = 0; s < 40; s++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.wr_agu_use      = 1;
                    it.stream_in_valid = 1;
                    it.stream_in_bank  = 2'(b);
                    it.stream_in_data  = gen_data(4000 + b * 64 + s);
                    send_item(it, 4);
                end
                for (int s = 0; s < 41; s++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.rd_agu_use   = 1;
                    it.rd_req_valid = 1;
                    it.rd_req_bank  = 2'(b);
                    send_item(it, 4);
                end
            end

            // =================================================================
            // Phase 5: AGU_GATHER_SCATTER (Mode 2'b11) Indexed Gather/Scatter
            //          (328 transactions across all 10 address bits)
            // =================================================================
            for (int b = 0; b < 4; b++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.wr_agu_cfg_load = 1; it.wr_agu_mode = 2'b11;
                it.wr_agu_base     = 10'(b * 64);
                it.wr_agu_count0   = 10'd40; it.wr_agu_count1 = 10'd1;
                it.rd_agu_cfg_load = 1; it.rd_agu_mode = 2'b11;
                it.rd_agu_base     = 10'(b * 64);
                it.rd_agu_count0   = 10'd40; it.rd_agu_count1 = 10'd1;
                send_item(it, 5);

                for (int s = 0; s < 40; s++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.wr_agu_use      = 1;
                    it.stream_in_valid = 1;
                    it.stream_in_bank  = 2'(b);
                    it.stream_in_addr  = 10'((s * 23) ^ (1 << (s % 10)));
                    it.stream_in_data  = gen_data(5000 + b * 64 + s);
                    send_item(it, 5);
                end
                for (int s = 0; s < 41; s++) begin
                    it = sram_mem_seq_item::type_id::create("it");
                    it.rd_agu_use   = 1;
                    it.rd_req_valid = 1;
                    it.rd_req_bank  = 2'(b);
                    it.rd_req_addr  = 10'(((s % 40) * 23) ^ (1 << ((s % 40) % 10)));
                    send_item(it, 5);
                end
            end

            // =================================================================
            // Phase 6: Single-Bit SECDED Fault Injection (All 144 Codeword Bits
            //          + Dual Simultaneous Subword 1-Bit Errors -> 300 tx)
            // =================================================================
            for (int bit_idx = 0; bit_idx < 144; bit_idx++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.rd_req_valid    = 1;
                it.rd_req_bank     = 2'(bit_idx & 3);
                it.rd_req_addr     = 10'(16 + (bit_idx & 3) * 32 + ((bit_idx >> 2) % 39) * 3);
                it.err_inject_en   = 1;
                it.err_inject_mask = (144'd1 << bit_idx);
                send_item(it, 6);
            end
            for (int k = 0; k < 156; k++) begin
                int b0 = k % 72;
                int b1 = 72 + ((k * 11 + 7) % 72);
                it = sram_mem_seq_item::type_id::create("it");
                it.rd_req_valid    = 1;
                it.rd_req_bank     = 2'(k & 3);
                it.rd_req_addr     = 10'(16 + (k & 3) * 32 + ((k % 39) * 3));
                it.err_inject_en   = 1;
                it.err_inject_mask = (144'd1 << b0) | (144'd1 << b1);
                send_item(it, 6);
            end

            // =================================================================
            // Phase 7: Double-Bit SECDED Fault Injection (256 tx across both
            //          72-bit subwords: data+data, data+parity, parity+parity)
            // =================================================================
            for (int k = 0; k < 256; k++) begin
                int sub = k & 1;
                int b_a = (k >> 1) % 72;
                int b_b = (b_a + 1 + ((k >> 3) % 70)) % 72;
                if (b_b == b_a) b_b = (b_a + 1) % 72;
                it = sram_mem_seq_item::type_id::create("it");
                it.rd_req_valid    = 1;
                it.rd_req_bank     = 2'(k & 3);
                it.rd_req_addr     = 10'(16 + (k & 3) * 32 + ((k % 39) * 3));
                it.err_inject_en   = 1;
                it.err_inject_mask = (144'd1 << (sub * 72 + b_a)) |
                                     (144'd1 << (sub * 72 + b_b));
                send_item(it, 7);
            end

            // =================================================================
            // Phase 8: Row-Redundancy Repair, Sleep/Retention/ShutDown Modes,
            //          Same-Bank Conflict Detection, and March C- MBIST (260 tx)
            // =================================================================
            // 8A: Row-Redundancy Spare CAM Repair across all 4 banks (64 tx)
            for (int b = 0; b < 4; b++) begin
                for (int r = 0; r < 8; r++) begin
                    bit [9:0] r_addr = 10'(700 + b * 16 + r);
                    it = sram_mem_seq_item::type_id::create("it");
                    it.bank_repair_en   = (4'b0001 << b);
                    it.bank_repair_addr = r_addr;
                    it.stream_in_valid  = 1;
                    it.stream_in_bank   = 2'(b);
                    it.stream_in_addr   = r_addr;
                    it.stream_in_data   = gen_data(8000 + b * 16 + r);
                    send_item(it, 8);
                    it = sram_mem_seq_item::type_id::create("it");
                    it.bank_repair_en   = (4'b0001 << b);
                    it.bank_repair_addr = r_addr;
                    it.rd_req_valid     = 1;
                    it.rd_req_bank      = 2'(b);
                    it.rd_req_addr      = r_addr;
                    send_item(it, 8);
                end
            end

            // 8B: Same-Bank Conflict Detection (Write priority + Read suppressed, 64 tx)
            for (int k = 0; k < 64; k++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.stream_in_valid = 1;
                it.stream_in_bank  = 2'(k & 3);
                it.stream_in_addr  = 10'(800 + k);
                it.stream_in_data  = gen_data(8500 + k);
                it.rd_req_valid    = 1;
                it.rd_req_bank     = 2'(k & 3);
                it.rd_req_addr     = 10'(800 + k);
                send_item(it, 8);
            end
            for (int k = 0; k < 64; k++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.rd_req_valid = 1;
                it.rd_req_bank  = 2'(k & 3);
                it.rd_req_addr  = 10'(800 + k);
                send_item(it, 8);
            end

            // 8C: Light-Sleep, Deep-Sleep & Shut-Down Modes + Post-Wakeup Retention (20 tx)
            for (int b = 0; b < 4; b++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.bank_slp_n   = ~(4'b0001 << b);
                it.rd_req_valid = 1; it.rd_req_bank = 2'(b); it.rd_req_addr = 10'(800 + b);
                send_item(it, 8);
                it = sram_mem_seq_item::type_id::create("it");
                it.bank_ds_n    = ~(4'b0001 << b);
                it.rd_req_valid = 1; it.rd_req_bank = 2'(b); it.rd_req_addr = 10'(800 + b);
                send_item(it, 8);
                it = sram_mem_seq_item::type_id::create("it");
                it.rd_req_valid = 1; it.rd_req_bank = 2'(b); it.rd_req_addr = 10'(800 + b);
                send_item(it, 8);
                it = sram_mem_seq_item::type_id::create("it");
                it.bank_sd_n    = ~(4'b0001 << b);
                it.rd_req_valid = 1; it.rd_req_bank = 2'(b); it.rd_req_addr = 10'(700 + b * 16);
                send_item(it, 8);
                it = sram_mem_seq_item::type_id::create("it");
                it.bank_repair_en   = (4'b0001 << b);
                it.bank_repair_addr = 10'(700 + b * 16);
                it.rd_req_valid     = 1; it.rd_req_bank = 2'(b); it.rd_req_addr = 10'(700 + b * 16);
                send_item(it, 8);
            end

            // 8D: Full Production March C- MBIST Execution + Post-MBIST Readback (17 tx)
            it = sram_mem_seq_item::type_id::create("it");
            it.mbist_en = 1;
            send_item(it, 8);
            for (int k = 0; k < 16; k++) begin
                it = sram_mem_seq_item::type_id::create("it");
                it.rd_req_valid = 1;
                it.rd_req_bank  = 2'(k & 3);
                it.rd_req_addr  = 10'(k * 63);
                send_item(it, 8);
            end
        endtask
    endclass

    class sram_mem_driver extends uvm_driver #(sram_mem_seq_item);
        `uvm_component_utils(sram_mem_driver)

        virtual groq_sram_mem_if vif;
        int unsigned driven = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual groq_sram_mem_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "sram_mem_driver virtual interface missing")
        endfunction

        task run_phase(uvm_phase phase);
            sram_mem_seq_item item;
            wait (vif.rst_n === 1'b1);
            forever begin
                seq_item_port.get_next_item(item);
                @(negedge vif.clk);
                vif.rd_agu_cfg_load  = item.rd_agu_cfg_load;
                vif.rd_agu_mode      = item.rd_agu_mode;
                vif.rd_agu_base      = item.rd_agu_base;
                vif.rd_agu_stride0   = item.rd_agu_stride0;
                vif.rd_agu_stride1   = item.rd_agu_stride1;
                vif.rd_agu_count0    = item.rd_agu_count0;
                vif.rd_agu_count1    = item.rd_agu_count1;
                vif.rd_agu_use       = item.rd_agu_use;
                vif.wr_agu_cfg_load  = item.wr_agu_cfg_load;
                vif.wr_agu_mode      = item.wr_agu_mode;
                vif.wr_agu_base      = item.wr_agu_base;
                vif.wr_agu_stride0   = item.wr_agu_stride0;
                vif.wr_agu_stride1   = item.wr_agu_stride1;
                vif.wr_agu_count0    = item.wr_agu_count0;
                vif.wr_agu_count1    = item.wr_agu_count1;
                vif.wr_agu_use       = item.wr_agu_use;
                vif.stream_in_valid  = item.stream_in_valid;
                vif.stream_in_bank   = item.stream_in_bank;
                vif.stream_in_addr   = item.stream_in_addr;
                vif.stream_in_data   = item.stream_in_data;
                vif.stream_in_bwe_n  = item.stream_in_bwe_n;
                vif.rd_req_valid     = item.rd_req_valid;
                vif.rd_req_bank      = item.rd_req_bank;
                vif.rd_req_addr      = item.rd_req_addr;
                vif.bank_slp_n       = item.bank_slp_n;
                vif.bank_ds_n        = item.bank_ds_n;
                vif.bank_sd_n        = item.bank_sd_n;
                vif.bank_repair_en   = item.bank_repair_en;
                vif.bank_repair_addr = item.bank_repair_addr;
                vif.mbist_en         = item.mbist_en;
                vif.err_inject_en    = item.err_inject_en;
                vif.err_inject_mask  = item.err_inject_mask;
                vif.tx_id            = item.tx_id;
                vif.tx_phase         = item.tx_phase;
                if (item.mbist_en) begin
                    vif.tx_sample = 1'b0;
                    while (vif.mbist_done !== 1'b1) @(negedge vif.clk);
                    vif.tx_sample = 1'b1;
                end else begin
                    vif.tx_sample = 1'b1;
                end
                @(posedge vif.clk);
                #2ps;
                vif.tx_sample = 1'b0;
                driven++;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class sram_mem_monitor extends uvm_monitor;
        `uvm_component_utils(sram_mem_monitor)

        virtual groq_sram_mem_if vif;
        uvm_analysis_port #(sram_mem_seq_item) observed;
        int unsigned seen = 0;
        bit [1:0] cur_rd_agu_mode = 2'b00;
        bit [1:0] cur_wr_agu_mode = 2'b00;

        covergroup sram_mem_cg with function sample(
            bit         rd_val,
            bit [1:0]   rd_bank,
            bit         wr_val,
            bit [1:0]   wr_bank,
            bit [1:0]   r_agu_mode,
            bit [1:0]   w_agu_mode,
            bit         sec_err,
            bit         ded_err,
            bit         conflict_err,
            bit [1:0]   pwr_st,
            bit         rep_active,
            bit         mbist_pass
        );
            option.per_instance = 1;
            rd_bank_cp: coverpoint rd_bank iff (rd_val) {
                bins b0 = {2'd0}; bins b1 = {2'd1}; bins b2 = {2'd2}; bins b3 = {2'd3};
            }
            wr_bank_cp: coverpoint wr_bank iff (wr_val) {
                bins b0 = {2'd0}; bins b1 = {2'd1}; bins b2 = {2'd2}; bins b3 = {2'd3};
            }
            rd_agu_mode_cp: coverpoint r_agu_mode {
                bins linear_stride  = {2'b00};
                bins tile_2d        = {2'b01};
                bins kv_ring        = {2'b10};
                bins gather_scatter = {2'b11};
            }
            wr_agu_mode_cp: coverpoint w_agu_mode {
                bins linear_stride  = {2'b00};
                bins tile_2d        = {2'b01};
                bins kv_ring        = {2'b10};
                bins gather_scatter = {2'b11};
            }
            ecc_status_cp: coverpoint {ded_err, sec_err} {
                bins clean_0bit = {2'b00};
                bins sec_1bit   = {2'b01};
                bins ded_2bit   = {2'b10};
            }
            conflict_cp: coverpoint conflict_err {
                bins no_conflict   = {1'b0};
                bins bank_conflict = {1'b1};
            }
            pwr_state_cp: coverpoint pwr_st {
                bins active      = {2'd0};
                bins light_sleep = {2'd1};
                bins deep_sleep  = {2'd2};
                bins shut_down   = {2'd3};
            }
            repair_cp: coverpoint rep_active {
                bins normal_access   = {1'b0};
                bins repaired_access = {1'b1};
            }
            mbist_cp: coverpoint mbist_pass {
                bins functional = {1'b0};
                bins mbist_done = {1'b1};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            observed = new("observed", this);
            sram_mem_cg = new();
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual groq_sram_mem_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "sram_mem_monitor virtual interface missing")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(negedge vif.clk);
                #1ps;
                if (vif.rst_n && vif.tx_sample) begin
                    sram_mem_seq_item item = sram_mem_seq_item::type_id::create("obs_item");
                    bit [1:0] pwr_st;
                    item.tx_id            = vif.tx_id;
                    item.tx_phase         = vif.tx_phase;
                    item.rd_agu_cfg_load  = vif.rd_agu_cfg_load;
                    item.rd_agu_mode      = vif.rd_agu_mode;
                    item.rd_agu_base      = vif.rd_agu_base;
                    item.rd_agu_stride0   = vif.rd_agu_stride0;
                    item.rd_agu_stride1   = vif.rd_agu_stride1;
                    item.rd_agu_count0    = vif.rd_agu_count0;
                    item.rd_agu_count1    = vif.rd_agu_count1;
                    item.rd_agu_use       = vif.rd_agu_use;
                    item.wr_agu_cfg_load  = vif.wr_agu_cfg_load;
                    item.wr_agu_mode      = vif.wr_agu_mode;
                    item.wr_agu_base      = vif.wr_agu_base;
                    item.wr_agu_stride0   = vif.wr_agu_stride0;
                    item.wr_agu_stride1   = vif.wr_agu_stride1;
                    item.wr_agu_count0    = vif.wr_agu_count0;
                    item.wr_agu_count1    = vif.wr_agu_count1;
                    item.wr_agu_use       = vif.wr_agu_use;
                    item.stream_in_valid  = vif.stream_in_valid;
                    item.stream_in_bank   = vif.stream_in_bank;
                    item.stream_in_addr   = vif.stream_in_addr;
                    item.stream_in_data   = vif.stream_in_data;
                    item.stream_in_bwe_n  = vif.stream_in_bwe_n;
                    item.rd_req_valid     = vif.rd_req_valid;
                    item.rd_req_bank      = vif.rd_req_bank;
                    item.rd_req_addr      = vif.rd_req_addr;
                    item.bank_slp_n       = vif.bank_slp_n;
                    item.bank_ds_n        = vif.bank_ds_n;
                    item.bank_sd_n        = vif.bank_sd_n;
                    item.bank_repair_en   = vif.bank_repair_en;
                    item.bank_repair_addr = vif.bank_repair_addr;
                    item.mbist_en         = vif.mbist_en;
                    item.err_inject_en    = vif.err_inject_en;
                    item.err_inject_mask  = vif.err_inject_mask;

                    item.obs_bank_conflict_error = vif.bank_conflict_error;
                    item.obs_rd_tile_done        = vif.rd_tile_done;
                    item.obs_wr_tile_done        = vif.wr_tile_done;

                    @(posedge vif.clk);
                    #1ps;
                    item.obs_stream_out_valid = vif.stream_out_valid;
                    item.obs_stream_out_data  = vif.stream_out_data;
                    item.obs_ecc_single_err   = vif.ecc_single_err;
                    item.obs_ecc_double_err   = vif.ecc_double_err;
                    item.obs_ecc_syndrome     = vif.ecc_syndrome;
                    item.obs_mbist_done       = vif.mbist_done;
                    item.obs_mbist_fail       = vif.mbist_fail;

                    if (item.rd_agu_cfg_load) cur_rd_agu_mode = item.rd_agu_mode;
                    if (item.wr_agu_cfg_load) cur_wr_agu_mode = item.wr_agu_mode;

                    if (item.bank_sd_n != 4'hF)       pwr_st = 2'd3;
                    else if (item.bank_ds_n != 4'hF)  pwr_st = 2'd2;
                    else if (item.bank_slp_n != 4'hF) pwr_st = 2'd1;
                    else                              pwr_st = 2'd0;

                    sram_mem_cg.sample(
                        item.rd_req_valid, item.rd_req_bank,
                        item.stream_in_valid, item.stream_in_bank,
                        cur_rd_agu_mode, cur_wr_agu_mode,
                        bit'(item.obs_ecc_single_err), bit'(item.obs_ecc_double_err),
                        bit'(item.obs_bank_conflict_error), pwr_st,
                        (item.bank_repair_en != 4'h0),
                        bit'(item.obs_mbist_done && !item.obs_mbist_fail)
                    );
                    seen++;
                    observed.write(item);
                end
            end
        endtask
    endclass

    class sram_mem_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(sram_mem_scoreboard)

        uvm_analysis_imp #(sram_mem_seq_item, sram_mem_scoreboard) input_port;

        int unsigned checked         = 0;
        int unsigned mismatches      = 0;
        int unsigned ordering_errors = 0;
        int unsigned read_checked    = 0;
        int unsigned write_checked   = 0;
        int unsigned sec_checked     = 0;
        int unsigned ded_checked     = 0;
        int unsigned conflict_seen   = 0;
        int unsigned mbist_verified  = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            input_port = new("input_port", this);
        endfunction

        function void start_of_simulation_phase(uvm_phase phase);
            super.start_of_simulation_phase(phase);
            dpi_sram_reset();
        endfunction

        function void write(sram_mem_seq_item item);
            longint unsigned exp_lo, exp_hi;
            int unsigned     exp_flags, exp_addrs;
            bit              exp_out_valid, exp_conflict, exp_sec, exp_ded;
            bit              exp_rd_done, exp_wr_done, exp_bist_done, exp_bist_fail;
            bit [15:0]       exp_syn;
            bit              tx_ok;

            if (item.tx_id != checked) begin
                ordering_errors++;
                `uvm_error("ORDER_ERR", $sformatf("Expected tx_id=%0d got %0d", checked, item.tx_id))
            end

            dpi_sram_step(
                int'(item.rd_agu_cfg_load), int'(item.rd_agu_mode), int'(item.rd_agu_base),
                int'(item.rd_agu_stride0),  int'(item.rd_agu_stride1),
                int'(item.rd_agu_count0),   int'(item.rd_agu_count1),  int'(item.rd_agu_use),
                int'(item.wr_agu_cfg_load), int'(item.wr_agu_mode), int'(item.wr_agu_base),
                int'(item.wr_agu_stride0),  int'(item.wr_agu_stride1),
                int'(item.wr_agu_count0),   int'(item.wr_agu_count1),  int'(item.wr_agu_use),
                int'(item.stream_in_valid), int'(item.stream_in_bank), int'(item.stream_in_addr),
                longint'(item.stream_in_data[63:0]), longint'(item.stream_in_data[127:64]),
                int'(item.stream_in_bwe_n),
                int'(item.rd_req_valid),    int'(item.rd_req_bank),    int'(item.rd_req_addr),
                int'(item.bank_slp_n),      int'(item.bank_ds_n),      int'(item.bank_sd_n),
                int'(item.bank_repair_en),  int'(item.bank_repair_addr), int'(item.mbist_en),
                int'(item.err_inject_en),
                longint'(item.err_inject_mask[63:0]),   int'(item.err_inject_mask[71:64]),
                longint'(item.err_inject_mask[135:72]), int'(item.err_inject_mask[143:136])
            );

            exp_lo    = dpi_sram_exp_rdata_lo();
            exp_hi    = dpi_sram_exp_rdata_hi();
            exp_flags = dpi_sram_exp_flags();
            exp_addrs = dpi_sram_exp_addrs();

            exp_out_valid = exp_flags[0];
            exp_conflict  = exp_flags[1];
            exp_sec       = exp_flags[2];
            exp_ded       = exp_flags[3];
            exp_rd_done   = exp_flags[4];
            exp_wr_done   = exp_flags[5];
            exp_bist_done = exp_flags[6];
            exp_bist_fail = exp_flags[7];
            exp_syn       = exp_flags[23:8];

            checked++;
            if (item.stream_in_valid) write_checked++;
            if (exp_out_valid)        read_checked++;
            if (exp_sec)              sec_checked++;
            if (exp_ded)              ded_checked++;
            if (exp_conflict)         conflict_seen++;
            if (exp_bist_done && !exp_bist_fail) mbist_verified++;

            tx_ok = (item.obs_stream_out_valid    === exp_out_valid) &&
                    (item.obs_bank_conflict_error === exp_conflict)  &&
                    (item.obs_ecc_single_err      === exp_sec)       &&
                    (item.obs_ecc_double_err      === exp_ded)       &&
                    (item.obs_rd_tile_done        === exp_rd_done)   &&
                    (item.obs_wr_tile_done        === exp_wr_done)   &&
                    (item.obs_mbist_done          === exp_bist_done) &&
                    (item.obs_mbist_fail          === exp_bist_fail);

            if (exp_out_valid) begin
                tx_ok = tx_ok && (item.obs_ecc_syndrome === exp_syn);
                if (!exp_ded) begin
                    tx_ok = tx_ok && (item.obs_stream_out_data === {exp_hi, exp_lo});
                end
            end

            if (!tx_ok) begin
                mismatches++;
                `uvm_error("DPI_MISMATCH", $sformatf(
                    "tx=%0d ph=%0d rd_addr=%0d wr_addr=%0d out_val=%0b/%0b conf=%0b/%0b sec=%0b/%0b ded=%0b/%0b syn=%04x/%04x rdata=%032x exp=%016x_%016x",
                    item.tx_id, item.tx_phase, exp_addrs[9:0], exp_addrs[25:16],
                    item.obs_stream_out_valid, exp_out_valid,
                    item.obs_bank_conflict_error, exp_conflict,
                    item.obs_ecc_single_err, exp_sec,
                    item.obs_ecc_double_err, exp_ded,
                    item.obs_ecc_syndrome, exp_syn,
                    item.obs_stream_out_data, exp_hi, exp_lo))
            end
        endfunction
    endclass

    class sram_mem_env extends uvm_env;
        `uvm_component_utils(sram_mem_env)

        sram_mem_sequencer  sequencer;
        sram_mem_driver     driver;
        sram_mem_monitor    monitor;
        sram_mem_scoreboard scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sequencer  = new("sequencer", this);
            driver     = sram_mem_driver::type_id::create("driver", this);
            monitor    = sram_mem_monitor::type_id::create("monitor", this);
            scoreboard = sram_mem_scoreboard::type_id::create("scoreboard", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.observed.connect(scoreboard.input_port);
        endfunction
    endclass

    class sram_mem_test extends uvm_test;
        `uvm_component_utils(sram_mem_test)

        sram_mem_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = sram_mem_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            sram_mem_sequence seq = sram_mem_sequence::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(env.sequencer);
            repeat (4) @(negedge env.driver.vif.clk);
            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            int unsigned dpi_calls;
            real         func_cov;
            bit          valid_run;
            int          fd;
            super.report_phase(phase);

            dpi_calls = dpi_sram_get_calls();
            func_cov  = env.monitor.sram_mem_cg.get_inst_coverage();

            valid_run = (env.driver.driven >= 2500) &&
                        (env.monitor.seen == env.driver.driven) &&
                        (env.scoreboard.checked == env.driver.driven) &&
                        (dpi_calls == env.driver.driven) &&
                        (env.scoreboard.mismatches == 0) &&
                        (env.scoreboard.ordering_errors == 0) &&
                        (env.scoreboard.sec_checked == 300) &&
                        (env.scoreboard.ded_checked == 256) &&
                        (env.scoreboard.conflict_seen == 64) &&
                        (env.scoreboard.mbist_verified == 1) &&
                        (func_cov == 100.0);

            fd = $fopen("uvm_sram_summary.json", "w");
            if (fd == 0) `uvm_fatal("SUMMARY_OPEN", "Cannot open uvm_sram_summary.json")
            $fdisplay(fd,
                "{\"driven\":%0d,\"observed\":%0d,\"checked\":%0d,\"dpi_calls\":%0d,\"mismatches\":%0d,\"ordering_errors\":%0d,\"read_checked\":%0d,\"write_checked\":%0d,\"sec_checked\":%0d,\"ded_checked\":%0d,\"conflict_seen\":%0d,\"mbist_verified\":%0d,\"functional_coverage\":%0f,\"pass\":%0d}",
                env.driver.driven, env.monitor.seen, env.scoreboard.checked, dpi_calls,
                env.scoreboard.mismatches, env.scoreboard.ordering_errors,
                env.scoreboard.read_checked, env.scoreboard.write_checked,
                env.scoreboard.sec_checked, env.scoreboard.ded_checked,
                env.scoreboard.conflict_seen, env.scoreboard.mbist_verified,
                func_cov, valid_run);
            $fclose(fd);

            dpi_sram_set_status(valid_run ? 0 : 1);
            if (!valid_run) begin
                `uvm_fatal("UVM_SRAM_REJECTED", $sformatf(
                    "UVM SRAM qualification failed: driven=%0d checked=%0d mismatches=%0d cov=%0.2f%%",
                    env.driver.driven, env.scoreboard.checked, env.scoreboard.mismatches, func_cov))
            end else begin
                `uvm_info("UVM_SRAM_PASS", $sformatf(
                    "ALL %0d SRAM transactions verified against C++ DPI-C golden model (0 mismatches, 100.0%% functional coverage)",
                    env.scoreboard.checked), UVM_LOW)
            end
        endfunction
    endclass

endpackage
