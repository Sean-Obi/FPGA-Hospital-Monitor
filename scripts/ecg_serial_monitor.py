#!/usr/bin/env python3
"""
Live ECG monitor - reads the FPGA over the serial cable and plots it.

The FPGA sends four kinds of line at 115200 baud, all six characters:

    S2048       one raw ECG sample, 500 times a second
    B0075       the heart rate, whenever a new one is worked out
    T0345       skin temperature in tenths of a degree C (34.5)
    O0098       blood oxygen percent. 0 = no finger on the sensor,
                999 = the MAX30102 is not responding

This script reads them all, draws the waveform, and shows the numbers.
The TelemetryReader class here is also what ecg_monitor.py uses for
its live mode.

--------------------------------------------------------------------
WHY THIS IS A SEPARATE SCRIPT FROM ecg_monitor.py
--------------------------------------------------------------------

ecg_monitor.py plays back a PhysioNet recording. It is given the
whole signal up front and walks through it on a timer, so it knows
how long the recording is and can scale the axes from all of it
before drawing anything.

Live data has none of that. Samples turn up when the FPGA sends
them, there is no "end", and the scaling has to come from what has
arrived so far. That is a different shape of program, so it is a
different file. The PhysioNet player is still useful for figures
and for testing without hardware.

--------------------------------------------------------------------
USAGE
--------------------------------------------------------------------

    # what serial ports exist?
    python ecg_serial_monitor.py --list-ports

    # just print what is arriving - use this FIRST, before the GUI
    python ecg_serial_monitor.py --port COM3 --dump

    # the actual monitor
    python ecg_serial_monitor.py --port COM3

    # no hardware? fake a heart
    python ecg_serial_monitor.py --simulate

--------------------------------------------------------------------
IF NOTHING APPEARS
--------------------------------------------------------------------

Run with --dump first. It prints raw bytes and needs no GUI, so it
separates "the FPGA is not sending" from "the plot is not drawing".

  * nothing at all      -> wrong port, or the design is not running.
                           Check the alive LED (led[1]) is blinking.
  * garbage characters  -> baud rate mismatch. Both ends must be
                           115200. On the FPGA that is
                           CLKS_PER_BIT = 104 in top.v.
  * "Access is denied"  -> something else already has the port open.
                           Close PuTTY / the Arduino serial monitor.
"""

import argparse
import math
import sys
import threading
import time
from collections import deque

# --------------------------------------------------------------------
# SETTINGS
# --------------------------------------------------------------------

DEFAULT_BAUD = 115200       # must match CLKS_PER_BIT in top.v
SAMPLE_RATE_HZ = 500        # must match sample_tick.v
WINDOW_SECONDS = 5          # how much history the plot shows
ADC_MAX = 4095              # 12-bit XADC

WINDOW_SAMPLES = WINDOW_SECONDS * SAMPLE_RATE_HZ
REDRAW_HZ = 30              # plot refresh; the eye cannot use more


# --------------------------------------------------------------------
# READING THE SERIAL LINE
# --------------------------------------------------------------------

class TelemetryReader:
    """
    Reads the FPGA in a background thread.

    A background thread matters. Reading a serial port blocks until
    data arrives, and if that happened on the GUI thread the whole
    window would freeze between samples.

    The thread only ever appends to `samples` and `beats`; the GUI
    only ever reads them. A lock guards the swap so the GUI never
    sees a half-written list.
    """

    def __init__(self, port, baud=DEFAULT_BAUD, simulate=False):
        self.port = port
        self.baud = baud
        self.simulate = simulate

        self._lock = threading.Lock()
        self._pending_samples = []
        self._pending_beats = 0

        self.latest_bpm = 0
        self.latest_temp_tenths = None    # None until the first T line
        self.latest_spo2 = None           # None until the first O line
        self.total_samples = 0
        self.bad_lines = 0
        self.connected = False
        self.error = None

        self._stop = threading.Event()
        self._thread = None

    # ----------------------------------------------------------------

    def start(self):
        target = self._run_simulated if self.simulate else self._run_serial
        self._thread = threading.Thread(target=target, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2.0)

    def drain(self):
        """Hand everything received since last time to the caller."""
        with self._lock:
            samples = self._pending_samples
            beats = self._pending_beats
            self._pending_samples = []
            self._pending_beats = 0
        return samples, beats

    # ----------------------------------------------------------------

    def _handle_line(self, line):
        """
        Turn one received line into either a sample or a heart rate.

        Anything unrecognised is counted and thrown away rather than
        crashing the reader. A garbled byte on startup is normal -
        the first line is often partial, because the port opens
        mid-message.
        """
        line = line.strip()
        if not line:
            return

        tag, digits = line[0], line[1:]

        if not digits.isdigit():
            self.bad_lines += 1
            return

        value = int(digits)

        if tag == 'S':
            with self._lock:
                self._pending_samples.append(value)
            self.total_samples += 1

        elif tag == 'B':
            self.latest_bpm = value
            with self._lock:
                self._pending_beats += 1

        elif tag == 'T':
            self.latest_temp_tenths = value

        elif tag == 'O':
            self.latest_spo2 = value

        else:
            self.bad_lines += 1

    # ----------------------------------------------------------------

    def spo2_text(self):
        """SpO2 as the display should show it."""
        if self.latest_spo2 is None:
            return "--"
        if self.latest_spo2 == 999:
            return "ERR"
        if self.latest_spo2 == 0:
            return "--"
        return str(self.latest_spo2)

    def temp_text(self):
        """Temperature as the display should show it."""
        if self.latest_temp_tenths is None:
            return "--"
        return f"{self.latest_temp_tenths / 10:.1f}"

    # ----------------------------------------------------------------

    def _run_serial(self):
        try:
            import serial
        except ImportError:
            self.error = ("pyserial is not installed.\n"
                          "    pip install pyserial")
            return

        try:
            # A short timeout means the loop wakes up regularly even
            # when nothing is arriving, so Ctrl-C and window-close
            # still work.
            with serial.Serial(self.port, self.baud, timeout=0.1) as ser:
                self.connected = True

                # The port may open partway through a message, so
                # throw away whatever is buffered and the first
                # line, which is probably a fragment.
                ser.reset_input_buffer()
                ser.readline()

                while not self._stop.is_set():
                    raw = ser.readline()
                    if raw:
                        self._handle_line(raw.decode('ascii', errors='replace'))

        except Exception as exc:                      # noqa: BLE001
            self.error = f"{type(exc).__name__}: {exc}"
            self.connected = False

    # ----------------------------------------------------------------

    def _run_simulated(self):
        """
        A fake heart, for when the board is not to hand.

        Produces the same message stream the FPGA would, so the rest
        of this script cannot tell the difference.
        """
        self.connected = True
        bpm = 72
        samples_per_beat = int(SAMPLE_RATE_HZ * 60 / bpm)
        phase = 0
        tick = 0
        next_due = time.time()

        while not self._stop.is_set():
            value = 2048 + int(700 * _fake_ecg(phase / samples_per_beat))
            self._handle_line(f"S{value:04d}")

            if phase == 0:
                self._handle_line(f"B{bpm:04d}")

            # Temperature twice a second, SpO2 every 2.5 s, like the FPGA.
            if tick % 250 == 0:
                self._handle_line(f"T{345 + (tick // 250) % 3:04d}")
            if tick % 1250 == 0:
                self._handle_line(f"O{97 + (tick // 1250) % 2:04d}")

            phase = (phase + 1) % samples_per_beat
            tick += 1

            next_due += 1.0 / SAMPLE_RATE_HZ
            delay = next_due - time.time()
            if delay > 0:
                time.sleep(delay)
            else:
                next_due = time.time()


def _fake_ecg(t):
    """One heartbeat, t running 0 to 1. Rough, but the right shape."""
    if t < 0.10:
        return 0.08 * math.sin(math.pi * t / 0.10)      # P wave
    if t < 0.16:
        return 0.0
    if t < 0.18:
        return -0.15                                    # Q
    if t < 0.21:
        return 1.0                                      # R spike
    if t < 0.24:
        return -0.25                                    # S
    if t < 0.32:
        return 0.0
    if t < 0.50:
        return 0.22 * math.sin(math.pi * (t - 0.32) / 0.18)   # T wave
    return 0.0


# --------------------------------------------------------------------
# DUMP MODE - no GUI, just show what is arriving
# --------------------------------------------------------------------

def run_dump(reader):
    """
    Print what the FPGA is sending. This is the first thing to run
    on a new board: if nothing shows here, the problem is upstream
    of anything to do with plotting.
    """
    reader.start()
    print()
    print("Listening. Ctrl-C to stop.")
    print()

    last_report = time.time()
    last_count = 0

    try:
        while True:
            time.sleep(1.0)

            if reader.error:
                print(f"  ERROR: {reader.error}")
                return 1

            now = time.time()
            rate = (reader.total_samples - last_count) / (now - last_report)
            last_report, last_count = now, reader.total_samples

            print(f"  {reader.total_samples:>7} samples   "
                  f"{rate:>6.1f} Hz   "
                  f"BPM {reader.latest_bpm:>3}   "
                  f"SpO2 {reader.spo2_text():>3}   "
                  f"temp {reader.temp_text():>5} C   "
                  f"bad lines {reader.bad_lines}")

            if rate < 1 and reader.total_samples == 0:
                print("      (nothing arriving - wrong port, or the "
                      "design is not running)")
            elif reader.bad_lines > reader.total_samples:
                print("      (mostly garbage - check the baud rate "
                      "is 115200 at both ends)")

    except KeyboardInterrupt:
        print()
        return 0
    finally:
        reader.stop()


# --------------------------------------------------------------------
# THE MONITOR WINDOW
# --------------------------------------------------------------------

def run_gui(reader):
    try:
        from PyQt6 import QtCore, QtWidgets
        import pyqtgraph as pg
    except ImportError as exc:
        print(f"\nMissing GUI package: {exc}")
        print("    pip install PyQt6 pyqtgraph\n")
        print("Or use --dump, which needs neither.\n")
        return 1

    pg.setConfigOptions(antialias=True)

    app = QtWidgets.QApplication(sys.argv)
    window = QtWidgets.QMainWindow()
    window.setWindowTitle("FPGA ECG Monitor")
    window.resize(1000, 480)

    central = QtWidgets.QWidget()
    layout = QtWidgets.QHBoxLayout(central)
    window.setCentralWidget(central)

    # ---- the trace ----
    plot = pg.PlotWidget(background='#000000')
    plot.showGrid(x=True, y=True, alpha=0.20)
    plot.setLabel('left', 'ADC code')
    plot.setLabel('bottom', 'seconds')
    plot.setYRange(0, ADC_MAX)
    curve = plot.plot(pen=pg.mkPen('#00ff5f', width=1.6))
    layout.addWidget(plot, stretch=4)

    # ---- the numbers down the side ----
    side = QtWidgets.QVBoxLayout()
    layout.addLayout(side, stretch=1)

    bpm_caption = QtWidgets.QLabel("HR  bpm")
    bpm_caption.setStyleSheet("color:#00ff5f; font-size:15px;")
    side.addWidget(bpm_caption)

    bpm_value = QtWidgets.QLabel("--")
    bpm_value.setStyleSheet("color:#00ff5f; font-size:86px; font-weight:500;")
    side.addWidget(bpm_value)

    beat_dot = QtWidgets.QLabel("●")
    beat_dot.setStyleSheet("color:#003311; font-size:44px;")
    side.addWidget(beat_dot)

    spo2_caption = QtWidgets.QLabel("SpO₂  %")
    spo2_caption.setStyleSheet("color:#00d9ff; font-size:15px;")
    side.addWidget(spo2_caption)

    spo2_value = QtWidgets.QLabel("--")
    spo2_value.setStyleSheet("color:#00d9ff; font-size:54px; font-weight:500;")
    side.addWidget(spo2_value)

    temp_caption = QtWidgets.QLabel("TEMP  °C (skin)")
    temp_caption.setStyleSheet("color:#ffd84a; font-size:15px;")
    side.addWidget(temp_caption)

    temp_value = QtWidgets.QLabel("--")
    temp_value.setStyleSheet("color:#ffd84a; font-size:54px; font-weight:500;")
    side.addWidget(temp_value)

    side.addStretch(1)

    status = QtWidgets.QLabel("connecting…")
    status.setStyleSheet("color:#7f7f7f; font-size:12px;")
    status.setWordWrap(True)
    side.addWidget(status)

    # ---- state ----
    waveform = deque([0] * WINDOW_SAMPLES, maxlen=WINDOW_SAMPLES)
    x_axis = [i / SAMPLE_RATE_HZ for i in range(WINDOW_SAMPLES)]

    state = {
        'last_count': 0,
        'last_time': time.time(),
        'rate': 0.0,
        'flash_until': 0.0,
        'seen_any': False,
    }

    def refresh():
        samples, beats = reader.drain()

        if samples:
            waveform.extend(samples)
            state['seen_any'] = True
            curve.setData(x_axis, list(waveform))

        # Flash the dot on a beat, and hold it lit briefly so it is
        # actually visible - a single frame would not be.
        now = time.time()
        if beats:
            state['flash_until'] = now + 0.12
            bpm_value.setText(str(reader.latest_bpm))

        lit = now < state['flash_until']
        beat_dot.setStyleSheet(
            f"color:{'#00ff5f' if lit else '#003311'}; font-size:44px;")

        spo2_value.setText(reader.spo2_text())
        temp_value.setText(reader.temp_text())

        # Measured sample rate, once a second. Worth watching: if it
        # is not close to 500 Hz, samples are being lost somewhere.
        if now - state['last_time'] >= 1.0:
            state['rate'] = ((reader.total_samples - state['last_count'])
                             / (now - state['last_time']))
            state['last_count'] = reader.total_samples
            state['last_time'] = now

        if reader.error:
            status.setText(f"ERROR\n{reader.error}")
            status.setStyleSheet("color:#ff5f5f; font-size:12px;")
        elif not state['seen_any']:
            status.setText("connected, but nothing arriving yet.\n"
                           "Is led[1] blinking on the board?")
        else:
            status.setText(f"{state['rate']:.0f} Hz  "
                           f"(expect {SAMPLE_RATE_HZ})\n"
                           f"{reader.total_samples} samples\n"
                           f"{reader.bad_lines} bad lines")

    timer = QtCore.QTimer()
    timer.timeout.connect(refresh)
    timer.start(int(1000 / REDRAW_HZ))

    reader.start()
    window.show()

    try:
        return app.exec()
    finally:
        reader.stop()


# --------------------------------------------------------------------

def list_ports():
    try:
        from serial.tools import list_ports as lp
    except ImportError:
        print("\npyserial is not installed.\n    pip install pyserial\n")
        return 1

    ports = list(lp.comports())
    print()
    if not ports:
        print("No serial ports found.")
        print("Is the board plugged in, and did Vivado install the")
        print("cable drivers?")
    else:
        print("Serial ports:")
        for p in ports:
            print(f"  {p.device:<12} {p.description}")
        print()
        print("The Cmod A7 usually shows up as a USB Serial Port.")
    print()
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Live ECG monitor for the FPGA heart monitor.")
    parser.add_argument('--port',
                        help="serial port, e.g. COM3 or /dev/ttyUSB0")
    parser.add_argument('--baud', type=int, default=DEFAULT_BAUD,
                        help=f"baud rate (default {DEFAULT_BAUD})")
    parser.add_argument('--list-ports', action='store_true',
                        help="show available serial ports and exit")
    parser.add_argument('--dump', action='store_true',
                        help="print arriving data instead of plotting")
    parser.add_argument('--simulate', action='store_true',
                        help="fake a heartbeat, no hardware needed")
    args = parser.parse_args()

    if args.list_ports:
        return list_ports()

    if not args.port and not args.simulate:
        parser.error("give --port, or --simulate to run without hardware")

    reader = TelemetryReader(args.port, args.baud, simulate=args.simulate)

    return run_dump(reader) if args.dump else run_gui(reader)


if __name__ == '__main__':
    sys.exit(main())
