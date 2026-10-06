`timescale 1ns/1ps
module bpm_calc_tb;
    reg        clk = 0;
    reg        sample_valid = 0;
    reg        beat = 0;
    wire [9:0] period;
    wire       period_valid;

    bpm_calc dut (.clk(clk), .sample_valid(sample_valid), .beat(beat),
                  .period(period), .period_valid(period_valid));

    always #41.667 clk = ~clk;   // 12 MHz

    // One sample: sample_valid pulse, optionally followed by a beat pulse
    // one clock later (that's how beat_detect behaves).
    task sample(input with_beat);
        begin
            @(posedge clk); sample_valid <= 1;
            @(posedge clk); sample_valid <= 0; beat <= with_beat;
            @(posedge clk); beat <= 0;
            @(posedge clk);                    // short gap (real gap is ~24,000 clocks)
        end
    endtask

    // Send `n_beats` heartbeats, `gap` samples apart
    integer b, s;
    task heartbeats(input integer gap, input integer n_beats);
        begin
            for (b = 0; b < n_beats; b = b + 1)
                for (s = 1; s <= gap; s = s + 1)
                    sample(s == gap);         // beat on the last sample of each gap
            repeat (3) @(posedge clk);        // let the last result come out
        end
    endtask

    // Checker: print every period and compare with what we expect
    integer expected = -1, errors = 0, checked = 0;
    always @(posedge clk) if (period_valid) begin
        #1;
        if (expected < 0)
            $display("period = %0d  (first beat - ignored)", period);
        else begin
            checked = checked + 1;
            if (period == expected)
                $display("period = %0d  OK  (%0d BPM)", period, 30000 / period);
            else begin
                $display("period = %0d  ERROR, expected %0d", period, expected);
                errors = errors + 1;
            end
        end
    end

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, bpm_calc_tb);
        repeat (3) @(posedge clk);

        heartbeats(123, 1);                        // first beat: no previous one, ignore

        expected = 500; heartbeats(500, 3);        //  60 BPM
        expected = 400; heartbeats(400, 3);        //  75 BPM
        expected = 250; heartbeats(250, 3);        // 120 BPM

        // Finger off: 2000 samples with no beat -> count must stop at 1023
        expected = 1023; heartbeats(2000, 1);

        expected = 400; heartbeats(400, 2);        // finger back on: 75 BPM

        if (errors == 0) $display("PASS: all %0d periods correct", checked);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule