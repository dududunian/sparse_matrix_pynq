`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// A compact-vector ROM.
//
// Each a_compact_vec.hex line is one 66-word vector packed high-to-low in the text file.
// word0 is exposed at dout[31:0].  The read port is synchronous, so users must issue en/addr one cycle before consuming dout.
// -----------------------------------------------------------------------------
module A_vec_rom #(
    parameter integer DATA_W    = 2112,
    parameter integer ADDR_W    = 12,
    parameter integer DEPTH     = 4096,
    parameter         INIT_FILE = "a_compact_vec.hex"
) (
    input  wire              clk,
    input  wire              en,
    input  wire [ADDR_W-1:0] addr,
    output reg  [DATA_W-1:0] dout
);

    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "NONE") begin
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
