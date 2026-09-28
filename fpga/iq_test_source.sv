// Board-independent, deterministic complex-IQ stream source for DSP bring-up.
// The tone is a 32-bit phase-accumulator DDS with a compact 16-step
// quarter-wave table. It emits ON_SAMPLES of tone followed by OFF_SAMPLES of
// zero, repeating forever. There is no board clock/reset/register interface.
module iq_test_source #(
    parameter integer ON_SAMPLES  = 8000,
    parameter integer OFF_SAMPLES = 2000,
    parameter integer GAIN_Q15     = 32768
) (
    input  wire               aclk,
    input  wire               aresetn,
    input  wire               enable,
    input  wire [31:0]        phase_step,
    output reg  [31:0]        m_axis_tdata, // {signed I[15:0], signed Q[15:0]}
    output reg                m_axis_tvalid,
    input  wire               m_axis_tready
);
    localparam [32:0] PERIOD = ON_SAMPLES + OFF_SAMPLES;
    localparam [32:0] ON_COUNT = 33'(ON_SAMPLES);
    reg [31:0] phase;
    reg [32:0] burst_pos;

    function [15:0] quarter_sine;
        input [4:0] address;
        begin
            case (address)
                5'd0:  quarter_sine = 16'd0;
                5'd1:  quarter_sine = 16'd3212;
                5'd2:  quarter_sine = 16'd6393;
                5'd3:  quarter_sine = 16'd9512;
                5'd4:  quarter_sine = 16'd12539;
                5'd5:  quarter_sine = 16'd15446;
                5'd6:  quarter_sine = 16'd18205;
                5'd7:  quarter_sine = 16'd20787;
                5'd8:  quarter_sine = 16'd23170;
                5'd9:  quarter_sine = 16'd25329;
                5'd10: quarter_sine = 16'd27245;
                5'd11: quarter_sine = 16'd28898;
                5'd12: quarter_sine = 16'd30273;
                5'd13: quarter_sine = 16'd31356;
                5'd14: quarter_sine = 16'd32137;
                5'd15: quarter_sine = 16'd32609;
                5'd16: quarter_sine = 16'd32767;
                default: quarter_sine = 16'd0;
            endcase
        end
    endfunction

    function [15:0] sine;
        input [5:0] index;
        reg [4:0] offset;
        reg [15:0] magnitude;
        begin
            offset = {1'b0, index[3:0]};
            if (index[4])
                magnitude = quarter_sine(5'd16 - offset);
            else
                magnitude = quarter_sine({1'b0, offset[3:0]});
            sine = index[5] ? (16'd0 - magnitude) : magnitude;
        end
    endfunction

    function [15:0] scale_sample;
        input [15:0] sample;
        reg signed [31:0] product;
        begin
            product = $signed(sample) * GAIN_Q15;
            scale_sample = 16'($signed(product) >>> 15);
        end
    endfunction

    wire [5:0] phase_index = phase[31:26];
    wire [15:0] q_sample = sine(phase_index);
    wire [15:0] i_sample = sine(phase_index + 6'd16);

    // A one-entry output register makes the source AXI-stream compliant:
    // valid and data remain unchanged for any number of stalled cycles.
    // Configuration (phase_step) is sampled when a new beat is produced.
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            phase         <= 32'd0;
            burst_pos     <= 33'd0;
            m_axis_tdata  <= 32'd0;
            m_axis_tvalid <= 1'b0;
        end else if (!m_axis_tvalid || m_axis_tready) begin
            if (enable) begin
                m_axis_tvalid <= 1'b1;
                if (burst_pos < ON_COUNT)
                    m_axis_tdata <= {scale_sample(i_sample), scale_sample(q_sample)};
                else
                    m_axis_tdata <= 32'd0;

                phase <= phase + phase_step;
                if (PERIOD == 0 || burst_pos + 1 >= PERIOD)
                    burst_pos <= 33'd0;
                else
                    burst_pos <= burst_pos + 1'b1;
            end else begin
                m_axis_tvalid <= 1'b0;
            end
        end
    end
endmodule
