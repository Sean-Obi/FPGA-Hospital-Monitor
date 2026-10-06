`timescale 1ns/1ps //tells simulator how we measure simulation time 
//main time unit is nanoseconds (ns)

module practice_tb_sample_tick; //starts our testbench module

// no inputs or outputs needed because the testbench represents the outside world
// probe the module with different signals, using testbench

//testbench itself is what probes the clk signal to switch between 0 and 1
reg clk; // instatiate sample_tick in testbench
reg reset; // reg means controlled by testbench
wire tick; // wire means controlled by sample_tick

  practice_sample_tick uut ( // unit under test
        .clk(clk), // Connect the testbench's clk signal to the clk input of sample_tick
        // .clk is the port on the module and (clk) is the testbench clk signal
        .reset(reset),
        .tick(tick)
    );

 

initial begin // testbench acts like a switch to start clk
// initial keyword starts the simulation
    $dumpfile("prwave.vcd"); // save recording in this file
    $dumpvars(0, practice_tb_sample_tick); //Record the signals inside my testbench
    $dumpvars(0, uut.counter); // record counter inside my testbench
    clk = 0;
    reset = 1;
    // #5 clk = 1;  // wait 5 units of simulation time before moving onto the next thing 
    // #5 clk = 0; 
    // #5 clk = 1;
    // #5 clk = 0;

    #10;
    reset = 0;
    #100 ;// after 100ns stop
    $finish;
end
always #5 clk = ~clk; // always keep flipping the clk signal every 5ns 
endmodule

// first rising edge is being used to reset counter and tick. counter starts at 0 as soon as the second rising edge occurs 