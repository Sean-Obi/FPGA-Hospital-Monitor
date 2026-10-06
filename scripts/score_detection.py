#!/usr/bin/env python3
"""
Score the beat detector against a cardiologist's markings.

Compares the beats validation_tb found against the annotations that
came with the PhysioNet record, and reports the standard figures.

--------------------------------------------------------------------
THE FIGURES, IN PLAIN TERMS
--------------------------------------------------------------------

A detection counts as correct if it lands within a small window of
a real beat - 150 ms by default, which is the tolerance the
literature on QRS detection normally uses.

    Sensitivity   of all the real beats, how many were found?
                  Misses hurt this.

    PPV           of everything the detector called a beat, how many
                  really were? False alarms hurt this.
                  (Positive Predictive Value.)

    F1            the two combined into one number, so a single
                  figure can be compared across settings.

Both matter and they pull against each other. Drop the threshold and
you find every beat but also call noise a beat. Raise it and every
detection is real but you miss the small ones. That trade-off is the
interesting thing to plot in the report.

--------------------------------------------------------------------
USAGE
--------------------------------------------------------------------

    # score the last run
    python score_detection.py --record 100

    # sweep the threshold to find the best one, then plot it
    python score_detection.py --record 100 --sweep 30 200 10
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
DATA = os.path.join(ROOT, 'data')

SAMPLE_RATE_HZ = 500
DEFAULT_TOLERANCE_MS = 150


# --------------------------------------------------------------------

def read_indices(path):
    values = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                values.append(int(line))
    return sorted(values)


# --------------------------------------------------------------------

def score(detected, truth, tolerance_samples):
    """
    Match each detection to at most one real beat, and vice versa.

    Matching one-to-one matters. If two detections both landed near
    the same real beat, only one is a hit - the other is a false
    alarm, and counting it as correct would hide exactly the
    double-counting the refractory window exists to prevent.
    """
    used = [False] * len(truth)
    true_positives = 0
    false_positives = 0
    offsets = []

    ti = 0
    for d in detected:
        # Walk forward to the first real beat that could still match.
        while ti < len(truth) and truth[ti] < d - tolerance_samples:
            ti += 1

        matched = False
        probe = ti
        while probe < len(truth) and truth[probe] <= d + tolerance_samples:
            if not used[probe]:
                used[probe] = True
                offsets.append(d - truth[probe])
                true_positives += 1
                matched = True
                break
            probe += 1

        if not matched:
            false_positives += 1

    false_negatives = used.count(False)

    sensitivity = (true_positives / (true_positives + false_negatives)
                   if (true_positives + false_negatives) else 0.0)
    ppv = (true_positives / (true_positives + false_positives)
           if (true_positives + false_positives) else 0.0)
    f1 = (2 * sensitivity * ppv / (sensitivity + ppv)
          if (sensitivity + ppv) else 0.0)

    mean_offset_ms = (sum(offsets) / len(offsets) / SAMPLE_RATE_HZ * 1000
                      if offsets else 0.0)

    return {
        'tp': true_positives,
        'fp': false_positives,
        'fn': false_negatives,
        'sensitivity': sensitivity,
        'ppv': ppv,
        'f1': f1,
        'mean_offset_ms': mean_offset_ms,
    }


# --------------------------------------------------------------------

def report(result, truth_count):
    print()
    print(f"  real beats           : {truth_count}")
    print(f"  correctly detected   : {result['tp']}")
    print(f"  missed               : {result['fn']}")
    print(f"  false detections     : {result['fp']}")
    print()
    print(f"  Sensitivity          : {result['sensitivity'] * 100:6.2f}%")
    print(f"  PPV                  : {result['ppv'] * 100:6.2f}%")
    print(f"  F1                   : {result['f1'] * 100:6.2f}%")
    print()
    print(f"  mean timing offset   : {result['mean_offset_ms']:+.1f} ms")
    print()

    # A little interpretation, so the numbers are not just numbers.
    if result['fn'] > result['tp'] * 0.05:
        print("  Missing more than 5% of beats. The threshold is")
        print("  probably too high - lower it and run again.")
        print()
    elif result['fp'] > result['tp'] * 0.05:
        print("  More than 5% false detections. Either the threshold")
        print("  is too low, or T waves are being counted - check")
        print("  whether the false ones sit just after a real beat.")
        print()


# --------------------------------------------------------------------

def run_sweep(record, lo, hi, step, tolerance_samples, truth):
    """
    Rebuild and re-run the testbench at each threshold.

    The threshold is a Verilog parameter, so it is fixed when the
    simulation is built. Trying a different one means compiling
    again - which takes about a second, so a sweep is cheap.
    """
    samples_path = os.path.join(DATA, f'{record}_samples.hex')
    count = sum(1 for _ in open(samples_path))

    rtl = [os.path.join(ROOT, 'rtl', f) for f in (
        'heart_pipeline.v', 'ecg_filter.v', 'baseline_remove.v',
        'beat_detect.v', 'bpm_calc.v', 'bpm_div.v', 'bpm_uart.v', 'uart.v')]
    tb = os.path.join(ROOT, 'tb', 'validation_tb.v')

    print()
    print("  threshold   sens     PPV      F1      TP    FP    FN")
    print("  " + "-" * 54)

    rows = []
    for threshold in range(lo, hi + 1, step):
        sim = os.path.join(DATA, '_sweep_sim')
        out = os.path.join(DATA, '_sweep_beats.txt')

        build = subprocess.run(
            ['iverilog', '-g2012',
             f'-Pvalidation_tb.THRESHOLD={threshold}',
             '-o', sim, tb] + rtl,
            capture_output=True, text=True)

        if build.returncode != 0:
            print(f"  build failed at threshold {threshold}:")
            print(build.stderr)
            return None

        subprocess.run(['vvp', sim,
                        f'+samples={samples_path}',
                        f'+count={count}',
                        f'+out={out}'],
                       capture_output=True, text=True)

        detected = read_indices(out)
        r = score(detected, truth, tolerance_samples)
        rows.append((threshold, r))

        print(f"  {threshold:>9}   "
              f"{r['sensitivity'] * 100:5.1f}%  "
              f"{r['ppv'] * 100:5.1f}%  "
              f"{r['f1'] * 100:5.1f}%  "
              f"{r['tp']:>5} {r['fp']:>5} {r['fn']:>5}")

    for path in ('_sweep_sim', '_sweep_beats.txt'):
        full = os.path.join(DATA, path)
        if os.path.exists(full):
            os.remove(full)

    best = max(rows, key=lambda row: row[1]['f1'])
    print()
    print(f"  Best F1 at threshold {best[0]}: "
          f"{best[1]['f1'] * 100:.2f}%")
    print()
    print("  Put this table in the report. It shows the threshold")
    print("  was chosen from measurements, not picked by eye.")
    print()

    return rows


# --------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Score the beat detector against PhysioNet annotations.")
    parser.add_argument('--record', default='100',
                        help="record name used by make_ecg_hex.py")
    parser.add_argument('--detected',
                        help="detections file (default data/detected_beats.txt)")
    parser.add_argument('--tolerance', type=float,
                        default=DEFAULT_TOLERANCE_MS,
                        help=f"match window in ms (default {DEFAULT_TOLERANCE_MS})")
    parser.add_argument('--sweep', nargs=3, type=int,
                        metavar=('LO', 'HI', 'STEP'),
                        help="rebuild and re-run across a threshold range")
    args = parser.parse_args()

    truth_path = os.path.join(DATA, f'{args.record}_beats.txt')
    detected_path = args.detected or os.path.join(DATA, 'detected_beats.txt')

    print()
    print("=" * 52)
    print(" BEAT DETECTOR SCORING")
    print("=" * 52)

    if not os.path.exists(truth_path):
        print()
        print(f"  No annotations at {truth_path}")
        print("  Run make_ecg_hex.py first.")
        print()
        return 1

    truth = read_indices(truth_path)
    tolerance_samples = int(args.tolerance / 1000 * SAMPLE_RATE_HZ)

    print()
    print(f"  record          : {args.record}")
    print(f"  match tolerance : {args.tolerance:.0f} ms "
          f"({tolerance_samples} samples)")

    if args.sweep:
        lo, hi, step = args.sweep
        run_sweep(args.record, lo, hi, step, tolerance_samples, truth)
        return 0

    if not os.path.exists(detected_path):
        print()
        print(f"  No detections at {detected_path}")
        print("  Run the validation testbench first:")
        print(f"    vvp val_sim +samples=data/{args.record}_samples.hex "
              f"+count=<N>")
        print()
        return 1

    detected = read_indices(detected_path)
    print(f"  detections      : {len(detected)}")

    report(score(detected, truth, tolerance_samples), len(truth))
    return 0


if __name__ == '__main__':
    sys.exit(main())
