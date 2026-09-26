// Complex-power EMA squelch for Q1.15 IQ streams.
// threshold_q30 is a linear power threshold with 30 fractional bits; the
// threshold's dB-to-linear conversion belongs in the host/configuration layer.
module complex_squelch #(
    parameter [14:0] ALPHA_Q15 = 15'd33
) (
    input  wire                 aclk,
    input  wire                 aresetn,
    input  wire signed [15:0]   s_i,
    input  wire signed [15:0]   s_q,
    input  wire                 s_valid,
    output wire                 s_ready,
    input  wire [32:0]          threshold_q30,
    output wire signed [15:0]   m_i,
    output wire signed [15:0]   m_q,
    output wire                 m_valid,
    input  wire                 m_ready,
    output reg  [32:0]          average_power_q30
);
    wire signed [31:0] square_i = s_i * s_i;
    wire signed [31:0] square_q = s_q * s_q;
    wire [32:0] instantaneous_power = {1'b0, square_i} + {1'b0, square_q};
    wire signed [33:0] power_delta = $signed({1'b0, instantaneous_power}) -
                                      $signed({1'b0, average_power_q30});
    wire signed [48:0] scaled_delta = power_delta * $signed({1'b0, ALPHA_Q15});
    wire signed [33:0] filtered_delta = 34'($signed(scaled_delta >>> 15));
    wire signed [33:0] next_power_wide = $signed({1'b0, average_power_q30}) + filtered_delta;
    wire [32:0] next_power = (next_power_wide < 0) ? 33'd0 :
                             (next_power_wide > 34'sh1ffffffff) ? 33'h1ffffffff :
                             next_power_wide[32:0];
    wire open_after_sample = next_power >= threshold_q30;

    assign s_ready = m_ready;
    assign m_valid = s_valid;
    assign m_i = open_after_sample ? s_i : 16'sd0;
    assign m_q = open_after_sample ? s_q : 16'sd0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            average_power_q30 <= 33'd0;
        end else if (s_valid && s_ready) begin
            average_power_q30 <= next_power;
        end
    end
endmodule
