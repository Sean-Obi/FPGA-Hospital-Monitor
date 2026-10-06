"""
FPGA ECG Monitor - Hospital Style Front End

Two ways to run it:

LIVE MODE  (the real thing)

    python scripts/ecg_monitor.py --port COM4

  Everything on screen comes from the FPGA over the serial cable:
    - ECG waveform      S#### lines, 500 a second, from the AD8232
    - heart rate        B#### lines, worked out on the FPGA
    - SpO2              O#### lines, from the MAX30102 via the FPGA
    - skin temperature  T#### lines, from the TMP36 via the FPGA

  No hardware to hand?  --simulate  fakes the serial stream.

PHYSIONET TEST MODE  (no --port)

    python scripts/ecg_monitor.py --record 100

  Plays back a PhysioNet recording with its annotated beats, and
  shows DEMO values for SpO2 and temperature. Useful for figures and
  for checking the display without the board.

Learning project only - not a clinical medical device.
"""

import sys
import argparse
from fractions import Fraction

import numpy as np

from PyQt6 import QtCore, QtWidgets
import pyqtgraph as pg

# The serial reader lives in ecg_serial_monitor.py, in this folder.
from ecg_serial_monitor import TelemetryReader, DEFAULT_BAUD


# ============================================================
# PROJECT SETTINGS
# ============================================================

TARGET_FS = 500

DISPLAY_SECONDS = 6

UPDATE_MS = 20

# Live mode: one ADC count is 0.8105 mV at the Cmod A7's analog pin
# (3.32 V full scale / 4096). Measured on the board: 4051 counts for
# the 3.28 V rail. The AD8232 idles near mid-rail, about 2030 counts;
# the plot shows the swing around that, in mV at the AD8232 output.
MV_PER_COUNT = 0.8105

# How often the live plot re-fits its vertical scale, in seconds.
# Too often and the axis jumps about; too rarely and a big R peak
# goes off the top for a while.
LIVE_RESCALE_SECONDS = 2.0


# ============================================================
# PHYSIONET BEAT SYMBOLS
# ============================================================

BEAT_SYMBOLS = {
    "N",
    "L",
    "R",
    "A",
    "a",
    "J",
    "S",
    "V",
    "F",
    "e",
    "j",
    "E",
    "/",
    "f",
    "Q",
}


# ============================================================
# LOAD PHYSIONET ECG
# ============================================================

def load_physionet_record(
    database,
    record_name,
    lead_number,
    duration_seconds,
):

    # Imported here, not at the top, so live mode does not need
    # wfdb and scipy installed.
    import wfdb
    from scipy.signal import resample_poly

    print()
    print("----------------------------------------")
    print("LOADING PHYSIONET ECG")
    print("----------------------------------------")
    print()

    print(f"Database : {database}")
    print(f"Record   : {record_name}")

    print()
    print("Downloading/loading ECG...")
    print()

    record = wfdb.rdrecord(
        record_name,
        pn_dir=database
    )

    annotation = wfdb.rdann(
        record_name,
        "atr",
        pn_dir=database
    )

    original_fs = float(record.fs)

    print(
        f"Original sample rate : "
        f"{original_fs:.1f} Hz"
    )

    if lead_number >= record.p_signal.shape[1]:

        raise ValueError(
            f"Lead {lead_number} does not exist. "
            f"This record has "
            f"{record.p_signal.shape[1]} lead(s)."
        )

    ecg = record.p_signal[
        :,
        lead_number
    ]

    lead_name = record.sig_name[
        lead_number
    ]

    print(
        f"ECG lead             : "
        f"{lead_name}"
    )

    beat_samples = np.array(
        [
            sample
            for sample, symbol
            in zip(
                annotation.sample,
                annotation.symbol
            )
            if symbol in BEAT_SYMBOLS
        ],
        dtype=np.int64
    )


    # --------------------------------------------------------
    # RESAMPLE TO 500 HZ
    # --------------------------------------------------------

    ratio = Fraction(
        TARGET_FS / original_fs
    ).limit_denominator(1000)

    up = ratio.numerator
    down = ratio.denominator

    ecg_500 = resample_poly(
        ecg,
        up,
        down
    )

    beat_samples_500 = np.rint(
        beat_samples
        * TARGET_FS
        / original_fs
    ).astype(np.int64)


    # --------------------------------------------------------
    # LIMIT TEST DURATION
    # --------------------------------------------------------

    if duration_seconds > 0:

        maximum_samples = int(
            duration_seconds
            * TARGET_FS
        )

        ecg_500 = ecg_500[
            :maximum_samples
        ]

        beat_samples_500 = (
            beat_samples_500[
                beat_samples_500
                < maximum_samples
            ]
        )


    print(
        f"Project sample rate  : "
        f"{TARGET_FS} Hz"
    )

    print(
        f"Loaded ECG samples   : "
        f"{len(ecg_500)}"
    )

    print(
        f"Annotated beats      : "
        f"{len(beat_samples_500)}"
    )

    print()
    print("PhysioNet ECG ready.")
    print()

    return (
        ecg_500,
        beat_samples_500,
        lead_name,
        original_fs,
    )


# ============================================================
# HELPER: CREATE VITAL SIGN DISPLAY
# ============================================================

def create_vital_widget(
    title,
    value,
    unit,
    color,
):

    widget = QtWidgets.QWidget()

    layout = QtWidgets.QVBoxLayout(
        widget
    )

    layout.setContentsMargins(
        5,
        5,
        5,
        5
    )

    title_label = QtWidgets.QLabel(
        title
    )

    title_label.setAlignment(
        QtCore.Qt.AlignmentFlag.AlignCenter
    )

    title_label.setStyleSheet(
        f"""
        color: {color};
        font-size: 18px;
        font-weight: bold;
        """
    )

    value_label = QtWidgets.QLabel(
        value
    )

    value_label.setAlignment(
        QtCore.Qt.AlignmentFlag.AlignCenter
    )

    value_label.setStyleSheet(
        f"""
        color: {color};
        font-size: 64px;
        font-weight: bold;
        """
    )

    unit_label = QtWidgets.QLabel(
        unit
    )

    unit_label.setAlignment(
        QtCore.Qt.AlignmentFlag.AlignCenter
    )

    unit_label.setStyleSheet(
        f"""
        color: {color};
        font-size: 18px;
        """
    )

    layout.addWidget(
        title_label
    )

    layout.addWidget(
        value_label
    )

    layout.addWidget(
        unit_label
    )

    return (
        widget,
        value_label,
    )


# ============================================================
# ECG MONITOR WINDOW
# ============================================================

class ECGMonitor(
    QtWidgets.QMainWindow
):

    def __init__(
        self,
        ecg,
        beat_samples,
        lead_name,
        demo_spo2,
        demo_temp,
        reader=None,
    ):

        super().__init__()

        # LIVE MODE: a TelemetryReader supplies everything.
        # PHYSIONET MODE: reader is None and ecg holds the recording.
        self.reader = reader
        self.live = reader is not None

        self.ecg = ecg

        self.beat_samples = (
            beat_samples
        )

        self.lead_name = (
            lead_name
        )

        self.demo_spo2 = (
            demo_spo2
        )

        self.demo_temp = (
            demo_temp
        )

        self.position = 0

        self.previous_position = 0

        self.window_samples = (
            DISPLAY_SECONDS
            * TARGET_FS
        )

        self.samples_per_update = max(
            1,
            int(
                TARGET_FS
                * UPDATE_MS
                / 1000
            )
        )

        self.last_beat_sample = None

        self.next_beat_index = 0


        # ----------------------------------------------------
        # WINDOW
        # ----------------------------------------------------

        self.setWindowTitle(
            "FPGA Hospital ECG Monitor"
        )

        self.resize(
            1500,
            800
        )

        central_widget = (
            QtWidgets.QWidget()
        )

        self.setCentralWidget(
            central_widget
        )

        main_layout = (
            QtWidgets.QHBoxLayout(
                central_widget
            )
        )


        # ====================================================
        # LEFT SIDE: ECG
        # ====================================================

        left_panel = (
            QtWidgets.QWidget()
        )

        left_layout = (
            QtWidgets.QVBoxLayout(
                left_panel
            )
        )


        # ----------------------------------------------------
        # MONITOR TITLE
        # ----------------------------------------------------

        header = QtWidgets.QLabel(
            "FPGA ECG MONITOR"
        )

        header.setStyleSheet(
            """
            color: #cccccc;
            font-size: 24px;
            font-weight: bold;
            """
        )

        left_layout.addWidget(
            header
        )


        # ----------------------------------------------------
        # ECG GRAPH
        # ----------------------------------------------------

        self.plot = (
            pg.PlotWidget()
        )

        self.plot.setBackground(
            "#020502"
        )

        self.plot.showGrid(
            x=True,
            y=True,
            alpha=0.18
        )

        self.plot.setLabel(
            "left",
            "ECG",
            units="mV",
            color="#00ff55"
        )

        self.plot.setLabel(
            "bottom",
            "Time",
            units="s",
            color="#888888"
        )

        self.plot.setXRange(
            -DISPLAY_SECONDS,
            0,
            padding=0
        )

        self.curve = (
            self.plot.plot(
                pen=pg.mkPen(
                    color="#00ff55",
                    width=2
                )
            )
        )

        if self.live:

            # Nothing has arrived yet. Start with a range that fits
            # a typical AD8232 trace; it is re-fitted as data comes in.
            self.plot.setYRange(
                -300,
                600,
                padding=0
            )

            # The rolling window of samples, in mV.
            self.live_window = np.full(
                self.window_samples,
                np.nan
            )

            self.live_last_rescale = 0.0

        else:

            finite_ecg = self.ecg[
                np.isfinite(
                    self.ecg
                )
            ]

            low, high = np.percentile(
                finite_ecg,
                [1, 99]
            )

            amplitude = (
                high - low
            )

            if amplitude <= 0:
                amplitude = 1

            margin = (
                amplitude * 0.25
            )

            self.plot.setYRange(
                low - margin,
                high + margin,
                padding=0
            )

        left_layout.addWidget(
            self.plot
        )


        # ----------------------------------------------------
        # LEAD INFORMATION
        # ----------------------------------------------------

        lead_label = (
            QtWidgets.QLabel(
                f"Lead: {lead_name}"
                if not self.live else
                "Live: AD8232 -> Cmod A7 XADC -> UART   "
                "(mV at the AD8232 output, around its baseline)"
            )
        )

        lead_label.setStyleSheet(
            """
            color: #888888;
            font-size: 16px;
            """
        )

        left_layout.addWidget(
            lead_label
        )

        main_layout.addWidget(
            left_panel,
            stretch=5
        )


        # ====================================================
        # RIGHT SIDE: VITAL SIGNS
        # ====================================================

        right_panel = (
            QtWidgets.QFrame()
        )

        right_panel.setStyleSheet(
            """
            QFrame {
                background-color: #010301;
                border-left:
                    1px solid #333333;
            }
            """
        )

        right_layout = (
            QtWidgets.QVBoxLayout(
                right_panel
            )
        )


        # ----------------------------------------------------
        # HEART RATE
        # ----------------------------------------------------

        (
            hr_widget,
            self.hr_label,

        ) = create_vital_widget(

            "HR",
            "---",
            "BPM",
            "#00ff55",

        )

        right_layout.addWidget(
            hr_widget
        )


        # ----------------------------------------------------
        # SPO2
        # ----------------------------------------------------
        #
        # CURRENTLY A DEMO VALUE.
        #
        # Later this can come from a real
        # pulse-oximeter sensor.

        (
            spo2_widget,
            self.spo2_label,

        ) = create_vital_widget(

            "SpO₂",
            "--" if self.live else f"{demo_spo2:.0f}",
            "%",
            "#00d9ff",

        )

        right_layout.addWidget(
            spo2_widget
        )


        # ----------------------------------------------------
        # TEMPERATURE
        # ----------------------------------------------------
        #
        # CURRENTLY A DEMO VALUE.
        #
        # Later this can come from a real
        # temperature sensor.

        (
            temp_widget,
            self.temp_label,

        ) = create_vital_widget(

            "TEMP",
            "--" if self.live else f"{demo_temp:.1f}",
            "°C (skin)" if self.live else "°C",
            "#ffd84a",

        )

        right_layout.addWidget(
            temp_widget
        )


        # ----------------------------------------------------
        # HEARTBEAT INDICATOR
        # ----------------------------------------------------

        self.beat_indicator = (
            QtWidgets.QLabel(
                "♥"
            )
        )

        self.beat_indicator.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        self.beat_indicator.setStyleSheet(
            """
            color: #13351c;
            font-size: 75px;
            """
        )

        right_layout.addWidget(
            self.beat_indicator
        )


        # ----------------------------------------------------
        # STATUS
        # ----------------------------------------------------

        status_label = (
            QtWidgets.QLabel(
                "LIVE - connecting..."
                if self.live else
                "PHYSIONET TEST MODE\n"
                "SpO₂ + TEMP = DEMO"
            )
        )

        status_label.setAlignment(
            QtCore.Qt.AlignmentFlag.AlignCenter
        )

        status_label.setStyleSheet(
            """
            color: #777777;
            font-size: 12px;
            """
        )

        status_label.setWordWrap(True)

        right_layout.addWidget(
            status_label
        )

        self.status_label = status_label

        # For the live sample-rate readout.
        self.live_rate_count = 0
        self.live_rate_time = 0.0
        self.live_rate_hz = 0.0

        main_layout.addWidget(
            right_panel,
            stretch=1
        )


        # ----------------------------------------------------
        # GLOBAL BACKGROUND
        # ----------------------------------------------------

        central_widget.setStyleSheet(
            """
            background-color: #020402;
            """
        )


        # ----------------------------------------------------
        # TIMER
        # ----------------------------------------------------

        self.timer = (
            QtCore.QTimer(self)
        )

        self.timer.timeout.connect(
            self.update_monitor
        )

        self.timer.start(
            UPDATE_MS
        )


    # ========================================================
    # UPDATE DISPLAY
    # ========================================================

    def update_monitor(self):

        if self.live:
            self.update_live()
            return

        self.previous_position = (
            self.position
        )

        self.position += (
            self.samples_per_update
        )

        if (
            self.position
            >= len(self.ecg)
        ):

            self.position = (
                len(self.ecg)
            )

            self.timer.stop()


        start = max(
            0,
            self.position
            - self.window_samples
        )

        segment = self.ecg[
            start:self.position
        ]

        display_data = np.full(
            self.window_samples,
            np.nan
        )

        if len(segment) > 0:

            display_data[
                -len(segment):
            ] = segment


        x = np.linspace(
            -DISPLAY_SECONDS,
            0,
            self.window_samples,
            endpoint=False
        )

        self.curve.setData(
            x,
            display_data
        )


        # ----------------------------------------------------
        # CHECK FOR BEATS
        # ----------------------------------------------------

        while (
            self.next_beat_index
            < len(
                self.beat_samples
            )
        ):

            beat_sample = (
                self.beat_samples[
                    self.next_beat_index
                ]
            )

            if (
                beat_sample
                > self.position
            ):

                break

            if (
                beat_sample
                > self.previous_position
            ):

                self.handle_beat(
                    beat_sample
                )

            self.next_beat_index += 1


    # ========================================================
    # LIVE UPDATE - everything comes from the FPGA
    # ========================================================

    def update_live(self):

        import time

        reader = self.reader

        samples, beats = reader.drain()

        # ----------------------------------------------------
        # WAVEFORM
        # ----------------------------------------------------
        #
        # Convert ADC counts to mV around the running baseline, so
        # the trace sits on zero like a hospital monitor rather
        # than at 2030 counts.

        if samples:

            counts = np.asarray(
                samples,
                dtype=np.float64
            )

            n = min(
                len(counts),
                self.window_samples
            )

            self.live_window = np.roll(
                self.live_window,
                -n
            )

            self.live_window[-n:] = (
                counts[-n:] * MV_PER_COUNT
            )

            finite = self.live_window[
                np.isfinite(self.live_window)
            ]

            if len(finite) > 0:

                baseline = np.median(finite)

                display_data = (
                    self.live_window - baseline
                )

                x = np.linspace(
                    -DISPLAY_SECONDS,
                    0,
                    self.window_samples,
                    endpoint=False
                )

                self.curve.setData(
                    x,
                    display_data
                )

                # Re-fit the vertical scale now and then.
                now = time.time()

                if (
                    now - self.live_last_rescale
                    > LIVE_RESCALE_SECONDS
                ):

                    self.live_last_rescale = now

                    centred = finite - baseline

                    low, high = np.percentile(
                        centred,
                        [0.5, 99.9]
                    )

                    span = max(
                        high - low,
                        100.0          # never zoom in past 100 mV
                    )

                    self.plot.setYRange(
                        low - 0.25 * span,
                        high + 0.25 * span,
                        padding=0
                    )

        # ----------------------------------------------------
        # HEART RATE
        # ----------------------------------------------------
        #
        # The FPGA sends a B line each time it works out a new
        # rate, which is once per beat after the first two. So
        # a B line is a beat: flash the heart.

        if beats:

            self.hr_label.setText(
                str(reader.latest_bpm)
                if reader.latest_bpm > 0
                else "---"
            )

            self.flash_heart()

        # ----------------------------------------------------
        # SPO2 AND TEMPERATURE
        # ----------------------------------------------------

        self.spo2_label.setText(
            reader.spo2_text()
        )

        self.temp_label.setText(
            reader.temp_text()
        )

        # ----------------------------------------------------
        # STATUS LINE
        # ----------------------------------------------------

        now = time.time()

        if now - self.live_rate_time >= 1.0:

            if self.live_rate_time > 0:
                self.live_rate_hz = (
                    (reader.total_samples - self.live_rate_count)
                    / (now - self.live_rate_time)
                )

            self.live_rate_count = reader.total_samples
            self.live_rate_time = now

            if reader.error:
                self.status_label.setText(
                    f"ERROR\n{reader.error}"
                )

            elif reader.total_samples == 0:
                self.status_label.setText(
                    "LIVE - connected, nothing arriving yet.\n"
                    "Is LD2 blinking on the board?"
                )

            else:
                spo2_note = (
                    "MAX30102 not responding"
                    if reader.latest_spo2 == 999 else
                    "no finger on SpO₂ sensor"
                    if reader.latest_spo2 == 0 else
                    ""
                )

                self.status_label.setText(
                    f"LIVE  {reader.port or 'simulated'}\n"
                    f"{self.live_rate_hz:.0f} Hz  "
                    f"(expect {TARGET_FS})\n"
                    f"{reader.bad_lines} bad lines\n"
                    f"{spo2_note}"
                )


    # ========================================================
    # HEARTBEAT
    # ========================================================

    def handle_beat(
        self,
        beat_sample,
    ):

        # ----------------------------------------------------
        # BPM
        # ----------------------------------------------------

        if (
            self.last_beat_sample
            is not None
        ):

            interval = (
                beat_sample
                - self.last_beat_sample
            )

            if interval > 0:

                bpm = (
                    60
                    * TARGET_FS
                    / interval
                )

                self.hr_label.setText(
                    f"{bpm:.0f}"
                )


        self.last_beat_sample = (
            beat_sample
        )

        self.flash_heart()


    # ========================================================
    # HEART FLASH
    # ========================================================

    def flash_heart(self):

        self.beat_indicator.setStyleSheet(
            """
            color: #00ff55;
            font-size: 75px;
            """
        )

        QtCore.QTimer.singleShot(
            120,
            self.clear_beat_flash
        )


    # ========================================================
    # CLEAR HEART FLASH
    # ========================================================

    def clear_beat_flash(self):

        self.beat_indicator.setStyleSheet(
            """
            color: #13351c;
            font-size: 75px;
            """
        )


# ============================================================
# MAIN
# ============================================================

def main():

    parser = argparse.ArgumentParser(
        description=(
            "Hospital-style FPGA ECG monitor. "
            "Give --port for live data from the board, "
            "or nothing for PhysioNet playback."
        )
    )


    # --------------------------------------------------------
    # LIVE MODE
    # --------------------------------------------------------

    parser.add_argument(
        "--port",
        help="serial port of the Cmod A7, e.g. COM4 - turns on live mode",
    )

    parser.add_argument(
        "--baud",
        type=int,
        default=DEFAULT_BAUD,
        help=f"baud rate (default {DEFAULT_BAUD}, must match top.v)",
    )

    parser.add_argument(
        "--simulate",
        action="store_true",
        help="live mode with a fake serial stream, no hardware needed",
    )


    # --------------------------------------------------------
    # PHYSIONET MODE
    # --------------------------------------------------------

    parser.add_argument(
        "--database",
        default="mitdb",
    )

    parser.add_argument(
        "--record",
        default="100",
    )

    parser.add_argument(
        "--lead",
        type=int,
        default=0,
    )

    parser.add_argument(
        "--duration",
        type=float,
        default=60,
    )


    # --------------------------------------------------------
    # DEMO SPO2
    # --------------------------------------------------------

    parser.add_argument(
        "--spo2",
        type=float,
        default=98,
        help="Demo SpO2 value"
    )


    # --------------------------------------------------------
    # DEMO TEMPERATURE
    # --------------------------------------------------------

    parser.add_argument(
        "--temp",
        type=float,
        default=36.8,
        help="Demo temperature value"
    )

    args = parser.parse_args()


    # --------------------------------------------------------
    # LIVE MODE
    # --------------------------------------------------------

    if args.port or args.simulate:

        reader = TelemetryReader(
            args.port,
            args.baud,
            simulate=args.simulate,
        )

        reader.start()

        app = QtWidgets.QApplication(
            sys.argv
        )

        monitor = ECGMonitor(
            None,
            None,
            "live",
            0,
            0,
            reader=reader,
        )

        monitor.show()

        try:
            return_code = app.exec()
        finally:
            reader.stop()

        sys.exit(return_code)


    # --------------------------------------------------------
    # PHYSIONET MODE
    # --------------------------------------------------------

    try:

        (
            ecg,
            beat_samples,
            lead_name,
            original_fs,

        ) = load_physionet_record(

            args.database,
            args.record,
            args.lead,
            args.duration,

        )

    except Exception as error:

        print()
        print(
            "Could not load "
            "PhysioNet data."
        )
        print()
        print(error)
        print()

        sys.exit(1)


    app = QtWidgets.QApplication(
        sys.argv
    )

    monitor = ECGMonitor(
        ecg,
        beat_samples,
        lead_name,
        args.spo2,
        args.temp,
    )

    monitor.show()

    sys.exit(
        app.exec()
    )


if __name__ == "__main__":
    main()