`timescale 1ns/1ps
`default_nettype none


// ------------------------------------------------------------
// TESTBENCH: tb_led_flash
//
// PURPOSE:
//
// Pretend that heartbeats are being detected and check that:
//
// 1. A heartbeat turns the LED ON.
// 2. The LED stays ON for the chosen number of sample ticks.
// 3. The LED then turns OFF.
//
// In the REAL project:
//
//     1 sample_tick = 2 ms
//
// because:
//
//     sample rate = 500 Hz
//
// For this simulation we use only 5 ticks instead of 50,
// so the test finishes quickly.
// ------------------------------------------------------------

module tb_led_flash;


// ------------------------------------------------------------
// TESTBENCH SIGNALS
// ------------------------------------------------------------

// Fake FPGA clock that we generate in this testbench.
reg clk;


// Reset signal.
reg reset;


// Pretends to be the 500 Hz pulse from sample_tick.v.
reg sample_tick;


// Pretends to be the heartbeat pulse from beat_detect.v.
reg beat;


// This is the output from led_flash.v.
wire led;


// Used only by the TESTBENCH to count the ticks
// and make the terminal output easier to understand.
integer tick_number;


// ------------------------------------------------------------
// CREATE THE LED FLASH MODULE
// ------------------------------------------------------------
//
// The REAL led_flash module normally uses:
//
//     FLASH_TICKS = 50
//
// At 500 Hz:
//
//     1 tick = 2 ms
//
// so:
//
//     50 × 2 ms = 100 ms
//
// But for this simulation, we use:
//
//     FLASH_TICKS = 5
//
// so we only need to send 5 fake ticks.

led_flash #(

    .FLASH_TICKS(5)

) uut (

    .clk(clk),
    .reset(reset),

    .sample_tick(sample_tick),
    .beat(beat),

    .led(led)

);


// ------------------------------------------------------------
// CREATE A FAKE FPGA CLOCK
// ------------------------------------------------------------
//
// The exact frequency does NOT matter for this logic test.
//
// clk changes every 5 ns:
//
//     0 -> 1
//     wait 5 ns
//     1 -> 0
//     wait 5 ns
//
// Therefore one full clock cycle is 10 ns.

always #5 clk = ~clk;


// ------------------------------------------------------------
// TASK: CREATE ONE HEARTBEAT
// ------------------------------------------------------------
//
// A task is just a reusable piece of testbench code.
//
// Instead of writing all the timing commands again,
// we can simply write:
//
//     send_beat();
//
// This creates one heartbeat pulse.

task send_beat;

    begin

        // Wait until a falling clock edge.
        //
        // This gives us time to change beat BEFORE
        // the next rising edge.
        @(negedge clk);


        // Pretend beat_detect found a heartbeat.
        beat = 1'b1;


        // Wait until the next falling edge.
        //
        // A rising edge happened in between,
        // so led_flash had a chance to see beat = 1.
        @(negedge clk);


        // Heartbeat pulse is finished.
        beat = 1'b0;

    end

endtask;


// ------------------------------------------------------------
// TASK: CREATE ONE SAMPLE TICK
// ------------------------------------------------------------
//
// In the real FPGA:
//
// sample_tick.v creates one pulse every 2 ms.
//
// Here we create them manually.

task send_sample_tick;

    begin

        // Wait until a falling edge.
        @(negedge clk);


        // Pretend another 2 ms has passed.
        sample_tick = 1'b1;


        // Allow one rising edge to occur
        // while sample_tick is HIGH.
        @(negedge clk);


        // End the sample_tick pulse.
        sample_tick = 1'b0;

    end

endtask;


// ------------------------------------------------------------
// MAIN TEST
// ------------------------------------------------------------

initial begin


    // --------------------------------------------------------
    // STARTING VALUES
    // --------------------------------------------------------

    clk         = 1'b0;
    reset       = 1'b1;
    sample_tick = 1'b0;
    beat        = 1'b0;

    tick_number = 0;


    // --------------------------------------------------------
    // RESET
    // --------------------------------------------------------

    // Keep reset active briefly.
    #20;


    // Release reset.
    reset = 1'b0;


    $display("");
    $display("--------------------------------");
    $display("LED FLASH TEST");
    $display("--------------------------------");
    $display("");


    // --------------------------------------------------------
    // FIRST HEARTBEAT
    // --------------------------------------------------------

    send_beat();


    // --------------------------------------------------------
    // SEND 5 SAMPLE TICKS
    // --------------------------------------------------------
    //
    // Because this test uses FLASH_TICKS = 5,
    // the LED should turn OFF on tick 5.

    send_sample_tick();   // tick 1
    send_sample_tick();   // tick 2
    send_sample_tick();   // tick 3
    send_sample_tick();   // tick 4
    send_sample_tick();   // tick 5


    // Wait a little before the next fake heartbeat.
    #20;


    // --------------------------------------------------------
    // SECOND HEARTBEAT
    // --------------------------------------------------------

    send_beat();


    // Again, send 5 ticks.

    send_sample_tick();   // tick 1
    send_sample_tick();   // tick 2
    send_sample_tick();   // tick 3
    send_sample_tick();   // tick 4
    send_sample_tick();   // tick 5


    // Wait briefly.
    #20;


    $display("");
    $display("--------------------------------");
    $display("TEST FINISHED");
    $display("--------------------------------");
    $display("");


    // End the simulation.
    $finish;

end


// ------------------------------------------------------------
// PRINT ONLY IMPORTANT EVENTS
// ------------------------------------------------------------
//
// We do NOT print every clock cycle.
//
// We only print: heartbeat or sample_tick
// That makes the terminal output much easier to understand.

always @(posedge clk) begin


    // Wait 1 ns so that the non-blocking assignments
    // inside led_flash.v have finished updating.
    #1;
    // --------------------------------------------------------
    // HEARTBEAT
    // --------------------------------------------------------
    if (beat) begin

        // A new heartbeat starts a new LED flash.
        tick_number = 0;


        $display(
            "HEARTBEAT detected  ->  LED=%b",
            led
        );

    end


    // --------------------------------------------------------
    // SAMPLE TICK
    // --------------------------------------------------------

    else if (sample_tick) begin


        // Another 2 ms of ECG time has passed.
        tick_number = tick_number + 1;


        $display(
            "tick %0d             ->  LED=%b",
            tick_number,
            led
        );

    end

end


endmodule

`default_nettype wire