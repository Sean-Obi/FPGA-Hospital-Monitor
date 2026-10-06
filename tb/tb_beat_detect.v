`timescale 1ns/1ps
`default_nettype none

module tb_beat_detect;


// ------------------------------------------------------------
// TESTBENCH SIGNALS
// ------------------------------------------------------------

reg clk;
reg reset;

reg signed [15:0] sample;
reg sample_valid;

wire beat;


// ------------------------------------------------------------
// CREATE THE BEAT DETECTOR
// ------------------------------------------------------------
//
// THRESHOLD stays at 300.
//
// But for this TEST only,
// refractory period = 4 samples.
//
// The real module default is still 125 samples.

beat_detect #(
    .THRESHOLD(16'sd300), // signed 16-bit number with value 300
    .REFRACTORY_SAMPLES(4)
) uut (

    .clk(clk),
    .reset(reset),
    .sample(sample),
    .sample_valid(sample_valid),
    .beat(beat)

);


// ------------------------------------------------------------
// CREATE TEST CLOCK
// ------------------------------------------------------------
//
// We do not need a real 12 MHz clock for this logic test.
//
// A simple 10 ns period is easier to work with.

always #5 clk = ~clk;


// ------------------------------------------------------------
// TASK: SEND ONE ECG SAMPLE
// ------------------------------------------------------------
//
// This lets us write:
//
// send_sample(250);
//
// instead of repeating all the timing code every time.

task send_sample;

    input signed [15:0] value;

    begin

        // Put the new ECG value on the input
        sample = value;

        // Tell the detector this is a new sample
        sample_valid = 1'b1;

        // Wait for one clock cycle
        #10;

        // No new sample now
        sample_valid = 1'b0;

        // Wait another clock cycle
        #10;

    end

endtask


// ------------------------------------------------------------
// TEST
// ------------------------------------------------------------

initial begin

    // Starting values
    clk          = 1'b0;
    reset        = 1'b1;
    sample       = 16'sd0;
    sample_valid = 1'b0;


    // Hold reset briefly
    #20;

    // Release reset
    reset = 1'b0;


    // ----------------------------------------
    // FIRST FAKE ECG PEAK
    // ----------------------------------------

    send_sample(16'sd100);
    send_sample(16'sd200);
    send_sample(16'sd280);

    // Crosses threshold 300 here.
    // We expect ONE beat.
    send_sample(16'sd350);

    // Still above threshold.
    // These must NOT produce more beats.
    send_sample(16'sd600);
    send_sample(16'sd800);

    // Come back below threshold.
    send_sample(16'sd200);


    // ----------------------------------------
    // SECOND FAKE ECG PEAK
    // ----------------------------------------

    send_sample(16'sd250);

    // Cross threshold again.
    // Refractory period should now be finished,
    // so we expect another beat.
    send_sample(16'sd400);

    send_sample(16'sd700);
    send_sample(16'sd200);


    // Finish simulation
    #20;
    $finish;

end


// ------------------------------------------------------------
// PRINT RESULTS
// ------------------------------------------------------------

always @(posedge clk) begin

    if (sample_valid) begin

        // Wait 1 ns so the non-blocking assignments
        // inside beat_detect have time to update.
        #1;

        $display(
            "time=%0t  sample=%0d  beat=%b",
            $time,
            sample,
            beat
        );

    end

end


endmodule

`default_nettype wire