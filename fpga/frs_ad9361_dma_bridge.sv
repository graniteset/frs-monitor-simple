// Live-AD9363 to FRS audio bridge for the PlutoSky CLG400 system.
//
// The ADI RX user interface cannot be backpressured. This module therefore
// accepts I/Q into a small dual-clock FIFO and lets the FRS DSP apply its own
// ready/valid flow control behind that boundary. The serialized FRS records
// are packed two-at-a-time into the existing 64-bit receive-DMA write FIFO.
//
// DMA payload format (little-endian 64-bit words):
//   [20:0]  record 0 = {channel[4:0], signed_audio_q1_15[15:0]}
//   [41:21] record 1 = same; [61:42] reserved zero; [63:62] record count=2
// A capture descriptor should use a byte length divisible by eight.
module frs_ad9361_dma_bridge #(
    parameter integer TEST_MODE = 0,
    parameter integer RX_FIFO_ADDR_WIDTH = 6,
    parameter integer OFFSET_BINARY_INPUT = 0,
    parameter integer TEST_ON_SAMPLES = 320_000,
    parameter integer TEST_OFF_SAMPLES = 3_200_000,
    // TEST_PHASE_STEP is retained for compatibility with existing Vivado
    // module-reference metadata. The explicit CARRIER alias documents what
    // the phase increment controls while allowing older BD wrappers to build.
    parameter [31:0] TEST_PHASE_STEP = 32'h9c80_0000,
    parameter [31:0] TEST_CARRIER_PHASE_STEP = TEST_PHASE_STEP,
    parameter [31:0] TEST_MESSAGE_PHASE_STEP = 32'h000a_3d71,
    parameter [31:0] TEST_DEVIATION_PHASE_STEP = 32'd671_089,
    parameter TEST_SINE_LUT = "fpga/coeffs/test_sine_q15_1024.memh",
    parameter DDC_TAPS = "fpga/coeffs/subband_q17.memh",
    parameter NCO_TAPS = "fpga/coeffs/nco_q15_quarter.memh",
    parameter BAND1_MAP = "fpga/coeffs/channel_map_band1.memh",
    parameter BAND2_MAP = "fpga/coeffs/channel_map_band2.memh",
    parameter PFB_TAPS = "fpga/coeffs/channel_modulated_q17.memh",
    parameter AUDIO_TAPS = "fpga/coeffs/audio_q17.memh"
) (
    input  wire        adc_clk,
    input  wire        adc_resetn,
    input  wire        dsp_clk,
    input  wire        dsp_resetn,
    input  wire [15:0] adc0_word,
    input  wire [15:0] adc1_word,
    input  wire        valid0,
    input  wire        valid1,
    input  wire        enable0,
    input  wire        enable1,

    (* X_INTERFACE_INFO = "analog.com:interface:fifo_wr_rtl:1.0 fifo_wr EN" *)
    output reg         fifo_wr_en,
    (* X_INTERFACE_INFO = "analog.com:interface:fifo_wr_rtl:1.0 fifo_wr DATA" *)
    output reg  [63:0] fifo_wr_din,
    (* X_INTERFACE_INFO = "analog.com:interface:fifo_wr_rtl:1.0 fifo_wr OVERFLOW" *)
    input  wire        fifo_wr_overflow,
    (* X_INTERFACE_INFO = "analog.com:interface:fifo_wr_rtl:1.0 fifo_wr SYNC" *)
    output wire        fifo_wr_sync,
    (* X_INTERFACE_INFO = "analog.com:interface:fifo_wr_rtl:1.0 fifo_wr XFER_REQ" *)
    input  wire        fifo_wr_xfer_req,

    (* X_INTERFACE_IGNORE = "true" *) output wire rx_fifo_overrun,
    (* X_INTERFACE_IGNORE = "true" *) output reg status_overflow_seen,
    (* X_INTERFACE_IGNORE = "true" *) output wire pair_mismatch_seen,
    (* X_INTERFACE_IGNORE = "true" *) output wire band1_overrun,
    (* X_INTERFACE_IGNORE = "true" *) output wire band2_overrun,
    (* X_INTERFACE_IGNORE = "true" *) output wire invalid_channel
);
    wire signed [11:0] decoded_i;
    wire signed [11:0] decoded_q;
    wire decoded_valid;
    wire pair_mismatch;
    wire input_drop;
    reg pair_mismatch_sticky;
    wire capture_active = fifo_wr_xfer_req;
    reg adc_reset_stage1;
    reg adc_reset_stage2;
    reg dsp_reset_stage1;
    reg dsp_reset_stage2;
    wire adc_domain_resetn = adc_reset_stage2;
    wire dsp_domain_resetn = dsp_reset_stage2;
    wire core_aresetn = dsp_domain_resetn && capture_active;
    reg capture_active_sync1;
    reg capture_active_sync2;
    wire [23:0] sample_fifo_head;
    wire sample_fifo_empty;
    wire sample_fifo_full;
    wire sample_fifo_wr_overflow;
    wire radio_source_ready;
    wire sample_pop = !sample_fifo_empty &&
                      ((TEST_MODE != 0) || !capture_active || radio_source_ready);
    wire sample_push = (TEST_MODE == 0) && decoded_valid && capture_active_sync2;

    always @(posedge adc_clk or negedge adc_resetn) begin
        if (!adc_resetn) begin
            adc_reset_stage1 <= 1'b0;
            adc_reset_stage2 <= 1'b0;
        end else begin
            adc_reset_stage1 <= 1'b1;
            adc_reset_stage2 <= adc_reset_stage1;
        end
    end
    always @(posedge dsp_clk or negedge dsp_resetn) begin
        if (!dsp_resetn) begin
            dsp_reset_stage1 <= 1'b0;
            dsp_reset_stage2 <= 1'b0;
        end else begin
            dsp_reset_stage1 <= 1'b1;
            dsp_reset_stage2 <= dsp_reset_stage1;
        end
    end

    always @(posedge adc_clk or negedge adc_domain_resetn) begin
        if (!adc_domain_resetn) begin
            capture_active_sync1 <= 1'b0;
            capture_active_sync2 <= 1'b0;
        end else begin
            capture_active_sync1 <= capture_active;
            capture_active_sync2 <= capture_active_sync1;
        end
    end

    frs_ad9361_rx_adapter #(
        .OFFSET_BINARY_INPUT(OFFSET_BINARY_INPUT)
    ) input_adapter (
        .rx_clk(adc_clk),
        .adc_data_i(adc0_word), .adc_data_q(adc1_word),
        .adc_valid_i(valid0), .adc_valid_q(valid1),
        .adc_enable_i(enable0), .adc_enable_q(enable1),
        .core_ready(!sample_fifo_full),
        .sample_i(decoded_i), .sample_q(decoded_q),
        .sample_valid(decoded_valid), .pair_mismatch(pair_mismatch),
        .drop_event(input_drop)
    );

    // Keep every ADC-domain state element on the local reset, whose assertion
    // is asynchronous but whose release is synchronized to adc_clk above.
    always @(posedge adc_clk or negedge adc_domain_resetn) begin
        if (!adc_domain_resetn)
            pair_mismatch_sticky <= 1'b0;
        else if (pair_mismatch)
            pair_mismatch_sticky <= 1'b1;
    end

    frs_async_fifo #(.WIDTH(24), .ADDR_WIDTH(RX_FIFO_ADDR_WIDTH)) rx_fifo (
        .wr_clk(adc_clk), .wr_resetn(adc_domain_resetn), .wr_en(sample_push),
        .din({decoded_i, decoded_q}), .full(sample_fifo_full),
        .wr_overflow(sample_fifo_wr_overflow),
        .rd_clk(dsp_clk), .rd_resetn(dsp_domain_resetn), .rd_en(sample_pop),
        .dout(sample_fifo_head), .empty(sample_fifo_empty)
    );

    assign rx_fifo_overrun = sample_fifo_wr_overflow || input_drop;
    wire signed [11:0] radio_i = $signed(sample_fifo_head[23:12]);
    wire signed [11:0] radio_q = $signed(sample_fifo_head[11:0]);
    wire [31:0] radio_q15 = {radio_i, 4'b0000, radio_q, 4'b0000};
    wire [31:0] test_q15;
    wire test_valid;
    wire test_source_ready;
    wire test_mux_ready;
    reg [2:0] test_cadence_phase;
    reg [4:0] test_cadence_countdown;
    wire test_sample_tick = (TEST_MODE == 0) ||
                            (test_cadence_countdown == 0);
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] selected_q15;
    /* verilator lint_on UNUSEDSIGNAL */
    wire selected_valid;
    wire selected_ready;

    frs_fm_test_source #(
        .ON_SAMPLES(TEST_ON_SAMPLES), .OFF_SAMPLES(TEST_OFF_SAMPLES),
        .CARRIER_PHASE_STEP(TEST_CARRIER_PHASE_STEP),
        .MESSAGE_PHASE_STEP(TEST_MESSAGE_PHASE_STEP),
        .DEVIATION_PHASE_STEP(TEST_DEVIATION_PHASE_STEP),
        .SINE_LUT(TEST_SINE_LUT)
    ) test_source (
        .aclk(dsp_clk), .aresetn(core_aresetn), .enable(TEST_MODE != 0),
        .m_axis_tdata(test_q15),
        .m_axis_tvalid(test_valid),
        .m_axis_tready(test_source_ready)
    );

    axis_iq_mux source_mux (
        .aclk(dsp_clk), .aresetn(core_aresetn), .select(TEST_MODE != 0),
        .a_tdata(radio_q15),
        .a_tvalid((TEST_MODE == 0) && !sample_fifo_empty),
        .a_tready(radio_source_ready),
        .b_tdata(test_q15), .b_tvalid(test_valid && test_sample_tick),
        .b_tready(test_mux_ready), .m_tdata(selected_q15),
        .m_tvalid(selected_valid), .m_tready(selected_ready)
    );

    // 100 MHz core clock to the reference 6.4 MS/s input cadence:
    // five 16-clock intervals and three 15-clock intervals per eight samples.
    assign test_source_ready = test_mux_ready && test_sample_tick;
    always @(posedge dsp_clk or negedge core_aresetn) begin
        if (!core_aresetn) begin
            test_cadence_phase <= 3'd0;
            test_cadence_countdown <= 5'd0;
        end else if (TEST_MODE != 0) begin
            if (test_cadence_countdown != 0) begin
                test_cadence_countdown <= test_cadence_countdown - 1'b1;
            end else if (test_valid && test_mux_ready) begin
                test_cadence_countdown <= (test_cadence_phase < 5) ? 5'd15 : 5'd14;
                test_cadence_phase <= test_cadence_phase + 1'b1;
            end
        end
    end

    wire signed [11:0] selected_i = $signed(selected_q15[31:20]);
    wire signed [11:0] selected_q = $signed(selected_q15[15:4]);
    wire [20:0] audio_record;
    wire audio_valid;
    reg have_first_record;
    reg [20:0] first_record;
    reg packed_word_valid;
    reg [63:0] packed_word;
    reg [1:0] fifo_write_response_wait;
    wire audio_ready = !packed_word_valid;

    frs_receive_core #(
        .DDC_TAPS(DDC_TAPS), .NCO_TAPS(NCO_TAPS),
        .BAND1_MAP(BAND1_MAP), .BAND2_MAP(BAND2_MAP),
        .PFB_TAPS(PFB_TAPS), .AUDIO_TAPS(AUDIO_TAPS)
    ) receive_path (
        .aclk(dsp_clk), .aresetn(core_aresetn),
        .s_adc_i(selected_i), .s_adc_q(selected_q),
        .s_valid(selected_valid), .s_ready(selected_ready),
        .threshold_q30(33'd0), .m_audio_data(audio_record),
        .m_audio_valid(audio_valid), .m_audio_ready(audio_ready),
        .band1_overrun(band1_overrun), .band2_overrun(band2_overrun),
        .invalid_channel(invalid_channel)
    );
    // Pair records into 64-bit DMA words. Keep the completed word stable
    // until the ADI DMAC reports an active transfer.
    always @(posedge dsp_clk or negedge dsp_domain_resetn) begin
        if (!dsp_domain_resetn) begin
            have_first_record <= 1'b0;
            first_record <= 21'b0;
            packed_word_valid <= 1'b0;
            packed_word <= 64'b0;
            fifo_write_response_wait <= 2'd0;
            fifo_wr_en <= 1'b0;
            fifo_wr_din <= 64'b0;
            status_overflow_seen <= 1'b0;
        end else if (!capture_active) begin
            have_first_record <= 1'b0;
            first_record <= 21'b0;
            packed_word_valid <= 1'b0;
            packed_word <= 64'b0;
            fifo_write_response_wait <= 2'd0;
            fifo_wr_en <= 1'b0;
            fifo_wr_din <= 64'b0;
            status_overflow_seen <= 1'b0;
        end else begin
            fifo_wr_en <= 1'b0;
            if (fifo_wr_overflow)
                status_overflow_seen <= 1'b1;
            // The ADI fifo_wr_xfer_req means "DMA descriptor active", not
            // "this beat was accepted". src_fifo_inf exposes no ready pin;
            // instead fifo_wr_overflow is a registered rejection indication.
            // Keep one word in flight and don't retire it until that delayed
            // result is known. This also leaves time for the DMAC's internal
            // request FIFO to become ready at descriptor start.
            if (fifo_write_response_wait == 2'd2) begin
                fifo_write_response_wait <= 2'd1;
            end else if (fifo_write_response_wait == 2'd1) begin
                fifo_write_response_wait <= 2'd0;
                if (fifo_wr_overflow) begin
                    status_overflow_seen <= 1'b1;
                    // Keep packed_word_valid set and retry the identical beat.
                end else begin
                    packed_word_valid <= 1'b0;
                end
            end else if (packed_word_valid && fifo_wr_xfer_req) begin
                fifo_wr_din <= packed_word;
                fifo_wr_en <= 1'b1;
                fifo_write_response_wait <= 2'd2;
            end
            if (audio_valid && audio_ready) begin
                if (!have_first_record) begin
                    first_record <= audio_record;
                    have_first_record <= 1'b1;
                end else begin
                    packed_word <= {2'b10, 20'b0, audio_record, first_record};
                    packed_word_valid <= 1'b1;
                    have_first_record <= 1'b0;
                end
            end
        end
    end

    assign fifo_wr_sync = 1'b1;
    assign pair_mismatch_seen = pair_mismatch_sticky;
endmodule
