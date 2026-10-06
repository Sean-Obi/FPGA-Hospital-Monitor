`default_nettype none

// ============================================================
// MODULE: telemetry_uart
//
// PURPOSE:
//
// Sends everything the laptop needs over the one serial line,
// in a form the Python monitor can read without guessing.
//
// Every message is the same shape: one tag letter, four decimal
// digits with leading zeros, and a newline. Six characters.
//
//     S2048\n   one ECG sample, 0..4095, 500 times a second
//     B0075\n   heart rate in BPM, whenever a new one is worked out
//     T0345\n   skin temperature in tenths of a degree C (34.5 C)
//     O0098\n   blood oxygen, percent. 0000 = no finger.
//               0999 = the MAX30102 is not responding.
//
// Fixed width matters: the receiver can rely on the length, and
// a message that comes out the wrong length is obviously garbage
// rather than quietly mis-parsed.
//
// ------------------------------------------------------------
// BANDWIDTH
// ------------------------------------------------------------
//
// One message is 6 characters, each 10 bits on the wire (start,
// 8 data, stop).
//
//     500 samples/s x 6 x 10 = 30,000 bits/s   for the ECG stream
//
// The other three are a few messages a second between them, so
// at 115,200 baud the line is about 27% busy.
//
//     CLKS_PER_BIT = 12,000,000 / 115,200 = 104.17  ->  104
//
// 104 gives 115,385 baud, 0.16% off. UART tolerates about 2%.
// Measured on hardware: 0 bad lines in 114,000 messages.
//
// ------------------------------------------------------------
// WHO GOES FIRST
// ------------------------------------------------------------
//
// If more than one message is waiting, heart rate goes first,
// then SpO2, then temperature, then the sample. The slow ones
// are rare and are what a person actually reads; a sample is
// never more than one message behind. If a new sample arrives
// while the previous one is still waiting, the old one is
// dropped and counted in dropped_samples. That should stay at 0.
// ============================================================

module telemetry_uart #(
    parameter integer CLKS_PER_BIT = 104
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [11:0] sample,
    input  wire        sample_valid,

    input  wire [7:0]  bpm,
    input  wire        bpm_valid,

    input  wire [13:0] temp_tenths,
    input  wire        temp_valid,

    input  wire [9:0]  spo2,            // 0..100, or 999
    input  wire        spo2_valid,

    output wire        tx,
    output reg  [15:0] dropped_samples
);


// ------------------------------------------------------------
// THE UART ITSELF
// ------------------------------------------------------------

reg        uart_start;
reg  [7:0] uart_data;
wire       uart_busy;

uart_tx #(
    .CLKS_PER_BIT (CLKS_PER_BIT)
) u_tx (
    .clk   (clk),
    .start (uart_start),
    .data  (uart_data),
    .tx    (tx),
    .busy  (uart_busy)
);


// ------------------------------------------------------------
// WHAT IS WAITING TO BE SENT
// ------------------------------------------------------------

reg [13:0] s_hold, b_hold, t_hold, o_hold;
reg        s_pend, b_pend, t_pend, o_pend;

// The message being sent right now.
reg [7:0]  cur_tag;
reg [13:0] cur_val;
reg [2:0]  char_index;


// ------------------------------------------------------------
// SPLIT THE VALUE INTO FOUR DIGITS
// ------------------------------------------------------------
//
// Adding 48 turns a digit into its ASCII character ('0' is 48).

wire [3:0] d3 =  cur_val / 1000;
wire [3:0] d2 = (cur_val % 1000) / 100;
wire [3:0] d1 = (cur_val % 100)  / 10;
wire [3:0] d0 =  cur_val % 10;

reg [7:0] current_char;

always @(*) begin
    case (char_index)
        3'd0:    current_char = cur_tag;
        3'd1:    current_char = {4'd3, d3};      // 0x30 + digit
        3'd2:    current_char = {4'd3, d2};
        3'd3:    current_char = {4'd3, d1};
        3'd4:    current_char = {4'd3, d0};
        default: current_char = 8'd10;           // newline
    endcase
end

localparam [2:0] LAST_INDEX = 3'd5;


// ------------------------------------------------------------
// THE SENDING STATE MACHINE
// ------------------------------------------------------------
//
//   IDLE       pick the highest-priority waiting message
//   SEND       hand one character to the UART
//   WAIT_START wait for the UART to raise busy
//   WAIT_DONE  wait for it to finish, then next char or IDLE
//
// WAIT_START matters: the UART takes a clock to raise busy.
// Without it we would look too early, see it still low, and
// think the character had already gone.

localparam [1:0] IDLE       = 2'd0,
                 SEND       = 2'd1,
                 WAIT_START = 2'd2,
                 WAIT_DONE  = 2'd3;

reg [1:0] state;

// The sample is being picked up for sending on this clock.
wire s_taken = (state == IDLE) && !b_pend && !o_pend && !t_pend && s_pend;


always @(posedge clk) begin

    if (reset) begin
        state           <= IDLE;
        uart_start      <= 1'b0;
        uart_data       <= 8'd0;
        s_hold <= 0; b_hold <= 0; t_hold <= 0; o_hold <= 0;
        s_pend <= 0; b_pend <= 0; t_pend <= 0; o_pend <= 0;
        cur_tag         <= "S";
        cur_val         <= 14'd0;
        char_index      <= 3'd0;
        dropped_samples <= 16'd0;
    end

    else begin

        uart_start <= 1'b0;

        // ----------------------------------------------------
        // SEND
        // ----------------------------------------------------

        case (state)

            IDLE: begin
                char_index <= 3'd0;
                if (b_pend) begin
                    b_pend <= 1'b0; cur_tag <= "B"; cur_val <= b_hold; state <= SEND;
                end
                else if (o_pend) begin
                    o_pend <= 1'b0; cur_tag <= "O"; cur_val <= o_hold; state <= SEND;
                end
                else if (t_pend) begin
                    t_pend <= 1'b0; cur_tag <= "T"; cur_val <= t_hold; state <= SEND;
                end
                else if (s_pend) begin
                    s_pend <= 1'b0; cur_tag <= "S"; cur_val <= s_hold; state <= SEND;
                end
            end

            SEND: begin
                // uart_tx ignores start while busy, and it has no
                // reset of its own - after a reset button press it
                // may still be finishing a character. So wait.
                if (!uart_busy) begin
                    uart_data  <= current_char;
                    uart_start <= 1'b1;
                    state      <= WAIT_START;
                end
            end

            WAIT_START: begin
                if (uart_busy)
                    state <= WAIT_DONE;
            end

            WAIT_DONE: begin
                if (!uart_busy) begin
                    if (char_index == LAST_INDEX)
                        state <= IDLE;
                    else begin
                        char_index <= char_index + 1'b1;
                        state      <= SEND;
                    end
                end
            end

            default: state <= IDLE;

        endcase


        // ----------------------------------------------------
        // TAKE IN NEW DATA - regardless of what is being sent
        // ----------------------------------------------------
        //
        // This comes AFTER the state machine on purpose. If a
        // value arrives on the very clock its predecessor is
        // being picked up, both want to write the pend flag:
        // the state machine clears it, this block sets it. The
        // later non-blocking assignment wins, so the new value
        // is kept rather than lost.

        if (sample_valid) begin
            // Dropped only if one was waiting AND it is not being
            // picked up right now.
            if (s_pend && !s_taken)
                dropped_samples <= dropped_samples + 1'b1;
            s_hold <= {2'b00, sample};
            s_pend <= 1'b1;
        end

        if (bpm_valid) begin
            b_hold <= {6'b0, bpm};
            b_pend <= 1'b1;
        end

        if (temp_valid) begin
            t_hold <= (temp_tenths > 14'd9999) ? 14'd9999 : temp_tenths;
            t_pend <= 1'b1;
        end

        if (spo2_valid) begin
            o_hold <= {4'b0, spo2};
            o_pend <= 1'b1;
        end

    end

end


endmodule

`default_nettype wire
