`timescale 1ns/1ps
module tb_frs_async_fifo;
    reg wr_clk = 1'b0;
    reg rd_clk = 1'b0;
    always #20 wr_clk = ~wr_clk;
    always #5 rd_clk = ~rd_clk;

    reg resetn = 1'b0;
    reg wr_en = 1'b0;
    reg [7:0] din = 8'd0;
    wire full;
    wire wr_overflow;
    reg rd_en = 1'b0;
    wire [7:0] dout;
    wire empty;
    integer read_count = 0;
    integer expected = 0;

    frs_async_fifo #(.WIDTH(8), .ADDR_WIDTH(3)) dut (
        .wr_clk(wr_clk), .wr_resetn(resetn), .wr_en(wr_en), .din(din),
        .full(full), .wr_overflow(wr_overflow),
        .rd_clk(rd_clk), .rd_resetn(resetn), .rd_en(rd_en),
        .dout(dout), .empty(empty)
    );

    always @(posedge rd_clk) begin
        if (resetn && rd_en && !empty) begin
            if (dout !== expected[7:0])
                $fatal(1, "FIFO order mismatch: got %0d, expected %0d", dout, expected);
            expected = expected + 1;
            read_count = read_count + 1;
        end
    end

    initial begin
        repeat (4) @(negedge wr_clk);
        resetn = 1'b1;

        for (integer i = 0; i < 8; i = i + 1) begin
            @(negedge wr_clk);
            while (full) @(negedge wr_clk);
            din = i[7:0];
            wr_en = 1'b1;
            @(negedge wr_clk);
            wr_en = 1'b0;
        end
        wait (full);
        @(negedge wr_clk);
        din = 8'hEE;
        wr_en = 1'b1;
        @(negedge wr_clk);
        wr_en = 1'b0;
        repeat (2) @(negedge wr_clk);
        if (!wr_overflow)
            $fatal(1, "FIFO failed to latch an overrun attempt");

        rd_en = 1'b1;
        wait (read_count == 8);
        @(negedge rd_clk);
        rd_en = 1'b0;
        wait (empty);
        if (read_count != 8)
            $fatal(1, "FIFO produced %0d words, expected 8", read_count);
        $display("PASS: asynchronous FIFO crosses clocks in order, fills, and flags overflow");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "asynchronous FIFO test timed out");
    end
endmodule
