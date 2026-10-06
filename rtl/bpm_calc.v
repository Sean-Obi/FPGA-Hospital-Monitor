module bpm_calc(
    input clk,
    input sample_valid,
    input beat,
    output reg [9:0] period,
    output reg period_valid
);

    reg [9:0] count;
    reg [9:0] remaining;
    reg busy;
    reg [7:0] bpm;

    initial begin
        count = 1'b0;
        period = 1'b0;
        period_valid = 1'b0;
    end

    always @(posedge clk) begin

        period_valid <= 0;
        
        if (sample_valid) begin
            count <= (count < 1023) ? count + 1 : 1023;
        end

        if (beat) begin
            period <= count;
            count <= 1'b0;
            period_valid <= 1'b1;
        end

        // On start (when a new period arrives): load remaining with 30000, set bpm to 0, set busy.
        // While busy: do the rule above each clock.
        // When done: clear busy, and pulse bpm_valid for one clock.

        if (beat) begin
            remaining <= count;
            bpm <= 0;
            busy <= 0;
        end

    end

endmodule