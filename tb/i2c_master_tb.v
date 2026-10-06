`timescale 1ns / 1ps
`default_nettype none

// ------------------------------------------------------------
// TESTBENCH: i2c_master_tb
//
// Drives i2c_master.v against the MAX30102 model and checks the
// bytes that land in the model's registers, and the bytes that
// come back out.
//
//   1. A register write lands in the right register.
//   2. A register read (write pointer, repeated START, read)
//      returns what was written, and auto-increments.
//   3. PART_ID reads as 0x15.
//   4. An absent slave produces NACK, not a hang.
//   5. A stuck-low SCL produces bus_error, not a hang, and the
//      master releases both lines afterwards.
//   6. START/STOP counts seen by the slave are what we sent.
//
//   iverilog -g2012 -o i2c_sim tb/i2c_master_tb.v tb/max30102_model.v rtl/i2c_master.v
//   vvp i2c_sim
// ------------------------------------------------------------

module i2c_master_tb;

    localparam integer CLK_HALF = 42;
    localparam integer CLK_HZ   = 12_000_000;
    localparam integer SCL_HZ   = 400_000;        // fast, model does not mind

    reg        clk   = 1'b0;
    reg        reset = 1'b1;

    reg        cmd_valid = 1'b0;
    reg  [1:0] cmd       = 2'd0;
    reg  [7:0] wr_data   = 8'd0;
    reg        rd_ack    = 1'b0;

    wire       busy, done, ack_ok, bus_error;
    wire [7:0] rd_data;
    wire       scl_oe, sda_oe;

    tri1       scl, sda;                           // pull-ups

    reg        present = 1'b1;

    integer errors = 0;

    always #CLK_HALF clk = ~clk;

    assign scl = scl_oe ? 1'b0 : 1'bz;
    assign sda = sda_oe ? 1'b0 : 1'bz;

    i2c_master #(
        .CLK_HZ       (CLK_HZ),
        .SCL_HZ       (SCL_HZ),
        .TIMEOUT_CLKS (2000)                       // short, for test 5
    ) dut (
        .clk(clk), .reset(reset),
        .cmd_valid(cmd_valid), .cmd(cmd), .wr_data(wr_data), .rd_ack(rd_ack),
        .busy(busy), .done(done), .rd_data(rd_data), .ack_ok(ack_ok),
        .bus_error(bus_error),
        .scl_oe(scl_oe), .sda_oe(sda_oe), .scl_in(scl), .sda_in(sda)
    );

    max30102_model slave (
        .scl(scl), .sda(sda),
        .red_in(18'd0), .ir_in(18'd0), .present(present)
    );


    // --------------------------------------------------------
    // HELPERS
    // --------------------------------------------------------

    task check_true(input condition, input [80*8:1] name);
        begin
            if (condition) $display("  PASS  %0s", name);
            else begin $display("  FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    task do_cmd(input [1:0] c, input [7:0] d, input a);
        begin
            @(negedge clk);
            cmd = c; wr_data = d; rd_ack = a; cmd_valid = 1'b1;
            @(negedge clk);
            cmd_valid = 1'b0;
            wait (done === 1'b1);
            #1;
        end
    endtask

    task i2c_start;              begin do_cmd(2'd0, 8'h00, 1'b0); end endtask
    task i2c_stop;               begin do_cmd(2'd3, 8'h00, 1'b0); end endtask
    task i2c_write(input [7:0] d); begin do_cmd(2'd1, d, 1'b0);  end endtask
    task i2c_read(input a);      begin do_cmd(2'd2, 8'h00, a);   end endtask

    task write_reg(input [7:0] r, input [7:0] v);
        begin
            i2c_start;
            i2c_write(8'hAE);
            i2c_write(r);
            i2c_write(v);
            i2c_stop;
        end
    endtask

    reg [7:0] got0, got1;

    task read_two(input [7:0] r);
        begin
            i2c_start;
            i2c_write(8'hAE);
            i2c_write(r);
            i2c_start;                      // repeated START
            i2c_write(8'hAF);
            i2c_read(1'b1); got0 = rd_data;
            i2c_read(1'b0); got1 = rd_data;
            i2c_stop;
        end
    endtask


    // --------------------------------------------------------
    // MAIN
    // --------------------------------------------------------

    integer starts_before;

    initial begin
        $dumpfile("i2c_master_tb.vcd");
        $dumpvars(0, i2c_master_tb);

        $display("");
        $display("========================================");
        $display(" I2C MASTER TEST");
        $display("========================================");
        $display("");

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (5) @(posedge clk);

        check_true(scl === 1'b1 && sda === 1'b1, "bus idles high");

        // ----------------------------------------------------
        $display("-- 1. register write --");
        write_reg(8'h0C, 8'h1F);
        check_true(ack_ok, "slave acknowledged");
        check_true(slave.regs[8'h0C] == 8'h1F, "LED1_PA register holds 0x1F");
        check_true(slave.bytes_written == 1, "exactly one data byte written");
        $display("");

        // ----------------------------------------------------
        $display("-- 2. register read with repeated START --");
        write_reg(8'h0D, 8'h2A);
        read_two(8'h0C);
        check_true(got0 == 8'h1F, "first byte is 0x1F (reg 0x0C)");
        check_true(got1 == 8'h2A, "second byte is 0x2A (reg 0x0D, auto-increment)");
        $display("");

        // ----------------------------------------------------
        $display("-- 3. PART_ID --");
        read_two(8'hFE);
        check_true(got0 == 8'h03 && got1 == 8'h15, "REV_ID 0x03, PART_ID 0x15");
        $display("");

        // ----------------------------------------------------
        $display("-- 4. absent slave --");
        present = 1'b0;
        i2c_start;
        i2c_write(8'hAE);
        check_true(!ack_ok, "no ACK from an absent slave");
        check_true(!bus_error, "and it is not reported as a bus error");
        i2c_stop;
        present = 1'b1;
        $display("");

        // ----------------------------------------------------
        $display("-- 5. stuck SCL --");
        i2c_start;
        force scl = 1'b0;                     // something holds the clock down
        @(negedge clk);
        cmd = 2'd1; wr_data = 8'hAE; cmd_valid = 1'b1;
        @(negedge clk);
        cmd_valid = 1'b0;
        wait (done === 1'b1); #1;
        check_true(bus_error, "bus_error reported");
        check_true(!busy, "master is no longer busy");
        release scl;
        repeat (10) @(posedge clk);
        check_true(scl_oe == 1'b0 && sda_oe == 1'b0, "both lines released after the error");
        check_true(scl === 1'b1 && sda === 1'b1, "bus back to idle");

        // And it still works afterwards.
        write_reg(8'h0C, 8'h33);
        check_true(slave.regs[8'h0C] == 8'h33, "recovers: a later write succeeds");
        $display("");

        // ----------------------------------------------------
        $display("-- 6. slave's view of START/STOP --");
        starts_before = slave.start_count;
        read_two(8'h0C);
        check_true(slave.start_count == starts_before + 2, "slave saw START + repeated START");
        check_true(slave.wrong_addr_count == 0, "never addressed the wrong device");
        $display("");

        $display("========================================");
        if (errors == 0) $display(" PASS - all checks passed");
        else             $display(" FAIL - %0d check(s) failed", errors);
        $display("========================================");
        $display("");
        $finish;
    end

    initial begin
        #20_000_000;
        $display(" TIMEOUT - a command never finished");
        $finish;
    end

endmodule

`default_nettype wire
