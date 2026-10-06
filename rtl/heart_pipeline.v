`default_nettype none

// ------------------------------------------------------------
// MODULE: heart_pipeline
//
// PURPOSE:
//
// Wires the whole digital signal chain together.
//
//   raw 12-bit sample
//        |
//   ecg_filter        smooth out fast noise (8-point moving average)
//        |
//   baseline_remove   subtract the slow DC level, output signed
//        |
//   beat_detect       find upward threshold crossings -> beat pulse
//        |
//   bpm_calc          count samples between beats -> period
//        |
//   bpm_div           30000 / period -> beats per minute
//        |
//   bpm_uart          send the number as ASCII over the serial line
//
// Every connection below is written as .port(signal) rather than
// relying on the order the ports happen to be declared in.
// Positional connections compile happily even when they are wrong,
// which is how the filter ended up bypassed in an earlier version.
// ------------------------------------------------------------

module heart_pipeline #(

    // 12 MHz / 9600 baud = 1250 clocks per serial bit.
    parameter integer CLKS_PER_BIT = 1250,

    // How far above the baseline the signal has to rise before
    // it counts as an R peak. Tune this against the real ECG.
    parameter signed [15:0] THRESHOLD = 16'sd70,

    // Whether this module drives the serial line itself.
    //
    // 1 = yes, it contains its own bpm_uart and drives tx.
    //     This is how heart_pipeline_tb tests it.
    //
    // 0 = no. tx is left idle and the top level sends the data
    //     instead, using telemetry_uart, which can carry the
    //     raw samples as well as the heart rate.
    parameter integer INCLUDE_BPM_UART = 1

)(
    input  wire        clk,
    input  wire        reset,

    // One 12-bit ECG sample, valid when sample_valid is high.
    input  wire [11:0] sample,
    input  wire        sample_valid,

    // One-clock pulse per detected heartbeat.
    // Drives the buzzer and the LED at the top level.
    output wire        beat,

    output wire [7:0]  bpm,

    // One-clock pulse when bpm holds a newly calculated value.
    // The top level needs this to know when to send it.
    output wire        bpm_valid,

    output wire        tx
);


// ------------------------------------------------------------
// WIRES BETWEEN THE BLOCKS
// ------------------------------------------------------------

// ecg_filter -> baseline_remove
wire [11:0]        filt_sample;
wire               filt_valid;

// baseline_remove -> beat_detect  (signed: can go below the baseline)
wire signed [15:0] cent_sample;
wire               cent_valid;

// bpm_calc -> bpm_div
wire [9:0]         period;
wire               period_valid;



// ------------------------------------------------------------
// STAGE 1: SMOOTH THE RAW SAMPLES
// ------------------------------------------------------------

ecg_filter u_filter (
    .clk        (clk),
    .in_valid   (sample_valid),
    .in_sample  (sample),
    .out_valid  (filt_valid),
    .out_sample (filt_sample)
);


// ------------------------------------------------------------
// STAGE 2: REMOVE THE SLOW BASELINE
// ------------------------------------------------------------
//
// Takes the FILTERED sample, not the raw one.

baseline_remove u_base (
    .clk        (clk),
    .in_valid   (filt_valid),
    .in_sample  (filt_sample),
    .out_valid  (cent_valid),
    .out_sample (cent_sample)
);


// ------------------------------------------------------------
// STAGE 3: FIND THE HEARTBEATS
// ------------------------------------------------------------

beat_detect #(
    .THRESHOLD (THRESHOLD)
) u_beat (
    .clk          (clk),
    .reset        (reset),
    .sample       (cent_sample),
    .sample_valid (cent_valid),
    .beat         (beat)
);


// ------------------------------------------------------------
// STAGE 4: MEASURE THE GAP BETWEEN BEATS
// ------------------------------------------------------------

bpm_calc u_calc (
    .clk          (clk),
    .sample_valid (cent_valid),
    .beat         (beat),
    .period       (period),
    .period_valid (period_valid)
);


// ------------------------------------------------------------
// STAGE 5: TURN THAT GAP INTO BEATS PER MINUTE
// ------------------------------------------------------------

bpm_div u_div (
    .clk       (clk),
    .start     (period_valid),
    .period    (period),
    .bpm       (bpm),
    .bpm_valid (bpm_valid)
);


// ------------------------------------------------------------
// STAGE 6: SEND IT OUT OVER SERIAL
// ------------------------------------------------------------

// Built only when INCLUDE_BPM_UART is 1. A generate block is
// how Verilog includes or leaves out a whole piece of hardware
// depending on a parameter - it is decided at build time, not
// while the design is running.

generate
    if (INCLUDE_BPM_UART) begin : g_bpm_uart

        bpm_uart #(
            .CLKS_PER_BIT (CLKS_PER_BIT)
        ) u_uart (
            .clk       (clk),
            .bpm       (bpm),
            .bpm_valid (bpm_valid),
            .tx        (tx)
        );

    end
    else begin : g_no_uart

        // A serial line sits HIGH when nothing is being sent,
        // so that is what an unused output should look like.
        assign tx = 1'b1;

    end
endgenerate


endmodule

`default_nettype wire
