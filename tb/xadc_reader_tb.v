`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: xadc_reader_tb
//
// Tests xadc_reader.v against the behavioural XADC model in
// tb/xadc_model.v.
//
// Run it with:
//
//   iverilog -g2012 -o xadc_sim tb/xadc_reader_tb.v tb/xadc_model.v rtl/xadc_reader.v
//   vvp xadc_sim
//   gtkwave xadc_reader_tb.vcd
//
// WHAT IS BEING CHECKED
//
//   1. Reset holds sample at 0 and sample_valid low.
//   2. After reset, a sample_tick delivers the converted value.
//   3. sample_valid is exactly ONE clock wide, never longer.
//   4. sample_valid appears only in response to sample_tick -
//      the count of valids must equal the count of ticks.
//   5. sample HOLDS its value between ticks, even though the
//      XADC keeps converting underneath. This is the whole point
//      of the module: it turns a fast free-running ADC into a
//      clean 500 Hz sample stream.
//   6. A new analog value shows up on the next tick.
//   7. Reset part-way through clears everything again.
//   8. Every DRP read asks for the register of the channel that
//      just finished (0x14 for VAUX4, 0x1C for VAUX12). The model
//      counts any wrong address.
//   9. The second channel (the temperature sensor on VAUX12)
//      comes through on temp_sample, and the two channels never
//      get mixed up.
//
// NOTE ON SPEED
//
// The real design ticks at 500 Hz, which is 24000 clocks apart.
// Simulating that would be slow and would prove nothing extra,
// so this testbench drives sample_tick directly and much faster.
// sample_tick is an input to xadc_reader, so the module cannot
// tell the difference. sample_tick.v is tested separately by
// tb_sample_tick.v.
// ------------------------------------------------------------

module xadc_reader_tb;

    // 12 MHz clock -> 83.33 ns period. 42 ns half-period is close
    // enough; nothing here depends on the exact frequency.
    localparam integer CLK_HALF = 42;

    reg         clk         = 1'b0;
    reg         reset       = 1'b1;
    reg         sample_tick = 1'b0;

    wire [11:0] sample;
    wire [11:0] temp_sample;
    wire        sample_valid;

    integer errors       = 0;
    integer tick_count   = 0;
    integer valid_count  = 0;
    integer valid_run    = 0;   // how many clocks in a row valid has been high
    integer width_errors = 0;

    always #CLK_HALF clk = ~clk;


    // --------------------------------------------------------
    // DEVICE UNDER TEST
    // --------------------------------------------------------
    //
    // vauxp/vauxn are tied off because the model does not use
    // them - the "analog" value is poked into the model directly.

    xadc_reader dut (
        .clk          (clk),
        .reset        (reset),
        .sample_tick  (sample_tick),
        .vauxp_ecg    (1'b0),
        .vauxn_ecg    (1'b0),
        .vauxp_temp   (1'b0),
        .vauxn_temp   (1'b0),
        .sample       (sample),
        .temp_sample  (temp_sample),
        .sample_valid (sample_valid)
    );


    // --------------------------------------------------------
    // BACKGROUND MONITORS
    // --------------------------------------------------------
    //
    // These watch sample_valid the whole time, so a glitch
    // anywhere in the run gets caught, not just at the moments
    // the main test happens to look.

    always @(posedge clk) begin
        if (sample_valid) begin
            valid_count = valid_count + 1;
            valid_run   = valid_run + 1;

            if (valid_run > 1) begin
                width_errors = width_errors + 1;
                $display("  FAIL  sample_valid stayed high for %0d clocks at t=%0t",
                         valid_run, $time);
            end
        end
        else begin
            valid_run = 0;
        end
    end


    // --------------------------------------------------------
    // HELPERS
    // --------------------------------------------------------

    // Set the "voltage" on the ECG pin.
    task set_analog(input [11:0] value);
        begin
            dut.xadc_inst.analog_code = value;
        end
    endtask

    // Set the "voltage" on the temperature pin.
    task set_temp(input [11:0] value);
        begin
            dut.xadc_inst.analog_code_vaux12 = value;
        end
    endtask

    task check_temp(input [11:0] want, input [80*8:1] name);
        begin
            if (temp_sample === want)
                $display("  PASS  %0s: temp_sample = %0d", name, temp_sample);
            else begin
                $display("  FAIL  %0s: temp_sample = %0d, expected %0d", name, temp_sample, want);
                errors = errors + 1;
            end
        end
    endtask

    // Wait for n completed PASSES over both channels, so the reader
    // has had a chance to store fresh values for each internally.
    task wait_conversions(input integer n);
        integer k;
        begin
            for (k = 0; k < 2 * n + 1; k = k + 1)
                @(posedge dut.xadc_drdy);
        end
    endtask

    // Raise sample_tick for exactly one clock.
    // Driven on the falling edge so it is stable at the rising edge.
    task pulse_tick;
        begin
            @(negedge clk);
            sample_tick = 1'b1;
            tick_count  = tick_count + 1;
            @(negedge clk);
            sample_tick = 1'b0;
        end
    endtask

    task check_sample(input [11:0] want, input [80*8:1] name);
        begin
            if (sample === want)
                $display("  PASS  %0s: sample = %0d", name, sample);
            else begin
                $display("  FAIL  %0s: sample = %0d, expected %0d", name, sample, want);
                errors = errors + 1;
            end
        end
    endtask

    task check_true(input condition, input [80*8:1] name);
        begin
            if (condition)
                $display("  PASS  %0s", name);
            else begin
                $display("  FAIL  %0s", name);
                errors = errors + 1;
            end
        end
    endtask


    // --------------------------------------------------------
    // MAIN TEST SEQUENCE
    // --------------------------------------------------------

    initial begin
        $dumpfile("xadc_reader_tb.vcd");
        $dumpvars(0, xadc_reader_tb);

        $display("");
        $display("========================================");
        $display(" XADC READER TEST");
        $display("========================================");
        $display("");


        // ----------------------------------------------------
        // 1. RESET
        // ----------------------------------------------------
        $display("-- 1. reset holds outputs clear --");

        reset = 1'b1;
        set_analog(12'd1234);          // something non-zero, to prove
        repeat (200) @(posedge clk);   // reset really is clearing it

        check_sample(12'd0, "sample cleared during reset");
        check_true(sample_valid === 1'b0, "sample_valid low during reset");

        @(negedge clk);
        reset = 1'b0;
        $display("");


        // ----------------------------------------------------
        // 2. FIRST REAL SAMPLE
        // ----------------------------------------------------
        $display("-- 2. a tick delivers the converted value --");

        set_analog(12'd2048);          // mid-scale, ~1.65 V on a 3.3 V range
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd2048, "mid-scale 2048");
        $display("");


        // ----------------------------------------------------
        // 3. SAMPLE HOLDS BETWEEN TICKS
        // ----------------------------------------------------
        //
        // The ADC is converting continuously in the background.
        // Change the input but send NO tick: the output must not
        // move. This is what makes the 500 Hz stream well behaved.

        $display("-- 3. sample holds steady between ticks --");

        set_analog(12'd3000);
        wait_conversions(5);           // several conversions, no tick
        check_sample(12'd2048, "still 2048 with no tick");
        $display("");


        // ----------------------------------------------------
        // 4. NEW VALUE ARRIVES ON THE NEXT TICK
        // ----------------------------------------------------
        $display("-- 4. next tick picks up the new value --");

        pulse_tick;
        check_sample(12'd3000, "updated to 3000");
        $display("");


        // ----------------------------------------------------
        // 5. FULL RANGE
        // ----------------------------------------------------
        //
        // 0 and 4095 are the ends of the 12-bit range. Worth
        // checking explicitly: an off-by-one in the DO[15:4] slice
        // would show up at the top of the range.

        $display("-- 5. ends of the 12-bit range --");

        set_analog(12'd0);
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd0, "bottom of range");

        set_analog(12'd4095);
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd4095, "top of range");
        $display("");


        // ----------------------------------------------------
        // 6. A RUN OF SAMPLES, LIKE THE REAL THING
        // ----------------------------------------------------
        //
        // Walk through a few values in a row, the way an ECG
        // waveform would, checking each one.

        $display("-- 6. a short run of changing values --");

        set_analog(12'd1000);
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd1000, "run value 1000");

        set_analog(12'd1500);
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd1500, "run value 1500");

        set_analog(12'd2500);
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd2500, "run value 2500");

        set_analog(12'd1200);
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd1200, "run value 1200");
        $display("");


        // ----------------------------------------------------
        // 7. ONE VALID PER TICK
        // ----------------------------------------------------
        $display("-- 7. one sample_valid pulse per tick --");

        // Let the last tick's pulse finish being counted.
        // The monitor above runs on the same clock edge as this
        // block, and Verilog does not promise which goes first,
        // so step past the edge before reading the counters.
        repeat (2) @(posedge clk);
        #1;

        check_true(valid_count == tick_count,
                   "sample_valid count matches sample_tick count");
        $display("        (%0d ticks, %0d valid pulses)", tick_count, valid_count);

        check_true(width_errors == 0,
                   "sample_valid never wider than one clock");
        $display("");


        // ----------------------------------------------------
        // 8. RESET PART-WAY THROUGH
        // ----------------------------------------------------
        //
        // Reset is not just a power-up thing: the button has to
        // work mid-run too.

        $display("-- 8. reset works mid-run --");

        @(negedge clk);
        reset = 1'b1;
        repeat (10) @(posedge clk);
        check_sample(12'd0, "sample cleared by mid-run reset");

        @(negedge clk);
        reset = 1'b0;

        set_analog(12'd777);
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd777, "recovers after reset");
        $display("");


        // ----------------------------------------------------
        // 9. DRP ADDRESS
        // ----------------------------------------------------
        //
        // xadc_reader builds the DRP address from CHANNEL.
        // For VAUX4 that has to come out as 0x14. The model has
        // been counting every time it did not.

        $display("-- 9. DRP address --");

        check_true(dut.xadc_inst.daddr_errors == 0,
                   "every DRP read asked for the channel that just finished");
        $display("");


        // ----------------------------------------------------
        // 10. THE SECOND CHANNEL
        // ----------------------------------------------------
        //
        // The temperature sensor shares the converter. Its value
        // must come out on temp_sample, and never leak into the
        // ECG sample or vice versa.

        $display("-- 10. temperature channel (VAUX12) --");

        set_analog(12'd2030);          // ECG idling at mid-rail
        set_temp(12'd1049);            // TMP36 at ~35 C through the divider
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd2030, "ECG still 2030");
        check_temp(12'd1049,   "temperature 1049");

        set_temp(12'd1100);            // warmer, ECG untouched
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd2030, "ECG unchanged when only temperature moves");
        check_temp(12'd1100,   "temperature follows its own pin");

        set_analog(12'd2500);          // ECG spike, temperature untouched
        wait_conversions(3);
        pulse_tick;
        check_sample(12'd2500, "ECG follows its own pin");
        check_temp(12'd1100,   "temperature unchanged when only ECG moves");

        check_true(dut.xadc_inst.daddr_errors == 0,
                   "still no wrong DRP addresses with two channels");
        $display("");


        // ----------------------------------------------------
        // RESULT
        // ----------------------------------------------------

        $display("========================================");
        if (errors == 0)
            $display(" PASS - all checks passed");
        else
            $display(" FAIL - %0d check(s) failed", errors);
        $display("========================================");
        $display("");

        $finish;
    end


    // --------------------------------------------------------
    // SAFETY NET
    // --------------------------------------------------------
    //
    // If something never happens - a conversion that never
    // finishes, a DRDY that never arrives - the test would hang
    // forever waiting. This stops it and says so.

    initial begin
        #2_000_000;
        $display("");
        $display(" TIMEOUT - simulation ran too long, something is stuck.");
        $display(" Check that EOC and DRDY are pulsing in the waveform.");
        $display("");
        $finish;
    end

endmodule

`default_nettype wire
