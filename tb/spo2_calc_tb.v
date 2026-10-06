`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: spo2_calc_tb
//
// Feeds blocks of red/IR samples with KNOWN AC and DC parts and
// checks the SpO2 that comes out against values worked out by
// hand from SpO2 = 110 - 25R.
//
// Each block is half the samples at DC+A and half at DC-A, so
// the average is exactly DC and max-min is exactly 2A. That
// makes the expected answers exact, not approximate.
//
//   1. R = 0.5  -> 98 %      (the textbook healthy case)
//   2. R = 1.0  -> 85 %
//   3. R = 0.4  -> 100 %     (clamped at the top)
//   4. no finger (tiny IR DC) -> 0, finger flag low
//   5. flat IR (no pulse)     -> 0
//   6. absurd ratio           -> 0 (clamped at the bottom)
//   7. exactly one result per block, blocks are N samples long
//
//   iverilog -g2012 -o spo2_sim tb/spo2_calc_tb.v rtl/spo2_calc.v rtl/udiv.v
//   vvp spo2_sim
// ------------------------------------------------------------

module spo2_calc_tb;

    localparam integer CLK_HALF   = 42;
    localparam integer BLOCK_LOG2 = 4;            // 16 samples, for speed
    localparam integer N          = 1 << BLOCK_LOG2;

    reg         clk   = 1'b0;
    reg         reset = 1'b1;
    reg  [17:0] red   = 18'd0;
    reg  [17:0] ir    = 18'd0;
    reg         sample_valid = 1'b0;

    wire [7:0]  spo2;
    wire        spo2_valid, finger;
    wire [17:0] dc_red, dc_ir, ac_red, ac_ir;
    wire [15:0] r100;

    integer errors  = 0;
    integer results = 0;

    always #CLK_HALF clk = ~clk;

    spo2_calc #(
        .BLOCK_LOG2 (BLOCK_LOG2),
        .FINGER_MIN (30000)
    ) dut (
        .clk(clk), .reset(reset),
        .red(red), .ir(ir), .sample_valid(sample_valid),
        .spo2(spo2), .spo2_valid(spo2_valid), .finger(finger),
        .dc_red_out(dc_red), .dc_ir_out(dc_ir),
        .ac_red_out(ac_red), .ac_ir_out(ac_ir), .r100_out(r100)
    );

    always @(posedge clk)
        if (spo2_valid) results = results + 1;


    task check_true(input condition, input [80*8:1] name);
        begin
            if (condition) $display("  PASS  %0s", name);
            else begin $display("  FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    // One sample, with a gap, like the real 100 Hz stream (scaled).
    task sample(input [17:0] r, input [17:0] i);
        begin
            @(negedge clk);
            red = r; ir = i; sample_valid = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            repeat (60) @(posedge clk);          // longer than the divider
        end
    endtask

    // A whole block: N/2 samples at DC+A then N/2 at DC-A.
    task block(input [17:0] red_dc, input [17:0] red_a,
               input [17:0] ir_dc,  input [17:0] ir_a);
        integer k, prev;
        begin
            prev = results;
            for (k = 0; k < N/2; k = k + 1) sample(red_dc + red_a, ir_dc + ir_a);
            for (k = 0; k < N/2; k = k + 1) sample(red_dc - red_a, ir_dc - ir_a);
            wait (results > prev);
            @(posedge clk); #1;
        end
    endtask


    initial begin
        $dumpfile("spo2_calc_tb.vcd");
        $dumpvars(0, spo2_calc_tb);

        $display("");
        $display("========================================");
        $display(" SPO2 CALCULATION TEST");
        $display("========================================");
        $display("");

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // ----------------------------------------------------
        $display("-- 1. R = 0.5 --");
        // red: 10% swing, IR: 20% swing  -> R = 0.1/0.2 = 0.5
        block(18'd100000, 18'd5000, 18'd150000, 18'd15000);
        $display("        dc_red=%0d ac_red=%0d dc_ir=%0d ac_ir=%0d r100=%0d spo2=%0d",
                 dc_red, ac_red, dc_ir, ac_ir, r100, spo2);
        check_true(dc_red == 100000 && ac_red == 10000, "red DC/AC measured exactly");
        check_true(dc_ir == 150000 && ac_ir == 30000,   "IR DC/AC measured exactly");
        check_true(r100 == 50,                           "R100 = 50");
        check_true(spo2 == 98,                           "SpO2 = 98 %");
        check_true(finger,                               "finger detected");
        $display("");

        // ----------------------------------------------------
        $display("-- 2. R = 1.0 --");
        block(18'd100000, 18'd10000, 18'd100000, 18'd10000);
        check_true(r100 == 100, "R100 = 100");
        check_true(spo2 == 85,  "SpO2 = 85 %");
        $display("");

        // ----------------------------------------------------
        $display("-- 3. R = 0.4, clamps at 100 --");
        block(18'd100000, 18'd2000, 18'd100000, 18'd5000);
        check_true(r100 == 40,  "R100 = 40");
        check_true(spo2 == 100, "SpO2 clamped to 100 %");
        $display("");

        // ----------------------------------------------------
        $display("-- 4. no finger --");
        block(18'd400, 18'd50, 18'd500, 18'd60);
        check_true(spo2 == 0,  "SpO2 = 0");
        check_true(!finger,    "finger flag low");
        $display("");

        // ----------------------------------------------------
        $display("-- 5. flat IR --");
        block(18'd100000, 18'd5000, 18'd150000, 18'd0);
        check_true(spo2 == 0, "SpO2 = 0 with no IR pulse (no divide by zero)");
        $display("");

        // ----------------------------------------------------
        $display("-- 6. absurd ratio --");
        // red swinging 60%, IR 2%  -> R = 30 -> R100 = 3000
        block(18'd100000, 18'd30000, 18'd100000, 18'd1000);
        check_true(r100 == 3000, "R100 = 3000");
        check_true(spo2 == 0,    "SpO2 clamped to 0");
        $display("");

        // ----------------------------------------------------
        $display("-- 7. block length --");
        check_true(results == 6, "exactly one result per block (6 blocks, 6 results)");
        $display("");

        $display("========================================");
        if (errors == 0) $display(" PASS - all checks passed");
        else             $display(" FAIL - %0d check(s) failed", errors);
        $display("========================================");
        $display("");
        $finish;
    end

    initial begin
        #50_000_000;
        $display(" TIMEOUT - no result arrived");
        $finish;
    end

endmodule

`default_nettype wire
