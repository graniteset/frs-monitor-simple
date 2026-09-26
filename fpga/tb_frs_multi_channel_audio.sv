`timescale 1ns/1ps
module tb_frs_multi_channel_audio;
    localparam integer CHANNELS = 22;
    localparam integer INPUTS_PER_CHANNEL = 128;
    localparam integer OUTPUTS_PER_CHANNEL = INPUTS_PER_CHANNEL / 2;
    localparam integer TOLERANCE_LSB = 6;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg [36:0] s_data = 37'd0;
    reg s_valid = 1'b0;
    wire s_ready;
    reg [32:0] threshold_q30 = 33'd1_000_000;
    wire [20:0] m_data;
    wire m_valid;
    reg m_ready = 1'b1;
    wire invalid_channel;

    reg [31:0] input_mem [0:2047];
    reg [31:0] expected_mem [0:1023];
    integer output_seen [1:CHANNELS];
    integer input_seen [1:CHANNELS];
    integer send_channel;
    integer monitor_channel;
    integer sample_index;
    integer output_index;
    integer error_value;
    integer max_error = 0;
    integer timeout_cycles = 0;
    integer global_cycle = 0;

    frs_multi_channel_audio dut (
        .aclk(clk), .aresetn(resetn), .s_data(s_data), .s_valid(s_valid),
        .s_ready(s_ready), .threshold_q30(threshold_q30), .m_data(m_data),
        .m_valid(m_valid), .m_ready(m_ready), .invalid_channel(invalid_channel)
    );

    initial begin
        $readmemh("fpga/vectors/fm_input.memh", input_mem);
        $readmemh("fpga/vectors/audio_expected.memh", expected_mem);
        for (integer idx = 1; idx <= CHANNELS; idx = idx + 1)
            begin output_seen[idx] = 0; input_seen[idx] = 0; end
    end

    // Irregular downstream readiness exercises held-valid stability.
    always @(negedge clk) begin
        if (resetn)
            m_ready = ((global_cycle % 13) < 9);
    end

    always @(posedge clk) begin
        if (resetn) global_cycle = global_cycle + 1;
        if (resetn && s_valid && s_ready && s_data[36:32] != 0)
            input_seen[s_data[36:32]] = input_seen[s_data[36:32]] + 1;
        if (resetn && m_valid && m_ready) begin
            monitor_channel = m_data[20:16];
            if (monitor_channel < 1 || monitor_channel > CHANNELS)
                $fatal(1, "bad FRS channel tag %0d", monitor_channel);
            output_index = output_seen[monitor_channel];
            if (output_index >= OUTPUTS_PER_CHANNEL)
                $fatal(1, "too many outputs on channel %0d after %0d accepted inputs", monitor_channel, input_seen[monitor_channel]);
            error_value = $signed(m_data[15:0]) - $signed(expected_mem[output_index][31:16]);
            if (error_value < 0) error_value = -error_value;
            if (error_value > max_error) max_error = error_value;
            if (error_value > TOLERANCE_LSB)
                $fatal(1, "ch%0d output %0d got %0d expected %0d (err %0d)",
                       monitor_channel, output_index, $signed(m_data[15:0]),
                       $signed(expected_mem[output_index][31:16]), error_value);
            output_seen[monitor_channel] = output_seen[monitor_channel] + 1;
        end
    end

    task send_sample;
        input [4:0] tag;
        input [31:0] value;
        begin
            @(negedge clk);
            s_data = {tag, value};
            s_valid = 1'b1;
            do @(posedge clk); while (!s_ready);
            @(negedge clk);
            s_valid = 1'b0;
        end
    endtask

    initial begin
        $readmemh("fpga/vectors/fm_input.memh", input_mem);
        repeat (3) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;

        // Channel zero is reserved and must be consumed safely but flagged.
        send_sample(5'd0, input_mem[0]);
        if (!invalid_channel) $fatal(1, "invalid channel was not flagged");

        // Each PFB channel produces roughly once per 4,000 fabric clocks.
        // Spread the 22 serialized channel outputs across a frame and leave
        // idle time so the shared 121-tap audio worker can keep up.
        for (sample_index = 0; sample_index < INPUTS_PER_CHANNEL; sample_index = sample_index + 1) begin
            for (send_channel = 1; send_channel <= CHANNELS; send_channel = send_channel + 1) begin
                send_sample(send_channel[4:0], input_mem[sample_index]);
                repeat (105) @(posedge clk);
            end
            repeat (1300) @(posedge clk);
        end

        s_valid = 1'b0;
        m_ready = 1'b1;
        while (timeout_cycles < 500_000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
            monitor_channel = 1;
            while (monitor_channel <= CHANNELS && output_seen[monitor_channel] == OUTPUTS_PER_CHANNEL)
                monitor_channel = monitor_channel + 1;
            if (monitor_channel > CHANNELS) begin
                $display("PASS: 22-channel shared FM/audio path, backpressure, invalid tag, max error %0d LSB", max_error);
                $finish;
            end
        end
        for (monitor_channel = 1; monitor_channel <= CHANNELS; monitor_channel = monitor_channel + 1)
            if (output_seen[monitor_channel] != OUTPUTS_PER_CHANNEL)
                $fatal(1, "channel %0d count %0d expected %0d", monitor_channel,
                       output_seen[monitor_channel], OUTPUTS_PER_CHANNEL);
        $fatal(1, "timeout draining multi-channel audio");
    end
endmodule
