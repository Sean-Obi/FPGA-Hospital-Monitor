`default_nettype none

module beat_detect #(

    // Starting threshold for TESTING.
    // We will change this once we know the real filtered ECG amplitude.
    parameter signed [15:0] THRESHOLD = 16'sd300, //

    // At 500 samples per second:
    //
    // 125 samples × 2 ms = 250 ms
    //
    // This prevents the same heartbeat being detected repeatedly.
    parameter integer REFRACTORY_SAMPLES = 125

)(
    // Main FPGA clock: 12 MHz
    input wire clk,

    // Reset everything to a known starting state
    input wire reset,

    // ECG sample.
    //
    // signed means it can represent positive AND negative values.
    input wire signed [15:0] sample,

    // Goes high for one FPGA clock whenever a NEW ECG sample arrives
    input wire sample_valid,

    // Goes high for one FPGA clock when a heartbeat is detected
    output reg beat
);


// Remember the previous ECG sample.
//
// We need this so we can detect a CROSSING:
//
// previous <= threshold
// current  > threshold
reg signed [15:0] previous_sample;


// Counts how many ECG samples remain in the refractory period.
reg [15:0] refractory_counter;


// At startup, we do not have a previous ECG sample yet.
//
// This stops the very first sample from accidentally
// being detected as a threshold crossing.
reg have_previous;


// ------------------------------------------------------------
// MAIN BEAT DETECTOR
// ------------------------------------------------------------

always @(posedge clk) begin

    // Reset the detector
    if (reset) begin

        previous_sample    <= 16'sd0;
        refractory_counter <= 16'd0;
        have_previous      <= 1'b0;
        beat               <= 1'b0;

    end

    else begin

        // Normally beat is LOW.
        //
        // If a beat is found below, we temporarily set it HIGH.
        beat <= 1'b0;


        // Only process the ECG when a NEW sample arrives.
        if (sample_valid) begin


            // ------------------------------------------------
            // FIRST SAMPLE
            // ------------------------------------------------

            if (!have_previous) begin

                // We cannot detect a crossing yet,
                // because there is no older sample to compare with.
                previous_sample <= sample;

                // From now on, we have a previous sample.
                have_previous <= 1'b1;

            end


            // ------------------------------------------------
            // ALL LATER SAMPLES
            // ------------------------------------------------

            else begin


                // Are we currently ignoring new beats
                // because one was recently detected?
                if (refractory_counter != 0) begin

                    // Count one ECG sample closer to zero.
                    refractory_counter <= refractory_counter - 1'b1;

                end


                // If we are NOT refractory,
                // check whether the ECG crossed upward
                // through the threshold.
                else if (
                    (previous_sample <= THRESHOLD) &&
                    (sample > THRESHOLD)
                ) begin

                    // Heartbeat detected!
                    beat <= 1'b1;

                    // Start the refractory period.
                    refractory_counter <= REFRACTORY_SAMPLES - 1;

                end


                // Today's ECG sample becomes the previous
                // sample for the next comparison.
                previous_sample <= sample;

            end

        end

    end

end


endmodule

`default_nettype wire