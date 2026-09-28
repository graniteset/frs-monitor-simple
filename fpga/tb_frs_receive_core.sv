`timescale 1ns/1ps
module tb_frs_receive_core;
    localparam integer CHANNELS = 22;
    localparam integer RAW_SAMPLES = 8192; // 32 PFB frames per branch
    localparam integer EXPECTED_PER_CHANNEL = 16; // ÷2 audio from 32 IQ frames

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
    integer count_by_channel [1:CHANNELS];
    integer channel;
    integer sample_index;
    integer drain_cycles = 0;

    frs_receive_core dut (
        .aclk(clk), .aresetn(resetn), .s_adc_i(adc_i), .s_adc_q(adc_q),
        .s_valid(s_valid), .s_ready(s_ready), .threshold_q30(33'd0),
        .m_audio_data(audio_data), .m_audio_valid(audio_valid),
        .m_audio_ready(1'b1), .band1_overrun(band1_overrun),
        .band2_overrun(band2_overrun), .invalid_channel(invalid_channel)
    );

    initial begin
        for (integer idx = 1; idx <= CHANNELS; idx = idx + 1)
            count_by_channel[idx] = 0;
    end

    always @(posedge clk) begin
        if (resetn && audio_valid) begin
            channel = audio_data[20:16];
            if (channel < 1 || channel > CHANNELS)
                $fatal(1, "bad top-level audio tag %0d", channel);
            if (audio_data[15:0] !== 16'd0)
                $fatal(1, "zero-input top produced nonzero audio %0d on channel %0d", $signed(audio_data[15:0]), channel);
            count_by_channel[channel] = count_by_channel[channel] + 1;
        end
        if (resetn && (band1_overrun || band2_overrun || invalid_channel))
            $fatal(1, "top-level overrun or invalid channel flagged");
    end

    task send_raw_sample;
        begin
            @(negedge clk);
            adc_i = 12'sd0;
            adc_q = 12'sd0;
            s_valid = 1'b1;
            do @(posedge clk); while (!s_ready);
            @(negedge clk);
            s_valid = 1'b0;
            // Approximate the 6.4 MS/s ADC cadence at a 100 MHz fabric clock.
            repeat (15) @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        for (sample_index = 0; sample_index < RAW_SAMPLES; sample_index = sample_index + 1)
            send_raw_sample();

        while (drain_cycles < 500_000) begin
            @(posedge clk);
            drain_cycles = drain_cycles + 1;
            channel = 1;
            while (channel <= CHANNELS && count_by_channel[channel] == EXPECTED_PER_CHANNEL)
                channel = channel + 1;
            if (channel > CHANNELS) begin
                $display("PASS: full dual-band receive core emits all 22 tagged audio channels");
                $finish;
            end
        end
        for (channel = 1; channel <= CHANNELS; channel = channel + 1)
            if (count_by_channel[channel] != EXPECTED_PER_CHANNEL)
                $fatal(1, "channel %0d produced %0d outputs, expected %0d", channel,
                       count_by_channel[channel], EXPECTED_PER_CHANNEL);
        $fatal(1, "top-level drain timeout");
    end
endmodule
