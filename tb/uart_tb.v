`timescale 1ns/1ps
module uart_tx_tb;
    localparam CPB = 4;               // clocks per bit (tiny for sim; 1250 on real board)

    reg        clk = 0;
    reg        start = 0;
    reg  [7:0] data = 0;
    wire       tx, busy;

    uart_tx #(.CLKS_PER_BIT(CPB)) dut (
        .clk(clk), .start(start), .data(data), .tx(tx), .busy(busy)
    );

    always #41.667 clk = ~clk;        // 12 MHz

    // Send one byte: put it on data, pulse start for one clock
    task send(input [7:0] b);
        begin
            @(posedge clk); data <= b; start <= 1;
            @(posedge clk); start <= 0;
            wait (busy);                          // it started...
            wait (!busy);                         // ...and finished
            repeat (3) @(posedge clk);            // short idle gap
        end
    endtask

    // Receiver: watches tx and rebuilds the byte, like a PC would
    reg [7:0] rx; integer i;
    initial forever begin
        @(negedge tx);                            // start bit begins
        repeat (CPB/2) @(posedge clk);            // move to middle of start bit
        if (tx !== 0) $display("ERROR: start bit not low");
        for (i = 0; i < 8; i = i + 1) begin
            repeat (CPB) @(posedge clk);          // middle of next bit
            rx[i] = tx;                           // LSB first
        end
        repeat (CPB) @(posedge clk);
        if (tx !== 1) $display("ERROR: stop bit not high");
        $display("received 0x%h ('%c')", rx, rx);
    end

    // Safety net: stop if the design never finishes
    initial begin
        #50000 $display("TIMEOUT - busy never went low?");
        $finish;
    end

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, uart_tx_tb);
        repeat (5) @(posedge clk);
        send("H");
        send("i");
        send("!");
        $finish;
    end
endmodule