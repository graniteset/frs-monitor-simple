// Single-channel 121-tap audio low-pass FIR and decimate-by-two stage.
// Input and output are signed Q1.15; taps are signed Q1.17 in audio_q17.memh.
// The one-product-per-clock MAC finishes long before the next 25 kS/s sample.
module audio_fir_decimator #(
    parameter integer TAPS = 121,
    parameter AUDIO_TAPS_FILE = "fpga/coeffs/audio_q17.memh"
) (
    input  wire                 aclk,
    input  wire                 aresetn,
    input  wire signed [15:0]   s_audio_q15,
    input  wire                 s_valid,
    output wire                 s_ready,
    output reg  signed [15:0]   m_audio_q15,
    output reg                  m_valid,
    input  wire                 m_ready
);
    localparam integer PTR_W = $clog2(TAPS);
    localparam [PTR_W-1:0] PTR_LAST = PTR_W'(TAPS-1);

    reg signed [17:0] taps [0:TAPS-1];
    reg signed [15:0] history [0:TAPS-1];
    reg [PTR_W-1:0] write_index;
    reg [PTR_W-1:0] frame_end_index;
    reg [PTR_W:0] history_count;
    reg decimate_phase;
    reg mac_busy;
    reg [PTR_W-1:0] tap_index;
    reg signed [41:0] accumulator;

    initial $readmemh(AUDIO_TAPS_FILE, taps);

    function [PTR_W-1:0] wrap_addr;
        input [PTR_W-1:0] head;
        input [PTR_W-1:0] offset;
        integer address;
        begin
            address = integer'(head) - integer'(offset);
            if (address < 0)
                address = address + TAPS;
            wrap_addr = PTR_W'(address);
        end
    endfunction

    wire [PTR_W-1:0] history_addr = wrap_addr(frame_end_index, tap_index);
    wire history_valid = {1'b0, tap_index} < history_count;
    wire signed [15:0] history_sample = history_valid ? history[history_addr] : 16'sd0;
    wire signed [33:0] product = history_sample * taps[tap_index];
    wire signed [41:0] next_accumulator = accumulator + {{8{product[33]}}, product};

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

    assign s_ready = !mac_busy && (!m_valid || m_ready);

    // Synchronous write keeps the delay line eligible for FPGA RAM inference.
    always @(posedge aclk) begin
        if (s_valid && s_ready)
            history[write_index] <= s_audio_q15;
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            write_index <= {PTR_W{1'b0}};
            frame_end_index <= {PTR_W{1'b0}};
            history_count <= {(PTR_W+1){1'b0}};
            decimate_phase <= 1'b1;
            mac_busy <= 1'b0;
            tap_index <= {PTR_W{1'b0}};
            accumulator <= 42'sd0;
            m_audio_q15 <= 16'sd0;
            m_valid <= 1'b0;
        end else begin
            if (m_valid && m_ready)
                m_valid <= 1'b0;

            if (s_valid && s_ready) begin
                write_index <= (write_index == PTR_LAST) ? {PTR_W{1'b0}} : write_index + 1'b1;
                if (history_count < (PTR_W+1)'(TAPS))
                    history_count <= history_count + 1'b1;
                if (decimate_phase) begin
                    decimate_phase <= 1'b0;
                    frame_end_index <= write_index;
                    tap_index <= {PTR_W{1'b0}};
                    accumulator <= 42'sd0;
                    mac_busy <= 1'b1;
                end else begin
                    decimate_phase <= 1'b1;
                end
            end

            if (mac_busy) begin
                accumulator <= next_accumulator;
                if (tap_index == PTR_LAST) begin
                    m_audio_q15 <= q32_to_q15(next_accumulator);
                    m_valid <= 1'b1;
                    mac_busy <= 1'b0;
                end else begin
                    tap_index <= tap_index + 1'b1;
                end
            end
        end
    end
endmodule
