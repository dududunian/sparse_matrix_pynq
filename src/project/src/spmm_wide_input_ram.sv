`timescale 1ns/1ps
`default_nettype none
// 66 independent 32-bit banks. Host writes one word; the core reads one
// 2112-bit vector synchronously, exactly as with the original ROM.
module spmm_wide_input_ram (
    input wire clk,
    input wire rd_en,
    input wire [8:0] rd_addr,
    output wire [2111:0] dout,
    input wire wr_en,
    input wire [8:0] wr_row,
    input wire [6:0] wr_word,
    input wire [31:0] wr_data
);
    genvar g;
    generate for(g=0;g<66;g=g+1) begin: BANK
        (* ram_style="block" *) reg [31:0] mem [0:511];
        reg [31:0] q;
        always @(posedge clk) begin
            if(wr_en && wr_word==g) mem[wr_row] <= wr_data;
            if(rd_en) q <= mem[rd_addr];
        end
        assign dout[g*32 +: 32] = q;
    end endgenerate
endmodule
`default_nettype wire
