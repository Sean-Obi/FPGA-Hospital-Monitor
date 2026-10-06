`default_nettype none

// ============================================================
// MODULE: i2c_master
//
// PURPOSE:
//
// Talks I2C, one byte at a time, on behalf of max30102_driver.
//
// I2C is a two-wire bus: SCL (clock) and SDA (data). Neither
// wire is ever driven HIGH by anyone. Each device can only pull
// a wire LOW or let go of it, and a pull-up resistor takes it
// high when nobody is pulling. That is why this module has
// *_oe outputs ("output enable" = pull low) and *_in inputs,
// instead of a plain output: the top level turns them into a
// tri-state pin.
//
//     assign sda = sda_oe ? 1'b0 : 1'bz;      // in top.v
//
// ------------------------------------------------------------
// THE PROTOCOL, IN ONE PARAGRAPH
// ------------------------------------------------------------
//
// START is SDA falling while SCL is high. STOP is SDA rising
// while SCL is high. In between, SDA may only change while SCL
// is low, and is read while SCL is high. Bytes go out MSB
// first, and after every byte the receiver pulls SDA low for
// one clock to say "got it" (ACK). A master reading bytes ACKs
// each one except the last, where it leaves SDA high (NACK) so
// the slave knows to stop sending.
//
// ------------------------------------------------------------
// COMMANDS
// ------------------------------------------------------------
//
// The caller raises cmd_valid for one clock with one of:
//
//     CMD_START   send a (repeated) START
//     CMD_WRITE   send wr_data, then read the slave's ACK bit
//     CMD_READ    read a byte, then send ACK (rd_ack=1) or NACK
//     CMD_STOP    send a STOP
//
// busy goes high while it works and done pulses when finished.
// After CMD_WRITE, ack_ok says whether the slave answered.
// After CMD_READ, rd_data holds the byte.
//
// ------------------------------------------------------------
// TIMING
// ------------------------------------------------------------
//
// Each bit is split into four equal quarters:
//
//     Q0  SCL low, SDA already set up
//     Q1  SCL released - wait for it to actually go high
//     Q2  SCL high - SDA is sampled at the end of Q1/start of Q2
//     Q3  SCL pulled low again; set up the next bit
//
// At 12 MHz and 100 kHz, a quarter is 30 clocks (2.5 us). The
// MAX30102 is a 400 kHz part, so its setup/hold requirements
// (0.6 us) are met several times over. A slow 100 kHz-only
// slave that insists on 4.7 us START setup would want SCL_HZ
// dropped to 50_000.
//
// "Wait for it to actually go high" is clock stretching: a slave
// is allowed to hold SCL low to make the master wait. The MAX30102
// does not, but supporting it costs nothing, and it means a missing
// pull-up resistor shows up as a bus_error instead of a silent hang.
//
// QUARTER must be at least 2 clocks.
// ============================================================

module i2c_master #(
    parameter integer CLK_HZ = 12_000_000,
    parameter integer SCL_HZ = 100_000,

    // How long to wait for SCL to rise before giving up.
    // 25 ms is far longer than any real stretch.
    parameter integer TIMEOUT_CLKS = CLK_HZ / 40
)(
    input  wire       clk,
    input  wire       reset,

    input  wire       cmd_valid,
    input  wire [1:0] cmd,
    input  wire [7:0] wr_data,
    input  wire       rd_ack,

    output reg        busy,
    output reg        done,
    output reg  [7:0] rd_data,
    output reg        ack_ok,
    output reg        bus_error,     // pulses with done if SCL never rose

    output reg        scl_oe,        // 1 = pull SCL low
    output reg        sda_oe,        // 1 = pull SDA low
    input  wire       scl_in,
    input  wire       sda_in
);


localparam [1:0] CMD_START = 2'd0,
                 CMD_WRITE = 2'd1,
                 CMD_READ  = 2'd2,
                 CMD_STOP  = 2'd3;

// Clocks per quarter bit. Never less than 2.
localparam integer QUARTER = (CLK_HZ / (SCL_HZ * 4)) > 2 ? (CLK_HZ / (SCL_HZ * 4)) : 2;


// ------------------------------------------------------------
// SYNCHRONISE THE PINS
// ------------------------------------------------------------
//
// The bus wires change whenever the slave (or the pull-ups)
// decide, with no relationship to our clock. Two flip-flops
// settle them before any logic looks. Same reason as the reset
// button in top.v.

reg [1:0] scl_sync = 2'b11;
reg [1:0] sda_sync = 2'b11;

always @(posedge clk) begin
    scl_sync <= {scl_sync[0], scl_in};
    sda_sync <= {sda_sync[0], sda_in};
end

wire scl_s = scl_sync[1];
wire sda_s = sda_sync[1];


// ------------------------------------------------------------
// STATE
// ------------------------------------------------------------

localparam [2:0] S_IDLE  = 3'd0,
                 S_START = 3'd1,
                 S_BITS  = 3'd2,   // the 8 data bits of a byte
                 S_ACK   = 3'd3,   // the 9th bit
                 S_STOP  = 3'd4;

reg [2:0]  state;
reg [1:0]  phase;        // Q0..Q3 of the current bit
reg [2:0]  bit_idx;      // 7 down to 0
reg        is_read;      // current byte is a read
reg [7:0]  shift;        // byte going out, or coming in
reg        ack_to_send;  // for reads: ACK (pull low) or NACK

reg [$clog2(QUARTER+1)-1:0]      q_timer;
reg [$clog2(TIMEOUT_CLKS+1)-1:0] stretch_timer;

// A quarter has elapsed.
wire q_done = (q_timer == QUARTER - 1);

// While SCL is released we only count once the wire really is
// high. That is the clock-stretch wait.
wire counting = scl_oe | scl_s;

wire stretch_timeout = (stretch_timer == TIMEOUT_CLKS - 1);

// "A quarter finished this clock."
wire step = q_done && counting;


always @(posedge clk) begin

    if (reset) begin
        state         <= S_IDLE;
        phase         <= 2'd0;
        bit_idx       <= 3'd7;
        busy          <= 1'b0;
        done          <= 1'b0;
        rd_data       <= 8'd0;
        ack_ok        <= 1'b0;
        bus_error     <= 1'b0;
        scl_oe        <= 1'b0;      // both lines released = bus idle
        sda_oe        <= 1'b0;
        is_read       <= 1'b0;
        shift         <= 8'd0;
        ack_to_send   <= 1'b0;
        q_timer       <= 0;
        stretch_timer <= 0;
    end

    else begin

        done      <= 1'b0;
        bus_error <= 1'b0;

        // ---- quarter timer and stretch watchdog ----
        if (state == S_IDLE) begin
            q_timer       <= 0;
            stretch_timer <= 0;
        end
        else if (counting) begin
            q_timer       <= q_done ? 0 : q_timer + 1'b1;
            stretch_timer <= 0;
        end
        else begin
            // SCL released but still reading low: somebody is
            // stretching, or there is no pull-up. Count that.
            stretch_timer <= stretch_timer + 1'b1;
        end

        // ---- give up if SCL never comes back ----
        if (state != S_IDLE && !counting && stretch_timeout) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            scl_oe    <= 1'b0;
            sda_oe    <= 1'b0;
            done      <= 1'b1;
            bus_error <= 1'b1;
            ack_ok    <= 1'b0;
        end

        else case (state)

        // ----------------------------------------------------
        // Accept a command. SDA is set up here, while SCL is
        // low, so that Q0 of the first bit is the setup time.
        S_IDLE: begin
            if (cmd_valid) begin
                busy    <= 1'b1;
                phase   <= 2'd0;
                bit_idx <= 3'd7;
                scl_oe  <= 1'b1;                 // hold SCL low to start
                case (cmd)
                    CMD_START: begin
                        sda_oe <= 1'b0;          // SDA must be high first
                        state  <= S_START;
                    end
                    CMD_STOP: begin
                        sda_oe <= 1'b1;          // SDA low first
                        state  <= S_STOP;
                    end
                    CMD_WRITE: begin
                        is_read <= 1'b0;
                        shift   <= wr_data;
                        sda_oe  <= ~wr_data[7];  // MSB first
                        state   <= S_BITS;
                    end
                    CMD_READ: begin
                        is_read     <= 1'b1;
                        shift       <= 8'd0;
                        ack_to_send <= rd_ack;
                        sda_oe      <= 1'b0;     // let the slave drive
                        state       <= S_BITS;
                    end
                endcase
            end
        end

        // ----------------------------------------------------
        // START (also repeated START):
        //   Q0 SCL low, SDA high     Q1 SCL released, SDA still high
        //   Q2 SDA pulled low = START   Q3 SCL pulled low
        S_START: begin
            if (step) begin
                phase <= phase + 1'b1;
                case (phase)
                    2'd0: scl_oe <= 1'b0;
                    2'd1: sda_oe <= 1'b1;
                    2'd2: scl_oe <= 1'b1;
                    2'd3: begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                    end
                endcase
            end
        end

        // ----------------------------------------------------
        // DATA BITS, MSB first.
        //   Q0 SCL low, SDA set up      Q1 release SCL, then sample
        //   Q2 SCL high                 Q3 pull SCL low, set up next bit
        S_BITS: begin
            if (step) begin
                phase <= phase + 1'b1;
                case (phase)
                    2'd0: scl_oe <= 1'b0;
                    2'd1: if (is_read) shift <= {shift[6:0], sda_s};
                    2'd2: scl_oe <= 1'b1;
                    2'd3: begin
                        if (bit_idx == 3'd0) begin
                            // On to the ACK bit.
                            sda_oe <= is_read ? ack_to_send : 1'b0;
                            state  <= S_ACK;
                        end
                        else begin
                            bit_idx <= bit_idx - 1'b1;
                            if (!is_read) begin
                                shift  <= {shift[6:0], 1'b0};
                                sda_oe <= ~shift[6];   // next bit
                            end
                        end
                    end
                endcase
            end
        end

        // ----------------------------------------------------
        // THE ACK BIT.
        //   writes: SDA released, read what the slave does with it
        //   reads:  SDA low for ACK, left high for NACK
        S_ACK: begin
            if (step) begin
                phase <= phase + 1'b1;
                case (phase)
                    2'd0: scl_oe <= 1'b0;
                    2'd1: if (!is_read) ack_ok <= ~sda_s;   // low = acknowledged
                    2'd2: scl_oe <= 1'b1;
                    2'd3: begin
                        sda_oe  <= 1'b0;          // never leave SDA held
                        rd_data <= shift;
                        state   <= S_IDLE;
                        busy    <= 1'b0;
                        done    <= 1'b1;
                    end
                endcase
            end
        end

        // ----------------------------------------------------
        // STOP:
        //   Q0 SCL low, SDA low       Q1 release SCL
        //   Q2 release SDA = STOP     Q3 bus-free time
        S_STOP: begin
            if (step) begin
                phase <= phase + 1'b1;
                case (phase)
                    2'd0: scl_oe <= 1'b0;
                    2'd1: sda_oe <= 1'b0;
                    2'd2: ;
                    2'd3: begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                    end
                endcase
            end
        end

        default: state <= S_IDLE;

        endcase

    end

end


endmodule

`default_nettype wire
