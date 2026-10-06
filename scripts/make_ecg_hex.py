#!/usr/bin/env python3
"""
Turn a real PhysioNet ECG recording into something the Verilog
testbench can read.

--------------------------------------------------------------------
WHY BOTHER
--------------------------------------------------------------------

Testing a beat detector on a waveform you invented yourself proves
very little. You drew the waveform, so of course your detector
finds the peaks in it.

PhysioNet's MIT-BIH Arrhythmia Database is real ECG from real
patients, and every beat in it has been marked by a cardiologist.
Run your detector over that and compare against those markings and
you get an actual number: how many real beats it found, and how
many things it called a beat that were not.

That number is the difference between "it worked when I tried it"
and a measured result.

--------------------------------------------------------------------
WHAT THIS PRODUCES
--------------------------------------------------------------------

    data/<record>_samples.hex    one 12-bit sample per line, hex
    data/<record>_beats.txt      sample index of every true beat
    data/<record>_info.txt       what was done, for the write-up

The .hex file is what $readmemh reads in tb/validation_tb.v.

--------------------------------------------------------------------
USAGE
--------------------------------------------------------------------

    pip install wfdb numpy scipy

    # 60 seconds of record 100, the usual starting point
    python make_ecg_hex.py

    # a different record, or a longer stretch
    python make_ecg_hex.py --record 119 --seconds 120

    # no internet? make a synthetic file with the same layout
    python make_ecg_hex.py --synthetic

--------------------------------------------------------------------
A NOTE ON THE SAMPLE RATE
--------------------------------------------------------------------

MIT-BIH is recorded at 360 Hz. The FPGA runs at 500 Hz. The signal
is resampled so the sample indices in the .hex file mean the same
thing as sample counts inside the design - otherwise every BPM
figure would come out wrong by a factor of 500/360.
"""

import argparse
import math
import os
import sys

TARGET_FS = 500          # must match sample_tick.v
ADC_MAX = 4095           # 12-bit XADC
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        '..', 'data')


# --------------------------------------------------------------------

def scale_to_adc(signal, headroom=0.90):
    """
    Map the recording onto the 0..4095 range the XADC produces.

    Centred at mid-scale, because that is where the AD8232 sits: it
    outputs around half its supply voltage and swings either side.

    headroom keeps the peaks off the rails. A signal clipped at 0 or
    4095 would flatten the R peak, which is the one part of the
    waveform the detector depends on.
    """
    import numpy as np

    signal = np.asarray(signal, dtype=float)
    signal = signal[np.isfinite(signal)]

    centred = signal - np.mean(signal)
    peak = np.max(np.abs(centred))
    if peak == 0:
        peak = 1.0

    scaled = (centred / peak) * (ADC_MAX / 2) * headroom
    codes = np.rint(scaled + ADC_MAX / 2)

    return np.clip(codes, 0, ADC_MAX).astype(int)


# --------------------------------------------------------------------

def load_from_physionet(record, database, seconds, lead):
    import numpy as np
    import wfdb
    from scipy.signal import resample_poly
    from fractions import Fraction

    print(f"  downloading {database}/{record} from PhysioNet...")
    rec = wfdb.rdrecord(record, pn_dir=database)
    ann = wfdb.rdann(record, 'atr', pn_dir=database)

    original_fs = float(rec.fs)
    print(f"  original rate      : {original_fs:.0f} Hz")
    print(f"  leads              : {', '.join(rec.sig_name)}")

    channel = lead if lead < rec.p_signal.shape[1] else 0
    print(f"  using lead         : {rec.sig_name[channel]}")

    signal = rec.p_signal[:, channel]

    # Resample to the rate the FPGA runs at.
    ratio = Fraction(TARGET_FS / original_fs).limit_denominator(1000)
    signal = resample_poly(signal, ratio.numerator, ratio.denominator)

    # Move the beat markings onto the new timebase too.
    beats = np.rint(np.asarray(ann.sample) *
                    (TARGET_FS / original_fs)).astype(int)

    # Keep only the requested stretch.
    wanted = int(seconds * TARGET_FS)
    if wanted < len(signal):
        signal = signal[:wanted]
        beats = beats[beats < wanted]

    return signal, beats, f"{database}/{record}, lead {rec.sig_name[channel]}"


# --------------------------------------------------------------------

def make_synthetic(seconds, bpm=75):
    """
    A stand-in for when PhysioNet is not reachable.

    It is NOT a substitute for real data in the write-up - it has no
    noise, no baseline wander and no arrhythmia. It exists so the
    testbench plumbing can be checked offline.
    """
    import numpy as np

    samples_per_beat = int(TARGET_FS * 60 / bpm)
    total = int(seconds * TARGET_FS)

    signal = np.zeros(total)
    beats = []

    for i in range(total):
        phase = i % samples_per_beat
        t = phase / samples_per_beat

        if t < 0.10:
            v = 0.08 * math.sin(math.pi * t / 0.10)     # P
        elif t < 0.16:
            v = 0.0
        elif t < 0.18:
            v = -0.15                                   # Q
        elif t < 0.21:
            v = 1.0                                     # R
        elif t < 0.24:
            v = -0.25                                   # S
        elif t < 0.32:
            v = 0.0
        elif t < 0.50:
            v = 0.22 * math.sin(math.pi * (t - 0.32) / 0.18)   # T
        else:
            v = 0.0

        # A slow wander, so baseline_remove has something to do.
        v += 0.05 * math.sin(2 * math.pi * i / (TARGET_FS * 4))

        signal[i] = v

        if phase == int(0.195 * samples_per_beat):
            beats.append(i)

    return signal, np.array(beats), f"synthetic, {bpm} BPM"


# --------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Convert a PhysioNet ECG record for the Verilog testbench.")
    parser.add_argument('--record', default='100',
                        help="record name (default 100)")
    parser.add_argument('--database', default='mitdb',
                        help="PhysioNet database (default mitdb)")
    parser.add_argument('--seconds', type=float, default=60.0,
                        help="how much to convert (default 60)")
    parser.add_argument('--lead', type=int, default=0,
                        help="which lead, 0 or 1 (default 0)")
    parser.add_argument('--synthetic', action='store_true',
                        help="generate fake data instead of downloading")
    args = parser.parse_args()

    print()
    print("=" * 52)
    print(" PREPARING ECG DATA FOR SIMULATION")
    print("=" * 52)
    print()

    try:
        import numpy as np                              # noqa: F401
    except ImportError:
        print("  numpy is required.\n    pip install numpy\n")
        return 1

    if args.synthetic:
        signal, beats, description = make_synthetic(args.seconds)
    else:
        try:
            signal, beats, description = load_from_physionet(
                args.record, args.database, args.seconds, args.lead)
        except ImportError as exc:
            print(f"  missing package: {exc}")
            print("    pip install wfdb scipy\n")
            return 1
        except Exception as exc:                        # noqa: BLE001
            print(f"  could not fetch the record: {exc}")
            print()
            print("  If you have no internet, --synthetic makes a file")
            print("  with the same layout so the testbench can be run.")
            print()
            return 1

    codes = scale_to_adc(signal)

    os.makedirs(DATA_DIR, exist_ok=True)
    stem = 'synthetic' if args.synthetic else args.record

    hex_path = os.path.join(DATA_DIR, f'{stem}_samples.hex')
    beat_path = os.path.join(DATA_DIR, f'{stem}_beats.txt')
    info_path = os.path.join(DATA_DIR, f'{stem}_info.txt')

    with open(hex_path, 'w') as f:
        for value in codes:
            f.write(f"{value:03x}\n")

    with open(beat_path, 'w') as f:
        for index in beats:
            f.write(f"{int(index)}\n")

    duration = len(codes) / TARGET_FS
    mean_bpm = (len(beats) / duration * 60) if duration else 0

    info = [
        f"source          : {description}",
        f"sample rate     : {TARGET_FS} Hz",
        f"samples         : {len(codes)}",
        f"duration        : {duration:.1f} s",
        f"annotated beats : {len(beats)}",
        f"mean heart rate : {mean_bpm:.1f} BPM",
        f"ADC range used  : {codes.min()} to {codes.max()} (of 0..{ADC_MAX})",
    ]

    with open(info_path, 'w') as f:
        f.write("\n".join(info) + "\n")

    print()
    for line in info:
        print("  " + line)
    print()
    print(f"  wrote {hex_path}")
    print(f"  wrote {beat_path}")
    print()
    print("  Next:")
    print("    iverilog -g2012 -o val_sim tb/validation_tb.v \\")
    print("             rtl/heart_pipeline.v rtl/ecg_filter.v \\")
    print("             rtl/baseline_remove.v rtl/beat_detect.v \\")
    print("             rtl/bpm_calc.v rtl/bpm_div.v rtl/bpm_uart.v rtl/uart.v")
    print(f"    vvp val_sim +samples={hex_path} +count={len(codes)}")
    print(f"    python scripts/score_detection.py --record {stem}")
    print()

    return 0


if __name__ == '__main__':
    sys.exit(main())
