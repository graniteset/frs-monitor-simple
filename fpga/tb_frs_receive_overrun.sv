`timescale 1ns/1ps
module tb_frs_receive_overrun;
    localparam integer RAW_SAMPLES = 4096;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg signed [11:0] adc_i = 12'sd0;
    reg signed [11:0] adc_q = 12'sd0;
    reg s_valid = 1'b0;
    wire s_ready;
    wire [20:0] audio_data;
    wire audio_valid;
    wire band1_overrun;
    wire band2_overrun;
    wire invalid_channel;
    integer accepted = 0;
    integer idx;

    frs_receive_core dut (
        .aclk(clk), .aresetn(resetn), .s_adc_i(adc_i), .s_adc_q(adc_q),
        .s_valid(s_valid), .s_ready(s_ready), .threshold_q30(33'd0),
        .m_audio_data(audio_data), .m_audio_valid(audio_valid),
        .m_audio_ready(1'b0), .band1_overrun(band1_overrun),
        .band2_overrun(band2_overrun), .invalid_channel(invalid_channel)
    );

    always @(posedge clk) begin
        if (resetn && s_valid && s_ready)
            accepted = accepted + 1;
        if (resetn && invalid_channel)
            $fatal(1, "unexpected invalid channel tag");
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        for (idx = 0; idx < RAW_SAMPLES; idx = idx + 1) begin
            @(negedge clk);
            adc_i = 12'sd0;
            adc_q = 12'sd0;
            s_valid = 1'b1;
            do @(posedge clk); while (!s_ready);
            @(negedge clk);
            s_valid = 1'b0;
            repeat (15) @(posedge clk);
        end
        s_valid = 1'b0;
        repeat (20_000) @(posedge clk);
        if (accepted != RAW_SAMPLES)
            $fatal(1, "input handshakes %0d/%0d", accepted, RAW_SAMPLES);
        if (!(band1_overrun || band2_overrun))
            $fatal(1, "unserviced output stall was not reported as PFB overrun");
        $display("PASS: output stall across DDC/PFB boundaries accepts %0d inputs and asserts sticky overrun (band1=%0b band2=%0b)",
                 accepted, band1_overrun, band2_overrun);
        $finish;
    end
endmodule
