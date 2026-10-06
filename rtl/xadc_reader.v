`default_nettype none

// ============================================================
// MODULE: xadc_reader
//
// PURPOSE:
//
// Reads TWO analog voltages with the Artix-7's built-in ADC (the
// XADC) and hands them to the rest of the design as tidy 500 Hz
// samples:
//
//     sample       the ECG, from the AD8232       (DIP pin 15, VAUX4)
//     temp_sample  the TMP36 via its buffer       (DIP pin 16, VAUX12)
//
// Both are 12 bits, 0..4095, where 4095 is 3.3 V at the pin.
//
// ------------------------------------------------------------
// HOW THE XADC IS DRIVEN
// ------------------------------------------------------------
//
// The XADC is a real piece of hardware inside the chip, not a
// module we wrote. We instantiate it, configure it through its
// INIT_xx parameters, and talk to it through the DRP, a little
// register bus. Three things happen in a loop:
//
//   1. The XADC is in "continuous sequence" mode, so it converts
//      VAUX4, then VAUX12, then VAUX4 ... forever, about 100,000
//      times a second each. Far faster than we need.
//
//   2. Every time a conversion finishes it pulses EOC and shows
//      which channel it was on CHANNEL. We note the channel, and
//      on the next clock ask the DRP for that channel's result
//      register (address = channel number).
//
//   3. A few clocks later DRDY pulses and DO holds the result,
//      12 bits in the top of a 16-bit word. We store it in
//      latest_ecg or latest_temp depending on which channel it was.
//
// Then, independently, every sample_tick (500 Hz) we copy both
// "latest" values to the outputs and pulse sample_valid. That is
// what turns a fast, free-running converter into a clean, fixed
// rate sample stream.
//
// ------------------------------------------------------------
// WHY THE ADDRESS IS LATCHED
// ------------------------------------------------------------
//
// With one channel it did not matter: the address was always
// 0x14. With two, the read must ask for the channel that JUST
// finished, so the channel number is captured at the EOC pulse
// and the read is issued one clock later from that copy. The
// behavioural model in tb/xadc_model.v checks every read asks
// for the right register.
// ============================================================

module xadc_reader (
    input  wire        clk,
    input  wire        reset,

    // 500 Hz, from sample_tick.v
    input  wire        sample_tick,

    // The analog pins. The _n halves are grounded on the Cmod A7.
    input  wire        vauxp_ecg,      // VAUX4  = DIP pin 15
    input  wire        vauxn_ecg,
    input  wire        vauxp_temp,     // VAUX12 = DIP pin 16
    input  wire        vauxn_temp,

    output reg  [11:0] sample,         // ECG
    output reg  [11:0] temp_sample,    // temperature sensor
    output reg         sample_valid    // one-clock pulse, both valid
);


// The channel numbers, as they appear on CHANNEL and as DRP
// addresses of the result registers.
localparam [4:0] CH_ECG  = 5'h14;      // VAUX4
localparam [4:0] CH_TEMP = 5'h1C;      // VAUX12


// ------------------------------------------------------------
// XADC SIGNALS
// ------------------------------------------------------------

wire [15:0] xadc_do;
wire        xadc_drdy;
wire        xadc_eoc;
wire        xadc_busy;
wire [4:0]  xadc_channel;

// The read: issued one clock after EOC, with the channel latched.
reg         read_now;
reg  [6:0]  read_addr;

always @(posedge clk) begin
    if (reset) begin
        read_now  <= 1'b0;
        read_addr <= 7'd0;
    end
    else begin
        read_now <= xadc_eoc;
        if (xadc_eoc)
            read_addr <= {2'b00, xadc_channel};
    end
end


// ------------------------------------------------------------
// THE XADC ITSELF
// ------------------------------------------------------------

XADC #(
    // Config register 0.
    // In sequence mode the channel bits here are ignored.
    // No averaging, unipolar, continuous.
    .INIT_40(16'h0000),

    // Config register 1.
    // Bits 15:12 = 0010 = continuous sequence mode: go round
    // the channels enabled in INIT_48/INIT_49 forever.
    .INIT_41(16'h2000),

    // Config register 2: ADC clock = DCLK / 2 = 6 MHz.
    .INIT_42(16'h0200),

    // Sequence channel selection.
    // INIT_48 picks on-chip channels (temperature, supplies) -
    // none wanted. INIT_49 picks VAUX channels: bit 4 = VAUX4,
    // bit 12 = VAUX12.
    .INIT_48(16'h0000),
    .INIT_49(16'h1010),

    // No averaging, unipolar, default settling, for every channel.
    .INIT_4A(16'h0000),
    .INIT_4B(16'h0000),
    .INIT_4C(16'h0000),
    .INIT_4D(16'h0000),
    .INIT_4E(16'h0000),
    .INIT_4F(16'h0000),

    .SIM_DEVICE("7SERIES")
) xadc_inst (
    .DCLK      (clk),
    .RESET     (reset),

    .CONVST    (1'b0),
    .CONVSTCLK (1'b0),

    // VAUXP[15:0]: our two pins land at bits 4 and 12.
    .VAUXP     ({3'b0, vauxp_temp, 7'b0, vauxp_ecg, 4'b0}),
    .VAUXN     ({3'b0, vauxn_temp, 7'b0, vauxn_ecg, 4'b0}),
    .VP        (1'b0),
    .VN        (1'b0),

    // DRP: read only.
    .DADDR     (read_addr),
    .DEN       (read_now),
    .DI        (16'b0),
    .DWE       (1'b0),
    .DO        (xadc_do),
    .DRDY      (xadc_drdy),

    .EOC       (xadc_eoc),
    .EOS       (),
    .BUSY      (xadc_busy),
    .CHANNEL   (xadc_channel),

    .ALM       (),
    .OT        (),
    .MUXADDR   (),
    .JTAGBUSY  (),
    .JTAGLOCKED(),
    .JTAGMODIFIED()
);


// ------------------------------------------------------------
// STORE EACH RESULT, RELEASE BOTH AT 500 Hz
// ------------------------------------------------------------

reg [11:0] latest_ecg;
reg [11:0] latest_temp;

always @(posedge clk) begin

    if (reset) begin
        latest_ecg   <= 12'd0;
        latest_temp  <= 12'd0;
        sample       <= 12'd0;
        temp_sample  <= 12'd0;
        sample_valid <= 1'b0;
    end

    else begin
        sample_valid <= 1'b0;

        if (xadc_drdy) begin
            // 12-bit result in DO[15:4]. Route by the address we asked for.
            if (read_addr[4:0] == CH_ECG)
                latest_ecg  <= xadc_do[15:4];
            else if (read_addr[4:0] == CH_TEMP)
                latest_temp <= xadc_do[15:4];
        end

        if (sample_tick) begin
            sample       <= latest_ecg;
            temp_sample  <= latest_temp;
            sample_valid <= 1'b1;
        end
    end

end


endmodule

`default_nettype wire
