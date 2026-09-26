`timescale 1ns/1ps
module tb_frs_channel_audio;
    localparam integer INPUT_COUNT = 2048;
    localparam integer OUTPUT_COUNT = 1024;
    localparam integer TOLERANCE_LSB = 20;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg signed [15:0] s_i = 16'sd0;
    reg signed [15:0] s_q = 16'sd0;
    reg s_valid = 1'b0;
    wire s_ready;
    reg [32:0] threshold_q30 = 33'd1_000_000;
    wire [20:0] m_data;
    wire m_valid;
    wire m_ready = 1'b1;
    wire [32:0] channel_power_q30;
    reg [31:0] input_mem [0:INPUT_COUNT-1];
    reg [31:0] expected_mem [0:OUTPUT_COUNT-1];
    integer input_index = 0;
    integer output_index = 0;
    integer error_value;
    integer max_error = 0;
    integer timeout_cycles = 0;

    frs_channel_audio #(.CHANNEL_ID(5'd7), .CHANNEL_GAIN_Q15(16'sd8192)) dut (
        .aclk(clk), .aresetn(resetn), .s_i(s_i), .s_q(s_q),
        .s_valid(s_valid), .s_ready(s_ready), .threshold_q30(threshold_q30),
        .m_data(m_data), .m_valid(m_valid), .m_ready(m_ready),
        .channel_power_q30(channel_power_q30)
    );

    initial begin
        $readmemh("fpga/vectors/fm_input.memh", input_mem);
        $readmemh("fpga/vectors/audio_expected.memh", expected_mem);
    end

    always @(negedge clk) begin
        if (resetn && input_index < INPUT_COUNT) begin
            s_valid = 1'b1;
            s_i = input_mem[input_index][31:16];
            s_q = input_mem[input_index][15:0];
        end else begin
            s_valid = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (resetn) begin
            if (s_valid && s_ready)
                input_index = input_index + 1;
            if (m_valid && m_ready) begin
                if (m_data[20:16] != 5'd7)
                    $fatal(1, "channel audio tag mismatch");
                if (output_index >= OUTPUT_COUNT)
                    $fatal(1, "channel audio path produced too many outputs");
                error_value = $signed(m_data[15:0]) - $signed(expected_mem[output_index][31:16]);
                if (error_value < 0) error_value = -error_value;
                if (error_value > max_error) max_error = error_value;
                if (error_value > TOLERANCE_LSB)
                    $fatal(1, "full audio path mismatch at %0d: got %0d expected %0d error %0d LSB",
                           output_index, $signed(m_data[15:0]),
                           $signed(expected_mem[output_index][31:16]), error_value);
                output_index = output_index + 1;
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        while (output_index < OUTPUT_COUNT && timeout_cycles < 500_000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        if (input_index != INPUT_COUNT || output_index != OUTPUT_COUNT)
            $fatal(1, "channel audio stream count mismatch: input %0d output %0d",
                   input_index, output_index);
        $display("PASS: complete single-channel audio path matches GNU Radio (max error %0d LSB)", max_error);
        $finish;
    end
endmodule
