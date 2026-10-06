`default_nettype none


// ------------------------------------------------------------
// MODULE: buzzer
//
// PURPOSE:
//
// Every time a heartbeat is detected:
//
//     1. Start a short beep.
//     2. Keep the beep active for about 100 ms.
//     3. While the beep is active, create a 2 kHz
//        square wave for the passive buzzer.
//
// The beat pulse comes from beat_detect.v.
//
// The 500 Hz sample_tick is used to measure
// how LONG the beep lasts.
//
// The 12 MHz FPGA clock is used to create
// the actual AUDIO FREQUENCY.
// ------------------------------------------------------------

module buzzer #(

    // Main FPGA clock frequency.
    //
    // Our Cmod A7 project uses 12 MHz.
    parameter integer CLOCK_HZ = 12_000_000,


    // Desired buzzer tone.
    //
    // 2000 Hz = 2000 sound-wave cycles per second.
    //
    // This should produce a fairly clear electronic beep.
    parameter integer TONE_HZ = 2000,


    // How many 500 Hz sample ticks should the beep last?
    //
    // 1 tick = 2 ms
    //
    // 50 × 2 ms = 100 ms
    parameter integer BEEP_TICKS = 50

)(

    // Main FPGA clock: 12 MHz
    input wire clk,


    // Reset the buzzer logic
    input wire reset,


    // 500 Hz timing pulse from sample_tick.v
    input wire sample_tick,


    // One-clock pulse from beat_detect.v
    //
    // Means:
    //
    // "A heartbeat was detected."
    input wire beat,


    // Digital signal that will eventually control
    // the physical buzzer circuit.
    output reg buzzer_out

);


// ------------------------------------------------------------
// CALCULATE THE AUDIO HALF-PERIOD
// ------------------------------------------------------------
//
// We want a 2 kHz square wave.
//
// A complete 2 kHz cycle takes:
//
//     12,000,000 / 2,000
//     = 6,000 FPGA clocks
//
// But a square wave must change twice per cycle:
//
//     LOW  -> HIGH
//     HIGH -> LOW
//
// Therefore:
//
//     6,000 / 2
//     = 3,000 clocks per toggle.
//
// Another way to write that:
//
//               CLOCK_HZ
// half period = ----------------
//               2 × TONE_HZ
//

localparam integer TONE_HALF_PERIOD_CLKS =
    CLOCK_HZ / (2 * TONE_HZ);


// ------------------------------------------------------------
// BEEP ACTIVE FLAG
// ------------------------------------------------------------
//
// 0 = buzzer should be silent
//
// 1 = we are currently inside the short beep window

reg beep_active;


// ------------------------------------------------------------
// BEEP DURATION COUNTER
// ------------------------------------------------------------
//
// This counts how many 500 Hz sample ticks
// remain before the beep should stop.
//
// Real example:
//
//     50
//     49
//     48
//     ...
//     2
//     1
//     0
//
// 50 ticks × 2 ms = 100 ms.

reg [7:0] beep_ticks_remaining;


// ------------------------------------------------------------
// AUDIO TONE COUNTER
// ------------------------------------------------------------
//
// This counts ordinary 12 MHz FPGA clocks.
//
// When it reaches 2999:
//
//     buzzer_out changes:
//
//         0 -> 1
//
//     or:
//
//         1 -> 0
//
// Then the counter starts again.
//
// This produces the 2 kHz square wave.

reg [31:0] tone_counter;


// ------------------------------------------------------------
// MAIN BUZZER LOGIC
// ------------------------------------------------------------

always @(posedge clk) begin


    // --------------------------------------------------------
    // RESET
    // --------------------------------------------------------

    if (reset) begin

        // Buzzer starts silent.
        buzzer_out <= 1'b0;


        // No beep currently happening.
        beep_active <= 1'b0;


        // No beep time remaining.
        beep_ticks_remaining <= 8'd0;


        // Reset tone generator.
        tone_counter <= 32'd0;

    end


    // --------------------------------------------------------
    // HEARTBEAT DETECTED
    // --------------------------------------------------------

    else if (beat) begin

        // Start the beep.
        beep_active <= 1'b1;


        // Load the duration timer.
        //
        // In the real design:
        //
        // 50 ticks × 2 ms
        // = 100 ms
        beep_ticks_remaining <= BEEP_TICKS;


        // Start a new tone from the beginning.
        tone_counter <= 32'd0;


        // Begin the square wave HIGH.
        buzzer_out <= 1'b1;

    end


    // --------------------------------------------------------
    // BEEP IS CURRENTLY ACTIVE
    // --------------------------------------------------------

    else if (beep_active) begin


        // ----------------------------------------------------
        // CONTROL HOW LONG THE BEEP LASTS
        // ----------------------------------------------------
        //
        // We only reduce this counter when sample_tick occurs.
        //
        // Therefore every count represents 2 ms.

        if (sample_tick) begin


            // More than one duration tick remaining?
            if (beep_ticks_remaining > 1) begin

                // Move one 2 ms step closer to the end.
                beep_ticks_remaining
                    <= beep_ticks_remaining - 1'b1;

            end


            // Final duration tick?
            else if (beep_ticks_remaining == 1) begin

                // Beep is finished.
                beep_ticks_remaining <= 8'd0;


                // Stop tone generation.
                beep_active <= 1'b0;


                // Make sure buzzer output ends LOW.
                buzzer_out <= 1'b0;


                // Reset audio counter.
                tone_counter <= 32'd0;

            end

        end


        // ----------------------------------------------------
        // CREATE THE AUDIO TONE
        // ----------------------------------------------------
        //
        // Only generate another tone edge if this clock
        // is NOT simultaneously ending the beep.
        //
        // At the real settings:
        //
        // TONE_HALF_PERIOD_CLKS = 3000

        if (
            !(
                sample_tick &&
                (beep_ticks_remaining == 1)
             )
        ) begin

            if (
                tone_counter ==
                TONE_HALF_PERIOD_CLKS - 1
            ) begin

                // Start counting the next half-cycle.
                tone_counter <= 32'd0;


                // Toggle buzzer output:
                //
                // 0 becomes 1
                // 1 becomes 0
                buzzer_out <= ~buzzer_out;

            end

            else begin

                // Keep counting 12 MHz clocks.
                tone_counter <= tone_counter + 1'b1;

            end

        end

    end


    // --------------------------------------------------------
    // NO BEEP ACTIVE
    // --------------------------------------------------------

    else begin

        // Keep physical output silent.
        buzzer_out <= 1'b0;


        // Keep audio counter ready for the next beat.
        tone_counter <= 32'd0;

    end

end


endmodule


`default_nettype wire