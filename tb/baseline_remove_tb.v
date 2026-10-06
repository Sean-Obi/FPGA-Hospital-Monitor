`timescale 1ns/1ps
module baseline_remove_tb;
    localparam K = 8;

    reg                clk = 0;
    reg                in_valid = 0;
    reg         [11:0] in_sample = 0;
    wire               out_valid;
    wire signed [15:0] out_sample;

    baseline_remove #(.K(K)) dut (
        .clk(clk), .in_valid(in_valid), .in_sample(in_sample),
        .out_valid(out_valid), .out_sample(out_sample)
    );

    always #41.667 clk = ~clk;   // 12 MHz

    // ---- Reference model ----
    integer ref_acc = 0, ref_first = 1, expected;
    integer errors = 0, checked = 0, n = 0;
    integer min_out, max_out;

    task push(input integer s);
        integer base;
        begin
            base = ref_acc >> K;
            if (ref_first) begin
                ref_acc = s << K; ref_first = 0; expected = 0;
            end else begin
                expected = s - base;
                ref_acc  = ref_acc + s - base;
            end

            @(posedge clk); in_sample <= s; in_valid <= 1;
            @(posedge clk); in_valid <= 0;
            fork : wait_out
                begin @(posedge out_valid); disable wait_out; end
                begin repeat (3) @(posedge clk);
                      $display("ERROR: no out_valid"); errors = errors + 1;
                      disable wait_out; end
            join
            #1;
            checked = checked + 1;
            if (out_sample !== expected) begin
                if (errors < 10)
                    $display("ERROR: sample %0d: in=%0d got %0d, expected %0d",
                             n, s, out_sample, expected);
                errors = errors + 1;
            end
            if (out_sample < min_out) min_out = out_sample;
            if (out_sample > max_out) max_out = out_sample;
            n = n + 1;
            repeat (2) @(posedge clk);
        end
    endtask

    // A fake PPG pulse: 400 samples per beat (75 BPM at 500 Hz)
    function integer pulse(input integer t);
        integer p;
        begin
            p = t % 400;
            if      (p < 40)  pulse = p * 5;              // fast rise to +200
            else if (p < 200) pulse = 200 - (p - 40);     // slow fall to +40
            else              pulse = 40 - (p - 200) / 5; // back to 0
        end
    endfunction

    integer t;
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, baseline_remove_tb);
        repeat (3) @(posedge clk);

        // Test 1: flat signal at 2000 -> output should be 0 straight away
        min_out = 99999; max_out = -99999;
        for (t = 0; t < 50; t = t + 1) push(2000);
        $display("flat 2000       : output range %0d to %0d  (want 0 to 0)", min_out, max_out);

        // Test 2: pulses riding on 2000 -> output swings around 0
        for (t = 0; t < 1200; t = t + 1) push(2000 + pulse(t));
        min_out = 99999; max_out = -99999;
        for (t = 1200; t < 2000; t = t + 1) push(2000 + pulse(t));
        $display("pulses on 2000  : output range %0d to %0d  (should go negative AND positive)", min_out, max_out);

        // Test 3: baseline drifts up to 2600 (finger pressure changes)
        for (t = 0; t < 1200; t = t + 1) push(2000 + t/2 + pulse(t));
        for (t = 1200; t < 2400; t = t + 1) push(2600 + pulse(t));   // settle
        min_out = 99999; max_out = -99999;
        for (t = 2400; t < 3200; t = t + 1) push(2600 + pulse(t));
        $display("pulses on 2600  : output range %0d to %0d  (similar to above)", min_out, max_out);

        if (errors == 0) $display("PASS: all %0d outputs correct", checked);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule