# Hardware Bug Ledger & Verification Fixes (`groq_lpu_tsp_20261106`)

## Stage 7A (`uvm_stream_icu` - `groq_stream_fabric` & `groq_icu_slice`)

### BUG-ICU-001: Unlatched `sync_mask` During Multi-Cycle `ICU_SYNC_BARRIER` Stall When `imem_fetch_en_o` Is Gated
- **Module**: `rtl/groq_icu_slice.sv`
- **Severity**: High (Functional Barrier Premature Release / Deadlock Hazard)
- **Root Cause**: When a slice `s` executes `ICU_SYNC_BARRIER` on cycle $t$ and the barrier is not immediately satisfied on cycle $t$, `barrier_waiting_q[s]` asserts on cycle $t+1$, which deasserts `imem_fetch_en_o[s]` (`0`) to save instruction SRAM fetch power. However, `active_sync_mask` previously computed the barrier participation mask combinationally from `s_sync_mask[s]` (`imem_vliw_bundle_i[s][95:88]`) on every cycle without latching `s_sync_mask[s]` into a register when entering `barrier_waiting_q[s]`. Consequently, when the instruction SRAM output bus or UVM driver changed `imem_vliw_bundle_i[s]` on cycle $t+1$ while `imem_fetch_en_o[s] == 0`, `active_sync_mask` lost the waiting slice's target `sync_mask` and released the barrier prematurely before all participating slices asserted `ICU_NOTIFY`.
- **Fix Applied**: Added per-slice register `logic [P_NUM_SLICES-1:0][P_NUM_SLICES-1:0] sync_mask_q` in `rtl/groq_icu_slice.sv`. When `slice_entering_sync[s]` asserts and `barrier_release_pulse_o == 0`, `sync_mask_q[s]` latches `s_sync_mask[s][P_NUM_SLICES-1:0]`, and `active_sync_mask` selects `barrier_waiting_q[s] ? sync_mask_q[s] : s_sync_mask[s][P_NUM_SLICES-1:0]`. Cleared `sync_mask_q[s]` upon `barrier_release_pulse_o`.
- **Verification**: Re-verified with Yosys 0.60 formal proof (`formal/prove_icu_slice.ys`: `SAT proof finished - no model found: SUCCESS!`) and 2,200-cycle Accellera IEEE 1800.2-2020 UVM multi-slice barrier sequence (`0 mismatches`).

### BUG-ICU-002: Ungated `ICU_NOTIFY` & `ICU_REALSYNC_ADJ` Instruction Decode on Halted or Barrier-Waiting Slices
- **Module**: `rtl/groq_icu_slice.sv`
- **Severity**: Medium (Spurious Barrier Notification / Deskew Corruption after `ICU_HALT` or during `barrier_waiting_q`)
- **Root Cause**: In `rtl/groq_icu_slice.sv`, `barrier_ready_mask_o[s]` and `notify_latched_q[s]` decoded `(icu_enable_i & ~nop_active_q[s] & (s_icu_op[s] == groq_pkg::ICU_NOTIFY))` without gating by `~slice_halted_q[s] & ~barrier_waiting_q[s]`. Similarly, `ICU_REALSYNC_ADJ` on `SLICE_ICU` did not check `~slice_halted_q[SLICE_ICU]`. If a halted or barrier-waiting slice had residual `ICU_NOTIFY` or `ICU_REALSYNC_ADJ` bits on its disabled `imem_vliw_bundle_i` bus, it could falsely assert `notify_latched_q[s]` or overwrite `realsync_deskew_q`.
- **Fix Applied**: Gated `slice_entering_sync[s]`, `ICU_NOTIFY` decode in `barrier_ready_mask_o[s]` and `notify_latched_q[s]`, and `ICU_REALSYNC_ADJ` decode with `~slice_halted_q` and `~barrier_waiting_q`.
- **Verification**: Verified via Yosys 0.60 bounded formal proof (`prove_icu_slice.ys`) and UVM Phase D directed `ICU_HALT` + barrier stress test.

## Stage 7C (`uvm_mxm_sxm` - `groq_mxm_slice` & `groq_sxm_slice`)

### BUG-MXM-001: Per-Byte Zero-Skip Operand Isolation Corrupts 16-Bit Planar Weight Pair (`PREC_FP16` / `PREC_BF16`) When Only One Byte of a 16-Bit Activation Is Zero
- **Module**: `rtl/groq_mxm_slice.sv`
- **Severity**: High (Silent Data Corruption in `PREC_FP16` / `PREC_BF16` Planar Contraction Mode when `act_zero_gate_en_i == 1`)
- **Root Cause**: In `PREC_FP16` and `PREC_BF16` planar contraction modes, each 16-bit activation element is formed across an even/odd lane pair `{iso_act_lane[2*k+1], iso_act_lane[2*k]}` and multiplied against the 16-bit weight pair `{iso_wt_mat[2*k+1][c], iso_wt_mat[2*k][c]}`. However, the zero-skip operand isolation logic in `groq_mxm_slice.sv` evaluated `lane_is_zero[r] = (act_lane_raw[r] == 8'h00)` independently per 8-bit lane `r` regardless of `prec_mode_i`. Consequently, whenever a valid non-zero 16-bit planar activation had one zero byte and one non-zero byte (e.g., `16'h0300` where `act_lane_raw[2*k] == 8'h00` and `act_lane_raw[2*k+1] == 8'h03`), `zero_skip_gate_mask_o[2*k]` asserted and forced `iso_wt_mat[2*k][c] = 8'h00`, corrupting the lower byte of the 16-bit weight `{iso_wt_mat[2*k+1][c], iso_wt_mat[2*k][c]}` in the planar dot-product multiplier.
- **Fix Applied**: Updated `lane_is_zero[r]` in `rtl/groq_mxm_slice.sv` so that when `(prec_mode_i == groq_pkg::PREC_FP16) || (prec_mode_i == groq_pkg::PREC_BF16)`, both lanes of the 16-bit planar pair `(2*(r/2)+1, 2*(r/2))` are zero-gated if and only if both bytes of the 16-bit activation operand are zero (`(act_lane_raw[2*(r/2)] == 8'h00) && (act_lane_raw[2*(r/2)+1] == 8'h00)`).
- **Verification**: Verified via Yosys 0.60 formal SAT proof (`SAT proof finished - no model found: SUCCESS!`) and 3,200-transaction Accellera IEEE 1800.2-2020 UVM suite (`uvm_tb/uvm_mxm_sxm/`) with directed half-zero 16-bit planar operands (`16'h0300`) and C++17 DPI-C reference checking (`0 mismatches`).

## Stage 7D (`uvm_vxm_nim` — `groq_vxm_slice` & `groq_nim_realsync`)

### BUG-VXM-001: 32-Bit Signed Rounding Addition Overflow in `VXM_QUANT_SCALE` Near `INT32_MAX` Causes Positive-to-Negative Saturation Inversion
- **Module**: `rtl/groq_vxm_slice.sv`
- **Severity**: High (Silent Sign Inversion in Dynamic Quantizer / Scaler When `use_accum_32b_i == 1`)
- **Root Cause**: In `quant_scale_elem()`, `rounded = (raw_val + (32'sd1 <<< (shamt - 3'd1))) >>> shamt` performed rounding addition in 32-bit signed arithmetic (`logic signed [31:0]`). When `use_accum_32b_i == 1` and `accum_32b_in_i[i]` was near `INT32_MAX` (`32'h7FFF_FFF0`) with `quant_shift_i >= 5`, adding the rounding bias `1 << (shamt - 1)` overflowed 32-bit signed range to `-2147483632`, causing `sat_int8` to saturate a large positive 32-bit accumulator to `-128` (`0x80`) instead of `+127` (`0x7F` / `0x7E` in `PREC_FP8_E4M3`).
- **Fix Applied**: Widened `raw_ext` and `rounded` in `quant_scale_elem()` to 33-bit signed (`logic signed [32:0]`) before adding `(33'sd1 <<< (shamt - 3'd1))` and saturating to `[-128, +127]`.
- **Verification**: Re-verified via Yosys 0.60 formal SAT proof (`formal/prove_vxm_slice.ys`: `SAT proof finished - no model found: SUCCESS!`) and 3,200-transaction Accellera IEEE 1800.2-2020 UVM suite (`uvm_tb/uvm_vxm_nim/`) with directed `32'h7FFF_FFF0` rounding boundary vectors (`0 mismatches`).

### BUG-VXM-002: Unsigned Concatenation Before Arithmetic Right Shift (`>>> 6`) in `VXM_SWIGLU` Zero-Fills Sign Bits and Clamps All Negative SwiGLU Products to `+127`
- **Module**: `rtl/groq_vxm_slice.sv`
- **Severity**: Critical (All Negative Fused SwiGLU Outputs Corrupted to `+127`)
- **Root Cause**: In `groq_vxm_slice.sv`, `VXM_SWIGLU` computed `out_acc32_comb[i] = {{16{mul_prod[i][15]}}, mul_prod[i]} >>> 6;`. Per IEEE 1800-2017 Section 11.4.12, any concatenation `{...}` is unsigned regardless of operand signedness. Consequently, `>>> 6` performed an unsigned logical right shift (`6'b000000` shifted into `[31:26]`), turning every negative `mul_prod[i]` (`32'hFFFF_xxxx`) into a large positive value (`32'h03FF_xxxx`) that `sat_int8` saturated to `+127` (`0x7F`). Caught by the C++17 DPI-C UVM scoreboard (`187` mismatches on `vxm_op = 8`).
- **Fix Applied**: Wrapped the sign-extended concatenation in `$signed(...)`: `out_acc32_comb[i] = $signed({{16{mul_prod[i][15]}}, mul_prod[i]}) >>> 6;`.
- **Verification**: Verified via Yosys 0.60 formal SAT proof (`formal/prove_vxm_slice.ys`: `SUCCESS!`) and 3,200-transaction Accellera IEEE 1800.2-2020 UVM verification suite (`0 mismatches`, `100.00%` functional coverage).

### BUG-NIM-001: Silent Deskew Flit Drop When Scheduled `RealSync` Target Release Cycle Coincides With Active Non-`NIM_RECV` Opcode
- **Module**: `rtl/groq_nim_realsync.sv`, `rtl/groq_pkg.sv`
- **Severity**: High (Silent C2C Packet Loss Under Full-Duplex `NIM_SEND` / `NIM_FORWARD` / `NIM_NOP`)
- **Root Cause**: In `groq_nim_realsync.sv`, when a buffered C2C flit reached its scheduled release cycle (`slot_match_valid == 1`), the elastic deskew buffer cleared `buf_valid[slot_match_idx] <= 1'b0` unconditionally, whereas the local stream output router gated `local_stream_out_valid_o` with `(!op_valid_i || (nim_op_i == groq_pkg::NIM_RECV))`. Whenever `op_valid_i == 1` with `NIM_NOP`, `NIM_SEND`, `NIM_FORWARD`, or `NIM_REALSYNC_PING` on the exact release cycle, the deskewed flit was cleared from the buffer without asserting `local_stream_out_valid_o`. In addition, `NIM_SYNC_BEACON`, `NIM_DESKEW_CAL`, and `NIM_LOOPBACK` opcodes were added to `groq_pkg.sv` and `groq_nim_realsync.sv`.
- **Fix Applied**: Changed the deskew ejection condition in `rtl/groq_nim_realsync.sv` from `if (slot_match_valid && (!op_valid_i || (nim_op_i == groq_pkg::NIM_RECV)))` to `if (slot_match_valid)` so scheduled deskew releases always eject onto `local_stream_out_valid_o` / `local_stream_out_data_o` unless explicitly overridden by `NIM_ALLREDUCE_ADD` or `NIM_LOOPBACK`.
- **Verification**: Re-verified via Yosys 0.60 formal SAT proof (`formal/prove_nim_realsync.ys`: `SAT proof finished - no model found: SUCCESS!`) and 3,200-transaction Accellera IEEE 1800.2-2020 UVM suite (`1,597` deskew release events, `0 mismatches`).

## Stage 8 (`formal/prove_lpu_top.ys` & `formal/tb_stage8_adversarial_stress.sv` - Full-Chip Formal & Adversarial Stress Audit)

### BUG-TOP-001: Unpacked Struct Array Member Indexing (`vliw[s].field`) and Dynamic 3D Packed LHS/RHS Bit-Slice Indexing in `groq_lpu_top.sv`
- **Module**: `rtl/groq_lpu_top.sv`
- **Severity**: High (Yosys 0.60 Formal Verification & RTL Synthesis Elaboration Hazard; Implicit 1-Bit `undef` Wire Substitution on Slice VLIW Fields)
- **Root Cause**: `rtl/groq_lpu_top.sv` previously unpacked `slice_vliw_bundle_o[s]` into an unpacked array of packed structs (`groq_pkg::groq_vliw_instr_t vliw [P_NUM_SLICES]`) and accessed fields via `vliw[s].field`. While Verilator 5.054 accepted this construct, Yosys 0.60's SystemVerilog AST frontend (`read_verilog -sv`) does not resolve struct member access on indexed elements of an unpacked struct array, emitting `Warning: Identifier \vliw[s].<field> is implicitly declared` and `Range select out of bounds ... Setting all result bits to undef`. Furthermore, dynamic stream-ID indexing on the 3D packed fabric bus (`fab_east_inject_data[s][slice_inj_sid[s]] = slice_inj_data[s]`) caused exponential AST dynamic part-select expansion in Yosys when `slice_inj_sid[s]` became a live 4-bit register.
- **Fix Applied**: Replaced `vliw[s].field` references in `rtl/groq_lpu_top.sv` with direct packed bit-slices of `slice_vliw_bundle_o[s]` matching `groq_pkg::groq_vliw_instr_t` (`[139:136]` `icu_op`, `[135:132]` `mem_op`, `[131:128]` `sxm_op`, `[127:124]` `vxm_op`, `[123:120]` `mxm_op`, `[119:116]` `nim_op`, `[115:112]` `prec_mode`, `[111:107]` `src_stream_a`, `[106:102]` `src_stream_b`, `[100:97]` `dst_stream[3:0]`, `[96]` `dst_dir_west`, `[71:56]` `mem_base_addr`, `[55:48]` `mem_stride`, `[47:40]` `vec_length`, `[39:32]` `sxm_shift_amt`, `[31:16]` `imm16`), and refactored `select_stream_valid`, `select_stream_data`, and fabric injection muxing to use constant-index `for (int k = 0; k < P_NUM_EAST_STREAMS; k++)` loops gated by `(sid[3:0] == 4'(k))`.
- **Verification**: Re-verified with Verilator 5.054 (`--lint-only -Wall`: `0 warnings, 0 errors`), Yosys 0.60 full-chip formal proof (`formal/prove_lpu_top.ys` & `formal/prove_full_chip.ys`), and 100,000-cycle Stage 8 adversarial stress simulation (`formal/tb_stage8_adversarial_stress.sv`: `500,085` self-checking assertions across `MXM`, `SXM`, `VXM`, `NIM`, and `LPU_TOP`, `0 errors`).


## Stage 7E (`uvm_full_chip` - `groq_lpu_cluster_top` & `groq_lpu_top`)

### BUG-CLUSTER-001: Hardcoded Tie-Off of East Hemisphere Host DMA Preload (`host_mem_e_wr_*`) and SECDED ECC Fault Injection (`mem_err_inject_*`) Ports in `groq_lpu_cluster_top`
- **Module**: `rtl/groq_lpu_cluster_top.sv`
- **Severity**: Medium (Cluster Top-Level Integration Defect Blocking Host DMA Preload of East Hemisphere SRAM and Cluster-Level SECDED ECC Fault Qualification)
- **Root Cause**: In `rtl/groq_lpu_cluster_top.sv`, both `u_lpu_chip0` and `u_lpu_chip1` (`groq_lpu_top`) instances had `.host_mem_e_wr_en_i(1'b0)`, `.host_mem_e_bank_i('0)`, `.host_mem_e_addr_i('0)`, `.host_mem_e_data_i('0)` and `.mem_err_inject_en_i(1'b0)`, `.mem_err_inject_mask_i('0)` hardcoded to constant zeros rather than exposed at the `groq_lpu_cluster_top` module boundary. This prevented Host DMA preloading of Chip 0 and Chip 1 East Hemisphere SRAM (`SLICE_MEM_E`) and blocked cluster-level SECDED ECC fault injection (`mem_err_inject_en_i=1`) during multi-chip spatial pipeline execution.
- **Fix Applied**: Added `chip0_host_mem_e_wr_*`, `chip1_host_mem_e_wr_*`, `chip0_mem_err_inject_en_i`, `chip0_mem_err_inject_mask_i`, `chip1_mem_err_inject_en_i`, and `chip1_mem_err_inject_mask_i` ports (with backwards-compatible default `'0` assignments) to `rtl/groq_lpu_cluster_top.sv` and wired them to `u_lpu_chip0` and `u_lpu_chip1`.
- **Verification**: Verified via 3,666-cycle Accellera IEEE 1800.2-2020 Full-Chip & 2-Chip Cluster UVM verification suite (`uvm_tb/uvm_full_chip/`) across 48 single-bit SECDED ECC fault injection waves (`0..143` bit positions) and East/West Host DMA SRAM preloads (`0 mismatches`).

## Stage 14B (`uvm_dragonfly_8chip` — `groq_dragonfly_8chip_cluster`)

### BUG-DRAGONFLY-001: Hardcoded Tie-Off of Per-Chip SRAM SECDED ECC Fault Injection Ports (`mem_err_inject_en_i`, `mem_err_inject_mask_i`) in `groq_dragonfly_8chip_cluster`
- **Module**: `rtl/groq_dragonfly_8chip_cluster.sv`
- **Severity**: Medium (Cluster Top-Level Integration Defect Blocking 8-Chip SRAM SECDED ECC Fault Qualification; `cluster_ecc_single_err_o[7:0]` and `cluster_ecc_double_err_o[7:0]` Unreachable)
- **Root Cause**: In `rtl/groq_dragonfly_8chip_cluster.sv`, all 8 generated `groq_lpu_top` instances (`gen_chip[0..7].u_lpu`) had `.mem_err_inject_en_i(1'b0)` and `.mem_err_inject_mask_i('0)` tied to constant zeros instead of exposed at the `groq_dragonfly_8chip_cluster` module boundary, preventing cluster-wide single-bit (SEC) and double-bit (DED) SRAM ECC fault injection across the 8 chips and leaving the exported `cluster_ecc_single_err_o[7:0]` and `cluster_ecc_double_err_o[7:0]` telemetry outputs permanently stuck at `8'h00`.
- **Fix Applied**: Added `input logic [P_NUM_CHIPS-1:0] mem_err_inject_en_i = '0` and `input logic [143:0] mem_err_inject_mask_i = '0` ports to `rtl/groq_dragonfly_8chip_cluster.sv` and wired `mem_err_inject_en_i[c]` and `mem_err_inject_mask_i` to each chip's `u_lpu` instance.
- **Verification**: Verified via Yosys 0.60 compositional formal proof (`formal/prove_dragonfly_8chip.ys`: `SAT proof finished - no model found: SUCCESS!`), Verilator 5.054 `--lint-only -Wall` (`0 warnings, 0 errors`), and 3,102-cycle Accellera IEEE 1800.2-2020 UVM verification suite (`uvm_tb/uvm_dragonfly_8chip/`) across 75 SEC and 75 DED waves across all 8 chips (`0 mismatches`).

### BUG-DRAGONFLY-002: 64B/66B Scrambler LFSR Phase Desynchronization & Unlatched Replay Destination Across 8x8 Dragonfly Switch Matrix During Go-Back-N CRC-16 Replay
- **Module**: `rtl/groq_dragonfly_8chip_cluster.sv`
- **Severity**: High (Permanent CRC-16 Failure & Packet Drop on Go-Back-N Replay When `pcs_scramble_en_i == 1`)
- **Root Cause**: In `rtl/groq_dragonfly_8chip_cluster.sv`, when a C2C frame transmitted by source chip `s` was corrupted in flight via `pcs_err_inject_en_i[s]`, `gen_chip[s].u_pcs` advanced its `tx_lfsr_q` on the initial transmission while `gen_chip[d].u_pcs` gated its `rx_lfsr_q` with `!rx_crc16_err_o`. On the subsequent Go-Back-N NACK replay cycle, `u_pcs[s]` scrambled the replayed payload with an advanced LFSR seed (`tx_lfsr_q != rx_lfsr_q`), causing `u_pcs[d]` to descramble with a mismatched mask and fail CRC-16 indefinitely when `pcs_scramble_en_i == 1`. In addition, `dly_dst_q[c]` and `link_tx_dst_eff[c]` sampled live `routed_dst_chip[c]` rather than the replayed frame's header destination `pcs_tx_meta_unused[14:12]` during active replay (`pcs_replay_act_unused || pcs_nack_in[c]`).
- **Fix Applied**: Added per-chip TX/RX scrambler phase tracking (`chip_tx_lfsr_q[c]`, `chip_rx_lfsr_q[c]`) across the 8x8 Dragonfly Switch Matrix in `rtl/groq_dragonfly_8chip_cluster.sv` so payloads normalize from source `s`'s TX LFSR domain before link error injection and re-scramble into destination `d`'s RX LFSR domain upon switch egress, and selected `pcs_tx_meta_unused[14:12]` for `eff_routed_dst` during Go-Back-N replay.
- **Verification**: Re-verified via Yosys 0.60 formal proof (`formal/prove_dragonfly_8chip.ys`: `SUCCESS!`) and 3,102-cycle Accellera IEEE 1800.2-2020 UVM suite (`92` CRC-16 error events, `288` Go-Back-N replay flit recoveries across 0-cycle and 1-cycle plesiochronous link delays, `0 mismatches`).

## Stage 11, 12, 13 & 17 Additional Hardware & Netlist Bugs Discovered and Fixed

### BUG-DOT-001: 8-Bit Magnitude Product Truncation in `MODE_INT8_SYM` (`a_mag * w_mag`)
- **Module**: `rtl/groq_mxfp8_nvfp4_dot_engine.sv`
- **Severity**: High (Arithmetic Overflow on `INT8` Symmetric Dot Products When $|a_i| \cdot |w_i| \ge 256$)
- **Root Cause**: In `groq_mxfp8_nvfp4_dot_engine.sv`, `decode_and_mul_lane` initially assigned the product of two 8-bit unsigned magnitudes (`a_mag * w_mag`, ranging up to $128 \times 128 = 16,384$) into an 8-bit temporary `sig_prod8` before aligning into the 24-bit mantissa accumulator. Caught immediately by the Stage 11 self-checking testbench (`formal/tb_stage11_mxfp8_nvfp4.sv`) and Yosys SAT proof (`formal/prove_mxfp8_nvfp4_dot.ys`).
- **Fix Applied**: Added a dedicated 16-bit magnitude product `logic [15:0] int8_mag16 = 16'(a_mag) * 16'(w_mag)` for `MODE_INT8_SYM` and shifted by `{8'd0, int8_mag16} << shift_amt`.
- **Verification**: Verified via Yosys 0.60 6-step sequential SAT proof (`formal/formal_mxfp8_nvfp4_dot.log`: `1,227,296` vars -> `SUCCESS! Q.E.D.`), ASAP7 gate-equivalence proof (`formal/formal_mxfp8_nvfp4_gate_equiv.log`: `SUCCESS!`), and 3,600-cycle Accellera UVM Suite 6 (`0 mismatches`).

### BUG-PCS-001: Width Mismatch Between 4-Bit `rx_expected_seq_q` and 2-Bit Go-Back-N Replay Pointer `nack_seq_o[1:0]`
- **Module**: `rtl/groq_c2c_serdes_pcs.sv`
- **Severity**: Low/Medium (Verilator `WIDTHEXPAND` Lint Hazard & Potential Sequence Number Wrap Mismatch in 4-Entry Replay Buffer)
- **Root Cause**: `rx_expected_seq_q` was declared as 4 bits while the 4-entry circular Go-Back-N replay buffer is indexed by a 2-bit modulo-4 sequence pointer `nack_seq_o[1:0]`. Caught by `verilator --lint-only -Wall`.
- **Fix Applied**: Unified `rx_expected_seq_q` and sequence comparison with `rx_descrambled_comb[59:58]` to 2 bits (`[1:0]`).
- **Verification**: Verified via Verilator 5.054 `--lint-only -Wall` (`0 warnings`), Yosys 0.60 SAT proof (`formal/formal_c2c_serdes_pcs.log`: `SUCCESS!`), and ASAP7 gate equivalence proof.

### BUG-DFLY-001: Combinational Reverse-NACK Feedback Loop (`UNOPTFLAT`) Across 0-Delay 8x8 Dragonfly Switch Matrix
- **Module**: `rtl/groq_dragonfly_8chip_cluster.sv`
- **Severity**: High (Combinational Loop Across Cross-Chip NACK Return Path When `link_delay_en_i == 8'h00`)
- **Root Cause**: In `groq_dragonfly_8chip_cluster.sv`, routing `pcs_nack_out[d]` combinationally back to source chip `s`'s `nack_valid_i` while `u_pcs[s]` combinationally muxed `tx_flit_o` on `nack_valid_i` created a cross-switch combinational loop flagged by Verilator 5.054 (`UNOPTFLAT`).
- **Fix Applied**: Registered the reverse NACK return path (`pcs_nack_in`, `pcs_nack_seq_in`) across the Dragonfly switch matrix, matching physical 1-cycle reverse link propagation.
- **Verification**: Verified via Verilator 5.054 `--lint-only -Wall` (`0 warnings, 0 errors`) and Yosys 0.60 compositional formal proof (`formal/formal_dragonfly_8chip.log`: `2,701,514` vars -> `SUCCESS! Q.E.D.`).

### BUG-ASAP7-SIM-001: Active-Low Async Set/Reset (`SETN`/`RESETN`) and Inverted `QN` Polarity in `DFFASRHQNx1_ASAP7_75t_R` Gate-Level Simulation Model
- **Module**: `gate_sim/gen_asap7_sim_lib.py` (`gate_sim/asap7_sim_cells.v`)
- **Severity**: High (639 False Gate-vs-RTL Mismatches in `groq_nim_realsync_gate` Post-Synthesis Simulation)
- **Root Cause**: In the ASAP7 7nm Liberty library (`asap7_rvt_ff.lib`), Yosys `dfflibmap` maps sequential flip-flops to `DFFASRHQNx1_ASAP7_75t_R`, whose Liberty pin specification has active-low asynchronous `SETN` (`preset: "!SETN"`), active-low asynchronous `RESETN` (`clear: "!RESETN"`), and inverted output `QN` (`function: "IQN"`). Treating `QN` as non-inverting caused inverted register states in `groq_nim_realsync_gate`.
- **Fix Applied**: Updated `gen_asap7_sim_lib.py` to model `IQ <= 1'b0` on `!RESETN`, `IQ <= 1'b1` on `!SETN`, `IQ <= D` on `posedge CLK`, and `assign QN = ~IQ`.
- **Verification**: All 8 synthesized ASAP7 gate-level netlists (`99,178` standard cells) matched behavioral RTL across `5,220` cycles (`41,600` checks, `0 mismatches`, `100.0% CYCLE-ACCURATE EQUIVALENCE VERIFIED!`).


## Stage 32 (`BUG-LIT-001..004` - Literature-Driven RTL & Architectural Upgrades: ISCA 2020/2022 + GTC 2026 NVIDIA Groq 3 LPX)

### BUG-LIT-001: Two's-Complement `-128` (`8'h80`) Negation Wrap-Around Overflow in `SXM_BUTTERFLY_SWAP` RoPE Even-Lane Sign Negation
- **Module**: `rtl/groq_sxm_slice.sv`, `uvm_tb/uvm_mxm_sxm/dpi_mxm_sxm_ref.cpp`
- **Severity**: High (Silent Sign Inversion on Minimum INT8 `-128` Activation During Rotary Position Embedding `RoPE` Butterfly Swap)
- **Root Cause**: In `apply_sxm_perm()` of `rtl/groq_sxm_slice.sv`, when `(op == groq_pkg::SXM_BUTTERFLY_SWAP) && rope_neg && (i[0] == 1'b0)`, the even lane was negated via 8-bit two's-complement unary negation `dst[i] = -src[idx_bfly];`. In 8-bit signed two's-complement arithmetic (`[-128, +127]`), negating `-128` (`8'h80`) computes `~8'h80 + 8'h01 = 8'h80` (`-128`), which remains negative instead of saturating to `+127` (`8'h7F`), corrupting RoPE rotation pairs $(-x_{2m+1}, x_{2m})$ whenever $x_{2m+1} = -128$.
- **Fix Applied**: Replaced `-src[idx_bfly]` with saturating INT8 negation `(src[idx_bfly] == 8'h80) ? 8'h7F : -src[idx_bfly];` in `rtl/groq_sxm_slice.sv` and updated the C++17 DPI-C reference predictor in `uvm_tb/uvm_mxm_sxm/dpi_mxm_sxm_ref.cpp`. Added formal Property 4 in `rtl/groq_sxm_slice.sv` asserting `$signed(out_lane_comb[k]) != -8'sd128` across all even lanes $k \in \{0,2,\dots,14\}$.
- **Verification**: Verified via Yosys 0.60 formal SAT proof (`formal/formal_sxm_slice.log`: `1,195,800` vars, `3,484,534` clauses -> `SAT proof finished - no model found: SUCCESS! Q.E.D.`), ASAP7/Sky130 re-synthesis, and 12-module gate-level co-simulation (`0 mismatches`).

### BUG-LIT-002: Missing Native NVIDIA Blackwell / Vera Rubin / Groq 3 LPX `NVFP4` Mode With `FP8 E4M3` Fractional Block Scales (`MODE_NVFP4_E4M3_SCALE = 3'd5`)
- **Module**: `rtl/groq_mxfp8_nvfp4_dot_engine.sv`
- **Severity**: Medium/High (Incomplete Hardware Support for Native NVIDIA `NVFP4` Fractional `E4M3` Micro-Block Scaling vs. OCP `MXFP4` `E8M0` Power-of-Two Scaling)
- **Root Cause**: While `MODE_NVFP4_E2M1` (`3'd3`) implements OCP Microscaling `MXFP4` with shared `E8M0` power-of-two exponent scales, native NVIDIA Blackwell / Vera Rubin / Groq 3 LPX `NVFP4` uses `FP8 E4M3` (`[6:3]=exp4`, `[2:0]=mant3`) fractional block scales per 16-element micro-block to preserve sub-bit quantization fidelity.
- **Fix Applied**: Added `localparam logic [2:0] MODE_NVFP4_E4M3_SCALE = 3'd5;` in `rtl/groq_mxfp8_nvfp4_dot_engine.sv` (preserving modes `3'd0..3'd4` 100% bit-exact). In `MODE_NVFP4_E4M3_SCALE`, `act_scale_e8m0_i[6:0]` and `wt_scale_e8m0_i[6:0]` are decoded as `FP8 E4M3` scales: `7'h7F` triggers `nan_inf_comb = 1'b1`, `7'h00` with `zero_skip_en_i` triggers `block_zero_skip_comb = 1'b1`, the 32-sublane `E2M1` tree sum is scaled by the product of the 4-bit normal/subnormal mantissas `(nvfp4_tree_sum_comb * $signed({1'b0, act_m4 * wt_m4})) >>> 6`, and the effective `E8M0`-biased exponents `8'd120 + {4'd0, scale[6:3]}` are passed to Stage 2.
- **Verification**: Verified via Yosys 0.60 6-step sequential SAT proof (`formal/formal_mxfp8_nvfp4_dot.log`: `1,242,249` vars, `3,502,615` clauses -> `SUCCESS! Q.E.D.`) and ASAP7 gate-equivalence proof (`formal/formal_mxfp8_nvfp4_gate_equiv.log`: `SUCCESS! Q.E.D.`).

### BUG-LIT-003: Missing Autonomous ISCA 2022 Hardware-Aligned Counter (`HAC`) Local Consensus Oscillator State in `groq_nim_realsync.sv`
- **Module**: `rtl/groq_nim_realsync.sv`
- **Severity**: Medium (Reliance on External `realsync_aligned_time_i` Input Without Internal Autonomous Hardware-Aligned Counter `HAC` Tracking on `NIM_DESKEW_CAL`)
- **Root Cause**: Per ISCA 2022 (*"A Look at Communication-Intensive Workloads on the Groq TSP"*), each TSP chip maintains an internal Hardware-Aligned Counter (`HAC`) that increments every cycle and snaps to consensus time upon receiving an error-free `NIM_DESKEW_CAL` calibration flit across the Dragonfly fabric. `groq_nim_realsync.sv` previously computed `measured_skew_o` against `realsync_aligned_time_i` without maintaining an internal `hac_counter_q` and `hac_deskew_locked_q` state machine.
- **Fix Applied**: Added 16-bit internal `hac_counter_q` and `hac_deskew_locked_q` registers in `rtl/groq_nim_realsync.sv` that reset to `0`, align to `incoming_target_cycle + 16'd1` with `hac_deskew_locked_q <= 1'b1` on a valid error-free `NIM_DESKEW_CAL` flit, and increment (`hac_counter_q + 16'd1`) on all other cycles. Added formal sequential assertions proving 1-cycle lock and exact counter alignment after `NIM_DESKEW_CAL`.
- **Verification**: Verified via Yosys 0.60 6-step sequential SAT proof (`formal/formal_nim_realsync.log`: `958,872` vars, `2,561,837` clauses -> `SUCCESS! Q.E.D.`), ASAP7/Sky130 re-synthesis, and 12-module gate co-simulation (`0 mismatches`).

### BUG-LIT-004: Calibration of 256-Chip Rack Simulator & Architecture Spec to Official GTC 2026 NVIDIA Groq 3 LPX Specifications (`500 MB/die`, `128 GB/rack`, `315 PFLOPS` FP8, `16x 2U` Trays, NVIDIA Dynamo)
- **Module**: `benchmarks/lpx_rack_and_spec_decode/sim_lpx_256chip_rack.py`, `docs/GROQ_LPU_ARCHITECTURE_SPEC.md`, `reports/STAGE22_LPX_RACK_AND_SPEC_DECODE_REPORT.md`
- **Severity**: Low/Documentation & Analytical Model Completeness
- **Root Cause**: The 256-chip rack simulator and architecture documentation required explicit cross-calibration between the `150 MB/die` (`38.4 GB/rack`) baseline and the official GTC 2026 **NVIDIA Groq 3 LPX** rack specification (`500 MB` / `512 MB` binary SRAM per Samsung SF4X 4nm die = `128 GB` SRAM per 256-chip rack across `16 x 2U` trays with 16 LPUs/tray, `150 TB/s` SRAM BW/die = `38.4-40.0 PB/s` rack SRAM BW, `315 PFLOPS` FP8 compute/rack, `640 TB/s` scale-up C2C interconnect BW, and **NVIDIA Dynamo** disaggregated prefill-decode orchestration).
- **Fix Applied**: Updated `sim_lpx_256chip_rack.py`, `lpx_256chip_rack_results.json`, `STAGE22_LPX_RACK_AND_SPEC_DECODE_REPORT.md`, and `GROQ_LPU_ARCHITECTURE_SPEC.md` with full dual-point (`500 MB/die` GTC 2026 LPX + `150 MB/die` baseline) telemetry.
- **Verification**: Re-ran `python3 benchmarks/lpx_rack_and_spec_decode/sim_lpx_256chip_rack.py` and verified JSON output integrity (`0 errors`).


## Stage 34 (115-Source Literature Audit Wave 2 - `BUG-LIT-005` to `BUG-LIT-008`)

### BUG-LIT-005: Missing IEEE 754-2019 Round-to-Nearest-Even (`PREC_INT8_RNE`) Mode in `groq_vxm_slice.sv` Dynamic Quantizer
- **Module**: `rtl/groq_pkg.sv`, `rtl/groq_vxm_slice.sv`
- **Severity**: Medium (Systematic +0.5 LSB Positive Bias on Halfway Ties Under Round-Half-Up `PREC_INT8` Across Deep Transformer Layers)
- **Root Cause**: Per Groq Patent `US11263129B1` (`[S61]`, *Numerical Interpretation Module in a Tensor Streaming Processor*) and IEEE Std 754-2019 (`[S86]`), deterministic fixed-point and floating-point rescaling requires unbiased Round-to-Nearest-Even (`RNE`) tie-breaking so that exact halfway residuals (`0.5 LSB`) do not accumulate positive drift across 80+ Transformer layers. Previously, `quant_scale_elem` in `rtl/groq_vxm_slice.sv` only implemented round-half-up `(raw_ext + (1 <<< (shamt - 1))) >>> shamt`.
- **Fix Applied**: Added `localparam logic [3:0] PREC_INT8_RNE = 4'd3;` to `rtl/groq_pkg.sv`. In `rtl/groq_vxm_slice.sv` (`quant_scale_elem`), kept `PREC_INT8`, `PREC_FP16`, and `PREC_FP8_E4M3` 100% bit-exact unchanged, and for `pmode == groq_pkg::PREC_INT8_RNE` with `shamt != 3'd0`, evaluated `is_exact_tie = ((raw_ext & rem_mask) == half_val)` and `quot_lsb_even = (((raw_ext >>> shamt) & 33'sd1) == 33'sd0)`, selecting `round_bias = (is_exact_tie && quot_lsb_even) ? 33'sd0 : half_val` so exact halfway ties always round to an even quotient (`LSB == 0`).
- **Verification**: Verified via Yosys 0.60 formal SAT proof (`formal/formal_vxm_slice.log`: `SUCCESS! Q.E.D.`) and Python golden reference unit test `test_09_vxm_quant_scale_ieee754_rne_exact_ties` (`PASS`).

### BUG-LIT-006: Missing Native NVIDIA `NVFP4` `FP8 E4M3` Fractional Block Scale Telemetry Register (`scale_nvfp4_e4m3_q`) in `groq_c2c_kv_quant_rx_engine.sv`
- **Module**: `rtl/groq_c2c_kv_quant_rx_engine.sv`
- **Severity**: Low/Medium (Incomplete Native `NVFP4` `FP8 E4M3` Fractional Block Scale Generation Alongside OCP `E8M0` Scale During Prefill-to-Decode KV Disaggregation)
- **Root Cause**: When quantizing incoming 16-lane `BF16`/`FP16` KV-cache blocks over NVLink-C2C (`[S35]`, `[S79]`, `[S85]`), `groq_c2c_kv_quant_rx_engine.sv` previously generated only the 8-bit OCP power-of-two `E8M0` scale (`scale_e8m0_o`), without latching the native NVIDIA `NVFP4` `FP8 E4M3` fractional block scale (`{1'b0, nvfp4_e4m3_exp4_c, max_emax_frac3_c}`).
- **Fix Applied**: Added `max_emax_frac3_c`, `nvfp4_e4m3_exp4_c`, and registered `scale_nvfp4_e4m3_q[7:0]` in `rtl/groq_c2c_kv_quant_rx_engine.sv`, computing `{1'b0, nvfp4_e4m3_exp4_c, max_emax_frac3_c}` when `|is_finite_nz_c` is true and `8'd0` when all 16 lanes are zero. Added formal invariants proving `scale_nvfp4_e4m3_q[7] == 1'b0` and `(&f_past_is_zero) -> (scale_nvfp4_e4m3_q == 8'd0)`.
- **Verification**: Verified via Yosys 0.60 3-step sequential SAT proof (`formal/formal_c2c_kv_quant_rx.log`: `82,505` vars, `226,822` clauses -> `SAT proof finished - no model found: SUCCESS! Q.E.D.`) and Python golden reference test `test_15` (`PASS`).

### BUG-LIT-007: Missing EAGLE-2 / EAGLE-3 Context-Aware Dynamic Draft Tree Confidence Accumulator (`eagle2_tree_confidence_q`) in `groq_spec_decode_tree_sampler.sv`
- **Module**: `rtl/groq_spec_decode_tree_sampler.sv`
- **Severity**: Low/Medium (Missing Hardware Confidence Telemetry for Dynamic Draft Tree Depth Calibration in Speculative Decoding)
- **Root Cause**: Per EAGLE-2 (`[S96]`, EMNLP 2024) and EAGLE-3 (`[S97]`, 2025), context-aware speculative draft tree expansion relies on cumulative target confidence across accepted tree nodes to dynamically adjust draft tree branching on subsequent decode steps. `groq_spec_decode_tree_sampler.sv` verified causal path acceptance without accumulating accepted node target probabilities.
- **Fix Applied**: Added 16-bit `eagle2_tree_confidence_comb` and registered `eagle2_tree_confidence_q[15:0]` in `rtl/groq_spec_decode_tree_sampler.sv`, summing `tree_target_prob_i[8*d +: 8]` across all accepted nodes `node_path_valid_comb[d]`. Added formal assertions proving `eagle2_tree_confidence_q <= 16'd2040` and `(accepted_draft_len_o == 3'd0) -> (eagle2_tree_confidence_q == 16'd0)`.
- **Verification**: Verified via Yosys 0.60 3-step sequential SAT proof (`formal/formal_spec_decode_sampler.log`: `346,510` vars, `990,735` clauses -> `SAT proof finished - no model found: SUCCESS! Q.E.D.`) and Python golden reference test `test_16` (`PASS`).

### BUG-LIT-008: Golden Reference Model (`groq_golden_model.py`) Parity Gap for Phase II?IV Hardware IP Blocks & Wave 1-2 Literature Upgrades
- **Module**: `arch_model/groq_golden_model.py`, `arch_model/test_golden_model.py`
- **Severity**: Medium (Incomplete Bit-Exact Python Reference Coverage for New RTL Modes and Phase II?IV Subsystem IPs)
- **Root Cause**: `arch_model/groq_golden_model.py` originally modeled the 8 baseline functional slices and 7 unit tests, lacking bit-exact Python reference classes/methods for `SXM` RoPE `-128` saturation (`BUG-LIT-001`), `VXM` `PREC_INT8_RNE` (`BUG-LIT-005`), `NIM` autonomous `HAC` consensus (`BUG-LIT-003`), `GroqMXFP8NVFP4DotEngineModel` (modes `0..5` including `MODE_NVFP4_E4M3_SCALE = 5`, `BUG-LIT-002`), `GroqC2CKVQuantRxModel` (`BUG-LIT-006`), `GroqSpecDecodeTreeSamplerModel` (`BUG-LIT-007`), `GroqPowerDroopControllerModel`, and `GroqSRAMECCScrubberModel`.
- **Fix Applied**: Upgraded `arch_model/groq_golden_model.py` with all 8 bit-exact hardware reference classes/methods and expanded `arch_model/test_golden_model.py` from 7 to 18 unit tests.
- **Verification**: Executed `python3 arch_model/test_golden_model.py` -> `Ran 18 tests in 0.124s: OK (18/18 PASS)`.
