`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: temp_convert_tb
//
// Feeds known ADC codes and checks the tenths-of-a-degree out.
//
//   TMP36:  V = 0.5 V + 0.01 V/C.   Cmod pin: 0.8105 mV per count.
//
//   code  617  ->  500.1 mV  ->   0.0 C
//   code 1049  ->  850.2 mV  ->  35.0 C     (skin temperature)
//   code 1172  ->  949.9 mV  ->  44.9 C
//   code    0  ->    0.0 mV  ->  clamps to 0.0 C
//   code 4095  -> 3319.0 mV  -> 281.9 C     (top of range, no overflow)
//
// Also: a batch that alternates 1049 and 1050 must average, not
// just take the last one; and exactly one result per batch.
//
//   iverilog -g2012 -o temp_sim tb/temp_convert_tb.v rtl/temp_convert.v
//   vvp temp_sim
// ------------------------------------------------------------

module temp_convert_tb;

    localparam integer CLK_HALF = 42;
    localparam integer AVG_LOG2 = 4;         // 16 readings per batch here
    localparam integer N        = 1 << AVG_LOG2;

    reg         clk   = 1'b0;
    reg         reset = 1'b1;
    reg  [11:0] code  = 12'd0;
    reg         code_valid = 1'b0;

    wire [13:0] temp_tenths;
    wire        temp_valid;

    integer errors  = 0;
    integer results = 0;

    always #CLK_HALF clk = ~clk;

    temp_convert #(.AVG_LOG2(AVG_LOG2)) dut (
        .clk(clk), .reset(reset),
        .code(code), .code_valid(code_valid),
        .temp_tenths(temp_tenths), .temp_valid(temp_valid)
    );

    always @(posedge clk) if (temp_valid) results = results + 1;

    task check_true(input condition, input [80*8:1] name);
        begin
            if (condition) $display("  PASS  %0s", name);
            else begin $display("  FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    task reading(input [11:0] c);
        begin
            @(negedge clk);
            code = c; code_valid = 1'b1;
            @(negedge clk);
            code_valid = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    task batch(input [11:0] c);
        integer k, prev;
        begin
            prev = results;
            for (k = 0; k < N; k = k + 1) reading(c);
            wait (results > prev);
            @(posedge clk); #1;
        end
    endtask

    task check_temp(input integer want, input [80*8:1] name);
        begin
            if (temp_tenths == want)
                $display("  PASS  %0s: %0d.%0d C", name, temp_tenths / 10, temp_tenths % 10);
            else begin
                $display("  FAIL  %0s: got %0d tenths, expected %0d", name, temp_tenths, want);
                errors = errors + 1;
            end
        end
    endtask

    integer k, prev;

    initial begin
        $display("");
        $display("========================================");
        $display(" TEMPERATURE CONVERSION TEST");
        $display("========================================");
        $display("");

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        batch(12'd617);   check_temp(0,    "617 counts = 0 C");
        batch(12'd1049);  check_temp(350,  "1049 counts = 35.0 C");
        batch(12'd1172);  check_temp(449,  "1172 counts = 44.9 C");
        batch(12'd0);     check_temp(0,    "0 counts clamps to 0 C");
        batch(12'd4095);  check_temp(2819, "4095 counts = 281.9 C (no overflow)");

        // Averaging: half 1049, half 1050 -> 1049.5 counts = 850.6 mV -> 350 or 351.
        prev = results;
        for (k = 0; k < N; k = k + 1) reading((k % 2) ? 12'd1050 : 12'd1049);
        wait (results > prev); @(posedge clk); #1;
        check_true(temp_tenths == 350 || temp_tenths == 351,
                   "alternating 1049/1050 averages to 35.0-35.1 C");

        // A single hot reading in a batch of cool ones must be averaged in,
        // not taken on its own: 15 x 1049 + 1 x 1300 -> 1064.7 counts -> 36.3 C
        prev = results;
        for (k = 0; k < N; k = k + 1) reading((k == 3) ? 12'd1300 : 12'd1049);
        wait (results > prev); @(posedge clk); #1;
        check_true(temp_tenths >= 362 && temp_tenths <= 364,
                   "one outlier is averaged in, not reported alone");

        check_true(results == 7, "exactly one result per batch of 16 readings");

        $display("");
        $display("========================================");
        if (errors == 0) $display(" PASS - all checks passed");
        else             $display(" FAIL - %0d check(s) failed", errors);
        $display("========================================");
        $display("");
        $finish;
    end

    initial begin
        #5_000_000;
        $display(" TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
