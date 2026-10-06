`timescale 1ns/1ps 

module tb_sample_tick; 
reg clk; 
reg reset; 
wire tick; 


  sample_tick uut ( 
        .clk(clk), 
        .reset(reset),
        .tick(tick)
    );
initial begin
    $dumpfile("wave.vcd"); 
    $dumpvars(0, uut.counter);
    clk = 0;
    reset = 1;
    #100;
    reset = 0;
    #5000000; 
    $finish;
    $display("Simulation finished");
end
always @(posedge tick) begin
    $display("TICK happened at time %0t", $time);
end
always #41.667 clk = ~clk;  
endmodule

