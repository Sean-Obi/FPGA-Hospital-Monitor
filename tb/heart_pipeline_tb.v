`timescale 1ns/1ps
module heart_pipeline_tb;
    localparam CPB           = 4;    // UART clocks per bit (tiny for sim)
    localparam CLKS_PER_SAMP = 20;   // real board: 24,000 (500 Hz). Tiny here for speed.

    reg         clk = 0;
    reg         reset = 1;
    reg  [11:0] sample = 0;
    reg         sample_valid = 0;
    wire        beat;
    wire [7:0]  bpm;
    wire        tx;

    heart_pipeline #(.CLKS_PER_BIT(CPB)) dut (
        .clk(clk), .reset(reset), .sample(sample), .sample_valid(sample_valid),
        .beat(beat), .bpm(bpm), .tx(tx));

    always #41.667 clk = ~clk;   // 12 MHz

    // ---- Serial monitor: decode tx and print each line ----
    reg [7:0] rx; integer i;
    reg [8*8-1:0] line = 0;
    initial forever begin
        @(negedge tx);
        repeat (CPB/2) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            repeat (CPB) @(posedge clk);
            rx[i] = tx;
        end
        repeat (CPB) @(posedge clk);
        if (rx == 10) begin
            $display("   serial monitor: \"%0s\"", line);
            line = 0;
        end
        else if (rx != 13)
            line = {line[8*7-1:0], rx};
    end

    // count beats so we can see beat_detect working
    integer beats = 0;
    always @(posedge clk) if (beat) beats = beats + 1;

    // ---- Fake PPG sensor: pulses riding on a DC level ----
    function integer pulse(input integer t, input integer gap);
        integer p;
        begin
            p = t % gap;
            if      (p < 40)  pulse = p * 5;              // fast rise to +200
            else if (p < 200) pulse = 200 - (p - 40);     // slow fall to +40
            else if (p < 400) pulse = 40 - (p - 200) / 5; // back to 0
            else              pulse = 0;
        end
    endfunction

    task send_sample(input integer s);
        begin
            @(posedge clk); sample <= s; sample_valid <= 1;
            @(posedge clk); sample_valid <= 0;
            repeat (CLKS_PER_SAMP - 2) @(posedge clk);
        end
    endtask

    integer t;
    task heart_rate(input integer bpm_wanted, input integer n_beats, input integer level);
        integer gap;
        begin
            gap = 30000 / bpm_wanted;                 // samples per beat
            $display("---- fake heart at %0d BPM (%0d samples/beat), DC level %0d ----",
                     bpm_wanted, gap, level);
            for (t = 0; t < gap * n_beats; t = t + 1)
                send_sample(level + pulse(t, gap));
        end
    endtask

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, heart_pipeline_tb);
        repeat (5) @(posedge clk);
        reset = 0;

        heart_rate(75,  8, 2000);   // settles to " 75" (first lines are start-up junk)
        heart_rate(60,  6, 2000);   // settles to " 60"
        heart_rate(120, 10, 2600);  // settles to "120", despite the DC level jumping

        $display("total beats detected: %0d", beats);
        $finish;
    end
endmodule