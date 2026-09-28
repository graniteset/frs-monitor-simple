`timescale 1ns/1ps
module tb_band_ddc #(
    parameter integer BAND2 = 0
);
    localparam integer INPUT_COUNT = 4096;
    localparam integer OUTPUT_COUNT = 256;
    localparam integer TOLERANCE_LSB = 6;
    localparam [8:0] PHASE_STEP = BAND2 ? 9'd311 : 9'd199;
    localparam [8:0] INITIAL_PHASE = BAND2 ? 9'd490 : 9'd330;

    reg clk;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg resetn = 1'b0;
    reg signed [15:0] s_i = 16'sd0;
    reg signed [15:0] s_q = 16'sd0;
    reg s_valid = 1'b0;
    wire s_ready;
    wire signed [15:0] m_i;
    wire signed [15:0] m_q;
    wire m_valid;
    reg m_ready = 1'b1;
    wire overrun;

    band_ddc_decimator #(
        .DECIMATION(16), .TAPS(205), .PHASE_STEP(PHASE_STEP),
        .INITIAL_PHASE(INITIAL_PHASE),
        .TAPS_FILE("fpga/coeffs/subband_q17.memh"),
        .NCO_FILE("fpga/coeffs/nco_q15_quarter.memh")
    ) dut (
        .aclk(clk), .aresetn(resetn), .s_i(s_i), .s_q(s_q),
        .s_valid(s_valid), .s_ready(s_ready), .m_i(m_i), .m_q(m_q),
        .m_valid(m_valid), .m_ready(m_ready), .overrun(overrun)
    );

    reg [31:0] input_mem [0:INPUT_COUNT-1];
    reg [31:0] expected_mem [0:OUTPUT_COUNT-1];
    integer input_index = 0;
    integer output_index = 0;
    integer diff_i;
    integer diff_q;
    integer max_error_i = 0;
    integer max_error_q = 0;
    integer timeout_cycles = 0;

    initial begin
        // Icarus 12 (Ubuntu 24.04) cannot pass a parameterized string to
        // $readmemh, even when the expression is constant after elaboration.
        if (BAND2) begin
            $readmemh("fpga/vectors/ddc_band2_input.memh", input_mem);
            $readmemh("fpga/vectors/ddc_band2_expected.memh", expected_mem);
        end else begin
            $readmemh("fpga/vectors/ddc_input.memh", input_mem);
            $readmemh("fpga/vectors/ddc_expected.memh", expected_mem);
        end
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
                if ((^m_i) === 1'bx || (^m_q) === 1'bx)
                    $fatal(1, "DDC produced X-valued output at sample %0d", output_index);
                if (output_index >= OUTPUT_COUNT)
                    $fatal(1, "DDC produced too many outputs");
                diff_i = $signed(m_i) - $signed(expected_mem[output_index][31:16]);
                diff_q = $signed(m_q) - $signed(expected_mem[output_index][15:0]);
                if (diff_i < 0) diff_i = -diff_i;
                if (diff_q < 0) diff_q = -diff_q;
                if (diff_i > max_error_i) max_error_i = diff_i;
                if (diff_q > max_error_q) max_error_q = diff_q;
                if (diff_i > TOLERANCE_LSB || diff_q > TOLERANCE_LSB)
                    $fatal(1, "DDC mismatch at output %0d: got (%0d,%0d), expected (%0d,%0d), error (%0d,%0d) LSB",
                           output_index, $signed(m_i), $signed(m_q),
                           $signed(expected_mem[output_index][31:16]),
                           $signed(expected_mem[output_index][15:0]), diff_i, diff_q);
                output_index = output_index + 1;
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        while (output_index < OUTPUT_COUNT && timeout_cycles < 200000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        if (input_index != INPUT_COUNT)
            $fatal(1, "input source stopped early (%0d/%0d)", input_index, INPUT_COUNT);
        if (output_index != OUTPUT_COUNT)
            $fatal(1, "output timeout (%0d/%0d)", output_index, OUTPUT_COUNT);
        if (overrun)
            $fatal(1, "DDC MAC overrun flag asserted");
        $display("PASS: band %0d fixed-point DDC matches GNU Radio within %0d LSB (%0d outputs; max I/Q error %0d/%0d LSB)",
                 BAND2 ? 2 : 1, TOLERANCE_LSB, output_index, max_error_i, max_error_q);
        $finish;
    end
endmodule
