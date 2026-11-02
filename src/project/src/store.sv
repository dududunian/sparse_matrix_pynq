`timescale 1ns/1ps
`default_nettype none

`include "spmm_loader_defs.svh"

// -----------------------------------------------------------------------------
// Result store.
//
// Each PE lane has a short FIFO that captures {row,col,val} at the same time as
// the lane result handshake.  A single priority writer drains those FIFOs into
// dense C RAM using row-major addressing: addr = row * cfg_n + col.
// -----------------------------------------------------------------------------
module Store #(
    parameter integer PE_LANES    = `SPMM_PE_LANES,
    parameter integer ROW_W       = `SPMM_ROW_W,
    parameter integer COL_W       = `SPMM_COL_W,
    parameter integer VAL_W       = `SPMM_VAL_W,
    parameter integer C_ADDR_W    = `SPMM_C_ADDR_W,
    parameter integer C_DEPTH     = `SPMM_C_DEPTH,
    parameter integer FIFO_DEPTH  = `SPMM_FIFO_DEPTH_DFLT,
    parameter integer FIFO_ADDR_W = `SPMM_FIFO_ADDR_W_DFLT
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    input  wire [ROW_W-1:0]             cfg_m,
    input  wire [COL_W-1:0]             cfg_n,

    input  wire [PE_LANES*ROW_W-1:0]    lane_row_bus,

    input  wire [PE_LANES-1:0]          lane_result_valid,
    output wire [PE_LANES-1:0]          lane_result_ready,
    input  wire [PE_LANES*COL_W-1:0]    lane_result_col_bus,
    input  wire [PE_LANES*VAL_W-1:0]    lane_result_val_bus,

    output reg                          c_wr_en,
    output reg  [C_ADDR_W-1:0]          c_wr_addr,
    output reg  [VAL_W-1:0]             c_wr_data,

    output wire                         empty,
    output wire                         busy,
    output reg                          error_no_row
);
    localparam integer FIFO_W = ROW_W + COL_W + VAL_W;

    wire [PE_LANES-1:0] fifo_out_valid;
    wire [PE_LANES-1:0] fifo_out_ready;
    wire [PE_LANES-1:0] fifo_empty;
    wire [PE_LANES-1:0] fifo_full;
    wire [PE_LANES*FIFO_W-1:0] fifo_in_data_bus;
    wire [PE_LANES*FIFO_W-1:0] fifo_out_data_bus;

    genvar g;
    generate
        for (g = 0; g < PE_LANES; g = g + 1) begin : GEN_STORE_FIFO
            assign fifo_in_data_bus[g*FIFO_W +: FIFO_W] = {
                lane_row_bus[g*ROW_W +: ROW_W],
                lane_result_col_bus[g*COL_W +: COL_W],
                lane_result_val_bus[g*VAL_W +: VAL_W]
            };

            fifo #(
                .DATA_W (FIFO_W),
                .DEPTH  (FIFO_DEPTH),
                .ADDR_W (FIFO_ADDR_W)
            ) u_store_fifo (
                .clk       (clk),
                .rst_n     (rst_n),
                .in_valid  (lane_result_valid[g]),
                .in_ready  (lane_result_ready[g]),
                .in_data   (fifo_in_data_bus[g*FIFO_W +: FIFO_W]),
                .out_valid (fifo_out_valid[g]),
                .out_ready (fifo_out_ready[g]),
                .out_data  (fifo_out_data_bus[g*FIFO_W +: FIFO_W]),
                .empty     (fifo_empty[g]),
                .full      (fifo_full[g]),
                .count     ()
            );
        end
    endgenerate

    reg [$clog2(PE_LANES)-1:0] sel_lane;
    reg                        sel_valid;
    integer i;
    always @(*) begin
        // Fixed-priority arbitration is sufficient here because Store is a
        // writeback concentrator; per-lane FIFOs absorb short bursts from PE.
        sel_valid = 1'b0;
        sel_lane  = {$clog2(PE_LANES){1'b0}};
        for (i = 0; i < PE_LANES; i = i + 1) begin
            if (!sel_valid && fifo_out_valid[i]) begin
                sel_valid = 1'b1;
                sel_lane  = i;
            end
        end
    end

    generate
        for (g = 0; g < PE_LANES; g = g + 1) begin : GEN_STORE_POP
            assign fifo_out_ready[g] = sel_valid && (sel_lane == g);
        end
    endgenerate

    wire [FIFO_W-1:0] sel_data = fifo_out_data_bus[sel_lane*FIFO_W +: FIFO_W];
    wire [VAL_W-1:0]  sel_val  = sel_data[VAL_W-1:0];
    wire [COL_W-1:0]  sel_col  = sel_data[VAL_W +: COL_W];
    wire [ROW_W-1:0]  sel_row  = sel_data[VAL_W + COL_W +: ROW_W];

    wire [63:0] write_addr_full = ({{(64-ROW_W){1'b0}},sel_row} * cfg_n) + sel_col;
    assign empty = &fifo_empty;
    assign busy  = ~empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_wr_en      <= 1'b0;
            c_wr_addr    <= {C_ADDR_W{1'b0}};
            c_wr_data    <= {VAL_W{1'b0}};
            error_no_row <= 1'b0;
        end else begin
            c_wr_en <= 1'b0;
            if (start)
                error_no_row <= 1'b0;

            if (sel_valid) begin
                // The row id has already been mapped by top.sv.
                // Store only performs the final dense address calculation.
                if(sel_row>=cfg_m || sel_col>=cfg_n || write_addr_full>=C_DEPTH)
                    error_no_row<=1;
                else begin
                    c_wr_en<=1; c_wr_addr<=write_addr_full[C_ADDR_W-1:0]; c_wr_data<=sel_val;
                end
            end
        end
    end

endmodule

`default_nettype wire
