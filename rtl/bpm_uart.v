module bpm_uart #(parameter CLKS_PER_BIT = 1250) (
    input clk,
    input [7:0] bpm,
    input bpm_valid,
    output tx
);

    reg uart_start;
    reg [7:0] uart_data;
    wire uart_busy;

    uart_tx #(CLKS_PER_BIT) u_tx(
        clk,
        uart_start,
        uart_data,
        tx,
        uart_busy
    );

    reg [7:0] bpm_hold;

    wire [3:0] hundreds = bpm_hold / 100;
    wire [3:0] tens = (bpm_hold % 100) / 10;
    wire [3:0] units = bpm_hold % 10;

    reg [2:0] byte_idx;
    reg [7:0] char;

    always @(*) begin
        case (byte_idx)
            3'd0: char = (hundreds != 0) ? hundreds + 8'd48 : 8'd32;
            3'd1: char = (hundreds == 0 && tens == 0) ? 8'd32 : tens + 8'd48;
            3'd2: char = units + 8'd48;
            3'd3: char = 13;
            3'd4: char = 10;
            default: char = 0;
        endcase
    end

    // Now the FSM to send the chars
    localparam IDLE = 2'd0,
               SEND = 2'd1,
               WAIT_START = 2'd2,
               WAIT_DONE = 2'd3;

    reg [1:0] state;

    initial begin
        state = IDLE;
        uart_start = 0;
        uart_data = 0;
        byte_idx = 0;
        bpm_hold = 0;
    end

    always @(posedge clk) begin
        uart_start <= 0;

        case (state)
            IDLE: begin
                if (bpm_valid) begin
                    bpm_hold <= bpm;
                    byte_idx <= 0;
                    state <= SEND;
                end
            end

            SEND: begin
                uart_data <= char;
                uart_start <= 1;
                state <= WAIT_START;
            end

            WAIT_START: begin
                if (uart_busy) begin
                    state <= WAIT_DONE;
                end
            end

            WAIT_DONE: begin
                if (~uart_busy) begin
                    if (byte_idx == 4)
                        state <= IDLE;
                    else begin
                        byte_idx <= byte_idx + 1;
                        state <= SEND;
                    end
                end
            end

        endcase
    end 

    
endmodule