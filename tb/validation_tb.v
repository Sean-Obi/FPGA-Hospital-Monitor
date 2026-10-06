`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: validation_tb
//
// Runs real ECG through the pipeline and records every beat it
// finds, so the detector can be scored against a cardiologist's
// markings.
//
// This is the testbench that produces the number worth putting
// in the report. Every other testbench here checks that a block
// does what it was designed to do. This one asks a different
// question: on real patient data, how often is the design right?
//
// ------------------------------------------------------------
// HOW TO RUN IT
// ------------------------------------------------------------
//
//   python scripts/make_ecg_hex.py --record 100 --seconds 60
//
//   iverilog -g2012 -o val_sim tb/validation_tb.v \
//            rtl/heart_pipeline.v rtl/ecg_filter.v \
//            rtl/baseline_remove.v rtl/beat_detect.v \
//            rtl/bpm_calc.v rtl/bpm_div.v rtl/bpm_uart.v rtl/uart.v
//
//   vvp val_sim +samples=data/100_samples.hex +count=30000
//
//   python scripts/score_detection.py --record 100
//
// To try a different threshold without editing this file:
//
//   iverilog -g2012 -Pvalidation_tb.THRESHOLD=120 -o val_sim ...
//
// which is what the sweep in score_detection.py uses.
//
// ------------------------------------------------------------
// WHY THERE IS NO PASS OR FAIL HERE
// ------------------------------------------------------------
//
// The other testbenches know the right answer and can say PASS.
// This one produces a measurement. Whether 99.2% sensitivity is
// good is a judgement, not something the testbench can decide,
// so it writes the detections out and the scoring script works
// out the figures.
// ------------------------------------------------------------

module validation_tb #(

    // Overridable from the command line with -P, so a sweep can
    // try several without editing anything.
    parameter signed [15:0] THRESHOLD = 16'sd70,

    // Biggest recording this can hold. 150,000 samples at 500 Hz
    // is five minutes, which is far more than a validation run
    // needs and still allocates quickly.
    parameter integer MAX_SAMPLES = 150000

);

    localparam integer CLK_HALF = 42;      // ~12 MHz

    // Clock cycles between samples. Nothing here depends on the
    // real 500 Hz spacing - the pipeline only ever reacts to
    // sample_valid - so a small number keeps the run short.
    //
    // It has to leave room for bpm_div, which takes up to about
    // 255 clocks after each beat. Beats are hundreds of samples
    // apart, so 10 clocks per sample is plenty.
    localparam integer CLKS_PER_SAMPLE = 10;

    reg         clk          = 1'b0;
    reg         reset        = 1'b1;
    reg  [11:0] sample       = 12'd0;
    reg         sample_valid = 1'b0;

    wire        beat;
    wire [7:0]  bpm;
    wire        bpm_valid;
    wire        tx;

    always #CLK_HALF clk = ~clk;


    // --------------------------------------------------------
    // THE DESIGN
    // --------------------------------------------------------
    //
    // INCLUDE_BPM_UART is 0 because nothing is listening to the
    // serial line here, and leaving it out keeps the run quick.

    heart_pipeline #(
        .THRESHOLD        (THRESHOLD),
        .INCLUDE_BPM_UART (0)
    ) dut (
        .clk          (clk),
        .reset        (reset),
        .sample       (sample),
        .sample_valid (sample_valid),
        .beat         (beat),
        .bpm          (bpm),
        .bpm_valid    (bpm_valid),
        .tx           (tx)
    );


    // --------------------------------------------------------
    // THE RECORDING
    // --------------------------------------------------------

    reg [11:0] ecg [0:MAX_SAMPLES-1];

    reg [1023:0] samples_path;
    reg [1023:0] out_path;
    integer      sample_count;

    integer      out_file;
    integer      beats_found = 0;
    integer      i;

    // Which sample is being presented right now. This is the
    // number written out for each beat, so it can be lined up
    // against the annotation file.
    integer      sample_index = 0;


    // Record every beat, with the sample index it happened on.
    //
    // beat_detect raises beat one clock AFTER the sample that
    // caused it, so the index is stepped on in the same block
    // that feeds samples in, keeping the two in step.
    always @(posedge clk) begin
        if (beat && !reset) begin
            beats_found = beats_found + 1;
            $fwrite(out_file, "%0d\n", sample_index);
        end
    end


    // --------------------------------------------------------
    // MAIN
    // --------------------------------------------------------

    initial begin
        $display("");
        $display("========================================");
        $display(" VALIDATION RUN");
        $display("========================================");
        $display("");

        // Where to read from and write to.
        if (!$value$plusargs("samples=%s", samples_path)) begin
            $display("  ERROR: no input file given.");
            $display("");
            $display("  vvp val_sim +samples=data/100_samples.hex +count=30000");
            $display("");
            $finish;
        end

        if (!$value$plusargs("count=%d", sample_count)) begin
            $display("  ERROR: +count=<number of samples> is required.");
            $display("  It is printed by make_ecg_hex.py.");
            $display("");
            $finish;
        end

        if (sample_count > MAX_SAMPLES) begin
            $display("  WARNING: %0d samples is more than MAX_SAMPLES (%0d).",
                     sample_count, MAX_SAMPLES);
            $display("  Only the first %0d will be used.", MAX_SAMPLES);
            sample_count = MAX_SAMPLES;
        end

        if (!$value$plusargs("out=%s", out_path))
            out_path = "data/detected_beats.txt";

        // Blank the array first. $readmemh leaves anything it
        // does not fill as X, and an X sample would quietly
        // poison the filter.
        for (i = 0; i < MAX_SAMPLES; i = i + 1)
            ecg[i] = 12'd0;

        $readmemh(samples_path, ecg);

        out_file = $fopen(out_path, "w");
        if (out_file == 0) begin
            $display("  ERROR: could not write to %0s", out_path);
            $display("  Does the data/ directory exist?");
            $finish;
        end

        $display("  samples file : %0s", samples_path);
        $display("  samples      : %0d  (%0.1f seconds at 500 Hz)",
                 sample_count, sample_count / 500.0);
        $display("  threshold    : %0d", THRESHOLD);
        $display("  writing to   : %0s", out_path);
        $display("");
        $display("  running...");

        // Let the design settle, then release reset.
        repeat (20) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (10) @(posedge clk);

        // Feed the recording through, one sample at a time.
        for (i = 0; i < sample_count; i = i + 1) begin
            sample_index = i;

            @(negedge clk);
            sample       = ecg[i];
            sample_valid = 1'b1;

            @(negedge clk);
            sample_valid = 1'b0;

            repeat (CLKS_PER_SAMPLE - 2) @(negedge clk);

            // Something to watch, so a long run does not look
            // like it has hung.
            if ((i % 10000) == 0 && i > 0)
                $display("    %0d / %0d samples, %0d beats so far",
                         i, sample_count, beats_found);
        end

        // Let the last beat work its way out.
        repeat (1000) @(posedge clk);

        $fclose(out_file);

        $display("");
        $display("  beats detected : %0d", beats_found);
        $display("  mean rate      : %0.1f BPM",
                 (sample_count > 0)
                     ? (beats_found * 500.0 * 60.0 / sample_count)
                     : 0.0);
        $display("");
        $display("  Now score it:");
        $display("    python scripts/score_detection.py");
        $display("");

        $finish;
    end

endmodule

`default_nettype wire
