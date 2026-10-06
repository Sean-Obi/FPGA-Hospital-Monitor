`timescale 1ns/1ps
module bpm_uart_tb;
    localparam CPB = 4;                  // clocks per bit (tiny for sim)

    reg        clk = 0;
    reg  [7:0] bpm = 0;
    reg        bpm_valid = 0;
    wire       tx;

    bpm_uart #(.CLKS_PER_BIT(CPB)) dut (
        .clk(clk), .bpm(bpm), .bpm_valid(bpm_valid), .tx(tx));

    always #41.667 clk = ~clk;           // 12 MHz

    // ---- Receiver: decodes tx like a serial monitor would ----
    reg [7:0] rx; integer i;
    reg [8*8-1:0] line = 0;              // characters of the current line
    initial forever begin
        @(negedge tx);
        repeat (CPB/2) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            repeat (CPB) @(posedge clk);
            rx[i] = tx;
        end
        repeat (CPB) @(posedge clk);
        if (tx !== 1) $display("ERROR: bad stop bit");
        if (rx == 10) begin              // newline: print the finished line
            $display("serial monitor shows: \"%0s\"", line);
            line = 0;
        end
        else if (rx != 13)                // ignore \r, keep other characters
            line = {line[8*7-1:0], rx};
    end

    // Send one reading and give it time to go out (5 bytes x 10 bits x CPB)
    task reading(input [7:0] b);
        begin
            @(posedge clk); bpm <= b; bpm_valid <= 1;
            @(posedge clk); bpm_valid <= 0;
            repeat (5 * 10 * CPB + 40) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, bpm_uart_tb);
        repeat (5) @(posedge clk);
        reading(75);         // expect "075"
        reading(120);        // expect "120"
        reading(8);          // expect "008"
        reading(0);          // expect "000"  (no pulse)

        // bpm changes halfway through sending: output must still be "062"
        @(posedge clk); bpm <= 62; bpm_valid <= 1;
        @(posedge clk); bpm_valid <= 0;
        repeat (30) @(posedge clk);
        bpm <= 199;
        repeat (5 * 10 * CPB + 40) @(posedge clk);
        $finish;
    end
endmodule