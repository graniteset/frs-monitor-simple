// Deterministic, channel-accurate FRS FM test stream for board bring-up.
//
// Defaults assume the wideband IQ input is centered at 465.125 MHz and paced
// at exactly 6.4 MS/s. The carrier is on FRS channel 4 (462.6375 MHz), with a
// 1 kHz sinusoidal message and +/-1 kHz peak frequency deviation. Its output
// is complex Q1.15 {I,Q}; the bridge applies the normal 6.4 MS/s cadence.
module frs_fm_test_source #(
    parameter integer ON_SAMPLES = 320_000,
    parameter integer OFF_SAMPLES = 3_200_000,
    parameter integer GAIN_Q15 = 26_214, // about -1.94 dBFS
    parameter [31:0] CARRIER_PHASE_STEP = 32'h9c80_0000,
    parameter [31:0] MESSAGE_PHASE_STEP = 32'h000a_3d71,
    parameter [31:0] DEVIATION_PHASE_STEP = 32'd671_089,
    parameter SINE_LUT = "fpga/coeffs/test_sine_q15_1024.memh"
) (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        enable,
    output reg  [31:0] m_axis_tdata, // {signed I[15:0], signed Q[15:0]}
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready
);
    localparam [32:0] PERIOD = ON_SAMPLES + OFF_SAMPLES;

    reg signed [15:0] sine_lut [0:1023];
    reg [31:0] carrier_phase;
    reg [31:0] message_phase;
    reg [32:0] burst_pos;
    initial $readmemh(SINE_LUT, sine_lut);

    wire signed [15:0] message_sample = sine_lut[message_phase[31:22]];
    wire signed [15:0] q_unscaled = sine_lut[carrier_phase[31:22]];
    wire signed [15:0] i_unscaled = sine_lut[carrier_phase[31:22] + 10'd256];
    // Explicitly extend both operands before multiply. SystemVerilog sizes a
    // multiplication expression from its operands; assigning a narrow product
    // to a wider destination does not reliably preserve the full 33x16 result.
    wire signed [48:0] deviation_scale_ext = {17'd0, DEVIATION_PHASE_STEP};
    wire signed [48:0] message_sample_ext = {{33{message_sample[15]}}, message_sample};
    wire signed [48:0] deviation_product = deviation_scale_ext * message_sample_ext;
    wire signed [31:0] deviation_step = deviation_product >>> 15;
    wire [31:0] instantaneous_step = CARRIER_PHASE_STEP + deviation_step;
    wire signed [31:0] i_product = i_unscaled * GAIN_Q15;
    wire signed [31:0] q_product = q_unscaled * GAIN_Q15;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            carrier_phase <= 32'd0;
            message_phase <= 32'd0;
            burst_pos <= 33'd0;
            m_axis_tdata <= 32'd0;
            m_axis_tvalid <= 1'b0;
        end else if (!m_axis_tvalid || m_axis_tready) begin
            if (enable) begin
                m_axis_tvalid <= 1'b1;
                if (burst_pos < ON_SAMPLES)
                    m_axis_tdata <= {
                        16'($signed(i_product) >>> 15),
                        16'($signed(q_product) >>> 15)
                    };
                else
                    m_axis_tdata <= 32'd0;

                carrier_phase <= carrier_phase + instantaneous_step;
                message_phase <= message_phase + MESSAGE_PHASE_STEP;
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
