`timescale 1ns / 1ps

// ============================================================
//  SIMULATION ONLY - DO NOT ADD THIS FILE TO VIVADO SYNTHESIS
// ============================================================
//
// A behavioural model of the MAX30102 pulse oximeter chip, seen
// from its I2C pins. It lets i2c_master.v, max30102_driver.v
// and top.v be tested without the real part.
//
// It models:
//
//   * an I2C slave at address 0x57: START, repeated START, STOP,
//     address match, ACK/NACK, register pointer auto-increment
//   * the register map that matters: FIFO pointers, FIFO data,
//     FIFO/mode/SpO2 config, LED currents, PART_ID
//   * the 32-deep FIFO, filled at a fixed rate with whatever is
//     on red_in / ir_in, and drained six bytes at a time through
//     FIFO_DATA exactly as the datasheet describes
//   * the RESET bit in MODE_CONFIG
//   * "not connected": with present = 0 it never acknowledges,
//     which is what an unplugged sensor looks like
//
// It does NOT model: optical anything, interrupts, the die
// temperature sensor, multi-LED mode, or the real part's timing
// down to the nanosecond. None of those matter to the driver.
//
// HOW THE TESTBENCH FEEDS IN "LIGHT"
//
//   model.red_in / model.ir_in are latched into the FIFO every
//   SAMPLE_PERIOD_NS, the way the real ADC samples the photodiode.
//
// The bus wires must be declared tri1 (pulled up) in the testbench.
// ============================================================

`default_nettype none

module max30102_model #(
    parameter [6:0]   ADDR             = 7'h57,
    parameter integer SAMPLE_PERIOD_NS = 10_000_000     // 100 Hz
)(
    inout  wire        scl,
    inout  wire        sda,
    input  wire [17:0] red_in,
    input  wire [17:0] ir_in,
    input  wire        present
);

// ------------------------------------------------------------
// BUS DRIVER
// ------------------------------------------------------------

reg sda_drive = 1'b0;                     // 1 = pull low
assign sda = sda_drive ? 1'b0 : 1'bz;
assign scl = 1'bz;                        // never stretches


// ------------------------------------------------------------
// REGISTERS AND FIFO
// ------------------------------------------------------------

reg [7:0]  regs [0:255];
reg [17:0] fifo_red [0:31];
reg [17:0] fifo_ir  [0:31];

// Pointers live in their registers so a read of 0x04/0x06 just
// works. 5-bit wrap is done by hand.
`define WR_PTR  regs[8'h04]
`define OVF_CNT regs[8'h05]
`define RD_PTR  regs[8'h06]

integer start_count       = 0;
integer stop_count        = 0;
integer bytes_written     = 0;
integer bytes_read        = 0;
integer samples_generated = 0;
integer samples_consumed  = 0;
integer reset_count       = 0;
integer wrong_addr_count  = 0;   // transactions aimed at someone else

// The ID the chip reports. A testbench can change this to
// pretend some other I2C device is sitting at address 0x57.
reg [7:0] part_id = 8'h15;

task reset_regs;
    integer k;
    begin
        for (k = 0; k < 256; k = k + 1) regs[k] = 8'h00;
        regs[8'hFE] = 8'h03;              // REV_ID
        regs[8'hFF] = part_id;            // PART_ID
        fifo_byte   = 0;
    end
endtask

reg [2:0] fifo_byte = 0;                  // which of the 6 bytes is next

initial reset_regs;


// ------------------------------------------------------------
// THE SAMPLE GENERATOR
// ------------------------------------------------------------
//
// In SpO2 mode (MODE = 011) and not shut down, push a sample
// into the FIFO at the configured rate.

wire        mode_spo2 = (regs[8'h09][2:0] == 3'b011);
wire        shutdown  = regs[8'h09][7];
wire        rollover  = regs[8'h08][4];

always begin
    #(SAMPLE_PERIOD_NS);
    if (present && mode_spo2 && !shutdown) begin : push
        reg [4:0] next_wr;
        next_wr = `WR_PTR[4:0] + 5'd1;

        fifo_red[`WR_PTR[4:0]] = red_in;
        fifo_ir [`WR_PTR[4:0]] = ir_in;

        if (next_wr == `RD_PTR[4:0]) begin
            // FIFO full.
            `OVF_CNT = (`OVF_CNT == 8'h1F) ? 8'h1F : `OVF_CNT + 1;
            if (rollover) begin
                `RD_PTR = {3'b000, `RD_PTR[4:0] + 5'd1};
                `WR_PTR = {3'b000, next_wr};
            end
            // else: sample dropped, pointer stays
        end
        else
            `WR_PTR = {3'b000, next_wr};

        samples_generated = samples_generated + 1;
    end
end


// ------------------------------------------------------------
// BYTE SOURCE / SINK
// ------------------------------------------------------------

reg [7:0] ptr = 8'h00;        // register pointer
reg       got_ptr = 1'b0;     // first byte of a write sets it

// Supply the next byte for a master read.
function [7:0] peek_byte;
    input dummy;
    begin
        if (ptr == 8'h07) begin
            case (fifo_byte)
                0: peek_byte = {6'b0, fifo_red[`RD_PTR[4:0]][17:16]};
                1: peek_byte = fifo_red[`RD_PTR[4:0]][15:8];
                2: peek_byte = fifo_red[`RD_PTR[4:0]][7:0];
                3: peek_byte = {6'b0, fifo_ir[`RD_PTR[4:0]][17:16]};
                4: peek_byte = fifo_ir[`RD_PTR[4:0]][15:8];
                default: peek_byte = fifo_ir[`RD_PTR[4:0]][7:0];
            endcase
        end
        else
            peek_byte = regs[ptr];
    end
endfunction

// Called once the byte has gone out: advance whatever needs advancing.
task consumed_byte;
    begin
        bytes_read = bytes_read + 1;
        if (ptr == 8'h07) begin
            // FIFO_DATA does not auto-increment the register
            // pointer, only the FIFO read pointer, after 6 bytes.
            if (fifo_byte == 5) begin
                fifo_byte = 0;
                if (`RD_PTR[4:0] != `WR_PTR[4:0]) begin
                    `RD_PTR = {3'b000, `RD_PTR[4:0] + 5'd1};
                    samples_consumed = samples_consumed + 1;
                end
            end
            else
                fifo_byte = fifo_byte + 1;
        end
        else
            ptr = ptr + 1;
    end
endtask

// Take a byte written by the master.
task accept_byte(input [7:0] b);
    begin
        if (!got_ptr) begin
            ptr     = b;
            got_ptr = 1'b1;
            if (ptr == 8'h07) fifo_byte = 0;
        end
        else begin
            bytes_written = bytes_written + 1;
            if (ptr == 8'h09 && b[6]) begin
                // RESET: everything to defaults, bit clears itself.
                reset_regs;
                reset_count = reset_count + 1;
                regs[8'h09] = 8'h40;
                fork begin
                    #50_000;                      // 50 us
                    regs[8'h09] = regs[8'h09] & 8'hBF;
                end join_none
            end
            else begin
                regs[ptr] = b;
                if (ptr == 8'h04 || ptr == 8'h06)
                    regs[ptr] = {3'b000, b[4:0]};
            end
            ptr = ptr + 1;
        end
    end
endtask


// ------------------------------------------------------------
// THE I2C STATE MACHINE
// ------------------------------------------------------------

localparam [2:0] I_IDLE     = 3'd0,
                 I_ADDR     = 3'd1,   // receiving the address byte
                 I_ACK_ADDR = 3'd2,   // we are pulling SDA low
                 I_WDATA    = 3'd3,   // receiving a data byte
                 I_ACK_W    = 3'd4,   // acknowledging it
                 I_RDATA    = 3'd5,   // sending a byte
                 I_ACK_R    = 3'd6;   // master's ACK/NACK clock

reg [2:0] st   = I_IDLE;
reg [7:0] sh   = 8'd0;
reg [3:0] bitn = 4'd0;
reg       rw   = 1'b0;           // 1 = master reads
reg       master_acked = 1'b0;
reg [7:0] out_byte = 8'd0;

// START: SDA falls while SCL is high.
always @(negedge sda) begin
    if (scl === 1'b1) begin
        st          = I_ADDR;
        bitn        = 0;
        sh          = 0;
        got_ptr     = 1'b0;
        sda_drive   = 1'b0;
        start_count = start_count + 1;
    end
end

// STOP: SDA rises while SCL is high.
always @(posedge sda) begin
    if (scl === 1'b1 && st != I_IDLE) begin
        st         = I_IDLE;
        sda_drive  = 1'b0;
        stop_count = stop_count + 1;
    end
end

// Rising SCL: read a bit (or the master's ACK).
always @(posedge scl) begin
    case (st)
        I_ADDR, I_WDATA: begin
            sh   = {sh[6:0], sda};
            bitn = bitn + 1;
        end
        I_ACK_R: master_acked = (sda === 1'b0);
        default: ;
    endcase
end

// Falling SCL: change what we drive.
always @(negedge scl) begin
    case (st)

        I_ADDR: begin
            if (bitn == 8) begin
                if (sh[7:1] == ADDR && present) begin
                    rw        = sh[0];
                    sda_drive = 1'b1;              // ACK
                    st        = I_ACK_ADDR;
                end
                else begin
                    if (sh[7:1] != ADDR)
                        wrong_addr_count = wrong_addr_count + 1;
                    st = I_IDLE;                   // not for us: stay quiet
                end
            end
        end

        I_ACK_ADDR: begin
            sda_drive = 1'b0;
            bitn      = 0;
            if (rw) begin
                out_byte  = peek_byte(1'b0);
                sda_drive = ~out_byte[7];
                bitn      = 1;
                st        = I_RDATA;
            end
            else
                st = I_WDATA;
        end

        I_WDATA: begin
            if (bitn == 8) begin
                accept_byte(sh);
                sda_drive = 1'b1;                  // ACK
                st        = I_ACK_W;
            end
        end

        I_ACK_W: begin
            sda_drive = 1'b0;
            bitn      = 0;
            st        = I_WDATA;
        end

        I_RDATA: begin
            if (bitn < 8) begin
                sda_drive = ~out_byte[7 - bitn];
                bitn      = bitn + 1;
            end
            else begin
                sda_drive = 1'b0;                  // let the master ACK/NACK
                consumed_byte;
                st = I_ACK_R;
            end
        end

        I_ACK_R: begin
            if (master_acked) begin
                out_byte  = peek_byte(1'b0);
                sda_drive = ~out_byte[7];
                bitn      = 1;
                st        = I_RDATA;
            end
            else begin
                sda_drive = 1'b0;
                st        = I_IDLE;                // NACK: done sending
            end
        end

        default: ;
    endcase
end

`undef WR_PTR
`undef OVF_CNT
`undef RD_PTR

endmodule

`default_nettype wire
