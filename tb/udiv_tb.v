`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: udiv_tb
//
// Checks the sequential divider against Verilog's own "/" on a
// spread of values, including the awkward ones: zero numerator,
// denominator of one, equal operands, the largest values that
// spo2_calc will ever produce, and division by zero.
//
//   iverilog -g2012 -o udiv_sim tb/udiv_tb.v rtl/udiv.v
//   vvp udiv_sim
// ------------------------------------------------------------

module udiv_tb;

    localparam integer W = 44;
    localparam integer CLK_HALF = 42;

    reg          clk   = 1'b0;
    reg          reset = 1'b1;
    reg          start = 1'b0;
    reg  [W-1:0] num   = 0;
    reg  [W-1:0] den   = 0;

    wire [W-1:0] quot;
    wire         done, busy, dbz;

    integer errors = 0;
    integer tests  = 0;

    always #CLK_HALF clk = ~clk;

    udiv #(.W(W)) dut (
        .clk(clk), .reset(reset), .start(start),
        .numerator(num), .denominator(den),
        .quotient(quot), .done(done), .busy(busy), .div_by_zero(dbz)
    );

    task divide(input [W-1:0] n, input [W-1:0] d);
        reg [W-1:0] want;
        begin
            @(negedge clk);
            num = n; den = d; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            // Division by zero finishes on the very next clock, so
            // done may already be high here. wait() copes with both.
            wait (done === 1'b1);
            #1;
            tests = tests + 1;
            if (d == 0) begin
                if (dbz && quot == {W{1'b1}})
                    $display("  PASS  %0d / 0 -> flagged div_by_zero", n);
                else begin
                    $display("  FAIL  %0d / 0 not flagged", n);
                    errors = errors + 1;
                end
            end
            else begin
                want = n / d;
                if (quot === want && !dbz)
                    $display("  PASS  %0d / %0d = %0d", n, d, quot);
                else begin
                    $display("  FAIL  %0d / %0d = %0d, expected %0d", n, d, quot, want);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        $display("");
        $display("========================================");
        $display(" SEQUENTIAL DIVIDER TEST (W=%0d)", W);
        $display("========================================");
        $display("");

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        divide(0, 7);
        divide(7, 7);
        divide(7, 1);
        divide(100, 3);
        divide(30000, 400);                  // the bpm_div case
        divide(44'd12345678901, 44'd98765);
        divide({W{1'b1}}, 1);                // largest / 1
        divide({W{1'b1}}, {W{1'b1}});        // largest / largest

        // The spo2_calc case: ac_red * dc_ir * 100 / (dc_red * ac_ir)
        //   ac_red=10000 dc_ir=150000 -> num = 150e9
        //   dc_red=100000 ac_ir=30000 -> den = 3e9   -> R100 = 50
        divide(44'd150000000000, 44'd3000000000);

        // Worst-case widths spo2_calc can produce (18-bit operands).
        divide(44'd262143 * 44'd262143 * 44'd100, 44'd1);
        divide(44'd262143 * 44'd262143 * 44'd100, 44'd262143 * 44'd262143);

        divide(12345, 0);                    // division by zero

        // Back-to-back: a start while busy must be ignored.
        @(negedge clk);
        num = 1000; den = 10; start = 1'b1;
        @(negedge clk);
        num = 5; den = 1;                    // garbage while busy
        @(negedge clk);
        start = 1'b0;
        wait (done === 1'b1); #1;
        tests = tests + 1;
        if (quot == 100) $display("  PASS  start ignored while busy");
        else begin $display("  FAIL  start not ignored while busy (got %0d)", quot); errors = errors + 1; end

        $display("");
        $display("========================================");
        if (errors == 0) $display(" PASS - all checks passed (%0d divisions)", tests);
        else             $display(" FAIL - %0d check(s) failed", errors);
        $display("========================================");
        $display("");
        $finish;
    end

    initial begin
        #5_000_000;
        $display(" TIMEOUT - done never arrived");
        $finish;
    end

endmodule

`default_nettype wire
