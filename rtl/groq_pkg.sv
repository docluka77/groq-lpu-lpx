// =============================================================================
// File: rtl/groq_pkg.sv
// Project: Groq LPU / NVIDIA Groq 3 LPX Tensor Streaming Processor (TSP)
// Description: Global Architecture Package defining spatial slice topology,
//              superlane stream parameters, opcodes, and 144-bit VLIW bundle.
// =============================================================================
`ifndef GROQ_PKG_SV
`define GROQ_PKG_SV

/* verilator lint_off UNUSEDPARAM */
package groq_pkg;

  // ---------------------------------------------------------------------------
  // 1. Spatial Superlane & Stream Fabric Parameters (ISCA 2020 / 2022 TSP)
  // ---------------------------------------------------------------------------
  parameter int SUPERLANE_LANES   = 16;   // 16 elements per superlane
  parameter int ELEM_BITS         = 8;    // 8-bit base element (INT8 / FP8)
  parameter int STREAM_WIDTH      = SUPERLANE_LANES * ELEM_BITS; // 128 bits/superlane
  parameter int FULL_CHIP_SUPERLANES = 20; // 20 superlanes = 320 Bytes/stream
  parameter int NUM_EAST_STREAMS  = 16;   // 16 Eastward stream channels
  parameter int NUM_WEST_STREAMS  = 16;   // 16 Westward stream channels
  parameter int TOTAL_STREAMS     = NUM_EAST_STREAMS + NUM_WEST_STREAMS; // 32 streams
  parameter int NUM_SLICES        = 8;    // 8 spatial functional slices
  parameter int VLIW_INSTR_BITS   = 144;  // 144-bit deterministic VLIW bundle

  // ---------------------------------------------------------------------------
  // 2. Spatial Hemisphere Slice Topology Indices (West=0 -> East=7)
  // ---------------------------------------------------------------------------
  parameter int SLICE_NIM   = 0; // Network Interface & RealSync C2C Router
  parameter int SLICE_MEM_W = 1; // West Hemisphere 44-Bank On-Chip SRAM Slice
  parameter int SLICE_SXM   = 2; // Switch / Transpose / Permute Execution Module
  parameter int SLICE_VXM   = 3; // Vector Execution Module (16-Lane SIMD + Nonlinear)
  parameter int SLICE_MXM_W = 4; // West Matrix Execution Module (INT8/FP8/FP16 Systolic)
  parameter int SLICE_ICU   = 5; // Instruction Control Unit (Central VLIW Dispatch)
  parameter int SLICE_MXM_E = 6; // East Matrix Execution Module (INT8/FP8/FP16 Systolic)
  parameter int SLICE_MEM_E = 7; // East Hemisphere 44-Bank On-Chip SRAM Slice

  // ---------------------------------------------------------------------------
  // 3. Precision & Data Format Encoding
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    PREC_INT8     = 4'd0,
    PREC_FP8_E4M3 = 4'd1,
    PREC_FP8_E5M2 = 4'd2,
    PREC_FP16     = 4'd3,
    PREC_BF16     = 4'd4,
    PREC_INT4     = 4'd5,
    PREC_FP32     = 4'd6
  } prec_mode_e;
  localparam logic [3:0] PREC_INT8_RNE = 4'd3; // IEEE 754-2019 Round-to-Nearest-Even (US11263129B1)

  // ---------------------------------------------------------------------------
  // 4. Functional Slice Sub-Opcodes
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ICU_NOP          = 4'd0,
    ICU_NOP_DELAY    = 4'd1, // Deterministic multi-cycle fetch stall (power save)
    ICU_SYNC_BARRIER = 4'd2, // Wait for all slices in sync_mask to assert NOTIFY
    ICU_NOTIFY       = 4'd3, // Assert slice readiness to hardware barrier
    ICU_JUMP_IMM     = 4'd4, // Deterministic loop branch
    ICU_REALSYNC_ADJ = 4'd5, // Update plesiochronous RealSync deskew offset
    ICU_HALT         = 4'd6  // End of scheduled inference program
  } icu_op_e;

  typedef enum logic [3:0] {
    MEM_NOP          = 4'd0,
    MEM_READ_EAST    = 4'd1, // Read SRAM bank -> inject into Eastward stream
    MEM_READ_WEST    = 4'd2, // Read SRAM bank -> inject into Westward stream
    MEM_WRITE_EAST   = 4'd3, // Capture Eastward stream -> write SRAM bank
    MEM_WRITE_WEST   = 4'd4, // Capture Westward stream -> write SRAM bank
    MEM_STRIDE_CFG   = 4'd5, // Configure Tensor AGU stride/modulus
    MEM_BANK_SLEEP   = 4'd6  // Fine-grained SRAM bank sleep gating
  } mem_op_e;

  typedef enum logic [3:0] {
    SXM_NOP            = 4'd0,
    SXM_PASSTHROUGH    = 4'd1,
    SXM_BARREL_ROTATE  = 4'd2, // Circular shift by sxm_shift_amt lanes
    SXM_TRANSPOSE_4X4  = 4'd3, // 4x4 sub-tile matrix transpose
    SXM_BIT_REVERSE    = 4'd4, // Bit-reversal lane permutation
    SXM_BROADCAST_LANE = 4'd5, // Broadcast selected lane across superlane
    SXM_INTERLEAVE     = 4'd6, // Even/odd superlane interleave
    SXM_ROTATE_LEFT    = 4'd7, // Barrel rotate left across 16 lanes
    SXM_ROTATE_RIGHT   = 4'd8, // Barrel rotate right across 16 lanes
    SXM_REVERSE        = 4'd9, // Full 16-lane reversal (lane[15-i])
    SXM_TRANSPOSE_LOAD = 4'd10,// Load row into 16x16 transpose buffer
    SXM_TRANSPOSE_READ = 4'd11,// Read col from 16x16 transpose buffer
    SXM_BUTTERFLY_SWAP = 4'd12 // Butterfly XOR permutation (i ^ mask)
  } sxm_op_e;
  localparam sxm_op_e SXM_PASS      = SXM_PASSTHROUGH;
  localparam sxm_op_e SXM_BROADCAST = SXM_BROADCAST_LANE;

  typedef enum logic [3:0] {
    VXM_NOP            = 4'd0,
    VXM_VADD           = 4'd1,
    VXM_VMUL           = 4'd2,
    VXM_VFMA           = 4'd3,
    VXM_SILU_LUT       = 4'd4, // SwiGLU / SiLU piecewise linear + LUT
    VXM_GELU_LUT       = 4'd5, // GELU activation
    VXM_RMSNORM_RED    = 4'd6, // Tree reduction sum-of-squares + rsqrt
    VXM_SOFTMAX_EXP    = 4'd7, // Max-subtract + exp + tree sum
    VXM_SWIGLU         = 4'd8, // Fused SwiGLU (SiLU(a) * b) / RoPE
    VXM_QUANT_CLIP     = 4'd9, // FP32/FP16 -> INT8/FP8 deterministic quant
    VXM_SUB            = 4'd10,
    VXM_MAX_ELEM       = 4'd11,
    VXM_MIN_ELEM       = 4'd12,
    VXM_RELU           = 4'd13,
    VXM_REDUCE_SUM     = 4'd14,
    VXM_REDUCE_MAX     = 4'd15
  } vxm_op_e;
  localparam vxm_op_e VXM_ADD         = VXM_VADD;
  localparam vxm_op_e VXM_MUL         = VXM_VMUL;
  localparam vxm_op_e VXM_FMA         = VXM_VFMA;
  localparam vxm_op_e VXM_SILU        = VXM_SILU_LUT;
  localparam vxm_op_e VXM_GELU        = VXM_GELU_LUT;
  localparam vxm_op_e VXM_RSQRT_LUT   = VXM_RMSNORM_RED;
  localparam vxm_op_e VXM_EXP_LUT     = VXM_SOFTMAX_EXP;
  localparam vxm_op_e VXM_ROPE_ROTATE = VXM_SWIGLU;
  localparam vxm_op_e VXM_QUANT_SCALE = VXM_QUANT_CLIP;

  typedef enum logic [3:0] {
    MXM_NOP            = 4'd0,
    MXM_LOAD_WEIGHT_B0 = 4'd1, // Stage weights into ping buffer 0
    MXM_LOAD_WEIGHT_B1 = 4'd2, // Stage weights into pong buffer 1
    MXM_SWAP_WEIGHT    = 4'd3, // Zero-cycle ping-pong active weight swap
    MXM_SYSTOLIC_EXEC  = 4'd4, // Execute 16x16 wavefront MAC on active buffer
    MXM_ACCUM_FLUSH    = 4'd5, // Drain FP32 accumulators to output stream
    MXM_ACCUM_CLEAR    = 4'd6, // Clear accumulators to zero
    MXM_ACCUM_PRELOAD  = 4'd7  // Preload accumulators from stream
  } mxm_op_e;
  localparam mxm_op_e MXM_SWAP_WEIGHTS = MXM_SWAP_WEIGHT;

  typedef enum logic [3:0] {
    NIM_NOP            = 4'd0,
    NIM_TX_CHIP2CHIP   = 4'd1, // Transmit stream flit over Dragonfly C2C link
    NIM_RX_CHIP2CHIP   = 4'd2, // Inject received C2C flit onto local stream
    NIM_REALSYNC_PING  = 4'd3, // Exchange RealSync plesiochronous deskew marker
    NIM_ROUTE_BYPASS   = 4'd4, // Non-minimal / minimal Dragonfly hop bypass
    NIM_ALLREDUCE_ADD  = 4'd5, // In-network C2C + local vector All-Reduce sum
    NIM_DESKEW_CAL     = 4'd6, // Plesiochronous RealSync deskew offset calibration
    NIM_LOOPBACK       = 4'd7  // Near-end C2C + local stream diagnostic loopback
  } nim_op_e;
  localparam nim_op_e NIM_SEND        = NIM_TX_CHIP2CHIP;
  localparam nim_op_e NIM_RECV        = NIM_RX_CHIP2CHIP;
  localparam nim_op_e NIM_FORWARD     = NIM_ROUTE_BYPASS;
  localparam nim_op_e NIM_SYNC_BEACON = NIM_REALSYNC_PING;

  // ---------------------------------------------------------------------------
  // 5. Complete 144-Bit Deterministic VLIW Instruction Bundle Struct
  //    Total width = 4*8(32) + 16(48) + 24(72) + 32(104) + 40(144) = 144 bits
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [3:0]  target_slice;   // [143:140] Target spatial slice ID (0..7)
    icu_op_e     icu_op;         // [139:136] ICU control opcode
    mem_op_e     mem_op;         // [135:132] Memory slice opcode
    sxm_op_e     sxm_op;         // [131:128] Switch/Permute slice opcode
    vxm_op_e     vxm_op;         // [127:124] Vector ALU slice opcode
    mxm_op_e     mxm_op;         // [123:120] Matrix Systolic slice opcode
    nim_op_e     nim_op;         // [119:116] Network/RealSync slice opcode
    prec_mode_e  prec_mode;      // [115:112] Precision mode (INT8/FP8/FP16/FP32)
    logic [4:0]  src_stream_a;   // [111:107] Source stream A ID (0..15 E, 16..31 W)
    logic [4:0]  src_stream_b;   // [106:102] Source stream B ID
    logic [4:0]  dst_stream;     // [101:97]  Destination stream ID
    logic        dst_dir_west;   // [96]      0 = Inject Eastward, 1 = Inject Westward
    logic [7:0]  sync_mask;      // [95:88]   8-slice hardware barrier participation mask
    logic [15:0] nop_delay_cnt;  // [87:72]   Deterministic NOP_DELAY countdown cycles
    logic [15:0] mem_base_addr;  // [71:56]   SRAM bank row address
    logic [7:0]  mem_stride;     // [55:48]   AGU address stride
    logic [7:0]  vec_length;     // [47:40]   Tensor burst length
    logic [7:0]  sxm_shift_amt;  // [39:32]   Permute / barrel shift control
    logic [15:0] imm16;          // [31:16]   Immediate / RealSync deskew offset
    logic [15:0] trace_tag;      // [15:0]    Compiler deterministic cycle tag
  } groq_vliw_instr_t;

endpackage : groq_pkg
/* verilator lint_on UNUSEDPARAM */

`endif // GROQ_PKG_SV
