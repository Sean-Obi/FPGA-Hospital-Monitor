`default_nettype none

// ------------------------------------------------------------
// MODULE: sample_tick
//
// PURPOSE:
//
// The FPGA clock runs at 12 MHz. Nothing in the ECG design
// wants to run that fast.
//
// This counts clock cycles and produces a one-clock pulse
// every DIVIDE cycles, which gives the rest of the design a
// steady 500 samples per second to work to.
//
//     12,000,000 / 24,000 = 500 ticks per second
//     1 tick = 2 ms
// ------------------------------------------------------------

module sample_tick #(

    // How many clock cycles between ticks.
    //
    // The default is the real hardware value.
    //
    // Testbenches override it with something small, so a
    // simulation does not have to grind through 24,000 clock
    // cycles for every single sample. The logic is identical
    // either way - only the spacing changes.
    parameter integer DIVIDE = 24000

)(
    input wire clk,
    input wire reset,
    output reg  tick
);


// Counter wide enough to hold DIVIDE-1, worked out from the
// parameter rather than written as a fixed number. That way
// changing DIVIDE cannot silently overflow the counter.
reg [$clog2(DIVIDE)-1:0] counter;


always @(posedge clk) begin

    if (reset) begin
        counter <= 0;
        tick    <= 1'b0;     // assign tick 1 bit binary value of 0
    end

    else if (counter == DIVIDE - 1) begin
        counter <= 0;
        tick    <= 1'b1;
    end

    else begin
        // Take the number currently stored in counter, add 1,
        // and store the new number back into it.
        counter <= counter + 1'b1;
        tick    <= 1'b0;
    end

end


endmodule

`default_nettype wire
