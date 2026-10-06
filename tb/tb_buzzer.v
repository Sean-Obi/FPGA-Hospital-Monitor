`timescale 1ns/1ps
`default_nettype none


// ------------------------------------------------------------
// TESTBENCH: tb_buzzer
//
// PURPOSE:
//
// Check that:
//
// 1. A heartbeat starts a beep.
//
// 2. While the beep is active, buzzer_out
//    repeatedly changes between 0 and 1.
//
// 3. After the chosen number of sample ticks,
//    the buzzer stops.
//
// We use VERY small numbers in this simulation
// to make the behavior easy to see.
// ------------------------------------------------------------

module tb_buzzer;


// ------------------------------------------------------------
// TESTBENCH SIGNALS
// ------------------------------------------------------------

reg clk;
reg reset;

reg sample_tick;
reg beat;

wire buzzer_out;


// Used only to make terminal output readable.
integer duration_tick;
integer tone_edge;


// ------------------------------------------------------------
// CREATE BUZZER MODULE
// ------------------------------------------------------------
//
// REAL design:
//
//     CLOCK_HZ  = 12,000,000
//     TONE_HZ   = 2,000
//     BEEP_TICKS = 50
//
// TEST design:
//
//     CLOCK_HZ = 100
//     TONE_HZ  = 10
//
// Therefore:
//
//     half period
//       = 100 / (2 × 10)
//       = 5 clocks
//
// So the buzzer toggles every 5 test clocks.
//
// We also use only 5 duration ticks.

buzzer #(

    .CLOCK_HZ(100),
    .TONE_HZ(10),
    .BEEP_TICKS(5)

) uut (

    .clk(clk),
    .reset(reset),

    .sample_tick(sample_tick),
    .beat(beat),

    .buzzer_out(buzzer_out)

);


// ------------------------------------------------------------
// CREATE TEST CLOCK
// ------------------------------------------------------------

always #5 clk = ~clk;


// ------------------------------------------------------------
// TASK: CREATE ONE HEARTBEAT
// ------------------------------------------------------------

task send_beat;

    begin

        @(negedge clk);

        beat = 1'b1;

        @(negedge clk);

        beat = 1'b0;

    end

endtask;


// ------------------------------------------------------------
// TASK: CREATE ONE SAMPLE TICK
// ------------------------------------------------------------

task send_sample_tick;

    begin

        // Let the tone run for several FPGA clocks
        // before saying another 2 ms has passed.
        repeat (8) begin

            @(negedge clk);

        end


        // Create one sample_tick pulse.
        sample_tick = 1'b1;


        @(negedge clk);


        sample_tick = 1'b0;

    end

endtask;


// ------------------------------------------------------------
// MAIN TEST
// ------------------------------------------------------------

initial begin

    // Initial values
    clk         = 1'b0;
    reset       = 1'b1;
    sample_tick = 1'b0;
    beat        = 1'b0;

    duration_tick = 0;
    tone_edge     = 0;


    // Reset briefly
    #20;

    reset = 1'b0;


    $display("");
    $display("--------------------------------");
    $display("BUZZER TEST");
    $display("--------------------------------");
    $display("");


    // --------------------------------------------------------
    // FIRST HEARTBEAT
    // --------------------------------------------------------

    send_beat();


    // The real buzzer would remain active for 50 ticks.
    //
    // For this simulation it only lasts 5.

    send_sample_tick();   // duration tick 1
    send_sample_tick();   // duration tick 2
    send_sample_tick();   // duration tick 3
    send_sample_tick();   // duration tick 4
    send_sample_tick();   // duration tick 5


    // Wait briefly after beep stops.
    repeat (10) begin

        @(negedge clk);

    end


    $display("");
    $display("--------------------------------");
    $display("TEST FINISHED");
    $display("--------------------------------");
    $display("");


    $finish;

end


// ------------------------------------------------------------
// PRINT HEARTBEAT AND DURATION EVENTS
// ------------------------------------------------------------

always @(posedge clk) begin

    // Wait until sequential logic has updated.
    #1;


    // Heartbeat occurred.
    if (beat) begin

        duration_tick = 0;

        $display(
            "HEARTBEAT -> BEEP START"
        );

    end


    // A new duration tick occurred.
    if (sample_tick) begin

        duration_tick = duration_tick + 1;

        $display(
            "duration tick %0d -> buzzer=%b",
            duration_tick,
            buzzer_out
        );

    end

end


// ------------------------------------------------------------
// PRINT AUDIO TONE CHANGES
// ------------------------------------------------------------
//
// Instead of dumping every FPGA clock,
// only show us when buzzer_out actually changes.

always @(buzzer_out) begin

    // Don't count reset/startup changes.
    if (!reset) begin

        tone_edge = tone_edge + 1;

        $display(
            "    tone edge %0d -> buzzer=%b",
            tone_edge,
            buzzer_out
        );

    end

end


endmodule

`default_nettype wire