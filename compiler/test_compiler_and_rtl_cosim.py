#!/usr/bin/env python3
"""
Stage 15: Comprehensive Deterministic Spatial VLIW Compiler Test Suite,
Negative Hazard Injection Qualification, Golden Model Co-Execution, and
Verilator 5.054 RTL Co-Simulation (`compiler/test_compiler_and_rtl_cosim.py`).
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
from typing import Any, Dict, List, Tuple

import numpy as np

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_ROOT_DIR = os.path.dirname(_THIS_DIR)
if _ROOT_DIR not in sys.path:
    sys.path.insert(0, _ROOT_DIR)
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

from compiler.groq_deterministic_compiler import (
    CompiledSchedule,
    GroqDeterministicVliwCompiler,
    GroqVliwInstr,
    NUM_SLICES,
    OperatorType,
    RTL_MEM_READ_EAST,
    RTL_MEM_WRITE_EAST,
    RTL_SXM_ROTATE_LEFT,
    RTL_VXM_VADD,
    RtlBitExactHelper,
    RtlBitExactSimulator,
    SLICE_MEM_E,
    SLICE_MEM_W,
    SLICE_MXM_E,
    SLICE_MXM_W,
    SLICE_NAMES,
    SLICE_NIM,
    SLICE_SXM,
    SLICE_VXM,
    StaticScheduleVerifier,
    build_workload1_attention_rope_kv_ring,
    build_workload2_swiglu_fp8_realsync_allreduce,
    build_workload3_deepseek_mla_moe_dispatch,
    emit_sv_rom,
    emit_vliw_hex,
    evaluate_dag_functional_spec,
    execute_on_arch_golden_model,
)


def create_deterministic_initial_state() -> Tuple[
    Dict[int, Dict[int, Dict[Tuple[int, int], np.ndarray]]],
    Dict[int, Dict[int, np.ndarray]],
]:
    """
    Creates the exact deterministic initial SRAM (4 banks x 16 rows on Chip 0 & Chip 1)
    and 16x16 MXM_W / MXM_E weight matrices matching `tb_compiler_rtl_cosim.sv`.
    """
    sram: Dict[int, Dict[int, Dict[Tuple[int, int], np.ndarray]]] = {
        0: {SLICE_MEM_W: {}, SLICE_MEM_E: {}},
        1: {SLICE_MEM_W: {}, SLICE_MEM_E: {}},
    }
    mxm_wt: Dict[int, Dict[int, np.ndarray]] = {
        0: {
            SLICE_MXM_W: np.zeros((2, 16, 16), dtype=np.int32),
            SLICE_MXM_E: np.zeros((2, 16, 16), dtype=np.int32),
        },
        1: {
            SLICE_MXM_W: np.zeros((2, 16, 16), dtype=np.int32),
            SLICE_MXM_E: np.zeros((2, 16, 16), dtype=np.int32),
        },
    }

    for b in range(4):
        for a in range(16):
            v0 = np.array(
                [RtlBitExactHelper.s8(((b * 17 + a * 5 + l * 3 + 1) & 0x3F) - 16) for l in range(16)],
                dtype=np.int32,
            )
            v1 = np.array(
                [RtlBitExactHelper.s8(((b * 13 + a * 7 + l * 5 + 3) & 0x3F) - 16) for l in range(16)],
                dtype=np.int32,
            )
            sram[0][SLICE_MEM_W][(b, a)] = v0.copy()
            sram[0][SLICE_MEM_E][(b, a)] = v0.copy()
            sram[1][SLICE_MEM_W][(b, a)] = v1.copy()
            sram[1][SLICE_MEM_E][(b, a)] = v1.copy()

    # Active bank 0 weights are preloaded from Bank 0 Rows 0..15
    for r in range(16):
        mxm_wt[0][SLICE_MXM_W][0, r, :] = sram[0][SLICE_MEM_W][(0, r)].copy()
        mxm_wt[0][SLICE_MXM_E][0, r, :] = sram[0][SLICE_MEM_W][(0, r)].copy()
        mxm_wt[1][SLICE_MXM_W][0, r, :] = sram[1][SLICE_MEM_W][(0, r)].copy()
        mxm_wt[1][SLICE_MXM_E][0, r, :] = sram[1][SLICE_MEM_W][(0, r)].copy()

    return sram, mxm_wt


def vec16_to_hex32(vec: np.ndarray) -> str:
    """Packs 16 x 8-bit lanes (lane 15 MSB .. lane 0 LSB) into a 32-char lowercase hex string."""
    val = 0
    for l in range(16):
        val |= (int(vec[l]) & 0xFF) << (8 * l)
    return f"{val:032x}"

def run_negative_hazard_injection_tests(
    base_sched: CompiledSchedule,
    verifier: StaticScheduleVerifier,
    log_lines: List[str],
) -> Dict[str, Any]:
    """
    Deliberately injects 4 distinct classes of schedule hazards into cloned schedules
    and proves that `StaticScheduleVerifier` catches and rejects 100% of them:
      1. Stream Write Collision Injection
      2. Same-Bank SRAM Read/Write Conflict Injection
      3. 1-Cycle Producer-Consumer Timing Skew Injection
      4. Uninitialized Stream Read Injection
    """
    results: Dict[str, Any] = {}

    # Negative Test 1: Inject Stream Write Collision on East Stream 0 at Hop 2 (SLICE_SXM)
    # In base_sched (Workload 1), Chip 0 SLICE_MEM_W (Hop 1) reads at Cycle 0 onto East Stream 0,
    # which arrives at Hop 2 (SLICE_SXM) at Cycle 2. If SLICE_MEM_W ALSO reads onto East Stream 0
    # at Cycle 1, its injection at Hop 1 at Cycle 2 collides with an injection at Hop 2 at Cycle 3!
    # Even simpler: if SLICE_MEM_W issues MEM_READ_EAST -> Stream 0 at Cycle 0 (injected at Hop 1 at Cycle 1,
    # propagates to Hop 2 at Cycle 2), and SLICE_SXM (Hop 2) injects onto East Stream 0 at Cycle 2
    # while East Stream 0 is already valid at Hop 2 at Cycle 2! Wait: in Workload 1 Wave 2, let's inject
    # a second MEM_READ_EAST -> Stream 0 at Cycle 0 on SLICE_NIM (Hop 0) -> arrives at Hop 1 at Cycle 2,
    # while SLICE_MEM_W (Hop 1) issues MEM_READ_EAST -> Stream 0 at Cycle 1 (injects at Hop 1 at Cycle 2)!
    sched_coll = copy.deepcopy(base_sched)
    # At Cycle 0, SLICE_MEM_W issues MEM_READ_EAST on dst_stream=0 (injects at Hop 1 at Cycle 1, reaches Hop 2 at Cycle 2).
    # Inject a bogus SXM op at Cycle 1 on dst_stream=0 so SXM injects at Hop 2 at Cycle 2 -> collides with propagating flit!
    sched_coll.cycle_table[0][1][SLICE_SXM] = GroqVliwInstr(
        target_slice=SLICE_SXM,
        sxm_op=RTL_SXM_ROTATE_LEFT,
        src_stream_a=0,
        dst_stream=0,
        dst_dir_west=0,
    )
    rep_coll = verifier.verify(sched_coll)
    assert not rep_coll.passed and rep_coll.stream_write_collisions > 0, (
        "Negative Test 1 FAILED: Stream write collision was not caught!"
    )
    log_lines.append(
        f"  [PASS] Negative Hazard Test 1 (Injected Stream Write Collision): "
        f"REJECTED as expected (collisions={rep_coll.stream_write_collisions}) -> {rep_coll.violations[0]}"
    )
    results["neg_stream_collision_caught"] = True

    # Negative Test 2: Inject Same-Bank SRAM Read/Write Conflict on SLICE_MEM_W Bank 0 at Cycle 0
    sched_bank = copy.deepcopy(base_sched)
    sched_bank.reservation_tables[0].reserve_bank(0, SLICE_MEM_W, 0, "WR", 999)
    sched_bank.cycle_table[0][0][SLICE_MEM_W].imm16 |= 0x8000
    rep_bank = verifier.verify(sched_bank)
    assert not rep_bank.passed and rep_bank.sram_bank_conflicts > 0, (
        "Negative Test 2 FAILED: SRAM same-bank Read/Write conflict was not caught!"
    )
    log_lines.append(
        f"  [PASS] Negative Hazard Test 2 (Injected Same-Bank SRAM Conflict): "
        f"REJECTED as expected (bank_conflicts={rep_bank.sram_bank_conflicts}) -> {rep_bank.violations[0]}"
    )
    results["neg_bank_conflict_caught"] = True

    # Negative Test 3: Inject +1-Cycle Producer-Consumer Timing Skew on Edge 0 (w1_load_h -> w1_rmsnorm)
    sched_skew = copy.deepcopy(base_sched)
    edge0 = sched_skew.dag.edges[0]
    dst_node = sched_skew.dag.nodes[edge0.dst_node_id]
    old_t = dst_node.scheduled_cycle
    new_t = old_t + 1
    dst_node.scheduled_cycle = new_t
    edge0.consume_cycle = new_t
    sched_skew.cycle_table[0][new_t][dst_node.target_slice] = copy.deepcopy(
        sched_skew.cycle_table[0][old_t][dst_node.target_slice]
    )
    sched_skew.cycle_table[0][old_t][dst_node.target_slice] = GroqVliwInstr(
        target_slice=dst_node.target_slice
    )
    rep_skew = verifier.verify(sched_skew)
    assert (
        not rep_skew.passed
        and rep_skew.flight_time_violations > 0
        and rep_skew.uninitialized_stream_reads > 0
    ), "Negative Test 3 FAILED: +1-cycle timing skew was not caught!"
    log_lines.append(
        f"  [PASS] Negative Hazard Test 3 (Injected +1-Cycle Timing Skew): "
        f"REJECTED as expected (flight_violations={rep_skew.flight_time_violations}, "
        f"uninit_reads={rep_skew.uninitialized_stream_reads}) -> {rep_skew.violations[-1]}"
    )
    results["neg_timing_skew_caught"] = True

    # Negative Test 4: Inject Uninitialized Stream Read on unused Stream 15 at SLICE_VXM Cycle 1
    sched_uninit = copy.deepcopy(base_sched)
    sched_uninit.cycle_table[0][1][SLICE_VXM] = GroqVliwInstr(
        target_slice=SLICE_VXM,
        vxm_op=RTL_VXM_VADD,
        src_stream_a=15,
        src_stream_b=15,
        dst_stream=14,
    )
    rep_uninit = verifier.verify(sched_uninit)
    assert not rep_uninit.passed and rep_uninit.uninitialized_stream_reads > 0, (
        "Negative Test 4 FAILED: Uninitialized stream read was not caught!"
    )
    log_lines.append(
        f"  [PASS] Negative Hazard Test 4 (Injected Uninitialized Stream Read): "
        f"REJECTED as expected (uninit_reads={rep_uninit.uninitialized_stream_reads}) -> {rep_uninit.violations[0]}"
    )
    results["neg_uninit_read_caught"] = True

    return results

def build_and_run_verilator_cosim(compiler_dir: str, out_dir: str, log_lines: List[str]) -> Dict[str, str]:
    """Compiles `tb_compiler_rtl_cosim.sv` with Verilator 5.054 and runs the RTL co-simulation."""
    root_dir = os.path.dirname(compiler_dir)
    rtl_dir = os.path.join(root_dir, "rtl")
    sram_dir = os.path.join(root_dir, "sram_ip")
    build_dir = os.path.join(compiler_dir, "build_cosim")
    os.makedirs(build_dir, exist_ok=True)

    tc_root = "/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain"
    verilator_root = os.path.join(tc_root, "verilator-5.054")
    verilator_bin = os.path.join(verilator_root, "bin", "verilator")

    env = os.environ.copy()
    env["VERILATOR_ROOT"] = verilator_root

    cmd = [
        verilator_bin,
        "--cc", "--exe", "--build", "--timing",
        "-j", "8", "-Wno-fatal",
        "--top-module", "tb_compiler_rtl_cosim",
        "--Mdir", build_dir,
        f"+incdir+{rtl_dir}",
        f"+incdir+{sram_dir}",
        f"+incdir+{out_dir}",
        f"+incdir+{compiler_dir}",
        os.path.join(rtl_dir, "groq_pkg.sv"),
        os.path.join(sram_dir, "groq_sram_macro_sp.sv"),
        os.path.join(sram_dir, "groq_sram_ecc_secded.sv"),
        os.path.join(sram_dir, "groq_mem_agu.sv"),
        os.path.join(sram_dir, "groq_mem_slice.sv"),
        os.path.join(rtl_dir, "groq_stream_fabric.sv"),
        os.path.join(rtl_dir, "groq_icu_slice.sv"),
        os.path.join(rtl_dir, "groq_nim_realsync.sv"),
        os.path.join(rtl_dir, "groq_sxm_slice.sv"),
        os.path.join(rtl_dir, "groq_vxm_slice.sv"),
        os.path.join(rtl_dir, "groq_mxm_slice.sv"),
        os.path.join(rtl_dir, "groq_lpu_top.sv"),
        os.path.join(rtl_dir, "groq_lpu_cluster_top.sv"),
        os.path.join(compiler_dir, "tb_compiler_rtl_cosim.sv"),
        os.path.join(compiler_dir, "sim_compiler_cosim.cpp"),
        "-CFLAGS", "-O1 -std=c++17",
        "-o", "compiler_rtl_cosim_sim",
    ]
    log_lines.append("[VERILATOR] Compiling tb_compiler_rtl_cosim.sv with Verilator 5.054...")
    proc_build = subprocess.run(cmd, cwd=compiler_dir, env=env, capture_output=True, text=True)
    if proc_build.returncode != 0:
        raise RuntimeError(f"Verilator build failed:\n{proc_build.stdout}\n{proc_build.stderr}")

    sim_bin = os.path.join(build_dir, "compiler_rtl_cosim_sim")
    log_lines.append("[VERILATOR] Executing RTL co-simulation binary compiler_rtl_cosim_sim...")
    proc_run = subprocess.run([sim_bin], cwd=out_dir, env=env, capture_output=True, text=True)
    if proc_run.returncode != 0:
        raise RuntimeError(f"Verilator run failed:\n{proc_run.stdout}\n{proc_run.stderr}")
    log_lines.append(f"  {proc_run.stdout.strip()}")

    res_path = os.path.join(out_dir, "rtl_cosim_results.txt")
    parsed: Dict[str, str] = {}
    with open(res_path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) == 2:
                parsed[parts[0]] = parts[1].lower()
    return parsed


def main() -> None:
    out_dir = os.path.join(_THIS_DIR, "out")
    os.makedirs(out_dir, exist_ok=True)
    log_lines: List[str] = [
        "================================================================================",
        "Stage 15: Groq LPU Deterministic Spatial VLIW Compiler & Static Verifier Suite",
        "================================================================================",
    ]

    compiler = GroqDeterministicVliwCompiler(c2c_flight_cycles=5)
    verifier = StaticScheduleVerifier(c2c_flight_cycles=5)
    init_sram, init_mxm_wt = create_deterministic_initial_state()

    workloads = [
        ("w1", build_workload1_attention_rope_kv_ring(), 1, [
            ("W1_C0_E_B0_R8",  0, SLICE_MEM_E, 0, 8),
            ("W1_C0_E_B1_R9",  0, SLICE_MEM_E, 1, 9),
            ("W1_C0_W_B2_R10", 0, SLICE_MEM_W, 2, 10),
        ]),
        ("w2", build_workload2_swiglu_fp8_realsync_allreduce(), 2, [
            ("W2_C0_E_B0_R11", 0, SLICE_MEM_E, 0, 11),
            ("W2_C0_W_B3_R12", 0, SLICE_MEM_W, 3, 12),
            ("W2_C1_E_B2_R12", 1, SLICE_MEM_E, 2, 12),
        ]),
        ("w3", build_workload3_deepseek_mla_moe_dispatch(), 2, [
            ("W3_C0_E_B2_R13", 0, SLICE_MEM_E, 2, 13),
            ("W3_C0_E_B3_R14", 0, SLICE_MEM_E, 3, 14),
            ("W3_C1_E_B3_R15", 1, SLICE_MEM_E, 3, 15),
        ]),
    ]

    compiled_schedules: Dict[str, CompiledSchedule] = {}
    golden_expected: Dict[str, str] = {}
    summary_data: Dict[str, Any] = {"workloads": {}, "negative_tests": {}, "rtl_cosim": {}}

    for prefix, dag, n_chips, check_targets in workloads:
        sched = compiler.compile(dag, num_chips=n_chips, drain_cycles=4)
        compiled_schedules[prefix] = sched
        rep = verifier.verify(sched)
        assert rep.passed, f"StaticScheduleVerifier failed on {dag.name}: {rep.violations}"

        emit_vliw_hex(sched, out_dir, prefix)
        emit_sv_rom(sched, out_dir, prefix)

        # 1. Pure High-Level DAG Functional Spec
        dag_spec_res = evaluate_dag_functional_spec(dag, init_sram, init_mxm_wt)
        # 2. Cycle-Accurate Golden Simulator & Arch Golden Model
        sim = RtlBitExactSimulator(num_chips=2, c2c_flight_cycles=5)
        sim.sram = copy.deepcopy(init_sram)
        sim.mxm_wt = copy.deepcopy(init_mxm_wt)
        sim_res = sim.run_schedule(sched)
        gm_res = execute_on_arch_golden_model(dag, init_sram, init_mxm_wt)

        # Verify 100% node-by-node agreement between High-Level DAG Spec and Compiled Schedule Simulator
        for nid in dag.nodes:
            assert np.array_equal(dag_spec_res["node_outputs"][nid], sim_res["node_outputs"][nid]), (
                f"Node {nid} mismatch between DAG Spec and Compiled Schedule!"
            )

        for tag, c_id, m_slice, b_id, r_id in check_targets:
            spec_hex = vec16_to_hex32(dag_spec_res["sram"][c_id][m_slice][(b_id, r_id)])
            sim_hex = vec16_to_hex32(sim_res["sram"][c_id][m_slice][(b_id, r_id)])
            assert spec_hex == sim_hex
            golden_expected[tag] = spec_hex

        log_lines.append(
            f"[PASS] {dag.name} ({prefix}): nodes={len(dag.nodes)}, edges={len(dag.edges)}, "
            f"cycles={sched.total_cycles}, unrolled_bundles={sched.uncompressed_instr_count}, "
            f"nop_delay_compressed={sched.compressed_instr_count} ({sched.nop_delay_compression_ratio}x), "
            f"collisions={rep.stream_write_collisions}, bank_conflicts={rep.sram_bank_conflicts}, "
            f"uninit_reads={rep.uninitialized_stream_reads}, flight_eq_violations={rep.flight_time_violations}, "
            f"gm_collisions={gm_res['gm_collision_count']}"
        )
        summary_data["workloads"][prefix] = {
            "name": dag.name,
            "nodes": len(dag.nodes),
            "edges": len(dag.edges),
            "total_cycles": sched.total_cycles,
            "uncompressed_bundles": sched.uncompressed_instr_count,
            "compressed_bundles": sched.compressed_instr_count,
            "compression_ratio": sched.nop_delay_compression_ratio,
            "static_verifier_passed": rep.passed,
        }

    log_lines.append("--------------------------------------------------------------------------------")
    log_lines.append("[NEGATIVE HAZARD INJECTION QUALIFICATION]")
    summary_data["negative_tests"] = run_negative_hazard_injection_tests(
        compiled_schedules["w1"], verifier, log_lines
    )

    log_lines.append("--------------------------------------------------------------------------------")
    rtl_results = build_and_run_verilator_cosim(_THIS_DIR, out_dir, log_lines)
    assert int(rtl_results.get("RUNTIME_FAULTS", "1")) == 0, "RTL runtime fault detected!"

    mismatches = 0
    for tag, exp_hex in golden_expected.items():
        rtl_hex = rtl_results.get(tag, "MISSING")
        match = (rtl_hex == exp_hex)
        if not match:
            mismatches += 1
        log_lines.append(
            f"  [{'MATCH' if match else 'MISMATCH'}] {tag}: DAG_Spec/Golden={exp_hex} | RTL_Verilator={rtl_hex}"
        )

    assert mismatches == 0, f"RTL Co-Simulation had {mismatches} mismatches!"
    summary_data["rtl_cosim"] = {
        "total_rtl_cycles": int(rtl_results["TOTAL_RTL_CYCLES"]),
        "runtime_faults": int(rtl_results["RUNTIME_FAULTS"]),
        "vector_checks": len(golden_expected),
        "lane_checks": len(golden_expected) * 16,
        "mismatches": mismatches,
    }
    log_lines.append("================================================================================")
    log_lines.append(
        f"STAGE 15 VERIFICATION RESULT: PASS (3/3 Workloads, 4/4 Negative Hazard Tests, "
        f"{len(golden_expected)}/{len(golden_expected)} 128-bit Vectors = {len(golden_expected)*16} Lanes Bit-Exact, 0 Mismatches)"
    )
    log_lines.append("================================================================================")

    log_text = "\n".join(log_lines) + "\n"
    print(log_text, end="")
    with open(os.path.join(_THIS_DIR, "compiler_verification.log"), "w", encoding="utf-8") as f:
        f.write(log_text)
    with open(os.path.join(out_dir, "compiler_verification_summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary_data, f, indent=2)


if __name__ == "__main__":
    main()
