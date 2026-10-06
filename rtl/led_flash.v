`default_nettype none

module led_flash #(

    // How many 500 Hz sample ticks
    // the LED should stay on for.
    //
    // 500 ticks = 1 second
    // 50 ticks  = 0.1 second = 100 ms
    parameter integer FLASH_TICKS = 50

)(

    // Main FPGA clock: 12 MHz
    input wire clk,

    // Reset the module
    input wire reset,

    // One-clock pulse from sample_tick.v
    //
    // Happens 500 times per second.
    input wire sample_tick,

    // One-clock pulse from beat_detect.v
    // Means:"A heartbeat was just detected."
    input wire beat,
    output reg led   // Drives the LED
);


// ------------------------------------------------------------
// FLASH COUNTER
// ------------------------------------------------------------
//
// This remembers how many 500 Hz ticks are left before the LED should turn off.
// Example: beat detected:
// flash_counter = 50
//
// then:
// 49
// 48
// 47
// ...
// 2
// 1
// 0
//
// When it reaches 0, the LED turns off.

reg [7:0] flash_counter;


// ------------------------------------------------------------
// MAIN LOGIC
// ------------------------------------------------------------

always @(posedge clk) begin


    // --------------------------------------------------------    
    // RESET
    // --------------------------------------------------------

    if (reset) begin

        // LED starts off
        led <= 1'b0;

        // No flash time remaining
        flash_counter <= 8'd0;

    end


    // --------------------------------------------------------
    // HEARTBEAT DETECTED
    // --------------------------------------------------------

    else if (beat) begin

        // Turn the LED on immediately.
        led <= 1'b1;

        // Keep it on for 50 sample ticks.
        //
        // At 500 Hz:
        //
        // 50 × 2 ms = 100 ms
        flash_counter <= FLASH_TICKS;

    end


    // --------------------------------------------------------
    // NEW 500 Hz SAMPLE TICK
    // --------------------------------------------------------

    else if (sample_tick) begin


        // Is the LED flash timer still running?
        if (flash_counter > 1) begin

            // Count one tick closer to zero.
            flash_counter <= flash_counter - 1'b1;

            // Keep LED on.
            led <= 1'b1;

        end


        // Is this the final tick?
        else if (flash_counter == 1) begin

            // Timer has finished.
            flash_counter <= 8'd0;

            // Turn LED off.
            led <= 1'b0;

        end

    end

end


endmodule

`default_nettype wire

