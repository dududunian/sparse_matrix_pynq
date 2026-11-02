`timescale 1ns/1ps
`default_nettype none

`include "spmm_loader_defs.svh"

// -----------------------------------------------------------------------------
// Top-level SpMM / matrix ADD-SUB datapath.
//
// Loader-to-PE traffic is fully FIFO decoupled:
//   A_loader -> A lane FIFOs -> PE lanes
//   B_loader -> B lane FIFOs -> PE lanes
//
// Store is the only writer to the dense C result RAM after the explicit clear phase.
// The debug read port is used by the simulation testbench to dump C in row-major order.
// // -----------------------------------------------------------------------------
module top #(
    parameter integer PE_LANES       = `SPMM_PE_LANES,
    parameter integer FP_LATENCY     = 2,
    parameter integer K_MAX          = `SPMM_K_MAX,
    parameter integer M_MAX          = `SPMM_M_MAX,
    parameter integer N_MAX          = `SPMM_N_MAX,
    parameter integer WATCHDOG_CYCLES = 3000000,
    parameter integer ROW_W          = `SPMM_ROW_W,
    parameter integer K_W            = `SPMM_K_W,
    parameter integer VAL_W          = `SPMM_VAL_W,
    parameter integer COL_W          = `SPMM_COL_W,

    parameter integer A_VEC_WORDS    = `SPMM_A_VEC_WORDS,
    parameter integer A_VEC_W        = `SPMM_A_VEC_W,
    parameter integer A_VEC_ADDR_W   = `SPMM_A_VEC_ADDR_W,
    parameter integer A_VEC_DEPTH    = `SPMM_A_VEC_DEPTH,

    parameter integer B_PTR_W        = `SPMM_PTR_W,
    parameter integer B_PTR_ADDR_W   = `SPMM_B_PTR_ADDR_W,
    parameter integer B_PTR_DEPTH    = `SPMM_B_PTR_DEPTH,
    parameter integer B_VAL_ADDR_W   = `SPMM_B_VAL_ADDR_W,
    parameter integer B_PACK_W       = `SPMM_B_PACK_W,
    parameter integer B_VAL_DEPTH    = `SPMM_B_VAL_DEPTH,

    parameter integer C_ADDR_W       = `SPMM_C_ADDR_W,
    parameter integer C_DEPTH        = `SPMM_C_DEPTH,

    parameter integer GROUP_W        = `SPMM_GROUP_W,
    parameter integer A_FIFO_DEPTH   = `SPMM_FIFO_DEPTH_DFLT,
    parameter integer A_FIFO_ADDR_W  = `SPMM_FIFO_ADDR_W_DFLT,
    parameter integer B_FIFO_DEPTH   = `SPMM_FIFO_DEPTH_DFLT,
    parameter integer B_FIFO_ADDR_W  = `SPMM_FIFO_ADDR_W_DFLT,
    parameter integer PE_BUF_DEPTH   = `SPMM_PE_BUF_DEPTH,
    parameter integer PE_BUF_ADDR_W  = `SPMM_PE_BUF_ADDR_W,
    parameter integer PE_META_DEPTH  = `SPMM_PE_META_DEPTH,
    parameter integer PE_META_ADDR_W = `SPMM_PE_META_ADDR_W,

    parameter         A_VEC_INIT_FILE = `SPMM_A_VEC_INIT_FILE,
    parameter         A_ROW_INIT_FILE = `SPMM_A_ROW_INIT_FILE,
    parameter         B_PTR_INIT_FILE = `SPMM_B_PTR_INIT_FILE,
    parameter         B_VAL_INIT_FILE = `SPMM_B_VAL_INIT_FILE
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    input wire upload_we,
    input wire [16:0] upload_index,
    input wire [31:0] upload_data,

    input  wire [ROW_W-1:0]             cfg_m,
    input  wire [COL_W-1:0]             cfg_n,
    input  wire [K_W-1:0]               cfg_k,
    input  wire [15:0]                  cfg_block_vecs,
    input  wire [A_VEC_ADDR_W:0]        cfg_a_vec_count,

    input  wire [1:0]                   cfg_pe_mode,
    input  wire [B_PTR_ADDR_W-1:0]      cfg_b_spmm_ptr_base,
    input  wire [B_PTR_ADDR_W-1:0]      cfg_b_add_ptr_base,

    input  wire [31:0]                  cfg_b_chunk_count,
    input  wire [31:0]                  cfg_b_ptr_count,
    output reg [7:0]                    error_code,

    output wire                         busy,
    output wire                         done,
    output wire                         error,

    input  wire                         dbg_c_en,
    input  wire [C_ADDR_W-1:0]          dbg_c_addr,
    output wire [VAL_W-1:0]             dbg_c_dout
);
    localparam integer A_FIFO_W = `SPMM_A_FIFO_W;
    localparam integer B_FIFO_W = `SPMM_B_LANE_FIFO_W;

    localparam [2:0]
        TOP_IDLE  = 3'd0,
        TOP_CLEAR = 3'd1,
        TOP_START = 3'd2,
        TOP_RUN   = 3'd3,
        TOP_DONE  = 3'd4,
        TOP_ERROR = 3'd5;

    reg [2:0] top_state;
    reg [31:0] clear_count, element_count, run_cycles;
    wire [C_ADDR_W-1:0] clear_addr = clear_count[C_ADDR_W-1:0];
    reg core_start_pulse;

    reg [ROW_W-1:0] cfg_m_r;
    reg [COL_W-1:0] cfg_n_r;
    reg [K_W-1:0] cfg_k_r;
    reg [15:0] cfg_block_vecs_r;
    reg [A_VEC_ADDR_W:0] cfg_a_vec_count_r;
    reg [1:0] cfg_pe_mode_r;
    reg [B_PTR_ADDR_W-1:0] cfg_b_spmm_ptr_base_r, cfg_b_add_ptr_base_r;
    reg [31:0] cfg_b_chunk_count_r, cfg_b_ptr_count_r;
    reg start_d;
    wire core_rst_n = rst_n && ((top_state == TOP_START) || (top_state == TOP_RUN));
    wire [31:0] requested_m = cfg_m;
    wire [31:0] requested_n = cfg_n;
    wire [31:0] requested_elements = requested_m * requested_n;
    reg [7:0] config_error;
    always @(*) begin
        config_error=0;
        if (cfg_pe_mode > 2) config_error=8'h01;
        else if (cfg_m==0 || cfg_m>M_MAX || cfg_n==0 || cfg_n>N_MAX || cfg_n>PE_BUF_DEPTH) config_error=8'h02;
        else if (requested_elements > C_DEPTH) config_error=8'h03;
        else if (cfg_pe_mode==0 && (cfg_k==0 || cfg_k>K_MAX)) config_error=8'h04;
        else if (cfg_a_vec_count==0 || cfg_a_vec_count>A_VEC_DEPTH) config_error=8'h05;
        else if (cfg_pe_mode==0 && (cfg_block_vecs==0 || cfg_block_vecs>A_FIFO_DEPTH)) config_error=8'h06;
        else if ((cfg_pe_mode==0 && (cfg_b_ptr_count>B_PTR_DEPTH ||
                 ({1'b0,cfg_b_spmm_ptr_base}+{1'b0,cfg_k})>=cfg_b_ptr_count)) ||
                 (cfg_pe_mode!=0 && cfg_b_add_ptr_base!=0)) config_error=8'h07;
        else if (cfg_b_chunk_count>B_VAL_DEPTH || (cfg_pe_mode!=0 && cfg_b_chunk_count==0)) config_error=8'h08;
    end

    wire spmm_mode = (cfg_pe_mode_r == `SPMM_PE_MODE_SPMM);
    wire mat_mode  = (cfg_pe_mode_r == `SPMM_PE_MODE_MAT_ADD) ||
                     (cfg_pe_mode_r == `SPMM_PE_MODE_MAT_SUB);

    wire a_busy, a_done, a_error_vec_overrun;
    wire b_busy, b_done, b_error_bad_k;

    wire a_vec_en;
    wire [A_VEC_ADDR_W-1:0] a_vec_addr;
    wire [A_VEC_W-1:0] a_vec_data;

    wire [GROUP_W-1:0] row_group_idx;
    wire [PE_LANES*ROW_W-1:0] row_order_bus;
    wire [PE_LANES*ROW_W-1:0] lane_row_bus;

    wire [PE_LANES-1:0] a_push_valid;
    wire [PE_LANES-1:0] a_push_ready;
    wire [PE_LANES*K_W-1:0] a_push_idx_bus;
    wire [PE_LANES*VAL_W-1:0] a_push_val_bus;
    wire [PE_LANES-1:0] a_push_eor;
    wire [PE_LANES-1:0] a_push_dummy;

    wire k_update_valid;
    wire k_update_ready;
    wire [PE_LANES-1:0] k_update_mask;
    wire [PE_LANES*K_W-1:0] k_update_bus;
    wire a_block_done_valid;
    wire a_block_done_ready;
    wire a_block_done_last;

    wire b_rowptr_en;
    wire [B_PTR_ADDR_W-1:0] b_rowptr_addr;
    reg [B_PTR_W-1:0] b_row_start_ptr;
    reg [B_PTR_W-1:0] b_row_end_ptr;
    wire b_val_en;
    wire [B_VAL_ADDR_W-1:0] b_val_addr;
    wire [B_PACK_W-1:0] b_val_dout;

    wire [PE_LANES-1:0] b_push_valid;
    wire [PE_LANES-1:0] b_push_ready;
    wire [PE_LANES*K_W-1:0] b_push_k_bus;
    wire [PE_LANES*COL_W-1:0] b_push_col_bus;
    wire [PE_LANES*VAL_W-1:0] b_push_val_bus;
    wire [PE_LANES-1:0] b_push_eor;
    wire [PE_LANES-1:0] b_push_dummy;

    wire b_block_done_valid;
    wire b_block_done_last;
    wire b_block_done_ready;

    wire [PE_LANES-1:0] a_fifo_out_valid;
    wire [PE_LANES-1:0] a_fifo_out_ready;
    wire [PE_LANES-1:0] a_fifo_empty;
    wire [PE_LANES*A_FIFO_W-1:0] a_fifo_in_data_bus;
    wire [PE_LANES*A_FIFO_W-1:0] a_fifo_out_data_bus;

    wire [PE_LANES-1:0] b_fifo_out_valid;
    wire [PE_LANES-1:0] b_fifo_out_ready;
    wire [PE_LANES-1:0] b_fifo_empty;
    wire [PE_LANES*B_FIFO_W-1:0] b_fifo_in_data_bus;
    wire [PE_LANES*B_FIFO_W-1:0] b_fifo_out_data_bus;

    wire [PE_LANES-1:0] pe_result_valid;
    wire [PE_LANES-1:0] pe_result_ready;
    wire [PE_LANES*ROW_W-1:0] pe_result_row_bus_unused;
    wire [PE_LANES*COL_W-1:0] pe_result_col_bus;
    wire [PE_LANES*VAL_W-1:0] pe_result_val_bus;
    wire [PE_LANES-1:0] pe_busy_bus;
    wire [PE_LANES-1:0] pe_error_bus;
    wire [PE_LANES-1:0] pe_block_idle_bus;

    wire all_pe_idle    = ~(|pe_busy_bus);
    wire any_pe_error   =  |pe_error_bus;
    wire a_fifos_empty  =  &a_fifo_empty;
    wire b_fifos_empty  =  &b_fifo_empty;
    wire any_result_val =  |pe_result_valid;

    wire store_empty;
    wire store_busy;
    wire store_error_no_row;
    wire c_store_wr_en;
    wire [C_ADDR_W-1:0] c_store_wr_addr;
    wire [VAL_W-1:0] c_store_wr_data;

    // A 64-row group is complete only after both loaders, all lane FIFOs,
    // all PE result channels and Store have drained.  A_loader/B_loader use this
    // signal to advance to the next group in ADD/SUB mode and at SpMM group boundaries.
    wire store_group_ready = all_pe_idle && a_fifos_empty && b_fifos_empty && !any_result_val && store_empty && !c_store_wr_en;
    // B holds block_done until all traffic from this block has retired.
    // Unlike group completion, partial-result buffers are allowed to be full.
    wire spmm_block_drained = (&pe_block_idle_bus) && a_fifos_empty &&
                              b_fifos_empty && !any_result_val && store_empty && !c_store_wr_en;
    assign b_block_done_ready = spmm_block_drained;
    wire spmm_block_retired = b_block_done_valid && b_block_done_ready;
    wire core_done_condition = a_done && b_done && store_group_ready;

    assign busy = (top_state==TOP_CLEAR || top_state==TOP_START || top_state==TOP_RUN);
    assign done = (top_state==TOP_DONE || top_state==TOP_ERROR);
    assign error = (error_code!=0);

    wire bad_a_read = a_vec_en && (a_vec_addr>=A_VEC_DEPTH || a_vec_addr>=cfg_a_vec_count_r);
    wire bad_b_ptr_read = b_rowptr_en && (({1'b0,b_rowptr_addr}+1)>=B_PTR_DEPTH ||
                                        ({1'b0,b_rowptr_addr}+1)>=cfg_b_ptr_count_r);
    wire bad_b_read = b_val_en && (b_val_addr>=B_VAL_DEPTH || b_val_addr>=cfg_b_chunk_count_r);
    reg bad_a_index;
    integer check_lane;
    always @(*) begin
        bad_a_index=0;
        for(check_lane=0;check_lane<PE_LANES;check_lane=check_lane+1)
            if(a_push_valid[check_lane] && !a_push_dummy[check_lane]) begin
                if(spmm_mode && a_push_idx_bus[check_lane*K_W +: K_W]>=cfg_k_r) bad_a_index=1;
                if(mat_mode && a_push_idx_bus[check_lane*K_W +: K_W]>=cfg_n_r) bad_a_index=1;
            end
    end
    reg [7:0] runtime_error;
    always @(*) begin
        runtime_error=0;
        if(a_error_vec_overrun) runtime_error=8'h09;
        else if(bad_a_read) runtime_error=8'h10;
        else if(bad_b_ptr_read) runtime_error=8'h11;
        else if(bad_b_read) runtime_error=8'h12;
        else if(b_error_bad_k) runtime_error=8'h13;
        else if(bad_a_index) runtime_error=8'h14;
        else if(store_error_no_row) runtime_error=8'h15;
        else if(any_pe_error) runtime_error=8'h17;
        else if(WATCHDOG_CYCLES!=0 && run_cycles>=WATCHDOG_CYCLES-1) runtime_error=8'h16;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            top_state<=TOP_IDLE; start_d<=0; core_start_pulse<=0;
            clear_count<=0; element_count<=0; run_cycles<=0; error_code<=0;
            cfg_m_r<=0;cfg_n_r<=0;cfg_k_r<=0;cfg_block_vecs_r<=0;cfg_a_vec_count_r<=0;
            cfg_pe_mode_r<=0;cfg_b_spmm_ptr_base_r<=0;cfg_b_add_ptr_base_r<=0;
            cfg_b_chunk_count_r<=0;cfg_b_ptr_count_r<=0;
        end else begin
            start_d<=start;
            core_start_pulse<=0;
            case(top_state)
                TOP_IDLE: if(start && !start_d) begin
                    error_code<=config_error;
                    if(config_error!=0) top_state<=TOP_ERROR;
                    else begin
                        cfg_m_r<=cfg_m;cfg_n_r<=cfg_n;cfg_k_r<=cfg_k;
                        cfg_block_vecs_r<=cfg_block_vecs;cfg_a_vec_count_r<=cfg_a_vec_count;
                        cfg_pe_mode_r<=cfg_pe_mode;
                        cfg_b_spmm_ptr_base_r<=cfg_b_spmm_ptr_base;
                        cfg_b_add_ptr_base_r<=cfg_b_add_ptr_base;
                        cfg_b_chunk_count_r<=cfg_b_chunk_count;cfg_b_ptr_count_r<=cfg_b_ptr_count;
                        clear_count<=0;element_count<=requested_elements;run_cycles<=0;
                        top_state<=TOP_CLEAR;
                    end
                end
                TOP_CLEAR: if(clear_count+32'd1>=element_count) top_state<=TOP_START;
                           else clear_count<=clear_count+32'd1;
                TOP_START: begin core_start_pulse<=1;top_state<=TOP_RUN;end
                TOP_RUN: begin
                    run_cycles<=run_cycles+32'd1;
                    if(runtime_error!=0) begin error_code<=runtime_error;top_state<=TOP_ERROR;end
                    else if(core_done_condition) top_state<=TOP_DONE;
                end
                TOP_DONE,TOP_ERROR: if(!start) top_state<=TOP_IDLE;
                default: top_state<=TOP_IDLE;
            endcase
        end
    end

    A_loader #(
        .PE_LANES(PE_LANES), .K_W(K_W), .VAL_W(VAL_W), .ROW_W(ROW_W),
        .A_VEC_WORDS(A_VEC_WORDS), .A_VEC_W(A_VEC_W), .A_ADDR_W(A_VEC_ADDR_W), .GROUP_W(GROUP_W), .A_DEPTH(A_VEC_DEPTH)
    ) u_a_loader (
        .clk(clk), .rst_n(core_rst_n), .start(core_start_pulse),
        .cfg_pe_mode(cfg_pe_mode_r), .cfg_m(cfg_m_r), .cfg_a_vec_count(cfg_a_vec_count_r),
        .cfg_block_vecs(cfg_block_vecs_r), .store_group_ready(store_group_ready),
        .spmm_block_retired(spmm_block_retired),
        .busy(a_busy), .done(a_done), .error_vec_overrun(a_error_vec_overrun),
        .a_vec_en(a_vec_en), .a_vec_addr(a_vec_addr), .a_vec_data(a_vec_data),
        .row_group_idx(row_group_idx),
        .a_push_valid(a_push_valid), .a_push_ready(a_push_ready),
        .a_push_idx_bus(a_push_idx_bus), .a_push_val_bus(a_push_val_bus),
        .a_push_eor(a_push_eor), .a_push_dummy(a_push_dummy),
        .k_update_valid(k_update_valid), .k_update_ready(k_update_ready),
        .k_update_mask(k_update_mask), .k_update_bus(k_update_bus),
        .a_block_done_valid(a_block_done_valid), .a_block_done_ready(a_block_done_ready),
        .a_block_done_last(a_block_done_last)
    );

    B_loader #(
        .PE_LANES(PE_LANES), .K_MAX(K_MAX), .K_W(K_W), .ROW_W(ROW_W),
        .VAL_W(VAL_W), .COL_W(COL_W), .PTR_W(B_PTR_W), .PTR_ADDR_W(B_PTR_ADDR_W),
        .B_ADDR_W(B_VAL_ADDR_W), .B_PACK_W(B_PACK_W), .GROUP_W(GROUP_W)
    ) u_b_loader (
        .clk(clk), .rst_n(core_rst_n), .start(core_start_pulse),
        .cfg_pe_mode(cfg_pe_mode_r), .cfg_m(cfg_m_r), .cfg_k(cfg_k_r),
        .cfg_n(cfg_n_r), .cfg_b_chunk_count(cfg_b_chunk_count_r),
        .cfg_b_spmm_ptr_base(cfg_b_spmm_ptr_base_r), .cfg_b_add_ptr_base(cfg_b_add_ptr_base_r),
        .store_group_ready(store_group_ready),
        .busy(b_busy), .done(b_done), .error_bad_k(b_error_bad_k),
        .k_update_valid(k_update_valid), .k_update_ready(k_update_ready),
        .k_update_mask(k_update_mask), .k_update_bus(k_update_bus),
        .a_block_done_valid(a_block_done_valid), .a_block_done_ready(a_block_done_ready),
        .a_block_done_last(a_block_done_last),
        .b_rowptr_en(b_rowptr_en), .b_rowptr_addr(b_rowptr_addr),
        .b_row_start_ptr(b_row_start_ptr), .b_row_end_ptr(b_row_end_ptr),
        .b_val_en(b_val_en), .b_val_addr(b_val_addr), .b_val_dout(b_val_dout),
        .b_push_valid(b_push_valid), .b_push_ready(b_push_ready),
        .b_push_k_bus(b_push_k_bus), .b_push_col_bus(b_push_col_bus),
        .b_push_val_bus(b_push_val_bus), .b_push_eor(b_push_eor), .b_push_dummy(b_push_dummy),
        .b_block_done_valid(b_block_done_valid), .b_block_done_ready(b_block_done_ready),
        .b_block_done_last(b_block_done_last)
    );

    // Input memories retain the original core-side read latency and packing.
    // Host writes are admitted by u_ctrl only while the complete core is idle.
    // Host tiles only M/N. K is retained in full (up to 512), preserving
    // the original per-output FP16 multiply/add accumulation order.
    wire [16:0] b_index = upload_index - 17'd33792;
    wire [8:0] a_write_row = upload_index / 66;
    wire [6:0] a_write_word = upload_index % 66;
    wire [8:0] b_write_row = b_index / 66;
    wire [6:0] b_write_word = b_index % 66;
    spmm_wide_input_ram u_a_input (
        .clk(clk), .rd_en(a_vec_en && !bad_a_read && core_rst_n),
        .rd_addr(a_vec_addr), .dout(a_vec_data),
        .wr_en(upload_we && upload_index < 33792),
        .wr_row(a_write_row), .wr_word(a_write_word), .wr_data(upload_data));
    spmm_wide_input_ram u_b_input (
        .clk(clk), .rd_en(b_val_en && !bad_b_read && core_rst_n),
        .rd_addr(b_val_addr), .dout(b_val_dout),
        .wr_en(upload_we && upload_index >= 33792 && upload_index < 67584),
        .wr_row(b_write_row), .wr_word(b_write_word), .wr_data(upload_data));
    reg [15:0] host_row_order [0:63];
    reg [31:0] host_b_ptr [0:1023];
    wire [5:0] row_write_addr = upload_index - 17'd67584;
    wire [9:0] ptr_write_addr = upload_index - 17'd67648;
    always @(posedge clk) begin
        if(upload_we && upload_index >= 67584 && upload_index < 67648)
            host_row_order[row_write_addr] <= upload_data[15:0];
        if(upload_we && upload_index >= 67648 && upload_index < 68672)
            host_b_ptr[ptr_write_addr] <= upload_data;
        if(b_rowptr_en && !bad_b_ptr_read && core_rst_n) begin
            b_row_start_ptr <= host_b_ptr[b_rowptr_addr];
            b_row_end_ptr <= host_b_ptr[b_rowptr_addr + 10'd1];
        end
    end
    genvar hr;
    generate for(hr=0;hr<64;hr=hr+1) begin: HOST_ROWS
        assign row_order_bus[hr*ROW_W +: ROW_W] = host_row_order[hr];
    end endgenerate

    genvar rg;
    generate
        for (rg = 0; rg < PE_LANES; rg = rg + 1) begin : GEN_LANE_ROW
            wire [ROW_W-1:0] identity_row;
            assign identity_row = (({{(ROW_W-GROUP_W){1'b0}}, row_group_idx}) << 6) + rg;
            // SpMM stores rows in reordered A order and must map each lane back to the original row id.
            // ADD/SUB keeps identity row order.
            assign lane_row_bus[rg*ROW_W +: ROW_W] = spmm_mode ? row_order_bus[rg*ROW_W +: ROW_W] : identity_row;
        end
    endgenerate

    genvar gi;
    generate
        for (gi = 0; gi < PE_LANES; gi = gi + 1) begin : GEN_LANE
            assign a_fifo_in_data_bus[gi*A_FIFO_W +: A_FIFO_W] = {
                a_push_dummy[gi],
                a_push_eor[gi],
                a_push_idx_bus[gi*K_W +: K_W],
                a_push_val_bus[gi*VAL_W +: VAL_W]
            };

            fifo #(.DATA_W(A_FIFO_W), .DEPTH(A_FIFO_DEPTH), .ADDR_W(A_FIFO_ADDR_W))
            u_a_lane_fifo (
                .clk(clk), .rst_n(core_rst_n),
                .in_valid(a_push_valid[gi]), .in_ready(a_push_ready[gi]),
                .in_data(a_fifo_in_data_bus[gi*A_FIFO_W +: A_FIFO_W]),
                .out_valid(a_fifo_out_valid[gi]), .out_ready(a_fifo_out_ready[gi]),
                .out_data(a_fifo_out_data_bus[gi*A_FIFO_W +: A_FIFO_W]),
                .empty(a_fifo_empty[gi]), .full(), .count()
            );

            assign b_fifo_in_data_bus[gi*B_FIFO_W +: B_FIFO_W] = {
                b_push_dummy[gi],
                b_push_eor[gi],
                b_push_k_bus[gi*K_W +: K_W],
                b_push_col_bus[gi*COL_W +: COL_W],
                b_push_val_bus[gi*VAL_W +: VAL_W]
            };

            fifo #(.DATA_W(B_FIFO_W), .DEPTH(B_FIFO_DEPTH), .ADDR_W(B_FIFO_ADDR_W))
            u_b_lane_fifo (
                .clk(clk), .rst_n(core_rst_n),
                .in_valid(b_push_valid[gi]), .in_ready(b_push_ready[gi]),
                .in_data(b_fifo_in_data_bus[gi*B_FIFO_W +: B_FIFO_W]),
                .out_valid(b_fifo_out_valid[gi]), .out_ready(b_fifo_out_ready[gi]),
                .out_data(b_fifo_out_data_bus[gi*B_FIFO_W +: B_FIFO_W]),
                .empty(b_fifo_empty[gi]), .full(), .count()
            );

            pe_core #(
                .ROW_W(ROW_W), .K_W(K_W), .COL_W(COL_W), .VAL_W(VAL_W),
                .BUF_DEPTH(PE_BUF_DEPTH), .BUF_ADDR_W(PE_BUF_ADDR_W),
                .META_DEPTH(PE_META_DEPTH), .META_ADDR_W(PE_META_ADDR_W),
                .FP_LATENCY(FP_LATENCY)
            ) u_pe_core (
                .clk(clk), .rst_n(core_rst_n),
                .a_valid(a_fifo_out_valid[gi]), .a_ready(a_fifo_out_ready[gi]),
                .a_idx(a_fifo_out_data_bus[gi*A_FIFO_W + VAL_W +: K_W]),
                .a_val(a_fifo_out_data_bus[gi*A_FIFO_W +: VAL_W]),
                .a_eor(a_fifo_out_data_bus[gi*A_FIFO_W + VAL_W + K_W]),
                .a_dummy(a_fifo_out_data_bus[gi*A_FIFO_W + VAL_W + K_W + 1]),
                .lane_row(lane_row_bus[gi*ROW_W +: ROW_W]),
                .b_valid(b_fifo_out_valid[gi]), .b_ready(b_fifo_out_ready[gi]),
                .b_k(b_fifo_out_data_bus[gi*B_FIFO_W + VAL_W + COL_W +: K_W]),
                .b_col(b_fifo_out_data_bus[gi*B_FIFO_W + VAL_W +: COL_W]),
                .b_val(b_fifo_out_data_bus[gi*B_FIFO_W +: VAL_W]),
                .b_eor(b_fifo_out_data_bus[gi*B_FIFO_W + VAL_W + COL_W + K_W]),
                .b_dummy(b_fifo_out_data_bus[gi*B_FIFO_W + VAL_W + COL_W + K_W + 1]),
                .cfg_pe_mode(cfg_pe_mode_r),
                .result_valid(pe_result_valid[gi]), .result_ready(pe_result_ready[gi]),
                .result_row(pe_result_row_bus_unused[gi*ROW_W +: ROW_W]),
                .result_col(pe_result_col_bus[gi*COL_W +: COL_W]),
                .result_val(pe_result_val_bus[gi*VAL_W +: VAL_W]),
                .pe_busy(pe_busy_bus[gi]), .pe_error(pe_error_bus[gi]),
                .block_idle(pe_block_idle_bus[gi])
            );
        end
    endgenerate

    Store #(
        .PE_LANES(PE_LANES), .ROW_W(ROW_W), .COL_W(COL_W), .VAL_W(VAL_W),
        .C_ADDR_W(C_ADDR_W), .C_DEPTH(C_DEPTH), .FIFO_DEPTH(A_FIFO_DEPTH), .FIFO_ADDR_W(A_FIFO_ADDR_W)
    ) u_store (
        .clk(clk), .rst_n(core_rst_n), .start(core_start_pulse), .cfg_m(cfg_m_r), .cfg_n(cfg_n_r),
        .lane_row_bus(lane_row_bus),
        .lane_result_valid(pe_result_valid), .lane_result_ready(pe_result_ready),
        .lane_result_col_bus(pe_result_col_bus), .lane_result_val_bus(pe_result_val_bus),
        .c_wr_en(c_store_wr_en), .c_wr_addr(c_store_wr_addr), .c_wr_data(c_store_wr_data),
        .empty(store_empty), .busy(store_busy), .error_no_row(store_error_no_row)
    );

    // The C RAM write port is shared by the clear sequencer and Store.
    // Store is inactive during TOP_CLEAR, so this mux has no write-write arbitration.
    wire c_clear_wr_en = (top_state == TOP_CLEAR);
    wire c_wr_en_mux = c_clear_wr_en | (c_store_wr_en && top_state==TOP_RUN && !error);
    wire [C_ADDR_W-1:0] c_wr_addr_mux = c_clear_wr_en ? clear_addr : c_store_wr_addr;
    wire [VAL_W-1:0] c_wr_data_mux = c_clear_wr_en ? {VAL_W{1'b0}} : c_store_wr_data;

    wire [VAL_W-1:0] dbg_c_raw;
    assign dbg_c_dout = (dbg_c_addr<C_DEPTH) ? dbg_c_raw : {VAL_W{1'b0}};
    C_res_ram #(.DATA_W(VAL_W), .ADDR_W(C_ADDR_W), .DEPTH(C_DEPTH))
    u_c_res_ram (
        .clk(clk), .wr_en(c_wr_en_mux), .wr_addr(c_wr_addr_mux), .wr_data(c_wr_data_mux),
        .rd_en(dbg_c_en && dbg_c_addr<C_DEPTH), .rd_addr(dbg_c_addr), .rd_data(dbg_c_raw)
    );

endmodule

`default_nettype wire
