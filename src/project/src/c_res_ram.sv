`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Dense C result RAM.
//
// The write port is shared by top.sv clear logic and Store.
// The read port is a synchronous debug/readback path used by the testbench result dumper.
// -----------------------------------------------------------------------------
module C_res_ram #(
    parameter integer DATA_W = 16,
    parameter integer ADDR_W = 18,
    parameter integer DEPTH  = 262144
) (
    input  wire              clk,

    input  wire              wr_en,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire [DATA_W-1:0] wr_data,

    input  wire              rd_en,
    input  wire [ADDR_W-1:0] rd_addr,
    output reg  [DATA_W-1:0] rd_data
);

    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            mem[i] = {DATA_W{1'b0}};
        end
    end

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end

endmodule

`default_nettype wire
