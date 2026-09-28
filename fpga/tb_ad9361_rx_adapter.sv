`timescale 1ns/1ps

module tb_ad9361_rx_adapter;
    reg rx_clk = 1'b0;
    always #5 rx_clk = ~rx_clk;

    reg [15:0] adc_data_i = 16'd0;
    reg [15:0] adc_data_q = 16'd0;
    reg adc_valid_i = 1'b0;
    reg adc_valid_q = 1'b0;
    reg adc_enable_i = 1'b0;
    reg adc_enable_q = 1'b0;
    reg core_ready = 1'b1;

    wire signed [11:0] sample_i_tc;
    wire signed [11:0] sample_q_tc;
    wire valid_tc, mismatch_tc, drop_tc;
    wire signed [11:0] sample_i_ob;
    wire signed [11:0] sample_q_ob;
    wire valid_ob, mismatch_ob, drop_ob;

    frs_ad9361_rx_adapter #(.OFFSET_BINARY_INPUT(0)) two_complement (
        .rx_clk(rx_clk), .adc_data_i(adc_data_i), .adc_data_q(adc_data_q),
        .adc_valid_i(adc_valid_i), .adc_valid_q(adc_valid_q),
        .adc_enable_i(adc_enable_i), .adc_enable_q(adc_enable_q),
        .core_ready(core_ready), .sample_i(sample_i_tc), .sample_q(sample_q_tc),
        .sample_valid(valid_tc), .pair_mismatch(mismatch_tc), .drop_event(drop_tc)
    );

    frs_ad9361_rx_adapter #(.OFFSET_BINARY_INPUT(1)) offset_binary (
        .rx_clk(rx_clk), .adc_data_i(adc_data_i), .adc_data_q(adc_data_q),
        .adc_valid_i(adc_valid_i), .adc_valid_q(adc_valid_q),
        .adc_enable_i(adc_enable_i), .adc_enable_q(adc_enable_q),
        .core_ready(core_ready), .sample_i(sample_i_ob), .sample_q(sample_q_ob),
        .sample_valid(valid_ob), .pair_mismatch(mismatch_ob), .drop_event(drop_ob)
    );

    task check(input condition, input [8*80-1:0] message);
        begin
            if (!condition) $fatal(1, "%0s", message);
        end
    endtask

    initial begin
        #1;
        adc_data_i = {4'hA, 12'h7FF};
        adc_data_q = {4'h5, 12'h800};
        adc_valid_i = 1'b1;
        adc_valid_q = 1'b1;
        adc_enable_i = 1'b1;
        adc_enable_q = 1'b1;
        #1;
        check(valid_tc && valid_ob, "paired enabled ADI samples should be valid");
        check(sample_i_tc == 12'sd2047 && sample_q_tc == -12'sd2048,
              "two's-complement mode must use the low 12 ADC bits");
        check(sample_i_ob == -12'sd1 && sample_q_ob == 12'sd0,
              "offset-binary mode must flip the ADC sign bit");
        check(!mismatch_tc && !drop_tc && !drop_ob,
              "matched valid samples and ready core must not report errors");

        // A 16-bit word may carry sign extension in the upper bits; they are
        // intentionally ignored in favor of the 12-bit converter payload.
        adc_data_i = 16'hF123;
        adc_data_q = 16'h0123;
        #1;
        check(sample_i_tc == 12'sh123 && sample_q_tc == 12'sh123,
              "adapter must ignore optional 16-bit sign-extension bits");

        adc_valid_q = 1'b0;
        #1;
        check(!valid_tc && mismatch_tc,
              "unpaired I/Q valid signals must be suppressed and flagged");
        adc_valid_q = 1'b1;
        adc_enable_i = 1'b0;
        #1;
        check(!valid_tc && mismatch_tc,
              "unpaired I/Q enable signals must be suppressed and flagged");
        adc_enable_i = 1'b1;
        core_ready = 1'b0;
        #1;
        check(valid_tc && drop_tc && drop_ob,
              "non-backpressurable valid sample must report downstream drop");

        $display("PASS: ADI AD9361 16-bit RX words map to signed 12-bit IQ with pair/drop checks");
        $finish;
    end
endmodule
