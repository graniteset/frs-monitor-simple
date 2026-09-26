// Board-independent, oversample-2 sparse 32-bin channelizer.
//
// This implementation is deliberately a small, time-multiplexed direct
// polyphase-equivalent FIR: two complex taps are accumulated per fabric
// clock, and only configured bins are computed. For 22 outputs and a 241-tap
// prototype it performs 22*121 MAC clocks per 16 input samples. A 512-sample
// history ring lets the input continue while that work runs; the system clock
// must be fast enough that a frame finishes before the next frame boundary.
module sparse_channelizer #(
    parameter integer CHANNELS = 22,
    parameter integer TAPS = 241,
    parameter integer FRAME_SAMPLES = 16,
    parameter integer HISTORY_SIZE = 512,
    parameter MAP_FILE = "fpga/coeffs/channel_map_band1.memh",
    parameter COEFF_FILE = "fpga/coeffs/channel_modulated_q17.memh"
) (
    input  wire                 aclk,
    input  wire                 aresetn,
    input  wire signed [15:0]   s_i,
    input  wire signed [15:0]   s_q,
    input  wire                 s_valid,
    output wire                 s_ready,
    output wire [36:0]          m_data, // {channel[4:0], I[15:0], Q[15:0]}
    output wire                 m_valid,
    input  wire                 m_ready,
    output reg                  overrun
);
    localparam integer HIST_AW = $clog2(HISTORY_SIZE);
    localparam integer FRAME_AW = $clog2(FRAME_SAMPLES);
    localparam integer MAP_AW = (CHANNELS <= 2) ? 1 : $clog2(CHANNELS);
    localparam integer MAP_FILE_WIDTH = 10;
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_MAC = 3'd1;
    localparam [2:0] ST_DRAIN = 3'd2;
    localparam [2:0] ST_OUTPUT = 3'd3;

    reg signed [15:0] history_i [0:HISTORY_SIZE-1];
    reg signed [15:0] history_q [0:HISTORY_SIZE-1];
    reg [MAP_FILE_WIDTH-1:0] channel_map [0:CHANNELS-1];
    reg [35:0] modulated_taps [0:32*TAPS-1];
    // Results are filled during the MAC phase, then read sequentially during
    // the output phase. Keep this small frame buffer out of the asynchronous
    // reset process so Vivado can implement it as distributed RAM rather than
    // resettable registers. It contains only CHANNELS words and is not large
    // enough to justify consuming a block RAM.
    (* ram_style = "distributed" *) reg [36:0] channel_results [0:CHANNELS-1];

    initial begin
        $readmemh(MAP_FILE, channel_map);
        $readmemh(COEFF_FILE, modulated_taps);
    end

    reg [2:0] state;
    reg [HIST_AW-1:0] write_index;
    reg [HIST_AW-1:0] frame_end_index;
    reg [HIST_AW:0] history_count;
    reg [HIST_AW:0] frame_history_count;
    reg [FRAME_AW-1:0] frame_count;
    reg frame_parity;
    reg active_frame_parity;
    reg [MAP_AW-1:0] map_index;
    reg [7:0] tap_index;
    reg [MAP_AW-1:0] output_index;
    reg signed [41:0] accum_i;
    reg signed [41:0] accum_q;

    // MAC pipeline: dynamic history/coefficient selection, DSP products,
    // per-tap complex sums, pair reduction, then the running accumulator.
    // Valid/last travel alongside the datapath; the scheduler pauses between
    // channels until the final pair has drained into the accumulator.
    reg mac_s1_valid, mac_s1_last;
    reg mac_s2_valid, mac_s2_last;
    reg mac_s3_valid, mac_s3_last;
    reg mac_s4_valid, mac_s4_last;
    reg mac_addr_valid, mac_addr_last;
    reg signed [15:0] mac_s1_xi0, mac_s1_xq0, mac_s1_xi1, mac_s1_xq1;
    reg signed [17:0] mac_s1_cr0, mac_s1_ci0, mac_s1_cr1, mac_s1_ci1;
    reg signed [33:0] mac_s2_p0_ii, mac_s2_p0_qq, mac_s2_p0_iq, mac_s2_p0_qi;
    reg signed [33:0] mac_s2_p1_ii, mac_s2_p1_qq, mac_s2_p1_iq, mac_s2_p1_qi;
    reg signed [35:0] mac_s3_i0, mac_s3_i1, mac_s3_q0, mac_s3_q1;
    reg signed [35:0] mac_s4_term_i, mac_s4_term_q;
    reg [12:0] mac_addr_coeff0, mac_addr_coeff1;
    reg [HIST_AW-1:0] mac_addr_hist0, mac_addr_hist1;
    reg mac_addr_coeff1_valid, mac_addr_hist0_valid, mac_addr_hist1_valid;
    reg [4:0] active_bin;
    reg [4:0] active_channel;

    wire [MAP_AW-1:0] next_map_index =
        (map_index == MAP_AW'(CHANNELS-1)) ? {MAP_AW{1'b0}} : map_index + 1'b1;
    wire [MAP_FILE_WIDTH-1:0] next_map_word = channel_map[next_map_index];

    wire [12:0] coeff_addr0 = 13'(active_bin * TAPS + 32'(tap_index));
    wire [12:0] coeff_addr1 = coeff_addr0 + 13'd1;
    wire [35:0] coeff0 = modulated_taps[mac_addr_coeff0];
    wire [35:0] coeff1 = mac_addr_coeff1_valid ?
                         modulated_taps[mac_addr_coeff1] : 36'd0;

    wire [HIST_AW-1:0] hist_addr0 = frame_end_index - tap_index;
    wire [HIST_AW-1:0] hist_addr1 = frame_end_index - tap_index - 1'b1;
    wire valid_history0 = {2'b00, tap_index} < frame_history_count;
    wire valid_history1 = ({2'b00, tap_index} + 10'd1) < frame_history_count;
    wire signed [15:0] xi0 = mac_addr_hist0_valid ? history_i[mac_addr_hist0] : 16'sd0;
    wire signed [15:0] xq0 = mac_addr_hist0_valid ? history_q[mac_addr_hist0] : 16'sd0;
    wire signed [15:0] xi1 = mac_addr_hist1_valid ? history_i[mac_addr_hist1] : 16'sd0;
    wire signed [15:0] xq1 = mac_addr_hist1_valid ? history_q[mac_addr_hist1] : 16'sd0;
    wire signed [17:0] cr0 = $signed(coeff0[35:18]);
    wire signed [17:0] ci0 = $signed(coeff0[17:0]);
    wire signed [17:0] cr1 = $signed(coeff1[35:18]);
    wire signed [17:0] ci1 = $signed(coeff1[17:0]);

    wire signed [35:0] mac_s3_i0_next =
        {{2{mac_s2_p0_ii[33]}}, mac_s2_p0_ii} - {{2{mac_s2_p0_qq[33]}}, mac_s2_p0_qq};
    wire signed [35:0] mac_s3_i1_next =
        {{2{mac_s2_p1_ii[33]}}, mac_s2_p1_ii} - {{2{mac_s2_p1_qq[33]}}, mac_s2_p1_qq};
    wire signed [35:0] mac_s3_q0_next =
        {{2{mac_s2_p0_iq[33]}}, mac_s2_p0_iq} + {{2{mac_s2_p0_qi[33]}}, mac_s2_p0_qi};
    wire signed [35:0] mac_s3_q1_next =
        {{2{mac_s2_p1_iq[33]}}, mac_s2_p1_iq} + {{2{mac_s2_p1_qi[33]}}, mac_s2_p1_qi};
    wire signed [35:0] mac_s4_term_i_next = mac_s3_i0 + mac_s3_i1;
    wire signed [35:0] mac_s4_term_q_next = mac_s3_q0 + mac_s3_q1;
    wire signed [41:0] next_accum_i = accum_i + {{6{mac_s4_term_i[35]}}, mac_s4_term_i};
    wire signed [41:0] next_accum_q = accum_q + {{6{mac_s4_term_q[35]}}, mac_s4_term_q};

    function signed [15:0] q32_to_q15;
        input signed [41:0] value;
        reg signed [42:0] rounded;
        reg signed [25:0] scaled;
        begin
            rounded = (value >= 0) ? (value + 43'sd65536) :
                                      (value - 43'sd65536);
            scaled = 26'($signed(rounded) >>> 17);
            if (scaled > 26'sd32767)
                q32_to_q15 = 16'sd32767;
            else if (scaled < -26'sd32768)
                q32_to_q15 = -16'sd32768;
            else
                q32_to_q15 = scaled[15:0];
        end
    endfunction

    function signed [15:0] negate_q15;
        input signed [15:0] value;
        begin
            negate_q15 = (value == -16'sd32768) ? 16'sd32767 : -value;
        end
    endfunction

    assign s_ready = 1'b1;
    assign m_valid = (state == ST_OUTPUT);
    assign m_data = channel_results[output_index];

    // Like the DDC history, the IQ ring has no bulk reset; the valid-sample
    // count masks old locations during startup and preserves RAM inference.
    always @(posedge aclk) begin
        if (s_valid && s_ready) begin
            history_i[write_index] <= s_i;
            history_q[write_index] <= s_q;
        end
    end

    // Stage the selected sample/coefficient words, then the products, before
    // reducing the complex products into the running accumulator. The eight
    // DSP multiplies still accept one two-tap pair every clock.
    always @(posedge aclk) begin
        if (state == ST_MAC) begin
            mac_addr_coeff0 <= coeff_addr0;
            mac_addr_coeff1 <= coeff_addr1;
            mac_addr_coeff1_valid <= (tap_index < 8'(TAPS-1));
            mac_addr_hist0 <= hist_addr0;
            mac_addr_hist1 <= hist_addr1;
            mac_addr_hist0_valid <= valid_history0;
            mac_addr_hist1_valid <= (tap_index < 8'(TAPS-1)) && valid_history1;
        end
        if (mac_addr_valid) begin
            mac_s1_xi0 <= xi0;
            mac_s1_xq0 <= xq0;
            mac_s1_xi1 <= xi1;
            mac_s1_xq1 <= xq1;
            mac_s1_cr0 <= cr0;
            mac_s1_ci0 <= ci0;
            mac_s1_cr1 <= cr1;
            mac_s1_ci1 <= ci1;
        end
        if (mac_s1_valid) begin
            mac_s2_p0_ii <= mac_s1_xi0 * mac_s1_cr0;
            mac_s2_p0_qq <= mac_s1_xq0 * mac_s1_ci0;
            mac_s2_p0_iq <= mac_s1_xi0 * mac_s1_ci0;
            mac_s2_p0_qi <= mac_s1_xq0 * mac_s1_cr0;
            mac_s2_p1_ii <= mac_s1_xi1 * mac_s1_cr1;
            mac_s2_p1_qq <= mac_s1_xq1 * mac_s1_ci1;
            mac_s2_p1_iq <= mac_s1_xi1 * mac_s1_ci1;
            mac_s2_p1_qi <= mac_s1_xq1 * mac_s1_cr1;
        end
        if (mac_s2_valid) begin
            mac_s3_i0 <= mac_s3_i0_next;
            mac_s3_i1 <= mac_s3_i1_next;
            mac_s3_q0 <= mac_s3_q0_next;
            mac_s3_q1 <= mac_s3_q1_next;
        end
        if (mac_s3_valid) begin
            mac_s4_term_i <= mac_s4_term_i_next;
            mac_s4_term_q <= mac_s4_term_q_next;
        end
    end

    // This result store is intentionally not reset. A result is written only
    // after its final pipelined term has been included in the accumulator.
    always @(posedge aclk) begin
        if (mac_s4_valid) begin
            if (mac_s4_last) begin
                channel_results[map_index] <= {
                    active_channel,
                    (active_frame_parity && active_bin[0]) ?
                        negate_q15(q32_to_q15(next_accum_i)) :
                        q32_to_q15(next_accum_i),
                    (active_frame_parity && active_bin[0]) ?
                        negate_q15(q32_to_q15(next_accum_q)) :
                        q32_to_q15(next_accum_q)
                };
            end
        end
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state              <= ST_IDLE;
            write_index        <= {HIST_AW{1'b0}};
            frame_end_index    <= {HIST_AW{1'b0}};
            history_count      <= {(HIST_AW+1){1'b0}};
            frame_history_count <= {(HIST_AW+1){1'b0}};
            frame_count        <= {FRAME_AW{1'b0}};
            frame_parity       <= 1'b0;
            active_frame_parity <= 1'b0;
            map_index          <= {MAP_AW{1'b0}};
            tap_index          <= 8'd0;
            output_index       <= {MAP_AW{1'b0}};
            active_bin         <= 5'd0;
            active_channel     <= 5'd0;
            accum_i            <= 42'sd0;
            accum_q            <= 42'sd0;
            mac_addr_valid     <= 1'b0;
            mac_addr_last      <= 1'b0;
            mac_s1_valid       <= 1'b0;
            mac_s1_last        <= 1'b0;
            mac_s2_valid       <= 1'b0;
            mac_s2_last        <= 1'b0;
            mac_s3_valid       <= 1'b0;
            mac_s3_last        <= 1'b0;
            mac_s4_valid       <= 1'b0;
            mac_s4_last        <= 1'b0;
            overrun            <= 1'b0;
        end else begin
            mac_addr_valid <= (state == ST_MAC);
            mac_addr_last <= (state == ST_MAC) &&
                             (9'(tap_index) + 9'd2 >= 9'(TAPS));
            mac_s1_valid <= mac_addr_valid;
            mac_s1_last <= mac_addr_last;
            mac_s2_valid <= mac_s1_valid;
            mac_s2_last <= mac_s1_last;
            mac_s3_valid <= mac_s2_valid;
