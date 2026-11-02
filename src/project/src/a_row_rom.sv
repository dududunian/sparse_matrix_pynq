`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Row-order lookup table.
//
// a_row_order.hex stores one original row id per reordered A row.
// For each row_group index this module exposes the 64 row ids needed by the PE lanes and Store.
// Reads are combinational because the table is small and latency on the
// row mapping path would otherwise have to be aligned with result writeback.
// -----------------------------------------------------------------------------
module A_row_rom #(
    parameter integer PE_LANES  = 64,
    parameter integer ROW_W     = 16,
    parameter integer M_MAX     = 512,
    parameter integer GROUP_W   = 3,
    parameter         INIT_FILE = "a_row_order.hex"
) (
    input  wire [GROUP_W-1:0]                group_idx,
    output reg  [PE_LANES*ROW_W-1:0]         row_bus
);

    (* ram_style = "distributed" *) reg [ROW_W-1:0] mem [0:M_MAX-1];

    integer i;
    integer row_addr;

    initial begin
        if (INIT_FILE != "NONE") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(*) begin
        row_bus = {PE_LANES*ROW_W{1'b0}};
        for (i = 0; i < PE_LANES; i = i + 1) begin
            row_addr = (group_idx * PE_LANES) + i;
            if (row_addr < M_MAX)
                row_bus[i*ROW_W +: ROW_W] = mem[row_addr];
            else
                row_bus[i*ROW_W +: ROW_W] = {ROW_W{1'b0}};
        end
    end

endmodule

`default_nettype wire
