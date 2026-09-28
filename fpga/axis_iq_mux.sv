// Board-independent 2:1 AXI4-Stream mux for packed complex IQ beats.
// Select 0 routes source A; select 1 routes source B. Selection is locked for
// the duration of a stalled output beat, so changing select cannot corrupt an
// in-flight transfer. Inputs must themselves obey AXI4-Stream stability.
module axis_iq_mux (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        select,
    input  wire [31:0] a_tdata,
    input  wire        a_tvalid,
    output wire        a_tready,
    input  wire [31:0] b_tdata,
    input  wire        b_tvalid,
    output wire        b_tready,
    output wire [31:0] m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready
);
    reg locked;
    reg locked_select;
    wire active_select = locked ? locked_select : select;

    assign m_tdata  = active_select ? b_tdata  : a_tdata;
    assign m_tvalid = active_select ? b_tvalid : a_tvalid;
    assign a_tready = !active_select && m_tready;
    assign b_tready =  active_select && m_tready;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            locked        <= 1'b0;
            locked_select <= 1'b0;
        end else if (!locked) begin
            if (m_tvalid && !m_tready) begin
                locked        <= 1'b1;
                locked_select <= active_select;
            end
        end else if (m_tvalid && m_tready) begin
            locked <= 1'b0;
        end
    end
endmodule
