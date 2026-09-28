// Fixed-point NBFM quadrature discriminator for complex Q1.15 input.
// Output approximates GNU Radio quadrature_demod_cf after multiplying phase
// delta by RATE_HZ/(2*pi*MAX_DEVIATION_HZ). It uses a 16-step iterative CORDIC
// and therefore reuses arithmetic over fabric clocks instead of unrolling
// an atan2 datapath.
module quadrature_demod #(
    parameter signed [16:0] GAIN_Q15 = 17'sd52150
) (
    input  wire                 aclk,
    input  wire                 aresetn,
    input  wire signed [15:0]   s_i,
    input  wire signed [15:0]   s_q,
    input  wire                 s_valid,
    output wire                 s_ready,
    output reg  signed [15:0]   m_demod_q15,
    output reg                  m_valid,
    input  wire                 m_ready
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_CORDIC = 2'd1;
    localparam signed [17:0] PI_Q14 = 18'sd51472;

    reg [1:0] state;
    reg signed [15:0] previous_i;
    reg signed [15:0] previous_q;
    reg signed [34:0] cordic_x;
    reg signed [34:0] cordic_y;
    reg signed [17:0] cordic_z;
    reg [4:0] iteration;

    wire signed [31:0] ii_product = s_i * previous_i;
    wire signed [31:0] qq_product = s_q * previous_q;
    wire signed [31:0] qi_product = s_q * previous_i;
    wire signed [31:0] iq_product = s_i * previous_q;
    wire signed [32:0] dot_product = $signed(ii_product) + $signed(qq_product);
    wire signed [32:0] cross_product = $signed(qi_product) - $signed(iq_product);

    function signed [17:0] atan_q14;
        input [4:0] index;
        begin
            case (index)
                5'd0: atan_q14 = 18'sd12868;
                5'd1: atan_q14 = 18'sd7596;
                5'd2: atan_q14 = 18'sd4014;
                5'd3: atan_q14 = 18'sd2037;
                5'd4: atan_q14 = 18'sd1023;
                5'd5: atan_q14 = 18'sd512;
                5'd6: atan_q14 = 18'sd256;
                5'd7: atan_q14 = 18'sd128;
                5'd8: atan_q14 = 18'sd64;
                5'd9: atan_q14 = 18'sd32;
                5'd10: atan_q14 = 18'sd16;
                5'd11: atan_q14 = 18'sd8;
                5'd12: atan_q14 = 18'sd4;
                5'd13: atan_q14 = 18'sd2;
                5'd14: atan_q14 = 18'sd1;
                default: atan_q14 = 18'sd0;
            endcase
        end
    endfunction

    wire signed [34:0] shifted_x = cordic_x >>> iteration;
    wire signed [34:0] shifted_y = cordic_y >>> iteration;
    wire signed [34:0] next_x = (cordic_y > 0) ? cordic_x + shifted_y :
                                 (cordic_y < 0) ? cordic_x - shifted_y : cordic_x;
    wire signed [34:0] next_y = (cordic_y > 0) ? cordic_y - shifted_x :
                                 (cordic_y < 0) ? cordic_y + shifted_x : cordic_y;
    wire signed [17:0] next_z = (cordic_y > 0) ? cordic_z + atan_q14(iteration) :
                                 (cordic_y < 0) ? cordic_z - atan_q14(iteration) : cordic_z;
    wire signed [34:0] scaled_angle = next_z * GAIN_Q15;
    wire signed [19:0] demod_scaled = 20'($signed(scaled_angle) >>> 14);

    function signed [15:0] saturate_q15;
        input signed [19:0] value;
        begin
            if (value > 20'sd32767)
                saturate_q15 = 16'sd32767;
            else if (value < -20'sd32768)
                saturate_q15 = -16'sd32768;
            else
                saturate_q15 = value[15:0];
        end
    endfunction

    assign s_ready = (state == ST_IDLE) && (!m_valid || m_ready);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state <= ST_IDLE;
            previous_i <= 16'sd0;
            previous_q <= 16'sd0;
            cordic_x <= 35'sd0;
            cordic_y <= 35'sd0;
            cordic_z <= 18'sd0;
            iteration <= 5'd0;
            m_demod_q15 <= 16'sd0;
            m_valid <= 1'b0;
        end else begin
            if (m_valid && m_ready)
                m_valid <= 1'b0;

            if (state == ST_IDLE && s_valid && s_ready) begin
                previous_i <= s_i;
                previous_q <= s_q;
                iteration <= 5'd0;
                if (dot_product < 0) begin
                    cordic_x <= -{{2{dot_product[32]}}, dot_product};
                    cordic_y <= -{{2{cross_product[32]}}, cross_product};
                    cordic_z <= (cross_product >= 0) ? PI_Q14 : -PI_Q14;
                end else begin
                    cordic_x <= {{2{dot_product[32]}}, dot_product};
                    cordic_y <= {{2{cross_product[32]}}, cross_product};
                    cordic_z <= 18'sd0;
                end
                state <= ST_CORDIC;
            end

            if (state == ST_CORDIC) begin
                cordic_x <= next_x;
                cordic_y <= next_y;
                cordic_z <= next_z;
                if (iteration == 5'd15) begin
                    m_demod_q15 <= saturate_q15(demod_scaled);
                    m_valid <= 1'b1;
                    state <= ST_IDLE;
                end else begin
                    iteration <= iteration + 1'b1;
                end
            end
        end
    end
endmodule
