module bpm_div #(
    parameter SAMPLES_PER_MIN = 30000
)(
    input  wire clk,
    input  wire start,     
    input  wire [9:0] period,
    output reg  [7:0] bpm,
    output reg bpm_valid
);

    reg [14:0] remaining;   
    reg [7:0] count;       
    reg busy;

    initial begin
        // give busy, bpm, bpm_valid starting values
        busy = 1'b0;
        bpm_valid = 1'b0;
        bpm = 1'b0;
    end

    always @(posedge clk) begin
        bpm_valid <= 0;                   

        if (start && !busy) begin
            // load remaining with 30000, count with 0, set busy
            if (period < 100 || period == 1023) begin
                bpm <= 1'b0;
                bpm_valid <= 1'b1;
            end
            else begin
                remaining <= SAMPLES_PER_MIN;
                count <= 1'b0;
                busy <= 1'b1;
            end
        end
        else if (busy) begin
            if (remaining >= period) begin
                // subtract period from remaining, add 1 to count
                remaining <= remaining - period;
                count <= count + 1;
            end
            else begin
                // finished: copy count into bpm, pulse bpm_valid, clear busy
                bpm <= count;
                bpm_valid <= 1'b1;
                busy <= 1'b0;
            end
        end
    end

endmodule