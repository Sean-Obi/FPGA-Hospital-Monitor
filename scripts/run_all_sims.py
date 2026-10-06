#!/usr/bin/env python3
"""
Build and run every testbench, and say what passed.

    python scripts/run_all_sims.py

Works the same on Windows, macOS and Linux, so there is no separate
.sh and .bat to keep in step.

Run this after changing anything in rtl/. It takes a couple of
minutes and it is the difference between "I think that still works"
and knowing.
"""

import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
RTL = os.path.join(ROOT, 'rtl')
TB = os.path.join(ROOT, 'tb')
BUILD = os.path.join(ROOT, 'build')


def rtl_files(*, include_xadc=False, include_top=False, include_practice=False):
    out = []
    for name in sorted(os.listdir(RTL)):
        if not name.endswith('.v'):
            continue
        if name == 'xadc_reader.v' and not include_xadc:
            continue
        if name == 'top.v' and not include_top:
            continue
        if name.startswith('practice') and not include_practice:
            continue
        out.append(os.path.join(RTL, name))
    return out


# Each entry: testbench name -> the files it needs.
#
# xadc_reader and top need the XADC simulation model, because Icarus
# has no idea what the Xilinx XADC primitive is. Vivado does, so that
# model must never go into synthesis - see the note at the top of it.
#
# Likewise the MAX30102 model stands in for the real pulse oximeter
# chip on the I2C bus. Simulation only.
def build_plan():
    xadc = os.path.join(TB, 'xadc_model.v')
    max3 = os.path.join(TB, 'max30102_model.v')

    plan = {
        'ecg_filter_tb':       rtl_files(),
        'baseline_remove_tb':  rtl_files(),
        'bpm_calc_tb':         rtl_files(),
        'bpm_div_tb':          rtl_files(),
        'bpm_uart_tb':         rtl_files(),
        'uart_tb':             rtl_files(),
        'telemetry_uart_tb':   rtl_files(),
        'heart_pipeline_tb':   rtl_files(),
        'tb_sample_tick':      rtl_files(),
        'tb_beat_detect':      rtl_files(),
        'tb_buzzer':           rtl_files(),
        'tb_led_flash':        rtl_files(),
        'udiv_tb':             rtl_files(),
        'temp_convert_tb':     rtl_files(),
        'spo2_calc_tb':        rtl_files(),
        'i2c_master_tb':       [max3] + rtl_files(),
        'max30102_driver_tb':  [max3] + rtl_files(),
        'xadc_reader_tb':      [xadc, os.path.join(RTL, 'xadc_reader.v')],
        'top_tb':              [xadc, max3] + rtl_files(include_xadc=True,
                                                        include_top=True),
    }

    return {name: files for name, files in plan.items()
            if os.path.exists(os.path.join(TB, name + '.v'))}


PASS_PATTERNS = [
    re.compile(r'PASS\s*-\s*all checks passed'),
    re.compile(r'PASS:\s*all \d+ .* correct'),
    re.compile(r'TEST FINISHED'),
]

FAIL_PATTERNS = [
    re.compile(r'\bFAIL\b'),
    re.compile(r'\bERROR\b'),
    re.compile(r'TIMEOUT'),
]


def main():
    os.makedirs(BUILD, exist_ok=True)
    plan = build_plan()

    print()
    print("=" * 62)
    print(" RUNNING ALL TESTBENCHES")
    print("=" * 62)
    print()

    failures = []
    started = time.time()

    for name, files in plan.items():
        tb_path = os.path.join(TB, name + '.v')
        out_path = os.path.join(BUILD, name + '.out')

        print(f"  {name:<22}", end='', flush=True)

        build = subprocess.run(
            ['iverilog', '-g2012', '-o', out_path, tb_path] + files,
            capture_output=True, text=True, cwd=ROOT)

        if build.returncode != 0:
            print("BUILD ERROR")
            print(build.stderr.strip()[:400])
            failures.append(name)
            continue

        try:
            run = subprocess.run(['vvp', out_path], capture_output=True,
                                 text=True, cwd=ROOT, timeout=600)
        except subprocess.TimeoutExpired:
            print("TIMED OUT")
            failures.append(name)
            continue

        text = run.stdout

        if any(p.search(text) for p in FAIL_PATTERNS):
            print("FAILED")
            for line in text.splitlines():
                if any(p.search(line) for p in FAIL_PATTERNS):
                    print(f"      {line.strip()}")
            failures.append(name)
        elif any(p.search(text) for p in PASS_PATTERNS):
            summary = ''
            for line in text.splitlines():
                if any(p.search(line) for p in PASS_PATTERNS):
                    summary = line.strip()
            print(f"pass    {summary[:40]}")
        else:
            # Some of the earlier testbenches just print a trace and
            # have nothing to assert. Not a failure, but worth
            # distinguishing from one that actually checked itself.
            print("ran     (no self-check)")

    elapsed = time.time() - started

    print()
    print("=" * 62)
    if failures:
        print(f" {len(failures)} FAILED: {', '.join(failures)}")
    else:
        print(f" ALL {len(plan)} TESTBENCHES OK   ({elapsed:.0f}s)")
    print("=" * 62)
    print()

    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
