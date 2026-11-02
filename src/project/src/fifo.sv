`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Ready/valid FIFO used on the PE lane streams.
//
// Contract:
//   - one write may be accepted when in_valid && in_ready;
//   - one read may be retired when out_valid && out_ready;
//   - out_data is fall-through and reflects the current read pointer while the FIFO is non-empty.
//
// The default depth is sized for short backpressure between loaders, PE lanes
// and Store.  Wider buffering should be provided by a dedicated BRAM FIFO.
// -----------------------------------------------------------------------------
module fifo #(
    parameter integer DATA_W = 32,
    parameter integer DEPTH  = 16,
    parameter integer ADDR_W = 4
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire              in_valid,
    output wire              in_ready,
    input  wire [DATA_W-1:0] in_data,

    output wire              out_valid,
    input  wire              out_ready,
    output wire [DATA_W-1:0] out_data,

    output wire              empty,
    output wire              full,
    output wire [ADDR_W:0]   count
);

    localparam [ADDR_W:0]   DEPTH_COUNT = DEPTH;
    localparam [ADDR_W-1:0] DEPTH_LAST  = DEPTH - 1;

    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    reg [ADDR_W-1:0] rd_ptr;
    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W:0]   count_r;

    wire do_push = in_valid  && in_ready;
    wire do_pop  = out_valid && out_ready;

    assign empty     = (count_r == { (ADDR_W+1){1'b0} });
    assign full      = (count_r == DEPTH_COUNT);
    assign count     = count_r;
    assign in_ready  = !full;
    assign out_valid = !empty;
    assign out_data  = mem[rd_ptr];

    // RAM data has no reset. Keep its write process free of asynchronous
    // control events so synthesis can infer distributed RAM rather than FFs.
    always @(posedge clk) begin
        if (rst_n && do_push) mem[wr_ptr] <= in_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr  <= {ADDR_W{1'b0}};
            wr_ptr  <= {ADDR_W{1'b0}};
            count_r <= { (ADDR_W+1){1'b0} };
        end else begin
            if (do_push) begin
                if (wr_ptr == DEPTH_LAST)
                    wr_ptr <= {ADDR_W{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end

            if (do_pop) begin
                if (rd_ptr == DEPTH_LAST)
                    rd_ptr <= {ADDR_W{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end

            case ({do_push, do_pop})
                2'b10: count_r <= count_r + 1'b1;
                2'b01: count_r <= count_r - 1'b1;
                default: count_r <= count_r;
            endcase
        end
    end

endmodule

`default_nettype wire
