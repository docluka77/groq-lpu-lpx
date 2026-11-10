#!/usr/bin/env python3
"""
Stage 9: End-to-End Deterministic LLM Token Decode VLIW Schedule Compiler &
Bit-Exact Python Golden Reference Generator for 2-Chip Groq LPU Cluster.
"""

import json
import os
from typing import Dict, List, Tuple
import numpy as np

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

ICU_NOP          = 0
ICU_NOP_DELAY    = 1
ICU_SYNC_BARRIER = 2
ICU_NOTIFY       = 3
ICU_JUMP_IMM     = 4
ICU_REALSYNC_ADJ = 5
ICU_HALT         = 6

MEM_NOP        = 0
MEM_READ_EAST  = 1
MEM_READ_WEST  = 2
MEM_WRITE_EAST = 3
MEM_WRITE_WEST = 4
MEM_STRIDE_CFG = 5
MEM_BANK_SLEEP = 6

SXM_NOP            = 0
SXM_PASSTHROUGH    = 1
SXM_BARREL_ROTATE  = 2
SXM_TRANSPOSE_4X4  = 3
SXM_BIT_REVERSE    = 4
SXM_BROADCAST_LANE = 5
SXM_INTERLEAVE     = 6
SXM_ROTATE_LEFT    = 7
SXM_ROTATE_RIGHT   = 8
SXM_REVERSE        = 9
SXM_TRANSPOSE_LOAD = 10
SXM_TRANSPOSE_READ = 11
SXM_BUTTERFLY_SWAP = 12

VXM_NOP         = 0
VXM_ADD         = 1
VXM_MUL         = 2
VXM_FMA         = 3
VXM_SILU        = 4
VXM_GELU        = 5
VXM_RSQRT_LUT   = 6
VXM_EXP_LUT     = 7
VXM_SWIGLU      = 8
VXM_QUANT_SCALE = 9
VXM_SUB         = 10
VXM_MAX_ELEM    = 11
VXM_MIN_ELEM    = 12
VXM_RELU        = 13
VXM_REDUCE_SUM  = 14
VXM_REDUCE_MAX  = 15

MXM_NOP            = 0
MXM_LOAD_WEIGHT_B0 = 1
MXM_LOAD_WEIGHT_B1 = 2
MXM_SWAP_WEIGHT    = 3
MXM_SYSTOLIC_EXEC  = 4
MXM_ACCUM_FLUSH    = 5
MXM_ACCUM_CLEAR    = 6
MXM_ACCUM_PRELOAD  = 7

NIM_NOP           = 0
NIM_SEND          = 1
NIM_RECV          = 2
NIM_REALSYNC_PING = 3
NIM_FORWARD       = 4
NIM_ALLREDUCE_ADD = 5
NIM_DESKEW_CAL    = 6
NIM_LOOPBACK      = 7


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
            # In 8-bit two's complement, -(-128) wraps to -128
            out[i] = to_s8((-val) & 0xFF)
        else:
            out[i] = val
    return out


def mxm_contract_int8(act: list, wt_mat: list) -> Tuple[list, list, int]:
    """Returns (stream_out_s8[16], accum_32b[16], zero_skip_lanes)."""
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


def build_model_tensors() -> dict:
    # Input token embedding vector (16 lanes, includes sparse zeros to test zero-skip)
    x_embed = [2, -1, 3, 0, -2, 1, 2, -3, 1, 0, -1, 2, 3, -2, 1, -1]
    # RoPE sin(theta) rotational scale table
    rope_sin = [1, 1, 1, 1, 2, 2, 1, 1, -1, -1, 1, 1, 2, 2, -1, -1]

    chips = {}
    for cid in (0, 1):
        rng = np.random.default_rng(20261106 + cid * 101)
        # Small bounded INT8 weights in [-2, 2] with ~30% structured sparsity
        def gen_mat(scale=2):
            m = rng.integers(-scale, scale + 1, size=(16, 16)).tolist()
            for r in range(16):
                for c in range(16):
                    if ((r + c + cid) % 4) == 0:
                        m[r][c] = 0
            return m

        W_Q = gen_mat(2)
        W_K = gen_mat(2)
        W_V = gen_mat(1)
        K_cache_T = gen_mat(1)
        V_cache = gen_mat(1)
        W_gate = gen_mat(2)
        W_up = gen_mat(2)
        W_down = gen_mat(1)
        chips[cid] = {
            "W_Q": W_Q,
            "W_K": W_K,
            "W_V": W_V,
            "K_cache_T": K_cache_T,
            "V_cache": V_cache,
            "W_gate": W_gate,
            "W_up": W_up,
            "W_down": W_down,
        }
    return {"x_embed": x_embed, "rope_sin": rope_sin, "chips": chips}


def compute_golden_pipeline(model: dict) -> dict:
    x = model["x_embed"]
    rope_sin = model["rope_sin"]

    # Stage A: Input Embedding & Hardware RMSNorm
    x_sq = [sat_int8(to_s8(v) * to_s8(v)) for v in x]
    sum_sq_scalar = sum(to_s8(v) for v in x_sq)
    sum_sq_lane = sat_int8(sum_sq_scalar)
    rsqrt_scalar = rsqrt_lut_int8(sum_sq_lane)
    rsqrt_bcast = [rsqrt_scalar] * 16
    x_scaled = [sat_int8(to_s8(x[i]) * rsqrt_bcast[i]) for i in range(16)]
    x_norm = [quant_scale_elem(to_s8(v), shamt=3, pmode=PREC_INT8) for v in x_scaled]

    per_chip = {}
    for cid in (0, 1):
        cm = model["chips"][cid]
        # Stage B: QKV Projections + RoPE + KV-Cache Append
        q_raw, q_acc32, zs_q = mxm_contract_int8(x_norm, cm["W_Q"])
        k_raw, k_acc32, zs_k = mxm_contract_int8(x_norm, cm["W_K"])
        v_vec, v_acc32, zs_v = mxm_contract_int8(x_norm, cm["W_V"])

        q_rot = rope_butterfly_swap(q_raw, mask=1, neg_even=True)
        q_rope = [
            sat_int8(to_s8(q_rot[i]) * to_s8(rope_sin[i]) + q_acc32[i])
            for i in range(16)
        ]
        k_rope = rope_butterfly_swap(k_raw, mask=1, neg_even=True)

        # Stage C: GQA Attention Score (Q * K^T) & Numerically Stable Softmax + Score * V
        s_attn, _, zs_qk = mxm_contract_int8(q_rope, cm["K_cache_T"])
        s_max = max(to_s8(v) for v in s_attn)
        s_max_bcast = [s_max] * 16
        s_shift = [sat_int8(to_s8(s_attn[i]) - s_max_bcast[i]) for i in range(16)]
        p_exp = [exp_lut_int8(v) for v in s_shift]
        sum_exp_scalar = sum(to_s8(v) for v in p_exp)
        sum_exp_lane = sat_int8(sum_exp_scalar)
        p_attn = [quant_scale_elem(to_s8(v), shamt=3, pmode=PREC_INT8) for v in p_exp]
        o_attn, _, zs_sv = mxm_contract_int8(p_attn, cm["V_cache"])

        # Stage D: Fused SwiGLU FFN & Multi-Chip Dragonfly RealSync AllReduce
        g_ffn, _, zs_gate = mxm_contract_int8(o_attn, cm["W_gate"])
        u_ffn, _, zs_up = mxm_contract_int8(o_attn, cm["W_up"])
        h_swiglu = [
            sat_int8((silu_lut_int8(g_ffn[i]) * to_s8(u_ffn[i])) >> 6)
            for i in range(16)
        ]
        y_down, _, zs_down = mxm_contract_int8(h_swiglu, cm["W_down"])

        per_chip[cid] = {
            "q_raw": q_raw,
            "k_raw": k_raw,
            "v_vec": v_vec,
            "q_rot": q_rot,
            "q_rope": q_rope,
            "k_rope": k_rope,
            "s_attn": s_attn,
            "s_max": s_max,
            "s_shift": s_shift,
            "p_exp": p_exp,
            "sum_exp_scalar": sum_exp_scalar,
            "sum_exp_lane": sum_exp_lane,
            "p_attn": p_attn,
            "o_attn": o_attn,
            "g_ffn": g_ffn,
            "u_ffn": u_ffn,
            "h_swiglu": h_swiglu,
            "y_down": y_down,
            "zero_skip_macs": (zs_q + zs_k + zs_v + zs_qk + zs_sv + zs_gate + zs_up + zs_down) * 16,
            "zero_skip_lanes": zs_q + zs_k + zs_v + zs_qk + zs_sv + zs_gate + zs_up + zs_down,
        }

    y_final = [
        sat_int8(to_s8(per_chip[1]["y_down"][i]) + to_s8(per_chip[0]["y_down"][i]))
        for i in range(16)
    ]
    return {
        "stage_a": {
            "x_embed": x,
            "x_sq": x_sq,
            "sum_sq_scalar": sum_sq_scalar,
            "sum_sq_lane": sum_sq_lane,
            "rsqrt_scalar": rsqrt_scalar,
            "x_scaled": x_scaled,
            "x_norm": x_norm,
        },
        "chips": per_chip,
        "y_final_allreduce": y_final,
    }


def compile_vliw_schedule(chip_id: int) -> List[List[str]]:
    MAX_PC = 276
    imem = [
        [pack_vliw_144(target_slice=s, trace_tag=pc) for pc in range(MAX_PC)]
        for s in range(8)
    ]

    def emit(pc: int, s: int, **kwargs):
        imem[s][pc] = pack_vliw_144(target_slice=s, trace_tag=pc, **kwargs)

    # -------------------------------------------------------------------------
    # STAGE A: Input Embedding & Hardware RMSNorm (PC = 1 .. 28)
    # -------------------------------------------------------------------------
    # PC=1: MEM_W reads x_embed (Bank 0, Addr 0) -> E0
    emit(1, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | 0, dst_stream=0, dst_dir_west=0)
    # PC=2: MEM_W configures Write AGU in AGU_KV_RING (2'b10) for KV-Cache Ring Buffer (Bank 1, Addr 15)
    emit(2, SLICE_MEM_W, mem_op=MEM_STRIDE_CFG, mem_base_addr=(1 << 10) | 15, mem_stride=1, vec_length=16, imm16=0x0002)
    # PC=4: VXM computes x^2 = VXM_MUL(E0, E0) -> W0
    emit(4, SLICE_VXM, vxm_op=VXM_MUL, src_stream_a=0, src_stream_b=0, dst_stream=0, dst_dir_west=1)
    # PC=6: SXM reflects W0 -> E1
    emit(6, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
    # PC=8: VXM computes VXM_REDUCE_SUM(E1) -> W0
    emit(8, SLICE_VXM, vxm_op=VXM_REDUCE_SUM, src_stream_a=1, dst_stream=0, dst_dir_west=1)
    # PC=10: SXM reflects W0 -> E1
    emit(10, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
    # PC=12: VXM computes VXM_RSQRT_LUT(E1) -> W0
    emit(12, SLICE_VXM, vxm_op=VXM_RSQRT_LUT, src_stream_a=1, dst_stream=0, dst_dir_west=1)
    # PC=13: MEM_W re-reads x_embed (Bank 0, Addr 0) -> E0 (arrives at VXM at PC=16)
    emit(13, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | 0, dst_stream=0, dst_dir_west=0)
    # PC=14: SXM broadcasts lane 0 of W0 (rsqrt) across 16 lanes -> E2 (arrives at VXM at PC=16)
    emit(14, SLICE_SXM, sxm_op=SXM_BROADCAST_LANE, src_stream_a=16, sxm_shift_amt=0x00, dst_stream=2, dst_dir_west=0)
    # PC=16: VXM computes x_scaled = VXM_MUL(E0, E2) -> W0
    emit(16, SLICE_VXM, vxm_op=VXM_MUL, src_stream_a=0, src_stream_b=2, dst_stream=0, dst_dir_west=1)
    # PC=18: SXM reflects W0 -> E1
    emit(18, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
    # PC=20: VXM quantizes x_scaled (shift=3) -> W0
    emit(20, SLICE_VXM, vxm_op=VXM_QUANT_SCALE, src_stream_a=1, imm16=(3 << 5), dst_stream=0, dst_dir_west=1)
    # PC=22: SXM reflects x_norm (W0) -> E3 (to MEM_E checkpoint at PC=28)
    emit(22, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=3, dst_dir_west=0)
    # PC=23: MEM_W writes x_norm (W0) -> Bank 3, Addr 0
    emit(23, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 0)
    # PC=28: MEM_E writes Stage A checkpoint x_norm (E3) -> East Bank 0, Addr 1
    emit(28, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=3, mem_base_addr=(0 << 10) | 1)

    # -------------------------------------------------------------------------
    # STAGE B: Attention QKV Projection, RoPE & KV-Cache Ring Append (PC = 25 .. 96)
    # -------------------------------------------------------------------------
    for r in range(16):
        # Load W_Q[r] (Bank 0, Addr 16+r) -> E4 -> MXM_W Bank 0
        emit(25 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | (16 + r), dst_stream=4, dst_dir_west=0)
        emit(29 + r, SLICE_MXM_W, mxm_op=MXM_LOAD_WEIGHT_B0, src_stream_b=4, imm16=r)
        # Load W_K[r] (Bank 0, Addr 32+r) -> E5 -> MXM_E Bank 0
        emit(41 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | (32 + r), dst_stream=5, dst_dir_west=0)
        emit(47 + r, SLICE_MXM_E, mxm_op=MXM_LOAD_WEIGHT_B0, src_stream_b=5, imm16=r)
        # Load W_V[r] (Bank 0, Addr 48+r) -> E4 -> MXM_W Bank 1
        emit(57 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | (48 + r), dst_stream=4, dst_dir_west=0)
        emit(61 + r, SLICE_MXM_W, mxm_op=MXM_LOAD_WEIGHT_B1, src_stream_b=4, imm16=r)

    # Read x_norm (Bank 3, Addr 0) -> E0 at PC=73 (arrives MXM_W at 77, MXM_E at 79)
    emit(28, SLICE_MXM_W, mxm_op=MXM_ACCUM_CLEAR)
    emit(73, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 0, dst_stream=0, dst_dir_west=0)
    emit(77, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=1, dst_dir_west=1)
    emit(77, SLICE_MXM_E, mxm_op=MXM_ACCUM_CLEAR)
    emit(79, SLICE_MXM_E, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=2, dst_dir_west=1)

    # RoPE on q_raw: read sin(theta) at PC=80 -> E2; SXM_BUTTERFLY_SWAP(q_raw) at PC=81 -> E1; VXM_FMA at PC=83 -> W0
    emit(80, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(0 << 10) | 1, dst_stream=2, dst_dir_west=0)
    emit(81, SLICE_SXM, sxm_op=SXM_BUTTERFLY_SWAP, src_stream_a=17, imm16=0x0101, dst_stream=1, dst_dir_west=0)
    emit(82, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=17, mem_base_addr=(3 << 10) | 1)
    emit(83, SLICE_VXM, vxm_op=VXM_FMA, src_stream_a=1, src_stream_b=2, imm16=0x0100, dst_stream=0, dst_dir_west=1)

    # RoPE pair swap on k_raw (W2) at PC=85 -> W2; save q_rope at PC=86; append k_rope to AGU_KV_RING at PC=87
    emit(85, SLICE_SXM, sxm_op=SXM_BUTTERFLY_SWAP, src_stream_a=18, imm16=0x0101, dst_stream=2, dst_dir_west=1)
    emit(86, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 2)
    emit(87, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=18, mem_base_addr=(1 << 10) | 15, imm16=0x0008)

    # Execute V = x_norm * W_V on MXM_W Bank 1
    emit(84, SLICE_MXM_W, mxm_op=MXM_SWAP_WEIGHT)
    emit(85, SLICE_MXM_W, mxm_op=MXM_ACCUM_CLEAR)
    emit(84, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 0, dst_stream=0, dst_dir_west=0)
    emit(88, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=3, dst_dir_west=1)
    emit(89, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 2, dst_stream=3, dst_dir_west=0)
    emit(93, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=19, mem_base_addr=(3 << 10) | 3)
    emit(96, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=3, mem_base_addr=(0 << 10) | 2)

    # -------------------------------------------------------------------------
    # STAGE C: GQA Attention Score & Numerically Stable Softmax (PC = 94 .. 188)
    # -------------------------------------------------------------------------
    for r in range(16):
        # Load K_cache_T[r] (Bank 1, Addr 16+r) -> E5 -> MXM_E Bank 1
        emit(94 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(1 << 10) | (16 + r), dst_stream=5, dst_dir_west=0)
        emit(100 + r, SLICE_MXM_E, mxm_op=MXM_LOAD_WEIGHT_B1, src_stream_b=5, imm16=r)

    emit(112, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 2, dst_stream=0, dst_dir_west=0)
    emit(116, SLICE_MXM_E, mxm_op=MXM_SWAP_WEIGHT)
    emit(117, SLICE_MXM_E, mxm_op=MXM_ACCUM_CLEAR)
    emit(118, SLICE_MXM_E, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=1, dst_dir_west=1)

    # Save s_attn at PC=125, re-read at PC=126 -> E0 -> VXM_REDUCE_MAX at PC=129 -> W0
    emit(125, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=17, mem_base_addr=(3 << 10) | 4)
    emit(126, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 4, dst_stream=0, dst_dir_west=0)
    emit(129, SLICE_VXM, vxm_op=VXM_REDUCE_MAX, src_stream_a=0, dst_stream=0, dst_dir_west=1)
    emit(130, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 4, dst_stream=0, dst_dir_west=0)
    emit(131, SLICE_SXM, sxm_op=SXM_BROADCAST_LANE, src_stream_a=16, sxm_shift_amt=0x00, dst_stream=2, dst_dir_west=0)
    emit(133, SLICE_VXM, vxm_op=VXM_SUB, src_stream_a=0, src_stream_b=2, dst_stream=0, dst_dir_west=1)
    emit(135, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
    emit(137, SLICE_VXM, vxm_op=VXM_EXP_LUT, src_stream_a=1, dst_stream=0, dst_dir_west=1)
    emit(139, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=1, dst_dir_west=0)
    emit(140, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 5)
    emit(141, SLICE_VXM, vxm_op=VXM_REDUCE_SUM, src_stream_a=1, dst_stream=0, dst_dir_west=1)
    emit(142, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 5, dst_stream=0, dst_dir_west=0)
    emit(145, SLICE_VXM, vxm_op=VXM_QUANT_SCALE, src_stream_a=0, imm16=(3 << 5), dst_stream=0, dst_dir_west=1)
    emit(148, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 6)

    for r in range(16):
        # Load V_cache[r] (Bank 1, Addr 32+r) -> E5 -> MXM_E Bank 0
        emit(149 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(1 << 10) | (32 + r), dst_stream=5, dst_dir_west=0)
        emit(155 + r, SLICE_MXM_E, mxm_op=MXM_LOAD_WEIGHT_B0, src_stream_b=5, imm16=r)

    emit(167, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 6, dst_stream=0, dst_dir_west=0)
    emit(171, SLICE_MXM_E, mxm_op=MXM_SWAP_WEIGHT)
    emit(172, SLICE_MXM_E, mxm_op=MXM_ACCUM_CLEAR)
    emit(173, SLICE_MXM_E, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=1, dst_dir_west=1)
    emit(180, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=17, mem_base_addr=(3 << 10) | 7)
    emit(181, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 7, dst_stream=3, dst_dir_west=0)
    emit(188, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=3, mem_base_addr=(0 << 10) | 3)

    # -------------------------------------------------------------------------
    # STAGE D: Fused SwiGLU FFN & Multi-Chip RealSync AllReduce (PC = 182 .. 271)
    # -------------------------------------------------------------------------
    for r in range(16):
        emit(182 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(2 << 10) | (0 + r), dst_stream=4, dst_dir_west=0)
        emit(186 + r, SLICE_MXM_W, mxm_op=MXM_LOAD_WEIGHT_B0, src_stream_b=4, imm16=r)
        emit(198 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(2 << 10) | (16 + r), dst_stream=5, dst_dir_west=0)
        emit(204 + r, SLICE_MXM_E, mxm_op=MXM_LOAD_WEIGHT_B1, src_stream_b=5, imm16=r)
        emit(214 + r, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(2 << 10) | (32 + r), dst_stream=4, dst_dir_west=0)
        emit(218 + r, SLICE_MXM_W, mxm_op=MXM_LOAD_WEIGHT_B1, src_stream_b=4, imm16=r)

    emit(202, SLICE_MXM_W, mxm_op=MXM_SWAP_WEIGHT)
    emit(220, SLICE_MXM_E, mxm_op=MXM_SWAP_WEIGHT)
    emit(221, SLICE_MXM_E, mxm_op=MXM_ACCUM_CLEAR)
    emit(234, SLICE_MXM_W, mxm_op=MXM_ACCUM_CLEAR)
    emit(231, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 7, dst_stream=0, dst_dir_west=0)
    emit(232, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 7, dst_stream=1, dst_dir_west=0)
    emit(236, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=1, dst_stream=2, dst_dir_west=1)
    emit(237, SLICE_MXM_E, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=0, dst_stream=3, dst_dir_west=1)
    emit(240, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=18, dst_stream=1, dst_dir_west=0)
    emit(241, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=18, mem_base_addr=(3 << 10) | 8)
    emit(242, SLICE_VXM, vxm_op=VXM_SWIGLU, src_stream_a=1, src_stream_b=19, dst_stream=0, dst_dir_west=1)
    emit(245, SLICE_MEM_W, mem_op=MEM_WRITE_WEST, src_stream_a=16, mem_base_addr=(3 << 10) | 9)

    emit(237, SLICE_MXM_W, mxm_op=MXM_SWAP_WEIGHT)
    emit(238, SLICE_MXM_W, mxm_op=MXM_ACCUM_CLEAR)
    if chip_id == 0:
        emit(244, SLICE_SXM, sxm_op=SXM_PASSTHROUGH, src_stream_a=16, dst_stream=2, dst_dir_west=0)
        emit(247, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=2, dst_stream=0, dst_dir_west=1)
        emit(253, SLICE_NIM, nim_op=NIM_SEND, src_stream_a=16, imm16=0x0001)
        emit(259, SLICE_NIM, nim_op=NIM_RECV, dst_stream=4, dst_dir_west=0)
        emit(267, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=4, mem_base_addr=(0 << 10) | 0)
    else:
        emit(246, SLICE_MEM_W, mem_op=MEM_READ_EAST, mem_base_addr=(3 << 10) | 9, dst_stream=2, dst_dir_west=0)
        emit(250, SLICE_MXM_W, mxm_op=MXM_SYSTOLIC_EXEC, src_stream_a=2, dst_stream=0, dst_dir_west=1)
        emit(256, SLICE_NIM, nim_op=NIM_ALLREDUCE_ADD, src_stream_a=16, imm16=0x0000, dst_stream=4, dst_dir_west=0)
        emit(264, SLICE_MEM_E, mem_op=MEM_WRITE_EAST, src_stream_a=4, mem_base_addr=(0 << 10) | 0)

    for s in range(8):
        if s == SLICE_ICU:
            emit(270, s, icu_op=ICU_SYNC_BARRIER, sync_mask=0xFF)
        else:
            emit(270, s, icu_op=ICU_NOTIFY)
        emit(271, s, icu_op=ICU_HALT)

    return imem


def export_all(out_dir: str):
    os.makedirs(out_dir, exist_ok=True)
    model = build_model_tensors()
    golden = compute_golden_pipeline(model)

    for cid in (0, 1):
        imem = compile_vliw_schedule(cid)
        for s in range(8):
            with open(os.path.join(out_dir, f"chip{cid}_imem_s{s}.hex"), "w") as f:
                for word_hex in imem[s]:
                    f.write(word_hex + "\n")

        # Export West SRAM preload list (bank, addr, hex128)
        cm = model["chips"][cid]
        preload_entries = []
        preload_entries.append((0, 0, pack_vec128_hex(model["x_embed"])))
        preload_entries.append((0, 1, pack_vec128_hex(model["rope_sin"])))
        for r in range(16):
            preload_entries.append((0, 16 + r, pack_vec128_hex(cm["W_Q"][r])))
            preload_entries.append((0, 32 + r, pack_vec128_hex(cm["W_K"][r])))
            preload_entries.append((0, 48 + r, pack_vec128_hex(cm["W_V"][r])))
            preload_entries.append((1, 16 + r, pack_vec128_hex(cm["K_cache_T"][r])))
            preload_entries.append((1, 32 + r, pack_vec128_hex(cm["V_cache"][r])))
            preload_entries.append((2, 0 + r, pack_vec128_hex(cm["W_gate"][r])))
            preload_entries.append((2, 16 + r, pack_vec128_hex(cm["W_up"][r])))
            preload_entries.append((2, 32 + r, pack_vec128_hex(cm["W_down"][r])))

        with open(os.path.join(out_dir, f"chip{cid}_sram_preload.txt"), "w") as f:
            for b, a, h in preload_entries:
                f.write(f"{b} {a} {h}\n")

    golden_out = {
        "model": model,
        "golden": golden,
        "expected_hex": {
            "stage_a_x_norm": pack_vec128_hex(golden["stage_a"]["x_norm"]),
            "chip0_q_raw": pack_vec128_hex(golden["chips"][0]["q_raw"]),
            "chip0_q_rope": pack_vec128_hex(golden["chips"][0]["q_rope"]),
            "chip0_k_rope": pack_vec128_hex(golden["chips"][0]["k_rope"]),
            "chip0_v_vec": pack_vec128_hex(golden["chips"][0]["v_vec"]),
            "chip0_s_attn": pack_vec128_hex(golden["chips"][0]["s_attn"]),
            "chip0_p_exp": pack_vec128_hex(golden["chips"][0]["p_exp"]),
            "chip0_p_attn": pack_vec128_hex(golden["chips"][0]["p_attn"]),
            "chip0_o_attn": pack_vec128_hex(golden["chips"][0]["o_attn"]),
            "chip0_g_ffn": pack_vec128_hex(golden["chips"][0]["g_ffn"]),
            "chip0_u_ffn": pack_vec128_hex(golden["chips"][0]["u_ffn"]),
            "chip0_h_swiglu": pack_vec128_hex(golden["chips"][0]["h_swiglu"]),
            "chip0_y_down": pack_vec128_hex(golden["chips"][0]["y_down"]),
            "chip1_q_rope": pack_vec128_hex(golden["chips"][1]["q_rope"]),
            "chip1_k_rope": pack_vec128_hex(golden["chips"][1]["k_rope"]),
            "chip1_o_attn": pack_vec128_hex(golden["chips"][1]["o_attn"]),
            "chip1_h_swiglu": pack_vec128_hex(golden["chips"][1]["h_swiglu"]),
            "chip1_y_down": pack_vec128_hex(golden["chips"][1]["y_down"]),
            "y_final_allreduce": pack_vec128_hex(golden["y_final_allreduce"]),
        },
    }
    with open(os.path.join(out_dir, "golden_reference.json"), "w") as f:
        json.dump(golden_out, f, indent=2)
    print("[GOLDEN] Generated VLIW schedules & golden reference in", out_dir)
    print("  Stage A x_norm        :", golden["stage_a"]["x_norm"])
    print("  Stage B Chip0 q_rope  :", golden["chips"][0]["q_rope"])
    print("  Stage C Chip0 o_attn  :", golden["chips"][0]["o_attn"])
    print("  Stage D Chip0 y_down  :", golden["chips"][0]["y_down"])
    print("  Stage D Chip1 y_down  :", golden["chips"][1]["y_down"])
    print("  Stage D Final AllRed  :", golden["y_final_allreduce"])


if __name__ == "__main__":
    export_all(os.path.dirname(os.path.abspath(__file__)))
