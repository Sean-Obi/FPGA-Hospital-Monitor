`default_nettype none

// ============================================================
// MODULE: max30102_driver
//
// PURPOSE:
//
// Runs the MAX30102 pulse oximeter chip over I2C and hands out
// one (red, infrared) light reading at a time.
//
// The MAX30102 shines a red LED and an infrared LED through your
// fingertip and measures how much light comes back. Blood that
// is carrying oxygen absorbs the two colours differently, so the
// ratio between the two signals says how saturated the blood is.
// This module only fetches the two numbers; spo2_calc.v does the
// maths.
//
// ------------------------------------------------------------
// WHAT IT DOES, IN ORDER
// ------------------------------------------------------------
//
//   1. Bus recovery: nine clock pulses and a STOP, in case the
//      chip was left mid-transfer by a previous bitstream.
//   2. Software reset (MODE_CONFIG bit 6), then wait 10 ms.
//   3. Read PART_ID. Must be 0x15, otherwise the thing on the
//      bus is not a MAX30102 and we stop and retry later.
//   4. Configure: FIFO, SpO2 ADC range / sample rate / pulse
//      width, LED currents, clear the FIFO pointers, and finally
//      switch to SpO2 mode.
//   5. Forever: read the FIFO write and read pointers. If they
//      differ, a sample is waiting: read six bytes from FIFO_DATA
//      and present them. Drain until the pointers match, then
//      wait a couple of milliseconds and look again.
//
// If anything fails (no ACK, PART_ID wrong, SCL stuck), sensor_ok
// drops, the driver waits a second and starts again from step 1.
// An unplugged sensor therefore shows up as sensor_ok = 0 rather
// than a hang, and plugging it in later just works.
//
// ------------------------------------------------------------
// WHY POLL THE POINTERS
// ------------------------------------------------------------
//
// The chip has an interrupt pin, but using it would mean another
// wire and another thing to get right on the breadboard. The two
// pointers tell us exactly how many samples are waiting, and
// reading them costs about 0.3 ms at 100 kHz - cheap against a
// 10 ms sample period.
//
// ------------------------------------------------------------
// THE SIX FIFO BYTES
// ------------------------------------------------------------
//
// In SpO2 mode every sample is RED then IR, three bytes each,
// MSB first, with the 18-bit value in the bottom 18 of 24 bits:
//
//     byte0[1:0] byte1[7:0] byte2[7:0]   = RED[17:0]
//     byte3[1:0] byte4[7:0] byte5[7:0]   = IR [17:0]
//
// Reading FIFO_DATA does not move the register pointer on to
// 0x08; it only advances the FIFO read pointer once all six
// bytes of a sample have been taken.
// ============================================================

module max30102_driver #(
    parameter integer CLK_HZ          = 12_000_000,
    parameter integer SCL_HZ          = 100_000,

    parameter integer RESET_WAIT_CLKS = CLK_HZ / 100,    // 10 ms
    parameter integer POLL_CLKS       = CLK_HZ / 500,    // 2 ms
    parameter integer RETRY_CLKS      = CLK_HZ,          // 1 s

    // Register values. See the datasheet, or the README.
    parameter [7:0]   FIFO_CONFIG     = 8'h10,   // no averaging, rollover on
    parameter [7:0]   SPO2_CONFIG     = 8'h27,   // 4096 nA, 100 sps, 411 us (18-bit)
    parameter [7:0]   LED_RED_PA      = 8'h1F,   // ~6.2 mA
    parameter [7:0]   LED_IR_PA       = 8'h1F
)(
    input  wire        clk,
    input  wire        reset,

    output reg  [17:0] red,
    output reg  [17:0] ir,
    output reg         sample_valid,     // one-clock pulse
    output reg         sensor_ok,        // high once PART_ID has been seen

    output wire        scl_oe,
    output wire        sda_oe,
    input  wire        scl_in,
    input  wire        sda_in
);


localparam [7:0] ADDR_W  = 8'hAE;   // 0x57 << 1
localparam [7:0] ADDR_R  = 8'hAF;
localparam [7:0] PART_ID = 8'h15;

localparam [7:0] REG_FIFO_WR  = 8'h04,
                 REG_FIFO_OVF = 8'h05,
                 REG_FIFO_RD  = 8'h06,
                 REG_FIFO_DAT = 8'h07,
                 REG_FIFO_CFG = 8'h08,
                 REG_MODE     = 8'h09,
                 REG_SPO2     = 8'h0A,
                 REG_LED1     = 8'h0C,
                 REG_LED2     = 8'h0D,
                 REG_PART_ID  = 8'hFF;


// ------------------------------------------------------------
// THE I2C MASTER
// ------------------------------------------------------------

localparam [1:0] CMD_START = 2'd0,
                 CMD_WRITE = 2'd1,
                 CMD_READ  = 2'd2,
                 CMD_STOP  = 2'd3;

reg        cmd_valid;
reg  [1:0] cmd;
reg  [7:0] wr_data;
reg        rd_ack;
wire       i2c_busy, i2c_done, i2c_ack, i2c_err;
wire [7:0] rd_data;

i2c_master #(
    .CLK_HZ (CLK_HZ),
    .SCL_HZ (SCL_HZ)
) u_i2c (
    .clk       (clk),
    .reset     (reset),
    .cmd_valid (cmd_valid),
    .cmd       (cmd),
    .wr_data   (wr_data),
    .rd_ack    (rd_ack),
    .busy      (i2c_busy),
    .done      (i2c_done),
    .rd_data   (rd_data),
    .ack_ok    (i2c_ack),
    .bus_error (i2c_err),
    .scl_oe    (scl_oe),
    .sda_oe    (sda_oe),
    .scl_in    (scl_in),
    .sda_in    (sda_in)
);


// ------------------------------------------------------------
// TRANSACTION ENGINE
// ------------------------------------------------------------
//
// Two kinds of transaction, built from the master's commands:
//
//   write register:  START  W(addr)  W(reg)  W(val)  STOP
//   read N bytes:    START  W(addr)  W(reg)  START  W(addr|1)
//                    R(ack) ... R(nack)  STOP
//
// The main state machine fills in x_kind / x_reg / x_val / x_n,
// pulses x_start, and waits for x_done. x_fail says whether
// anything went wrong on the way.

localparam [3:0] X_IDLE     = 4'd0,
                 X_START    = 4'd1,
                 X_ADDR     = 4'd2,
                 X_REG      = 4'd3,
                 X_VAL      = 4'd4,
                 X_RSTART   = 4'd5,
                 X_RADDR    = 4'd6,
                 X_RBYTE    = 4'd7,
                 X_STOP     = 4'd8,
                 X_RECOVER  = 4'd9;    // nine clocks with SDA free

reg [3:0]  x_state;
reg        x_start, x_done, x_fail;
reg        x_kind;                  // 0 = write, 1 = read
reg        x_recover;               // special: bus recovery
reg [7:0]  x_reg, x_val;
reg [2:0]  x_n;                     // bytes still to read
reg        waiting;                 // a command is in flight
reg        fail_pending;
reg [47:0] rx_buf;                  // the bytes read, newest at the bottom


// Issue one command to the master.
task issue(input [1:0] c, input [7:0] d, input a);
    begin
        cmd       <= c;
        wr_data   <= d;
        rd_ack    <= a;
        cmd_valid <= 1'b1;
        waiting   <= 1'b1;
    end
endtask


always @(posedge clk) begin

    if (reset) begin
        x_state      <= X_IDLE;
        x_done       <= 1'b0;
        x_fail       <= 1'b0;
        cmd_valid    <= 1'b0;
        cmd          <= CMD_START;
        wr_data      <= 8'd0;
        rd_ack       <= 1'b0;
        waiting      <= 1'b0;
        fail_pending <= 1'b0;
        rx_buf       <= 48'd0;
    end

    else begin

        x_done    <= 1'b0;
        cmd_valid <= 1'b0;

        if (x_state == X_IDLE) begin
            if (x_start) begin
                fail_pending <= 1'b0;
                x_fail       <= 1'b0;
                waiting      <= 1'b0;
                x_state      <= x_recover ? X_RECOVER : X_START;
            end
        end

        // A command is in flight: wait for the master.
        else if (waiting) begin
            if (i2c_done) begin
                waiting <= 1'b0;

                // Any failure: finish with a STOP, then report.
                if (i2c_err || (cmd == CMD_WRITE && !i2c_ack)) begin
                    fail_pending <= 1'b1;
                    x_state      <= i2c_err ? X_IDLE : X_STOP;
                    if (i2c_err) begin
                        x_done <= 1'b1;
                        x_fail <= 1'b1;
                    end
                end
                else case (x_state)
                    X_START:   x_state <= X_ADDR;
                    X_ADDR:    x_state <= X_REG;
                    X_REG:     x_state <= x_kind ? X_RSTART : X_VAL;
                    X_VAL:     x_state <= X_STOP;
                    X_RSTART:  x_state <= X_RADDR;
                    X_RADDR:   x_state <= X_RBYTE;
                    X_RBYTE: begin
                        rx_buf <= {rx_buf[39:0], rd_data};
                        if (x_n == 3'd1)
                            x_state <= X_STOP;
                        else
                            x_n <= x_n - 1'b1;
                    end
                    X_RECOVER: x_state <= X_STOP;
                    X_STOP: begin
                        x_state <= X_IDLE;
                        x_done  <= 1'b1;
                        x_fail  <= fail_pending;
                    end
                    default:   x_state <= X_IDLE;
                endcase
            end
        end

        // Nothing in flight: issue the command for this step.
        else if (!i2c_busy) begin
            case (x_state)
                X_START,
                X_RSTART:  issue(CMD_START, 8'h00, 1'b0);
                X_ADDR:    issue(CMD_WRITE, ADDR_W, 1'b0);
                X_REG:     issue(CMD_WRITE, x_reg,  1'b0);
                X_VAL:     issue(CMD_WRITE, x_val,  1'b0);
                X_RADDR:   issue(CMD_WRITE, ADDR_R, 1'b0);
                X_RBYTE:   issue(CMD_READ,  8'h00,  (x_n != 3'd1));   // NACK the last
                X_RECOVER: issue(CMD_READ,  8'h00,  1'b0);  // 9 clocks, SDA released
                X_STOP:    issue(CMD_STOP,  8'h00,  1'b0);
                default:   x_state <= X_IDLE;
            endcase
        end

    end

end


// ------------------------------------------------------------
// MAIN SEQUENCE
// ------------------------------------------------------------

localparam [3:0] M_RECOVER    = 4'd0,
                 M_RESET      = 4'd1,
                 M_RESET_WAIT = 4'd2,
                 M_ID         = 4'd3,
                 M_CFG        = 4'd4,
                 M_POLL_WAIT  = 4'd5,
                 M_PTRS       = 4'd6,
                 M_DATA       = 4'd7,
                 M_FAIL       = 4'd8;

reg [3:0]  m_state;
reg [2:0]  cfg_idx;
reg        m_busy;                 // a transaction has been started
reg [31:0] timer;

// The configuration writes, in order. Mode is set last so the
// chip does not start sampling with half a configuration.
reg [7:0] cfg_reg, cfg_val;

always @(*) begin
    case (cfg_idx)
        3'd0: begin cfg_reg = REG_FIFO_CFG; cfg_val = FIFO_CONFIG; end
        3'd1: begin cfg_reg = REG_SPO2;     cfg_val = SPO2_CONFIG; end
        3'd2: begin cfg_reg = REG_LED1;     cfg_val = LED_RED_PA;  end
        3'd3: begin cfg_reg = REG_LED2;     cfg_val = LED_IR_PA;   end
        3'd4: begin cfg_reg = REG_FIFO_WR;  cfg_val = 8'h00;       end
        3'd5: begin cfg_reg = REG_FIFO_OVF; cfg_val = 8'h00;       end
        3'd6: begin cfg_reg = REG_FIFO_RD;  cfg_val = 8'h00;       end
        default: begin cfg_reg = REG_MODE;  cfg_val = 8'h03;       end   // SpO2 mode
    endcase
end

wire [4:0] fifo_wr = rx_buf[20:16];     // byte 0 of a 3-byte read
wire [4:0] fifo_rd = rx_buf[4:0];       // byte 2


task start_write(input [7:0] r, input [7:0] v);
    begin
        x_kind    <= 1'b0;
        x_recover <= 1'b0;
        x_reg     <= r;
        x_val     <= v;
        x_start   <= 1'b1;
        m_busy    <= 1'b1;
    end
endtask

task start_read(input [7:0] r, input [2:0] n);
    begin
        x_kind    <= 1'b1;
        x_recover <= 1'b0;
        x_reg     <= r;
        x_n       <= n;
        x_start   <= 1'b1;
        m_busy    <= 1'b1;
    end
endtask


always @(posedge clk) begin

    if (reset) begin
        m_state      <= M_RECOVER;
        cfg_idx      <= 3'd0;
        m_busy       <= 1'b0;
        timer        <= 32'd0;
        x_start      <= 1'b0;
        x_kind       <= 1'b0;
        x_recover    <= 1'b0;
        x_reg        <= 8'd0;
        x_val        <= 8'd0;
        x_n          <= 3'd0;
        red          <= 18'd0;
        ir           <= 18'd0;
        sample_valid <= 1'b0;
        sensor_ok    <= 1'b0;
    end

    else begin

        x_start      <= 1'b0;
        sample_valid <= 1'b0;

        // Any failed transaction sends us to M_FAIL.
        if (m_busy && x_done && x_fail) begin
            m_busy    <= 1'b0;
            sensor_ok <= 1'b0;
            timer     <= 32'd0;
            m_state   <= M_FAIL;
        end

        else case (m_state)

            // ------------------------------------------------
            M_RECOVER: begin
                if (!m_busy) begin
                    x_recover <= 1'b1;
                    x_start   <= 1'b1;
                    m_busy    <= 1'b1;
                end
                else if (x_done) begin
                    m_busy  <= 1'b0;
                    m_state <= M_RESET;
                end
            end

            // ------------------------------------------------
            M_RESET: begin
                if (!m_busy)
                    start_write(REG_MODE, 8'h40);
                else if (x_done) begin
                    m_busy  <= 1'b0;
                    timer   <= 32'd0;
                    m_state <= M_RESET_WAIT;
                end
            end

            M_RESET_WAIT: begin
                if (timer >= RESET_WAIT_CLKS - 1)
                    m_state <= M_ID;
                else
                    timer <= timer + 1'b1;
            end

            // ------------------------------------------------
            M_ID: begin
                if (!m_busy)
                    start_read(REG_PART_ID, 3'd1);
                else if (x_done) begin
                    m_busy <= 1'b0;
                    if (rx_buf[7:0] == PART_ID) begin
                        sensor_ok <= 1'b1;
                        cfg_idx   <= 3'd0;
                        m_state   <= M_CFG;
                    end
                    else begin
                        timer   <= 32'd0;
                        m_state <= M_FAIL;
                    end
                end
            end

            // ------------------------------------------------
            M_CFG: begin
                if (!m_busy)
                    start_write(cfg_reg, cfg_val);
                else if (x_done) begin
                    m_busy <= 1'b0;
                    if (cfg_idx == 3'd7) begin
                        timer   <= 32'd0;
                        m_state <= M_POLL_WAIT;
                    end
                    else
                        cfg_idx <= cfg_idx + 1'b1;
                end
            end

            // ------------------------------------------------
            M_POLL_WAIT: begin
                if (timer >= POLL_CLKS - 1)
                    m_state <= M_PTRS;
                else
                    timer <= timer + 1'b1;
            end

            M_PTRS: begin
                if (!m_busy)
                    start_read(REG_FIFO_WR, 3'd3);     // WR_PTR, OVF, RD_PTR
                else if (x_done) begin
                    m_busy <= 1'b0;
                    if (fifo_wr != fifo_rd)
                        m_state <= M_DATA;
                    else begin
                        timer   <= 32'd0;
                        m_state <= M_POLL_WAIT;
                    end
                end
            end

            M_DATA: begin
                if (!m_busy)
                    start_read(REG_FIFO_DAT, 3'd6);
                else if (x_done) begin
                    m_busy       <= 1'b0;
                    red          <= {rx_buf[41:40], rx_buf[39:24]};
                    ir           <= {rx_buf[17:16], rx_buf[15:0]};
                    sample_valid <= 1'b1;
                    m_state      <= M_PTRS;              // drain the rest
                end
            end

            // ------------------------------------------------
            M_FAIL: begin
                if (timer >= RETRY_CLKS - 1)
                    m_state <= M_RECOVER;
                else
                    timer <= timer + 1'b1;
            end

            default: m_state <= M_RECOVER;

        endcase

    end

end


endmodule

`default_nettype wire
