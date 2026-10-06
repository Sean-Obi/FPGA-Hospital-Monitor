`default_nettype none

module practice_shift_register (

    // shift register is a row of little storage boxes. Each box holds one bit
    input wire clk, // shift register needs a clock to know when to shift the bits
    input wire reset, // shift register needs a reset to clear the bits
    input wire data_in,
    output wire [3:0] data_out
);

reg [3:0] shift_reg; // creates a 4 bit register called shift_reg
assign data_out = shift_reg; 
always @(posedge clk) begin // every time the clock goes from 0 to 1, do the following
    if (reset) begin // if reset = 1 (default)
            shift_reg <= 4'b0; // assign shift_reg a 4 bit binary value of 0   
        end
    else begin
        shift_reg <= {shift_reg[2:0], data_in}; // give me only bits 2,1,0 and add data_in to the end, and store the new number back into shift_reg
        // curly brackets mean concatenation
    end
end
endmodule

 

// Switch the default back, so this file cannot affect any other
// Verilog file compiled after it.
`default_nettype wire
