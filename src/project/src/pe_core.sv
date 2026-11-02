`timescale 1ns/1ps
`default_nettype none

`include "spmm_loader_defs.svh"
// -----------------------------------------------------------------------------
// Per-lane processing element.
//
// Both A and B enter through ready/valid FIFOs.  This keeps the PE independent
// from loader timing and avoids a separate broadcast path in SpMM mode.
//
// SpMM payloads:
//   A FIFO: {dummy,eor,k_idx,a_val}
//   B FIFO: {dummy,eor,b_k,b_col,b_val}
//
// The PE holds one A item, drains B items until the k index matches, multiplies
// the matched B row entries, and merges the product stream with the previous
// partial row held in ping-pong FIFOs.  Non-EOR A entries write a new partial
// row; EOR entries emit the finalized sparse row to Store.
//
// Matrix ADD/SUB payloads are lane-local sparse rows.  The PE performs a sorted
// column merge and reuses the result channel used by SpMM.
// -----------------------------------------------------------------------------

module pe_core #(
    parameter integer ROW_W       = `SPMM_ROW_W,
    parameter integer K_W         = `SPMM_K_W,
    parameter integer COL_W       = `SPMM_COL_W,
    parameter integer VAL_W       = `SPMM_VAL_W,
    parameter integer BUF_DEPTH   = `SPMM_PE_BUF_DEPTH,
    parameter integer BUF_ADDR_W  = `SPMM_PE_BUF_ADDR_W,
    parameter integer META_DEPTH  = `SPMM_PE_META_DEPTH,
    parameter integer META_ADDR_W = `SPMM_PE_META_ADDR_W,
    parameter integer FP_LATENCY  = 2
) (
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   a_valid,
    output wire                   a_ready,
    input  wire [K_W-1:0]         a_idx,
    input  wire [VAL_W-1:0]       a_val,
    input  wire                   a_eor,
    input  wire                   a_dummy,

    input  wire [ROW_W-1:0]       lane_row,

    input  wire                   b_valid,
    output wire                   b_ready,
    input  wire [K_W-1:0]         b_k,
    input  wire [COL_W-1:0]       b_col,
    input  wire [VAL_W-1:0]       b_val,
    input  wire                   b_eor,
    input  wire                   b_dummy,

    input  wire [1:0]             cfg_pe_mode,

    output wire                   result_valid,
    input  wire                   result_ready,
    output wire [ROW_W-1:0]       result_row,
    output wire [COL_W-1:0]       result_col,
    output wire [VAL_W-1:0]       result_val,

    output wire                   pe_busy,
    output reg                    pe_error,
    output wire                   block_idle
);
    localparam integer PARTIAL_W = COL_W + VAL_W;

    wire spmm_mode    = (cfg_pe_mode == `SPMM_PE_MODE_SPMM);
    wire mat_add_mode = (cfg_pe_mode == `SPMM_PE_MODE_MAT_ADD);
    wire mat_sub_mode = (cfg_pe_mode == `SPMM_PE_MODE_MAT_SUB);
    wire mat_mode     = mat_add_mode | mat_sub_mode;

    function [15:0] fp_neg;
        input [15:0] x;
        begin
            fp_neg = x ^ 16'h8000;
        end
    endfunction

    // ---------------------------------------------------------------------
    // Single-entry result channel register.
    // ---------------------------------------------------------------------
    reg              res_valid_r;
    reg [COL_W-1:0] res_col_r;
    reg [VAL_W-1:0] res_val_r;

    assign result_valid = res_valid_r;
    assign result_row   = lane_row;
    assign result_col   = res_col_r;
    assign result_val   = res_val_r;

    wire res_fire = res_valid_r && result_ready;

    // ---------------------------------------------------------------------
    // FIFO-based ping-pong partial buffers for SpMM.
    // Data format is {col, val}; old_sel selects the FIFO being read as the
    // previous partial row and the other FIFO receives the merged row.
    // ---------------------------------------------------------------------
    reg                    buf0_clear;
    reg                    buf1_clear;
    wire                   buf0_in_valid;
    wire                   buf0_in_ready;
    wire [PARTIAL_W-1:0]   buf0_in_data;
    wire                   buf0_out_valid;
    wire                   buf0_out_ready;
    wire [PARTIAL_W-1:0]   buf0_out_data;
    wire                   buf0_empty;
    wire                   buf0_full;

    wire                   buf1_in_valid;
    wire                   buf1_in_ready;
    wire [PARTIAL_W-1:0]   buf1_in_data;
    wire                   buf1_out_valid;
    wire                   buf1_out_ready;
    wire [PARTIAL_W-1:0]   buf1_out_data;
    wire                   buf1_empty;
    wire                   buf1_full;

    pe_partial_fifo #(.DATA_W(PARTIAL_W), .DEPTH(BUF_DEPTH), .ADDR_W(BUF_ADDR_W))
    u_partial_buf0 (
        .clk(clk), .rst_n(rst_n), .clear(buf0_clear),
        .in_valid(buf0_in_valid), .in_ready(buf0_in_ready), .in_data(buf0_in_data),
        .out_valid(buf0_out_valid), .out_ready(buf0_out_ready), .out_data(buf0_out_data),
        .empty(buf0_empty), .full(buf0_full)
    );

    pe_partial_fifo #(.DATA_W(PARTIAL_W), .DEPTH(BUF_DEPTH), .ADDR_W(BUF_ADDR_W))
    u_partial_buf1 (
        .clk(clk), .rst_n(rst_n), .clear(buf1_clear),
        .in_valid(buf1_in_valid), .in_ready(buf1_in_ready), .in_data(buf1_in_data),
        .out_valid(buf1_out_valid), .out_ready(buf1_out_ready), .out_data(buf1_out_data),
        .empty(buf1_empty), .full(buf1_full)
    );

    reg old_sel;  // 0: buf0 is old/read FIFO, buf1 is new/write FIFO. 1: opposite.

    wire                 old_valid = old_sel ? buf1_out_valid : buf0_out_valid;
    wire [PARTIAL_W-1:0] old_data  = old_sel ? buf1_out_data  : buf0_out_data;
    wire [COL_W-1:0]     old_col   = old_data[VAL_W +: COL_W];
    wire [VAL_W-1:0]     old_val   = old_data[0 +: VAL_W];

    wire                 new_ready = old_sel ? buf0_in_ready : buf1_in_ready;

    // ---------------------------------------------------------------------
    // SpMM state.
    // ---------------------------------------------------------------------
    localparam [2:0] SPMM_IDLE  = 3'd0;
    localparam [2:0] SPMM_SEEK  = 3'd1;
    localparam [2:0] SPMM_MERGE = 3'd2;
    localparam [2:0] SPMM_WAIT_MUL = 3'd3;
    localparam [2:0] SPMM_WAIT_ADD = 3'd4;
    reg spmm_sum_valid;
    reg [15:0] spmm_sum;
    reg mat_wait_sum, mat_sum_valid;
    reg [15:0] mat_sum;

    reg [2:0]       spmm_state;
    reg [K_W-1:0]   cur_a_k;
    reg [VAL_W-1:0] cur_a_val;
    reg             cur_a_eor;
    reg             cur_a_valid;

    reg             prod_valid;
    reg [COL_W-1:0] prod_col;
    reg [VAL_W-1:0] prod_val;
    reg             b_match_done;

    // Sorted merge decision for old partial entries and current product entry.
    reg             merge_emit_valid;
    reg             merge_take_old;
    reg             merge_take_prod;
    reg [COL_W-1:0] merge_col;
    reg [VAL_W-1:0] merge_val;

    always @(*) begin
        merge_emit_valid = 1'b0;
        merge_take_old   = 1'b0;
        merge_take_prod  = 1'b0;
        merge_col        = {COL_W{1'b0}};
        merge_val        = {VAL_W{1'b0}};

        if (spmm_state == SPMM_MERGE) begin
            if (old_valid && prod_valid) begin
                merge_emit_valid = 1'b1;
                if (old_col == prod_col) begin
                    merge_take_old  = 1'b1;
                    merge_take_prod = 1'b1;
                    merge_col       = old_col;
                    merge_emit_valid = spmm_sum_valid;
                    merge_val       = spmm_sum;
                end else if (old_col < prod_col) begin
                    merge_take_old  = 1'b1;
                    merge_col       = old_col;
                    merge_val       = old_val;
                end else begin
                    merge_take_prod = 1'b1;
                    merge_col       = prod_col;
                    merge_val       = prod_val;
                end
            end else if (prod_valid) begin
                merge_emit_valid = 1'b1;
                merge_take_prod  = 1'b1;
                merge_col        = prod_col;
                merge_val        = prod_val;
            end else if (old_valid && b_match_done) begin
                merge_emit_valid = 1'b1;
                merge_take_old   = 1'b1;
                merge_col        = old_col;
                merge_val        = old_val;
            end
        end
    end

    wire merge_to_result = cur_a_eor;
    wire merge_dst_ready = merge_to_result ? !res_valid_r : new_ready;
    wire merge_fire      = spmm_mode && (spmm_state == SPMM_MERGE) && merge_emit_valid && merge_dst_ready;

    wire [PARTIAL_W-1:0] merge_pack = {merge_col, merge_val};

    assign buf0_in_valid = spmm_mode && merge_fire && !merge_to_result && old_sel;
    assign buf1_in_valid = spmm_mode && merge_fire && !merge_to_result && !old_sel;
    assign buf0_in_data  = merge_pack;
    assign buf1_in_data  = merge_pack;

    assign buf0_out_ready = spmm_mode && merge_fire && merge_take_old && !old_sel;
    assign buf1_out_ready = spmm_mode && merge_fire && merge_take_old &&  old_sel;

    // ---------------------------------------------------------------------
    // ADD/SUB sparse merge state.
    // A and B hold at most one current entry.  EOR flags close each lane row.
    // ---------------------------------------------------------------------
    reg mat_a_cur_valid;
    reg [COL_W-1:0] mat_a_col;
    reg [VAL_W-1:0] mat_a_val;
    reg mat_a_eor;
    reg mat_a_done;

    reg mat_b_cur_valid;
    reg [COL_W-1:0] mat_b_col;
    reg [VAL_W-1:0] mat_b_val;
    reg mat_b_eor;
    reg mat_b_done;

    reg mat_pending_consume_a;
    reg mat_pending_consume_b;

    reg [COL_W-1:0] mat_emit_col;
    reg [VAL_W-1:0] mat_emit_val;
    reg             mat_emit_consume_a;
    reg             mat_emit_consume_b;
    reg             mat_emit_valid;

    always @(*) begin
        mat_emit_col       = {COL_W{1'b0}};
        mat_emit_val       = {VAL_W{1'b0}};
        mat_emit_consume_a = 1'b0;
        mat_emit_consume_b = 1'b0;
        mat_emit_valid     = 1'b0;

        if (mat_a_cur_valid && mat_b_cur_valid) begin
            mat_emit_valid = 1'b1;
            if (mat_a_col == mat_b_col) begin
                mat_emit_col       = mat_a_col;
                mat_emit_valid     = mat_sum_valid;
                mat_emit_val       = mat_sum;
                mat_emit_consume_a = 1'b1;
                mat_emit_consume_b = 1'b1;
            end else if (mat_a_col < mat_b_col) begin
                mat_emit_col       = mat_a_col;
                mat_emit_val       = mat_a_val;
                mat_emit_consume_a = 1'b1;
            end else begin
                mat_emit_col       = mat_b_col;
                mat_emit_val       = mat_sub_mode ? fp_neg(mat_b_val) : mat_b_val;
                mat_emit_consume_b = 1'b1;
            end
        end else if (mat_a_cur_valid && mat_b_done) begin
            mat_emit_valid     = 1'b1;
            mat_emit_col       = mat_a_col;
            mat_emit_val       = mat_a_val;
            mat_emit_consume_a = 1'b1;
        end else if (mat_b_cur_valid && mat_a_done) begin
            mat_emit_valid     = 1'b1;
            mat_emit_col       = mat_b_col;
            mat_emit_val       = mat_sub_mode ? fp_neg(mat_b_val) : mat_b_val;
            mat_emit_consume_b = 1'b1;
        end
    end

    wire mat_need_a = mat_mode && !mat_a_cur_valid && !mat_a_done && !res_valid_r && !mat_pending_consume_a && !mat_pending_consume_b;
    wire mat_need_b = mat_mode && !mat_b_cur_valid && !mat_b_done && !res_valid_r && !mat_pending_consume_a && !mat_pending_consume_b;

    wire mat_can_emit = mat_mode && !mat_wait_sum && !res_valid_r && !mat_pending_consume_a && !mat_pending_consume_b && mat_emit_valid;

    reg [1:0] mode_q;
    wire mode_changed = (mode_q != cfg_pe_mode);
    wire exec_req_ready, exec_rsp_valid;
    wire [15:0] exec_result;
    wire mul_candidate = spmm_mode && (spmm_state == SPMM_SEEK) &&
                         b_valid && (b_k == cur_a_k) && !b_dummy &&
                         (b_val != 0) && !prod_valid;
    wire add_candidate = spmm_mode && (spmm_state == SPMM_MERGE) &&
                         old_valid && prod_valid && (old_col == prod_col) && !spmm_sum_valid;
    wire mat_add_candidate = mat_mode && mat_a_cur_valid && mat_b_cur_valid &&
                             (mat_a_col == mat_b_col) && !res_valid_r &&
                             !mat_pending_consume_a && !mat_pending_consume_b &&
                             !mat_wait_sum && !mat_sum_valid;
    wire exec_req_valid = mul_candidate || add_candidate || mat_add_candidate;
    wire [1:0] exec_op = mul_candidate ? 2'd2 : (mat_add_candidate && mat_sub_mode ? 2'd1 : 2'd0);
    wire [15:0] exec_a = mul_candidate ? cur_a_val : (add_candidate ? old_val : mat_a_val);
    wire [15:0] exec_b = mul_candidate ? b_val : (add_candidate ? prod_val : mat_b_val);
    wire exec_rsp_ready = (spmm_state == SPMM_WAIT_MUL) ||
                          (spmm_state == SPMM_WAIT_ADD) || mat_wait_sum;
    fp16_exec #(.LATENCY(FP_LATENCY)) u_fp16_exec (
        .clk(clk), .rst_n(rst_n && !mode_changed),
        .req_valid(exec_req_valid), .req_ready(exec_req_ready),
        .req_op(exec_op), .req_a(exec_a), .req_b(exec_b),
        .rsp_valid(exec_rsp_valid), .rsp_ready(exec_rsp_ready), .rsp_result(exec_result)
    );

    // ---------------------------------------------------------------------
    // Input ready signals.
    // ---------------------------------------------------------------------
    wire spmm_idle_drain_b = spmm_mode && (spmm_state == SPMM_IDLE) && !a_valid;
    wire spmm_seek_drop_b  = spmm_mode && (spmm_state == SPMM_SEEK) && b_valid && (b_k < cur_a_k);
    wire spmm_seek_take_b  = spmm_mode && (spmm_state == SPMM_SEEK) && b_valid && (b_k == cur_a_k) && !prod_valid &&
                              (b_dummy || (b_val == 0) || exec_req_ready);

    assign a_ready = spmm_mode ? (spmm_state == SPMM_IDLE) : mat_need_a;
    assign b_ready = spmm_mode ? (spmm_idle_drain_b || spmm_seek_drop_b || spmm_seek_take_b) : mat_need_b;

    wire a_fire = a_valid && a_ready;
    wire b_fire = b_valid && b_ready;

    // ---------------------------------------------------------------------
    // Main sequential logic.
    // ---------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Asynchronous reset must load a constant. A dynamic reset value
            // infers unsupported preset/clear behavior in FPGA primitives.
            mode_q <= 2'd0;

            res_valid_r <= 1'b0;
            res_col_r   <= {COL_W{1'b0}};
            res_val_r   <= {VAL_W{1'b0}};
            pe_error    <= 1'b0;
            spmm_sum_valid <= 0; spmm_sum <= 0;
            mat_wait_sum <= 0; mat_sum_valid <= 0; mat_sum <= 0;

            spmm_state  <= SPMM_IDLE;
            cur_a_k     <= {K_W{1'b0}};
            cur_a_val   <= {VAL_W{1'b0}};
            cur_a_eor   <= 1'b0;
            cur_a_valid <= 1'b0;
            prod_valid  <= 1'b0;
            prod_col    <= {COL_W{1'b0}};
            prod_val    <= {VAL_W{1'b0}};
            b_match_done <= 1'b0;
            old_sel     <= 1'b0;
            buf0_clear  <= 1'b1;
            buf1_clear  <= 1'b1;

            mat_a_cur_valid <= 1'b0;
            mat_a_col       <= {COL_W{1'b0}};
            mat_a_val       <= {VAL_W{1'b0}};
            mat_a_eor       <= 1'b0;
            mat_a_done      <= 1'b0;
            mat_b_cur_valid <= 1'b0;
            mat_b_col       <= {COL_W{1'b0}};
            mat_b_val       <= {VAL_W{1'b0}};
            mat_b_eor       <= 1'b0;
            mat_b_done      <= 1'b0;
            mat_pending_consume_a <= 1'b0;
            mat_pending_consume_b <= 1'b0;
        end else begin
            mode_q <= cfg_pe_mode;
            buf0_clear <= 1'b0;
            buf1_clear <= 1'b0;

            if (mode_changed) begin
                spmm_sum_valid <= 0; mat_wait_sum <= 0; mat_sum_valid <= 0;
                res_valid_r <= 1'b0;
                spmm_state  <= SPMM_IDLE;
                cur_a_valid <= 1'b0;
                prod_valid  <= 1'b0;
                b_match_done <= 1'b0;
                old_sel     <= 1'b0;
                buf0_clear  <= 1'b1;
                buf1_clear  <= 1'b1;

                mat_a_cur_valid <= 1'b0;
                mat_a_done      <= 1'b0;
                mat_b_cur_valid <= 1'b0;
                mat_b_done      <= 1'b0;
                mat_pending_consume_a <= 1'b0;
                mat_pending_consume_b <= 1'b0;
            end else begin
                if (res_fire) begin
                    res_valid_r <= 1'b0;
                end

                if (exec_req_valid && exec_req_ready) begin
                    if (add_candidate) spmm_state <= SPMM_WAIT_ADD;
                    if (mat_add_candidate) mat_wait_sum <= 1;
                end
                if (mat_wait_sum && exec_rsp_valid) begin
                    mat_sum <= exec_result; mat_sum_valid <= 1; mat_wait_sum <= 0;
                end

                // SpMM mode: seek matching B rows and merge products into the
                // ping-pong partial buffers.
                if (spmm_mode) begin
                    case (spmm_state)
                        SPMM_IDLE: begin
                            // When A is absent, ready stays high for stale B
                            // traffic so block tails cannot clog B FIFOs.
                            if (a_fire) begin
                                cur_a_k      <= a_idx;
                                cur_a_val    <= a_val;
                                cur_a_eor    <= a_eor;
                                cur_a_valid  <= !a_dummy;
                                prod_valid   <= 1'b0;
                                b_match_done <= a_dummy;

                                // The destination FIFO is recycled before the
                                // next non-final partial row is accumulated.
                                if (!a_eor) begin
                                    if (old_sel) buf0_clear <= 1'b1;
                                    else         buf1_clear <= 1'b1;
                                end

                                if (a_dummy) begin
                                    // Dummy EOR closes an empty row while still
                                    // allowing prior partials to flush.
                                    spmm_state <= SPMM_MERGE;
                                end else begin
                                    spmm_state <= SPMM_SEEK;
                                end
                            end
                        end

                        SPMM_SEEK: begin
                            if (b_fire) begin
                                // b_k < current A.k is stale for this lane.
                                if (b_k == cur_a_k) begin
                                    if (!b_dummy && (b_val != {VAL_W{1'b0}})) begin
                                        prod_col   <= b_col;
                                        spmm_state <= SPMM_WAIT_MUL;
                                    end
                                    if (b_eor || b_dummy) begin
                                        b_match_done <= 1'b1;
                                    end
                                    if (b_dummy || (b_val == 0))
                                        spmm_state <= SPMM_MERGE;
                                end
                            end else if (b_valid && (b_k > cur_a_k)) begin
                                // b_k > current A.k means this A item has no
                                // matching B row.  Keep the B item for later A.
                                b_match_done <= 1'b1;
                                spmm_state   <= SPMM_MERGE;
                            end
                        end

                        SPMM_WAIT_MUL: begin
                            if (exec_rsp_valid) begin
                                prod_val <= exec_result;
                                prod_valid <= 1;
                                spmm_state <= SPMM_MERGE;
                            end
                        end
                        SPMM_WAIT_ADD: begin
                            if (exec_rsp_valid) begin
                                spmm_sum <= exec_result;
                                spmm_sum_valid <= 1;
                                spmm_state <= SPMM_MERGE;
                            end
                        end
                        SPMM_MERGE: begin
                            if (merge_fire) begin
                                spmm_sum_valid <= 0;
                                if (merge_to_result) begin
                                    res_valid_r <= 1'b1;
                                    res_col_r   <= merge_col;
                                    res_val_r   <= merge_val;
                                end
                                if (merge_take_prod) begin
                                    prod_valid <= 1'b0;
                                end
                            end

                            // Old entries are not emitted ahead of a possible
                            // product with a smaller/equal column.
                            if (!prod_valid && !b_match_done && !merge_fire) begin
                                spmm_state <= SPMM_SEEK;
                            end

                            // A item retirement waits for product, old partial
                            // and result register drain to avoid row interleave.
                            if (b_match_done && !prod_valid && !old_valid && !res_valid_r && !merge_emit_valid) begin
                                cur_a_valid  <= 1'b0;
                                b_match_done <= 1'b0;
                                if (cur_a_eor) begin
                                    old_sel    <= 1'b0;
                                    buf0_clear <= 1'b1;
                                    buf1_clear <= 1'b1;
                                end else begin
                                    old_sel <= ~old_sel;
                                end
                                spmm_state <= SPMM_IDLE;
                            end
                        end

                        default: begin
                            spmm_state <= SPMM_IDLE;
                        end
                    endcase
                end

                // ADD/SUB mode: sorted sparse row merge for lane-local streams.
                if (mat_mode) begin
                    if (a_fire) begin
                        if (a_dummy) begin
                            mat_a_cur_valid <= 1'b0;
                            if (a_eor) mat_a_done <= 1'b1;
                        end else begin
                            mat_a_cur_valid <= 1'b1;
                            mat_a_col       <= a_idx[COL_W-1:0];
                            mat_a_val       <= a_val;
                            mat_a_eor       <= a_eor;
                        end
                    end

                    if (b_fire) begin
                        if (b_dummy) begin
                            mat_b_cur_valid <= 1'b0;
                            if (b_eor) mat_b_done <= 1'b1;
                        end else begin
                            mat_b_cur_valid <= 1'b1;
                            mat_b_col       <= b_col;
                            mat_b_val       <= b_val;
                            mat_b_eor       <= b_eor;
                        end
                    end

                    if (mat_can_emit) begin
                        mat_sum_valid <= 0;
                        res_valid_r <= 1'b1;
                        res_col_r   <= mat_emit_col;
                        res_val_r   <= mat_emit_val;
                        mat_pending_consume_a <= mat_emit_consume_a;
                        mat_pending_consume_b <= mat_emit_consume_b;
                    end

                    if (res_fire) begin
                        if (mat_pending_consume_a) begin
                            mat_a_cur_valid <= 1'b0;
                            if (mat_a_eor) mat_a_done <= 1'b1;
                        end
                        if (mat_pending_consume_b) begin
                            mat_b_cur_valid <= 1'b0;
                            if (mat_b_eor) mat_b_done <= 1'b1;
                        end
                        mat_pending_consume_a <= 1'b0;
                        mat_pending_consume_b <= 1'b0;
                    end

                    if (mat_a_done && mat_b_done && !mat_a_cur_valid && !mat_b_cur_valid &&
                        !res_valid_r && !mat_pending_consume_a && !mat_pending_consume_b) begin
                        mat_a_done <= 1'b0;
                        mat_b_done <= 1'b0;
                    end
                end
            end
        end
    end

    // Partial rows intentionally survive a block boundary. They make pe_busy
    // true, but must not prevent the next block from continuing that row.
    assign block_idle = spmm_mode && (spmm_state == SPMM_IDLE) &&
                        !cur_a_valid && !prod_valid && !b_match_done && !res_valid_r;

    assign pe_busy = spmm_mode ? ((spmm_state != SPMM_IDLE) || cur_a_valid || prod_valid || b_match_done ||
                                  res_valid_r || !buf0_empty || !buf1_empty) :
                                  (mat_a_cur_valid || mat_b_cur_valid || mat_a_done || mat_b_done ||
                                   mat_pending_consume_a || mat_pending_consume_b || res_valid_r);

endmodule

// -----------------------------------------------------------------------------
// PE-local fall-through FIFO with synchronous clear.
// Used by the ping-pong partial-row buffers; clear provides row-granular reuse
// without touching the shared project-level FIFO.
// -----------------------------------------------------------------------------
module pe_partial_fifo #(
    parameter integer DATA_W = 32,
    parameter integer DEPTH  = 512,
    parameter integer ADDR_W = 9
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clear,

    input  wire              in_valid,
    output wire              in_ready,
    input  wire [DATA_W-1:0] in_data,

    output wire              out_valid,
    input  wire              out_ready,
    output wire [DATA_W-1:0] out_data,

    output wire              empty,
    output wire              full
);
    localparam [ADDR_W:0]   DEPTH_COUNT = DEPTH;
    localparam [ADDR_W-1:0] DEPTH_LAST  = DEPTH - 1;

    (* ram_style = "distributed" *) reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [ADDR_W-1:0] rd_ptr;
    reg [ADDR_W-1:0] wr_ptr;
    reg [ADDR_W:0]   count_r;

    wire do_push = in_valid  && in_ready;
    wire do_pop  = out_valid && out_ready;

    assign empty     = (count_r == {(ADDR_W+1){1'b0}});
    assign full      = (count_r == DEPTH_COUNT);
    assign in_ready  = !full;
    assign out_valid = !empty;
    assign out_data  = mem[rd_ptr];

    // Preserve data across reset/clear; only pointer/count state is cleared.
    // A plain clocked write permits LUTRAM inference in Vivado.
    always @(posedge clk) begin
        if (rst_n && !clear && do_push) mem[wr_ptr] <= in_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr  <= {ADDR_W{1'b0}};
            wr_ptr  <= {ADDR_W{1'b0}};
            count_r <= {(ADDR_W+1){1'b0}};
        end else if (clear) begin
            rd_ptr  <= {ADDR_W{1'b0}};
            wr_ptr  <= {ADDR_W{1'b0}};
            count_r <= {(ADDR_W+1){1'b0}};
        end else begin
            if (do_push) begin
                if (wr_ptr == DEPTH_LAST) wr_ptr <= {ADDR_W{1'b0}};
                else wr_ptr <= wr_ptr + 1'b1;
            end

            if (do_pop) begin
                if (rd_ptr == DEPTH_LAST) rd_ptr <= {ADDR_W{1'b0}};
                else rd_ptr <= rd_ptr + 1'b1;
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
