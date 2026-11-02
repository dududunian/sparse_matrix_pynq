`timescale 1ns/1ps
`default_nettype none

`include "spmm_loader_defs.svh"

// -----------------------------------------------------------------------------
// B stream loader.
//
// Boundary:
//   - accepts SpMM k-lists from A_loader and converts them to a per-block
//     k_bitmap;
//   - fetches packed B rows/chunks from the pointer and value ROMs;
//   - pushes B FIFO entries through the same per-lane interface for all modes.
//
// In SpMM, each serialized B row entry is replicated to all lanes; PE instances
// keep or discard the item by comparing b_k against their current A k_idx.
// In ADD/SUB, B_val_rom is treated as an identity-order compact-CSV stream and the
// row pointer ROM is not part of the active path.
// -----------------------------------------------------------------------------
module B_loader #(
    parameter integer PE_LANES   = `SPMM_PE_LANES,
    parameter integer K_MAX      = `SPMM_K_MAX,
    parameter integer K_W        = `SPMM_K_W,
    parameter integer ROW_W      = `SPMM_ROW_W,
    parameter integer VAL_W      = `SPMM_VAL_W,
    parameter integer COL_W      = `SPMM_COL_W,
    parameter integer PTR_W      = `SPMM_PTR_W,
    parameter integer PTR_ADDR_W = `SPMM_B_PTR_ADDR_W,
    parameter integer B_ADDR_W   = `SPMM_B_VAL_ADDR_W,
    parameter integer B_PACK_W   = `SPMM_B_PACK_W,
    parameter integer GROUP_W    = `SPMM_GROUP_W,
    parameter integer K_CHUNK    = 8
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,

    input  wire [1:0]                   cfg_pe_mode,
    input  wire [ROW_W-1:0]             cfg_m,
    input  wire [K_W-1:0]               cfg_k,
    input  wire [15:0]                  cfg_n,
    input  wire [31:0]                  cfg_b_chunk_count,
    input  wire [PTR_ADDR_W-1:0]        cfg_b_spmm_ptr_base,
    input  wire [PTR_ADDR_W-1:0]        cfg_b_add_ptr_base,   // kept for top compatibility; not used in ADD/SUB
    input  wire                         store_group_ready,

    output wire                         busy,
    output reg                          done,
    output reg                          error_bad_k,

    input  wire                         k_update_valid,
    output wire                         k_update_ready,
    input  wire [PE_LANES-1:0]          k_update_mask,
    input  wire [PE_LANES*K_W-1:0]      k_update_bus,

    input  wire                         a_block_done_valid,
    output wire                         a_block_done_ready,
    input  wire                         a_block_done_last,

    output reg                          b_rowptr_en,
    output reg  [PTR_ADDR_W-1:0]        b_rowptr_addr,
    input  wire [PTR_W-1:0]             b_row_start_ptr,
    input  wire [PTR_W-1:0]             b_row_end_ptr,

    output reg                          b_val_en,
    output reg  [B_ADDR_W-1:0]          b_val_addr,
    input  wire [B_PACK_W-1:0]          b_val_dout,

    output wire [PE_LANES-1:0]          b_push_valid,
    input  wire [PE_LANES-1:0]          b_push_ready,
    output wire [PE_LANES*K_W-1:0]      b_push_k_bus,
    output wire [PE_LANES*COL_W-1:0]    b_push_col_bus,
    output wire [PE_LANES*VAL_W-1:0]    b_push_val_bus,
    output wire [PE_LANES-1:0]          b_push_eor,
    output wire [PE_LANES-1:0]          b_push_dummy,

    output wire                         b_block_done_valid,
    input  wire                         b_block_done_ready,
    output wire                         b_block_done_last
);

    localparam [4:0]
        S_IDLE          = 5'd0,

        // SpMM block collection, pointer lookup and serialized B-row replay.
        S_COLLECT       = 5'd1,
        S_KPROC         = 5'd2,
        S_SCAN          = 5'd3,
        S_PTR_REQ       = 5'd4,
        S_PTR_WAIT      = 5'd5,
        S_PTR_LATCH     = 5'd6,
        S_VAL_REQ       = 5'd7,
        S_VAL_WAIT      = 5'd8,
        S_VAL_LATCH     = 5'd9,
        S_SER           = 5'd10,
        S_EMIT          = 5'd11,
        S_BLOCK_DONE    = 5'd12,

        // ADD/SUB identity compact-CSV stream; no pointer lookup is issued.
        S_ADD_INIT      = 5'd13,
        S_ADD_VAL_REQ   = 5'd14,
        S_ADD_VAL_WAIT  = 5'd15,
        S_ADD_VAL_LATCH = 5'd16,
        S_ADD_PUSH      = 5'd17,
        S_ADD_WAIT_GRP  = 5'd18,

        S_DONE          = 5'd19;

    wire spmm_mode = (cfg_pe_mode == `SPMM_PE_MODE_SPMM);
    wire mat_mode  = (cfg_pe_mode == `SPMM_PE_MODE_MAT_ADD) ||
                     (cfg_pe_mode == `SPMM_PE_MODE_MAT_SUB);

    reg [4:0] state;
    reg       start_d;
    wire      start_pulse = start & ~start_d;

    // ---------------------------------------------------------------------
    // SpMM k collection and row scan state.
    // k_bitmap is cleared after every a_block_done/b_block_done transaction.
    // ---------------------------------------------------------------------
    reg [K_MAX-1:0] k_bitmap;
    reg [PE_LANES-1:0]     pending_mask;
    reg [PE_LANES*K_W-1:0] pending_bus;
    reg [6:0]              kproc_base;

    reg [K_W-1:0] scan_k;
    reg [K_W-1:0] cur_k;
    reg           block_last_r;

    reg [PTR_W-1:0] row_start_r;
    reg [PTR_W-1:0] row_end_r;
    reg [PTR_W-1:0] chunk_ptr;
    reg             chunk_last_r;
    reg [B_PACK_W-1:0] chunk_buf;
    reg [6:0]       ser_idx;
    reg             row_emitted_any;

    reg [K_W-1:0]   emit_k;
    reg [COL_W-1:0] emit_col;
    reg [VAL_W-1:0] emit_val;
    reg             emit_eor;
    reg             emit_dummy;

    // ---------------------------------------------------------------------
    // ADD/SUB sequential compact-CSV B stream state.
    // add_vec_ptr is a value-ROM address, not a pointer-ROM derived address.
    // ---------------------------------------------------------------------
    reg [GROUP_W-1:0] add_group_idx;
    reg [B_ADDR_W:0] add_vec_ptr;
    reg [B_PACK_W-1:0] add_vec_buf;
    reg [PE_LANES-1:0] add_lane_active;

    // Per-lane pending masks give every broadcast/parallel item exactly one
    // write into each destination FIFO, even when lanes apply backpressure at different cycles.

    reg [PE_LANES-1:0] spmm_push_pending_mask;
    reg [PE_LANES-1:0] add_push_pending_mask;

    wire [ROW_W-1:0] add_group_base = ({{(ROW_W-GROUP_W){1'b0}}, add_group_idx} << 6);
    localparam [ROW_W-1:0] ROW_GROUP_SIZE = 64;

    reg [PE_LANES-1:0] add_valid_lane_mask;
    integer ii;
    always @(*) begin
        add_valid_lane_mask = {PE_LANES{1'b0}};
        for (ii = 0; ii < PE_LANES; ii = ii + 1) begin
            if ((add_group_base + ii[ROW_W-1:0]) < cfg_m)
                add_valid_lane_mask[ii] = 1'b1;
        end
    end

    wire [PE_LANES-1:0] add_eor_mask = add_vec_buf[PE_LANES-1:0];
    wire [PE_LANES-1:0] add_lane_after =
        add_lane_active & ~(add_lane_active & add_eor_mask);

    wire add_group_done_after =
        (add_lane_after == {PE_LANES{1'b0}});

    wire add_last_group_after =
        ((add_group_base + ROW_GROUP_SIZE) >= cfg_m);

    // ---------------------------------------------------------------------
    // Push handshakes.
    // These masks are the only place where ready signals retire pending writes.
    // ---------------------------------------------------------------------
    wire [PE_LANES-1:0] spmm_push_fire_mask =
        (state == S_EMIT) ? (spmm_push_pending_mask & b_push_ready) :
                            {PE_LANES{1'b0}};
    wire [PE_LANES-1:0] spmm_push_pending_next =
        spmm_push_pending_mask & ~spmm_push_fire_mask;
    wire spmm_push_done_after =
        (spmm_push_pending_next == {PE_LANES{1'b0}});

    wire [PE_LANES-1:0] add_push_fire_mask =
        (state == S_ADD_PUSH) ? (add_push_pending_mask & b_push_ready) :
                                {PE_LANES{1'b0}};
    wire [PE_LANES-1:0] add_push_pending_next =
        add_push_pending_mask & ~add_push_fire_mask;
    wire add_push_done_after =
        (add_push_pending_next == {PE_LANES{1'b0}});

    assign busy = (state != S_IDLE) && (state != S_DONE);

    assign k_update_ready     = (state == S_COLLECT);
    assign a_block_done_ready = (state == S_COLLECT);

    // b_block_done is part of the SpMM block protocol.  ADD/SUB advances by
    // store_group_ready because both A and B are lane-local streams.
    assign b_block_done_valid = (state == S_BLOCK_DONE);
    assign b_block_done_last  = block_last_r;

    wire spmm_emit_active = (state == S_EMIT);
    wire add_emit_active  = (state == S_ADD_PUSH);

    // ---------------------------------------------------------------------
    // Output decoding.
    // SpMM drives one replicated item; ADD/SUB decodes one lane word per lane.
    // ---------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < PE_LANES; g = g + 1) begin : GEN_B_PUSH
            wire [31:0] add_lane_word;
            assign add_lane_word = add_vec_buf[(2+g)*32 +: 32];

            assign b_push_valid[g] =
                spmm_emit_active ? spmm_push_pending_mask[g] :
                add_emit_active  ? add_push_pending_mask[g]  :
                                   1'b0;

            assign b_push_k_bus[g*K_W +: K_W] =
                spmm_emit_active ? emit_k : {K_W{1'b0}};

            assign b_push_col_bus[g*COL_W +: COL_W] =
                spmm_emit_active ? emit_col : add_lane_word[31:16];

            assign b_push_val_bus[g*VAL_W +: VAL_W] =
                spmm_emit_active ? emit_val : add_lane_word[15:0];

            assign b_push_eor[g] =
                spmm_emit_active ? emit_eor :
                add_emit_active  ? (add_eor_mask[g] & add_lane_active[g]) :
                                   1'b0;

            assign b_push_dummy[g] =
                spmm_emit_active ? emit_dummy :
                add_emit_active  ? (add_lane_active[g] && (add_lane_word == 32'h0000_0000)) :
                                   1'b0;
        end
    endgenerate

    // ---------------------------------------------------------------------
    // SpMM B chunk serializer helpers.
    // word2..word65 contain packed {col,val}; a zero word marks padding.
    // ---------------------------------------------------------------------
    function automatic [31:0] get_chunk_word;
        input [B_PACK_W-1:0] vec;
        input integer idx;
        begin
            get_chunk_word = vec[(2+idx)*32 +: 32];
        end
    endfunction

    reg [31:0] cur_word;
    reg [31:0] next_word;
    reg        cur_word_zero;
    reg        last_real_entry;

    always @(*) begin
        cur_word = get_chunk_word(chunk_buf, ser_idx);
        if (ser_idx == 7'd63)
            next_word = 32'h0000_0000;
        else
            next_word = get_chunk_word(chunk_buf, ser_idx + 1);

        cur_word_zero   = (cur_word == 32'h0000_0000);
        last_real_entry = chunk_last_r &&
                          ((ser_idx == 7'd63) || (next_word == 32'h0000_0000));
    end

    integer jj;
    reg [K_W-1:0] pending_k;

    // ---------------------------------------------------------------------
    // Main FSM.
    // Synchronous ROM reads use request, wait and latch states explicitly.
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            start_d          <= 1'b0;
            done             <= 1'b0;
            error_bad_k      <= 1'b0;

            b_rowptr_en      <= 1'b0;
            b_rowptr_addr    <= {PTR_ADDR_W{1'b0}};
            b_val_en         <= 1'b0;
            b_val_addr       <= {B_ADDR_W{1'b0}};

            k_bitmap         <= {K_MAX{1'b0}};
            pending_mask     <= {PE_LANES{1'b0}};
            pending_bus      <= {(PE_LANES*K_W){1'b0}};
            kproc_base       <= 7'd0;
            scan_k           <= {K_W{1'b0}};
            cur_k            <= {K_W{1'b0}};
            block_last_r     <= 1'b0;

            row_start_r      <= {PTR_W{1'b0}};
            row_end_r        <= {PTR_W{1'b0}};
            chunk_ptr        <= {PTR_W{1'b0}};
            chunk_last_r     <= 1'b0;
            chunk_buf        <= {B_PACK_W{1'b0}};
            ser_idx          <= 7'd0;
            row_emitted_any  <= 1'b0;

            emit_k           <= {K_W{1'b0}};
            emit_col         <= {COL_W{1'b0}};
            emit_val         <= {VAL_W{1'b0}};
            emit_eor         <= 1'b0;
            emit_dummy       <= 1'b0;

            add_group_idx    <= {GROUP_W{1'b0}};
            add_vec_ptr      <= {B_ADDR_W{1'b0}};
            add_vec_buf      <= {B_PACK_W{1'b0}};
            add_lane_active  <= {PE_LANES{1'b0}};

            spmm_push_pending_mask <= {PE_LANES{1'b0}};
            add_push_pending_mask  <= {PE_LANES{1'b0}};
        end else begin
            start_d     <= start;
            b_rowptr_en <= 1'b0;
            b_val_en    <= 1'b0;

            case (state)
                S_IDLE: begin
                    done        <= 1'b0;
                    error_bad_k <= 1'b0;

                    if (start_pulse) begin
                        k_bitmap      <= {K_MAX{1'b0}};
                        block_last_r  <= 1'b0;
                        add_group_idx <= {GROUP_W{1'b0}};
                        add_vec_ptr   <= {B_ADDR_W{1'b0}};  // ADD/SUB B CSV starts from b_val address 0
                        add_lane_active <= {PE_LANES{1'b0}};
                        spmm_push_pending_mask <= {PE_LANES{1'b0}};
                        add_push_pending_mask  <= {PE_LANES{1'b0}};

                        if (spmm_mode)
                            state <= S_COLLECT;
                        else if (mat_mode)
                            state <= S_ADD_INIT;
                        else
                            state <= S_DONE;
                    end
                end

                // Collect one A block's k-list updates before replaying the
                // referenced B rows.
                S_COLLECT: begin
                    if (k_update_valid) begin
                        pending_mask <= k_update_mask;
                        pending_bus  <= k_update_bus;
                        kproc_base   <= 7'd0;
                        state        <= S_KPROC;
                    end else if (a_block_done_valid) begin
                        block_last_r <= a_block_done_last;
                        scan_k       <= {K_W{1'b0}};
                        state        <= S_SCAN;
                    end
                end

                S_KPROC: begin
                    for (jj = 0; jj < K_CHUNK; jj = jj + 1) begin
                        if ((kproc_base + jj) < PE_LANES) begin
                            pending_k = pending_bus[(kproc_base + jj)*K_W +: K_W];
                            if (pending_mask[kproc_base + jj]) begin
                                if (pending_k < cfg_k && pending_k < K_MAX)
                                    k_bitmap[pending_k] <= 1'b1;
                                else
                                    error_bad_k <= 1'b1;
                            end
                        end
                    end

                    if ((kproc_base + K_CHUNK) >= PE_LANES)
                        state <= S_COLLECT;
                    else
                        kproc_base <= kproc_base + K_CHUNK;
                end

                S_SCAN: begin
                    if (scan_k >= cfg_k) begin
                        state <= S_BLOCK_DONE;
                    end else if (k_bitmap[scan_k]) begin
                        cur_k         <= scan_k;
                        b_rowptr_en   <= 1'b1;
                        b_rowptr_addr <= cfg_b_spmm_ptr_base + scan_k[PTR_ADDR_W-1:0];
                        state         <= S_PTR_WAIT;
                    end else begin
                        scan_k <= scan_k + 1'b1;
                    end
                end

                // Pointer ROM timing: registered request, one wait cycle, then
                // latch start/end pointers for the selected k row.
                S_PTR_WAIT: begin
                    state <= S_PTR_LATCH;
                end

                S_PTR_LATCH: begin
                    row_start_r     <= b_row_start_ptr;
                    row_end_r       <= b_row_end_ptr;
                    chunk_ptr       <= b_row_start_ptr;
                    row_emitted_any <= 1'b0;

                    if(b_row_start_ptr>b_row_end_ptr || b_row_end_ptr>cfg_b_chunk_count) begin
                        error_bad_k<=1;state<=S_DONE;
                    end else if (b_row_start_ptr == b_row_end_ptr) begin
                        emit_k     <= cur_k;
                        emit_col   <= {COL_W{1'b0}};
                        emit_val   <= {VAL_W{1'b0}};
                        emit_eor   <= 1'b1;
                        emit_dummy <= 1'b1;
                        spmm_push_pending_mask <= {PE_LANES{1'b1}};
                        state      <= S_EMIT;
                    end else begin
                        state <= S_VAL_REQ;
                    end
                end

                S_VAL_REQ: begin
                    if(chunk_ptr>=cfg_b_chunk_count) begin error_bad_k<=1;state<=S_DONE;end
                    else begin
                        b_val_en<=1; b_val_addr<=chunk_ptr[B_ADDR_W-1:0];state<=S_VAL_WAIT;
                    end
                end

                S_VAL_WAIT: begin
                    state <= S_VAL_LATCH;
                end

                S_VAL_LATCH: begin
                    chunk_buf    <= b_val_dout;
                    chunk_last_r <= ((chunk_ptr + 1'b1) >= row_end_r);
                    ser_idx      <= 7'd0;
                    state        <= S_SER;
                end

                S_SER: begin
                    if (!cur_word_zero && cur_word[31:16]>=cfg_n) begin
                        error_bad_k<=1;state<=S_DONE;
                    end else if (cur_word_zero && chunk_last_r) begin
                        if (!row_emitted_any) begin
                            emit_k     <= cur_k;
                            emit_col   <= {COL_W{1'b0}};
                            emit_val   <= {VAL_W{1'b0}};
                            emit_eor   <= 1'b1;
                            emit_dummy <= 1'b1;
                            spmm_push_pending_mask <= {PE_LANES{1'b1}};
                            state      <= S_EMIT;
                        end else begin
                            scan_k <= cur_k + 1'b1;
                            state  <= S_SCAN;
                        end
                    end else if (cur_word_zero && !chunk_last_r) begin
                        if (ser_idx == 7'd63) begin
                            chunk_ptr <= chunk_ptr + 1'b1;
                            state     <= S_VAL_REQ;
                        end else begin
                            ser_idx <= ser_idx + 1'b1;
                        end
                    end else begin
                        emit_k     <= cur_k;
                        emit_col   <= cur_word[31:16];
                        emit_val   <= cur_word[15:0];
                        emit_eor   <= last_real_entry;
                        emit_dummy <= 1'b0;
                        spmm_push_pending_mask <= {PE_LANES{1'b1}};
                        state      <= S_EMIT;
                    end
                end

                S_EMIT: begin
                    spmm_push_pending_mask <= spmm_push_pending_next;

                    if (spmm_push_done_after) begin
                        spmm_push_pending_mask <= {PE_LANES{1'b0}};
                        row_emitted_any <= row_emitted_any | ~emit_dummy;

                        if (emit_eor) begin
                            scan_k <= cur_k + 1'b1;
                            state  <= S_SCAN;
                        end else if (ser_idx == 7'd63) begin
                            chunk_ptr <= chunk_ptr + 1'b1;
                            state     <= S_VAL_REQ;
                        end else begin
                            ser_idx <= ser_idx + 1'b1;
                            state   <= S_SER;
                        end
                    end
                end

                S_BLOCK_DONE: begin
                    if (b_block_done_ready) begin
                        k_bitmap <= {K_MAX{1'b0}};
                        if (block_last_r)
                            state <= S_DONE;
                        else
                            state <= S_COLLECT;
                    end
                end

                // ADD/SUB path: no row pointer ROM and no row reordering.  The
                // B compact-CSV stream is consumed sequentially from B_val_rom.
                S_ADD_INIT: begin
                    add_push_pending_mask <= {PE_LANES{1'b0}};
                    if (cfg_m == {ROW_W{1'b0}}) begin
                        state <= S_DONE;
                    end else if (add_group_base >= cfg_m) begin
                        state <= S_DONE;
                    end else begin
                        add_lane_active <= add_valid_lane_mask;
                        state           <= S_ADD_VAL_REQ;
                    end
                end

                S_ADD_VAL_REQ: begin
                    if(add_vec_ptr>=cfg_b_chunk_count) begin error_bad_k<=1;state<=S_DONE;end
                    else begin
                        b_val_en<=1; b_val_addr<=add_vec_ptr[B_ADDR_W-1:0];state<=S_ADD_VAL_WAIT;
                    end
                end

                S_ADD_VAL_WAIT: begin
                    state <= S_ADD_VAL_LATCH;
                end

                S_ADD_VAL_LATCH: begin
                    add_vec_buf           <= b_val_dout;
                    add_push_pending_mask <= add_lane_active;
                    state                 <= S_ADD_PUSH;
                end

                S_ADD_PUSH: begin
                    add_push_pending_mask <= add_push_pending_next;

                    if (add_push_done_after) begin
                        add_push_pending_mask <= {PE_LANES{1'b0}};
                        add_lane_active      <= add_lane_after;
                        add_vec_ptr          <= add_vec_ptr + 1'b1;

                        if (add_group_done_after)
                            state <= S_ADD_WAIT_GRP;
                        else
                            state <= S_ADD_VAL_REQ;
                    end
                end

                S_ADD_WAIT_GRP: begin
                    if (store_group_ready) begin
                        if (add_last_group_after) begin
                            state <= S_DONE;
                        end else begin
                            add_group_idx <= add_group_idx + 1'b1;
                            state         <= S_ADD_INIT;
                        end
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    state <= S_DONE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

`ifdef SPMM_LOADER_DEBUG
    function automatic integer dbg_popcount64;
        input [PE_LANES-1:0] v;
        integer di;
        begin
            dbg_popcount64 = 0;
            for (di = 0; di < PE_LANES; di = di + 1) begin
                if (v[di]) dbg_popcount64 = dbg_popcount64 + 1;
            end
        end
    endfunction

    function automatic [127:0] dbg_state_name;
        input [4:0] s;
        begin
            case (s)
                S_IDLE:          dbg_state_name = "IDLE";
                S_COLLECT:       dbg_state_name = "COLLECT";
                S_KPROC:         dbg_state_name = "KPROC";
                S_SCAN:          dbg_state_name = "SCAN";
                S_PTR_REQ:       dbg_state_name = "PTR_REQ";
                S_PTR_WAIT:      dbg_state_name = "PTR_WAIT";
                S_PTR_LATCH:     dbg_state_name = "PTR_LATCH";
                S_VAL_REQ:       dbg_state_name = "VAL_REQ";
                S_VAL_WAIT:      dbg_state_name = "VAL_WAIT";
                S_VAL_LATCH:     dbg_state_name = "VAL_LATCH";
                S_SER:           dbg_state_name = "SER";
                S_EMIT:          dbg_state_name = "EMIT";
                S_BLOCK_DONE:    dbg_state_name = "BLOCK_DONE";
                S_ADD_INIT:      dbg_state_name = "ADD_INIT";
                S_ADD_VAL_REQ:   dbg_state_name = "ADD_VAL_REQ";
                S_ADD_VAL_WAIT:  dbg_state_name = "ADD_VAL_WAIT";
                S_ADD_VAL_LATCH: dbg_state_name = "ADD_VAL_LATCH";
                S_ADD_PUSH:      dbg_state_name = "ADD_PUSH";
                S_ADD_WAIT_GRP:  dbg_state_name = "ADD_WAIT_GRP";
                S_DONE:          dbg_state_name = "DONE";
                default:         dbg_state_name = "UNKNOWN";
            endcase
        end
    endfunction

    reg [4:0] dbg_state_q;
    integer dbg_stall_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_state_q   <= S_IDLE;
            dbg_stall_cnt <= 0;
        end else begin
            dbg_state_q <= state;

            if (dbg_state_q != state) begin
                $display("[B_LOADER][%0t] state %0s -> %0s | mode=%0d scan_k=%0d cur_k=%0d chunk_ptr=%0d ser_idx=%0d add_group=%0d add_vec_ptr=%0d add_active=%h pending_spmm=%0d pending_add=%0d b_ready=%h",
                         $time, dbg_state_name(dbg_state_q), dbg_state_name(state),
                         cfg_pe_mode, scan_k, cur_k, chunk_ptr, ser_idx,
                         add_group_idx, add_vec_ptr, add_lane_active,
                         dbg_popcount64(spmm_push_pending_mask),
                         dbg_popcount64(add_push_pending_mask),
                         b_push_ready);
                dbg_stall_cnt <= 0;
            end else begin
                dbg_stall_cnt <= dbg_stall_cnt + 1;

                if ((state == S_EMIT) && (spmm_push_pending_mask != {PE_LANES{1'b0}}) &&
                    ((dbg_stall_cnt % 200) == 199)) begin
                    $display("[B_LOADER][%0t][STALL] S_EMIT cur_k=%0d emit_col=%0d eor=%0b dummy=%0b pending=%h ready=%h not_ready=%h",
                             $time, emit_k, emit_col, emit_eor, emit_dummy,
                             spmm_push_pending_mask, b_push_ready,
                             spmm_push_pending_mask & ~b_push_ready);
                end

                if ((state == S_ADD_PUSH) && (add_push_pending_mask != {PE_LANES{1'b0}}) &&
                    ((dbg_stall_cnt % 200) == 199)) begin
                    $display("[B_LOADER][%0t][STALL] S_ADD_PUSH group=%0d vec_ptr=%0d active=%h eor=%h pending=%h ready=%h not_ready=%h",
                             $time, add_group_idx, add_vec_ptr,
                             add_lane_active, add_eor_mask,
                             add_push_pending_mask, b_push_ready,
                             add_push_pending_mask & ~b_push_ready);
                end

                if ((state == S_ADD_WAIT_GRP) && ((dbg_stall_cnt % 200) == 199)) begin
                    $display("[B_LOADER][%0t][STALL] S_ADD_WAIT_GRP group=%0d store_group_ready=%0b last=%0b next_base=%0d",
                             $time, add_group_idx, store_group_ready,
                             add_last_group_after, add_group_base + ROW_GROUP_SIZE);
                end
            end
        end
    end
`endif

endmodule

`default_nettype wire
