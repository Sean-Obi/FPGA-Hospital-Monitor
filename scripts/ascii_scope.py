"""
ascii_scope.py - plot the ECG stream in the terminal.

No GUI libraries needed, just pyserial. Time runs DOWN the page,
amplitude runs ACROSS. An R peak shows up as a spike to the right.

    python scripts/ascii_scope.py COM4

Optional second argument is how many seconds to capture (default 3).
"""

import sys
import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"
SECONDS = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

FS = 500                      # samples per second from the FPGA
WIDTH = 70                    # columns of plot
EVERY = 5                     # plot 1 sample in 5, so the page is readable

n_wanted = int(FS * SECONDS)

print(f"capturing {SECONDS:g}s from {PORT} ...")

ser = serial.Serial(PORT, 115200, timeout=2)
samples = []
bpm = temp = spo2 = None

while len(samples) < n_wanted:
    line = ser.readline().decode(errors="ignore").strip()
    if len(line) != 5 or not line[1:].isdigit():
        continue                      # a fragment, or not for us
    tag, value = line[0], int(line[1:])
    if tag == "S":
        samples.append(value)
    elif tag == "B":
        bpm = value
    elif tag == "T":
        temp = value
    elif tag == "O":
        spo2 = value

ser.close()

lo, hi = min(samples), max(samples)
span = hi - lo

print()
print(f"  samples   {len(samples)}")
print(f"  min       {lo}")
print(f"  max       {hi}")
print(f"  range     {span} counts  ({span * 0.81:.1f} mV)")
if bpm is not None:
    print(f"  BPM       {bpm}")
if temp is not None:
    print(f"  temp      {temp / 10:.1f} C (skin)")
if spo2 is not None:
    print(f"  SpO2      {'sensor not responding' if spo2 == 999 else 'no finger' if spo2 == 0 else str(spo2) + ' %'}")
print()

if span < 50:
    print("  Range under 50 counts - that is noise, not a heartbeat.")
    print("  A real R peak is 200+ counts above the baseline.")
    print()

# Plot. Each row is one sample; the marker's column is its value.
for i, v in enumerate(samples[::EVERY]):
    col = 0 if span == 0 else int((v - lo) / span * (WIDTH - 1))
    t = i * EVERY / FS
    bar = " " * col + "#"
    # a time marker every half second, so beats can be counted by eye
    tick = f"{t:5.2f}s" if (i * EVERY) % (FS // 2) == 0 else "      "
    print(f"{tick} |{bar}")

print()
print(f"left edge = {lo}   right edge = {hi}")
