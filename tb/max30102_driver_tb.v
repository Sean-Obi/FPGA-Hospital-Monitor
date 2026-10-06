`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: max30102_driver_tb
//
// Runs max30102_driver.v against the MAX30102 model and checks:
//
//   1. The chip is reset once and ends up configured exactly as
//      the parameters say, with SpO2 mode set LAST.
//   2. sensor_ok rises only after PART_ID has been read.
//   3. Samples come out with the right 18-bit values, including
//      the ends of the range (bit packing of the six bytes).
//   4. Every sample the chip produced is delivered exactly once,
//      and the FIFO never overflows.
//   5. An absent sensor: sensor_ok stays low, no hang, and the
//      driver recovers by itself once the sensor appears.
//   6. A wrong PART_ID is rejected.
//
//   iverilog -g2012 -o drv_sim tb/max30102_driver_tb.v tb/max30102_model.v \
//            rtl/max30102_driver.v rtl/i2c_master.v
//   vvp drv_sim
//
// Timing is scaled down (fast bus, short waits) because nothing
// here depends on the real milliseconds.
// ------------------------------------------------------------

module max30102_driver_tb;

    localparam integer CLK_HALF = 42;

    reg          clk   = 1'b0;
    reg          reset = 1'b1;

    wire [17:0]  red, ir;
    wire         sample_valid, sensor_ok;
    wire         scl_oe, sda_oe;
    tri1         scl, sda;

    reg  [17:0]  red_in  = 18'd0;
    reg  [17:0]  ir_in   = 18'd0;
    reg          present = 1'b1;

    integer errors = 0;

    always #CLK_HALF clk = ~clk;

    assign scl = scl_oe ? 1'b0 : 1'bz;
    assign sda = sda_oe ? 1'b0 : 1'bz;

    max30102_driver #(
        .CLK_HZ          (12_000_000),
        .SCL_HZ          (400_000),
        .RESET_WAIT_CLKS (200),
        .POLL_CLKS       (100),
        .RETRY_CLKS      (3000),
        .FIFO_CONFIG     (8'h10),
        .SPO2_CONFIG     (8'h27),
        .LED_RED_PA      (8'h1F),
        .LED_IR_PA       (8'h24)
    ) dut (
        .clk(clk), .reset(reset),
        .red(red), .ir(ir), .sample_valid(sample_valid), .sensor_ok(sensor_ok),
        .scl_oe(scl_oe), .sda_oe(sda_oe), .scl_in(scl), .sda_in(sda)
    );

    // One "sample" every 1 ms of simulated time. The bus here runs at
    // 400 kHz, so the driver needs about 0.35 ms per sample; on real
    // hardware it is 100 kHz and 10 ms, the same comfortable ratio.
    max30102_model #(.SAMPLE_PERIOD_NS(1_000_000)) chip (
        .scl(scl), .sda(sda), .red_in(red_in), .ir_in(ir_in), .present(present)
    );


    // --------------------------------------------------------
    // MONITORS
    // --------------------------------------------------------

    integer samples_out = 0;
    integer valid_run   = 0;
    integer width_errs  = 0;
    reg [17:0] last_red, last_ir;

    // Track the order of the configuration writes.
    integer mode_write_order = -1;
    integer write_order      = 0;
    always @(chip.bytes_written) begin
        write_order = chip.bytes_written;
        if (chip.ptr == 8'h0A && chip.regs[8'h09] == 8'h03)   // mode just set (ptr is now 0x0A)
            mode_write_order = write_order;
    end

    always @(posedge clk) begin
        if (sample_valid) begin
            samples_out = samples_out + 1;
            last_red    = red;
            last_ir     = ir;
            valid_run   = valid_run + 1;
            if (valid_run > 1) width_errs = width_errs + 1;
        end
        else valid_run = 0;
    end


    task check_true(input condition, input [80*8:1] name);
        begin
            if (condition) $display("  PASS  %0s", name);
            else begin $display("  FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    task wait_samples(input integer n);
        integer target;
        begin
            target = samples_out + n;
            wait (samples_out >= target);
            @(posedge clk); #1;
        end
    endtask


    // --------------------------------------------------------
    // MAIN
    // --------------------------------------------------------

    integer gen_before, out_before;

    initial begin
        $dumpfile("max30102_driver_tb.vcd");
        $dumpvars(0, max30102_driver_tb);

        $display("");
        $display("========================================");
        $display(" MAX30102 DRIVER TEST");
        $display("========================================");
        $display("");

        red_in = 18'd100000;
        ir_in  = 18'd150000;

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // ----------------------------------------------------
        $display("-- 1. initialisation --");
        wait (sensor_ok === 1'b1);
        wait (chip.regs[8'h09] == 8'h03);          // mode set = config finished
        @(posedge clk); #1;

        check_true(chip.reset_count == 1,             "chip was reset once");
        check_true(chip.regs[8'h08] == 8'h10,         "FIFO_CONFIG = 0x10");
        check_true(chip.regs[8'h0A] == 8'h27,         "SPO2_CONFIG = 0x27");
        check_true(chip.regs[8'h0C] == 8'h1F,         "LED1 (red) current = 0x1F");
        check_true(chip.regs[8'h0D] == 8'h24,         "LED2 (IR) current = 0x24");
        check_true(chip.regs[8'h09] == 8'h03,         "MODE_CONFIG = SpO2 mode");
        check_true(mode_write_order == chip.bytes_written,
                                                      "mode was the LAST register written");
        check_true(chip.wrong_addr_count == 0,        "only address 0x57 was used");
        $display("");

        // ----------------------------------------------------
        $display("-- 2. samples --");
        wait_samples(3);
        check_true(last_red == 18'd100000 && last_ir == 18'd150000,
                   "red=100000 ir=150000 delivered");

        red_in = 18'h3FFFF; ir_in = 18'd0;          // the two ends of 18 bits
        wait_samples(3);
        check_true(last_red == 18'h3FFFF && last_ir == 18'd0,
                   "red=0x3FFFF ir=0 (bit packing at the ends of range)");

        red_in = 18'd1; ir_in = 18'h2AAAA;
        wait_samples(3);
        check_true(last_red == 18'd1 && last_ir == 18'h2AAAA,
                   "red=1 ir=0x2AAAA (alternating bit pattern)");

        check_true(width_errs == 0, "sample_valid is always one clock wide");
        $display("");

        // ----------------------------------------------------
        $display("-- 3. nothing lost, nothing duplicated --");
        gen_before = chip.samples_generated;
        out_before = samples_out;
        wait_samples(40);
        // Give the driver a moment to drain anything in flight.
        #2_000_000;
        check_true((samples_out - out_before) == (chip.samples_generated - gen_before),
                   "delivered count equals generated count");
        $display("        (%0d generated, %0d delivered)",
                 chip.samples_generated - gen_before, samples_out - out_before);
        check_true(chip.regs[8'h05] == 8'h00, "FIFO never overflowed");
        $display("");

        // ----------------------------------------------------
        $display("-- 4. absent sensor --");
        @(negedge clk);
        reset = 1'b1;
        present = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Long enough to try, fail, wait RETRY_CLKS, and try again.
        repeat (12_000) @(posedge clk);
        check_true(sensor_ok === 1'b0, "sensor_ok stays low with nothing on the bus");
        check_true(dut.m_state == dut.M_FAIL || dut.m_state <= dut.M_ID,
                   "driver is retrying, not hung");
        check_true(scl === 1'b1 && sda === 1'b1, "bus is released while waiting");

        present = 1'b1;
        wait (sensor_ok === 1'b1);
        wait (chip.regs[8'h09] == 8'h03);
        check_true(1'b1, "recovers on its own when the sensor appears");
        wait_samples(2);
        check_true(1'b1, "and samples flow again");
        $display("");

        // ----------------------------------------------------
        $display("-- 5. wrong PART_ID --");
        chip.part_id = 8'h11;                        // something else at 0x57
        @(negedge clk);
        reset = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (12_000) @(posedge clk);
        check_true(sensor_ok === 1'b0, "sensor_ok stays low for the wrong part");
        check_true(chip.regs[8'h09] != 8'h03, "and it was never configured");
        chip.part_id = 8'h15;
        $display("");

        $display("========================================");
        if (errors == 0) $display(" PASS - all checks passed");
        else             $display(" FAIL - %0d check(s) failed", errors);
        $display("========================================");
        $display("");
        $finish;
    end

    initial begin
        #200_000_000;
        $display(" TIMEOUT - driver never got there. State %0d", dut.m_state);
        $finish;
    end

endmodule

`default_nettype wire
