// Time-multiplexed 22-channel squelch/FM/de-emphasis/audio path.
// Input is a serialized tagged complex stream {channel[4:0],I[15:0],Q[15:0]}
// at 25 kS/s per channel. One CORDIC serves all channels; per-channel power,
// discriminator history, deemphasis history, decimator phase, and audio FIR
// delay lines are kept separately. Audio outputs are serialized and tagged.
module frs_multi_channel_audio #(
    parameter integer CHANNELS = 22,
    parameter integer AUDIO_TAPS = 121,
    parameter integer AUDIO_FIFO_DEPTH = 32,
    parameter integer HISTORY_SIZE = 128,
    parameter signed [16:0] FM_GAIN_Q15 = 17'sd52150,
    parameter signed [17:0] DEEMPH_B0_Q17 = 18'sd28123,
    parameter signed [17:0] DEEMPH_FB_Q17 = 18'sd74826,
    parameter signed [15:0] CHANNEL_GAIN_Q15 = 16'sd8192,
    parameter AUDIO_TAPS_FILE = "fpga/coeffs/audio_q17.memh"
) (
    input  wire                 aclk,
    input  wire                 aresetn,
    input  wire [36:0]          s_data,
    input  wire                 s_valid,
    output wire                 s_ready,
    input  wire [32:0]          threshold_q30,
    output reg  [20:0]          m_data,
    output reg                  m_valid,
    input  wire                 m_ready,
    output reg                  invalid_channel
);
    localparam integer FIFO_AW = (AUDIO_FIFO_DEPTH <= 2) ? 1 : $clog2(AUDIO_FIFO_DEPTH);
    localparam integer FIFO_COUNT_W = FIFO_AW + 1;
    localparam integer TAP_AW = $clog2(AUDIO_TAPS);
    localparam integer HIST_AW = $clog2(HISTORY_SIZE);
    localparam integer AUDIO_HIST_ADDR_W = $clog2(CHANNELS * HISTORY_SIZE);
    localparam [3:0] FRONT_IDLE = 4'd0;
    localparam [3:0] FRONT_SQUARE = 4'd1;
    localparam [3:0] FRONT_POWER = 4'd2;
    localparam [3:0] FRONT_DISC_MUL = 4'd3;
    localparam [3:0] FRONT_DISC_SUM = 4'd4;
    localparam [3:0] FRONT_CORDIC_INIT = 4'd5;
    localparam [3:0] FRONT_CORDIC = 4'd6;
    localparam [3:0] FRONT_FM_SCALE = 4'd7;
    localparam [3:0] FRONT_DEEMPH_MUL = 4'd8;
    localparam [3:0] FRONT_DEEMPH_SUM0 = 4'd9;
    localparam [3:0] FRONT_DEEMPH_SUM1 = 4'd10;
    localparam [3:0] FRONT_DEEMPH_QUANT = 4'd11;
    localparam [3:0] FRONT_FIFO_WRITE = 4'd12;
    localparam [1:0] FIR_IDLE = 2'd0;
    localparam [1:0] FIR_MAC = 2'd1;

    reg [3:0] front_state;
    reg [1:0] fir_state;

    reg [32:0] power_average [0:CHANNELS-1];
    reg signed [15:0] previous_i [0:CHANNELS-1];
    reg signed [15:0] previous_q [0:CHANNELS-1];
    reg signed [15:0] deemph_previous_input [0:CHANNELS-1];
    reg signed [15:0] deemph_previous_output [0:CHANNELS-1];
    reg decimator_phase [0:CHANNELS-1];

    // FIFO payload is written synchronously and deliberately has no reset;
    // the resettable count/pointers ensure invalid entries are never consumed.
    // Packing the fields also gives synthesis a single distributed-RAM array.
    (* ram_style = "distributed" *) reg [21:0] audio_fifo_payload [0:AUDIO_FIFO_DEPTH-1];
    reg [FIFO_AW-1:0] audio_fifo_write;
    reg [FIFO_AW-1:0] audio_fifo_read;
    reg [FIFO_COUNT_W-1:0] audio_fifo_count;

    reg signed [17:0] audio_taps [0:AUDIO_TAPS-1];
    reg signed [15:0] audio_history [0:CHANNELS*HISTORY_SIZE-1];
    reg [HIST_AW-1:0] audio_write_pointer [0:CHANNELS-1];
    reg [TAP_AW:0] audio_history_count [0:CHANNELS-1];
    reg [HIST_AW-1:0] fir_head;
    reg [TAP_AW:0] fir_valid_count;

    reg [4:0] active_channel;
    reg active_decimated;
    // Break the channelizer-to-audio timing path at the stream boundary.
    // Channel selection and the squelch/discriminator arithmetic now operate
    // on this registered sample, rather than directly on the PFB output mux.
    reg [4:0] front_channel;
    reg signed [15:0] front_i;
    reg signed [15:0] front_q;
    reg front_decimated;
    reg signed [31:0] front_square_i;
    reg signed [31:0] front_square_q;
    reg [32:0] front_power_average;
    reg signed [15:0] front_gated_i;
    reg signed [15:0] front_gated_q;
    reg signed [31:0] front_disc_ii;
    reg signed [31:0] front_disc_qq;
    reg signed [31:0] front_disc_qi;
    reg signed [31:0] front_disc_iq;
    reg signed [32:0] front_disc_dot;
    reg signed [32:0] front_disc_cross;
    reg signed [17:0] front_final_cordic_z;
    reg signed [15:0] front_fm_sample;
    reg signed [33:0] front_deemph_current_product;
    reg signed [33:0] front_deemph_previous_product;
    reg signed [33:0] front_deemph_feedback_product;
    reg signed [37:0] front_deemph_sum01;
    reg signed [37:0] front_deemph_sum_all;
    reg signed [15:0] front_deemph_output;
    reg [4:0] fir_channel;
    reg [TAP_AW-1:0] fir_tap_index;
    reg signed [41:0] fir_accumulator;

    reg signed [34:0] cordic_x;
    reg signed [34:0] cordic_y;
    reg signed [17:0] cordic_z;
    reg [4:0] cordic_iteration;

    // The channel maps use human-facing FRS IDs 1..22 (zero is reserved).
    wire [4:0] input_channel = s_data[36:32];
    wire input_channel_valid = (input_channel != 0) && (input_channel <= 5'(CHANNELS));
    wire [4:0] input_channel_safe = input_channel_valid ? input_channel - 1'b1 : 5'd0;

    wire [4:0] front_channel_safe = front_channel - 1'b1;

    wire [32:0] input_power = {1'b0, front_square_i} + {1'b0, front_square_q};
    wire signed [33:0] input_power_delta = $signed({1'b0, input_power}) -
                                            $signed({1'b0, front_power_average});
    wire signed [48:0] power_update_product = input_power_delta * 16'sd33;
    wire signed [33:0] power_update = 34'($signed(power_update_product >>> 15));
    wire signed [33:0] power_next_wide = $signed({1'b0, power_average[front_channel_safe]}) + power_update;
    wire [32:0] power_next = (power_next_wide < 0) ? 33'd0 :
                             (power_next_wide > 34'sh1ffffffff) ? 33'h1ffffffff :
                             power_next_wide[32:0];
    wire input_squelch_open = (power_next >= threshold_q30);
    wire signed [15:0] gated_i = input_squelch_open ? front_i : 16'sd0;
    wire signed [15:0] gated_q = input_squelch_open ? front_q : 16'sd0;

    wire signed [31:0] discriminator_ii = front_gated_i * previous_i[front_channel_safe];
    wire signed [31:0] discriminator_qq = front_gated_q * previous_q[front_channel_safe];
    wire signed [31:0] discriminator_qi = front_gated_q * previous_i[front_channel_safe];
    wire signed [31:0] discriminator_iq = front_gated_i * previous_q[front_channel_safe];
    wire signed [32:0] discriminator_dot = $signed(front_disc_ii) + $signed(front_disc_qq);
    wire signed [32:0] discriminator_cross = $signed(front_disc_qi) - $signed(front_disc_iq);

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

    wire signed [34:0] cordic_shift_x = cordic_x >>> cordic_iteration;
    wire signed [34:0] cordic_shift_y = cordic_y >>> cordic_iteration;
    wire signed [34:0] cordic_next_x = (cordic_y > 0) ? cordic_x + cordic_shift_y :
                                       (cordic_y < 0) ? cordic_x - cordic_shift_y : cordic_x;
    wire signed [34:0] cordic_next_y = (cordic_y > 0) ? cordic_y - cordic_shift_x :
                                       (cordic_y < 0) ? cordic_y + cordic_shift_x : cordic_y;
    wire signed [17:0] cordic_next_z = (cordic_y > 0) ? cordic_z + atan_q14(cordic_iteration) :
                                       (cordic_y < 0) ? cordic_z - atan_q14(cordic_iteration) : cordic_z;
    wire signed [34:0] fm_scaled_wide = front_final_cordic_z * FM_GAIN_Q15;
    wire signed [19:0] fm_demod_q15_wide = 20'($signed(fm_scaled_wide) >>> 14);

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

    wire signed [37:0] deemph_sum01_next =
        {{4{front_deemph_current_product[33]}}, front_deemph_current_product} +
        {{4{front_deemph_previous_product[33]}}, front_deemph_previous_product};
    wire signed [37:0] deemph_sum_all_next = front_deemph_sum01 +
        {{4{front_deemph_feedback_product[33]}}, front_deemph_feedback_product};
    function signed [15:0] q32_to_q15;
        input signed [41:0] value;
        reg signed [42:0] rounded;
        reg signed [25:0] scaled;
        begin
            rounded = (value >= 0) ? (value + 43'sd65536) : (value - 43'sd65536);
            scaled = 26'($signed(rounded) >>> 17);
            if (scaled > 26'sd32767) q32_to_q15 = 16'sd32767;
            else if (scaled < -26'sd32768) q32_to_q15 = -16'sd32768;
            else q32_to_q15 = scaled[15:0];
        end
    endfunction
    wire signed [41:0] deemph_sum_all_42 = {{4{front_deemph_sum_all[37]}}, front_deemph_sum_all};
    wire signed [15:0] deemph_output_next = q32_to_q15(deemph_sum_all_42);

    wire fifo_pop = (fir_state == FIR_IDLE) && (audio_fifo_count != 0) && (!m_valid || m_ready);
    wire fifo_has_room = (audio_fifo_count < FIFO_COUNT_W'(AUDIO_FIFO_DEPTH)) || fifo_pop;
    assign s_ready = (front_state == FRONT_IDLE) &&
                     (!input_channel_valid || fifo_has_room);

    wire [HIST_AW-1:0] fir_history_address = (fir_head >= fir_tap_index) ?
                                               fir_head - fir_tap_index :
                                               fir_head + HIST_AW'(AUDIO_TAPS) - fir_tap_index;
    wire [AUDIO_HIST_ADDR_W-1:0] fir_flat_address =
        AUDIO_HIST_ADDR_W'(fir_channel) * AUDIO_HIST_ADDR_W'(HISTORY_SIZE) +
        AUDIO_HIST_ADDR_W'(fir_history_address);
    wire [21:0] fifo_payload_current = audio_fifo_payload[audio_fifo_read];
    wire [4:0] fifo_channel_current = fifo_payload_current[21:17];
    wire signed [15:0] fifo_sample_current = $signed(fifo_payload_current[16:1]);
    wire fifo_decimated_current = fifo_payload_current[0];
    wire [AUDIO_HIST_ADDR_W-1:0] fifo_write_flat_address =
        AUDIO_HIST_ADDR_W'(fifo_channel_current) * AUDIO_HIST_ADDR_W'(HISTORY_SIZE) +
        AUDIO_HIST_ADDR_W'(audio_write_pointer[fifo_channel_current]);
    wire fir_sample_valid = {1'b0, fir_tap_index} < fir_valid_count;
    wire signed [15:0] fir_sample = fir_sample_valid ? audio_history[fir_flat_address] : 16'sd0;
    wire signed [33:0] fir_product = fir_sample * audio_taps[fir_tap_index];
    wire signed [41:0] fir_next_accumulator = fir_accumulator + {{8{fir_product[33]}}, fir_product};

    function [HIST_AW-1:0] wrap_audio_pointer;
        input [HIST_AW-1:0] pointer;
        begin
            wrap_audio_pointer = (pointer == HIST_AW'(AUDIO_TAPS-1)) ?
                                 {HIST_AW{1'b0}} : pointer + HIST_AW'(1);
        end
    endfunction

    wire signed [31:0] audio_gain_product = q32_to_q15(fir_next_accumulator) * CHANNEL_GAIN_Q15;
    wire signed [32:0] audio_gain_rounded = (audio_gain_product >= 0) ?
                                             ($signed(audio_gain_product) + 33'sd16384) :
                                             ($signed(audio_gain_product) - 33'sd16384);
    wire signed [17:0] audio_gain_scaled = 18'($signed(audio_gain_rounded) >>> 15);
    wire signed [15:0] audio_gain_output = (audio_gain_scaled > 18'sd32767) ? 16'sd32767 :
                                           (audio_gain_scaled < -18'sd32768) ? -16'sd32768 :
                                           audio_gain_scaled[15:0];

    initial $readmemh(AUDIO_TAPS_FILE, audio_taps);

    // Single sample write port for the 22 channel-specific audio delay lines.
    always @(posedge aclk) begin
        if (front_state == FRONT_FIFO_WRITE) begin
            audio_fifo_payload[audio_fifo_write] <=
                {active_channel, front_deemph_output, active_decimated};
        end
        if (fifo_pop) begin
            audio_history[fifo_write_flat_address] <=
                fifo_sample_current;
        end
    end

    integer reset_channel;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            front_state <= FRONT_IDLE;
            fir_state <= FIR_IDLE;
            active_channel <= 5'd0;
            active_decimated <= 1'b0;
            front_channel <= 5'd1;
            front_i <= 16'sd0;
            front_q <= 16'sd0;
            front_decimated <= 1'b0;
            front_square_i <= 32'sd0;
            front_square_q <= 32'sd0;
            front_power_average <= 33'd0;
            front_gated_i <= 16'sd0;
            front_gated_q <= 16'sd0;
            front_disc_ii <= 32'sd0;
            front_disc_qq <= 32'sd0;
            front_disc_qi <= 32'sd0;
            front_disc_iq <= 32'sd0;
            front_disc_dot <= 33'sd0;
            front_disc_cross <= 33'sd0;
            front_final_cordic_z <= 18'sd0;
            front_fm_sample <= 16'sd0;
            front_deemph_current_product <= 34'sd0;
            front_deemph_previous_product <= 34'sd0;
            front_deemph_feedback_product <= 34'sd0;
            front_deemph_sum01 <= 38'sd0;
            front_deemph_sum_all <= 38'sd0;
            front_deemph_output <= 16'sd0;
            cordic_x <= 35'sd0;
            cordic_y <= 35'sd0;
            cordic_z <= 18'sd0;
            cordic_iteration <= 5'd0;
            audio_fifo_write <= {FIFO_AW{1'b0}};
            audio_fifo_read <= {FIFO_AW{1'b0}};
            audio_fifo_count <= {FIFO_COUNT_W{1'b0}};
            fir_channel <= 5'd0;
            fir_head <= {HIST_AW{1'b0}};
            fir_valid_count <= {(TAP_AW+1){1'b0}};
            fir_tap_index <= {TAP_AW{1'b0}};
            fir_accumulator <= 42'sd0;
            m_data <= 21'd0;
            m_valid <= 1'b0;
            invalid_channel <= 1'b0;
            for (reset_channel = 0; reset_channel < CHANNELS; reset_channel = reset_channel + 1) begin
                power_average[reset_channel] <= 33'd0;
                previous_i[reset_channel] <= 16'sd0;
                previous_q[reset_channel] <= 16'sd0;
                deemph_previous_input[reset_channel] <= 16'sd0;
                deemph_previous_output[reset_channel] <= 16'sd0;
                decimator_phase[reset_channel] <= 1'b1;
                audio_write_pointer[reset_channel] <= {HIST_AW{1'b0}};
                audio_history_count[reset_channel] <= {(TAP_AW+1){1'b0}};
            end
        end else begin
            if (m_valid && m_ready)
                m_valid <= 1'b0;

            if (s_valid && s_ready && front_state == FRONT_IDLE) begin
                if (!input_channel_valid) begin
                    invalid_channel <= 1'b1;
                end else begin
                    front_channel <= input_channel;
                    front_i <= s_data[31:16];
                    front_q <= s_data[15:0];
                    front_decimated <= decimator_phase[input_channel_safe];
                    active_channel <= input_channel_safe;
                    active_decimated <= decimator_phase[input_channel_safe];
                    front_state <= FRONT_SQUARE;
                end
            end

            // Pipeline the channelizer-to-CORDIC front end. Separate stages
            // keep sample selection, power/squelch, discriminator products,
            // and dot/cross reduction from forming one long combinational
            // path into the iterative CORDIC state registers.
            if (front_state == FRONT_SQUARE) begin
                front_square_i <= front_i * front_i;
                front_square_q <= front_q * front_q;
                front_power_average <= power_average[front_channel_safe];
                front_state <= FRONT_POWER;
            end

            if (front_state == FRONT_POWER) begin
                power_average[front_channel_safe] <= power_next;
                front_gated_i <= gated_i;
                front_gated_q <= gated_q;
                front_state <= FRONT_DISC_MUL;
            end

            if (front_state == FRONT_DISC_MUL) begin
                front_disc_ii <= discriminator_ii;
                front_disc_qq <= discriminator_qq;
                front_disc_qi <= discriminator_qi;
                front_disc_iq <= discriminator_iq;
                previous_i[front_channel_safe] <= front_gated_i;
                previous_q[front_channel_safe] <= front_gated_q;
                decimator_phase[front_channel_safe] <= ~front_decimated;
                front_state <= FRONT_DISC_SUM;
            end

            if (front_state == FRONT_DISC_SUM) begin
                front_disc_dot <= discriminator_dot;
                front_disc_cross <= discriminator_cross;
                front_state <= FRONT_CORDIC_INIT;
            end

            if (front_state == FRONT_CORDIC_INIT) begin
                cordic_iteration <= 5'd0;
                if (front_disc_dot < 0) begin
                    cordic_x <= -{{2{front_disc_dot[32]}}, front_disc_dot};
                    cordic_y <= -{{2{front_disc_cross[32]}}, front_disc_cross};
                    cordic_z <= (front_disc_cross >= 0) ? 18'sd51472 : -18'sd51472;
                end else begin
                    cordic_x <= {{2{front_disc_dot[32]}}, front_disc_dot};
                    cordic_y <= {{2{front_disc_cross[32]}}, front_disc_cross};
                    cordic_z <= 18'sd0;
                end
                front_state <= FRONT_CORDIC;
            end

            if (front_state == FRONT_CORDIC) begin
                cordic_x <= cordic_next_x;
                cordic_y <= cordic_next_y;
                cordic_z <= cordic_next_z;
                if (cordic_iteration == 5'd15) begin
                    front_final_cordic_z <= cordic_next_z;
                    front_state <= FRONT_FM_SCALE;
                end else begin
                    cordic_iteration <= cordic_iteration + 1'b1;
                end
            end

            // Post-CORDIC arithmetic is staged so the final z/scale result,
            // deemphasis products, product sums, quantization, and FIFO RAM
            // write do not share a long path to the distributed FIFO.
            if (front_state == FRONT_FM_SCALE) begin
                front_fm_sample <= saturate_q15(fm_demod_q15_wide);
                front_state <= FRONT_DEEMPH_MUL;
            end

            if (front_state == FRONT_DEEMPH_MUL) begin
                front_deemph_current_product <= front_fm_sample * DEEMPH_B0_Q17;
                front_deemph_previous_product <= deemph_previous_input[active_channel] * DEEMPH_B0_Q17;
                front_deemph_feedback_product <= deemph_previous_output[active_channel] * DEEMPH_FB_Q17;
                front_state <= FRONT_DEEMPH_SUM0;
            end

            if (front_state == FRONT_DEEMPH_SUM0) begin
                front_deemph_sum01 <= deemph_sum01_next;
                front_state <= FRONT_DEEMPH_SUM1;
            end

            if (front_state == FRONT_DEEMPH_SUM1) begin
                front_deemph_sum_all <= deemph_sum_all_next;
                front_state <= FRONT_DEEMPH_QUANT;
            end

            if (front_state == FRONT_DEEMPH_QUANT) begin
                front_deemph_output <= deemph_output_next;
                front_state <= FRONT_FIFO_WRITE;
            end

            if (front_state == FRONT_FIFO_WRITE) begin
                deemph_previous_input[active_channel] <= front_fm_sample;
                deemph_previous_output[active_channel] <= front_deemph_output;
                audio_fifo_write <= audio_fifo_write + 1'b1;
                front_state <= FRONT_IDLE;
            end

            if (fifo_pop) begin
                audio_fifo_read <= audio_fifo_read + 1'b1;
                fir_channel <= fifo_channel_current;
                if (audio_history_count[fifo_channel_current] < (TAP_AW+1)'(AUDIO_TAPS))
                    audio_history_count[fifo_channel_current] <=
                        audio_history_count[fifo_channel_current] + 1'b1;
                audio_write_pointer[fifo_channel_current] <=
                    wrap_audio_pointer(audio_write_pointer[fifo_channel_current]);
                if (fifo_decimated_current) begin
                    fir_head <= audio_write_pointer[fifo_channel_current];
                    fir_valid_count <= (audio_history_count[fifo_channel_current] < (TAP_AW+1)'(AUDIO_TAPS)) ?
                                        audio_history_count[fifo_channel_current] + 1'b1 :
                                        audio_history_count[fifo_channel_current];
                    fir_tap_index <= {TAP_AW{1'b0}};
                    fir_accumulator <= 42'sd0;
                    fir_state <= FIR_MAC;
                end else begin
                    fir_state <= FIR_IDLE;
                end
            end else if (fir_state == FIR_MAC) begin
                fir_accumulator <= fir_next_accumulator;
                if (fir_tap_index == TAP_AW'(AUDIO_TAPS-1)) begin
                    m_data <= {fir_channel + 5'd1, audio_gain_output};
                    m_valid <= 1'b1;
                    fir_state <= FIR_IDLE;
                end else begin
                    fir_tap_index <= fir_tap_index + 1'b1;
                end
            end

            case ({(front_state == FRONT_FIFO_WRITE), fifo_pop})
                2'b10: audio_fifo_count <= audio_fifo_count + 1'b1;
                2'b01: audio_fifo_count <= audio_fifo_count - 1'b1;
                default: audio_fifo_count <= audio_fifo_count;
            endcase
        end
    end
endmodule
