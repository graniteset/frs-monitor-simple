// Small Gray-pointer asynchronous FIFO. The AD9361 user clock and the PS
// FCLK0 DSP clock are unrelated; this is the IQ clock-domain crossing.
module frs_async_fifo #(
    parameter integer WIDTH = 24,
    parameter integer ADDR_WIDTH = 6
) (
    input  wire             wr_clk,
    input  wire             wr_resetn,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] din,
    output wire             full,
    output reg              wr_overflow,
    input  wire             rd_clk,
    input  wire             rd_resetn,
    input  wire             rd_en,
    output wire [WIDTH-1:0] dout,
    output wire             empty
);
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;
    reg [WIDTH-1:0] memory [0:(1 << ADDR_WIDTH)-1];
    reg [PTR_WIDTH-1:0] wr_bin;
    reg [PTR_WIDTH-1:0] wr_gray;
    reg [PTR_WIDTH-1:0] rd_bin;
    reg [PTR_WIDTH-1:0] rd_gray;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_wr_sync1;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] rd_gray_wr_sync2;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_rd_sync1;
    (* ASYNC_REG = "TRUE" *) reg [PTR_WIDTH-1:0] wr_gray_rd_sync2;

    wire wr_take = wr_en && !full;
    wire rd_take = rd_en && !empty;
    wire [PTR_WIDTH-1:0] wr_bin_next = wr_bin + wr_take;
    wire [PTR_WIDTH-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    wire [PTR_WIDTH-1:0] rd_bin_next = rd_bin + rd_take;
    wire [PTR_WIDTH-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;
    wire [PTR_WIDTH-1:0] full_compare = {
        ~rd_gray_wr_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
        rd_gray_wr_sync2[PTR_WIDTH-3:0]
    };

    assign full = (wr_gray == full_compare);
    assign empty = (rd_gray == wr_gray_rd_sync2);
    assign dout = memory[rd_bin[ADDR_WIDTH-1:0]];

    always @(posedge wr_clk or negedge wr_resetn) begin
        if (!wr_resetn) begin
            wr_bin <= {PTR_WIDTH{1'b0}};
            wr_gray <= {PTR_WIDTH{1'b0}};
            rd_gray_wr_sync1 <= {PTR_WIDTH{1'b0}};
            rd_gray_wr_sync2 <= {PTR_WIDTH{1'b0}};
            wr_overflow <= 1'b0;
        end else begin
            rd_gray_wr_sync1 <= rd_gray;
            rd_gray_wr_sync2 <= rd_gray_wr_sync1;
            if (wr_en && full)
                wr_overflow <= 1'b1;
            if (wr_take) begin
                memory[wr_bin[ADDR_WIDTH-1:0]] <= din;
                wr_bin <= wr_bin_next;
                wr_gray <= wr_gray_next;
            end
        end
    end

    always @(posedge rd_clk or negedge rd_resetn) begin
        if (!rd_resetn) begin
            rd_bin <= {PTR_WIDTH{1'b0}};
            rd_gray <= {PTR_WIDTH{1'b0}};
            wr_gray_rd_sync1 <= {PTR_WIDTH{1'b0}};
            wr_gray_rd_sync2 <= {PTR_WIDTH{1'b0}};
        end else begin
            wr_gray_rd_sync1 <= wr_gray;
            wr_gray_rd_sync2 <= wr_gray_rd_sync1;
            if (rd_take) begin
                rd_bin <= rd_bin_next;
                rd_gray <= rd_gray_next;
            end
        end
    end
endmodule
