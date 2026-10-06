`default_nettype none

module practice_sample_tick (
    input wire clk,
    input wire reset,
    output reg tick // gives output signal permission to be inside an always block 
);

// tick is the output signal (one-clock pulse) that processes the next ECG sample
// one bit can only store 0 or 1
reg [3:0] counter; // creates a register called counter containing (3 2 1 0) 4 bits 
// 4 bits can represent 0000 to 1111 so the 4 bit register can count from 0 to 15

always @(posedge clk) begin // always a positive/rising edge for the clock input, do whats inside when 0 goes to 1
    if (reset) begin // if reset = 1 (default)
        counter <= 4'b0000; // assign (<-) a 4-bit binary value of 0 to the counter
        tick <= 1'b0; // assign tick 1 bit binary value of 0
    end
    else if (counter == 3) begin
        counter <= 4'b0000;
        tick <= 1'b1;
    end
    else begin 
        counter <= counter + 1; // Take the number currently stored in counter, add 1, and store the new number back into
        tick <= 1'b0;
    end
end
// block will only run for rising edges 

// counter is a memory box that keeps track of the clk signals rising edges
// once counter counts 0,1,2,3 (4 clock edges) the counter resets to 0 and the tick signal goes to 1 then back to 0 (pulse)
endmodule

// Switch the default back, so this file cannot affect any other
// Verilog file compiled after it.
`default_nettype wire
