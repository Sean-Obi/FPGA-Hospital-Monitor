`default_nettype none

// ============================================================
// MODULE: temp_convert
//
// PURPOSE:
//
// Turns the raw ADC reading of the TMP36 into tenths of a degree
// Celsius, averaged so the last digit does not flicker.
//
// ------------------------------------------------------------
// THE ARITHMETIC
// ------------------------------------------------------------
//
// The TMP36 gives 500 mV at 0 C and 10 mV per degree:
//
//     temperature (C) = (mV - 500) / 10
//
// which is the same as saying
//
//     temperature in tenths of a degree = mV - 500
//
// And the Cmod A7's divided analog input reads 3.32 V at full
// scale (measured: 4051 counts for the 3.28 V rail), so
//
//     mV = counts * 3320 / 4096 = counts * 0.8105
//
// There is no floating point on an FPGA, so 0.8105 is written
// as a fraction with a power-of-two denominator:
//
//     0.8105 ~= 830 / 1024          (0.8105 exactly, to 4 places)
//
// A multiply by 830 and a shift right by 10. The shift is free.
//
// ------------------------------------------------------------
// AVERAGING
// ------------------------------------------------------------
//
// 2^AVG_LOG2 readings are summed and the maths is done on the
// sum, dividing by the count with the same shift. That keeps the
// fractional part of the average, so with 256 readings the result
// has about 16x the resolution of a single one: roughly 0.005 C,
// against the 0.08 C of one ADC count.
//
// At 500 readings/s, 256 of them is a new temperature every 0.5 s.
// ============================================================

module temp_convert #(
    parameter integer AVG_LOG2  = 8,       // 256 readings per result
    parameter integer MV_MUL    = 830,     // counts -> mV numerator
    parameter integer MV_SHIFT  = 10,      // counts -> mV denominator (2^10)
    parameter integer OFFSET_MV = 500      // TMP36 output at 0 C
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [11:0] code,         // raw ADC reading
    input  wire        code_valid,   // one-clock pulse per reading

    output reg  [13:0] temp_tenths,  // e.g. 345 = 34.5 C
    output reg         temp_valid    // one-clock pulse per result
);


localparam integer SUM_W = 12 + AVG_LOG2;
localparam integer N     = 1 << AVG_LOG2;

reg [SUM_W-1:0]      sum;
reg [AVG_LOG2-1:0]   count;

// sum * 830, then shift by (10 + AVG_LOG2) to divide by both
// 1024 and the number of readings in one go.
wire [SUM_W-1:0]        sum_n  = sum + code;
wire [SUM_W+10-1:0]     scaled = sum_n * MV_MUL;
wire [11:0]             mv     = scaled[SUM_W+10-1 : MV_SHIFT + AVG_LOG2];


always @(posedge clk) begin

    if (reset) begin
        sum         <= 0;
        count       <= 0;
        temp_tenths <= 14'd0;
        temp_valid  <= 1'b0;
    end

    else begin
        temp_valid <= 1'b0;

        if (code_valid) begin
            if (count == N - 1) begin
                // Last reading of the batch: convert and publish.
                if (mv > OFFSET_MV)
                    temp_tenths <= mv - OFFSET_MV;
                else
                    temp_tenths <= 14'd0;        // below 0 C: clamp

                temp_valid <= 1'b1;
                sum        <= 0;
                count      <= 0;
            end
            else begin
                sum   <= sum_n;
                count <= count + 1'b1;
            end
        end
    end

end


endmodule

`default_nettype wire
