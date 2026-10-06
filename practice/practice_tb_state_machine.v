`timescale 1ns/1ps

module practice_tb_state_machine;

reg clk; // instatiate practice_state_machine in testbench
reg reset; // reg means controlled by testbench
reg start;
wire active; // controlled by practice_state_machine

practice_state_machine uut (
    .clk(clk),
    .reset(reset),
    .start(start),
    .active(active)
);

always #5 clk = ~clk; // always keep flipping the clk signal every 5ns

initial begin
    clk = 0;
    reset = 1;
    start = 0; // initially wait 10ns, then set reset to 0, then wait 10ns, then set start to 1, then wait 10ns, then set start to 0, then wait 20ns, then finish simulation

    #10;
    reset = 0;

    #10;
    start = 1;

    #10;
    start = 0;

    #20;
    $finish;
end

always @(negedge clk) begin
    $display("time=%0t  reset=%b  start=%b  active=%b",  // display the time, reset, start, and active signals at every negative edge of the clock
             $time, reset, start, active);
end

endmodule