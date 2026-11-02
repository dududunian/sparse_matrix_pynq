`timescale 1ns/1ps
`default_nettype none

`include "spmm_loader_defs.svh"

// -----------------------------------------------------------------------------
// B row-pointer ROM.
//
// Each entry is a 32-bit chunk/vector address into B_val_rom.
// On en, the next clock returns mem[ptr_addr] and mem[ptr_addr+1] as an inclusive/exclusive range.
// The active SpMM path indexes this table with cfg_b_spmm_ptr_base + k.
// ADD/SUB case generation still emits compatible pointer files, although the
// current B_loader consumes B_val_rom sequentially in that mode.
// -----------------------------------------------------------------------------
module B_row_ptr_rom #(
    parameter integer PTR_W      = `SPMM_PTR_W,
    parameter integer ADDR_W     = `SPMM_B_PTR_ADDR_W,
    parameter integer DEPTH      = `SPMM_B_PTR_DEPTH,
    parameter         INIT_FILE  = `SPMM_B_PTR_INIT_FILE
) (
    input  wire                 clk,
    input  wire                 en,
    input  wire [ADDR_W-1:0]    ptr_addr,
    output reg  [PTR_W-1:0]     start_ptr,
    output reg  [PTR_W-1:0]     end_ptr
);

    (* ram_style = "block" *) reg [PTR_W-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "" && INIT_FILE != "NONE") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        if (en) begin
            start_ptr <= mem[ptr_addr];
            end_ptr   <= mem[ptr_addr + {{(ADDR_W-1){1'b0}}, 1'b1}];
        end
    end

endmodule

`default_nettype wire
