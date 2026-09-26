// Interface-level test for the PlutoSky wrapper. The stub core makes this a
// fast test of source selection, Q1.15-to-12-bit mapping, tags, and backpressure
// propagation; DSP correctness is covered by the separate core testbenches.
module frs_receive_core #(
    parameter DDC_TAPS = "unused",
    parameter NCO_TAPS = "unused",
    parameter BAND1_MAP = "unused",
    parameter BAND2_MAP = "unused",
    parameter PFB_TAPS = "unused",
    parameter AUDIO_TAPS = "unused"
) (
    input wire aclk, input wire aresetn,
    input wire signed [11:0] s_adc_i, input wire signed [11:0] s_adc_q,
    input wire s_valid, output wire s_ready,
    input wire [32:0] threshold_q30,
    output reg [20:0] m_audio_data, output reg m_audio_valid,
    input wire m_audio_ready,
    output wire band1_overrun, output wire band2_overrun,
    output wire invalid_channel
);
    assign s_ready = !m_audio_valid || m_audio_ready;
    assign band1_overrun = 1'b0;
    assign band2_overrun = 1'b0;
    assign invalid_channel = 1'b0;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_audio_data <= 21'd0;
            m_audio_valid <= 1'b0;
        end else begin
            if (m_audio_valid && m_audio_ready)
                m_audio_valid <= 1'b0;
            if (s_valid && s_ready) begin
                // Channel 7 and an easily checked signed-Q15 value.
                m_audio_data <= {5'd7, s_adc_i, 4'b0000};
                m_audio_valid <= 1'b1;
            end
        end
    end
endmodule

module tb_frs_plutosky_r2_stream;
    reg aclk = 0;
    always #5 aclk = ~aclk;
    reg aresetn = 0;
    reg test_enable = 0;
    reg [31:0] test_phase_step = 0;
    reg signed [11:0] radio_i = -12'sd100;
    reg signed [11:0] radio_q = 12'sd55;
    reg radio_valid = 0;
    wire radio_ready;
    reg [32:0] threshold_q30 = 33'd0;
    wire [20:0] audio_data;
    wire audio_valid;
    reg audio_ready = 0;
    wire band1_overrun, band2_overrun, invalid_channel;

    frs_plutosky_r2_stream #(
        .TEST_ON_SAMPLES(8), .TEST_OFF_SAMPLES(4)
    ) dut (.*);

    task tick;
        begin @(posedge aclk); #1; end
    endtask

    initial begin
        repeat (3) tick();
        aresetn = 1;
        tick();

        // Radio samples are mapped to normalized Q1.15 before the core, then
        // restored to signed 12-bit at the core boundary without bit loss.
        radio_valid = 1;
        wait (radio_ready);
        tick();
        radio_valid = 0;
        if (!audio_valid || audio_data !== {5'd7, -12'sd100, 4'b0000})
            $fatal(1, "radio input/Q mapping or channel tag incorrect: %h", audio_data);

        // The core output is stalled. Enable synthetic input and ensure that
        // its first beat remains stable across an attempted source switch.
        test_enable = 1;
        wait (dut.test_valid);
        wait (dut.selected_valid);
        #1;
        if (dut.selected_q15 !== {16'sd32767, 16'sd0})
            $fatal(1, "synthetic test beat is not expected Q1.15 tone: %h", dut.selected_q15);
        tick();
        test_enable = 0;
        #1;
        if (dut.selected_q15 !== {16'sd32767, 16'sd0})
            $fatal(1, "source changed while synthetic beat was stalled");
        if (audio_data !== {5'd7, -12'sd100, 4'b0000} || !audio_valid)
            $fatal(1, "audio payload changed while backpressured");

        // Drain old output; the locked synthetic transaction is accepted and
        // appears as channel-tagged audio with the expected sign/scale.
        audio_ready = 1;
        tick();
        audio_ready = 0;
        if (!audio_valid || audio_data !== {5'd7, 12'sd2047, 4'b0000})
            $fatal(1, "synthetic sample or tag incorrect: %h", audio_data);
        tick();
        if (!audio_valid || audio_data !== {5'd7, 12'sd2047, 4'b0000})
            $fatal(1, "tagged output was not stable under downstream stall");

        audio_ready = 1;
        tick();
        if (audio_valid)
            $fatal(1, "output valid failed to clear after handshake");
        if (band1_overrun || band2_overrun || invalid_channel)
            $fatal(1, "unexpected core status flag");
        $display("PASS: PlutoSky stream source mux/Q mapping/tag/backpressure seam");
        $finish;
    end
endmodule
