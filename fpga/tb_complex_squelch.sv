`timescale 1ns/1ps
module tb_complex_squelch;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg signed [15:0] s_i = 16'sd0;
    reg signed [15:0] s_q = 16'sd0;
    reg s_valid = 1'b0;
    wire s_ready;
    reg [32:0] threshold_q30 = 33'd1_000_000;
    wire signed [15:0] m_i;
    wire signed [15:0] m_q;
    wire m_valid;
    reg m_ready = 1'b1;
    wire [32:0] average_power_q30;
    integer i;
    reg [32:0] held_power;

    complex_squelch #(.ALPHA_Q15(15'd3277)) dut (
        .aclk(clk), .aresetn(resetn), .s_i(s_i), .s_q(s_q),
        .s_valid(s_valid), .s_ready(s_ready), .threshold_q30(threshold_q30),
        .m_i(m_i), .m_q(m_q), .m_valid(m_valid), .m_ready(m_ready),
        .average_power_q30(average_power_q30)
    );

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;

        // A 0.1-full-scale carrier exceeds the programmed linear threshold.
        for (i = 0; i < 32; i = i + 1) begin
            @(negedge clk);
            s_valid = 1'b1;
            s_i = 16'sd3277;
            s_q = 16'sd0;
            #1;
            if (!m_valid || !s_ready || m_i != 16'sd3277)
                $fatal(1, "squelch failed to open on above-threshold carrier");
            @(posedge clk);
        end

        // Silence drives the EMA below threshold; output remains muted.
        for (i = 0; i < 100; i = i + 1) begin
            @(negedge clk);
            s_i = 16'sd0;
            #1;
            if (m_i != 16'sd0 || m_q != 16'sd0)
                $fatal(1, "squelch passed a zero-valued input");
            @(posedge clk);
        end
        if (average_power_q30 >= threshold_q30)
            $fatal(1, "power estimate did not decay below threshold");

        // Low-level noise remains closed.
        for (i = 0; i < 100; i = i + 1) begin
            @(negedge clk);
            s_i = 16'sd100;
            #1;
            if (m_i != 16'sd0)
                $fatal(1, "squelch opened on below-threshold noise");
            @(posedge clk);
        end

        // Backpressure must freeze the EMA and leave a valid sample stable.
        @(negedge clk);
        s_i = 16'sd3277;
        m_ready = 1'b0;
        #1;
        if (!m_valid || s_ready || m_i != 16'sd3277)
            $fatal(1, "squelch stream backpressure behavior is incorrect");
        held_power = average_power_q30;
        repeat (4) @(posedge clk);
        #1;
        if (average_power_q30 != held_power || m_i != 16'sd3277)
            $fatal(1, "squelch changed state/data while output was stalled");

        @(negedge clk);
        m_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_valid = 1'b0;
        $display("PASS: Q1.15 power EMA squelch opens, closes, and holds under backpressure");
        $finish;
    end
endmodule
