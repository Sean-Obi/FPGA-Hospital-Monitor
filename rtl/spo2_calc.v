`default_nettype none

// ============================================================
// MODULE: spo2_calc
//
// PURPOSE:
//
// Turns the red and infrared light readings from the MAX30102
// into a blood-oxygen percentage.
//
// ------------------------------------------------------------
// THE PHYSICS, BRIEFLY
// ------------------------------------------------------------
//
// Each reading has two parts:
//
//   DC   the steady level - light through skin, bone and tissue
//   AC   the small wobble on top, from blood pulsing with each
//        heartbeat
//
// Oxygen-rich blood absorbs infrared more than red; oxygen-poor
// blood does the opposite. So the "ratio of ratios"
//
//          (AC_red / DC_red)
//     R = -------------------
//          (AC_ir  / DC_ir)
//
// tracks saturation. The standard textbook calibration is
//
//     SpO2 = 110 - 25 R
//
// (R = 0.5 -> 97.5 %). Real oximeters use a curve fitted on
// human volunteers; this straight line is the usual learning
// approximation and is accurate to a few percent in the normal
// range. It is not a clinical measurement.
//
// ------------------------------------------------------------
// HOW IT IS DONE IN INTEGERS
// ------------------------------------------------------------
//
// Samples are grouped into blocks of 2^BLOCK_LOG2 (256 at 100
// samples/s = 2.56 s, longer than one heartbeat even at 24 BPM).
// For each block and each colour:
//
//     DC = sum / 2^BLOCK_LOG2        (a shift, free)
//     AC = max - min
//
// Then, with R scaled by 100 so it stays an integer,
//
//     R100 = (AC_red * DC_ir * 100) / (DC_red * AC_ir)
//
// is one sequential division (udiv.v), and because 25/100 = 1/4,
//
//     SpO2 = 110 - R100 / 4  =  (442 - R100) >> 2   (rounded)
//
// No floating point anywhere.
//
// "No finger" is detected from the IR DC level: with nothing on
// the sensor almost no light returns and DC_ir is tiny. Those
// blocks report 0, which the display shows as "--".
// ============================================================

module spo2_calc #(
    parameter integer BLOCK_LOG2 = 8,       // 256 samples per block
    parameter integer FINGER_MIN = 30000    // IR DC below this = no finger
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [17:0] red,
    input  wire [17:0] ir,
    input  wire        sample_valid,

    output reg  [7:0]  spo2,          // 0..100, 0 = no finger / invalid
    output reg         spo2_valid,    // one-clock pulse, once per block
    output reg         finger,        // was a finger present in the last block

    // The intermediate numbers, for the testbench and for anyone
    // curious. Cost nothing if left unconnected.
    output reg  [17:0] dc_red_out,
    output reg  [17:0] dc_ir_out,
    output reg  [17:0] ac_red_out,
    output reg  [17:0] ac_ir_out,
    output reg  [15:0] r100_out
);


localparam integer N     = 1 << BLOCK_LOG2;
localparam integer SUM_W = 18 + BLOCK_LOG2;
localparam integer DIV_W = 44;                 // 18 + 18 + 7 bits, rounded up


// ------------------------------------------------------------
// BLOCK ACCUMULATORS
// ------------------------------------------------------------

reg [SUM_W-1:0] red_sum, ir_sum;
reg [17:0]      red_max, red_min, ir_max, ir_min;
reg [BLOCK_LOG2-1:0] count;

// The running values updated with the sample arriving now. The
// last sample of a block is folded in through these, so the
// block totals include it.
wire [SUM_W-1:0] red_sum_n = red_sum + red;
wire [SUM_W-1:0] ir_sum_n  = ir_sum  + ir;
wire [17:0] red_max_n = (red > red_max) ? red : red_max;
wire [17:0] red_min_n = (red < red_min) ? red : red_min;
wire [17:0] ir_max_n  = (ir  > ir_max)  ? ir  : ir_max;
wire [17:0] ir_min_n  = (ir  < ir_min)  ? ir  : ir_min;

wire block_done = sample_valid && (count == N - 1);

// Latched totals of the block just finished.
reg [17:0] dc_red, dc_ir, ac_red, ac_ir;


// ------------------------------------------------------------
// THE DIVIDER
// ------------------------------------------------------------

reg              div_start;
wire [DIV_W-1:0] div_quot;
wire             div_done, div_busy, div_dbz;

// 18 x 18 x 7 bits. Vivado puts these on DSP slices.
wire [DIV_W-1:0] numerator   = ac_red * dc_ir * 44'd100;
wire [DIV_W-1:0] denominator = dc_red * ac_ir;

udiv #(.W(DIV_W)) u_div (
    .clk         (clk),
    .reset       (reset),
    .start       (div_start),
    .numerator   (numerator),
    .denominator (denominator),
    .quotient    (div_quot),
    .done        (div_done),
    .busy        (div_busy),
    .div_by_zero (div_dbz)
);


// ------------------------------------------------------------
// STATE
// ------------------------------------------------------------

localparam [1:0] S_COLLECT = 2'd0,
                 S_DECIDE  = 2'd1,
                 S_DIVIDE  = 2'd2;

reg [1:0] state;

// (442 - R100) >> 2, clamped to 0..100.
function [7:0] spo2_from_r100(input [15:0] r);
    reg [15:0] t;
    begin
        if (r >= 16'd442)
            spo2_from_r100 = 8'd0;
        else begin
            t = (16'd442 - r) >> 2;
            spo2_from_r100 = (t > 16'd100) ? 8'd100 : t[7:0];
        end
    end
endfunction


always @(posedge clk) begin

    if (reset) begin
        state      <= S_COLLECT;
        red_sum    <= 0;  ir_sum  <= 0;
        red_max    <= 0;  ir_max  <= 0;
        red_min    <= 18'h3FFFF; ir_min <= 18'h3FFFF;
        count      <= 0;
        dc_red     <= 0;  dc_ir  <= 0;  ac_red <= 0;  ac_ir <= 0;
        spo2       <= 8'd0;
        spo2_valid <= 1'b0;
        finger     <= 1'b0;
        div_start  <= 1'b0;
        dc_red_out <= 0;  dc_ir_out <= 0;  ac_red_out <= 0;  ac_ir_out <= 0;
        r100_out   <= 0;
    end

    else begin

        spo2_valid <= 1'b0;
        div_start  <= 1'b0;

        // ---- accumulate, in every state ----
        //
        // Samples keep arriving while the divider runs. The
        // divider takes 44 clocks; samples are 120,000 apart, so
        // the next block is never disturbed.
        if (sample_valid) begin
            if (block_done) begin
                // Close the block with this sample included,
                // and start a fresh one.
                dc_red  <= red_sum_n[SUM_W-1:BLOCK_LOG2];
                dc_ir   <= ir_sum_n [SUM_W-1:BLOCK_LOG2];
                ac_red  <= red_max_n - red_min_n;
                ac_ir   <= ir_max_n  - ir_min_n;

                red_sum <= 0;  ir_sum <= 0;
                red_max <= 0;  ir_max <= 0;
                red_min <= 18'h3FFFF;  ir_min <= 18'h3FFFF;
                count   <= 0;
            end
            else begin
                red_sum <= red_sum_n;  ir_sum <= ir_sum_n;
                red_max <= red_max_n;  ir_max <= ir_max_n;
                red_min <= red_min_n;  ir_min <= ir_min_n;
                count   <= count + 1'b1;
            end
        end

        // ---- work out the number ----
        case (state)

            S_COLLECT: begin
                if (block_done)
                    state <= S_DECIDE;
            end

            S_DECIDE: begin
                dc_red_out <= dc_red;  dc_ir_out <= dc_ir;
                ac_red_out <= ac_red;  ac_ir_out <= ac_ir;

                if (dc_ir < FINGER_MIN || ac_ir == 0 || dc_red == 0) begin
                    // Nothing on the sensor, or a flat line.
                    finger     <= 1'b0;
                    spo2       <= 8'd0;
                    r100_out   <= 16'd0;
                    spo2_valid <= 1'b1;
                    state      <= S_COLLECT;
                end
                else begin
                    finger    <= 1'b1;
                    div_start <= 1'b1;
                    state     <= S_DIVIDE;
                end
            end

            S_DIVIDE: begin
                if (div_done) begin
                    // Anything over 16 bits is a nonsense ratio.
                    r100_out   <= (div_quot > 44'd65535) ? 16'd65535 : div_quot[15:0];
                    spo2       <= (div_quot > 44'd65535) ? 8'd0
                                                         : spo2_from_r100(div_quot[15:0]);
                    spo2_valid <= 1'b1;
                    state      <= S_COLLECT;
                end
            end

            default: state <= S_COLLECT;

        endcase

    end

end


endmodule

`default_nettype wire
