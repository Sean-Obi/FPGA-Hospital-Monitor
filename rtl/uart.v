module uart_tx #(parameter CLKS_PER_BIT = 1250) (
    input  wire clk,
    input  wire start,
    input  wire [7:0] data,
    output reg tx,
    output reg busy
);

    // Ten bits cuz includes start - 8 bits - stop
    reg [9:0] shift_reg;
    reg [10:0] bit_timer;
    reg [3:0] bit_counter;

    initial begin
        busy = 0;
        tx   = 1;   // line idles high
    end

    always @(posedge clk) begin
        if (start & ~busy) begin
            shift_reg <= {1'b1, data, 1'b0};
            bit_timer <= 0;
            bit_counter <= 0;
            busy <= 1;
        end
        else if (busy) begin
            tx <= shift_reg[0];

            if (bit_timer == CLKS_PER_BIT - 1) begin
                // one bit-time is over:
                // 1. reset bit_timer
                bit_timer <= 0;
                // 2. shift shift_reg right by one
                shift_reg <= {1'b0, shift_reg[9:1]};
                // 3. count up bit_counter
                bit_counter <= bit_counter + 1;
                // 4. if that was the last bit -> finish (busy low, tx high)
                if (bit_counter == 9) begin
                    busy <= 0;
                    tx <= 1;
                end
            end
            else begin
                // still in the middle of a bit: just count
                bit_timer <= bit_timer + 1;
            end
        end
    end

endmodule