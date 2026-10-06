`default_nettype none

// ------------------------------------------------------------
// MODULE: ecg_filter
//
// PURPOSE:
//
// Moving-average low-pass filter.
//
// It keeps the last N samples, adds them up, and divides by N.
// That smooths out fast noise while leaving the slow shape of
// the ECG alone.
//
// N is always a power of two, so the divide is a right shift.
// A shift costs nothing in hardware - it is just rewiring.
// A real divider would cost a lot.
//
// The filter runs at the SAMPLE rate, not the clock rate:
// it only does work on the clock cycles where in_valid is high.
// ------------------------------------------------------------

module ecg_filter #(

    // Width of one sample, in bits.
    // The XADC gives us 12 bits, so W = 12.
    parameter integer W = 12,

    // Window length, expressed as a power of two.
    //
    // LOG2N = 3  ->  N = 8 samples
    // LOG2N = 4  ->  N = 16 samples
    //
    // At 500 samples/second, 8 samples is 16 ms of averaging.
    parameter integer LOG2N = 3

) (
    input  wire         clk,

    // One-clock pulse meaning "a new sample is on in_sample".
    input  wire         in_valid,

    input  wire [W-1:0] in_sample,

    // One-clock pulse meaning "out_sample is the new average".
    output reg          out_valid,

    output wire [W-1:0] out_sample
);


// ------------------------------------------------------------
// SIZES DERIVED FROM THE PARAMETERS
// ------------------------------------------------------------
//
// Everything below is worked out from W and LOG2N.
// Nothing is hardcoded, so changing LOG2N resizes the whole
// filter correctly instead of silently breaking it.

// Number of samples in the window.
// 1 << LOG2N means "1 shifted left LOG2N places", i.e. 2**LOG2N.
localparam integer N = 1 << LOG2N;

// How wide the running total needs to be.
//
// The worst case is N samples all at their maximum value:
//
//     N x (2**W - 1)
//
// which always fits in W + LOG2N bits.
//
// With W = 12 and LOG2N = 3:
//
//     8 x 4095 = 32760,  and 15 bits holds up to 32767.
//
// That is a tight fit, which is exactly why this is computed
// rather than written as a literal 15.
localparam integer SUM_W = W + LOG2N;


// ------------------------------------------------------------
// STORAGE
// ------------------------------------------------------------

// The last N samples. buffer[0] is the newest, buffer[N-1] the oldest.
reg [W-1:0] buffer [0:N-1];

// Running total of everything currently in buffer.
//
// We keep a running total instead of adding up all N samples
// every time. That way each new sample costs one add and one
// subtract, no matter how long the window is.
reg [SUM_W-1:0] sum;

integer i, j;


// ------------------------------------------------------------
// STARTING STATE
// ------------------------------------------------------------
//
// On a Xilinx FPGA these initial values are written into the
// registers when the bitstream is loaded, so the filter starts
// from zero without needing a reset signal.
//
// The first N samples after startup produce an output that is
// still ramping up, because the window is not full yet.

initial begin
    sum       = {SUM_W{1'b0}};
    out_valid = 1'b0;
    for (i = 0; i < N; i = i + 1)
        buffer[i] = {W{1'b0}};
end


// ------------------------------------------------------------
// MAIN FILTER
// ------------------------------------------------------------

always @(posedge clk) begin

    // Default: no output this cycle.
    // Set high further down only when a sample arrives,
    // which makes out_valid a one-clock pulse.
    out_valid <= 1'b0;

    if (in_valid) begin

        // Add the sample arriving now, subtract the one
        // dropping out of the far end of the window.
        sum <= sum + in_sample - buffer[N-1];

        // Shift the whole window along by one position.
        buffer[0] <= in_sample;

        for (j = 1; j < N; j = j + 1)
            buffer[j] <= buffer[j-1];

        out_valid <= 1'b1;

    end

end


// ------------------------------------------------------------
// DIVIDE BY N
// ------------------------------------------------------------
//
// Shifting right by LOG2N places divides by 2**LOG2N = N.
//
// This is combinational, and sum is updated by a non-blocking
// assignment on the same clock edge that raises out_valid.
// So when out_valid is high, out_sample already shows the
// average that includes the newest sample.

assign out_sample = sum >> LOG2N;


endmodule

`default_nettype wire
