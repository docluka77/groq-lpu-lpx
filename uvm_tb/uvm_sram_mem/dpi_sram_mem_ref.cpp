// =============================================================================
// File: dpi_sram_mem_ref.cpp
// Description: Cycle-Accurate C++17 DPI-C Golden Reference Model for
//              Groq LPU Superlane Memory Slice IP (groq_mem_slice)
// =============================================================================
#include <cstdint>
#include <cstring>

namespace {

constexpr uint32_t NUM_BANKS   = 4;
constexpr uint32_t SUBWORDS    = 2;
constexpr uint32_t BANK_DEPTH  = 1024;
constexpr uint32_t ADDR_MASK   = 0x3FFU;

// Exact POS_MAP table matching groq_sram_ecc_secded.sv (i = 0..63)
constexpr uint8_t POS_MAP[64] = {
     3,  5,  6,  7,  9, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 33, 34, 35, 36, 37, 38,
    39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54,
    55, 56, 57, 58, 59, 60, 61, 62, 63, 65, 66, 67, 68, 69, 70, 71
};

struct Codeword72 {
    uint64_t data;
    uint8_t  ecc;
};

struct AguState {
    uint32_t mode_q;
    uint32_t base_q;
    uint32_t stride0_q;
    uint32_t stride1_q;
    uint32_t count0_q;
    uint32_t count1_q;
    uint32_t idx0_q;
    uint32_t idx1_q;
    uint32_t accum0_q;
    uint32_t accum1_q;
    bool     busy_q;

    void reset() {
        mode_q = 0; base_q = 0; stride0_q = 0; stride1_q = 0;
        count0_q = 1; count1_q = 1;
        idx0_q = 0; idx1_q = 0; accum0_q = 0; accum1_q = 0;
        busy_q = false;
    }

    void eval_comb(bool step_en, uint32_t gather_off, uint32_t& addr_out, bool& tile_done) const {
        uint32_t safe_c0 = (count0_q == 0) ? 1U : count0_q;
        uint32_t safe_c1 = (count1_q == 0) ? 1U : count1_q;
        bool last_0 = (idx0_q == (safe_c0 - 1U));
        bool last_1 = (mode_q == 1U) ? (idx1_q == (safe_c1 - 1U)) : true;
        uint32_t ring_mask = (stride1_q == 0) ? ADDR_MASK : stride1_q;
        tile_done = busy_q && step_en && last_0 && last_1;
        switch (mode_q & 3U) {
            case 0U: addr_out = (base_q + accum0_q) & ADDR_MASK; break;
            case 1U: addr_out = (base_q + accum0_q + accum1_q) & ADDR_MASK; break;
            case 2U: addr_out = (base_q + (accum0_q & ring_mask)) & ADDR_MASK; break;
            case 3U: addr_out = (base_q + (gather_off & ADDR_MASK)) & ADDR_MASK; break;
            default: addr_out = base_q & ADDR_MASK; break;
        }
    }

    void step_seq(bool cfg_load, uint32_t cfg_mode, uint32_t base_addr,
                  uint32_t stride_0, uint32_t stride_1, uint32_t count_0,
                  uint32_t count_1, bool step_en) {
        if (cfg_load) {
            mode_q    = cfg_mode & 3U;
            base_q    = base_addr & ADDR_MASK;
            stride0_q = stride_0 & ADDR_MASK;
            stride1_q = stride_1 & ADDR_MASK;
            uint32_t c0 = count_0 & ADDR_MASK;
            uint32_t c1 = count_1 & ADDR_MASK;
            count0_q  = (c0 == 0) ? 1U : c0;
            count1_q  = (c1 == 0) ? 1U : c1;
            idx0_q    = 0; idx1_q = 0; accum0_q = 0; accum1_q = 0;
            busy_q    = true;
        } else if (busy_q && step_en) {
            uint32_t safe_c0 = (count0_q == 0) ? 1U : count0_q;
            uint32_t safe_c1 = (count1_q == 0) ? 1U : count1_q;
            bool last_0 = (idx0_q == (safe_c0 - 1U));
            bool last_1 = (mode_q == 1U) ? (idx1_q == (safe_c1 - 1U)) : true;
            if (last_0) {
                idx0_q = 0; accum0_q = 0;
                if (mode_q == 1U) {
                    if (last_1) {
                        idx1_q = 0; accum1_q = 0; busy_q = false;
                    } else {
                        idx1_q   = (idx1_q + 1U) & ADDR_MASK;
                        accum1_q = (accum1_q + stride1_q) & ADDR_MASK;
                    }
                } else if (mode_q == 2U) {
                    busy_q = true;
                } else {
                    busy_q = false;
                }
            } else {
                idx0_q   = (idx0_q + 1U) & ADDR_MASK;
                accum0_q = (accum0_q + stride0_q) & ADDR_MASK;
            }
        }
    }
};

static inline uint32_t popparity64(uint64_t v) {
    return static_cast<uint32_t>(__builtin_parityll(v));
}

static inline uint32_t popparity8(uint8_t v) {
    return static_cast<uint32_t>(__builtin_parity(static_cast<unsigned int>(v)));
}

static Codeword72 secded_encode(uint64_t data_in) {
    uint8_t ecc = 0;
    for (int k = 0; k < 7; ++k) {
        uint32_t p = 0;
        for (int i = 0; i < 64; ++i) {
            if ((POS_MAP[i] >> k) & 1U) {
                p ^= static_cast<uint32_t>((data_in >> i) & 1ULL);
            }
        }
        ecc |= static_cast<uint8_t>(p << k);
    }
    uint32_t p7 = popparity64(data_in) ^ popparity8(ecc);
    ecc |= static_cast<uint8_t>(p7 << 7);
    return Codeword72{data_in, ecc};
}

static void secded_decode(Codeword72 cw, uint64_t& data_corr, uint8_t& syndrome,
                          bool& single_err, bool& double_err) {
    uint8_t syn_low = 0;
    for (int k = 0; k < 7; ++k) {
        uint32_t s = (cw.ecc >> k) & 1U;
        for (int i = 0; i < 64; ++i) {
            if ((POS_MAP[i] >> k) & 1U) {
                s ^= static_cast<uint32_t>((cw.data >> i) & 1ULL);
            }
        }
        syn_low |= static_cast<uint8_t>(s << k);
    }
    uint32_t overall_par = popparity64(cw.data) ^ popparity8(cw.ecc);
    syndrome   = static_cast<uint8_t>((overall_par << 7) | syn_low);
    single_err = (overall_par != 0U);
    double_err = (overall_par == 0U) && (syn_low != 0U);
    data_corr  = cw.data;
    if (single_err) {
        for (int i = 0; i < 64; ++i) {
            if (syn_low == POS_MAP[i]) {
                data_corr ^= (1ULL << i);
            }
        }
    }
}

static void write_masked_cw(Codeword72& dst, const Codeword72& src, uint8_t data_bwe_n) {
    for (int b = 0; b < 8; ++b) {
        if (!((data_bwe_n >> b) & 1U)) {
            uint64_t mask = 0xFFULL << (b * 8);
            dst.data = (dst.data & ~mask) | (src.data & mask);
        }
    }
    if (data_bwe_n != 0xFFU) {
        dst.ecc = src.ecc;
    }
}

static Codeword72 g_mem[NUM_BANKS][SUBWORDS][BANK_DEPTH];
static Codeword72 g_spare[NUM_BANKS][SUBWORDS];
static Codeword72 g_bank_rdata[NUM_BANKS][SUBWORDS];
static AguState   g_rd_agu;
static AguState   g_wr_agu;
static bool       g_rd_pipe_valid_q = false;
static uint32_t   g_rd_pipe_bank_q  = 0;

static uint64_t   g_exp_rdata_lo    = 0;
static uint64_t   g_exp_rdata_hi    = 0;
static uint32_t   g_exp_flags       = 0;
static uint32_t   g_exp_addrs       = 0;
static uint32_t   g_calls           = 0;
static int        g_status          = 2;

} // namespace

extern "C" void dpi_sram_reset() {
    std::memset(g_mem, 0, sizeof(g_mem));
    std::memset(g_spare, 0, sizeof(g_spare));
    std::memset(g_bank_rdata, 0, sizeof(g_bank_rdata));
    g_rd_agu.reset();
    g_wr_agu.reset();
    g_rd_pipe_valid_q = false;
    g_rd_pipe_bank_q  = 0;
    g_exp_rdata_lo    = 0;
    g_exp_rdata_hi    = 0;
    g_exp_flags       = 0;
    g_exp_addrs       = 0;
    g_calls           = 0;
}

extern "C" void dpi_sram_set_status(int status) { g_status = status; }
extern "C" int  dpi_sram_get_status() { return g_status; }
extern "C" unsigned int dpi_sram_get_calls() { return g_calls; }
extern "C" unsigned long long dpi_sram_exp_rdata_lo() { return g_exp_rdata_lo; }
extern "C" unsigned long long dpi_sram_exp_rdata_hi() { return g_exp_rdata_hi; }
extern "C" unsigned int dpi_sram_exp_flags() { return g_exp_flags; }
extern "C" unsigned int dpi_sram_exp_addrs() { return g_exp_addrs; }

extern "C" void dpi_sram_step(
    unsigned int rd_agu_cfg_load, unsigned int rd_agu_mode, unsigned int rd_agu_base,
    unsigned int rd_agu_stride0,  unsigned int rd_agu_stride1,
    unsigned int rd_agu_count0,   unsigned int rd_agu_count1,  unsigned int rd_agu_use,
    unsigned int wr_agu_cfg_load, unsigned int wr_agu_mode, unsigned int wr_agu_base,
    unsigned int wr_agu_stride0,  unsigned int wr_agu_stride1,
    unsigned int wr_agu_count0,   unsigned int wr_agu_count1,  unsigned int wr_agu_use,
    unsigned int stream_in_valid, unsigned int stream_in_bank, unsigned int stream_in_addr,
    unsigned long long stream_in_data_lo, unsigned long long stream_in_data_hi,
    unsigned int stream_in_bwe_n,
    unsigned int rd_req_valid,    unsigned int rd_req_bank,    unsigned int rd_req_addr,
    unsigned int bank_slp_n,      unsigned int bank_ds_n,      unsigned int bank_sd_n,
    unsigned int bank_repair_en,  unsigned int bank_repair_addr, unsigned int mbist_en,
    unsigned int err_inject_en,
    unsigned long long err_mask_s0_data, unsigned int err_mask_s0_ecc,
    unsigned long long err_mask_s1_data, unsigned int err_mask_s1_ecc
) {
    ++g_calls;
    bool rd_step_en = (rd_req_valid != 0U) && (rd_agu_use != 0U);
    bool wr_step_en = (stream_in_valid != 0U) && (wr_agu_use != 0U);

    uint32_t rd_agu_addr = 0, wr_agu_addr = 0;
    bool rd_tile_done = false, wr_tile_done = false;
    g_rd_agu.eval_comb(rd_step_en, rd_req_addr, rd_agu_addr, rd_tile_done);
    g_wr_agu.eval_comb(wr_step_en, stream_in_addr, wr_agu_addr, wr_tile_done);

    uint32_t eff_rd_addr = (rd_agu_use != 0U) ? rd_agu_addr : (rd_req_addr & ADDR_MASK);
    uint32_t eff_wr_addr = (wr_agu_use != 0U) ? wr_agu_addr : (stream_in_addr & ADDR_MASK);
    g_exp_addrs = ((eff_wr_addr & ADDR_MASK) << 16) | (eff_rd_addr & ADDR_MASK);

    uint32_t r_bank = rd_req_bank & 3U;
    uint32_t w_bank = stream_in_bank & 3U;
    bool bank_conflict = (rd_req_valid != 0U) && (stream_in_valid != 0U) && (r_bank == w_bank);

    g_rd_agu.step_seq(rd_agu_cfg_load != 0U, rd_agu_mode, rd_agu_base,
                      rd_agu_stride0, rd_agu_stride1, rd_agu_count0, rd_agu_count1, rd_step_en);
    g_wr_agu.step_seq(wr_agu_cfg_load != 0U, wr_agu_mode, wr_agu_base,
                      wr_agu_stride0, wr_agu_stride1, wr_agu_count0, wr_agu_count1, wr_step_en);

    bool r_bank_awake = (((bank_slp_n >> r_bank) & 1U) != 0U) &&
                        (((bank_ds_n  >> r_bank) & 1U) != 0U) &&
                        (((bank_sd_n  >> r_bank) & 1U) != 0U);
    g_rd_pipe_valid_q = (rd_req_valid != 0U) && !bank_conflict && (mbist_en == 0U) && r_bank_awake;
    g_rd_pipe_bank_q  = r_bank;

    Codeword72 wr_cw[2] = { secded_encode(stream_in_data_lo), secded_encode(stream_in_data_hi) };

    for (uint32_t b = 0; b < NUM_BANKS; ++b) {
        bool sd_n  = ((bank_sd_n  >> b) & 1U) != 0U;
        bool ds_n  = ((bank_ds_n  >> b) & 1U) != 0U;
        bool slp_n = ((bank_slp_n >> b) & 1U) != 0U;
        bool ready = sd_n && ds_n && slp_n;
        bool rep_en = ((bank_repair_en >> b) & 1U) != 0U;
        uint32_t rep_addr = bank_repair_addr & ADDR_MASK;

        if (!sd_n) {
            for (uint32_t w = 0; w < SUBWORDS; ++w) {
                g_bank_rdata[b][w] = Codeword72{0, 0};
                g_spare[b][w]      = Codeword72{0, 0};
            }
        } else if (!ready) {
            for (uint32_t w = 0; w < SUBWORDS; ++w) {
                g_bank_rdata[b][w] = Codeword72{0, 0};
            }
        } else if (mbist_en != 0U) {
            for (uint32_t w = 0; w < SUBWORDS; ++w) {
                for (uint32_t a = 0; a < BANK_DEPTH; ++a) {
                    if (rep_en && (a == rep_addr)) g_spare[b][w] = Codeword72{0, 0};
                    else g_mem[b][w][a] = Codeword72{0, 0};
                }
                g_bank_rdata[b][w] = Codeword72{0, 0};
            }
        } else {
            bool is_wr = (stream_in_valid != 0U) && (w_bank == b);
            bool is_rd = (rd_req_valid != 0U) && (r_bank == b) && !is_wr;
            if (is_wr || is_rd) {
                uint32_t b_addr = is_wr ? eff_wr_addr : eff_rd_addr;
                bool hit_spare  = rep_en && (b_addr == rep_addr);
                for (uint32_t w = 0; w < SUBWORDS; ++w) {
                    if (is_wr) {
                        uint8_t bwe_sub = static_cast<uint8_t>((stream_in_bwe_n >> (w * 8)) & 0xFFU);
                        Codeword72& dst = hit_spare ? g_spare[b][w] : g_mem[b][w][b_addr];
                        write_masked_cw(dst, wr_cw[w], bwe_sub);
                    } else {
                        g_bank_rdata[b][w] = hit_spare ? g_spare[b][w] : g_mem[b][w][b_addr];
                    }
                }
            }
        }
    }

    uint64_t err_mask_data[2] = { err_mask_s0_data, err_mask_s1_data };
    uint8_t  err_mask_ecc[2]  = { static_cast<uint8_t>(err_mask_s0_ecc & 0xFFU),
                                  static_cast<uint8_t>(err_mask_s1_ecc & 0xFFU) };
    uint64_t data_corr[2]     = { 0, 0 };
    uint8_t  syn[2]           = { 0, 0 };
    bool     sec[2]           = { false, false };
    bool     ded[2]           = { false, false };

    for (uint32_t s = 0; s < SUBWORDS; ++s) {
        Codeword72 cw = g_bank_rdata[g_rd_pipe_bank_q][s];
        if (err_inject_en != 0U) {
            cw.data ^= err_mask_data[s];
            cw.ecc  ^= err_mask_ecc[s];
        }
        secded_decode(cw, data_corr[s], syn[s], sec[s], ded[s]);
    }

    g_exp_rdata_lo = data_corr[0];
    g_exp_rdata_hi = data_corr[1];
    bool exp_sec = g_rd_pipe_valid_q && (sec[0] || sec[1]);
    bool exp_ded = g_rd_pipe_valid_q && (ded[0] || ded[1]);
    bool exp_mbist_done = (mbist_en != 0U);
    bool exp_mbist_fail = false;
    uint32_t syn16 = (static_cast<uint32_t>(syn[1]) << 8) | static_cast<uint32_t>(syn[0]);

    g_exp_flags = (g_rd_pipe_valid_q ? (1U << 0) : 0U)
                | (bank_conflict     ? (1U << 1) : 0U)
                | (exp_sec           ? (1U << 2) : 0U)
                | (exp_ded           ? (1U << 3) : 0U)
                | (rd_tile_done      ? (1U << 4) : 0U)
                | (wr_tile_done      ? (1U << 5) : 0U)
                | (exp_mbist_done    ? (1U << 6) : 0U)
                | (exp_mbist_fail    ? (1U << 7) : 0U)
                | (syn16 << 8);
}
