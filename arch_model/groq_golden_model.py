#!/usr/bin/env python3
"""
Groq LPU (v1 TSP) & NVIDIA Groq 3 LPX (LP30) Bit-Exact Cycle-Accurate Golden Reference Model
and Deterministic Spatial Dataflow VLIW Compiler (`GroqWare` Golden Reference).

Simulates the canonical 8-hop Superlane spatial architecture:
  Hop 0: NIM    (Network Interface & RealSync Plesiochronous Deskew / Dragonfly Router)
  Hop 1: MEM_W  (West 44-Bank On-Chip SRAM Slice with SECDED Hamming(72,64) ECC & Tensor AGU)
  Hop 2: SXM    (Switch, 16x16 Transpose, Barrel Shift & Permute Slice)
  Hop 3: VXM    (16-Lane Vector SIMD ALU, LUT Activations, Tree Reduction, RMSNorm, RoPE, SwiGLU)
  Hop 4: MXM_W  (West 16x16 Systolic/Wavefront Matrix Multiply Slice with Ping-Pong Weight Buffers)
  Hop 5: ICU    (144-Bit VLIW Instruction Control Unit, NOP_DELAY, SYNC/NOTIFY, HAC/SAC Counters)
  Hop 6: MXM_E  (East 16x16 Systolic/Wavefront Matrix Multiply Slice with Ping-Pong Weight Buffers)
  Hop 7: MEM_E  (East 44-Bank On-Chip SRAM Slice with SECDED Hamming(72,64) ECC & Tensor AGU)
"""

import json
import math
import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import numpy as np

# ============================================================================
# 1. Architectural Constants & Spatial Coordinates
# ============================================================================
NUM_HOPS = 8
HOP_NIM = 0
HOP_MEM_W = 1
HOP_SXM = 2
HOP_VXM = 3
HOP_MXM_W = 4
HOP_ICU = 5
HOP_MXM_E = 6
HOP_MEM_E = 7

LANES_PER_SUPERLANE = 16
NUM_STREAMS = 32          # S0..S15: Eastward (+1 hop/cycle), S16..S31: Westward (-1 hop/cycle)
BANKS_PER_MEM_SLICE = 44  # 44 SRAM banks per hemisphere per superlane (88 banks total/superlane)
ROWS_PER_BANK = 4096

# Pipeline Latencies (cycles from instruction issue to stream fabric injection)
LATENCY_MEM_READ = 2      # Cycle t: SRAM read; Cycle t+1: SECDED ECC decode -> injected at t+2
LATENCY_MEM_WRITE = 1     # Samples stream at cycle t
LATENCY_SXM = 1           # Injected at t+1
LATENCY_VXM = 1           # Injected at t+1
LATENCY_MXM_EXEC = 2      # Stage 1: 16x16 Mul-Tree; Stage 2: Accum/Quant -> injected at t+2
LATENCY_NIM_RX = 1        # Injected at t+1

# ============================================================================
# 2. 144-Bit VLIW ISA Opcodes
# ============================================================================
# ICU_CTRL [143:128]
ICU_STEP = 0x0
ICU_NOP_DELAY = 0x1
ICU_SYNC = 0x2
ICU_NOTIFY = 0x3
ICU_HAC_CALIB = 0x4
ICU_LOOP_BEGIN = 0x5
ICU_LOOP_END = 0x6
ICU_HALT = 0xF

# MEM_W_OP [127:96] & MEM_E_OP [95:64]
MEM_NOP = 0b000
MEM_READ_STREAM = 0b001
MEM_WRITE_STREAM = 0b010
MEM_AGU_CONFIG = 0b011
MEM_AGU_READ_AUTO = 0b100
MEM_AGU_WRITE_AUTO = 0b101
MEM_BANK_SLEEP_CFG = 0b110
MEM_ECC_SCRUB = 0b111

# MXM_OP [63:44]
MXM_NOP = 0x0
MXM_LOAD_W_PING = 0x1
MXM_LOAD_W_PONG = 0x2
MXM_SWAP_W_BUF = 0x3
MXM_EXEC_MVM = 0x4
MXM_EXEC_MVM_ACC = 0x5
MXM_DRAIN_ACC = 0x6
MXM_CLEAR_ACC = 0x7

MXM_TGT_NONE = 0b00
MXM_TGT_WEST = 0b01
MXM_TGT_EAST = 0b10
MXM_TGT_BOTH = 0b11

PREC_INT8 = 0
PREC_FP8_E4M3 = 1
PREC_FP16 = 2
PREC_INT8_RNE = 3
PREC_INT32_FP32 = 4
SXM_BUTTERFLY_SWAP = 0x7
NIM_DESKEW_CAL = 0x3

# VXM_OP [43:20]
VXM_NOP = 0x00
VXM_VADD = 0x01
VXM_VSUB = 0x02
VXM_VMUL = 0x03
VXM_VFMA = 0x04
VXM_VMAX = 0x05
VXM_VMIN = 0x06
VXM_LUT_RELU = 0x07
VXM_LUT_GELU = 0x08
VXM_LUT_SILU = 0x09
VXM_LUT_EXP = 0x0A
VXM_LUT_RSQRT = 0x0B
VXM_SWIGLU_FUSED = 0x0C
VXM_RED_SUM = 0x0D
VXM_RED_MAX = 0x0E
VXM_RED_SUMSQ = 0x0F
VXM_RMSNORM_SCALE = 0x10
VXM_ROPE_ROTATE = 0x11
VXM_DYN_QUANT = 0x12

# SXM_OP [19:8]
SXM_NOP = 0x0
SXM_SHIFT_RIGHT = 0x1
SXM_SHIFT_LEFT = 0x2
SXM_ROTATE_LANES = 0x3
SXM_BCAST_LANE = 0x4
SXM_TRANSPOSE_PUSH = 0x5
SXM_TRANSPOSE_POP = 0x6
SXM_BUTTERFLY_SWIZZLE = 0x7
SXM_REVERSE_LANES = 0x8

# NIM_OP [7:0]
NIM_NOP = 0x0
NIM_TX_STREAM = 0x1
NIM_RX_STREAM = 0x2
NIM_REALSYNC_ALIGN = 0x3
NIM_ALLREDUCE_ADD = 0x4
NIM_DRAGONFLY_ROUTE = 0x5

# ============================================================================
# 3. Bit-Exact SECDED Hamming(72,64) ECC Engine (Matches groq_sram_ecc_secded.sv)
# ============================================================================
class SecdedHamming7264:
    """
    Bit-exact Single-Error-Correcting, Double-Error-Detecting (SECDED) Hsiao/Hamming(72,64)
    codec matching `sram_ip/groq_sram_ecc_secded.sv`.
    Each 128-bit superlane SRAM word is protected as two independent 64-bit data words -> 144 bits.
    Codeword layout [71:0]:
      - Bits [63:0]  : 64-bit payload data
      - Bits [70:64] : 7 Hamming parity bits P[6:0] covering standard binary positions 1..71
      - Bit  [71]    : Overall even parity bit P[7] across all 71 bits [70:0]
    """

    @staticmethod
    def _bit_pos_for_data(d_idx: int) -> int:
        # Map data bit index d_idx in 0..63 to non-power-of-2 position in 1..71
        pos = 3
        count = 0
        while True:
            if (pos & (pos - 1)) != 0:  # Not a power of 2
                if count == d_idx:
                    return pos
                count += 1
            pos += 1

    DATA_POS_MAP: Tuple[int, ...] = tuple(pos for pos in range(3, 72) if (pos & (pos - 1)) != 0)

    @classmethod
    def encode64(cls, data64: int) -> int:
        data64 &= (1 << 64) - 1
        p = 0
        for b in range(7):
            mask_bit = 1 << b
            parity_b = 0
            for d_idx, pos in enumerate(cls.DATA_POS_MAP):
                if pos & mask_bit:
                    parity_b ^= (data64 >> d_idx) & 1
            p |= (parity_b << b)
        cw71 = data64 | (p << 64)
        overall_p = bin(cw71).count("1") & 1
        return cw71 | (overall_p << 71)

    @classmethod
    def decode72(cls, cw72: int) -> Tuple[int, int, bool, bool]:
        """Returns (corrected_data64, syndrome8, single_err_corrected, double_err_detected)."""
        cw72 &= (1 << 72) - 1
        data64 = cw72 & ((1 << 64) - 1)
        stored_p = (cw72 >> 64) & 0x7F
        recalc_cw = cls.encode64(data64)
        recalc_p = (recalc_cw >> 64) & 0x7F
        syndrome7 = stored_p ^ recalc_p
        overall_err = bin(cw72).count("1") & 1
        syndrome8 = (overall_err << 7) | syndrome7

        if syndrome7 == 0 and overall_err == 0:
            return data64, 0, False, False
        if overall_err == 1:
            # Single-bit error (either in data or in parity bits, or in bit 71 if syndrome7==0)
            if syndrome7 in cls.DATA_POS_MAP:
                bit_to_flip = cls.DATA_POS_MAP.index(syndrome7)
                data64 ^= (1 << bit_to_flip)
            return data64, syndrome8, True, False
        # syndrome7 != 0 and overall_err == 0 -> Uncorrectable Double-Bit Error (DED)
        return data64, syndrome8, False, True


# ============================================================================
# 4. 144-Bit VLIW Instruction Bundle Representation & Pack/Unpack
# ============================================================================
@dataclass
class MemOp32:
    opcode: int = MEM_NOP
    stream_id: int = 0
    bank_id: int = 0
    stride_imm: int = 1
    row_addr: int = 0

    def pack(self) -> int:
        return (
            ((self.opcode & 0x7) << 29)
            | ((self.stream_id & 0x1F) << 24)
            | ((self.bank_id & 0x3F) << 18)
            | ((self.stride_imm & 0x3F) << 12)
            | (self.row_addr & 0xFFF)
        )

    @classmethod
    def unpack(cls, val: int) -> "MemOp32":
        return cls(
            opcode=(val >> 29) & 0x7,
            stream_id=(val >> 24) & 0x1F,
            bank_id=(val >> 18) & 0x3F,
            stride_imm=(val >> 12) & 0x3F,
            row_addr=val & 0xFFF,
        )


@dataclass
class VliwBundle144:
    """Complete 144-bit deterministic VLIW bundle dispatched by the ICU."""
    # ICU [143:128] (16 bits)
    icu_opcode: int = ICU_STEP
    barrier_mask: int = 0
    imm8: int = 0
    # MEM_W [127:96] (32 bits) & MEM_E [95:64] (32 bits)
    mem_w: MemOp32 = field(default_factory=MemOp32)
    mem_e: MemOp32 = field(default_factory=MemOp32)
    # MXM [63:44] (20 bits)
    mxm_opcode: int = MXM_NOP
    mxm_target: int = MXM_TGT_WEST
    mxm_prec: int = PREC_INT8
    mxm_act_s: int = 0
    mxm_dst_s: int = 16
    # VXM [43:20] (24 bits)
    vxm_opcode: int = VXM_NOP
    vxm_prec: int = PREC_INT8
    vxm_src_a: int = 0
    vxm_src_b: int = 1
    vxm_dst_s: int = 16
    # SXM [19:8] (12 bits)
    sxm_opcode: int = SXM_NOP
    sxm_shift_amt: int = 0
    sxm_stream_sel: int = 0
    # NIM [7:0] (8 bits)
    nim_opcode: int = NIM_NOP
    nim_link_sel: int = 0

    def pack144(self) -> int:
        icu_bits = ((self.icu_opcode & 0xF) << 12) | ((self.barrier_mask & 0xF) << 8) | (self.imm8 & 0xFF)
        mem_w_bits = self.mem_w.pack()
        mem_e_bits = self.mem_e.pack()
        mxm_bits = (
            ((self.mxm_opcode & 0xF) << 16)
            | ((self.mxm_target & 0x3) << 14)
            | ((self.mxm_prec & 0x3) << 12)
            | ((self.mxm_act_s & 0x3F) << 6)
            | (self.mxm_dst_s & 0x3F)
        )
        dst_msb = (self.vxm_dst_s >> 4) & 0x1
        src_b_enc = (dst_msb << 5) | (self.vxm_src_b & 0x1F)
        vxm_bits = (
            ((self.vxm_opcode & 0x1F) << 19)
            | ((self.vxm_prec & 0x7) << 16)
            | ((self.vxm_src_a & 0x3F) << 10)
            | ((src_b_enc & 0x3F) << 4)
            | (self.vxm_dst_s & 0xF)
        )
        sxm_bits = ((self.sxm_opcode & 0xF) << 8) | ((self.sxm_shift_amt & 0xF) << 4) | (self.sxm_stream_sel & 0xF)
        nim_bits = ((self.nim_opcode & 0xF) << 4) | (self.nim_link_sel & 0xF)
        return (
            (icu_bits << 128)
            | (mem_w_bits << 96)
            | (mem_e_bits << 64)
            | (mxm_bits << 44)
            | (vxm_bits << 20)
            | (sxm_bits << 8)
            | nim_bits
        )

    def to_hex36(self) -> str:
        return f"{self.pack144():036x}"


# ============================================================================
# 5. Spatial Stream Fabric Model (32 Streams x 8 Hops x 16 Lanes)
# ============================================================================
class StreamFabricModel:
    """
    Cycle-accurate model of `rtl/groq_stream_fabric.sv`.
    - Streams 0..15 flow Eastward: Hop x -> Hop x+1 every clock edge.
    - Streams 16..31 flow Westward: Hop x -> Hop x-1 every clock edge.
    - Detects any producer stream collision on the same (stream_id, hop).
    """

    def __init__(self) -> None:
        self.data = np.zeros((NUM_STREAMS, NUM_HOPS, LANES_PER_SUPERLANE), dtype=np.int32)
        self.valid = np.zeros((NUM_STREAMS, NUM_HOPS), dtype=bool)
        self._pending_injections: List[Tuple[int, int, np.ndarray, str]] = []
        self.collision_count: int = 0
        self.active_hop_transfers: int = 0

    def read_stream(self, stream_id: int, hop: int) -> Tuple[np.ndarray, bool]:
        return self.data[stream_id, hop].copy(), bool(self.valid[stream_id, hop])

    def schedule_inject(self, stream_id: int, hop: int, vec: np.ndarray, producer: str) -> None:
        assert 0 <= stream_id < NUM_STREAMS, f"Invalid stream_id {stream_id}"
        assert 0 <= hop < NUM_HOPS, f"Invalid hop {hop}"
        self._pending_injections.append((stream_id, hop, np.asarray(vec, dtype=np.int32).copy(), producer))

    def step_cycle(self) -> None:
        next_data = np.zeros_like(self.data)
        next_valid = np.zeros_like(self.valid)

        # 1. Propagate existing streams by 1 spatial hop
        # Eastward S[0..15]: hop x moves to hop x+1
        next_data[0:16, 1:NUM_HOPS, :] = self.data[0:16, 0:NUM_HOPS - 1, :]
        next_valid[0:16, 1:NUM_HOPS] = self.valid[0:16, 0:NUM_HOPS - 1]

        # Westward S[16..31]: hop x moves to hop x-1
        next_data[16:32, 0:NUM_HOPS - 1, :] = self.data[16:32, 1:NUM_HOPS, :]
        next_valid[16:32, 0:NUM_HOPS - 1] = self.valid[16:32, 1:NUM_HOPS]

        self.active_hop_transfers += int(np.sum(next_valid))

        # 2. Apply new injections from slices completing their pipeline this cycle
        for s_id, hop, vec, producer in self._pending_injections:
            if next_valid[s_id, hop]:
                self.collision_count += 1
                raise RuntimeError(
                    f"Deterministic Stream Collision on S{s_id} at Hop {hop} from producer {producer}!"
                )
            next_data[s_id, hop, :] = vec
            next_valid[s_id, hop] = True
            self.active_hop_transfers += 1

        self._pending_injections.clear()
        self.data = next_data
        self.valid = next_valid


# ============================================================================
# 6. Multi-Banked On-Chip SRAM Slice Model (MEM_W @ Hop 1, MEM_E @ Hop 7)
# ============================================================================
class MemSliceModel:
    """
    Cycle-accurate model of `sram_ip/groq_mem_slice.sv`, `groq_sram_macro_sp.sv`,
    `groq_sram_ecc_secded.sv`, and `groq_mem_agu.sv`.
    - 44 physical SRAM banks per superlane hemisphere.
    - Each row stores 16 lanes x 8-bit (128-bit payload) + 16-bit SECDED parity (two Hamming(72,64) codewords).
    - Read latency = 2 cycles (Cycle t: SRAM read -> Cycle t+1: ECC decode -> Injected into stream at t+2).
    """

    def __init__(self, name: str, hop_coord: int) -> None:
        self.name = name
        self.hop = hop_coord
        self.sram_payload = np.zeros((BANKS_PER_MEM_SLICE, ROWS_PER_BANK, LANES_PER_SUPERLANE), dtype=np.int32)
        self.sram_cw_lo = np.zeros((BANKS_PER_MEM_SLICE, ROWS_PER_BANK), dtype=object)
        self.sram_cw_hi = np.zeros((BANKS_PER_MEM_SLICE, ROWS_PER_BANK), dtype=object)
        self.bank_sleep = np.ones(BANKS_PER_MEM_SLICE, dtype=bool)  # Default retention sleep

        # Tensor AGU state
        self.agu_bank_base: int = 0
        self.agu_row_base: int = 0
        self.agu_row_stride: int = 1
        self.agu_step_idx: int = 0

        # Pipeline stage for 2-cycle read latency: list of (stream_id, vec16)
        self._read_stage_q: List[Tuple[int, np.ndarray]] = []
        self.ecc_single_err_count: int = 0
        self.ecc_double_err_count: int = 0
        self.sram_read_count: int = 0
        self.sram_write_count: int = 0

    @staticmethod
    def _vec16_to_dual64(vec: np.ndarray) -> Tuple[int, int]:
        u8 = np.asarray(vec, dtype=np.int32) & 0xFF
        w_lo = 0
        w_hi = 0
        for i in range(8):
            w_lo |= int(u8[i]) << (8 * i)
            w_hi |= int(u8[i + 8]) << (8 * i)
        return w_lo, w_hi

    @staticmethod
    def _dual64_to_vec16(w_lo: int, w_hi: int, signed: bool = True) -> np.ndarray:
        out = np.zeros(LANES_PER_SUPERLANE, dtype=np.int32)
        for i in range(8):
            b_lo = (w_lo >> (8 * i)) & 0xFF
            b_hi = (w_hi >> (8 * i)) & 0xFF
            if signed:
                out[i] = b_lo - 256 if b_lo >= 128 else b_lo
                out[i + 8] = b_hi - 256 if b_hi >= 128 else b_hi
            else:
                out[i] = b_lo
                out[i + 8] = b_hi
        return out

    def direct_write_row(self, bank: int, row: int, vec: np.ndarray) -> None:
        v = np.clip(np.asarray(vec, dtype=np.int32), -128, 127)
        self.sram_payload[bank, row, :] = v
        w_lo, w_hi = self._vec16_to_dual64(v)
        self.sram_cw_lo[bank, row] = SecdedHamming7264.encode64(w_lo)
        self.sram_cw_hi[bank, row] = SecdedHamming7264.encode64(w_hi)

    def inject_bit_fault(self, bank: int, row: int, bit_pos: int, high_word: bool = False) -> None:
        if high_word:
            self.sram_cw_hi[bank, row] = int(self.sram_cw_hi[bank, row]) ^ (1 << bit_pos)
        else:
            self.sram_cw_lo[bank, row] = int(self.sram_cw_lo[bank, row]) ^ (1 << bit_pos)

    def _ecc_read_row(self, bank: int, row: int) -> np.ndarray:
        cw_lo = int(self.sram_cw_lo[bank, row])
        cw_hi = int(self.sram_cw_hi[bank, row])
        if cw_lo == 0 and cw_hi == 0:
            return self.sram_payload[bank, row].copy()
        d_lo, _, sec_lo, ded_lo = SecdedHamming7264.decode72(cw_lo)
        d_hi, _, sec_hi, ded_hi = SecdedHamming7264.decode72(cw_hi)
        if sec_lo or sec_hi:
            self.ecc_single_err_count += int(sec_lo) + int(sec_hi)
        if ded_lo or ded_hi:
            self.ecc_double_err_count += int(ded_lo) + int(ded_hi)
        return self._dual64_to_vec16(d_lo, d_hi, signed=True)

    def execute(self, op: MemOp32, fabric: StreamFabricModel) -> None:
        # 1. Complete Stage-2 of prior cycle's SRAM read -> inject into StreamFabric at end of cycle t+1 (arrives at t+2)
        for s_id, vec in self._read_stage_q:
            fabric.schedule_inject(s_id, self.hop, vec, self.name)
        self._read_stage_q.clear()

        # Default: put all banks to retention sleep except active bank
        self.bank_sleep[:] = True

        if op.opcode == MEM_NOP:
            return
        elif op.opcode == MEM_READ_STREAM:
            self.bank_sleep[op.bank_id] = False
            self.sram_read_count += 1
            vec = self._ecc_read_row(op.bank_id, op.row_addr)
            self._read_stage_q.append((op.stream_id, vec))
        elif op.opcode == MEM_WRITE_STREAM:
            self.bank_sleep[op.bank_id] = False
            self.sram_write_count += 1
            vec, valid = fabric.read_stream(op.stream_id, self.hop)
            if not valid:
                raise RuntimeError(f"{self.name}: MEM_WRITE_STREAM read invalid stream S{op.stream_id} at Hop {self.hop}!")
            self.direct_write_row(op.bank_id, op.row_addr, vec)
        elif op.opcode == MEM_AGU_CONFIG:
            self.agu_bank_base = op.bank_id
            self.agu_row_base = op.row_addr
            self.agu_row_stride = max(1, op.stride_imm)
            self.agu_step_idx = 0
        elif op.opcode == MEM_AGU_READ_AUTO:
            r = (self.agu_row_base + self.agu_step_idx * self.agu_row_stride) % ROWS_PER_BANK
            self.agu_step_idx += 1
            self.bank_sleep[self.agu_bank_base] = False
            self.sram_read_count += 1
            vec = self._ecc_read_row(self.agu_bank_base, r)
            self._read_stage_q.append((op.stream_id, vec))
        elif op.opcode == MEM_ECC_SCRUB:
            self.bank_sleep[op.bank_id] = False
            corrected_vec = self._ecc_read_row(op.bank_id, op.row_addr)
            self.direct_write_row(op.bank_id, op.row_addr, corrected_vec)


# ============================================================================
# 7. SXM Switch, Transpose & Permute Slice Model (Hop 2)
# ============================================================================
class SxmSliceModel:
    """
    Cycle-accurate model of `rtl/groq_sxm_slice.sv` at Hop 2.
    Latency = 1 cycle (reads stream at cycle t, injects permuted vector at end of cycle t -> arrives at t+1).
    """

    def __init__(self, hop_coord: int = HOP_SXM) -> None:
        self.hop = hop_coord
        self.transpose_buf = np.zeros((LANES_PER_SUPERLANE, LANES_PER_SUPERLANE), dtype=np.int32)
        self.op_count: int = 0

    @staticmethod
    def negate_sat_int8(val: int) -> int:
        v = int(val)
        return 127 if v <= -128 else int(np.clip(-v, -128, 127))

    @classmethod
    def butterfly_swap_rope(
        cls,
        vec: np.ndarray,
        mask: int = 1,
        negate_odd_en: bool = False,
        rotate_pair_mode: bool = False,
    ) -> np.ndarray:
        out = np.zeros(LANES_PER_SUPERLANE, dtype=np.int32)
        m = mask & 0xF
        for i in range(LANES_PER_SUPERLANE):
            partner = int(vec[i ^ m])
            if (negate_odd_en or rotate_pair_mode) and ((i & 1) == 0):
                out[i] = cls.negate_sat_int8(partner)
            else:
                out[i] = int(np.clip(partner, -128, 127))
        return out

    def execute(self, bundle: VliwBundle144, fabric: StreamFabricModel) -> None:
        op = bundle.sxm_opcode
        if op == SXM_NOP:
            return
        self.op_count += 1
        k = bundle.sxm_shift_amt & 0xF
        s_in = bundle.sxm_stream_sel & 0xF
        # Output stream defaults to paired Westward stream (s_in + 16) or same Eastward stream s_in
        s_out = s_in

        if op == SXM_TRANSPOSE_POP:
            col_vec = self.transpose_buf[:, k].copy()
            fabric.schedule_inject(s_out, self.hop, col_vec, "SXM")
            return

        vec, valid = fabric.read_stream(s_in, self.hop)
        if not valid:
            raise RuntimeError(f"SXM: Read invalid stream S{s_in} at Hop {self.hop} for opcode {op}!")

        if op == SXM_TRANSPOSE_PUSH:
            self.transpose_buf[k, :] = vec
            return

        out = np.zeros(LANES_PER_SUPERLANE, dtype=np.int32)
        if op == SXM_SHIFT_RIGHT:
            if k < LANES_PER_SUPERLANE:
                out[k:] = vec[: LANES_PER_SUPERLANE - k]
        elif op == SXM_SHIFT_LEFT:
            if k < LANES_PER_SUPERLANE:
                out[: LANES_PER_SUPERLANE - k] = vec[k:]
        elif op == SXM_ROTATE_LANES:
            out = np.roll(vec, k)
        elif op == SXM_BCAST_LANE:
            out[:] = vec[k]
        elif op == SXM_BUTTERFLY_SWIZZLE:
            for i in range(LANES_PER_SUPERLANE):
                out[i] = vec[i ^ k]
        elif op == SXM_REVERSE_LANES:
            out = vec[::-1].copy()

        fabric.schedule_inject(s_out, self.hop, out, "SXM")


# ============================================================================
# 8. VXM 16-Lane Vector Execution Module Model (Hop 3)
# ============================================================================
class VxmSliceModel:
    """
    Cycle-accurate model of `rtl/groq_vxm_slice.sv` at Hop 3.
    Supports INT8/FP8/FP16/FP32 fixed-point scaled SIMD arithmetic, piecewise-linear LUTs
    (ReLU, GELU, SiLU, Exp, Rsqrt), Fused SwiGLU, 16-lane Tree Reductions, RMSNorm, and RoPE.
    Latency = 1 cycle (injected at end of cycle t -> arrives at t+1).
    """

    def __init__(self, hop_coord: int = HOP_VXM) -> None:
        self.hop = hop_coord
        self.acc_vec = np.zeros(LANES_PER_SUPERLANE, dtype=np.int32)
        self.cached_red_scalar: int = 16
        self.op_count: int = 0

    @staticmethod
    def quant_scale_elem(raw_val: int, shamt: int, pmode: int = PREC_INT8) -> int:
        raw_ext = int(raw_val)
        sh = int(shamt) & 0x7
        if sh == 0:
            rounded = raw_ext
        else:
            half_val = 1 << (sh - 1)
            rem_mask = (1 << sh) - 1
            is_exact_tie = (raw_ext & rem_mask) == half_val
            quot_lsb_even = ((raw_ext >> sh) & 1) == 0
            if pmode == PREC_INT8_RNE and is_exact_tie and quot_lsb_even:
                rounded = raw_ext >> sh
            else:
                rounded = (raw_ext + half_val) >> sh
        q_int8 = int(np.clip(rounded, -128, 127))
        if pmode == PREC_FP8_E4M3:
            if q_int8 == 127:
                return 126
            if q_int8 == -1:
                return -2
        return q_int8

    @staticmethod
    def _sat_int8(x: np.ndarray) -> np.ndarray:
        return np.clip(np.asarray(x, dtype=np.int32), -128, 127)

    @staticmethod
    def _silu_int8(x: np.ndarray) -> np.ndarray:
        # Fixed-point Q4.4 approximation matching piecewise-linear LUT in groq_vxm_slice.sv
        xf = x.astype(np.float64) / 16.0
        yf = xf / (1.0 + np.exp(-xf))
        return np.clip(np.round(yf * 16.0), -128, 127).astype(np.int32)

    @staticmethod
    def _gelu_int8(x: np.ndarray) -> np.ndarray:
        xf = x.astype(np.float64) / 16.0
        yf = 0.5 * xf * (1.0 + np.tanh(math.sqrt(2.0 / math.pi) * (xf + 0.044715 * (xf ** 3))))
        return np.clip(np.round(yf * 16.0), -128, 127).astype(np.int32)

    def execute(self, bundle: VliwBundle144, fabric: StreamFabricModel) -> None:
        op = bundle.vxm_opcode
        if op == VXM_NOP:
            return
        self.op_count += 1
        sa = bundle.vxm_src_a & 0x1F
        sb = bundle.vxm_src_b & 0x1F
        sd = bundle.vxm_dst_s & 0x1F

        va, val_a = fabric.read_stream(sa, self.hop)
        if not val_a:
            raise RuntimeError(f"VXM: Read invalid srcA stream S{sa} at Hop {self.hop} for opcode {op}!")

        needs_b = op in (VXM_VADD, VXM_VSUB, VXM_VMUL, VXM_VFMA, VXM_VMAX, VXM_VMIN, VXM_SWIGLU_FUSED, VXM_RMSNORM_SCALE, VXM_ROPE_ROTATE)
        if needs_b:
            vb, val_b = fabric.read_stream(sb, self.hop)
            if not val_b:
                raise RuntimeError(f"VXM: Read invalid srcB stream S{sb} at Hop {self.hop} for opcode {op}!")
        else:
            vb = np.zeros(LANES_PER_SUPERLANE, dtype=np.int32)

        if op == VXM_VADD:
            out = self._sat_int8(va + vb)
        elif op == VXM_VSUB:
            out = self._sat_int8(va - vb)
        elif op == VXM_VMUL:
            out = self._sat_int8((va * vb) >> 4)
        elif op == VXM_VFMA:
            self.acc_vec = self._sat_int8(self.acc_vec + ((va * vb) >> 4))
            out = self.acc_vec.copy()
        elif op == VXM_VMAX:
            out = np.maximum(va, vb)
        elif op == VXM_VMIN:
            out = np.minimum(va, vb)
        elif op == VXM_LUT_RELU:
            out = np.maximum(va, 0)
        elif op == VXM_LUT_GELU:
            out = self._gelu_int8(va)
        elif op == VXM_LUT_SILU:
            out = self._silu_int8(va)
        elif op == VXM_LUT_EXP:
            xf = np.clip(va.astype(np.float64) / 16.0, -8.0, 4.0)
            out = self._sat_int8(np.round(np.exp(xf) * 16.0))
        elif op == VXM_LUT_RSQRT:
            xf = np.maximum(va.astype(np.float64) / 16.0, 1.0 / 16.0)
            out = self._sat_int8(np.round((1.0 / np.sqrt(xf)) * 16.0))
        elif op == VXM_SWIGLU_FUSED:
            silu_a = self._silu_int8(va)
            out = self._sat_int8((silu_a * vb) >> 4)
        elif op == VXM_RED_SUM:
            s_val = int(np.clip(np.sum(va), -128, 127))
            self.cached_red_scalar = s_val
            out = np.full(LANES_PER_SUPERLANE, s_val, dtype=np.int32)
        elif op == VXM_RED_MAX:
            m_val = int(np.max(va))
            self.cached_red_scalar = m_val
            out = np.full(LANES_PER_SUPERLANE, m_val, dtype=np.int32)
        elif op == VXM_RED_SUMSQ:
            mean_sq = max(1, int(np.sum((va * va) >> 4)) // LANES_PER_SUPERLANE)
            inv_rms = int(round(16.0 / math.sqrt(mean_sq / 16.0)))
            self.cached_red_scalar = int(np.clip(inv_rms, 1, 127))
            out = np.full(LANES_PER_SUPERLANE, self.cached_red_scalar, dtype=np.int32)
        elif op == VXM_RMSNORM_SCALE:
            scaled = (va * self.cached_red_scalar) >> 4
            out = self._sat_int8((scaled * vb) >> 4)
        elif op == VXM_ROPE_ROTATE:
            out = np.zeros(LANES_PER_SUPERLANE, dtype=np.int32)
            for i in range(0, LANES_PER_SUPERLANE, 2):
                x0, x1 = int(va[i]), int(va[i + 1])
                c_val, s_val = int(vb[i]), int(vb[i + 1])
                out[i] = int(np.clip((x0 * c_val - x1 * s_val) >> 4, -128, 127))
                out[i + 1] = int(np.clip((x0 * s_val + x1 * c_val) >> 4, -128, 127))
        elif op == VXM_DYN_QUANT:
            amax = max(1, int(np.max(np.abs(va))))
            out = self._sat_int8((va * 64) // amax)
        else:
            out = va.copy()

        fabric.schedule_inject(sd, self.hop, out, "VXM")


# ============================================================================
# 9. MXM 16x16 Matrix Execution Module Model (MXM_W @ Hop 4, MXM_E @ Hop 6)
# ============================================================================
class MxmSliceModel:
    """
    Cycle-accurate model of `rtl/groq_mxm_slice.sv`.
    - Contains dual ping-pong 16x16 weight buffers (`w_buf[0]`, `w_buf[1]`) and `active_buf` pointer.
    - Supports zero-stall background weight loading into inactive buffer while active buffer executes.
    - 2-cycle MAC execution latency (Cycle t: 16x16 dot-product -> Cycle t+1: FP32/INT32 accum & quantize -> injected at t+2).
    """

    def __init__(self, name: str, hop_coord: int, target_mask: int) -> None:
        self.name = name
        self.hop = hop_coord
        self.target_mask = target_mask
        self.w_buf = np.zeros((2, LANES_PER_SUPERLANE, LANES_PER_SUPERLANE), dtype=np.int32)
        self.active_buf: int = 0
        self.acc_reg = np.zeros(LANES_PER_SUPERLANE, dtype=np.int32)
        self._exec_stage_q: List[Tuple[int, np.ndarray]] = []
        self.mac_ops_count: int = 0

    def execute(self, bundle: VliwBundle144, fabric: StreamFabricModel) -> None:
        # 1. Complete Stage-2 of prior cycle's MVM -> inject onto StreamFabric at end of t+1 (arrives at t+2)
        for s_id, vec in self._exec_stage_q:
            fabric.schedule_inject(s_id, self.hop, vec, self.name)
        self._exec_stage_q.clear()

        op = bundle.mxm_opcode
        if op == MXM_NOP or (bundle.mxm_target & self.target_mask) == 0:
            return

        act_s = bundle.mxm_act_s & 0x1F
        dst_s = bundle.mxm_dst_s & 0x1F
        row_idx = bundle.mxm_dst_s & 0xF

        if op == MXM_LOAD_W_PING:
            vec, valid = fabric.read_stream(act_s, self.hop)
            if not valid:
                raise RuntimeError(f"{self.name}: MXM_LOAD_W_PING read invalid stream S{act_s} at Hop {self.hop}!")
            self.w_buf[0, row_idx, :] = vec
        elif op == MXM_LOAD_W_PONG:
            vec, valid = fabric.read_stream(act_s, self.hop)
            if not valid:
                raise RuntimeError(f"{self.name}: MXM_LOAD_W_PONG read invalid stream S{act_s} at Hop {self.hop}!")
            self.w_buf[1, row_idx, :] = vec
        elif op == MXM_SWAP_W_BUF:
            self.active_buf ^= 1
        elif op == MXM_CLEAR_ACC:
            self.acc_reg[:] = 0
        elif op in (MXM_EXEC_MVM, MXM_EXEC_MVM_ACC):
            x_vec, valid = fabric.read_stream(act_s, self.hop)
            if not valid:
                raise RuntimeError(f"{self.name}: {op} read invalid activation stream S{act_s} at Hop {self.hop}!")
            w_mat = self.w_buf[self.active_buf]
            # 16x16 matrix-vector dot product: y[j] = sum_k x[k] * W[k, j]
            dot32 = np.matmul(x_vec.astype(np.int32), w_mat.astype(np.int32))
            self.mac_ops_count += LANES_PER_SUPERLANE * LANES_PER_SUPERLANE * 2
            if op == MXM_EXEC_MVM_ACC:
                self.acc_reg += dot32
                quant_out = np.clip(self.acc_reg >> 6, -128, 127).astype(np.int32)
            else:
                self.acc_reg = dot32.copy()
                quant_out = np.clip(dot32 >> 6, -128, 127).astype(np.int32)
                if op == MXM_EXEC_MVM:
                    self._exec_stage_q.append((dst_s, quant_out))
        elif op == MXM_DRAIN_ACC:
            quant_out = np.clip(self.acc_reg >> 6, -128, 127).astype(np.int32)
            self._exec_stage_q.append((dst_s, quant_out))
            self.acc_reg[:] = 0


# ============================================================================
# 10. NIM Network Interface & RealSync Plesiochronous Deskew Router (Hop 0)
# ============================================================================
class NimRealSyncModel:
    """
    Cycle-accurate model of `rtl/groq_nim_realsync.sv` at Hop 0 (ISCA 2022).
    Implements Hardware Aligned Counter (HAC), Software Aligned Counter (SAC),
    bounded plesiochronous drift deskew FIFO (+/-4 cycles), and Dragonfly C2C collectives.
    """

    def __init__(self, hop_coord: int = HOP_NIM, max_drift_cycles: int = 4) -> None:
        self.hop = hop_coord
        self.max_drift = max_drift_cycles
        self.hac_counter: int = 0
        self.sac_counter: int = 0
        self.drift_offset: int = 0
        self.hac_deskew_locked: bool = False
        self.rx_deskew_fifo: Dict[int, List[np.ndarray]] = {i: [] for i in range(4)}
        self.tx_egress_log: Dict[int, List[np.ndarray]] = {i: [] for i in range(4)}

    def calibrate_hac_consensus(
        self, incoming_target_cycle: int, peer_drift: int = 0, link_crc_err: bool = False
    ) -> Tuple[int, bool, int]:
        if not link_crc_err:
            self.hac_counter = (int(incoming_target_cycle) + 1) & 0xFFFF
            self.hac_deskew_locked = True
            self.drift_offset = int(peer_drift) >> 1
        else:
            self.hac_counter = (self.hac_counter + 1) & 0xFFFF
        eff_hac = (self.hac_counter + self.drift_offset) & 0xFFFF
        return self.hac_counter, self.hac_deskew_locked, eff_hac

    def enqueue_c2c_ingress(self, link_id: int, vec: np.ndarray, clock_drift: int = 0) -> None:
        assert abs(clock_drift) <= self.max_drift, f"Plesiochronous drift {clock_drift} exceeds bound {self.max_drift}!"
        self.drift_offset = clock_drift
        self.rx_deskew_fifo[link_id & 0x3].append(np.asarray(vec, dtype=np.int32).copy())

    def execute(self, bundle: VliwBundle144, fabric: StreamFabricModel) -> None:
        self.sac_counter += 1
        self.hac_counter = self.sac_counter + self.drift_offset
        op = bundle.nim_opcode
        link = bundle.nim_link_sel & 0x3
        if op == NIM_NOP:
            return
        elif op == NIM_REALSYNC_ALIGN:
            # Hardware deskew calibration aligns HAC to SAC within 1 cycle
            self.drift_offset = 0
            self.hac_counter = self.sac_counter
        elif op == NIM_TX_STREAM:
            s_id = 16 + link
            vec, valid = fabric.read_stream(s_id, self.hop)
            if not valid:
                raise RuntimeError(f"NIM: NIM_TX_STREAM read invalid stream S{s_id} at Hop 0!")
            self.tx_egress_log[link].append(vec)
        elif op == NIM_RX_STREAM:
            if not self.rx_deskew_fifo[link]:
                raise RuntimeError(f"NIM: Deskew FIFO underflow on C2C link {link}!")
            vec = self.rx_deskew_fifo[link].pop(0)
            fabric.schedule_inject(link, self.hop, vec, "NIM")
        elif op == NIM_ALLREDUCE_ADD:
            s_local = 16 + link
            local_vec, valid = fabric.read_stream(s_local, self.hop)
            if not valid or not self.rx_deskew_fifo[link]:
                raise RuntimeError(f"NIM: NIM_ALLREDUCE_ADD missing local stream S{s_local} or C2C FIFO {link}!")
            remote_vec = self.rx_deskew_fifo[link].pop(0)
            sum_vec = np.clip(local_vec + remote_vec, -128, 127).astype(np.int32)
            fabric.schedule_inject(link, self.hop, sum_vec, "NIM")


# ============================================================================
# 11. Top-Level Cycle-Accurate LPU Golden Simulator (Matches groq_lpu_top.sv)
# ============================================================================
class GroqLpuGoldenModel:
    """
    Full 8-Hop Superlane cycle-accurate golden simulator integrating:
      Hop 0: NIM, Hop 1: MEM_W, Hop 2: SXM, Hop 3: VXM,
      Hop 4: MXM_W, Hop 5: ICU, Hop 6: MXM_E, Hop 7: MEM_E.
    """

    def __init__(self) -> None:
        self.fabric = StreamFabricModel()
        self.nim = NimRealSyncModel(HOP_NIM)
        self.mem_w = MemSliceModel("MEM_W", HOP_MEM_W)
        self.sxm = SxmSliceModel(HOP_SXM)
        self.vxm = VxmSliceModel(HOP_VXM)
        self.mxm_w = MxmSliceModel("MXM_W", HOP_MXM_W, MXM_TGT_WEST)
        self.mxm_e = MxmSliceModel("MXM_E", HOP_MXM_E, MXM_TGT_EAST)
        self.mem_e = MemSliceModel("MEM_E", HOP_MEM_E)

        self.cycle_count: int = 0
        self.pc: int = 0
        self.halted: bool = False
        self.nop_delay_remaining: int = 0

    def step_bundle(self, bundle: VliwBundle144) -> None:
        # Execute all spatial slices in lock-step on current cycle's stream state
        self.nim.execute(bundle, self.fabric)
        self.mem_w.execute(bundle.mem_w, self.fabric)
        self.sxm.execute(bundle, self.fabric)
        self.vxm.execute(bundle, self.fabric)
        self.mxm_w.execute(bundle, self.fabric)
        self.mxm_e.execute(bundle, self.fabric)
        self.mem_e.execute(bundle.mem_e, self.fabric)

        if bundle.icu_opcode == ICU_HALT:
            self.halted = True

        # Advance spatial stream registers by 1 hop (Eastward +1, Westward -1)
        self.fabric.step_cycle()
        self.cycle_count += 1

    def run_program(self, program: List[VliwBundle144], max_cycles: int = 100000) -> int:
        self.pc = 0
        self.halted = False
        self.nop_delay_remaining = 0
        nop_bundle = VliwBundle144()

        while not self.halted and self.cycle_count < max_cycles and self.pc < len(program):
            if self.nop_delay_remaining > 0:
                self.nop_delay_remaining -= 1
                self.step_bundle(nop_bundle)
                continue

            bundle = program[self.pc]
            self.pc += 1
            if bundle.icu_opcode == ICU_NOP_DELAY:
                # Current cycle is first NOP cycle, plus imm8 additional NOP cycles
                self.nop_delay_remaining = bundle.imm8 & 0xFF
                self.step_bundle(nop_bundle)
            else:
                self.step_bundle(bundle)
        return self.cycle_count

    def estimate_energy_pJ(self) -> Dict[str, float]:
        """Physical energy breakdown model (4nm LP30 / ASAP7 calibrated pJ per event)."""
        sram_reads = self.mem_w.sram_read_count + self.mem_e.sram_read_count
        sram_writes = self.mem_w.sram_write_count + self.mem_e.sram_write_count
        mac_ops = self.mxm_w.mac_ops_count + self.mxm_e.mac_ops_count
        vxm_ops = self.vxm.op_count * LANES_PER_SUPERLANE
        hop_moves = self.fabric.active_hop_transfers

        e_sram_pJ = (sram_reads + sram_writes) * 16.0 * 2.1   # 2.1 pJ/Byte on-chip SRAM
        e_stream_pJ = hop_moves * 16.0 * 0.14                 # 0.14 pJ/Byte/hop abutment register
        e_mac_pJ = mac_ops * 0.08                             # 0.08 pJ/Op INT8/FP8 MAC
        e_vxm_pJ = vxm_ops * 0.15                             # 0.15 pJ/Op SIMD/LUT
        e_icu_pJ = self.cycle_count * 1.2                     # 1.2 pJ/cycle static VLIW fetch
        total_pJ = e_sram_pJ + e_stream_pJ + e_mac_pJ + e_vxm_pJ + e_icu_pJ
        return {
            "sram_pJ": round(e_sram_pJ, 2),
            "stream_pJ": round(e_stream_pJ, 2),
            "mac_pJ": round(e_mac_pJ, 2),
            "vxm_pJ": round(e_vxm_pJ, 2),
            "icu_pJ": round(e_icu_pJ, 2),
            "total_pJ": round(total_pJ, 2),
        }


# ============================================================================
# 12. Deterministic Spatial VLIW Compiler (`GroqWare` Scheduler)
# ============================================================================
class DeterministicTimeline:
    """Cycle-indexed VLIW schedule table that automatically computes exact hop arrival times."""

    def __init__(self) -> None:
        self.slots: Dict[int, VliwBundle144] = {}

    def bundle_at(self, cycle: int) -> VliwBundle144:
        if cycle not in self.slots:
            self.slots[cycle] = VliwBundle144()
        return self.slots[cycle]

    @staticmethod
    def arrival_cycle(issue_cycle: int, prod_latency: int, src_hop: int, dst_hop: int) -> int:
        return issue_cycle + prod_latency + abs(dst_hop - src_hop)

    def finalize_program(self, extra_drain_cycles: int = 2) -> List[VliwBundle144]:
        if not self.slots:
            return [VliwBundle144(icu_opcode=ICU_HALT)]
        max_t = max(self.slots.keys()) + extra_drain_cycles
        prog = [self.slots.get(t, VliwBundle144()) for t in range(max_t + 1)]
        prog.append(VliwBundle144(icu_opcode=ICU_HALT))
        return prog


class GroqDeterministicCompiler:
    """
    Statically schedules neural network kernels onto the 8-hop Groq LPU spatial pipeline
    with zero runtime arbitration and zero stream collisions.
    """

    @staticmethod
    def schedule_load_weights_west(
        tl: DeterministicTimeline, start_t: int, bank: int, base_row: int, stream_s: int = 0, pong: bool = False
    ) -> int:
        """Streams 16x16 weight matrix from MEM_W (Hop 1) to MXM_W (Hop 4) on Eastward stream `stream_s`."""
        op_load = MXM_LOAD_W_PONG if pong else MXM_LOAD_W_PING
        for r in range(16):
            t_read = start_t + r
            b_read = tl.bundle_at(t_read)
            b_read.mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=stream_s, bank_id=bank, row_addr=base_row + r)

            t_arr = tl.arrival_cycle(t_read, LATENCY_MEM_READ, HOP_MEM_W, HOP_MXM_W)  # t_read + 2 + 3 = t_read + 5
            b_mxm = tl.bundle_at(t_arr)
            b_mxm.mxm_opcode = op_load
            b_mxm.mxm_target = MXM_TGT_WEST
            b_mxm.mxm_act_s = stream_s
            b_mxm.mxm_dst_s = r
        return start_t + 16 + 5

    @staticmethod
    def schedule_load_weights_east(
        tl: DeterministicTimeline, start_t: int, bank: int, base_row: int, stream_s: int = 16, pong: bool = False
    ) -> int:
        """Streams 16x16 weight matrix from MEM_E (Hop 7) to MXM_E (Hop 6) on Westward stream `stream_s`."""
        op_load = MXM_LOAD_W_PONG if pong else MXM_LOAD_W_PING
        for r in range(16):
            t_read = start_t + r
            b_read = tl.bundle_at(t_read)
            b_read.mem_e = MemOp32(opcode=MEM_READ_STREAM, stream_id=stream_s, bank_id=bank, row_addr=base_row + r)

            t_arr = tl.arrival_cycle(t_read, LATENCY_MEM_READ, HOP_MEM_E, HOP_MXM_E)  # t_read + 2 + 1 = t_read + 3
            b_mxm = tl.bundle_at(t_arr)
            b_mxm.mxm_opcode = op_load
            b_mxm.mxm_target = MXM_TGT_EAST
            b_mxm.mxm_act_s = stream_s
            b_mxm.mxm_dst_s = r
        return start_t + 16 + 3

    @classmethod
    def compile_gemv_and_silu(
        cls, w_bank: int = 0, w_row: int = 0, x_bank: int = 1, x_row: int = 0, out_bank: int = 2, out_row: int = 0
    ) -> List[VliwBundle144]:
        """Compiles `y = SiLU(x * W)` chaining MEM_W -> MXM_W -> VXM -> MEM_W without intermediate SRAM writes."""
        tl = DeterministicTimeline()
        t_ready = cls.schedule_load_weights_west(tl, start_t=0, bank=w_bank, base_row=w_row, stream_s=0)

        # Read activation x from MEM_W (Hop 1) on S1 so it arrives at MXM_W (Hop 4) at t_ready
        t_x_read = t_ready - (LATENCY_MEM_READ + abs(HOP_MXM_W - HOP_MEM_W))
        tl.bundle_at(t_x_read).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=1, bank_id=x_bank, row_addr=x_row)

        # Execute MVM at MXM_W (Hop 4) -> outputs onto Westward S16
        b_mvm = tl.bundle_at(t_ready)
        b_mvm.mxm_opcode = MXM_EXEC_MVM
        b_mvm.mxm_target = MXM_TGT_WEST
        b_mvm.mxm_act_s = 1
        b_mvm.mxm_dst_s = 16

        # Arrives at VXM (Hop 3) on S16 at t_ready + 2 + 1 = t_ready + 3
        t_vxm = tl.arrival_cycle(t_ready, LATENCY_MXM_EXEC, HOP_MXM_W, HOP_VXM)
        b_vxm = tl.bundle_at(t_vxm)
        b_vxm.vxm_opcode = VXM_LUT_SILU
        b_vxm.vxm_src_a = 16
        b_vxm.vxm_dst_s = 17

        # Arrives at MEM_W (Hop 1) on S17 at t_vxm + 1 + 2 = t_vxm + 3
        t_wb = tl.arrival_cycle(t_vxm, LATENCY_VXM, HOP_VXM, HOP_MEM_W)
        tl.bundle_at(t_wb).mem_w = MemOp32(opcode=MEM_WRITE_STREAM, stream_id=17, bank_id=out_bank, row_addr=out_row)
        return tl.finalize_program()

    @classmethod
    def compile_rmsnorm(
        cls, x_bank: int = 0, x_row: int = 0, gamma_bank: int = 1, gamma_row: int = 0, out_bank: int = 2, out_row: int = 0
    ) -> List[VliwBundle144]:
        """Compiles RMSNorm: Pass 1 computes 1/sqrt(mean(x^2)+eps) in VXM; Pass 2 scales x * inv_rms * gamma."""
        tl = DeterministicTimeline()
        # Pass 1: Read x on S0 at t=0 -> arrives at VXM (Hop 3) at t = 0 + 2 + (3 - 1) = 4
        tl.bundle_at(0).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=0, bank_id=x_bank, row_addr=x_row)
        t_red = tl.arrival_cycle(0, LATENCY_MEM_READ, HOP_MEM_W, HOP_VXM)
        b_red = tl.bundle_at(t_red)
        b_red.vxm_opcode = VXM_RED_SUMSQ
        b_red.vxm_src_a = 0
        b_red.vxm_dst_s = 16

        # Pass 2: Read x on S1 at t=2 and gamma on S2 at t=3 -> align both at VXM at t=7 using SXM 1-cycle delay or sequential read
        # Better: Read x from MEM_W (Hop 1, t=4 -> arrives Hop 3 at t=8) and gamma from MEM_E (Hop 7, t=2 -> arrives Hop 3 at t=2+2+4=8)
        tl.bundle_at(4).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=1, bank_id=x_bank, row_addr=x_row)
        tl.bundle_at(2).mem_e = MemOp32(opcode=MEM_READ_STREAM, stream_id=18, bank_id=gamma_bank, row_addr=gamma_row)

        t_scale = 8
        b_scale = tl.bundle_at(t_scale)
        b_scale.vxm_opcode = VXM_RMSNORM_SCALE
        b_scale.vxm_src_a = 1
        b_scale.vxm_src_b = 18
        b_scale.vxm_dst_s = 17

        t_wb = tl.arrival_cycle(t_scale, LATENCY_VXM, HOP_VXM, HOP_MEM_W)  # 8 + 1 + 2 = 11
        tl.bundle_at(t_wb).mem_w = MemOp32(opcode=MEM_WRITE_STREAM, stream_id=17, bank_id=out_bank, row_addr=out_row)
        return tl.finalize_program()

    @classmethod
    def compile_rope(
        cls, q_bank: int = 0, q_row: int = 0, cs_bank: int = 0, cs_row: int = 0, out_bank: int = 2, out_row: int = 0
    ) -> List[VliwBundle144]:
        """Compiles Rotary Position Embedding (RoPE) pairing Q from MEM_W (Hop 1) and Cos/Sin from MEM_E (Hop 7)."""
        tl = DeterministicTimeline()
        # Q from MEM_W (Hop 1) at t=2 -> arrives at VXM (Hop 3) at t = 2 + 2 + 2 = 6
        # Cos/Sin from MEM_E (Hop 7) at t=0 -> arrives at VXM (Hop 3) at t = 0 + 2 + 4 = 6
        tl.bundle_at(2).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=1, bank_id=q_bank, row_addr=q_row)
        tl.bundle_at(0).mem_e = MemOp32(opcode=MEM_READ_STREAM, stream_id=18, bank_id=cs_bank, row_addr=cs_row)

        b_rope = tl.bundle_at(6)
        b_rope.vxm_opcode = VXM_ROPE_ROTATE
        b_rope.vxm_src_a = 1
        b_rope.vxm_src_b = 18
        b_rope.vxm_dst_s = 17

        t_wb = tl.arrival_cycle(6, LATENCY_VXM, HOP_VXM, HOP_MEM_W)  # 6 + 1 + 2 = 9
        tl.bundle_at(t_wb).mem_w = MemOp32(opcode=MEM_WRITE_STREAM, stream_id=17, bank_id=out_bank, row_addr=out_row)
        return tl.finalize_program()

    @classmethod
    def compile_llm_decode_layer(cls) -> Tuple[List[VliwBundle144], Dict[str, int]]:
        """
        Compiles an end-to-end deterministic Autoregressive LLM Decode Layer across all slices:
          Stage A: Preload W_gate (MXM_W Ping), W_up (MXM_E Ping), W_down (MXM_E Pong)
          Stage B: RMSNorm(x) -> x_norm (MEM_W bank 3, row 0)
          Stage C: Dual-Hemisphere Gate (MXM_W) + Up (MXM_E) projections aligned at VXM (Hop 3)
          Stage D: In-flight Fused SwiGLU(Gate, Up) at VXM (Hop 3) -> Eastward S5
          Stage E: Down Projection at MXM_E (Hop 6) using Pong weight buffer -> Writeback (MEM_E bank 3, row 0)
        """
        tl = DeterministicTimeline()
        # 1. Non-overlapping deterministic weight loads into MXM_W Ping (t=5..20), MXM_E Ping (t=21..36), MXM_E Pong (t=37..52)
        cls.schedule_load_weights_west(tl, start_t=0, bank=0, base_row=0, stream_s=0, pong=False)
        cls.schedule_load_weights_east(tl, start_t=18, bank=0, base_row=0, stream_s=16, pong=False)
        cls.schedule_load_weights_east(tl, start_t=34, bank=1, base_row=0, stream_s=16, pong=True)

        # 2. Execute RMSNorm on input token x (MEM_W bank 2, row 0) & gamma (MEM_E bank 2, row 0)
        tl.bundle_at(50).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=1, bank_id=2, row_addr=0)
        t_red = tl.arrival_cycle(50, LATENCY_MEM_READ, HOP_MEM_W, HOP_VXM)  # t=54
        b_red = tl.bundle_at(t_red)
        b_red.vxm_opcode = VXM_RED_SUMSQ
        b_red.vxm_src_a = 1
        b_red.vxm_dst_s = 17

        tl.bundle_at(54).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=2, bank_id=2, row_addr=0)
        tl.bundle_at(52).mem_e = MemOp32(opcode=MEM_READ_STREAM, stream_id=18, bank_id=2, row_addr=0)
        t_norm = 58  # Both arrive at VXM (Hop 3) at t=58
        b_norm = tl.bundle_at(t_norm)
        b_norm.vxm_opcode = VXM_RMSNORM_SCALE
        b_norm.vxm_src_a = 2
        b_norm.vxm_src_b = 18
        b_norm.vxm_dst_s = 17  # Send x_norm Westward to MEM_W (arrives Hop 1 at t=58+1+2=61)
        tl.bundle_at(61).mem_w = MemOp32(opcode=MEM_WRITE_STREAM, stream_id=17, bank_id=3, row_addr=0)

        # 3. Read x_norm for Up (MXM_E @ Hop 6, dist=5): issue at t=62 -> arrives MXM_E at t=62+2+5=69
        #    Read x_norm for Gate (MXM_W @ Hop 4, dist=3): issue at t=66 -> arrives MXM_W at t=66+2+3=71
        tl.bundle_at(62).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=3, bank_id=3, row_addr=0)
        tl.bundle_at(66).mem_w = MemOp32(opcode=MEM_READ_STREAM, stream_id=4, bank_id=3, row_addr=0)

        b_up = tl.bundle_at(69)
        b_up.mxm_opcode = MXM_EXEC_MVM
        b_up.mxm_target = MXM_TGT_EAST
        b_up.mxm_act_s = 3
        b_up.mxm_dst_s = 19  # Injected at Hop 6 at t=71 -> arrives VXM (Hop 3) at t=71+3=74

        b_gate = tl.bundle_at(71)
        b_gate.mxm_opcode = MXM_EXEC_MVM
        b_gate.mxm_target = MXM_TGT_WEST
        b_gate.mxm_act_s = 4
        b_gate.mxm_dst_s = 18  # Injected at Hop 4 at t=73 -> arrives VXM (Hop 3) at t=73+1=74

        # 4. At cycle t=74, BOTH Gate (S18) and Up (S19) arrive at VXM (Hop 3)! Execute Fused SwiGLU -> Eastward S5
        b_swiglu = tl.bundle_at(74)
        b_swiglu.vxm_opcode = VXM_SWIGLU_FUSED
        b_swiglu.vxm_src_a = 18
        b_swiglu.vxm_src_b = 19
        b_swiglu.vxm_dst_s = 5  # Injected at Hop 3 at t=75 -> arrives MXM_E (Hop 6, dist=3) at t=78

        # Swap MXM_E weight buffer from Ping (W_up) to Pong (W_down) at cycle t=75
        b_swap = tl.bundle_at(75)
        b_swap.mxm_opcode = MXM_SWAP_W_BUF
        b_swap.mxm_target = MXM_TGT_EAST

        # 5. At cycle t=78, execute Down Projection at MXM_E (Hop 6) -> Eastward S6 -> Writeback to MEM_E (Hop 7) at t=81
        b_down = tl.bundle_at(78)
        b_down.mxm_opcode = MXM_EXEC_MVM
        b_down.mxm_target = MXM_TGT_EAST
        b_down.mxm_act_s = 5
        b_down.mxm_dst_s = 6  # Injected at Hop 6 at t=80 -> arrives MEM_E (Hop 7, dist=1) at t=81

        tl.bundle_at(81).mem_e = MemOp32(opcode=MEM_WRITE_STREAM, stream_id=6, bank_id=3, row_addr=0)
        return tl.finalize_program(), {"x_norm_cycle": 61, "swiglu_cycle": 74, "down_wb_cycle": 81}

    @staticmethod
    def export_program_vectors(
        out_dir: str,
        name: str,
        program: List[VliwBundle144],
        golden_io: Dict[str, object],
    ) -> Tuple[str, str]:
        os.makedirs(out_dir, exist_ok=True)
        hex_path = os.path.join(out_dir, f"{name}_prog144.hex")
        json_path = os.path.join(out_dir, f"{name}_golden.json")

        with open(hex_path, "w", encoding="utf-8") as fh:
            for bundle in program:
                fh.write(bundle.to_hex36() + "\n")

        payload = {
            "kernel_name": name,
            "num_instructions": len(program),
            "instructions_hex144": [b.to_hex36() for b in program],
            "golden_io": golden_io,
        }
        with open(json_path, "w", encoding="utf-8") as fj:
            json.dump(payload, fj, indent=2)
        return hex_path, json_path




# ============================================================================
# 13. Phase II?IV Hardware IP Golden Models (MXFP8/NVFP4, C2C KV-Quant, SpecDecode, Droop, Scrubber)
# ============================================================================
class GroqMXFP8NVFP4DotEngineModel:
    MODE_INT8_SYM = 0
    MODE_MXFP8_E4M3 = 1
    MODE_MXFP8_E5M2 = 2
    MODE_NVFP4_E2M1 = 3
    MODE_BF16_PAIR = 4
    MODE_NVFP4_E4M3_SCALE = 5

    @staticmethod
    def _decode_e2m1(nibble: int) -> int:
        s = (nibble >> 3) & 1
        e = (nibble >> 1) & 3
        m = nibble & 1
        mag = m if e == 0 else ((2 | m) << (e - 1))
        return -mag if s else mag

    @classmethod
    def compute_dot(
        cls,
        mode: int,
        act_lanes: List[int],
        wt_lanes: List[int],
        act_scale: int = 127,
        wt_scale: int = 127,
        accum_in: int = 0,
        zero_skip_en: bool = True,
    ) -> Dict[str, object]:
        if mode == cls.MODE_NVFP4_E4M3_SCALE:
            a_low7 = act_scale & 0x7F
            w_low7 = wt_scale & 0x7F
            nan_inf = (a_low7 == 0x7F) or (w_low7 == 0x7F)
            block_zero = zero_skip_en and ((a_low7 == 0) or (w_low7 == 0) or all(x == 0 for x in act_lanes) or all(w == 0 for w in wt_lanes))
            if block_zero or nan_inf:
                return {"dot_out": int(accum_in), "block_zero_skip": block_zero, "nan_inf": nan_inf, "eff_exp": 0}
            raw_sum = sum(cls._decode_e2m1(a & 0xF) * cls._decode_e2m1(w & 0xF) for a, w in zip(act_lanes, wt_lanes))
            a_e4, a_m3 = (act_scale >> 3) & 0xF, act_scale & 0x7
            w_e4, w_m3 = (wt_scale >> 3) & 0xF, wt_scale & 0x7
            a_m4 = a_m3 if a_e4 == 0 else (8 | a_m3)
            w_m4 = w_m3 if w_e4 == 0 else (8 | w_m3)
            scaled_tree = (raw_sum * (a_m4 * w_m4)) >> 6
            eff_a_exp = 121 if a_e4 == 0 else (120 + a_e4)
            eff_w_exp = 121 if w_e4 == 0 else (120 + w_e4)
            shift = (eff_a_exp + eff_w_exp) - 254
            aligned = (scaled_tree << shift) if shift >= 0 else (scaled_tree >> (-shift))
            return {"dot_out": int(accum_in + aligned), "block_zero_skip": False, "nan_inf": False, "eff_exp": eff_a_exp + eff_w_exp}

        nan_inf = (mode in (cls.MODE_MXFP8_E4M3, cls.MODE_MXFP8_E5M2, cls.MODE_NVFP4_E2M1)) and ((act_scale == 0xFF) or (wt_scale == 0xFF))
        scale_zero = (mode in (cls.MODE_MXFP8_E4M3, cls.MODE_MXFP8_E5M2, cls.MODE_NVFP4_E2M1)) and ((act_scale == 0) or (wt_scale == 0))
        block_zero = zero_skip_en and (scale_zero or all(x == 0 for x in act_lanes) or all(w == 0 for w in wt_lanes))
        if block_zero or nan_inf:
            return {"dot_out": int(accum_in), "block_zero_skip": block_zero, "nan_inf": nan_inf, "eff_exp": 0}
        if mode == cls.MODE_NVFP4_E2M1:
            tree_sum = sum(cls._decode_e2m1(a & 0xF) * cls._decode_e2m1(w & 0xF) for a, w in zip(act_lanes, wt_lanes))
        else:
            tree_sum = sum(int(a) * int(w) for a, w in zip(act_lanes, wt_lanes))
        shift = 0 if mode == cls.MODE_INT8_SYM else ((act_scale + wt_scale) - 254)
        aligned = (tree_sum << shift) if shift >= 0 else (tree_sum >> (-shift))
        return {"dot_out": int(accum_in + aligned), "block_zero_skip": False, "nan_inf": False, "eff_exp": act_scale + wt_scale}


class GroqC2CKVQuantRxModel:
    QUANT_BF16_TO_MXFP8_E4M3 = 0
    QUANT_FP16_TO_MXFP8_E4M3 = 1
    QUANT_BF16_TO_NVFP4_E2M1 = 2
    QUANT_BYPASS_RAW128 = 3

    @classmethod
    def quantize_block(cls, quant_mode: int, raw16_lanes: List[int]) -> Dict[str, object]:
        assert len(raw16_lanes) == 16
        signs, exp8s, frac7s, is_zero, is_nan_inf, is_fin_nz = [], [], [], [], [], []
        for raw in raw16_lanes:
            r = int(raw) & 0xFFFF
            s = (r >> 15) & 1
            if quant_mode == cls.QUANT_FP16_TO_MXFP8_E4M3:
                e5 = (r >> 10) & 0x1F
                e8 = 0 if e5 == 0 else (255 if e5 == 31 else (e5 + 112))
                f7 = (r >> 3) & 0x7F
            else:
                e8 = (r >> 7) & 0xFF
                f7 = r & 0x7F
            signs.append(s); exp8s.append(e8); frac7s.append(f7)
            z = (e8 == 0); ni = (e8 == 255); fnz = (not z) and (not ni)
            is_zero.append(z); is_nan_inf.append(ni); is_fin_nz.append(fnz)
        e_max = max([e for e, fnz in zip(exp8s, is_fin_nz)], default=127)
        if quant_mode in (cls.QUANT_BF16_TO_MXFP8_E4M3, cls.QUANT_FP16_TO_MXFP8_E4M3):
            scale_e8m0 = (e_max - 7) if e_max > 7 else 0
        elif quant_mode == cls.QUANT_BF16_TO_NVFP4_E2M1:
            scale_e8m0 = (e_max - 2) if e_max > 2 else 0
        else:
            scale_e8m0 = 127
        max_frac3 = max([(f >> 4) & 0x7 for e, f, fnz in zip(exp8s, frac7s, is_fin_nz) if fnz and e == e_max], default=0)
        e4m3_exp4 = 1 if scale_e8m0 <= 120 else (14 if scale_e8m0 >= 134 else ((scale_e8m0 & 0xF) - 8))
        scale_nvfp4_e4m3 = ((e4m3_exp4 << 3) | max_frac3) if any(is_fin_nz) else 0
        out_lanes = []
        for i in range(16):
            rel = exp8s[i] - scale_e8m0
            if quant_mode in (cls.QUANT_BF16_TO_MXFP8_E4M3, cls.QUANT_FP16_TO_MXFP8_E4M3):
                if is_zero[i] or exp8s[i] <= scale_e8m0: code = (signs[i] << 7)
                elif is_nan_inf[i] or rel >= 14: code = (signs[i] << 7) | (14 << 3) | 7
                else: code = (signs[i] << 7) | ((rel & 0xF) << 3) | ((frac7s[i] >> 4) & 0x7)
            else:
                if is_zero[i] or exp8s[i] <= scale_e8m0: code = (signs[i] << 3)
                elif is_nan_inf[i] or rel >= 3: code = (signs[i] << 3) | (3 << 1) | 1
                else: code = (signs[i] << 3) | ((rel & 0x3) << 1) | ((frac7s[i] >> 6) & 1)
            out_lanes.append(code)
        return {
            "scale_e8m0": scale_e8m0,
            "scale_nvfp4_e4m3": scale_nvfp4_e4m3,
            "quant_lanes": out_lanes,
            "zero_lanes_cnt": sum(1 for z in is_zero if z),
            "nan_inf_clamped": any(is_nan_inf),
        }



class GroqSpecDecodeTreeSamplerModel:
    SAMPLER_GREEDY_ARGMAX = 0
    SAMPLER_TOPK_TOPP = 1
    SAMPLER_SPEC_VERIFY_TREE = 2

    @classmethod
    def evaluate(
        cls,
        op_mode: int,
        logits: List[int],
        tokens: List[int],
        top_k: int = 4,
        top_p_thresh: int = 256,
        tree_parent_idx: Optional[List[int]] = None,
        tree_draft_tok: Optional[List[int]] = None,
        tree_target_prob: Optional[List[int]] = None,
        tree_draft_prob: Optional[List[int]] = None,
        tree_rand_u: Optional[List[int]] = None,
        bonus_tok: int = 99,
    ) -> Dict[str, object]:
        pairs = sorted(zip(logits, tokens, range(len(logits))), key=lambda x: (-int(x[0]), x[2]))
        sorted_logits = [int(x[0]) for x in pairs]
        sorted_tokens = [int(x[1]) for x in pairs]
        weights = [max(0, l + 128) for l in sorted_logits]
        nucleus_mask = []
        run_cum = 0
        for r, w in enumerate(weights):
            topk_ok = True if top_k == 0 else (r < top_k)
            topp_ok = True if r == 0 else (run_cum < top_p_thresh)
            nucleus_mask.append(True if r == 0 else (topk_ok and topp_ok))
            run_cum += w

        p_idx = tree_parent_idx or [0, 0, 1, 2, 1, 4, 2, 6]
        d_tok = tree_draft_tok or list(range(10, 18))
        t_prob = tree_target_prob or [220, 200, 180, 160, 90, 80, 70, 60]
        q_prob = tree_draft_prob or [200, 190, 170, 150, 200, 200, 200, 200]
        u_rand = tree_rand_u or [128] * 8

        path_valid = [True] + [False] * 7
        depths = [1] * 8
        for d in range(1, 8):
            local_ok = (t_prob[d] >= q_prob[d]) or ((t_prob[d] * 256) >= (u_rand[d] * q_prob[d]))
            par = p_idx[d] & 0x7
            if par < d and depths[par] < 4:
                path_valid[d] = path_valid[par] and local_ok
                depths[d] = depths[par] + 1

        best_leaf, best_depth, best_prob = 0, 1, t_prob[0]
        for d in range(1, 8):
            if path_valid[d]:
                if depths[d] > best_depth or (depths[d] == best_depth and t_prob[d] > best_prob):
                    best_leaf, best_depth, best_prob = d, depths[d], t_prob[d]

        eagle2_conf = sum(t_prob[d] for d in range(8) if path_valid[d])
        anc0 = best_leaf
        anc1 = p_idx[anc0]
        anc2 = p_idx[anc1]
        anc3 = p_idx[anc2]
        chain = [d_tok[anc0], d_tok[anc1], d_tok[anc2], d_tok[anc3]][:best_depth][::-1] + [bonus_tok]
        sel_tok = sorted_tokens[0] if op_mode != cls.SAMPLER_SPEC_VERIFY_TREE else d_tok[best_leaf]
        return {
            "sorted_logits": sorted_logits,
            "sorted_tokens": sorted_tokens,
            "nucleus_mask": nucleus_mask,
            "accepted_node_mask": path_valid,
            "best_leaf_idx": best_leaf,
            "accepted_draft_len": best_depth,
            "total_emitted_tokens": best_depth + 1,
            "committed_tokens": chain,
            "eagle2_tree_confidence": eagle2_conf,
            "selected_token": sel_tok,
        }


class GroqPowerDroopControllerModel:
    STATE_IDLE = 0
    STATE_PRECHARGE_RAMP_UP = 1
    STATE_ACTIVE_COMPUTE = 2
    STATE_EMERGENCY_STRETCH = 3
    STATE_SAFE_RAMP_DOWN = 4

    def __init__(self, droop_thresh_mv: int = 45, precharge_cycles: int = 4, rampdown_cycles: int = 4) -> None:
        self.thresh_mv = droop_thresh_mv
        self.precharge_cycles = precharge_cycles
        self.rampdown_cycles = rampdown_cycles
        self.state = self.STATE_IDLE
        self.throttle_events = 0

    def step(self, upcoming_mxm_burst: bool, active_compute: bool, measured_droop_mv: int) -> Dict[str, object]:
        if measured_droop_mv >= self.thresh_mv:
            self.state = self.STATE_EMERGENCY_STRETCH
            self.throttle_events += 1
            return {"state": self.state, "icu_fetch_stall": True, "mxm_rate_scale": 0.5, "nop_delay_req": 1}
        if upcoming_mxm_burst and self.state == self.STATE_IDLE:
            self.state = self.STATE_PRECHARGE_RAMP_UP
            return {"state": self.state, "icu_fetch_stall": True, "mxm_rate_scale": 0.25, "nop_delay_req": self.precharge_cycles}
        if active_compute:
            self.state = self.STATE_ACTIVE_COMPUTE
            return {"state": self.state, "icu_fetch_stall": False, "mxm_rate_scale": 1.0, "nop_delay_req": 0}
        if self.state in (self.STATE_ACTIVE_COMPUTE, self.STATE_EMERGENCY_STRETCH):
            self.state = self.STATE_SAFE_RAMP_DOWN
            return {"state": self.state, "icu_fetch_stall": False, "mxm_rate_scale": 0.5, "nop_delay_req": self.rampdown_cycles}
        self.state = self.STATE_IDLE
        return {"state": self.state, "icu_fetch_stall": False, "mxm_rate_scale": 0.0, "nop_delay_req": 0}


class GroqSRAMECCScrubberModel:
    def __init__(self, num_rows: int = 64) -> None:
        self.num_rows = num_rows
        self.scrub_ptr = 0
        self.sbe_corrected_count = 0
        self.dbe_sticky_alarm = False
        self.sram_codewords = [SecdedHamming7264.encode64(0) for _ in range(num_rows)]

    def write_functional(self, row: int, val64: int) -> None:
        self.sram_codewords[row % self.num_rows] = SecdedHamming7264.encode64(val64)

    def inject_bit_flips(self, row: int, bit_positions: List[int]) -> None:
        cw = self.sram_codewords[row % self.num_rows]
        for b in bit_positions:
            cw ^= (1 << (b % 72))
        self.sram_codewords[row % self.num_rows] = cw

    def step_patrol(self, func_port_busy: bool = False) -> Dict[str, object]:
        if func_port_busy:
            return {"scrubbed": False, "row": self.scrub_ptr, "sbe": False, "dbe": False}
        row = self.scrub_ptr
        self.scrub_ptr = (self.scrub_ptr + 1) % self.num_rows
        dec, _, sbe, dbe = SecdedHamming7264.decode72(self.sram_codewords[row])
        if sbe:
            self.sbe_corrected_count += 1
            self.sram_codewords[row] = SecdedHamming7264.encode64(dec)
        if dbe:
            self.dbe_sticky_alarm = True
        return {"scrubbed": True, "row": row, "sbe": sbe, "dbe": dbe, "data64": dec}


if __name__ == "__main__":
    print("Groq LPU / NVIDIA Groq 3 LPX Golden Reference Model & Deterministic Compiler loaded successfully.")
