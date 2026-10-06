`timescale 1ns / 1ps

// ============================================================
//  SIMULATION ONLY - DO NOT ADD THIS FILE TO VIVADO SYNTHESIS
// ============================================================
//
// This file defines a module called XADC.
//
// On the real FPGA, XADC is a piece of hardware physically built
// into the Artix-7 chip. Vivado knows about it automatically.
//
// Icarus Verilog does not, which is why xadc_reader.v could never
// be simulated before. This file is a stand-in: a simplified
// Verilog description that behaves enough like the real XADC for
// xadc_reader.v to be tested against it.
//
// It models:
//
//   * single-channel mode (INIT_41[15:12] = 3): convert the
//     channel in INIT_40[4:0] over and over
//   * continuous sequence mode (INIT_41[15:12] = 2): go round the
//     VAUX channels enabled in INIT_49, lowest first, forever,
//     pulsing EOS at the end of each pass
//   * EOC pulsing when each conversion finishes, with CHANNEL
//     showing which one it was
//   * the DRP read handshake (DEN in, DRDY + DO back a few clocks
//     later) returning that channel's own result register
//   * the 12-bit result sitting in the top bits of DO, i.e. DO[15:4]
//
// It also CHECKS that every DRP read asks for the register of the
// channel that most recently finished, and counts it if not.
//
// It does NOT model: analog voltages, the alarms, the on-chip
// temperature sensor, JTAG, averaging, or the exact number of
// clocks the real part takes. None of those matter to xadc_reader.
//
// ------------------------------------------------------------
// HOW THE TESTBENCH FEEDS IN AN "ANALOG" VALUE
// ------------------------------------------------------------
//
// Real analog voltages cannot be simulated here, so instead this
// model holds plain 12-bit registers the testbench writes to:
//
//     dut.xadc_inst.analog_code        = 12'd2048;   // VAUX4  (ECG)
//     dut.xadc_inst.analog_code_vaux12 = 12'd1049;   // VAUX12 (temperature)
//
// Each conversion latches whatever the relevant one holds at that
// moment, exactly as a real ADC latches whatever voltage is on
// the pin. In single-channel mode analog_code is used whatever
// the channel.
// ============================================================

`default_nettype none

module XADC #(
    parameter [15:0] INIT_40 = 16'h0000,   // config reg 0: channel select
    parameter [15:0] INIT_41 = 16'h0000,   // config reg 1: sequencer mode
    parameter [15:0] INIT_42 = 16'h0800,   // config reg 2: clock divider
    parameter [15:0] INIT_43 = 16'h0000,
    parameter [15:0] INIT_44 = 16'h0000,
    parameter [15:0] INIT_45 = 16'h0000,
    parameter [15:0] INIT_46 = 16'h0000,
    parameter [15:0] INIT_47 = 16'h0000,
    parameter [15:0] INIT_48 = 16'h0000,   // sequence: on-chip channels
    parameter [15:0] INIT_49 = 16'h0000,   // sequence: VAUX channels
    parameter [15:0] INIT_4A = 16'h0000,
    parameter [15:0] INIT_4B = 16'h0000,
    parameter [15:0] INIT_4C = 16'h0000,
    parameter [15:0] INIT_4D = 16'h0000,
    parameter [15:0] INIT_4E = 16'h0000,
    parameter [15:0] INIT_4F = 16'h0000,

    parameter SIM_DEVICE = "7SERIES",
    parameter SIM_MONITOR_FILE = "design.txt",

    // ---- knobs that exist only in this model ----

    // How many DCLK cycles one conversion takes.
    // The real part at ADCCLK = DCLK/2 takes roughly 26 ADCCLK,
    // which is about 52 DCLK.
    parameter integer MODEL_CONV_DCLKS = 52,

    // How many DCLK cycles after DEN before DRDY comes back.
    // Deliberately not 1, so the reader cannot accidentally rely
    // on the result arriving immediately.
    parameter integer MODEL_DRDY_DCLKS = 3

)(
    output reg  [7:0]  ALM,
    output reg         BUSY,
    output reg  [4:0]  CHANNEL,
    output reg  [15:0] DO,
    output reg         DRDY,
    output reg         EOC,
    output reg         EOS,
    output reg         JTAGBUSY,
    output reg         JTAGLOCKED,
    output reg         JTAGMODIFIED,
    output reg  [4:0]  MUXADDR,
    output reg         OT,

    input  wire        CONVST,
    input  wire        CONVSTCLK,
    input  wire        DCLK,
    input  wire        RESET,
    input  wire [6:0]  DADDR,
    input  wire        DEN,
    input  wire        DWE,
    input  wire [15:0] DI,
    input  wire [15:0] VAUXN,
    input  wire [15:0] VAUXP,
    input  wire        VN,
    input  wire        VP
);


// ------------------------------------------------------------
// WHICH CHANNELS, IN WHAT ORDER
// ------------------------------------------------------------

localparam [3:0] SEQ_MODE   = INIT_41[15:12];
localparam       SEQ_SINGLE = (SEQ_MODE == 4'd3);

// The list of channels to convert, built once at start-up.
reg [4:0]  seq_list [0:15];
integer    seq_len;
integer    seq_idx;

integer    i;
initial begin
    seq_len = 0;
    if (SEQ_SINGLE) begin
        seq_list[0] = INIT_40[4:0];
        seq_len     = 1;
    end
    else begin
        // Continuous sequence: VAUX channels from INIT_49, bit i
        // meaning VAUX[i], channel number 0x10 + i.
        for (i = 0; i < 16; i = i + 1)
            if (INIT_49[i]) begin
                seq_list[seq_len] = 5'h10 + i;
                seq_len = seq_len + 1;
            end
        if (seq_len == 0) begin
            $display("  XADC MODEL: sequence mode with no VAUX channels - using INIT_40");
            seq_list[0] = INIT_40[4:0];
            seq_len     = 1;
        end
    end
end


// ------------------------------------------------------------
// MODEL STATE
// ------------------------------------------------------------

// The "analog voltages", as 12-bit codes. The testbench writes
// to these directly. See the header comment.
reg [11:0] analog_code;           // VAUX4 (and anything else)
reg [11:0] analog_code_vaux12;    // VAUX12

function [11:0] code_for(input [4:0] ch);
    begin
        if (ch == 5'h1C) code_for = analog_code_vaux12;
        else             code_for = analog_code;
    end
endfunction

// One result register per channel.
reg [11:0] result_regs [0:31];

// The channel whose conversion most recently finished. A DRP
// read is expected to ask for exactly this register.
reg [4:0]  last_channel;

integer conv_count;

reg [7:0]  drp_pipe;
reg [6:0]  daddr_latched;

// Counts how many times xadc_reader asked for the wrong address.
integer daddr_errors;


initial begin
    ALM          = 8'd0;
    BUSY         = 1'b0;
    CHANNEL      = 5'd0;
    DO           = 16'd0;
    DRDY         = 1'b0;
    EOC          = 1'b0;
    EOS          = 1'b0;
    JTAGBUSY     = 1'b0;
    JTAGLOCKED   = 1'b0;
    JTAGMODIFIED = 1'b0;
    MUXADDR      = 5'd0;
    OT           = 1'b0;

    analog_code        = 12'd0;
    analog_code_vaux12 = 12'd0;
    for (i = 0; i < 32; i = i + 1) result_regs[i] = 12'd0;
    last_channel  = 5'd0;
    conv_count    = 0;
    seq_idx       = 0;
    drp_pipe      = 8'd0;
    daddr_latched = 7'd0;
    daddr_errors  = 0;
end


// ------------------------------------------------------------
// CONVERSION LOOP
// ------------------------------------------------------------
//
// Count MODEL_CONV_DCLKS clocks, latch the analog value for the
// current channel into its result register, pulse EOC (and EOS
// at the end of a pass), move to the next channel, repeat.

always @(posedge DCLK) begin

    if (RESET) begin
        conv_count   <= 0;
        seq_idx      <= 0;
        EOC          <= 1'b0;
        EOS          <= 1'b0;
        BUSY         <= 1'b0;
        CHANNEL      <= seq_list[0];
        last_channel <= seq_list[0];
    end
    else begin

        EOC <= 1'b0;
        EOS <= 1'b0;

        if (conv_count >= MODEL_CONV_DCLKS - 1) begin
            conv_count <= 0;

            // This is the moment the ADC "samples the pin".
            result_regs[seq_list[seq_idx]] <= code_for(seq_list[seq_idx]);
            last_channel <= seq_list[seq_idx];
            CHANNEL      <= seq_list[seq_idx];

            EOC  <= 1'b1;
            BUSY <= 1'b0;

            if (seq_idx == seq_len - 1) begin
                seq_idx <= 0;
                EOS     <= 1'b1;
            end
            else
                seq_idx <= seq_idx + 1;
        end
        else begin
            conv_count <= conv_count + 1;
            BUSY       <= 1'b1;
        end

    end

end


// ------------------------------------------------------------
// DRP READ HANDSHAKE
// ------------------------------------------------------------
//
// Take note of the address, wait a few clocks, then put the
// result on DO and raise DRDY for one clock.

always @(posedge DCLK) begin

    if (RESET) begin
        DRDY          <= 1'b0;
        DO            <= 16'd0;
        drp_pipe      <= 8'd0;
        daddr_latched <= 7'd0;
    end
    else begin

        drp_pipe <= {drp_pipe[6:0], (DEN && !DWE)};

        if (DEN && !DWE) begin
            daddr_latched <= DADDR;

            if (DADDR !== {2'b00, last_channel}) begin
                daddr_errors = daddr_errors + 1;
                $display("  XADC MODEL: DRP read of 0x%02h but channel 0x%02h just finished, at t=%0t",
                         DADDR, last_channel, $time);
            end
        end

        DRDY <= 1'b0;

        if (drp_pipe[MODEL_DRDY_DCLKS-1]) begin
            DRDY <= 1'b1;

            // Status registers 0x10..0x1F are the VAUX results.
            // Anything else returns junk, so a wrong address
            // shows up as obviously wrong data.
            if (daddr_latched[6:5] == 2'b00 && daddr_latched[4] == 1'b1)
                DO <= {result_regs[daddr_latched[4:0]], 4'b0000};
            else
                DO <= 16'hDEAD;
        end

    end

end


endmodule

`default_nettype wire
