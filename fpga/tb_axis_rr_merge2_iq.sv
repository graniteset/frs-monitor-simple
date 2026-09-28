`timescale 1ns/1ps
module tb_axis_rr_merge2_iq;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    wire [36:0] s0_data;
    wire [36:0] s1_data;
    reg s0_valid = 1'b1;
    reg s1_valid = 1'b1;
    wire s0_ready;
    wire s1_ready;
    wire [36:0] m_data;
    wire m_valid;
    reg m_ready = 1'b0;
    integer sent0 = 0;
    integer sent1 = 0;
    integer got0 = 0;
    integer got1 = 0;
    integer cycles = 0;
    reg was_stalled = 1'b0;
    reg [36:0] held_data = 37'd0;
    integer tag;
    integer sequence_number;

    assign s0_data = {5'd1, sent0[15:0], 16'h5a5a};
    assign s1_data = {5'd8, sent1[15:0], 16'ha5a5};

    axis_rr_merge2_iq dut (
        .aclk(clk), .aresetn(resetn),
        .s0_data(s0_data), .s0_valid(s0_valid), .s0_ready(s0_ready),
        .s1_data(s1_data), .s1_valid(s1_valid), .s1_ready(s1_ready),
        .m_data(m_data), .m_valid(m_valid), .m_ready(m_ready)
    );

    always @(negedge clk)
        if (resetn) m_ready = ((cycles % 7) == 2) || ((cycles % 7) == 3) || ((cycles % 7) == 4);

    always @(posedge clk) begin
        if (resetn) begin
            cycles = cycles + 1;
            if (was_stalled && (!m_valid || m_data !== held_data))
                $fatal(1, "merge output changed while stalled");
            was_stalled = m_valid && !m_ready;
            if (was_stalled) held_data = m_data;
            if (s0_valid && s0_ready) sent0 = sent0 + 1;
            if (s1_valid && s1_ready) sent1 = sent1 + 1;
            if (m_valid && m_ready) begin
                tag = m_data[36:32];
                sequence_number = m_data[31:16];
                if (tag == 1) begin
                    if (sequence_number != got0 || m_data[15:0] != 16'h5a5a)
                        $fatal(1, "band-1 order/data mismatch");
                    got0 = got0 + 1;
                end else if (tag == 8) begin
                    if (sequence_number != got1 || m_data[15:0] != 16'ha5a5)
                        $fatal(1, "band-2 order/data mismatch");
                    got1 = got1 + 1;
                end else begin
                    $fatal(1, "unexpected channel tag %0d", tag);
                end
            end
            if (sent0 == 8) s0_valid = 1'b0;
            if (sent1 == 8) s1_valid = 1'b0;
            if (got0 == 8 && got1 == 8) begin
                $display("PASS: two-band round-robin merge preserves order and stalls cleanly");
                $finish;
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        repeat (200) @(posedge clk);
        $fatal(1, "merge timeout sent %0d/%0d received %0d/%0d", sent0, sent1, got0, got1);
    end
endmodule
