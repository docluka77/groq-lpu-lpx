#!/usr/bin/env python3
"""Build and qualify the Stage 7B Accellera IEEE 1800.2-2020 UVM SRAM IP Suite."""
from pathlib import Path
import datetime
import json
import os
import re
import subprocess
import time

TB_DIR   = Path(__file__).resolve().parent
ROOT_DIR = TB_DIR.parents[1]
SRAM_DIR = ROOT_DIR / "sram_ip"
TOOL_ROOT = Path("/nfs/share/home/chenpei/verisegue_agent_v0/agent_v26/runs/uvm_gate0_20261104_221700/toolchain")
VERILATOR_ROOT = TOOL_ROOT / "verilator-5.054"
UVM_SRC  = TOOL_ROOT / "uvm-core-2020.3.1" / "src"
BUILD_DIR = TB_DIR / "build"
OUT_DIR   = TB_DIR / "results"


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, VERILATOR_ROOT=str(VERILATOR_ROOT), CCACHE_DISABLE="1")
    commands = []

    def run_cmd(name, argv, cwd, timeout=900):
        log_path = OUT_DIR / f"{name}.log"
        t0 = time.monotonic()
        print(f"[START] {name}", flush=True)
        with log_path.open("w") as f:
            proc = subprocess.run(argv, cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
        elapsed = round(time.monotonic() - t0, 3)
        rec = {"name": name, "returncode": proc.returncode, "seconds": elapsed, "log": str(log_path.name)}
        commands.append(rec)
        print(f"[DONE]  {name} rc={proc.returncode} ({elapsed}s)", flush=True)
        return proc.returncode

    cmd_compile = [
        str(VERILATOR_ROOT / "bin" / "verilator"),
        "--cc", "--exe", "--build", "--timing",
        "--coverage-line", "--coverage-toggle", "--coverage-user",
        "-j", "8", "-Wno-fatal",
        "--top-module", "sram_mem_top",
        "--Mdir", str(BUILD_DIR),
        "+define+UVM_NO_DPI",
        "+incdir+" + str(UVM_SRC),
        "+incdir+" + str(SRAM_DIR),
        "+incdir+" + str(TB_DIR),
        str(UVM_SRC / "uvm_pkg.sv"),
        str(SRAM_DIR / "groq_sram_ecc_secded.sv"),
        str(SRAM_DIR / "groq_sram_macro_sp.sv"),
        str(SRAM_DIR / "groq_mem_agu.sv"),
        str(SRAM_DIR / "groq_mem_slice.sv"),
        str(TB_DIR / "groq_sram_mem_if.sv"),
        str(TB_DIR / "groq_sram_mem_uvm_pkg.sv"),
        str(TB_DIR / "sram_mem_top.sv"),
        str(TB_DIR / "dpi_sram_mem_ref.cpp"),
        str(TB_DIR / "sim_main.cpp"),
        "-CFLAGS", "-O1 -std=c++17",
        "-o", "uvm_sram_sim"
    ]

    rc_build = run_cmd("compile", cmd_compile, TB_DIR, timeout=900)
    if rc_build != 0:
        print((OUT_DIR / "compile.log").read_text(errors="replace")[-8000:], flush=True)
        (TB_DIR / "qualification.json").write_text(json.dumps({"status": "BUILD_FAILED"}, indent=2))
        return 1

    sim_bin = BUILD_DIR / "uvm_sram_sim"
    vcov_bin = VERILATOR_ROOT / "bin" / "verilator_coverage"
    case_results = {}

    for case_name, extra_args in [("clean", []), ("dut_bug", ["+INJECT_DUT_BUG"])]:
        case_dir = OUT_DIR / case_name
        case_dir.mkdir(parents=True, exist_ok=True)
        rc_sim = run_cmd(f"sim_{case_name}", [str(sim_bin), "+UVM_VERBOSITY=UVM_LOW", *extra_args], case_dir, timeout=120)
        summary_file = case_dir / "uvm_sram_summary.json"
        summary = json.loads(summary_file.read_text()) if summary_file.is_file() else None
        cov_dat = case_dir / "coverage.dat"
        cov_info = case_dir / "coverage.info"
        if cov_dat.is_file():
            run_cmd(f"cov_{case_name}", [str(vcov_bin), "--write-info", str(cov_info), str(cov_dat)], case_dir, timeout=60)
        mod_cov = {}
        if cov_info.is_file():
            for sec in cov_info.read_text().split("end_of_record"):
                m = re.search(r"SF:(.+)", sec)
                if m and "/sram_ip/" in m.group(1):
                    fname = Path(m.group(1).strip()).name
                    counts = [int(x) for x in re.findall(r"^DA:\d+,(\d+)", sec, re.M)]
                    hit = sum(c > 0 for c in counts)
                    tot = len(counts)
                    mod_cov[fname] = {"hit": hit, "total": tot, "pct": round(100.0 * hit / tot, 2) if tot else 100.0}
        case_results[case_name] = {"returncode": rc_sim, "summary": summary, "rtl_coverage": mod_cov}

    clean_sum = case_results["clean"]["summary"] or {}
    bug_sum   = case_results["dut_bug"]["summary"] or {}
    checks = {
        "compile_zero_errors": rc_build == 0,
        "clean_exit_zero": case_results["clean"]["returncode"] == 0,
        "clean_transactions_ge_2500": clean_sum.get("checked", 0) >= 2500,
        "clean_zero_mismatches": clean_sum.get("mismatches", -1) == 0,
        "clean_functional_coverage_100": clean_sum.get("functional_coverage", 0.0) == 100.0,
        "clean_sec_1bit_verified": clean_sum.get("sec_checked", 0) == 300,
        "clean_ded_2bit_verified": clean_sum.get("ded_checked", 0) == 256,
        "clean_conflict_verified": clean_sum.get("conflict_seen", 0) == 64,
        "clean_mbist_verified": clean_sum.get("mbist_verified", 0) == 1,
        "dut_bug_caught_nonzero_rc": case_results["dut_bug"]["returncode"] != 0,
        "dut_bug_mismatches_detected": bug_sum.get("mismatches", 0) == 16
    }
    qual = {
        "stage": "7B_UVM_SRAM_MEM",
        "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": "PASS" if all(checks.values()) else "FAIL",
        "checks": checks,
        "cases": case_results,
        "commands": commands
    }
    (TB_DIR / "qualification.json").write_text(json.dumps(qual, indent=2))
    print(json.dumps(qual, indent=2), flush=True)
    return 0 if qual["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
