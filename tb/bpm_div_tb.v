module bpm_div_tb;
    reg        clk = 0;
    reg        start = 0;
    reg  [9:0] period = 0;
    wire [7:0] bpm;
    wire       bpm_valid;

    bpm_div dut (.clk(clk), .start(start), .period(period),
                 .bpm(bpm), .bpm_valid(bpm_valid));

    always #41.667 clk = ~clk;   // 12 MHz

    integer errors = 0, checked = 0;

    // Give the divider one period, wait for the answer, check it
    task check(input [9:0] p, input [7:0] expected);
        begin
            @(posedge clk); period <= p; start <= 1;
            @(posedge clk); start <= 0;
            fork : wait_result
                begin @(posedge bpm_valid); disable wait_result; end
                begin repeat (400) @(posedge clk);
                      $display("ERROR: period %0d - no bpm_valid (stuck?)", p);
                      errors = errors + 1; disable wait_result; end
            join
            #1;
            checked = checked + 1;
            if (bpm == expected)
                $display("period %4d -> %3d BPM  OK", p, bpm);
            else begin
                $display("period %4d -> %3d BPM  ERROR, expected %0d", p, bpm, expected);
                errors = errors + 1;
            end
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, bpm_div_tb);
        repeat (3) @(posedge clk);

        check(400,  75);   // normal
        check(500,  60);
        check(250, 120);
        check(750,  40);   // slow
        check(120, 250);   // very fast
        check(401,  74);   // doesn't divide exactly -> rounds down
        check(1023,  0);   // finger off -> 0
        check(50,    0);   // impossibly fast (noise) -> 0
        check(0,     0);   // must not get stuck!

        if (errors == 0) $display("PASS: all %0d results correct", checked);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule