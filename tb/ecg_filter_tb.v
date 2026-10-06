`timescale 1ns/1ps
module ecg_filter_tb;
    localparam W = 12, LOG2N = 3, N = 1 << LOG2N;

    reg          clk = 0;
    reg          in_valid = 0;
    reg  [W-1:0] in_sample = 0;
    wire         out_valid;
    wire [W-1:0] out_sample;

    ecg_filter #(.W(W), .LOG2N(LOG2N)) dut (
        .clk(clk), .in_valid(in_valid), .in_sample(in_sample),
        .out_valid(out_valid), .out_sample(out_sample)
    );

    always #41.667 clk = ~clk;   // 12 MHz

    // ---- Reference model: what the answer SHOULD be ----
    reg [W-1:0] hist [0:N-1];    // last N samples (all start at 0)
    reg [W+LOG2N-1:0] ref_sum;
    reg [W-1:0] expected;
    integer k, errors = 0, checked = 0;
    initial for (k = 0; k < N; k = k + 1) hist[k] = 0;

    task push(input [W-1:0] s);
        begin
            // update reference
            for (k = N-1; k > 0; k = k - 1) hist[k] = hist[k-1];
            hist[0] = s;
            ref_sum = 0;
            for (k = 0; k < N; k = k + 1) ref_sum = ref_sum + hist[k];
            expected = ref_sum >> LOG2N;
            // drive the design for one clock
            @(posedge clk); in_sample <= s; in_valid <= 1;
            @(posedge clk); in_valid <= 0;
            // wait for its answer (must come within 3 clocks)
            fork : wait_out
                begin @(posedge out_valid); disable wait_out; end
                begin repeat (3) @(posedge clk);
                      $display("ERROR: no out_valid after sample %0d", s);
                      errors = errors + 1; disable wait_out; end
            join
            #1;
            checked = checked + 1;
            if (out_sample !== expected) begin
                $display("ERROR: in=%0d  got %0d, expected %0d", s, out_sample, expected);
                errors = errors + 1;
            end
            repeat (3) @(posedge clk);   // idle gap like a real sample tick
        end
    endtask

    integer t, v, seed = 42;
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, ecg_filter_tb);
        repeat (3) @(posedge clk);

        // Test 1: step from 0 to 1000 -> output should ramp up over N samples
        for (t = 0; t < 12; t = t + 1) push(1000);

        // Test 2: noisy "pulse" -> output should be smoother than input
        for (t = 0; t < 80; t = t + 1) begin
            v = 2000 + ((t % 20) < 5 ? (t % 20) * 200 : 0) + ($random(seed) % 60);
            push(v);
        end

        // Test 3: full scale -> checks your sum doesn't overflow
        for (t = 0; t < 12; t = t + 1) push(4095);

        if (errors == 0) $display("PASS: all %0d outputs correct", checked);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule