`timescale 1ns/1ps
module tb_audio_fir_decimator;
    localparam integer INPUT_COUNT = 2048;
    localparam integer OUTPUT_COUNT = 1024;
    localparam integer TOLERANCE_LSB = 8;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg signed [15:0] s_audio_q15 = 16'sd0;
    reg s_valid = 1'b0;
    wire s_ready;
    wire signed [15:0] m_audio_q15;
    wire m_valid;
    wire m_ready = 1'b1;
    reg [31:0] input_mem [0:INPUT_COUNT-1];
    reg [31:0] expected_mem [0:OUTPUT_COUNT-1];
    integer input_index = 0;
    integer output_index = 0;
    integer error_value;
    integer max_error = 0;
    integer timeout_cycles = 0;

    audio_fir_decimator dut (
        .aclk(clk), .aresetn(resetn), .s_audio_q15(s_audio_q15),
        .s_valid(s_valid), .s_ready(s_ready), .m_audio_q15(m_audio_q15),
        .m_valid(m_valid), .m_ready(m_ready)
    );

    initial begin
        $readmemh("fpga/vectors/audio_input.memh", input_mem);
        $readmemh("fpga/vectors/audio_fir_expected.memh", expected_mem);
    end

    always @(negedge clk) begin
        if (resetn && input_index < INPUT_COUNT) begin
            s_valid = 1'b1;
            s_audio_q15 = input_mem[input_index][31:16];
        end else begin
            s_valid = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (resetn) begin
            if (s_valid && s_ready)
                input_index = input_index + 1;
            if (m_valid && m_ready) begin
                if (output_index >= OUTPUT_COUNT)
                    $fatal(1, "audio FIR produced too many outputs");
                error_value = $signed(m_audio_q15) - $signed(expected_mem[output_index][31:16]);
                if (error_value < 0) error_value = -error_value;
                if (error_value > max_error) max_error = error_value;
                if (error_value > TOLERANCE_LSB)
                    $fatal(1, "audio FIR mismatch at %0d: got %0d expected %0d error %0d LSB",
                           output_index, $signed(m_audio_q15),
                           $signed(expected_mem[output_index][31:16]), error_value);
                output_index = output_index + 1;
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        while (output_index < OUTPUT_COUNT && timeout_cycles < 300_000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        if (input_index != INPUT_COUNT || output_index != OUTPUT_COUNT)
            $fatal(1, "audio stream count mismatch: input %0d output %0d",
                   input_index, output_index);
        $display("PASS: 121-tap FIR decimator matches GNU Radio (max error %0d LSB)", max_error);
        $finish;
    end
endmodule
