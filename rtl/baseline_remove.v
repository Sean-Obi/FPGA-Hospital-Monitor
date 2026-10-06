module baseline_remove #(parameter K = 8) (       // baseline moves 1/2^K per sample
    input  wire               clk,
    input  wire               in_valid,           // from ecg_filter's out_valid
    input  wire        [11:0] in_sample,          // from ecg_filter's out_sample
    output reg                out_valid,          // to beat_detect's sample_valid
    output reg  signed [15:0] out_sample          // to beat_detect's sample
);

    reg  [11+K:0] acc;                  // baseline x 256 (20 bits)
    reg           have_first;
    wire [11:0]   baseline = acc >> K;

    initial begin
        /* set acc, have_first, out_valid, out_sample to 0 */
        acc = 1'b0;
        have_first = 1'b0;
        out_valid = 1'b0;
        out_sample = 16'b0;
    end

    always @(posedge clk) begin
        out_valid <= 0;

        if (in_valid) begin
            if (!have_first) begin
                /* acc starts at in_sample shifted left by K */
                acc <= in_sample << K;
                have_first <= 1;
                out_sample <= 16'b0;
            end
            else begin
                acc <= acc + in_sample - baseline;
                // Make sure it's signed since it can be -ve
                out_sample <= $signed(in_sample - baseline);
            end
            /* pulse out_valid */
            out_valid <= 1'b1;
        end
    end

endmodule