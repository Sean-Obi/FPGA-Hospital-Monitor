`default_nettype none

// ============================================================
// MODULE: top
//
// The top of the design. Everything else hangs off this.
//
// Three vital signs, one serial line:
//
//   ECG / heart rate   AD8232  -> XADC (VAUX4)  -> heart_pipeline
//   skin temperature   TMP36   -> XADC (VAUX12) -> temp_convert
//   blood oxygen       MAX30102 -> I2C          -> spo2_calc
//
//                     all three -> telemetry_uart -> laptop
//
// Port names match the Digilent Cmod A7 master .xdc, so the
// constraint file only has to uncomment lines, not rename them.
//
// ------------------------------------------------------------
// PINS
// ------------------------------------------------------------
//
//   sysclk        L17    12 MHz crystal
//   led[0]        A17    LD1, flashes on each beat
//   led[1]        C16    LD2, slow "alive" blink
//   btn[0]        A18    BTN0, reset
//   xa_p[0]       G3     DIP 15, ECG from the AD8232 OUTPUT
//   xa_p[1]       H2     DIP 16, temperature from the TMP36 (buffered)
//   xa_n[0..1]    G2,J2  grounded on the board
//   uart_rxd_out  J18    serial to the laptop via the USB chip
//   buzzer        M3     DIP 1, passive buzzer through a resistor
//   scl           L3     DIP 2, I2C clock to the MAX30102
//   sda           A16    DIP 3, I2C data  to the MAX30102
//
// ------------------------------------------------------------
// WHAT GOES OUT OVER THE SERIAL LINE
// ------------------------------------------------------------
//
//     S2048   one raw ECG sample, 500 times a second
//     B0075   heart rate, whenever a new one is worked out
//     T0345   skin temperature, 34.5 C, twice a second
//     O0098   SpO2 percent, every 2.6 s. 0 = no finger,
//             999 = the MAX30102 is not answering
//
// at 115200 baud. scripts/ecg_monitor.py --port COMx reads them.
// ============================================================

module top #(

    // 12 MHz / 115200 baud = 104 clock cycles per serial bit.
    parameter integer CLKS_PER_BIT = 104,

    // 12 MHz / 24000 = 500 samples per second.
    parameter integer SAMPLE_DIVIDE = 24000,

    // How far above the baseline counts as an R peak, in ADC
    // counts (0.81 mV each at the pin).
    //
    // 70 was picked against a synthetic waveform. On the first
    // real recording it caught about every other beat, so it is
    // probably high. Capture a few seconds with the pads on and
    // measure the R height before changing it - see the README.
    parameter signed [15:0] THRESHOLD = 16'sd70,

    // Which bit of the free-running counter drives the alive LED.
    // Bit 22 at 12 MHz flips every 0.35 s.
    parameter integer ALIVE_BIT = 22,

    // ---- temperature ----
    // Average 2^8 = 256 readings at 500 Hz: a new value every 0.5 s.
    parameter integer TEMP_AVG_LOG2 = 8,

    // ---- SpO2 ----
    parameter integer I2C_SCL_HZ          = 100_000,
    parameter integer MAX_RESET_WAIT_CLKS = 12_000_000 / 100,   // 10 ms
    parameter integer MAX_POLL_CLKS       = 12_000_000 / 500,   // 2 ms
    parameter integer MAX_RETRY_CLKS      = 12_000_000,         // 1 s
    parameter integer SPO2_BLOCK_LOG2     = 8,                  // 256 samples = 2.56 s
    parameter integer SPO2_FINGER_MIN     = 30000,              // IR DC below this = no finger

    // How often to say "sensor missing" when it is: once a second.
    parameter integer STATUS_TICKS = 500

)(
    input  wire       sysclk,
    input  wire [0:0] btn,
    output wire [1:0] led,

    // Analog inputs. [0] = ECG, [1] = temperature.
    input  wire [1:0] xa_p,
    input  wire [1:0] xa_n,

    output wire       uart_rxd_out,
    output wire       buzzer,

    // I2C to the MAX30102. Open-drain: driven low or let go.
    inout  wire       scl,
    inout  wire       sda
);


// ------------------------------------------------------------
// RESET
// ------------------------------------------------------------
//
// Power-on: hold reset for the first 128 clocks so every block
// starts from a known state. Button: two flip-flops first, so a
// press that lands on a clock edge cannot leave anything
// half-decided (metastability).

reg [7:0] por_counter = 8'd0;

always @(posedge sysclk) begin
    if (!por_counter[7])
        por_counter <= por_counter + 1'b1;
end

wire por_active = ~por_counter[7];

reg [1:0] btn_sync = 2'b00;

always @(posedge sysclk)
    btn_sync <= {btn_sync[0], btn[0]};

// Cmod A7 buttons read HIGH when pressed.
wire reset = por_active | btn_sync[1];


// ------------------------------------------------------------
// 500 Hz SAMPLE TIMING
// ------------------------------------------------------------

wire tick;

sample_tick #(
    .DIVIDE (SAMPLE_DIVIDE)
) u_tick (
    .clk   (sysclk),
    .reset (reset),
    .tick  (tick)
);


// ------------------------------------------------------------
// THE TWO ANALOG CHANNELS
// ------------------------------------------------------------
//
// The XADC converts both continuously; this block hands over
// the most recent of each once per tick.

wire [11:0] sample;
wire [11:0] temp_code;
wire        sample_valid;

xadc_reader u_adc (
    .clk          (sysclk),
    .reset        (reset),
    .sample_tick  (tick),
    .vauxp_ecg    (xa_p[0]),
    .vauxn_ecg    (xa_n[0]),
    .vauxp_temp   (xa_p[1]),
    .vauxn_temp   (xa_n[1]),
    .sample       (sample),
    .temp_sample  (temp_code),
    .sample_valid (sample_valid)
);


// ------------------------------------------------------------
// ECG: filter -> baseline -> beats -> BPM
// ------------------------------------------------------------

wire       beat;
wire [7:0] bpm;
wire       bpm_valid;

// INCLUDE_BPM_UART is 0: telemetry_uart drives the serial line.

heart_pipeline #(
    .CLKS_PER_BIT     (CLKS_PER_BIT),
    .THRESHOLD        (THRESHOLD),
    .INCLUDE_BPM_UART (0)
) u_pipeline (
    .clk          (sysclk),
    .reset        (reset),
    .sample       (sample),
    .sample_valid (sample_valid),
    .beat         (beat),
    .bpm          (bpm),
    .bpm_valid    (bpm_valid),
    .tx           ()
);


// ------------------------------------------------------------
// TEMPERATURE
// ------------------------------------------------------------

wire [13:0] temp_tenths;
wire        temp_valid;

temp_convert #(
    .AVG_LOG2 (TEMP_AVG_LOG2)
) u_temp (
    .clk         (sysclk),
    .reset       (reset),
    .code        (temp_code),
    .code_valid  (sample_valid),
    .temp_tenths (temp_tenths),
    .temp_valid  (temp_valid)
);


// ------------------------------------------------------------
// BLOOD OXYGEN
// ------------------------------------------------------------

wire        scl_oe, sda_oe;
wire [17:0] ppg_red, ppg_ir;
wire        ppg_valid;
wire        sensor_ok;

// Open-drain pins: pull low, or release and let the pull-up win.
assign scl = scl_oe ? 1'b0 : 1'bz;
assign sda = sda_oe ? 1'b0 : 1'bz;

max30102_driver #(
    .CLK_HZ          (12_000_000),
    .SCL_HZ          (I2C_SCL_HZ),
    .RESET_WAIT_CLKS (MAX_RESET_WAIT_CLKS),
    .POLL_CLKS       (MAX_POLL_CLKS),
    .RETRY_CLKS      (MAX_RETRY_CLKS)
) u_max (
    .clk          (sysclk),
    .reset        (reset),
    .red          (ppg_red),
    .ir           (ppg_ir),
    .sample_valid (ppg_valid),
    .sensor_ok    (sensor_ok),
    .scl_oe       (scl_oe),
    .sda_oe       (sda_oe),
    .scl_in       (scl),
    .sda_in       (sda)
);

wire [7:0] spo2;
wire       spo2_valid;
wire       finger;

spo2_calc #(
    .BLOCK_LOG2 (SPO2_BLOCK_LOG2),
    .FINGER_MIN (SPO2_FINGER_MIN)
) u_spo2 (
    .clk          (sysclk),
    .reset        (reset),
    .red          (ppg_red),
    .ir           (ppg_ir),
    .sample_valid (ppg_valid),
    .spo2         (spo2),
    .spo2_valid   (spo2_valid),
    .finger       (finger),
    .dc_red_out   (),
    .dc_ir_out    (),
    .ac_red_out   (),
    .ac_ir_out    (),
    .r100_out     ()
);

// While the sensor is missing, say so once a second instead of
// going quiet - a silent display and a broken one look the same.
reg [15:0] status_count = 16'd0;
reg        status_tick  = 1'b0;

always @(posedge sysclk) begin
    status_tick <= 1'b0;
    if (reset)
        status_count <= 16'd0;
    else if (tick) begin
        if (status_count == STATUS_TICKS - 1) begin
            status_count <= 16'd0;
            status_tick  <= 1'b1;
        end
        else
            status_count <= status_count + 1'b1;
    end
end

wire       spo2_report_valid = sensor_ok ? spo2_valid : status_tick;
wire [9:0] spo2_report       = sensor_ok ? {2'b00, spo2} : 10'd999;


// ------------------------------------------------------------
// SEND IT ALL TO THE LAPTOP
// ------------------------------------------------------------

wire [15:0] dropped_samples;

telemetry_uart #(
    .CLKS_PER_BIT (CLKS_PER_BIT)
) u_telemetry (
    .clk             (sysclk),
    .reset           (reset),
    .sample          (sample),
    .sample_valid    (sample_valid),
    .bpm             (bpm),
    .bpm_valid       (bpm_valid),
    .temp_tenths     (temp_tenths),
    .temp_valid      (temp_valid),
    .spo2            (spo2_report),
    .spo2_valid      (spo2_report_valid),
    .tx              (uart_rxd_out),
    .dropped_samples (dropped_samples)
);


// ------------------------------------------------------------
// BEEP AND FLASH ON EACH BEAT
// ------------------------------------------------------------

buzzer #(
    .CLOCK_HZ   (12_000_000),
    .TONE_HZ    (2000),
    .BEEP_TICKS (50)          // 50 ticks x 2 ms = 100 ms beep
) u_buzzer (
    .clk         (sysclk),
    .reset       (reset),
    .sample_tick (tick),
    .beat        (beat),
    .buzzer_out  (buzzer)
);

led_flash #(
    .FLASH_TICKS (50)         // same 100 ms as the beep
) u_led (
    .clk         (sysclk),
    .reset       (reset),
    .sample_tick (tick),
    .beat        (beat),
    .led         (led[0])
);


// ------------------------------------------------------------
// "IS IT EVEN RUNNING?" BLINK
// ------------------------------------------------------------
//
// A free-running counter driving the second LED at about 1.4 Hz.
// It depends on nothing except the clock. If this does not
// blink, the bitstream is not loaded, the clock is not arriving,
// or the pin constraints are wrong - fix that before anything.

reg [23:0] alive_counter = 24'd0;

always @(posedge sysclk)
    alive_counter <= alive_counter + 1'b1;

assign led[1] = alive_counter[ALIVE_BIT];


endmodule

`default_nettype wire
