`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: top_tb
//
// End-to-end test of the whole design, through top.v.
//
// A synthetic ECG waveform is fed into the XADC model, and the
// testbench then behaves like a laptop on the other end of the
// serial cable: it decodes the UART bit by bit and prints the
// heart rate, exactly as a terminal would show it.
//
// Run it with:
//
//   iverilog -g2012 -o top_sim tb/top_tb.v tb/xadc_model.v \
//            rtl/top.v rtl/sample_tick.v rtl/xadc_reader.v \
//            rtl/heart_pipeline.v rtl/ecg_filter.v \
//            rtl/baseline_remove.v rtl/beat_detect.v \
//            rtl/bpm_calc.v rtl/bpm_div.v rtl/bpm_uart.v \
//            rtl/uart.v rtl/buzzer.v rtl/led_flash.v
//   vvp top_sim
//   gtkwave top_tb.vcd
//
// WHAT IS BEING CHECKED
//
//   1. The "alive" LED blinks. If this fails on real hardware,
//      nothing else is worth looking at.
//   2. Beats are detected from a realistic ECG shape - one per
//      heartbeat, and NOT a second one on the T wave.
//   3. The BPM sent over the serial line matches the heart rate
//      that was fed in.
//   4. The beat LED flashes.
//   5. The buzzer makes a tone when a beat happens, and is
//      silent the rest of the time.
//   6. The reset button works while the design is running.
//   7. The temperature channel comes out as T#### in tenths of
//      a degree, from a known ADC code.
//   8. The MAX30102 model on the I2C bus is initialised, read,
//      and the SpO2 comes out as O####: a real value with a
//      finger on, 0 with it off, 999 with the sensor unplugged.
//
// A NOTE ON SPEED
//
// The real design ticks at 500 Hz, which is 24,000 clock cycles
// apart. Simulating a few seconds of that would take minutes
// and prove nothing extra, so SAMPLE_DIVIDE is turned right
// down here. Every other number in the design is untouched.
// ------------------------------------------------------------

module top_tb;

    // --------------------------------------------------------
    // SIMULATION SETTINGS
    // --------------------------------------------------------

    localparam integer CLK_HALF = 42;        // ~12 MHz

    // Simulation runs faster than hardware, but the RATIO
    // between the sample rate and the serial speed has to stay
    // realistic - otherwise the test asks the UART to send more
    // than the line can carry and samples get dropped for
    // reasons that would never happen on the board.
    //
    //   one S-message = 6 chars x 10 bits x CLKS_PER_BIT
    //                 = 6 x 10 x 4 = 240 clocks
    //   sample period = 400 clocks
    //   -> 60% of the line used
    //
    // Real hardware sits at 26% (6240 clocks of every 24000),
    // so this is a harder test than the real thing.
    localparam integer SAMPLE_DIVIDE = 400;

    // Serial bits are 40 clocks long instead of 1250.
    // Real hardware uses 104 (115200 baud). A smaller number
    // here just makes the serial line faster so the simulation
    // does not spend all its time shifting bits out.
    localparam integer CLKS_PER_BIT = 4;

    // Real hardware blinks the alive LED off bit 22, which is
    // millions of clock cycles. Bit 8 gives the same behaviour
    // fast enough to see here.
    localparam integer ALIVE_BIT = 8;

    // Scaled-down timings for the SpO2 path. The I2C bus runs at
    // 400 kHz instead of 100, the chip's reset wait is 200 clocks
    // instead of 10 ms, blocks are 16 samples instead of 256, and
    // temperature averages 16 readings instead of 256. None of
    // this changes any logic, only how long the test takes.
    localparam integer I2C_SCL_HZ      = 400_000;
    localparam integer SPO2_BLOCK_LOG2 = 4;
    localparam integer TEMP_AVG_LOG2   = 4;
    localparam integer STATUS_TICKS    = 50;

    // The model produces one PPG sample per millisecond of simulated
    // time, against a driver that needs about 0.35 ms per sample at
    // 400 kHz - the same comfortable ratio as the real 100 Hz / 100 kHz.
    localparam integer PPG_PERIOD_NS   = 1_000_000;

    // How many 500 Hz samples make up one heartbeat.
    // 100 samples at 2 ms each = 200 ms = 300 BPM... but since
    // the design only counts SAMPLES, what matters is that
    // 30000 / SAMPLES_PER_BEAT gives the BPM the design reports.
    //
    //   30000 / 400 = 75 BPM
    localparam integer SAMPLES_PER_BEAT = 400;
    localparam integer EXPECTED_BPM     = 30000 / SAMPLES_PER_BEAT;


    // --------------------------------------------------------
    // SIGNALS
    // --------------------------------------------------------

    reg        sysclk = 1'b0;
    reg  [0:0] btn    = 1'b0;

    wire [1:0] led;
    wire [1:0] xa_p = 2'b00;
    wire [1:0] xa_n = 2'b00;
    wire       uart_rxd_out;
    wire       buzzer;
    tri1       scl, sda;                 // I2C bus with pull-ups

    // What the MAX30102 model "sees" through the finger.
    reg [17:0] ppg_red = 18'd100000;
    reg [17:0] ppg_ir  = 18'd150000;
    reg        sensor_present = 1'b1;

    integer errors = 0;

    always #CLK_HALF sysclk = ~sysclk;


    // --------------------------------------------------------
    // DEVICE UNDER TEST
    // --------------------------------------------------------

    top #(
        .CLKS_PER_BIT        (CLKS_PER_BIT),
        .SAMPLE_DIVIDE       (SAMPLE_DIVIDE),
        .THRESHOLD           (16'sd70),
        .ALIVE_BIT           (ALIVE_BIT),
        .TEMP_AVG_LOG2       (TEMP_AVG_LOG2),
        .I2C_SCL_HZ          (I2C_SCL_HZ),
        .MAX_RESET_WAIT_CLKS (200),
        .MAX_POLL_CLKS       (100),
        .MAX_RETRY_CLKS      (3000),
        .SPO2_BLOCK_LOG2     (SPO2_BLOCK_LOG2),
        .STATUS_TICKS        (STATUS_TICKS)
    ) dut (
        .sysclk       (sysclk),
        .btn          (btn),
        .led          (led),
        .xa_p         (xa_p),
        .xa_n         (xa_n),
        .uart_rxd_out (uart_rxd_out),
        .buzzer       (buzzer),
        .scl          (scl),
        .sda          (sda)
    );

    max30102_model #(
        .SAMPLE_PERIOD_NS (PPG_PERIOD_NS)
    ) oximeter (
        .scl     (scl),
        .sda     (sda),
        .red_in  (ppg_red),
        .ir_in   (ppg_ir),
        .present (sensor_present)
    );

    // A crude pulse: the light levels swing +/-5% (red) and
    // +/-10% (IR) around their DC levels, which is R = 0.5 and
    // should read as 98%. Toggled every 3 ms so each 16-sample
    // block sees a fair mix of both levels.
    always begin
        #3_000_000;
        ppg_red = 18'd105000; ppg_ir = 18'd165000;
        #3_000_000;
        ppg_red = 18'd95000;  ppg_ir = 18'd135000;
    end


    // --------------------------------------------------------
    // MONITORS
    // --------------------------------------------------------

    integer beat_count      = 0;
    integer led_flash_count = 0;
    integer buzzer_edges    = 0;

    reg led0_prev = 1'b0;
    reg buzz_prev = 1'b0;

    always @(posedge sysclk) begin
        // Count heartbeats found by the detector.
        if (dut.beat)
            beat_count = beat_count + 1;

        // Count the LED turning on.
        if (led[0] && !led0_prev)
            led_flash_count = led_flash_count + 1;
        led0_prev <= led[0];

        // Count buzzer transitions. A tone is just a square wave,
        // so plenty of edges means a sound is being made.
        if (buzzer != buzz_prev)
            buzzer_edges = buzzer_edges + 1;
        buzz_prev <= buzzer;
    end


    // --------------------------------------------------------
    // SERIAL RECEIVER - stands in for the laptop
    // --------------------------------------------------------
    //
    // Waits for the line to drop (the start bit), waits half a
    // bit so it is sampling in the MIDDLE of each bit rather
    // than on the edges, then reads 8 bits.
    //
    // This is the same job the Python script will do, except
    // pyserial does the bit timing for you.

    localparam integer BIT_NS = CLKS_PER_BIT * CLK_HALF * 2;

    reg [7:0]   rx_byte;
    reg [8*8:1] line_buf;
    integer     line_len  = 0;
    integer     msg_count = 0;

    // The last complete number received, as an integer.
    integer     rx_bpm      = 0;
    integer     rx_acc      = 0;
    reg [7:0]   rx_tag      = 8'd0;
    integer     sample_msgs = 0;
    integer     bpm_msgs    = 0;
    integer     temp_msgs   = 0;
    integer     spo2_msgs   = 0;
    integer     rx_temp     = -1;
    integer     rx_spo2     = -1;
    integer     short_msgs  = 0;    // anything not 5 chars before the newline

    integer b;

    initial begin
        forever begin
            // Wait for the start bit.
            @(negedge uart_rxd_out);

            // Move into the middle of the start bit, then step
            // one full bit at a time.
            #(BIT_NS * 1.5);

            for (b = 0; b < 8; b = b + 1) begin
                rx_byte[b] = uart_rxd_out;
                #(BIT_NS);
            end

            // Carriage return or line feed ends the line.
            if (rx_byte == 8'd13 || rx_byte == 8'd10) begin
                if (line_len > 0) begin
                    msg_count = msg_count + 1;

                    // "S" is a raw sample, "B" is a heart rate.
                    if (rx_tag == "S") begin
                        sample_msgs = sample_msgs + 1;
                    end
                    else if (rx_tag == "B") begin
                        bpm_msgs = bpm_msgs + 1;
                        rx_bpm   = rx_acc;
                        $display("   serial monitor: \"%0s\"   -> %0d BPM",
                                 line_buf, rx_bpm);
                    end
                    else if (rx_tag == "T") begin
                        temp_msgs = temp_msgs + 1;
                        rx_temp   = rx_acc;
                        if (temp_msgs <= 3)
                            $display("   serial monitor: \"%0s\"   -> %0d.%0d C",
                                     line_buf, rx_temp / 10, rx_temp % 10);
                    end
                    else if (rx_tag == "O") begin
                        spo2_msgs = spo2_msgs + 1;
                        rx_spo2   = rx_acc;
                        $display("   serial monitor: \"%0s\"   -> SpO2 %0d",
                                 line_buf, rx_spo2);
                    end

                    if (line_len != 5)
                        short_msgs = short_msgs + 1;

                    line_buf = 0;
                    line_len = 0;
                    rx_acc   = 0;
                    rx_tag   = 8'd0;
                end
            end
            else begin
                line_buf = {line_buf[8*7:1], rx_byte};

                // The first character of a message is its tag.
                if (line_len == 0)
                    rx_tag = rx_byte;

                line_len = line_len + 1;

                if (rx_byte >= 8'd48 && rx_byte <= 8'd57)
                    rx_acc = rx_acc * 10 + (rx_byte - 8'd48);
            end
        end
    end


    // --------------------------------------------------------
    // SYNTHETIC ECG
    // --------------------------------------------------------
    //
    // A crude but fair imitation of one heartbeat:
    //
    //        R
    //        |
    //        |      T
    //   P    |     ---
    //  ---   |    /   \
    // ------ | --       --------
    //      Q-  -S
    //
    // The T wave matters. It is the second bump after the spike,
    // and it is the classic thing a naive detector counts as an
    // extra beat. The refractory window in beat_detect exists to
    // stop exactly that, so the waveform has to contain one for
    // the test to mean anything.
    //
    // Sitting on a DC level of 2000, which is roughly what the
    // AD8232 gives at mid-supply.

    localparam integer DC_LEVEL = 2000;

    function [11:0] ecg_shape(input integer phase);
        begin
            if      (phase < 30)  ecg_shape = DC_LEVEL;
            else if (phase < 45)  ecg_shape = DC_LEVEL + 40;    // P wave
            else if (phase < 60)  ecg_shape = DC_LEVEL;
            else if (phase < 64)  ecg_shape = DC_LEVEL - 60;    // Q
            else if (phase < 72)  ecg_shape = DC_LEVEL + 700;   // R spike
            else if (phase < 78)  ecg_shape = DC_LEVEL - 120;   // S
            else if (phase < 100) ecg_shape = DC_LEVEL;
            else if (phase < 140) ecg_shape = DC_LEVEL + 150;   // T wave
            else                  ecg_shape = DC_LEVEL;
        end
    endfunction


    integer phase = 0;

    // The temperature pin: 1049 counts = 850 mV = 35.0 C from a TMP36.
    initial dut.u_adc.xadc_inst.analog_code_vaux12 = 12'd1049;

    // Advance the waveform once per sample tick, so the ECG runs
    // at the same rate the design samples it.
    always @(posedge sysclk) begin
        if (dut.tick) begin
            dut.u_adc.xadc_inst.analog_code = ecg_shape(phase);
            phase = (phase + 1) % SAMPLES_PER_BEAT;
        end
    end


    // --------------------------------------------------------
    // HELPERS
    // --------------------------------------------------------

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

    // rx_bpm holds the last number the design sent, as an integer.
    // It is filled in by the serial receiver above, the same way
    // the Python script will turn the received text into a number.


    // --------------------------------------------------------
    // MAIN TEST SEQUENCE
    // --------------------------------------------------------

    integer alive_changes = 0;
    reg     alive_prev    = 1'b0;
    integer beats_before_reset;
    integer msgs_at;

    initial begin
        $dumpfile("top_tb.vcd");
        $dumpvars(0, top_tb);

        $display("");
        $display("========================================");
        $display(" FULL SYSTEM TEST (top.v)");
        $display("========================================");
        $display("");
        $display("  feeding a synthetic ECG at %0d BPM", EXPECTED_BPM);
        $display("  (%0d samples per beat, DC level %0d)",
                 SAMPLES_PER_BEAT, DC_LEVEL);
        $display("");


        // ----------------------------------------------------
        // 1. IS IT ALIVE?
        // ----------------------------------------------------
        //
        // Watch the alive LED for a while. This is the same
        // check you will do first on the real board.

        $display("-- 1. the alive LED --");

        alive_prev = led[1];
        repeat (20_000) begin
            @(posedge sysclk);
            if (led[1] !== alive_prev) begin
                alive_changes = alive_changes + 1;
                alive_prev = led[1];
            end
        end

        check_true(alive_changes > 0, "led[1] is blinking");
        $display("");


        // ----------------------------------------------------
        // 2. LET IT RUN
        // ----------------------------------------------------

        $display("-- 2. running the ECG (serial output below) --");
        $display("");

        // Long enough for a good number of beats, and for the
        // BPM figure to settle.
        repeat (15) @(posedge dut.beat);
        $display("");


        // ----------------------------------------------------
        // 3. BEATS
        // ----------------------------------------------------

        $display("-- 3. beat detection --");

        check_true(beat_count > 12, "beats are being detected");
        $display("        (%0d beats)", beat_count);

        // The T wave is the trap. If the refractory window were
        // missing, the detector would fire roughly twice per
        // heartbeat and the BPM would come out about double.
        check_true(rx_bpm > (EXPECTED_BPM * 9 / 10) &&
                   rx_bpm < (EXPECTED_BPM * 11 / 10),
                   "no double-counting on the T wave");
        $display("");


        // ----------------------------------------------------
        // 4. THE NUMBER ON THE SERIAL LINE
        // ----------------------------------------------------

        $display("-- 4. BPM over serial --");

        check_true(bpm_msgs > 5, "BPM messages are arriving over UART");
        $display("        (%0d BPM messages)", bpm_msgs);

        // The sample stream is what makes the waveform plottable.
        // There should be far more of these than BPM messages -
        // 500 a second against roughly one per heartbeat.
        // Roughly SAMPLES_PER_BEAT samples arrive for every one
        // BPM message, so the sample stream should dwarf it.
        check_true(sample_msgs > bpm_msgs * 250,
                   "raw sample stream is flowing");
        $display("        (%0d sample messages)", sample_msgs);

        check_true(dut.dropped_samples == 16'd0,
                   "no samples dropped at 115200 baud");

        check_true(rx_bpm == EXPECTED_BPM,
                   "reported BPM matches the input");
        $display("        (reported %0d, expected %0d)",
                 rx_bpm, EXPECTED_BPM);
        $display("");


        // ----------------------------------------------------
        // 5. LED AND BUZZER
        // ----------------------------------------------------

        $display("-- 5. LED and buzzer --");

        check_true(led_flash_count > 8, "beat LED is flashing");
        $display("        (%0d flashes)", led_flash_count);

        // A 2 kHz square wave produces a lot of edges. Silence
        // produces none. Anything substantial means a tone.
        check_true(buzzer_edges > 10, "buzzer is producing a tone");
        $display("        (%0d buzzer edges)", buzzer_edges);
        $display("");


        // ----------------------------------------------------
        // 6. THE RESET BUTTON
        // ----------------------------------------------------
        //
        // Reset is not just a power-up thing. Holding the button
        // must stop the detector, and releasing it must let the
        // design pick up again.

        $display("-- 6. reset button --");

        // The beat monitor above counts one clock AFTER a beat
        // rises, so step clear of the edge before reading the
        // counter. Reading it on the edge itself catches the
        // count mid-update and reports a beat that has not been
        // tallied yet.
        repeat (4) @(posedge sysclk);
        #1;
        beats_before_reset = beat_count;

        btn = 1'b1;                       // press
        repeat (5000) @(posedge sysclk);

        check_true(beat_count == beats_before_reset,
                   "no beats detected while reset is held");

        // The check above is necessary but not sufficient.
        //
        // Holding reset also stops xadc_reader producing samples,
        // so the detector goes quiet simply because nothing is
        // arriving. That means "no beats" would still be true even
        // if reset never reached the pipeline at all.
        //
        // So look inside beat_detect and confirm reset actually
        // cleared its state. This is the check that proves the
        // reset wire is really connected all the way down.
        check_true(dut.u_pipeline.u_beat.have_previous === 1'b0,
                   "reset reached beat_detect (have_previous cleared)");

        check_true(dut.u_pipeline.u_beat.refractory_counter === 16'd0,
                   "reset cleared the refractory counter");

        btn = 1'b0;                       // release
        repeat (60_000) @(posedge sysclk);

        check_true(beat_count > beats_before_reset,
                   "beats resume after reset is released");
        $display("");

        // The reset above cut a message off part-way, which the
        // receiver quite rightly saw as a short line. That is
        // expected (the Python side throws such lines away), so
        // only count short messages from here on.
        short_msgs = 0;


        // ----------------------------------------------------
        // 7. TEMPERATURE
        // ----------------------------------------------------

        $display("-- 7. temperature over serial --");

        check_true(temp_msgs > 3, "temperature messages are arriving");
        $display("        (%0d messages)", temp_msgs);
        check_true(rx_temp >= 349 && rx_temp <= 351,
                   "1049 counts reported as 35.0 C");
        $display("        (reported %0d.%0d C)", rx_temp / 10, rx_temp % 10);
        $display("");


        // ----------------------------------------------------
        // 8. SPO2
        // ----------------------------------------------------

        $display("-- 8. SpO2 over serial --");

        check_true(dut.sensor_ok === 1'b1,         "MAX30102 was found on the I2C bus");
        check_true(oximeter.regs[8'h09] == 8'h03,  "and put into SpO2 mode");
        check_true(spo2_msgs > 2,                  "SpO2 messages are arriving");
        $display("        (%0d messages)", spo2_msgs);
        check_true(rx_spo2 >= 96 && rx_spo2 <= 100,
                   "R = 0.5 reported as about 98%");
        $display("        (reported %0d%%)", rx_spo2);

        // Finger off: IR level collapses.
        ppg_ir = 18'd500; ppg_red = 18'd400;
        force top_tb.ppg_ir  = 18'd500;
        force top_tb.ppg_red = 18'd400;
        msgs_at = spo2_msgs;
        wait (spo2_msgs >= msgs_at + 2);           // a whole fresh block
        check_true(rx_spo2 == 0, "finger off -> O0000");

        // Sensor unplugged: driver loses the ACK, reports 999.
        sensor_present = 1'b0;
        msgs_at = spo2_msgs;
        wait (spo2_msgs >= msgs_at + 2);
        check_true(rx_spo2 == 999, "sensor unplugged -> O0999");
        release top_tb.ppg_ir;
        release top_tb.ppg_red;

        check_true(dut.dropped_samples == 16'd0,
                   "still no ECG samples dropped with all four streams");
        check_true(short_msgs == 0, "every message was exactly 6 characters");
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

    initial begin
        // 15 beats x 400 samples x 400 clocks x 84 ns is about
        // 200 ms of simulated time, so allow twice that.
        #600_000_000;
        $display("");
        $display(" TIMEOUT - simulation ran too long.");
        $display(" Beats so far: %0d.  Check tick, sample_valid", beat_count);
        $display(" and beat in the waveform to see where it stopped.");
        $display("");
        $finish;
    end

endmodule

`default_nettype wire
