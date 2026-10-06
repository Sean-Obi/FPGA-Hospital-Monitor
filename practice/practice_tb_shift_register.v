`timescale 1ns/1ps

module practice_tb_shift_register;

reg clk; // instatiate practice_shift_register in testbench
reg reset; // reg means controlled by testbench
reg data_in;
wire [3:0] data_out; // controlled by practice_shift_register

  practice_shift_register uut ( // unit under test
        .clk(clk), // Connect the testbench's clk signal to the clk input of practice_shift_register
        .reset(reset),
        .data_in(data_in),
        .data_out(data_out)
    );

always #5 clk = ~clk; // always keep flipping the clk signal every 5ns
initial begin // testbench acts like a switch to start clk
    clk = 0;
    reset = 1;
    data_in = 0;
    #10;
    reset = 0;
    #10;
    data_in = 1;
    #10;
    data_in = 1;
    #10;
    data_in = 0;
    #10;
    data_in = 1;
    #10;
    $finish; // intially wait 10ns, then set reset to 0, then wait 10ns, then set data_in to 1, then wait 10ns, then set data_in to 0, then wait 10ns, then finish simulation
end

always @(negedge clk) begin 
    $display("time=%0t  data_in=%b  data_out=%b", $time, data_in, data_out);
end
endmodule