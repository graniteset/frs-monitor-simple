// Lossless two-input round-robin merger for 37-bit tagged complex samples.
// Holds its grant stable while downstream is stalled.
module axis_rr_merge2_iq (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [36:0] s0_data,
    input  wire        s0_valid,
    output wire        s0_ready,
    input  wire [36:0] s1_data,
    input  wire        s1_valid,
    output wire        s1_ready,
    output wire [36:0] m_data,
    output wire        m_valid,
    input  wire        m_ready
);
    reg prefer_one;
    reg locked;
    reg grant_one;

    wire choose_one = locked ? grant_one :
                      (s1_valid && (!s0_valid || prefer_one));
    assign m_valid = choose_one ? s1_valid : s0_valid;
    assign m_data = choose_one ? s1_data : s0_data;
    assign s0_ready = m_ready && m_valid && !choose_one;
    assign s1_ready = m_ready && m_valid && choose_one;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            prefer_one <= 1'b0;
            locked <= 1'b0;
            grant_one <= 1'b0;
        end else begin
            if (m_valid && !m_ready && !locked) begin
                locked <= 1'b1;
                grant_one <= choose_one;
            end
            if (m_valid && m_ready) begin
                locked <= 1'b0;
                prefer_one <= !choose_one;
            end
        end
    end
endmodule
