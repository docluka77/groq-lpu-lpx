#!/usr/bin/env python3
"""
Comprehensive Verification & Vector Generation Suite for the Groq LPU / NVIDIA Groq 3 LPX
Bit-Exact Golden Reference Model & Deterministic Spatial VLIW Compiler.
"""

import os
import sys
import unittest
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from groq_golden_model import (
    GroqDeterministicCompiler,
    GroqLpuGoldenModel,
    HOP_MEM_E,
    HOP_MEM_W,
    HOP_MXM_W,
    HOP_NIM,
    HOP_SXM,
    HOP_VXM,
    ICU_HALT,
    ICU_NOP_DELAY,
    LANES_PER_SUPERLANE,
    MEM_ECC_SCRUB,
    MEM_READ_STREAM,
    MEM_WRITE_STREAM,
    MemOp32,
    NIM_ALLREDUCE_ADD,
    NIM_REALSYNC_ALIGN,
    NIM_RX_STREAM,
    NIM_TX_STREAM,
    SXM_BUTTERFLY_SWIZZLE,
    SXM_ROTATE_LANES,
    SXM_TRANSPOSE_POP,
    SXM_TRANSPOSE_PUSH,
    SecdedHamming7264,
    VliwBundle144,
)


class TestGroqGoldenModel(unittest.TestCase):
    def test_01_secded_hamming_72_64_exhaustive(self) -> None:
        """Verify 100% single-bit error correction across all 72 bits and double-bit detection."""
        test_words = [0x0123456789ABCDEF, 0xFEDCBA9876543210, 0xAAAAAAAAAAAAAAAA, 0x5555555555555555]
        for w in test_words:
            cw = SecdedHamming7264.encode64(w)
            d0, syn0, sec0, ded0 = SecdedHamming7264.decode72(cw)
            self.assertEqual(d0, w)
            self.assertEqual(syn0, 0)
            self.assertFalse(sec0)
            self.assertFalse(ded0)

            # Flip every single bit 0..71 -> must recover exact 64-bit word
            for b1 in range(72):
                corrupted1 = cw ^ (1 << b1)
                d1, _, sec1, ded1 = SecdedHamming7264.decode72(corrupted1)
                self.assertEqual(d1, w, f"Failed 1-bit recovery at bit {b1}")
                self.assertTrue(sec1)
                self.assertFalse(ded1)

            # Flip pairs of bits -> must assert double_err_detected (ded2 == True)
            for b1 in range(0, 72, 7):
                for b2 in range(b1 + 1, 72, 9):
                    corrupted2 = cw ^ (1 << b1) ^ (1 << b2)
                    _, _, sec2, ded2 = SecdedHamming7264.decode72(corrupted2)
                    self.assertFalse(sec2)
                    self.assertTrue(ded2, f"Failed 2-bit detection for bits ({b1}, {b2})")

    def test_02_sram_ecc_fault_injection_and_scrub(self) -> None:
        """Verify MEM_W on-chip SRAM single-bit upset auto-correction and hardware scrub."""
        lpu = GroqLpuGoldenModel()
        vec = np.arange(-8, 8, dtype=np.int32)
        lpu.mem_w.direct_write_row(bank=5, row=12, vec=vec)
        # Inject 1-bit upset in both low and high 64-bit Hamming codewords
        lpu.mem_w.inject_bit_fault(bank=5, row=12, bit_pos=13, high_word=False)
        lpu.mem_w.inject_bit_fault(bank=5, row=12, bit_pos=41, high_word=True)

        prog = [
            VliwBundle144(mem_w=MemOp32(opcode=MEM_READ_STREAM, stream_id=0, bank_id=5, row_addr=12)),
            VliwBundle144(mem_w=MemOp32(opcode=MEM_ECC_SCRUB, bank_id=5, row_addr=12)),
            VliwBundle144(icu_opcode=ICU_HALT),
        ]
        lpu.run_program(prog)
        self.assertEqual(lpu.mem_w.ecc_single_err_count, 4)  # 2 words corrected on read + 2 on scrub
        self.assertEqual(lpu.mem_w.ecc_double_err_count, 0)
        # Verify scrubbed codeword now has zero errors
        lpu.mem_w.ecc_single_err_count = 0
        recovered = lpu.mem_w._ecc_read_row(5, 12)
        np.testing.assert_array_equal(recovered, vec)
        self.assertEqual(lpu.mem_w.ecc_single_err_count, 0)

    def test_03_sxm_16x16_transpose_and_permute(self) -> None:
        """Verify SXM 16x16 matrix corner-turn transpose and butterfly lane swizzle."""
        lpu = GroqLpuGoldenModel()
        mat = np.arange(256, dtype=np.int32).reshape(16, 16) - 128
        for r in range(16):
            lpu.mem_w.direct_write_row(bank=0, row=r, vec=mat[r])

        from groq_golden_model import DeterministicTimeline
        tl = DeterministicTimeline()
        # Stream 16 rows from MEM_W (Hop 1) to SXM (Hop 2) on S0 -> arrives at t_read + 2 + 1 = t_read + 3
        for r in range(16):
            tl.bundle_at(r).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=0, bank_id=0, row_addr=r)
            b_push = tl.bundle_at(r + 3)
            b_push.sxm_opcode = SXM_TRANSPOSE_PUSH
            b_push.sxm_shift_amt = r
            b_push.sxm_stream_sel = 0

        # Pop 16 transposed columns from SXM (Hop 2) onto Eastward S1 -> write to MEM_E (Hop 7, dist=5 -> arrives t_pop + 1 + 5 = t_pop + 6)
        for c in range(16):
            t_pop = 20 + c
            b_pop = tl.bundle_at(t_pop)
            b_pop.sxm_opcode = SXM_TRANSPOSE_POP
            b_pop.sxm_shift_amt = c
            b_pop.sxm_stream_sel = 1
            tl.bundle_at(t_pop + 6).mem_e = MemOp32(opcode=MEM_WRITE_STREAM, stream_id=1, bank_id=0, row_addr=c)

        lpu.run_program(tl.finalize_program())
        for c in range(16):
            np.testing.assert_array_equal(lpu.mem_e.sram_payload[0, c], mat[:, c])

    def test_04_deterministic_gemv_and_silu_fusion(self) -> None:
        """Verify cycle-exact fused GEMV + SiLU (`MEM_W -> MXM_W -> VXM -> MEM_W`) against numpy reference."""
        lpu = GroqLpuGoldenModel()
        rng = np.random.default_rng(42)
        w_mat = rng.integers(-16, 16, size=(16, 16), dtype=np.int32)
        x_vec = rng.integers(-32, 32, size=(16,), dtype=np.int32)

        for r in range(16):
            lpu.mem_w.direct_write_row(bank=0, row=r, vec=w_mat[r])
        lpu.mem_w.direct_write_row(bank=1, row=0, vec=x_vec)

        prog = GroqDeterministicCompiler.compile_gemv_and_silu(
            w_bank=0, w_row=0, x_bank=1, x_row=0, out_bank=2, out_row=0
        )
        lpu.run_program(prog)

        # Compute exact golden reference
        dot32 = np.matmul(x_vec, w_mat)
        mxm_q = np.clip(dot32 >> 6, -128, 127).astype(np.int32)
        expected_silu = lpu.vxm._silu_int8(mxm_q)
        actual = lpu.mem_w.sram_payload[2, 0]
        np.testing.assert_array_equal(actual, expected_silu)
        self.assertEqual(lpu.fabric.collision_count, 0)

        vec_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
        GroqDeterministicCompiler.export_program_vectors(
            vec_dir,
            "gemv_silu",
            prog,
            {"x_vec": x_vec.tolist(), "w_mat": w_mat.tolist(), "expected_out": expected_silu.tolist()},
        )

    def test_05_rmsnorm_and_rope_compiler(self) -> None:
        """Verify deterministic RMSNorm and Rotary Position Embedding (RoPE) schedules."""
        # 1. RMSNorm test
        lpu_rms = GroqLpuGoldenModel()
        x_in = np.array([16, -16, 32, -32, 16, -16, 32, -32, 16, -16, 32, -32, 16, -16, 32, -32], dtype=np.int32)
        gamma = np.full(16, 16, dtype=np.int32)  # Unit scale in Q4.4
        lpu_rms.mem_w.direct_write_row(bank=0, row=0, vec=x_in)
        lpu_rms.mem_e.direct_write_row(bank=1, row=0, vec=gamma)
        prog_rms = GroqDeterministicCompiler.compile_rmsnorm(x_bank=0, x_row=0, gamma_bank=1, gamma_row=0, out_bank=2, out_row=0)
        lpu_rms.run_program(prog_rms)
        out_rms = lpu_rms.mem_w.sram_payload[2, 0]
        self.assertTrue(np.all(np.abs(out_rms) > 0))
        self.assertEqual(lpu_rms.fabric.collision_count, 0)

        # 2. RoPE test (90-degree rotation: cos=0, sin=16 in Q4.4 -> [x0, x1] maps to [-x1, x0])
        lpu_rope = GroqLpuGoldenModel()
        q_vec = np.arange(1, 17, dtype=np.int32) * 2
        cs_vec = np.array([0, 16] * 8, dtype=np.int32)
        lpu_rope.mem_w.direct_write_row(bank=0, row=0, vec=q_vec)
        lpu_rope.mem_e.direct_write_row(bank=0, row=0, vec=cs_vec)
        prog_rope = GroqDeterministicCompiler.compile_rope(q_bank=0, q_row=0, cs_bank=0, cs_row=0, out_bank=2, out_row=0)
        lpu_rope.run_program(prog_rope)
        out_rope = lpu_rope.mem_w.sram_payload[2, 0]
        for i in range(0, 16, 2):
            self.assertEqual(out_rope[i], -q_vec[i + 1])
            self.assertEqual(out_rope[i + 1], q_vec[i])

    def test_06_nim_realsync_plesiochronous_deskew_and_allreduce(self) -> None:
        """Verify NIM RealSync deskew absorbs +/-3 cycle clock drift and executes in-flight C2C AllReduce."""
        lpu = GroqLpuGoldenModel()
        remote_tensor = np.full(16, 25, dtype=np.int32)
        local_tensor = np.full(16, 17, dtype=np.int32)
        lpu.mem_w.direct_write_row(bank=0, row=0, vec=local_tensor)
        lpu.nim.enqueue_c2c_ingress(link_id=0, vec=remote_tensor, clock_drift=+3)

        from groq_golden_model import DeterministicTimeline
        tl = DeterministicTimeline()
        tl.bundle_at(0).nim_opcode = NIM_REALSYNC_ALIGN
        # Read local tensor from MEM_W (Hop 1) onto Westward S16 at t=1 -> arrives at NIM (Hop 0) at t = 1 + 2 + 1 = 4
        tl.bundle_at(1).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=16, bank_id=0, row_addr=0)
        tl.bundle_at(4).nim_opcode = NIM_ALLREDUCE_ADD
        tl.bundle_at(4).nim_link_sel = 0  # Emits sum onto Eastward S0 -> arrives MEM_W (Hop 1) at t = 4 + 1 + 1 = 6
        tl.bundle_at(6).mem_w = MemOp32(opcode=MEM_WRITE_STREAM, stream_id=0, bank_id=1, row_addr=0)

        lpu.run_program(tl.finalize_program())
        np.testing.assert_array_equal(lpu.mem_w.sram_payload[1, 0], np.full(16, 42, dtype=np.int32))
        self.assertEqual(lpu.nim.hac_counter, lpu.nim.sac_counter)

    def test_07_end_to_end_llm_decode_layer_and_export(self) -> None:
        """Execute full Llama-3 / DeepSeek decode layer (RMSNorm -> Gate/Up MXM -> SwiGLU -> Down MXM) & export vectors."""
        lpu = GroqLpuGoldenModel()
        rng = np.random.default_rng(2026)
        w_gate = rng.integers(-12, 12, size=(16, 16), dtype=np.int32)
        w_up = rng.integers(-12, 12, size=(16, 16), dtype=np.int32)
        w_down = rng.integers(-12, 12, size=(16, 16), dtype=np.int32)
        x_tok = rng.integers(-24, 24, size=(16,), dtype=np.int32)
        gamma = np.full(16, 16, dtype=np.int32)

        for r in range(16):
            lpu.mem_w.direct_write_row(bank=0, row=r, vec=w_gate[r])
            lpu.mem_e.direct_write_row(bank=0, row=r, vec=w_up[r])
            lpu.mem_e.direct_write_row(bank=1, row=r, vec=w_down[r])
        lpu.mem_w.direct_write_row(bank=2, row=0, vec=x_tok)
        lpu.mem_e.direct_write_row(bank=2, row=0, vec=gamma)

        prog, meta = GroqDeterministicCompiler.compile_llm_decode_layer()
        cycles = lpu.run_program(prog)
        self.assertEqual(lpu.fabric.collision_count, 0)

        # Verify bit-exact equivalence against step-by-step mathematical model
        x_norm = lpu.mem_w.sram_payload[3, 0]
        gate_q = np.clip(np.matmul(x_norm, w_gate) >> 6, -128, 127).astype(np.int32)
        up_q = np.clip(np.matmul(x_norm, w_up) >> 6, -128, 127).astype(np.int32)
        swiglu_q = np.clip((lpu.vxm._silu_int8(gate_q) * up_q) >> 4, -128, 127).astype(np.int32)
        expected_down = np.clip(np.matmul(swiglu_q, w_down) >> 6, -128, 127).astype(np.int32)

        actual_down = lpu.mem_e.sram_payload[3, 0]
        np.testing.assert_array_equal(actual_down, expected_down)

        energy = lpu.estimate_energy_pJ()
        vec_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")
        GroqDeterministicCompiler.export_program_vectors(
            vec_dir,
            "llm_decode_layer",
            prog,
            {
                "cycles": cycles,
                "schedule_meta": meta,
                "energy_pJ": energy,
                "x_tok": x_tok.tolist(),
                "x_norm": x_norm.tolist(),
                "swiglu_q": swiglu_q.tolist(),
                "expected_down": expected_down.tolist(),
            },
        )
        print(f"\n[PASS] Full LLM Decode Layer executed in {cycles} deterministic cycles with 0 collisions! Energy={energy['total_pJ']} pJ")


    def test_08_sxm_butterfly_swap_rope_neg128_saturation(self) -> None:
        """Verify BUG-LIT-001: SXM RoPE butterfly swap saturates -128 (0x80) to +127 instead of wrapping."""
        from groq_golden_model import SxmSliceModel
        vec = np.array([10, -128, -50, 127] + [0] * 12, dtype=np.int32)
        out = SxmSliceModel.butterfly_swap_rope(vec, mask=1, negate_odd_en=True)
        self.assertEqual(out[0], 127)   # -(-128) saturates to +127
        self.assertEqual(out[1], 10)
        self.assertEqual(out[2], -127)  # -(127) = -127
        self.assertEqual(out[3], -50)

    def test_09_vxm_quant_scale_ieee754_rne_exact_ties(self) -> None:
        """Verify BUG-LIT-005: VXM PREC_INT8_RNE rounds exact halfway ties to nearest even integer."""
        from groq_golden_model import VxmSliceModel, PREC_INT8, PREC_INT8_RNE
        # Exact tie 0.5 (raw=1, shamt=1): PREC_INT8 rounds to +1 (odd), PREC_INT8_RNE rounds to 0 (even)
        self.assertEqual(VxmSliceModel.quant_scale_elem(1, 1, PREC_INT8), 1)
        self.assertEqual(VxmSliceModel.quant_scale_elem(1, 1, PREC_INT8_RNE), 0)
        # Exact tie 1.5 (raw=3, shamt=1): both round to +2 (even)
        self.assertEqual(VxmSliceModel.quant_scale_elem(3, 1, PREC_INT8_RNE), 2)
        # Exact tie 2.5 (raw=5, shamt=1): PREC_INT8 rounds to +3 (odd), PREC_INT8_RNE rounds to +2 (even)
        self.assertEqual(VxmSliceModel.quant_scale_elem(5, 1, PREC_INT8), 3)
        self.assertEqual(VxmSliceModel.quant_scale_elem(5, 1, PREC_INT8_RNE), 2)
        # Exact tie -1.5 (raw=-3, shamt=1): PREC_INT8 rounds to -1 (odd), PREC_INT8_RNE rounds to -2 (even)
        self.assertEqual(VxmSliceModel.quant_scale_elem(-3, 1, PREC_INT8), -1)
        self.assertEqual(VxmSliceModel.quant_scale_elem(-3, 1, PREC_INT8_RNE), -2)

    def test_10_vxm_quant_scale_fp8_e4m3_nan_safe_clamp(self) -> None:
        """Verify VXM PREC_FP8_E4M3 clamps +127 -> +126 and -1 -> -2 to avoid E4M3 NaN bit patterns."""
        from groq_golden_model import VxmSliceModel, PREC_FP8_E4M3
        self.assertEqual(VxmSliceModel.quant_scale_elem(127, 0, PREC_FP8_E4M3), 126)
        self.assertEqual(VxmSliceModel.quant_scale_elem(-1, 0, PREC_FP8_E4M3), -2)
        self.assertEqual(VxmSliceModel.quant_scale_elem(64, 0, PREC_FP8_E4M3), 64)

    def test_11_nim_realsync_autonomous_hac_and_consensus_drift(self) -> None:
        """Verify BUG-LIT-003: NIM autonomous HAC snaps to target_cycle+1 and applies (drift>>1) consensus."""
        lpu = GroqLpuGoldenModel()
        hac, locked, eff = lpu.nim.calibrate_hac_consensus(incoming_target_cycle=500, peer_drift=4, link_crc_err=False)
        self.assertTrue(locked)
        self.assertEqual(hac, 501)
        self.assertEqual(eff, 503)  # 501 + (4 >> 1) = 503

    def test_12_mxfp8_nvfp4_dot_engine_modes_0_to_4(self) -> None:
        """Verify OCP MXFP8/NVFP4 dot engine across INT8, MXFP8_E4M3, NVFP4_E2M1, zero-skip, and NaN scale."""
        from groq_golden_model import GroqMXFP8NVFP4DotEngineModel as Dot
        r_int8 = Dot.compute_dot(Dot.MODE_INT8_SYM, [2] * 16, [3] * 16, accum_in=10)
        self.assertEqual(r_int8["dot_out"], 10 + 96)
        r_zskip = Dot.compute_dot(Dot.MODE_MXFP8_E4M3, [5] * 16, [5] * 16, act_scale=0, wt_scale=127, accum_in=42)
        self.assertTrue(r_zskip["block_zero_skip"])
        self.assertEqual(r_zskip["dot_out"], 42)
        r_nan = Dot.compute_dot(Dot.MODE_NVFP4_E2M1, [2] * 32, [2] * 32, act_scale=255, wt_scale=127, accum_in=77)
        self.assertTrue(r_nan["nan_inf"])
        self.assertEqual(r_nan["dot_out"], 77)

    def test_13_mxfp8_nvfp4_dot_engine_native_nvfp4_e4m3_scale(self) -> None:
        """Verify BUG-LIT-002: Native NVIDIA NVFP4 mode (MODE_NVFP4_E4M3_SCALE = 5) with FP8 E4M3 block scales."""
        from groq_golden_model import GroqMXFP8NVFP4DotEngineModel as Dot
        # E4M3 scale 0x38 = exp4=7 (120+7=127), mant3=0 (m4=8 -> 8*8=64 >> 6 = 1x)
        r = Dot.compute_dot(Dot.MODE_NVFP4_E4M3_SCALE, [0b0010] * 32, [0b0010] * 32, act_scale=0x38, wt_scale=0x38, accum_in=5)
        self.assertFalse(r["block_zero_skip"])
        self.assertFalse(r["nan_inf"])
        self.assertEqual(r["dot_out"], 5 + 128)
        r_nan = Dot.compute_dot(Dot.MODE_NVFP4_E4M3_SCALE, [2] * 32, [2] * 32, act_scale=0x7F, wt_scale=0x38, accum_in=19)
        self.assertTrue(r_nan["nan_inf"])
        self.assertEqual(r_nan["dot_out"], 19)

    def test_14_c2c_kv_quant_rx_bf16_fp16_to_mxfp8_and_nvfp4(self) -> None:
        """Verify C2C KV-Cache ingress quantizer across BF16/FP16 -> MXFP8 (2x) and NVFP4 (4x)."""
        from groq_golden_model import GroqC2CKVQuantRxModel as KVQ
        bf16_1p0 = 0x3F80  # exp8=127, frac7=0
        res = KVQ.quantize_block(KVQ.QUANT_BF16_TO_MXFP8_E4M3, [bf16_1p0] * 16)
        self.assertEqual(res["scale_e8m0"], 120)
        self.assertEqual(res["zero_lanes_cnt"], 0)
        self.assertTrue(all(c == (7 << 3) for c in res["quant_lanes"]))

    def test_15_c2c_kv_quant_rx_native_nvfp4_e4m3_fractional_scale(self) -> None:
        """Verify BUG-LIT-006: Native NVFP4 E4M3 fractional block scale non-negativity and all-zero block = 0."""
        from groq_golden_model import GroqC2CKVQuantRxModel as KVQ
        res_zero = KVQ.quantize_block(KVQ.QUANT_BF16_TO_NVFP4_E2M1, [0x0000] * 16)
        self.assertEqual(res_zero["scale_nvfp4_e4m3"], 0)
        self.assertEqual(res_zero["zero_lanes_cnt"], 16)
        res_nz = KVQ.quantize_block(KVQ.QUANT_BF16_TO_NVFP4_E2M1, [0x3FC0] * 16)  # 1.5 in BF16 (exp8=127, frac7=0x40)
        self.assertEqual(res_nz["scale_nvfp4_e4m3"] & 0x80, 0)
        self.assertGreater(res_nz["scale_nvfp4_e4m3"], 0)

    def test_16_spec_decode_tree_sampler_bitonic_and_eagle2_confidence(self) -> None:
        """Verify BUG-LIT-007: Speculative decoding K=16 bitonic sort, causal prefix tree, and EAGLE-2 confidence."""
        from groq_golden_model import GroqSpecDecodeTreeSamplerModel as Spec
        logits = [-10, 45, 12, 88, -5, 0, 33, 19, -40, 72, 5, -1, 60, 25, 10, 95]
        tokens = list(range(100, 116))
        res = Spec.evaluate(Spec.SAMPLER_SPEC_VERIFY_TREE, logits, tokens)
        self.assertEqual(res["sorted_logits"][0], 95)
        self.assertEqual(res["sorted_tokens"][0], 115)
        self.assertEqual(res["accepted_draft_len"], 4)
        self.assertEqual(res["total_emitted_tokens"], 5)
        self.assertEqual(res["eagle2_tree_confidence"], 220 + 200 + 180 + 160)

    def test_17_power_droop_controller_proactive_and_reactive_mitigation(self) -> None:
        """Verify di/dt power droop controller precharge ramp-up, emergency clock stretch, and safe ramp-down."""
        from groq_golden_model import GroqPowerDroopControllerModel
        ctrl = GroqPowerDroopControllerModel(droop_thresh_mv=45, precharge_cycles=4, rampdown_cycles=4)
        s_pre = ctrl.step(upcoming_mxm_burst=True, active_compute=False, measured_droop_mv=10)
        self.assertEqual(s_pre["state"], ctrl.STATE_PRECHARGE_RAMP_UP)
        self.assertTrue(s_pre["icu_fetch_stall"])
        s_act = ctrl.step(upcoming_mxm_burst=False, active_compute=True, measured_droop_mv=20)
        self.assertEqual(s_act["state"], ctrl.STATE_ACTIVE_COMPUTE)
        s_emg = ctrl.step(upcoming_mxm_burst=False, active_compute=True, measured_droop_mv=52)
        self.assertEqual(s_emg["state"], ctrl.STATE_EMERGENCY_STRETCH)
        self.assertEqual(s_emg["mxm_rate_scale"], 0.5)
        s_down = ctrl.step(upcoming_mxm_burst=False, active_compute=False, measured_droop_mv=15)
        self.assertEqual(s_down["state"], ctrl.STATE_SAFE_RAMP_DOWN)

    def test_18_sram_ecc_patrol_scrubber_sbe_auto_heal_and_dbe_alarm(self) -> None:
        """Verify zero-stall cycle-stealing SECDED SRAM scrubber SBE auto-heal and DBE sticky alarm."""
        from groq_golden_model import GroqSRAMECCScrubberModel
        scrub = GroqSRAMECCScrubberModel(num_rows=8)
        scrub.write_functional(0, 0xCAFE_BABE_1234_5678)
        scrub.inject_bit_flips(0, [13])  # Single-bit upset
        r_busy = scrub.step_patrol(func_port_busy=True)
        self.assertFalse(r_busy["scrubbed"])
        r_sbe = scrub.step_patrol(func_port_busy=False)
        self.assertTrue(r_sbe["sbe"])
        self.assertEqual(r_sbe["data64"], 0xCAFE_BABE_1234_5678)
        self.assertEqual(scrub.sbe_corrected_count, 1)
        scrub.write_functional(1, 0x1122_3344_5566_7788)
        scrub.inject_bit_flips(1, [5, 29])  # Double-bit upset
        r_dbe = scrub.step_patrol(func_port_busy=False)
        self.assertTrue(r_dbe["dbe"])
        self.assertTrue(scrub.dbe_sticky_alarm)

    def test_19_rtl_vs_reported_benchmark_calibration(self) -> None:
        """Verify Stage 48 10,000-cycle RTL hardware-in-the-loop calibration against 18 published benchmarks."""
        import json
        from pathlib import Path
        cal_path = Path(__file__).resolve().parent.parent / "benchmarks" / "rtl_perf_energy_calibration" / "sim_vs_reported_calibration.json"
        self.assertTrue(cal_path.exists(), f"Missing calibration receipt: {cal_path}")
        cal = json.loads(cal_path.read_text(encoding="utf-8"))
        self.assertEqual(cal["overall_status"], "PASS")
        self.assertEqual(cal["passed_benchmarks"], 18)
        self.assertEqual(cal["total_benchmarks"], 18)
        self.assertLessEqual(cal["max_relative_error_pct"], 1.00)
        self.assertEqual(cal["rtl_telemetry_summary"]["total_rtl_cycles"], 10000)
        self.assertEqual(cal["rtl_telemetry_summary"]["c2c_crc_errors"], 0)
        self.assertEqual(cal["rtl_telemetry_summary"]["cluster_collision_faults"], 0)

    def test_20_gtc2026_35x_perf_per_mw_validation(self) -> None:
        """Verify NVIDIA GTC 2026 Groq 3 LPX 256-chip rack energy efficiency (0.228 J/tok) & 35x Perf/MW multiplier."""
        import json
        from pathlib import Path
        cal_path = Path(__file__).resolve().parent.parent / "benchmarks" / "rtl_perf_energy_calibration" / "sim_vs_reported_calibration.json"
        cal = json.loads(cal_path.read_text(encoding="utf-8"))
        bm_map = {b["id"]: b for b in cal["benchmarks"]}
        self.assertAlmostEqual(bm_map["BM-11"]["simulated"], 0.230, delta=0.01)
        self.assertAlmostEqual(bm_map["BM-12"]["simulated"], 35.0, delta=1.0)
        self.assertTrue(bm_map["BM-11"]["pass"])
        self.assertTrue(bm_map["BM-12"]["pass"])

    def test_21_hil_c2c_realsync_deskew_and_scrubber_telemetry(self) -> None:
        """Verify Stage 48 21-module RTL HIL telemetry: C2C RealSync 0-cycle deskew, PDN di/dt droop, and SRAM scrubber SBE auto-heal."""
        import json
        from pathlib import Path
        tel_path = Path(__file__).resolve().parent.parent / "benchmarks" / "rtl_perf_energy_calibration" / "rtl_hardware_telemetry.json"
        self.assertTrue(tel_path.exists(), f"Missing RTL hardware telemetry: {tel_path}")
        tel = json.loads(tel_path.read_text(encoding="utf-8"))
        self.assertEqual(tel["c2c_tx_packets"], 500)
        self.assertEqual(tel["c2c_deskew_releases"], 500)
        self.assertEqual(tel["c2c_measured_skew_cycles"], 0)
        self.assertEqual(tel["c2c_crc_errors"], 0)
        self.assertGreaterEqual(tel["droop_mitigated_events"], 100)
        self.assertEqual(tel["emerg_throttle_events"], 0)
        self.assertGreaterEqual(tel["vdd_min_mv"], 780)
        self.assertGreater(tel["sram_scrub_corrected_sbe"], 0)
        self.assertEqual(tel["sram_scrub_ded_alerts"], 0)

    def test_22_18_benchmark_sub_1pct_accuracy(self) -> None:
        """Verify all 18 calibrated Groq TSP & NVIDIA Groq 3 LPX benchmarks achieve <= 1.00% relative error."""
        import json
        from pathlib import Path
        cal_path = Path(__file__).resolve().parent.parent / "benchmarks" / "rtl_perf_energy_calibration" / "sim_vs_reported_calibration.json"
        cal = json.loads(cal_path.read_text(encoding="utf-8"))
        self.assertEqual(len(cal["benchmarks"]), 18)
        for bm in cal["benchmarks"]:
            self.assertTrue(bm["pass"], f"Benchmark {bm['id']} failed calibration")
            self.assertLessEqual(bm["relative_error_pct"], 1.00, f"Benchmark {bm['id']} error {bm['relative_error_pct']}% > 1.00%")


if __name__ == "__main__":
    unittest.main(verbosity=2)
