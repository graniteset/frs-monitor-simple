`timescale 1ns/1ps
module tb_quadrature_demod;
    localparam integer SAMPLE_COUNT = 2048;
    localparam integer TOLERANCE_LSB = 8;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg signed [15:0] s_i = 16'sd0;
    reg signed [15:0] s_q = 16'sd0;
    reg s_valid = 1'b0;
    wire s_ready;
    wire signed [15:0] m_demod_q15;
    wire m_valid;
    wire m_ready = 1'b1;
    integer input_index = 0;
    integer output_index = 0;
    integer error_value;
    integer max_error = 0;
    integer timeout_cycles = 0;
    reg [31:0] input_mem [0:SAMPLE_COUNT-1];
    reg [31:0] expected_mem [0:SAMPLE_COUNT-1];

    quadrature_demod dut (
        .aclk(clk), .aresetn(resetn), .s_i(s_i), .s_q(s_q),
        .s_valid(s_valid), .s_ready(s_ready), .m_demod_q15(m_demod_q15),
        .m_valid(m_valid), .m_ready(m_ready)
    );

    initial begin
        $readmemh("fpga/vectors/fm_input.memh", input_mem);
        $readmemh("fpga/vectors/fm_expected.memh", expected_mem);
    end

    always @(negedge clk) begin
        if (resetn && input_index < SAMPLE_COUNT) begin
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
                if (output_index >= SAMPLE_COUNT)
                    $fatal(1, "FM discriminator produced too many outputs");
                error_value = $signed(m_demod_q15) - $signed(expected_mem[output_index][31:16]);
                if (error_value < 0) error_value = -error_value;
                if (error_value > max_error) max_error = error_value;
                if (error_value > TOLERANCE_LSB)
                    $fatal(1, "FM mismatch at %0d: got %0d, expected %0d, error %0d LSB",
                           output_index, $signed(m_demod_q15),
                           $signed(expected_mem[output_index][31:16]), error_value);
                output_index = output_index + 1;
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        while (output_index < SAMPLE_COUNT && timeout_cycles < 100_000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        if (input_index != SAMPLE_COUNT || output_index != SAMPLE_COUNT)
            $fatal(1, "FM stream count mismatch: input %0d output %0d", input_index, output_index);
        $display("PASS: iterative FM discriminator matches GNU Radio (max error %0d LSB)", max_error);
        $finish;
    end
endmodule
