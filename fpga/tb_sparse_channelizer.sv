`timescale 1ns/1ps
module tb_sparse_channelizer;
    localparam integer INPUT_COUNT = 4096;
    localparam integer OUTPUT_COUNT = 512;
    localparam integer TOLERANCE_LSB = 400;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg signed [15:0] s_i = 16'sd0;
    reg signed [15:0] s_q = 16'sd0;
    reg s_valid = 1'b0;
    wire s_ready;
    wire [36:0] m_data;
    wire m_valid;
    reg m_ready = 1'b1;
    wire overrun;

    sparse_channelizer #(
        .CHANNELS(2), .TAPS(241), .FRAME_SAMPLES(16),
        .MAP_FILE("fpga/coeffs/channel_map_pfb_test.memh"),
        .COEFF_FILE("fpga/coeffs/channel_modulated_q17.memh")
    ) dut (
        .aclk(clk), .aresetn(resetn), .s_i(s_i), .s_q(s_q),
        .s_valid(s_valid), .s_ready(s_ready), .m_data(m_data),
        .m_valid(m_valid), .m_ready(m_ready), .overrun(overrun)
    );

    reg [31:0] input_mem [0:INPUT_COUNT-1];
    reg [31:0] expected_mem [0:507];
    integer input_index = 0;
    integer output_index = 0;
    integer compare_index;
    integer diff_i;
    integer diff_q;
    integer max_error_i = 0;
    integer max_error_q = 0;
    integer max_checked_i = 0;
    integer max_checked_q = 0;
    longint signed sample_i;
    longint signed sample_q;
    longint signed desired_energy = 0;
    longint signed adjacent_energy = 0;
    integer desired_samples = 0;
    integer adjacent_samples = 0;
    integer cycles = 0;

    initial begin
        $readmemh("fpga/vectors/pfb_input.memh", input_mem);
        $readmemh("fpga/vectors/pfb_expected.memh", expected_mem);
    end

    always @(posedge clk) begin
        if (resetn && m_valid && m_ready) begin
            if ((^m_data) === 1'bx)
                $fatal(1, "channelizer produced X-valued output at beat %0d", output_index);
            if (m_data[36:32] != ((output_index % 2) == 0 ? 5'd7 : 5'd8))
                $fatal(1, "channel tag mismatch at word %0d: got %0d",
                       output_index, m_data[36:32]);
            // GNU's PFB and RTL have different startup frame schedules. After
            // alignment, RTL frame 2 corresponds to GNU frame 1; ignore the
            // first eleven reference frames while the long FIR settles.
            if (output_index >= 4) begin
                compare_index = output_index - 2;
                diff_i = $signed(m_data[31:16]) - $signed(expected_mem[compare_index][31:16]);
                diff_q = $signed(m_data[15:0]) - $signed(expected_mem[compare_index][15:0]);
                if (diff_i < 0) diff_i = -diff_i;
                if (diff_q < 0) diff_q = -diff_q;
                if (diff_i > max_error_i) max_error_i = diff_i;
                if (diff_q > max_error_q) max_error_q = diff_q;
                if (compare_index >= 22 && compare_index < 508) begin
                    if (diff_i > max_checked_i) max_checked_i = diff_i;
                    if (diff_q > max_checked_q) max_checked_q = diff_q;
                    sample_i = $signed(m_data[31:16]);
                    sample_q = $signed(m_data[15:0]);
                    if (m_data[36:32] == 5'd7) begin
                        desired_energy = desired_energy + sample_i*sample_i + sample_q*sample_q;
                        desired_samples = desired_samples + 1;
                    end else begin
                        adjacent_energy = adjacent_energy + sample_i*sample_i + sample_q*sample_q;
                        adjacent_samples = adjacent_samples + 1;
                    end
                end
                if (compare_index >= 22 && compare_index < 508 &&
                    (diff_i > TOLERANCE_LSB || diff_q > TOLERANCE_LSB))
                    $fatal(1, "PFB mismatch word %0d: got (%0d,%0d), expected (%0d,%0d), error (%0d,%0d)",
                           output_index, $signed(m_data[31:16]), $signed(m_data[15:0]),
                           $signed(expected_mem[compare_index][31:16]),
                           $signed(expected_mem[compare_index][15:0]), diff_i, diff_q);
            end
            output_index = output_index + 1;
        end
    end

    integer i;
    initial begin
        $readmemh("fpga/vectors/pfb_input.memh", input_mem);
        $readmemh("fpga/vectors/pfb_expected.memh", expected_mem);
        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        for (i = 0; i < INPUT_COUNT; i = i + 1) begin
            @(negedge clk);
            s_valid = 1'b1;
            s_i = input_mem[i][31:16];
            s_q = input_mem[i][15:0];
            @(posedge clk);
            if (!s_ready) $fatal(1, "channelizer unexpectedly backpressured input");
            input_index = input_index + 1;
            @(negedge clk);
            s_valid = 1'b0;
            repeat (249) @(posedge clk);
        end
        while (output_index < OUTPUT_COUNT && cycles < 200_000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (output_index != OUTPUT_COUNT)
            $fatal(1, "output timeout (%0d/%0d)", output_index, OUTPUT_COUNT);
        if (input_index != INPUT_COUNT)
            $fatal(1, "input count mismatch (%0d/%0d)", input_index, INPUT_COUNT);
        if (overrun)
            $fatal(1, "channelizer frame overrun");
        if (desired_samples < 200 || adjacent_samples < 200)
            $fatal(1, "not enough steady-state samples to check channel isolation");
        if (desired_energy >= 10_000_000_000 ||
            adjacent_energy <= 100_000_000_000 ||
            adjacent_energy <= desired_energy * 25)
            $fatal(1, "adjacent-channel isolation failed: desired energy %0d, adjacent energy %0d",
                   desired_energy, adjacent_energy);
        $display("PASS: sparse channelizer matches GNU Radio after startup (max I/Q error %0d/%0d LSB; startup max %0d/%0d)",
                 max_checked_i, max_checked_q, max_error_i, max_error_q);
        $finish;
    end
endmodule
