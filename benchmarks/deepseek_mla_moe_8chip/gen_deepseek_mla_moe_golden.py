#!/usr/bin/env python3
"""
Stage 16: Multi-Token Autoregressive Decode of DeepSeek-V3/R1 MLA + Routed MoE
on 8-Chip Dragonfly Group Scale-Out Cluster RTL (NVIDIA Groq 3 LPX).

Models a 4-Token Autoregressive Decode Chain (Token 0 -> Token 1 -> Token 2 -> Token 3)
across 8 LPU Chips (Chip 0..7) where:
  - Stage A: RMSNorm (VXM) + MLA Down-Projection (c_t^{KV} = x_hat_t * W_DKV) +
             Query Projection (q_t = x_hat_t * W_Q) + Decoupled RoPE (SXM_BUTTERFLY_SWAP +
             VXM_FMA) + On-Chip SRAM Circular KV-Ring Buffer Append (AGU_KV_RING)
  - Stage B: Causal Latent Attention Score over growing KV-Latent Ring Cache
             (seq_len: 1 -> 2 -> 3 -> 4) + Numerically Stable Softmax (VXM_REDUCE_MAX,
             VXM_SUB, VXM_EXP_LUT, VXM_REDUCE_SUM, VXM_QUANT_SCALE) + Up-Projection
             (o_attn = p_attn * W_UKV) + Residual Add (h_attn = x_hat_t + o_attn)
  - Stage C: 8-Chip Dragonfly MoE Router Gate (W_router + VXM_SILU) + Hardware
             Radix-2/8 Butterfly AllToAll (ROUTE_MOE_ALLTOALL_BUTTERFLY, dst = c ^ bstage)
             Token Dispatch across 64B/66B SerDes PCS Links with RealSync Elastic Deskew
  - Stage D: 8-Chip Parallel Routed Expert SwiGLU FFN (W_gate, W_up, VXM_SWIGLU, W_down) +
             Companion groq_mxfp8_nvfp4_dot_engine Co-Processors (MODE_W4A8_MIXED &
             MODE_NVFP4_E2M1 with E8M0 block scales) + 8-Chip Bidirectional Ring
             In-Network AllReduce (ROUTE_BIDIR_RING + NIM_ALLREDUCE_ADD) -> y^(t) = x^(t+1)
"""

import json
import os
from typing import Dict, List, Tuple
import numpy as np

NUM_CHIPS    = 8
NUM_TOKENS   = 4
TOKEN_STRIDE = 300
MAX_PC       = NUM_TOKENS * TOKEN_STRIDE + 20  # 1220 cycles

SLICE_NIM   = 0
SLICE_MEM_W = 1
SLICE_SXM   = 2
SLICE_VXM   = 3
SLICE_MXM_W = 4
SLICE_ICU   = 5
SLICE_MXM_E = 6
SLICE_MEM_E = 7

PREC_INT8     = 0
PREC_FP8_E4M3 = 1

ICU_NOP  = 0
ICU_HALT = 6

MEM_NOP        = 0
MEM_READ_EAST  = 1
MEM_READ_WEST  = 2
MEM_WRITE_EAST = 3
MEM_WRITE_WEST = 4
MEM_STRIDE_CFG = 5

SXM_NOP            = 0
SXM_PASSTHROUGH    = 1
SXM_BROADCAST_LANE = 5
SXM_BUTTERFLY_SWAP = 12

VXM_NOP         = 0
VXM_ADD         = 1
VXM_MUL         = 2
VXM_FMA         = 3
VXM_SILU        = 4
VXM_RSQRT_LUT   = 6
VXM_EXP_LUT     = 7
VXM_SWIGLU      = 8
VXM_QUANT_SCALE = 9
VXM_SUB         = 10
VXM_REDUCE_SUM  = 14
VXM_REDUCE_MAX  = 15

MXM_NOP            = 0
MXM_LOAD_WEIGHT_B0 = 1
MXM_LOAD_WEIGHT_B1 = 2
MXM_SWAP_WEIGHT    = 3
MXM_SYSTOLIC_EXEC  = 4
MXM_ACCUM_CLEAR    = 6

NIM_NOP           = 0
NIM_SEND          = 1
NIM_RECV          = 2
NIM_ALLREDUCE_ADD = 5

MODE_NVFP4_E2M1 = 3
MODE_W4A8_MIXED = 4

BUTTERFLY_STAGES = [1, 2, 4, 3]


def sat_int8(val: int) -> int:
    if val > 127:
        return 127
    if val < -128:
        return -128
    return int(val)


def to_s8(val: int) -> int:
    v = int(val) & 0xFF
    return v - 256 if v >= 128 else v


def silu_lut_int8(x: int) -> int:
    x = to_s8(x)
    if x <= -64:
        y = 0
    elif x <= -32:
        y = -((x + 64) >> 3)
    elif x < 0:
        y = x >> 2
    elif x < 32:
        y = ((x << 2) + x) >> 3
    elif x < 64:
        y = x - 12
    else:
        y = x
    return sat_int8(y)


def exp_lut_int8(x: int) -> int:
    x = to_s8(x)
    if x >= 0:
        return 127
    if x <= -64:
        return 1
    neg_x = (-x) & 0x3F
    seg = (neg_x >> 3) & 0x7
    frac_s = neg_x & 0x7
    table = {
        0: (127, frac_s << 2),
        1: (95, (frac_s << 1) + frac_s),
        2: (71, frac_s << 1),
        3: (55, frac_s << 1),
        4: (39, frac_s),
        5: (31, frac_s),
        6: (23, frac_s),
        7: (15, frac_s),
    }
    base_val, delta_val = table[seg]
    return sat_int8(base_val - delta_val)


def rsqrt_lut_int8(x: int) -> int:
    x = to_s8(x)
    abs_x = 127 if x == -128 else (abs(x) & 0x7F)
    seg = (abs_x >> 4) & 0x7
    frac_s = abs_x & 0xF
    table = {
        0: (127, (frac_s << 1) + frac_s),
        1: (79, frac_s << 1),
        2: (55, frac_s),
        3: (43, frac_s),
        4: (35, 0),
        5: (31, 0),
        6: (28, 0),
        7: (25, 0),
    }
    base_val, delta_val = table[seg]
    return sat_int8(base_val - (delta_val >> 1))


def quant_scale_elem(raw_val: int, shamt: int, pmode: int = PREC_INT8) -> int:
    if shamt == 0:
        rounded = raw_val
    else:
        rounded = (raw_val + (1 << (shamt - 1))) >> shamt
    q_int8 = sat_int8(rounded)
    if pmode == PREC_FP8_E4M3:
        if q_int8 == 127:
            return 126
        if q_int8 == -1:
            return -2
    return q_int8


def rope_butterfly_swap(vec: list, mask: int = 1, neg_even: bool = True) -> list:
    out = [0] * 16
    for i in range(16):
        idx = i ^ (mask & 0xF)
        val = to_s8(vec[idx])
        if neg_even and ((i & 1) == 0):
            out[i] = to_s8((-val) & 0xFF)
        else:
            out[i] = val
    return out


def mxm_contract_int8(act: list, wt_mat: list) -> Tuple[list, list, int]:
    zero_skips = sum(1 for a in act if (a & 0xFF) == 0)
    accum_32 = [0] * 16
    stream_8 = [0] * 16
    for c in range(16):
        acc = 0
        for r in range(16):
            a_val = to_s8(act[r])
            w_val = to_s8(wt_mat[r][c])
            if a_val != 0 and w_val != 0:
                acc += a_val * w_val
        accum_32[c] = acc
        stream_8[c] = to_s8(acc & 0xFF)
    return stream_8, accum_32, zero_skips


def fn_nvfp4_mag_2x(em: int) -> int:
    lut = {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 6, 6: 8, 7: 12}
    return lut[int(em) & 0x7]


def dot_engine_eval(
    mode: int,
    act_vec_bytes: List[int],
    wt_vec_bytes: List[int],
    act_scale_e8m0: int,
    wt_scale_e8m0: int,
    prev_accum: int = 0,
    accum_en: bool = True,
    accum_clear: bool = False,
) -> Dict[str, int]:
    """Bit-exact model of rtl/groq_mxfp8_nvfp4_dot_engine.sv."""
    act_128 = 0
    wt_128 = 0
    for i in range(16):
        act_128 |= (int(act_vec_bytes[i]) & 0xFF) << (i * 8)
        wt_128 |= (int(wt_vec_bytes[i]) & 0xFF) << (i * 8)

    block_zero_skip = (act_scale_e8m0 == 0) or (wt_scale_e8m0 == 0)
    nan_inf = 0

    if mode == MODE_NVFP4_E2M1:
        zero_cnt = 0
        tree_sum = 0
        for k in range(32):
            a_nib = (act_128 >> (k * 4)) & 0xF
            w_nib = (wt_128 >> (k * 4)) & 0xF
            is_z = block_zero_skip or ((a_nib & 0x7) == 0) or ((w_nib & 0x7) == 0)
            if is_z:
                zero_cnt += 1
            else:
                prod = fn_nvfp4_mag_2x(a_nib & 0x7) * fn_nvfp4_mag_2x(w_nib & 0x7)
                p_sign = ((a_nib >> 3) ^ (w_nib >> 3)) & 1
                tree_sum += -prod if p_sign else prod
        if block_zero_skip or zero_cnt == 32:
            tree_sum = 0
    else:  # MODE_W4A8_MIXED
        zero_cnt = 0
        tree_sum = 0
        for i in range(16):
            a_byte = (act_128 >> (i * 8)) & 0xFF
            w_nib = (wt_128 >> (i * 4)) & 0xF
            if (a_byte & 0x7F) == 0x7F:
                nan_inf = 1
            is_z = block_zero_skip or ((a_byte & 0x7F) == 0) or ((w_nib & 0x7) == 0)
            if is_z:
                zero_cnt += 1
            else:
                a_s = (a_byte >> 7) & 1
                w_s = (w_nib >> 3) & 1
                p_sign = a_s ^ w_s
                a_e4 = (a_byte >> 3) & 0xF
                a_ee4 = 1 if a_e4 == 0 else a_e4
                a_sig4 = (a_byte & 0x7) if a_e4 == 0 else (0x8 | (a_byte & 0x7))
                w_mag = fn_nvfp4_mag_2x(w_nib & 0x7)
                aligned = (a_sig4 * w_mag) << a_ee4
                tree_sum += -aligned if p_sign else aligned
        if block_zero_skip or zero_cnt == 16:
            tree_sum = 0

    s2_sign = 1 if tree_sum < 0 else 0
    s2_abs_mag = (-tree_sum) & 0xFFFFFFFF if tree_sum < 0 else (tree_sum & 0xFFFFFFFF)
    scale_sum = (act_scale_e8m0 & 0xFF) + (wt_scale_e8m0 & 0xFF)
    if scale_sum >= 254:
        lsh = min(7, scale_sum - 254)
        shifted_mag = s2_abs_mag << lsh
    else:
        rsh = min(7, 254 - scale_sum)
        shifted_mag = s2_abs_mag >> rsh

    if block_zero_skip or tree_sum == 0 or shifted_mag == 0:
        unaccum_dot = 0
    else:
        sat_mag = 0x7FFFFFFF if (shifted_mag >> 31) != 0 else (shifted_mag & 0x7FFFFFFF)
        unaccum_dot = -sat_mag if s2_sign else sat_mag

    base_acc = 0 if accum_clear else prev_accum
    if not accum_en:
        accum_next = 0 if accum_clear else unaccum_dot
    else:
        s_ext = base_acc + unaccum_dot
        if s_ext > 2147483647:
            accum_next = 2147483647
        elif s_ext < -2147483647:
            accum_next = -2147483647
        else:
            accum_next = s_ext

    # IEEE-754 FP32 normalizer
    msb_idx = 0
    for b in range(31):
        if (s2_abs_mag >> b) & 1:
            msb_idx = b
    norm_shift = (s2_abs_mag << (31 - msb_idx)) & 0xFFFFFFFF
    fp32_exp_wide = scale_sum + msb_idx - 127
    if nan_inf:
        fp32_word = 0x7FC00000
    elif block_zero_skip or s2_abs_mag == 0:
        fp32_word = 0x00000000
    elif fp32_exp_wide <= 0:
        fp32_word = (s2_sign << 31)
    elif fp32_exp_wide >= 255:
        fp32_word = (s2_sign << 31) | (0xFF << 23)
    else:
        fp32_word = (s2_sign << 31) | ((fp32_exp_wide & 0xFF) << 23) | ((norm_shift >> 8) & 0x7FFFFF)

    return {
        "unaccum_dot": int(unaccum_dot),
        "dot_accum": int(accum_next),
        "dot_fp32_hex": f"{fp32_word:08x}",
        "zero_skip_lanes": int(zero_cnt),
    }


def pack_vec128_hex(vec: list) -> str:
    val = 0
    for i in range(16):
        val |= (int(vec[i]) & 0xFF) << (i * 8)
    return f"{val:032x}"


def pack_vliw_144(
    target_slice: int = 0,
    icu_op: int = 0,
    mem_op: int = 0,
    sxm_op: int = 0,
    vxm_op: int = 0,
    mxm_op: int = 0,
    nim_op: int = 0,
    prec_mode: int = 0,
    src_stream_a: int = 0,
    src_stream_b: int = 0,
    dst_stream: int = 0,
    dst_dir_west: int = 0,
    sync_mask: int = 0,
    nop_delay_cnt: int = 0,
    mem_base_addr: int = 0,
    mem_stride: int = 0,
    vec_length: int = 0,
    sxm_shift_amt: int = 0,
    imm16: int = 0,
    trace_tag: int = 0,
) -> str:
    word = (
        ((target_slice & 0xF) << 140)
        | ((icu_op & 0xF) << 136)
        | ((mem_op & 0xF) << 132)
        | ((sxm_op & 0xF) << 128)
        | ((vxm_op & 0xF) << 124)
        | ((mxm_op & 0xF) << 120)
        | ((nim_op & 0xF) << 116)
        | ((prec_mode & 0xF) << 112)
        | ((src_stream_a & 0x1F) << 107)
        | ((src_stream_b & 0x1F) << 102)
        | ((dst_stream & 0x1F) << 97)
        | ((dst_dir_west & 0x1) << 96)
        | ((sync_mask & 0xFF) << 88)
        | ((nop_delay_cnt & 0xFFFF) << 72)
        | ((mem_base_addr & 0xFFFF) << 56)
        | ((mem_stride & 0xFF) << 48)
        | ((vec_length & 0xFF) << 40)
        | ((sxm_shift_amt & 0xFF) << 32)
        | ((imm16 & 0xFFFF) << 16)
        | (trace_tag & 0xFFFF)
    )
    return f"{word:036x}"


def build_8chip_mla_moe_tensors() -> dict:
    # Initial Token 0 prompt embedding vector (16 lanes, includes sparse zeros)
    x0_embed = [3, -2, 2, 0, -3, 1, 2, -2, 1, 0, -2, 3, 2, -1, 2, -1]
    # Decoupled RoPE sin(theta) rotational scale table
    rope_sin = [1, 1, 2, 2, 1, 1, -1, -1, 1, 1, 2, 2, -1, -1, 1, 1]

    chips = {}
    for cid in range(NUM_CHIPS):
        rng = np.random.default_rng(20261116 + cid * 137)

        def gen_mat(scale=2):
            m = rng.integers(-scale, scale + 1, size=(16, 16)).tolist()
            for r in range(16):
                for c in range(16):
                    if ((r + c + cid) % 4) == 0:
                        m[r][c] = 0
                    elif m[r][c] == 0 and ((r + c) % 3 == 1):
                        m[r][c] = 1 if ((r + cid) % 2 == 0) else -1
            return m

        W_Q = gen_mat(2)
        W_DKV = gen_mat(2)
        W_router = gen_mat(1)
        W_UKV = gen_mat(2)
        W_gate = gen_mat(2)
        W_up = gen_mat(2)
        W_down = gen_mat(1)

        # W4A8 and NVFP4 microscaling expert weight vectors (16 bytes = 32 nibbles)
        w4a8_wt = [int(x) for x in rng.integers(0, 256, size=16)]
        nvfp4_wt = [int(x) for x in rng.integers(0, 256, size=16)]
        w4a8_wt[cid % 16] = 0x00  # structured zero nibble for zero-skip telemetry
        nvfp4_wt[(cid + 3) % 16] = 0x00

        chips[cid] = {
            "W_Q": W_Q,
            "W_DKV": W_DKV,
            "W_router": W_router,
            "W_UKV": W_UKV,
            "W_gate": W_gate,
            "W_up": W_up,
            "W_down": W_down,
            "w4a8_wt": w4a8_wt,
            "nvfp4_wt": nvfp4_wt,
        }
    return {"x0_embed": x0_embed, "rope_sin": rope_sin, "chips": chips}


def compute_4token_autoregressive_golden(model: dict) -> dict:
    rope_sin = model["rope_sin"]
    # Current input embedding x^(t, c) per chip (at t=0, all 8 chips start with x0_embed)
    x_cur = {cid: list(model["x0_embed"]) for cid in range(NUM_CHIPS)}
    # On-chip SRAM AGU_KV_RING latent buffer per chip (16 rows x 16 cols, initialized to 0)
    kv_ring_cache = {cid: [[0] * 16 for _ in range(16)] for cid in range(NUM_CHIPS)}

    tokens_golden = []
    for t in range(NUM_TOKENS):
        bstage = BUTTERFLY_STAGES[t]
        per_chip = {}

        # Stage A & Stage B per chip (local MLA + growing KV-Ring Cache seq_len = t + 1)
        for cid in range(NUM_CHIPS):
            cm = model["chips"][cid]
            x_in = list(x_cur[cid])

            # Stage A: RMSNorm -> W_Q & W_DKV -> Decoupled RoPE -> AGU_KV_RING append
            x_sq = [sat_int8(to_s8(v) * to_s8(v)) for v in x_in]
            sum_sq_scalar = sum(to_s8(v) for v in x_sq)
            sum_sq_lane = sat_int8(sum_sq_scalar)
            rsqrt_scalar = rsqrt_lut_int8(sum_sq_lane)
            x_scaled = [sat_int8(to_s8(x_in[i]) * rsqrt_scalar) for i in range(16)]
            x_norm = [quant_scale_elem(to_s8(v), shamt=3, pmode=PREC_INT8) for v in x_scaled]

            q_raw, q_acc32, zs_q = mxm_contract_int8(x_norm, cm["W_Q"])
            c_kv_raw, _, zs_dkv = mxm_contract_int8(x_norm, cm["W_DKV"])
            r_logits, _, zs_rtr = mxm_contract_int8(x_norm, cm["W_router"])

            q_rot = rope_butterfly_swap(q_raw, mask=1, neg_even=True)
            q_rope = [
                sat_int8(to_s8(q_rot[i]) * to_s8(rope_sin[i]) + q_acc32[i])
                for i in range(16)
            ]
            c_kv_rope = rope_butterfly_swap(c_kv_raw, mask=1, neg_even=True)

            # Append c_kv_rope into on-chip AGU_KV_RING slot t (seq_len grows 1 -> 2 -> 3 -> 4)
            kv_ring_cache[cid][t] = list(c_kv_rope)
            kv_snapshot = [list(row) for row in kv_ring_cache[cid]]

            # Stage B: Causal Latent Attention over kv_ring_cache[0..t] + Softmax + W_UKV + Residual
            s_attn, _, zs_qk = mxm_contract_int8(q_rope, kv_snapshot)
            s_max = max(to_s8(v) for v in s_attn)
            s_shift = [sat_int8(to_s8(s_attn[i]) - s_max) for i in range(16)]
            p_exp = [exp_lut_int8(v) for v in s_shift]
            sum_exp_scalar = sum(to_s8(v) for v in p_exp)
            sum_exp_lane = sat_int8(sum_exp_scalar)
            p_attn = [quant_scale_elem(to_s8(v), shamt=3, pmode=PREC_INT8) for v in p_exp]
            o_attn, _, zs_ukv = mxm_contract_int8(p_attn, cm["W_UKV"])
            h_attn = [sat_int8(to_s8(x_norm[i]) + to_s8(o_attn[i])) for i in range(16)]

            per_chip[cid] = {
                "x_in": x_in,
                "x_norm": x_norm,
                "q_raw": q_raw,
                "q_rope": q_rope,
                "c_kv_raw": c_kv_raw,
                "c_kv_rope": c_kv_rope,
                "r_logits": r_logits,
                "kv_seq_len": t + 1,
                "s_attn": s_attn,
                "s_max": s_max,
                "p_exp": p_exp,
                "sum_exp_lane": sum_exp_lane,
                "p_attn": p_attn,
                "o_attn": o_attn,
                "h_attn": h_attn,
                "zs_ab": zs_q + zs_dkv + zs_rtr + zs_qk + zs_ukv,
            }

        # Stage C: 8-Chip Dragonfly MoE Router Gate + Butterfly AllToAll (dst = c ^ bstage)
        for cid in range(NUM_CHIPS):
            peer_cid = cid ^ bstage
            h_local = per_chip[cid]["h_attn"]
            h_peer = per_chip[peer_cid]["h_attn"]
            u_moe = [sat_int8(to_s8(h_local[i]) + to_s8(h_peer[i])) for i in range(16)]
            g_router = [silu_lut_int8(v) for v in per_chip[cid]["r_logits"]]
            e_in = [quant_scale_elem(to_s8(v), shamt=1, pmode=PREC_INT8) for v in u_moe]
            per_chip[cid]["butterfly_peer_chip"] = peer_cid
            per_chip[cid]["h_peer_rx"] = h_peer
            per_chip[cid]["u_moe"] = u_moe
            per_chip[cid]["g_router"] = g_router
            per_chip[cid]["e_in"] = e_in

        # Stage D: 8-Chip Parallel Expert SwiGLU FFN + W4A8/NVFP4 Dot Engine + Ring AllReduce
        for cid in range(NUM_CHIPS):
            cm = model["chips"][cid]
            e_in = per_chip[cid]["e_in"]
            g_ffn, _, zs_gate = mxm_contract_int8(e_in, cm["W_gate"])
            u_ffn, _, zs_up = mxm_contract_int8(e_in, cm["W_up"])
            h_swiglu = [
                sat_int8((silu_lut_int8(g_ffn[i]) * to_s8(u_ffn[i])) >> 6)
                for i in range(16)
            ]
            y_down, _, zs_down = mxm_contract_int8(h_swiglu, cm["W_down"])

            # Companion groq_mxfp8_nvfp4_dot_engine co-processor evaluations
            w4a8_res = dot_engine_eval(
                mode=MODE_W4A8_MIXED,
                act_vec_bytes=h_swiglu,
                wt_vec_bytes=cm["w4a8_wt"],
                act_scale_e8m0=127,
                wt_scale_e8m0=128,
                prev_accum=0,
                accum_en=True,
                accum_clear=True,
            )
            nvfp4_res = dot_engine_eval(
                mode=MODE_NVFP4_E2M1,
                act_vec_bytes=h_swiglu,
                wt_vec_bytes=cm["nvfp4_wt"],
                act_scale_e8m0=127,
                wt_scale_e8m0=127,
                prev_accum=w4a8_res["dot_accum"],
                accum_en=True,
                accum_clear=False,
            )

            per_chip[cid]["g_ffn"] = g_ffn
            per_chip[cid]["u_ffn"] = u_ffn
            per_chip[cid]["h_swiglu"] = h_swiglu
            per_chip[cid]["y_down"] = y_down
            per_chip[cid]["w4a8_dot"] = w4a8_res
            per_chip[cid]["nvfp4_dot"] = nvfp4_res
            per_chip[cid]["zero_skip_lanes"] = (
                per_chip[cid]["zs_ab"] + zs_gate + zs_up + zs_down
            )

        # 2-Step Chained Ring AllReduce over ROUTE_BIDIR_RING (Eastward c -> (c + 1) % 8)
        for cid in range(NUM_CHIPS):
            w1 = (cid - 1) % NUM_CHIPS
            w2 = (cid - 2) % NUM_CHIPS
            y_c = per_chip[cid]["y_down"]
            y_w1 = per_chip[w1]["y_down"]
            y_w2 = per_chip[w2]["y_down"]
            y_ring1 = [sat_int8(to_s8(y_c[i]) + to_s8(y_w1[i])) for i in range(16)]
            y_w1_ring1 = [sat_int8(to_s8(y_w1[i]) + to_s8(y_w2[i])) for i in range(16)]
            y_final = [sat_int8(to_s8(y_c[i]) + to_s8(y_w1_ring1[i])) for i in range(16)]
            per_chip[cid]["y_ring1"] = y_ring1
            per_chip[cid]["y_final"] = y_final
            # Autoregressive feedback: y^(t, c) becomes x^(t+1, c) in West SRAM (Bank 0, Addr 0)
            x_cur[cid] = list(y_final)

        tokens_golden.append(
            {
                "token_idx": t,
                "seq_len": t + 1,
                "butterfly_stage": bstage,
                "chips": per_chip,
            }
        )

    return {"tokens": tokens_golden}


def compile_8chip_4token_vliw_schedule(chip_id: int) -> List[List[str]]:
    imem = [
        [pack_vliw_144(target_slice=s, trace_tag=pc) for pc in range(MAX_PC)]
        for s in range(8)
    ]

    def emit(pc: int, s: int, **kwargs):
        imem[s][pc] = pack_vliw_144(target_slice=s, trace_tag=pc, **kwargs)

    for t in range(NUM_TOKENS):
        b = t * TOKEN_STRIDE
        bstage = BUTTERFLY_STAGES[t]
        peer_chip = chip_id ^ bstage
        east_ring_dst = (chip_id + 1) % NUM_CHIPS

        # ---------------------------------------------------------------------
        # STAGE A: MLA Input RMSNorm + W_Q / W_DKV / W_router + RoPE + AGU_KV_RING
        # ---------------------------------------------------------------------
        emit(b + 1, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | 0, dst_stream=0, dst_dir_west=0)
        emit(b + 2, SLICE_MEM_W, mem_op=MEM_STRIDE_CFG, mem_base_addr=(1 << 10) | (16 + t), mem_stride=1, vec_length=16, imm16=0x0002)
        emit(b + 4, SLICE_VXM, vxm_op=VXM_MUL, src_stream_a=0, src_stream_b=0, dst_stream=0, dst_dir_west=1)
        emit(b + 6, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
        emit(b + 8, SLICE_VXM, vxm_op=VXM_REDUCE_SUM, src_stream_a=1, dst_stream=0, dst_dir_west=1)
        emit(b + 10, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
        emit(b + 12, SLICE_VXM, vxm_op=VXM_RSQRT_LUT, src_stream_a=1, dst_stream=0, dst_dir_west=1)
        emit(b + 13, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | 0, dst_stream=0, dst_dir_west=0)
        emit(b + 14, SLICE_SXM, sxm_op=SXM_BROADCAST_LANE, src_stream_a=16, sxm_shift_amt=0x00, dst_stream=2, dst_dir_west=0)
        emit(b + 16, SLICE_VXM, vxm_op=VXM_MUL, src_stream_a=0, src_stream_b=2, dst_stream=0, dst_dir_west=1)
        emit(b + 18, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
        emit(b + 20, SLICE_VXM, vxm_op=VXM_QUANT_SCALE, src_stream_a=1, imm16=(3 << 5), dst_stream=0, dst_dir_west=1)
        emit(b + 22, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=3, dst_dir_west=0)
        emit(b + 23, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 0)
        emit(b + 28, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=3, mem_base_addr=(0 << 10) | 1)

        for r in range(16):
            emit(b + 25 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | (16 + r), dst_stream=4, dst_dir_west=0)
            emit(b + 29 + r, SLICE_MXM_W, mxm_op=MXM_LOAD_WEIGHT_B0, src_stream_b=4, imm16=r)
            emit(b + 41 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | (32 + r), dst_stream=5, dst_dir_west=0)
            emit(b + 47 + r, SLICE_MXM_E, mxm_op=MXM_LOAD_WEIGHT_B0, src_stream_b=5, imm16=r)
            emit(b + 57 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | (48 + r), dst_stream=4, dst_dir_west=0)
            emit(b + 61 + r, SLICE_MXM_W, mxm_op=MXM_LOAD_WEIGHT_B1, src_stream_b=4, imm16=r)

        emit(b + 28, SLICE_MXM_W, mxm_op=MXM_ACCUM_CLEAR)
        emit(b + 73, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 0, dst_stream=0, dst_dir_west=0)
        emit(b + 77, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=1, dst_dir_west=1)
        emit(b + 77, SLICE_MXM_E, mxm_op=MXM_ACCUM_CLEAR)
        emit(b + 79, SLICE_MXM_E, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=2, dst_dir_west=1)

        emit(b + 80, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | 1, dst_stream=2, dst_dir_west=0)
        emit(b + 81, SLICE_SXM, sxm_op=SXM_BUTTERFLY_SWAP, src_stream_a=17, imm16=0x0101, dst_stream=1, dst_dir_west=0)
        emit(b + 82, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=17, mem_base_addr=(3 << 10) | 1)
        emit(b + 83, SLICE_VXM, vxm_op=VXM_FMA, src_stream_a=1, src_stream_b=2, imm16=0x0100, dst_stream=0, dst_dir_west=1)

        emit(b + 85, SLICE_SXM, sxm_op=SXM_BUTTERFLY_SWAP, src_stream_a=18, imm16=0x0101, dst_stream=2, dst_dir_west=1)
        emit(b + 86, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 2)
        emit(b + 87, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=18, mem_base_addr=(1 << 10) | (16 + t), imm16=0x0008)

        emit(b + 84, SLICE_MXM_W, mxm_op=MXM_SWAP_WEIGHT)
        emit(b + 85, SLICE_MXM_W, mxm_op=MXM_ACCUM_CLEAR)
        emit(b + 84, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 0, dst_stream=0, dst_dir_west=0)
        emit(b + 88, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=3, dst_dir_west=1)
        emit(b + 93, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=19, mem_base_addr=(3 << 10) | 3)

        # ---------------------------------------------------------------------
        # STAGE B: MLA Causal Latent Attention over AGU_KV_RING + Softmax + W_UKV + Residual
        # ---------------------------------------------------------------------
        for r in range(16):
            emit(b + 94 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(1 << 10) | (16 + r), dst_stream=5, dst_dir_west=0)
            emit(b + 100 + r, SLICE_MXM_E, mxm_op=MXM_LOAD_WEIGHT_B1, src_stream_b=5, imm16=r)

        emit(b + 112, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 2, dst_stream=0, dst_dir_west=0)
        emit(b + 116, SLICE_MXM_E, mxm_op=MXM_SWAP_WEIGHT)
        emit(b + 117, SLICE_MXM_E, mxm_op=MXM_ACCUM_CLEAR)
        emit(b + 118, SLICE_MXM_E, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=1, dst_dir_west=1)

        emit(b + 125, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=17, mem_base_addr=(3 << 10) | 4)
        emit(b + 126, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 4, dst_stream=0, dst_dir_west=0)
        emit(b + 129, SLICE_VXM, vxm_op=VXM_REDUCE_MAX, src_stream_a=0, dst_stream=0, dst_dir_west=1)
        emit(b + 130, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 4, dst_stream=0, dst_dir_west=0)
        emit(b + 131, SLICE_SXM, sxm_op=SXM_BROADCAST_LANE, src_stream_a=16, sxm_shift_amt=0x00, dst_stream=2, dst_dir_west=0)
        emit(b + 133, SLICE_VXM, vxm_op=VXM_SUB, src_stream_a=0, src_stream_b=2, dst_stream=0, dst_dir_west=1)
        emit(b + 135, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
        emit(b + 137, SLICE_VXM, vxm_op=VXM_EXP_LUT, src_stream_a=1, dst_stream=0, dst_dir_west=1)
        emit(b + 139, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
        emit(b + 140, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 5)
        emit(b + 141, SLICE_VXM, vxm_op=VXM_REDUCE_SUM, src_stream_a=1, dst_stream=0, dst_dir_west=1)
        emit(b + 142, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 5, dst_stream=0, dst_dir_west=0)
        emit(b + 145, SLICE_VXM, vxm_op=VXM_QUANT_SCALE, src_stream_a=0, imm16=(3 << 5), dst_stream=0, dst_dir_west=1)
        emit(b + 148, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 6)

        for r in range(16):
            emit(b + 149 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(1 << 10) | (32 + r), dst_stream=5, dst_dir_west=0)
            emit(b + 155 + r, SLICE_MXM_E, mxm_op=MXM_LOAD_WEIGHT_B0, src_stream_b=5, imm16=r)

        emit(b + 167, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 6, dst_stream=0, dst_dir_west=0)
        emit(b + 171, SLICE_MXM_E, mxm_op=MXM_SWAP_WEIGHT)
        emit(b + 172, SLICE_MXM_E, mxm_op=MXM_ACCUM_CLEAR)
        emit(b + 173, SLICE_MXM_E, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=1, dst_dir_west=1)
        emit(b + 175, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 0, dst_stream=0, dst_dir_west=0)
        emit(b + 178, SLICE_VXM, vxm_op=VXM_ADD, src_stream_a=0, src_stream_b=17, dst_stream=0, dst_dir_west=1)
        emit(b + 180, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=17, mem_base_addr=(3 << 10) | 7)
        emit(b + 181, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 10)

        # ---------------------------------------------------------------------
        # STAGE C: 8-Chip Dragonfly MoE Router Gate + Butterfly AllToAll Dispatch
        # ---------------------------------------------------------------------
        emit(b + 182, SLICE_NIM, nim_op=NIM_SEND, src_stream_a=16, imm16=peer_chip)
        emit(b + 185, SLICE_NIM, nim_op=NIM_RECV, dst_stream=2, dst_dir_west=0)
        emit(b + 186, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 10, dst_stream=0, dst_dir_west=0)
        emit(b + 187, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 3, dst_stream=1, dst_dir_west=0)
        emit(b + 189, SLICE_VXM, vxm_op=VXM_ADD, src_stream_a=0, src_stream_b=2, dst_stream=0, dst_dir_west=1)
        emit(b + 190, SLICE_VXM, vxm_op=VXM_SILU, src_stream_a=1, dst_stream=1, dst_dir_west=1)
        emit(b + 192, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 11)
        emit(b + 193, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=17, mem_base_addr=(3 << 10) | 12)
        emit(b + 193, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=2, mem_base_addr=(0 << 10) | 3)
        emit(b + 194, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 11, dst_stream=0, dst_dir_west=0)
        emit(b + 197, SLICE_VXM, vxm_op=VXM_QUANT_SCALE, src_stream_a=0, imm16=(1 << 5), dst_stream=0, dst_dir_west=1)
        emit(b + 200, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 7)

        # ---------------------------------------------------------------------
        # STAGE D: 8-Chip Parallel Expert SwiGLU FFN + 2-Step Ring AllReduce -> x^(t+1)
        # ---------------------------------------------------------------------
        for r in range(16):
            emit(b + 201 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(2 << 10) | (0 + r), dst_stream=4, dst_dir_west=0)
            emit(b + 205 + r, SLICE_MXM_W, mxm_op=MXM_LOAD_WEIGHT_B0, src_stream_b=4, imm16=r)
            emit(b + 217 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(2 << 10) | (16 + r), dst_stream=5, dst_dir_west=0)
            emit(b + 223 + r, SLICE_MXM_E, mxm_op=MXM_LOAD_WEIGHT_B1, src_stream_b=5, imm16=r)
            emit(b + 233 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(2 << 10) | (32 + r), dst_stream=4, dst_dir_west=0)
            emit(b + 237 + r, SLICE_MXM_W, mxm_op=MXM_LOAD_WEIGHT_B1, src_stream_b=4, imm16=r)

        emit(b + 221, SLICE_MXM_W, mxm_op=MXM_SWAP_WEIGHT)
        emit(b + 239, SLICE_MXM_E, mxm_op=MXM_SWAP_WEIGHT)
        emit(b + 240, SLICE_MXM_E, mxm_op=MXM_ACCUM_CLEAR)
        emit(b + 253, SLICE_MXM_W, mxm_op=MXM_ACCUM_CLEAR)
        emit(b + 250, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 7, dst_stream=0, dst_dir_west=0)
        emit(b + 251, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 7, dst_stream=1, dst_dir_west=0)
        emit(b + 255, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=1, dst_stream=2, dst_dir_west=1)
        emit(b + 256, SLICE_MXM_E, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=3, dst_dir_west=1)
        emit(b + 259, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=18, dst_stream=1, dst_dir_west=0)
        emit(b + 260, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=18, mem_base_addr=(3 << 10) | 8)
        emit(b + 261, SLICE_VXM, vxm_op=VXM_SWIGLU, src_stream_a=1, src_stream_b=19, dst_stream=0, dst_dir_west=1)
        emit(b + 264, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 9)

        emit(b + 256, SLICE_MXM_W, mxm_op=MXM_SWAP_WEIGHT)
        emit(b + 257, SLICE_MXM_W, mxm_op=MXM_ACCUM_CLEAR)
        emit(b + 263, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=2, dst_dir_west=0)
        emit(b + 266, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=2, dst_stream=0, dst_dir_west=1)
        emit(b + 271, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 13)
        emit(b + 272, SLICE_NIM, nim_op=NIM_SEND, src_stream_a=16, imm16=east_ring_dst)
        emit(b + 273, SLICE_MEM_W, mem_op=MEM_READ_WEST, mem_base_addr=(3 << 10) | 13, dst_stream=0, dst_dir_west=1)
        emit(b + 275, SLICE_NIM, nim_op=NIM_ALLREDUCE_ADD, src_stream_a=16, dst_stream=4, dst_dir_west=0, imm16=east_ring_dst)
        emit(b + 276, SLICE_MEM_W, mem_op=MEM_READ_WEST, mem_base_addr=(3 << 10) | 13, dst_stream=0, dst_dir_west=1)
        emit(b + 278, SLICE_NIM, nim_op=NIM_ALLREDUCE_ADD, src_stream_a=16, dst_stream=4, dst_dir_west=0, imm16=east_ring_dst)
        emit(b + 280, SLICE_MEM_W, mem_op=MEM_WRITE_EAST, src_stream_a=4, mem_base_addr=(0 << 10) | 0)
        emit(b + 283, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=4, mem_base_addr=(0 << 10) | 4)
        emit(b + 286, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=4, mem_base_addr=(0 << 10) | (10 + t))
        emit(b + 285, SLICE_MXM_W, mxm_op=MXM_SWAP_WEIGHT)
        emit(b + 285, SLICE_MXM_E, mxm_op=MXM_SWAP_WEIGHT)

    halt_pc = NUM_TOKENS * TOKEN_STRIDE + 5
    for s in range(8):
        emit(halt_pc, s, icu_op=ICU_HALT)
    return imem


def export_all(out_dir: str):
    vec_dir = os.path.join(out_dir, "vectors")
    os.makedirs(vec_dir, exist_ok=True)

    model = build_8chip_mla_moe_tensors()
    golden = compute_4token_autoregressive_golden(model)

    for cid in range(NUM_CHIPS):
        imem = compile_8chip_4token_vliw_schedule(cid)
        for s in range(8):
            with open(os.path.join(vec_dir, f"chip{cid}_imem_s{s}.hex"), "w") as f:
                for line in imem[s]:
                    f.write(line + "\n")

        cm = model["chips"][cid]
        preload_entries = [
            (0, 0, pack_vec128_hex(model["x0_embed"])),
            (0, 1, pack_vec128_hex(model["rope_sin"])),
        ]
        for r in range(16):
            preload_entries.append((0, 16 + r, pack_vec128_hex(cm["W_Q"][r])))
        for r in range(16):
            preload_entries.append((0, 32 + r, pack_vec128_hex(cm["W_DKV"][r])))
        for r in range(16):
            preload_entries.append((0, 48 + r, pack_vec128_hex(cm["W_router"][r])))
        for r in range(16):
            preload_entries.append((1, 16 + r, pack_vec128_hex([0] * 16)))
        for r in range(16):
            preload_entries.append((1, 32 + r, pack_vec128_hex(cm["W_UKV"][r])))
        for r in range(16):
            preload_entries.append((2, 0 + r, pack_vec128_hex(cm["W_gate"][r])))
        for r in range(16):
            preload_entries.append((2, 16 + r, pack_vec128_hex(cm["W_up"][r])))
        for r in range(16):
            preload_entries.append((2, 32 + r, pack_vec128_hex(cm["W_down"][r])))

        with open(os.path.join(vec_dir, f"chip{cid}_sram_preload.txt"), "w") as f:
            for b_id, addr, hex_str in preload_entries:
                f.write(f"{b_id} {addr} {hex_str}\n")

        with open(os.path.join(vec_dir, f"chip{cid}_dot_weights.hex"), "w") as f:
            f.write(pack_vec128_hex(cm["w4a8_wt"]) + "\n")
            f.write(pack_vec128_hex(cm["nvfp4_wt"]) + "\n")

    # Export golden hex table for SystemVerilog testbench automatic comparison
    with open(os.path.join(vec_dir, "golden_tokens_8chip.txt"), "w") as f:
        for t in range(NUM_TOKENS):
            tok = golden["tokens"][t]
            for cid in range(NUM_CHIPS):
                cg = tok["chips"][cid]
                f.write(
                    f"{t} {cid} "
                    f"{pack_vec128_hex(cg['x_in'])} "
                    f"{pack_vec128_hex(cg['x_norm'])} "
                    f"{pack_vec128_hex(cg['q_rope'])} "
                    f"{pack_vec128_hex(cg['c_kv_rope'])} "
                    f"{pack_vec128_hex(cg['s_attn'])} "
                    f"{pack_vec128_hex(cg['p_attn'])} "
                    f"{pack_vec128_hex(cg['o_attn'])} "
                    f"{pack_vec128_hex(cg['h_attn'])} "
                    f"{pack_vec128_hex(cg['h_peer_rx'])} "
                    f"{pack_vec128_hex(cg['e_in'])} "
                    f"{pack_vec128_hex(cg['h_swiglu'])} "
                    f"{pack_vec128_hex(cg['y_down'])} "
                    f"{pack_vec128_hex(cg['y_ring1'])} "
                    f"{pack_vec128_hex(cg['y_final'])} "
                    f"{cg['w4a8_dot']['unaccum_dot'] & 0xFFFFFFFF:08x} "
                    f"{cg['w4a8_dot']['dot_fp32_hex']} "
                    f"{cg['w4a8_dot']['zero_skip_lanes']:02x} "
                    f"{cg['nvfp4_dot']['unaccum_dot'] & 0xFFFFFFFF:08x} "
                    f"{cg['nvfp4_dot']['dot_accum'] & 0xFFFFFFFF:08x} "
                    f"{cg['nvfp4_dot']['dot_fp32_hex']} "
                    f"{cg['nvfp4_dot']['zero_skip_lanes']:02x}\n"
                )

    with open(os.path.join(out_dir, "golden_reference.json"), "w") as f:
        json.dump({"model": model, "golden": golden}, f, indent=2)

    print(f"[STAGE 16 GOLDEN] Exported 8-Chip x 4-Token MLA+MoE schedules & vectors to {vec_dir}")
    for t in range(NUM_TOKENS):
        tok = golden["tokens"][t]
        print(
            f"  Token {t} (seq_len={tok['seq_len']}, bstage={tok['butterfly_stage']}): "
            f"Chip0 x_in={tok['chips'][0]['x_in'][:4]}.. -> y_final={tok['chips'][0]['y_final'][:4]}.. | "
            f"Chip7 y_final={tok['chips'][7]['y_final'][:4]}.."
        )


if __name__ == "__main__":
    export_all(os.path.dirname(os.path.abspath(__file__)))
