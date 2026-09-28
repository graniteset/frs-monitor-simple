`timescale 1ns/1ps
module tb_iq_stream;
    reg clk;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg resetn = 1'b0;
    reg enable = 1'b0;
    reg [31:0] phase_step = 32'h10000000; // four 64-entry LUT steps/sample
    reg ready = 1'b0;
    wire [31:0] data;
    wire valid;

    iq_test_source #(.ON_SAMPLES(3), .OFF_SAMPLES(2)) dut (
        .aclk(clk), .aresetn(resetn), .enable(enable),
        .phase_step(phase_step), .m_axis_tdata(data),
        .m_axis_tvalid(valid), .m_axis_tready(ready)
    );

    reg mux_select = 1'b0;
    reg [31:0] a_data = 32'h11112222;
    reg a_valid = 1'b1;
    wire a_ready;
    reg [31:0] b_data = 32'h33334444;
    reg b_valid = 1'b1;
    wire b_ready;
    wire [31:0] mux_data;
    wire mux_valid;
    reg mux_ready = 1'b0;

    axis_iq_mux mux (
        .aclk(clk), .aresetn(resetn), .select(mux_select),
        .a_tdata(a_data), .a_tvalid(a_valid), .a_tready(a_ready),
        .b_tdata(b_data), .b_tvalid(b_valid), .b_tready(b_ready),
        .m_tdata(mux_data), .m_tvalid(mux_valid), .m_tready(mux_ready)
    );

    task consume_source;
        output [31:0] got;
        begin
            @(negedge clk);
            while (!valid) @(negedge clk);
            got = data;
            ready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            ready = 1'b0;
        end
    endtask

    reg [31:0] got;
    reg [31:0] stalled_data;
    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        enable = 1'b1;

        // First beat must remain stable while stalled, despite source enable
        // being removed after the beat has been presented.
        @(negedge clk);
        while (!valid) @(negedge clk);
        stalled_data = data;
        if (stalled_data !== {16'd32767, 16'd0}) $fatal(1, "wrong initial tone sample");
        repeat (3) begin
            @(posedge clk); #1;
            if (!valid || data !== stalled_data) $fatal(1, "source changed a stalled beat");
        end
        enable = 1'b0;
        @(posedge clk); #1;
        if (!valid || data !== stalled_data) $fatal(1, "disable changed an in-flight beat");
        @(negedge clk); enable = 1'b1;
        consume_source(got);
        if (got !== {16'd32767, 16'd0}) $fatal(1, "first accepted beat mismatch");

        consume_source(got);
        if (got !== {16'd30273, 16'd12539}) $fatal(1, "second tone sample mismatch");
        consume_source(got);
        if (got !== {16'd23170, 16'd23170}) $fatal(1, "third tone sample mismatch");
        consume_source(got);
        if (got !== 32'd0) $fatal(1, "first burst gap sample was not zero");
        consume_source(got);
        if (got !== 32'd0) $fatal(1, "second burst gap sample was not zero");
        consume_source(got);
        if (got !== {16'hCF05, 16'd30273}) $fatal(1, "tone did not resume after gap");

        // Mux must lock the selected source while downstream is stalled.
        @(negedge clk);
        mux_select = 1'b0;
        #1;
        if (!mux_valid || mux_data !== a_data || a_ready || b_ready)
            $fatal(1, "mux source A routing failed");
        @(posedge clk); #1;
        mux_select = 1'b1;
        #1;
        if (mux_data !== a_data || !mux_valid || a_ready || b_ready)
            $fatal(1, "mux did not lock stalled selection");
        mux_ready = 1'b1;
        @(posedge clk); #1;
        @(negedge clk);
        mux_ready = 1'b0;
        #1;
        if (mux_data !== b_data || b_ready || a_ready)
            $fatal(1, "mux did not switch after accepted beat");

        // Reset clears valid and restores initial deterministic phase.
        resetn = 1'b0;
        #1;
        if (valid) $fatal(1, "reset did not clear source valid");
        repeat (2) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        ready = 1'b0;
        enable = 1'b1;
        @(negedge clk);
        while (!valid) @(negedge clk);
        if (data !== {16'd32767, 16'd0}) $fatal(1, "reset did not restore phase");

        $display("PASS: IQ source frequency sequence, burst gaps, backpressure, reset, and mux");
        $finish;
    end
endmodule
