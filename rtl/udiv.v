`default_nettype none

// ============================================================
// MODULE: udiv
//
// PURPOSE:
//
// Unsigned integer division, one bit per clock.
//
//     quotient = numerator / denominator
//
// A divider built from plain combinational logic would be
// enormous and slow. This one does it the way you do long
// division by hand: one digit (here, one bit) at a time, over
// W clock cycles. At 12 MHz a 44-bit divide takes under 4 us,
// which is nothing against the 2.5 seconds between SpO2 updates.
//
// The method is "restoring division":
//
//   for each bit, from the top down:
//       shift one more numerator bit into the remainder
//       if remainder >= denominator:
//           remainder = remainder - denominator
//           this quotient bit = 1
//       else:
//           this quotient bit = 0
//
// Dividing by zero returns all ones (the largest value) and
// sets div_by_zero, so the caller can treat it as invalid.
//
// USED BY: spo2_calc.v, for the ratio-of-ratios.
// ============================================================

module udiv #(
    parameter integer W = 44
)(
    input  wire         clk,
    input  wire         reset,

    input  wire         start,       // one-clock pulse
    input  wire [W-1:0] numerator,
    input  wire [W-1:0] denominator,

    output reg  [W-1:0] quotient,
    output reg          done,        // one-clock pulse
    output reg          busy,
    output reg          div_by_zero
);


reg [W-1:0] num_shift;    // numerator bits still to be brought down
reg [W-1:0] den_hold;
reg [W:0]   remainder;    // one bit wider: can hold 2*den before compare
reg [$clog2(W+1)-1:0] count;

// The remainder with the next numerator bit shifted in.
wire [W:0] rem_next = {remainder[W-1:0], num_shift[W-1]};

// Does the denominator fit? (compare in W+1 bits)
wire       fits     = rem_next >= {1'b0, den_hold};


always @(posedge clk) begin

    if (reset) begin
        busy        <= 1'b0;
        done        <= 1'b0;
        quotient    <= {W{1'b0}};
        remainder   <= {(W+1){1'b0}};
        num_shift   <= {W{1'b0}};
        den_hold    <= {W{1'b0}};
        count       <= 0;
        div_by_zero <= 1'b0;
    end

    else begin

        done <= 1'b0;

        if (start && !busy) begin
            if (denominator == {W{1'b0}}) begin
                // Nothing sensible to do. Say so and finish at once.
                quotient    <= {W{1'b1}};
                div_by_zero <= 1'b1;
                done        <= 1'b1;
            end
            else begin
                busy        <= 1'b1;
                div_by_zero <= 1'b0;
                num_shift   <= numerator;
                den_hold    <= denominator;
                remainder   <= {(W+1){1'b0}};
                quotient    <= {W{1'b0}};
                count       <= 0;
            end
        end

        else if (busy) begin

            // Bring one numerator bit down, subtract if it fits,
            // and record the quotient bit.
            remainder <= fits ? (rem_next - {1'b0, den_hold}) : rem_next;
            quotient  <= {quotient[W-2:0], fits};
            num_shift <= {num_shift[W-2:0], 1'b0};

            if (count == W - 1) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
            else
                count <= count + 1'b1;
        end

    end

end


endmodule

`default_nettype wire
