`timescale 1ns/1ps
`default_nettype none

`include "spmm_loader_defs.svh"

// -----------------------------------------------------------------------------
// Wide B value ROM.
//
// DATA_W defaults to 2112 bits = 66 x 32-bit words.
// The physical packing is shared across modes, but B_loader interprets the payload differently:
//   SpMM    : word2+i = {b_col[15:0], b_val[15:0]}, zero words are padding;
//   ADD/SUB : word0/1 = eor_mask[63:0],
//             word2+i = {lane_col[15:0], lane_val[15:0]}.
//
// The read port is synchronous and must be paired with an explicit wait/latch stage in the loader FSM.
// -----------------------------------------------------------------------------
module B_val_rom #(
    parameter integer DATA_W    = `SPMM_B_PACK_W,
    parameter integer ADDR_W    = `SPMM_B_VAL_ADDR_W,
    parameter integer DEPTH     = `SPMM_B_VAL_DEPTH,
    parameter         INIT_FILE = `SPMM_B_VAL_INIT_FILE
) (
    input  wire              clk,
    input  wire              en,
    input  wire [ADDR_W-1:0] addr,
    output reg  [DATA_W-1:0] dout
);

    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "" && INIT_FILE != "NONE") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        if (en) begin
            dout <= mem[addr];
        end
    end

endmodule

`default_nettype wire
