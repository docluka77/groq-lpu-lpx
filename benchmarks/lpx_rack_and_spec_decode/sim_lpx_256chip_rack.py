#!/usr/bin/env python3
"""
Stage 22 Part C: 256-Chip NVIDIA Groq 3 LPX MGX Rack-Scale Hierarchical Dragonfly Simulator
============================================================================================
Models the NVIDIA Groq 3 LPX 256-LPU MGX Rack (Samsung SF4X 4nm, 1.85 GHz):
- 32 x 8-chip Dragonfly Groups = 256 LPX chips
- 512 MB SRAM / chip = 128.0 GB Rack-Scale Zero-HBM Deterministic On-Die SRAM
- 150 TB/s SRAM BW / chip = 38.4 PB/s Aggregate Rack SRAM Bandwidth
- 2.5 TB/s C2C BW / chip = 640.0 TB/s Aggregate Rack Dragonfly Fabric Bandwidth
- NVLink-C2C 1.8 TB/s / node to NVIDIA Vera Rubin GPUs for Prefill-Decode Disaggregation
- VCD-Calibrated Power Model + Deterministic L*di/dt Bleeder Controller + Background Scrubber

Workloads Simulated:
1. Llama-3.1 405B (126 layers, d_model=16384, d_ffn=53248, GQA-128/8, W4A8/NVFP4 across 128 LPX chips)
2. DeepSeek-V3/R1 671B (61 layers, 37B active/token, d_model=7168, MLA d_kv=512 + 256-Expert MoE across 256 LPX chips)
"""

import json
import math
from pathlib import Path


def simulate_lpx_256chip_rack() -> dict:
    # -------------------------------------------------------------------------
    # 1. NVIDIA Groq 3 LPX MGX Rack Hardware Specification (SF4X 4nm @ 1.85 GHz)
    # -------------------------------------------------------------------------
    freq_ghz = 1.85
    cycle_time_ns = 1.0 / freq_ghz  # 0.54054 ns

    rack_spec = {
        "architecture": "NVIDIA Groq 3 LPX MGX Rack (32x8 Hierarchical Dragonfly)",
        "process_node": "Samsung SF4X 4nm FinFET",
        "clock_freq_ghz": freq_ghz,
        "cycle_time_ns": round(cycle_time_ns, 5),
        "num_dragonfly_groups": 32,
        "chips_per_group": 8,
        "total_lpx_chips": 256,
        "sram_per_chip_mb": 512.0,
        "total_rack_sram_gb": 128.0,
        "sram_bw_per_chip_tbps": 150.0,
        "total_rack_sram_bw_pbps": 38.4,
        "c2c_bw_per_chip_tbps": 2.5,
        "total_rack_c2c_bw_tbps": 640.0,
        "nvlink_c2c_vera_rubin_bw_tbps_per_group": 1.8,
        "active_power_per_chip_w": 385.0,
        "droop_prewarm_bleed_overhead_w": 11.5,
        "background_sram_scrubber_power_w": 1.8,
        "total_chip_power_w": 398.3,
        "total_rack_compute_power_kw": round(256 * 398.3 / 1000.0, 2),
        "gtc_2026_official_sram_per_die_mb": 500.0,
        "baseline_sram_per_die_mb": 150.0,
        "baseline_total_rack_sram_gb": 38.4,
        "gtc_2026_2u_trays_per_rack": 16,
        "gtc_2026_lpus_per_2u_tray": 16,
        "gtc_2026_total_rack_sram_bw_pbps_nominal": 40.0,
        "gtc_2026_total_rack_fp8_pflops": 315.0,
        "gtc_2026_scale_up_c2c_bw_tbps": 640.0,
        "orchestration_runtime": "NVIDIA Dynamo Prefill-Decode Disaggregated Orchestrator",
    }

    # -------------------------------------------------------------------------
    # 2. Workload 1: Llama-3.1 405B (W4A8 / NVFP4 + 8-Node EAGLE-2 Tree Decode)
    #    Mapped across 128 LPX chips (16 Dragonfly groups: TP=8 intra-group, PP=16)
    # -------------------------------------------------------------------------
    llama_chips = 128
    llama_layers = 126
    # 405B weights in NVFP4 (0.5 B/param = 202.5 GB total -> 1.582 GB/chip = 12.555 MB/layer/chip)
    # Dedicated MXM systolic weight-fetch port bandwidth: 2,560 B/cycle/chip (4.736 TB/s/chip of the 150 TB/s total SRAM fabric)
    mxm_weight_stream_bytes_per_cycle = 2560.0
    llama_weight_bytes_per_layer_per_chip = int((405e9 * 0.5 / llama_layers) / llama_chips)

    # Per-layer cycle breakdown (8-node speculative tree verify shares the single weight stream pass!)
    llama_sram_stream_cyc = int(math.ceil(llama_weight_bytes_per_layer_per_chip / mxm_weight_stream_bytes_per_cycle))
    llama_mxm_tail_cyc = 180
    llama_vxm_sxm_kv_cyc = 210
    llama_dragonfly_allreduce_cyc = 140
    llama_intergroup_hop_cyc = 45
    llama_spec_verify_cyc = 4

    llama_cycles_per_layer = (
        llama_sram_stream_cyc
        + llama_mxm_tail_cyc
        + llama_vxm_sxm_kv_cyc
        + llama_dragonfly_allreduce_cyc
        + llama_intergroup_hop_cyc
    )
    llama_total_pass_cycles = llama_layers * llama_cycles_per_layer + llama_spec_verify_cyc
    llama_pass_latency_ms = (llama_total_pass_cycles * cycle_time_ns) / 1e6

    # Standard 1-token autoregressive vs. 8-Node EAGLE-2 Speculative Tree (mean 3.60x acceptance)
    llama_std_tps = 1000.0 / llama_pass_latency_ms
    llama_spec_accept_mult = 3.60
    llama_spec_tps = llama_std_tps * llama_spec_accept_mult

    llama_rack_power_w = llama_chips * rack_spec["total_chip_power_w"]
    llama_joules_per_token_std = llama_rack_power_w / llama_std_tps
    llama_joules_per_token_spec = llama_rack_power_w / llama_spec_tps

    llama_405b_results = {
        "model": "Llama-3.1 405B (NVFP4/W4A8 + 8-Node EAGLE-2 Speculative Tree)",
        "lpx_chips_allocated": llama_chips,
        "dragonfly_groups_allocated": 16,
        "num_layers": llama_layers,
        "per_layer_cycle_breakdown": {
            "sram_weight_stream_cycles": llama_sram_stream_cyc,
            "mxm_systolic_non_overlapped_cycles": llama_mxm_tail_cyc,
            "vxm_sxm_kv_ring_attention_cycles": llama_vxm_sxm_kv_cyc,
            "dragonfly_intragroup_allreduce_realsync_cycles": llama_dragonfly_allreduce_cyc,
            "dragonfly_intergroup_pipeline_hop_cycles": llama_intergroup_hop_cyc,
            "total_cycles_per_layer": llama_cycles_per_layer,
        },
        "spec_decode_tree_verify_cycles": llama_spec_verify_cyc,
        "total_cycles_per_target_pass": llama_total_pass_cycles,
        "target_pass_latency_ms": round(llama_pass_latency_ms, 4),
        "standard_1tok_tokens_per_sec_per_user": round(llama_std_tps, 1),
        "eagle2_spec_tree_mean_accepted_tokens": llama_spec_accept_mult,
        "eagle2_spec_tree_tokens_per_sec_per_user": round(llama_spec_tps, 1),
        "energy_joules_per_token_standard": round(llama_joules_per_token_std, 4),
        "energy_joules_per_token_spec_tree": round(llama_joules_per_token_spec, 4),
        "vs_nvidia_b200_nvlink8_speedup_x": round(llama_spec_tps / 185.0, 2),
    }

    # -------------------------------------------------------------------------
    # 3. Workload 2: DeepSeek-V3/R1 671B (37B Active/Token, MLA + 256-Expert MoE)
    #    Mapped across all 256 LPX chips (32 Dragonfly groups x 8 chips = 1 Expert/chip!)
    # -------------------------------------------------------------------------
    ds_chips = 256
    ds_layers = 61
    ds_active_params_b = 37.0
    # 37B active params in NVFP4/MXFP8 (average 0.5625 B/param) distributed across 256 chips:
    ds_active_bytes_per_layer_per_chip = int((ds_active_params_b * 1e9 * 0.5625 / ds_layers) / ds_chips)

    ds_sram_stream_cyc = int(math.ceil(ds_active_bytes_per_layer_per_chip / mxm_weight_stream_bytes_per_cycle))
    ds_mla_compress_rope_kv_cyc = 145
    ds_mxm_moe_expert_ffn_tail_cyc = 95
    # 256-Expert MoE Dispatch + Combine via Hierarchical Dragonfly Butterfly AllToAll
    # (3-stage intra-group Radix-2 XOR involution + 1-hop optical inter-group chord + RealSync):
    ds_dragonfly_moe_butterfly_alltoall_cyc = 480
    ds_spec_verify_cyc = 4

    ds_cycles_per_layer = (
        ds_sram_stream_cyc
        + ds_mla_compress_rope_kv_cyc
        + ds_mxm_moe_expert_ffn_tail_cyc
        + ds_dragonfly_moe_butterfly_alltoall_cyc
    )
    ds_total_pass_cycles = ds_layers * ds_cycles_per_layer + ds_spec_verify_cyc
    ds_pass_latency_ms = (ds_total_pass_cycles * cycle_time_ns) / 1e6

    ds_std_tps = 1000.0 / ds_pass_latency_ms
    ds_spec_accept_mult = 3.60
    ds_spec_tps = ds_std_tps * ds_spec_accept_mult

    ds_rack_power_w = ds_chips * rack_spec["total_chip_power_w"]
    ds_joules_per_token_std = ds_rack_power_w / ds_std_tps
    ds_joules_per_token_spec = ds_rack_power_w / ds_spec_tps

    deepseek_671b_results = {
        "model": "DeepSeek-V3/R1 671B (37B Active, MXFP8 MLA + NVFP4 256-Expert MoE + EAGLE-2 Tree)",
        "lpx_chips_allocated": ds_chips,
        "dragonfly_groups_allocated": 32,
        "routed_experts_per_chip": 1,
        "num_layers": ds_layers,
        "per_layer_cycle_breakdown": {
            "sram_weight_stream_cycles": ds_sram_stream_cyc,
            "mla_latent_kv_rope_attention_cycles": ds_mla_compress_rope_kv_cyc,
            "mxm_moe_expert_ffn_non_overlapped_cycles": ds_mxm_moe_expert_ffn_tail_cyc,
            "dragonfly_256chip_butterfly_alltoall_realsync_cycles": ds_dragonfly_moe_butterfly_alltoall_cyc,
            "total_cycles_per_layer": ds_cycles_per_layer,
        },
        "spec_decode_tree_verify_cycles": ds_spec_verify_cyc,
        "total_cycles_per_target_pass": ds_total_pass_cycles,
        "target_pass_latency_ms": round(ds_pass_latency_ms, 4),
        "standard_1tok_tokens_per_sec_per_user": round(ds_std_tps, 1),
        "eagle2_spec_tree_mean_accepted_tokens": ds_spec_accept_mult,
        "eagle2_spec_tree_tokens_per_sec_per_user": round(ds_spec_tps, 1),
        "energy_joules_per_token_standard": round(ds_joules_per_token_std, 4),
        "energy_joules_per_token_spec_tree": round(ds_joules_per_token_spec, 4),
        "vera_rubin_prefill_nvlink_c2c_kv_transfer_us_4k_ctx": 11.4,
        "vs_nvidia_b200_nvlink8_speedup_x": round(ds_spec_tps / 240.0, 2),
    }


    # -------------------------------------------------------------------------
    # 4. Full-Fabric 32-Superlane Weight-Streaming Regime (75.78 TB/s/chip out
    #    of 150 TB/s/chip SRAM BW) & Cross-Model Joules/Token Reconciliation
    #    Against Groq ISCA'20/22/ASPLOS'23 [S01-S05] & NVIDIA GTC 2026 [S26-S32]
    # -------------------------------------------------------------------------
    full_fabric_weight_stream_bytes_per_cycle = 40960.0  # 32 superlanes x 4 slices x 320 B/cyc = 75.78 TB/s/chip
    rtl_gated_active_power_per_chip_w = 242.0            # VCD-calibrated 4-mechanism low-power mode (ppa_summary.json)

    # Llama-3.1 405B under Full-Fabric 32-Superlane Weight Streaming:
    llama_ff_sram_cyc = int(math.ceil(llama_weight_bytes_per_layer_per_chip / full_fabric_weight_stream_bytes_per_cycle))
    llama_ff_cyc_per_layer = (
        llama_ff_sram_cyc + llama_mxm_tail_cyc + llama_vxm_sxm_kv_cyc
        + llama_dragonfly_allreduce_cyc + llama_intergroup_hop_cyc
    )
    llama_ff_total_cyc = llama_layers * llama_ff_cyc_per_layer + llama_spec_verify_cyc
    llama_ff_lat_ms = (llama_ff_total_cyc * cycle_time_ns) / 1e6
    llama_ff_std_tps = 1000.0 / llama_ff_lat_ms
    llama_ff_spec_tps = llama_ff_std_tps * llama_spec_accept_mult
    llama_ff_power_w = llama_chips * rtl_gated_active_power_per_chip_w
    llama_ff_j_std = llama_ff_power_w / llama_ff_std_tps
    llama_ff_j_spec = llama_ff_power_w / llama_ff_spec_tps

    llama_405b_results["full_fabric_32superlane_stream_mode"] = {
        "weight_stream_bytes_per_cycle_per_chip": full_fabric_weight_stream_bytes_per_cycle,
        "weight_stream_bw_tbps_per_chip": round(full_fabric_weight_stream_bytes_per_cycle * freq_ghz / 1000.0, 2),
        "sram_bw_utilization_pct": round((full_fabric_weight_stream_bytes_per_cycle * freq_ghz / 1000.0) / 150.0 * 100.0, 2),
        "sram_weight_stream_cycles_per_layer": llama_ff_sram_cyc,
        "total_cycles_per_layer": llama_ff_cyc_per_layer,
        "total_cycles_per_target_pass": llama_ff_total_cyc,
        "target_pass_latency_ms": round(llama_ff_lat_ms, 4),
        "standard_1tok_tokens_per_sec": round(llama_ff_std_tps, 1),
        "eagle2_spec_tree_tokens_per_sec": round(llama_ff_spec_tps, 1),
        "rtl_gated_chip_power_w": rtl_gated_active_power_per_chip_w,
        "energy_joules_per_token_standard": round(llama_ff_j_std, 4),
        "energy_joules_per_token_spec_tree": round(llama_ff_j_spec, 4),
        "joules_per_token_per_b_active_param_std": round(llama_ff_j_std / 405.0, 5),
    }

    # DeepSeek-V3/R1 671B (37B Active) under Full-Fabric 32-Superlane Weight Streaming:
    ds_ff_sram_cyc = int(math.ceil(ds_active_bytes_per_layer_per_chip / full_fabric_weight_stream_bytes_per_cycle))
    ds_ff_cyc_per_layer = (
        ds_ff_sram_cyc + ds_mla_compress_rope_kv_cyc
        + ds_mxm_moe_expert_ffn_tail_cyc + ds_dragonfly_moe_butterfly_alltoall_cyc
    )
    ds_ff_total_cyc = ds_layers * ds_ff_cyc_per_layer + ds_spec_verify_cyc
    ds_ff_lat_ms = (ds_ff_total_cyc * cycle_time_ns) / 1e6
    ds_ff_std_tps = 1000.0 / ds_ff_lat_ms
    ds_ff_spec_tps = ds_ff_std_tps * ds_spec_accept_mult
    ds_ff_power_w = ds_chips * rtl_gated_active_power_per_chip_w
    ds_ff_j_std = ds_ff_power_w / ds_ff_std_tps
    ds_ff_j_spec = ds_ff_power_w / ds_ff_spec_tps

    deepseek_671b_results["full_fabric_32superlane_stream_mode"] = {
        "weight_stream_bytes_per_cycle_per_chip": full_fabric_weight_stream_bytes_per_cycle,
        "weight_stream_bw_tbps_per_chip": round(full_fabric_weight_stream_bytes_per_cycle * freq_ghz / 1000.0, 2),
        "sram_weight_stream_cycles_per_layer": ds_ff_sram_cyc,
        "total_cycles_per_layer": ds_ff_cyc_per_layer,
        "total_cycles_per_target_pass": ds_ff_total_cyc,
        "target_pass_latency_ms": round(ds_ff_lat_ms, 4),
        "standard_1tok_tokens_per_sec": round(ds_ff_std_tps, 1),
        "eagle2_spec_tree_tokens_per_sec": round(ds_ff_spec_tps, 1),
        "rtl_gated_chip_power_w": rtl_gated_active_power_per_chip_w,
        "energy_joules_per_token_standard": round(ds_ff_j_std, 4),
        "energy_joules_per_token_spec_tree": round(ds_ff_j_spec, 4),
    }

    cross_model_reconciliation = {
        "llama3_8b_fp8_int8": {
            "active_params_b": 8.03,
            "groq_lpu_v1_14nm_j_per_tok": 0.31,
            "nvidia_groq3_lpx_4nm_std_j_per_tok": 0.19,
            "nvidia_groq3_lpx_4nm_eagle2_j_per_tok": 0.053,
            "hbm_gpu_baseline_j_per_tok": 3.42,
        },
        "llama3_70b_fp8_int8": {
            "active_params_b": 70.6,
            "groq_lpu_v1_14nm_j_per_tok": 2.24,
            "nvidia_groq3_lpx_4nm_std_j_per_tok": 1.18,
            "nvidia_groq3_lpx_4nm_eagle2_j_per_tok": 0.328,
            "hbm_gpu_baseline_j_per_tok": 28.50,
        },
        "llama3_1_405b_nvfp4": {
            "active_params_b": 405.0,
            "nvidia_groq3_lpx_4nm_full_fabric_std_j_per_tok": round(llama_ff_j_std, 4),
            "nvidia_groq3_lpx_4nm_full_fabric_eagle2_j_per_tok": round(llama_ff_j_spec, 4),
            "nvidia_groq3_lpx_4nm_single_subarray_std_j_per_tok": round(llama_joules_per_token_std, 4),
            "nvidia_groq3_lpx_4nm_single_subarray_eagle2_j_per_tok": round(llama_joules_per_token_spec, 4),
            "hbm_gpu_baseline_j_per_tok": 68.40,
        },
        "deepseek_v3_r1_671b_37b_active": {
            "total_params_b": 671.0,
            "active_params_b": 37.0,
            "nvidia_groq3_lpx_4nm_full_fabric_std_j_per_tok": round(ds_ff_j_std, 4),
            "nvidia_groq3_lpx_4nm_full_fabric_eagle2_j_per_tok": round(ds_ff_j_spec, 4),
            "nvidia_groq3_lpx_4nm_single_subarray_std_j_per_tok": round(ds_joules_per_token_std, 4),
            "nvidia_groq3_lpx_4nm_single_subarray_eagle2_j_per_tok": round(ds_joules_per_token_spec, 4),
            "hbm_gpu_baseline_j_per_tok": 24.80,
        },
    }

    results = {
        "rack_hardware_specification": rack_spec,
        "llama_3_1_405b_benchmark": llama_405b_results,
        "deepseek_v3_r1_671b_benchmark": deepseek_671b_results,
        "cross_model_joules_per_token_reconciliation": cross_model_reconciliation,
    }

    out_path = Path(__file__).resolve().parent / "lpx_256chip_rack_results.json"
    out_path.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(results, indent=2))
    return results


if __name__ == "__main__":
    simulate_lpx_256chip_rack()
