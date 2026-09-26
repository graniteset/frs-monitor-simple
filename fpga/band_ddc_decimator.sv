// Fixed-point single-band DDC + decimating low-pass stage.
//
// Input/output samples are packed nowhere here: I and Q use separate signed
// Q1.15 ports. The AXI clock is a faster fabric clock; accepted samples may
// arrive with gaps (e.g. 6.4 MS/s on a 100 MHz clock). One real multiply per
// I/Q component is reused across FIR taps. Input backpressure is asserted at
// decimation boundaries while the previous FIR result is being computed.
// Use an upstream FIFO if the physical ADC stream cannot be paused.
module band_ddc_decimator #(
    parameter integer DECIMATION = 16,
    parameter integer TAPS = 205,
    parameter [8:0] PHASE_STEP = 9'd199,
    parameter [8:0] INITIAL_PHASE = 9'd330,
    parameter TAPS_FILE = "fpga/coeffs/subband_q17.memh",
    parameter NCO_FILE = "fpga/coeffs/nco_q15_quarter.memh"
) (
    input  wire                  aclk,
    input  wire                  aresetn,
    input  wire signed [15:0]    s_i,
    input  wire signed [15:0]    s_q,
    input  wire                  s_valid,
    output wire                  s_ready,
    output reg  signed [15:0]    m_i,
    output reg  signed [15:0]    m_q,
    output reg                   m_valid,
    input  wire                  m_ready,
    output reg                   overrun
);
    localparam integer PTR_W = $clog2(TAPS);
    localparam integer DEC_W = (DECIMATION <= 2) ? 1 : $clog2(DECIMATION);
    localparam [DEC_W-1:0] DEC_LAST = DEC_W'(DECIMATION - 1);
    localparam [PTR_W-1:0] PTR_LAST = PTR_W'(TAPS - 1);

    reg signed [17:0] taps [0:TAPS-1];
    reg signed [15:0] history_i [0:TAPS-1];
    reg signed [15:0] history_q [0:TAPS-1];
    reg [15:0] sine_quarter [0:127];

    initial begin
        $readmemh(TAPS_FILE, taps);
        $readmemh(NCO_FILE, sine_quarter);
    end

    reg [8:0] phase;
    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W:0] history_count;
    reg [PTR_W:0] mac_history_count;
    reg [PTR_W-1:0] mac_head;
    reg [PTR_W-1:0] tap_index;
    reg [DEC_W-1:0] decim_count;
    reg mac_busy;
    reg mac_launch_pending;
    reg signed [41:0] acc_i;
    reg signed [41:0] acc_q;

    // Mixer pipeline metadata. A decimation-boundary sample is not allowed
    // to launch its FIR until its delayed mixer result has actually reached
    // the history ring.
    reg mix_s0_valid, mix_s1_valid, mix_s2_valid, mix_s3_valid, mix_s4_valid;
    reg mix_s0_is_decim, mix_s1_is_decim, mix_s2_is_decim, mix_s3_is_decim, mix_s4_is_decim;
    reg [PTR_W-1:0] mix_s0_ptr, mix_s1_ptr, mix_s2_ptr, mix_s3_ptr, mix_s4_ptr;
    reg [PTR_W:0] mix_s0_history_count, mix_s1_history_count, mix_s2_history_count;
    reg [PTR_W:0] mix_s3_history_count, mix_s4_history_count;
    reg [8:0] mix_s0_phase;
    reg signed [15:0] mix_s0_i, mix_s0_q;
    reg signed [15:0] mix_s1_i, mix_s1_q, mix_s1_sin, mix_s1_cos;
    reg signed [31:0] mix_s2_ii, mix_s2_qs, mix_s2_is, mix_s2_qc;
    reg signed [32:0] mix_s3_i_sum, mix_s3_q_sum;
    reg signed [17:0] mix_s4_i_scaled, mix_s4_q_scaled;

    function [15:0] sin_q15;
        input [8:0] angle;
        reg [6:0] address;
        reg [15:0] magnitude;
        begin
            address = angle[6:0];
            case (angle[8:7])
                2'd0: magnitude = sine_quarter[address];
                2'd1: magnitude = (address == 0) ? 16'd32767 :
                                   sine_quarter[7'(8'd128-{1'b0,address})];
                2'd2: magnitude = sine_quarter[address];
                default: magnitude = (address == 0) ? 16'd32767 :
                                     sine_quarter[7'(8'd128-{1'b0,address})];
            endcase
            sin_q15 = angle[8] ? (16'd0 - magnitude) : magnitude;
        end
    endfunction

    wire signed [15:0] mix_s4_i_saturated = (mix_s4_i_scaled > 18'sd32767) ? 16'sd32767 :
                                               (mix_s4_i_scaled < -18'sd32768) ? -16'sd32768 :
                                               mix_s4_i_scaled[15:0];
    wire signed [15:0] mix_s4_q_saturated = (mix_s4_q_scaled > 18'sd32767) ? 16'sd32767 :
                                               (mix_s4_q_scaled < -18'sd32768) ? -16'sd32768 :
                                               mix_s4_q_scaled[15:0];

    wire signed [33:0] mix_s3_i_rounded = (mix_s3_i_sum >= 0) ?
        ($signed({mix_s3_i_sum[32], mix_s3_i_sum}) + 34'sd16384) :
        ($signed({mix_s3_i_sum[32], mix_s3_i_sum}) - 34'sd16384);
    wire signed [33:0] mix_s3_q_rounded = (mix_s3_q_sum >= 0) ?
        ($signed({mix_s3_q_sum[32], mix_s3_q_sum}) + 34'sd16384) :
        ($signed({mix_s3_q_sum[32], mix_s3_q_sum}) - 34'sd16384);
    wire signed [17:0] mix_s3_i_scaled = 18'($signed(mix_s3_i_rounded) >>> 15);
    wire signed [17:0] mix_s3_q_scaled = 18'($signed(mix_s3_q_rounded) >>> 15);
    wire signed [32:0] mix_s2_i_sum = $signed(mix_s2_ii) - $signed(mix_s2_qs);
    wire signed [32:0] mix_s2_q_sum = $signed(mix_s2_is) + $signed(mix_s2_qc);

    // Read oldest-to-newest while the ring buffer continues accepting newer
    // samples. This ordering prevents an incoming write from clobbering an
    // unread history value during a multi-cycle MAC.
    function [PTR_W-1:0] wrap_history_addr;
        input [PTR_W-1:0] head;
        input [PTR_W-1:0] offset;
        integer address;
        begin
            address = $signed({1'b0, head}) - $signed({1'b0, offset});
            if (address < 0)
                address = address + TAPS;
            wrap_history_addr = PTR_W'(address);
        end
    endfunction
    wire [PTR_W-1:0] history_addr = wrap_history_addr(mac_head, tap_index);
    wire history_sample_valid = {1'b0, tap_index} < mac_history_count;
    wire signed [15:0] history_sample_i = history_sample_valid ? history_i[history_addr] : 16'sd0;
    wire signed [15:0] history_sample_q = history_sample_valid ? history_q[history_addr] : 16'sd0;
    wire signed [33:0] product_i = history_sample_i * taps[tap_index];
    wire signed [33:0] product_q = history_sample_q * taps[tap_index];
    wire signed [41:0] next_acc_i = acc_i + {{8{product_i[33]}}, product_i};
    wire signed [41:0] next_acc_q = acc_q + {{8{product_q[33]}}, product_q};

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

    assign s_ready = (!m_valid || m_ready) &&
                     !((mac_busy || mac_launch_pending) && (decim_count == DEC_LAST));

    // Keep the sample ring as a synchronous-write memory so FPGA synthesis
    // can infer RAM instead of hundreds of resettable flip-flops. history_count
    // masks unwritten entries until the circular buffer has filled.
    // Five-stage mixer path: capture sample+phase, perform the NCO lookup,
    // register four products, register complex sums, then round/saturate and
    // commit the history word. Metadata follows the same valid pipeline.
    always @(posedge aclk) begin
        if (s_valid && s_ready) begin
            mix_s0_phase <= phase;
            mix_s0_i <= s_i;
            mix_s0_q <= s_q;
            mix_s0_ptr <= wr_ptr;
            mix_s0_is_decim <= (decim_count == DEC_LAST);
            mix_s0_history_count <= (history_count < (PTR_W+1)'(TAPS)) ?
                                    history_count + 1'b1 : history_count;
        end
        if (mix_s0_valid) begin
            mix_s1_i <= mix_s0_i;
            mix_s1_q <= mix_s0_q;
            mix_s1_sin <= $signed(sin_q15(mix_s0_phase));
            mix_s1_cos <= $signed(sin_q15(mix_s0_phase + 9'd128));
        end
        if (mix_s1_valid) begin
            mix_s2_ii <= mix_s1_i * mix_s1_cos;
            mix_s2_qs <= mix_s1_q * mix_s1_sin;
            mix_s2_is <= mix_s1_i * mix_s1_sin;
            mix_s2_qc <= mix_s1_q * mix_s1_cos;
        end
        if (mix_s2_valid) begin
            mix_s3_i_sum <= mix_s2_i_sum;
            mix_s3_q_sum <= mix_s2_q_sum;
        end
        if (mix_s3_valid) begin
            mix_s4_i_scaled <= mix_s3_i_scaled;
            mix_s4_q_scaled <= mix_s3_q_scaled;
        end
        if (mix_s4_valid) begin
            history_i[mix_s4_ptr] <= mix_s4_i_saturated;
            history_q[mix_s4_ptr] <= mix_s4_q_saturated;
        end
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            phase       <= INITIAL_PHASE;
            wr_ptr      <= {PTR_W{1'b0}};
            history_count <= {(PTR_W+1){1'b0}};
            mac_history_count <= {(PTR_W+1){1'b0}};
            mac_head    <= {PTR_W{1'b0}};
            tap_index   <= {PTR_W{1'b0}};
            // GNU Radio's sync-decimator emits its first item for input index
            // zero, then advances by DECIMATION samples each output.
            decim_count <= DEC_LAST;
            mac_busy    <= 1'b0;
            mac_launch_pending <= 1'b0;
            mix_s0_valid <= 1'b0;
            mix_s1_valid <= 1'b0;
            mix_s2_valid <= 1'b0;
            mix_s3_valid <= 1'b0;
            mix_s4_valid <= 1'b0;
            mix_s1_is_decim <= 1'b0;
            mix_s2_is_decim <= 1'b0;
            mix_s3_is_decim <= 1'b0;
            mix_s4_is_decim <= 1'b0;
            acc_i       <= 42'sd0;
            acc_q       <= 42'sd0;
            m_i         <= 16'sd0;
            m_q         <= 16'sd0;
            m_valid     <= 1'b0;
            overrun     <= 1'b0;
        end else begin
            mix_s0_valid <= s_valid && s_ready;
            mix_s1_valid <= mix_s0_valid;
            mix_s2_valid <= mix_s1_valid;
            mix_s3_valid <= mix_s2_valid;
            mix_s4_valid <= mix_s3_valid;
            mix_s1_is_decim <= mix_s0_is_decim;
            mix_s2_is_decim <= mix_s1_is_decim;
            mix_s3_is_decim <= mix_s2_is_decim;
            mix_s4_is_decim <= mix_s3_is_decim;
            mix_s1_ptr <= mix_s0_ptr;
            mix_s2_ptr <= mix_s1_ptr;
            mix_s3_ptr <= mix_s2_ptr;
            mix_s4_ptr <= mix_s3_ptr;
            mix_s1_history_count <= mix_s0_history_count;
            mix_s2_history_count <= mix_s1_history_count;
            mix_s3_history_count <= mix_s2_history_count;
            mix_s4_history_count <= mix_s3_history_count;

            if (m_valid && m_ready)
                m_valid <= 1'b0;

            if (s_valid && s_ready) begin
                if (history_count < (PTR_W+1)'(TAPS))
                    history_count <= history_count + 1'b1;
                wr_ptr <= (wr_ptr == PTR_LAST) ? {PTR_W{1'b0}} : wr_ptr + 1'b1;
                phase <= phase + PHASE_STEP;

                if (decim_count == DEC_LAST) begin
                    decim_count <= {DEC_W{1'b0}};
                    if (!mac_busy && !mac_launch_pending)
                        mac_launch_pending <= 1'b1;
                    else
                        overrun <= 1'b1;
                end else begin
                    decim_count <= decim_count + 1'b1;
                end
            end

            if (mix_s4_valid && mix_s4_is_decim) begin
                mac_launch_pending <= 1'b0;
                if (!mac_busy) begin
                    mac_busy  <= 1'b1;
                    mac_head  <= mix_s4_ptr;
                    mac_history_count <= mix_s4_history_count;
                    tap_index <= PTR_LAST;
                    acc_i     <= 42'sd0;
                    acc_q     <= 42'sd0;
                end else begin
                    overrun <= 1'b1;
                end
            end

            if (mac_busy) begin
                acc_i <= next_acc_i;
                acc_q <= next_acc_q;
                if (tap_index == 0) begin
                    m_i      <= q32_to_q15(next_acc_i);
                    m_q      <= q32_to_q15(next_acc_q);
                    m_valid  <= 1'b1;
                    mac_busy <= 1'b0;
                end else begin
                    tap_index <= tap_index - 1'b1;
                end
            end
        end
    end
endmodule
