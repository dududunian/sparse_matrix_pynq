`timescale 1ns/1ps
`default_nettype none

`include "spmm_loader_defs.svh"

// -----------------------------------------------------------------------------
// A stream loader.
//
// Boundary:
//   - reads one 66-word compact A vector from A_vec_rom;
//   - pushes one decoded entry into each active lane FIFO;
//   - in SpMM mode, reports the vector k-list to B_loader and marks block
//     boundaries with a_block_done.
//
// SpMM uses row_order outside this module.  A_loader only advances through the
// compact-vector stream and groups vectors into cfg_block_vecs-sized blocks.
// ADD/SUB uses the same vector format with lane-local column indices and does
// not generate k_update/a_block_done traffic.
// -----------------------------------------------------------------------------
module A_loader #(
    parameter integer PE_LANES    = `SPMM_PE_LANES,
    parameter integer K_W         = `SPMM_K_W,
    parameter integer VAL_W       = `SPMM_VAL_W,
    parameter integer ROW_W       = `SPMM_ROW_W,
    parameter integer A_VEC_WORDS = `SPMM_A_VEC_WORDS,
    parameter integer A_VEC_W     = `SPMM_A_VEC_W,
    parameter integer A_ADDR_W    = `SPMM_A_VEC_ADDR_W,
    parameter integer GROUP_W     = `SPMM_GROUP_W,
    parameter integer A_DEPTH     = `SPMM_A_VEC_DEPTH
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,

    input  wire [1:0]                   cfg_pe_mode,
    input  wire [ROW_W-1:0]             cfg_m,
    input  wire [A_ADDR_W:0]            cfg_a_vec_count,
    input  wire [15:0]                  cfg_block_vecs,
    input  wire                         store_group_ready,
    input  wire                         spmm_block_retired,

    output wire                         busy,
    output reg                          done,
    output reg                          error_vec_overrun,

    output reg                          a_vec_en,
    output reg  [A_ADDR_W-1:0]          a_vec_addr,
    input  wire [A_VEC_W-1:0]           a_vec_data,

    output reg  [GROUP_W-1:0]           row_group_idx,

    output wire [PE_LANES-1:0]          a_push_valid,
    input  wire [PE_LANES-1:0]          a_push_ready,
    output wire [PE_LANES*K_W-1:0]      a_push_idx_bus,
    output wire [PE_LANES*VAL_W-1:0]    a_push_val_bus,
    output wire [PE_LANES-1:0]          a_push_eor,
    output wire [PE_LANES-1:0]          a_push_dummy,

    output wire                         k_update_valid,
    input  wire                         k_update_ready,
    output wire [PE_LANES-1:0]          k_update_mask,
    output wire [PE_LANES*K_W-1:0]      k_update_bus,

    output wire                         a_block_done_valid,
    input  wire                         a_block_done_ready,
    output wire                         a_block_done_last
);

    localparam [3:0]
        S_IDLE       = 4'd0,
        S_INIT_GROUP = 4'd1,
        S_READ_REQ   = 4'd2,
        S_READ_WAIT  = 4'd3,
        S_READ_LATCH = 4'd4,
        S_PUSH       = 4'd5,
        S_BLOCK_DONE = 4'd6,
        S_WAIT_GROUP = 4'd7,
        S_DONE       = 4'd8,
        S_WAIT_BLOCK = 4'd9;

    wire spmm_mode = (cfg_pe_mode == `SPMM_PE_MODE_SPMM);
    wire mat_mode  = (cfg_pe_mode == `SPMM_PE_MODE_MAT_ADD) ||
                     (cfg_pe_mode == `SPMM_PE_MODE_MAT_SUB);

    reg [3:0] state;
    reg       start_d;
    wire      start_pulse = start & ~start_d;

    reg [A_ADDR_W:0]   vec_ptr;
    reg [15:0]         block_vec_count;
    reg [PE_LANES-1:0] lane_active;
    reg [A_VEC_W-1:0]  vec_buf;

    reg [PE_LANES-1:0] push_pending_mask;
    reg                k_update_pending;

    reg block_group_done_r;
    reg block_final_vec_r;
    reg block_last_r;
    reg wait_last_group;

    localparam [ROW_W-1:0] ROWS_PER_GROUP = {{(ROW_W-7){1'b0}}, 7'd64};

    wire [PE_LANES-1:0] eor_mask = vec_buf[PE_LANES-1:0];

    wire [ROW_W-1:0] group_base =
        ({{(ROW_W-GROUP_W){1'b0}}, row_group_idx} << 6);

    reg [PE_LANES-1:0] valid_lane_mask;
    integer vi;
    always @(*) begin
        // Mask off lanes beyond cfg_m in the final 64-row group.
        // Active lanes still receive dummy/EOR entries so PE and Store observe a clean group boundary.
        valid_lane_mask = {PE_LANES{1'b0}};
        for (vi = 0; vi < PE_LANES; vi = vi + 1) begin
            if ((group_base + vi[ROW_W-1:0]) < cfg_m)
                valid_lane_mask[vi] = 1'b1;
        end
    end

    wire [PE_LANES-1:0] active_eor_mask =
        lane_active & eor_mask;

    wire [PE_LANES-1:0] lane_active_after_push =
        lane_active & ~active_eor_mask;

    wire group_done_after_push =
        (lane_active_after_push == {PE_LANES{1'b0}});

    wire last_vec_after_push =
        ((vec_ptr + {{A_ADDR_W{1'b0}}, 1'b1}) >= cfg_a_vec_count);

    wire block_limit_after_push =
        ((block_vec_count + 16'd1) >= cfg_block_vecs);

    wire spmm_block_end_after_push =
        spmm_mode && (block_limit_after_push || group_done_after_push || last_vec_after_push);

    wire last_group_after_push =
        ((group_base + ROWS_PER_GROUP) >= cfg_m) || last_vec_after_push;

    // SpMM ordering rule: B_loader must see the current vector k-list before any lane consumes the matching A entries.
    // This keeps A/B FIFO traffic aligned at block boundaries.
    wire allow_lane_push =
        mat_mode || (!k_update_pending) || k_update_ready;

    wire [PE_LANES-1:0] push_fire_mask =
        ((state == S_PUSH) && allow_lane_push) ?
        (push_pending_mask & a_push_ready) :
        {PE_LANES{1'b0}};

    wire [PE_LANES-1:0] push_pending_next =
        push_pending_mask & ~push_fire_mask;

    wire push_done_after_fire =
        (push_pending_next == {PE_LANES{1'b0}});

    wire k_update_fire =
        k_update_valid && k_update_ready;

    wire k_update_done_after =
        mat_mode || (!k_update_pending) || k_update_fire;

    wire current_vec_done =
        (state == S_PUSH) && push_done_after_fire && k_update_done_after;

    assign busy = (state != S_IDLE) && (state != S_DONE);

    assign a_block_done_valid = spmm_mode && (state == S_BLOCK_DONE);
    assign a_block_done_last  = block_last_r;

    assign k_update_valid = spmm_mode && (state == S_PUSH) && k_update_pending;

    genvar g;
    generate
        for (g = 0; g < PE_LANES; g = g + 1) begin : GEN_DECODE_A
            wire [31:0] lane_word;
            assign lane_word = vec_buf[(2+g)*32 +: 32];

            assign a_push_valid[g] =
                (state == S_PUSH) && push_pending_mask[g] && allow_lane_push;

            // The high halfword is mode-dependent: k_idx for SpMM and col_idx for matrix ADD/SUB.
            assign a_push_idx_bus[g*K_W +: K_W] =
                lane_word[31:16];

            assign a_push_val_bus[g*VAL_W +: VAL_W] =
                lane_word[15:0];

            assign a_push_eor[g] =
                eor_mask[g] & push_pending_mask[g];

            assign a_push_dummy[g] =
                push_pending_mask[g] && (lane_word == 32'h0000_0000);

            assign k_update_mask[g] =
                spmm_mode && lane_active[g] && (lane_word != 32'h0000_0000);

            assign k_update_bus[g*K_W +: K_W] =
                lane_word[31:16];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            start_d            <= 1'b0;
            done               <= 1'b0;
            error_vec_overrun  <= 1'b0;

            a_vec_en           <= 1'b0;
            a_vec_addr         <= {A_ADDR_W{1'b0}};

            vec_ptr            <= {(A_ADDR_W+1){1'b0}};
            block_vec_count    <= 16'd0;
            lane_active        <= {PE_LANES{1'b0}};
            vec_buf            <= {A_VEC_W{1'b0}};
            push_pending_mask  <= {PE_LANES{1'b0}};
            k_update_pending   <= 1'b0;

            row_group_idx      <= {GROUP_W{1'b0}};
            block_group_done_r <= 1'b0;
            block_final_vec_r  <= 1'b0;
            block_last_r       <= 1'b0;
            wait_last_group    <= 1'b0;
        end else begin
            start_d  <= start;
            a_vec_en <= 1'b0;

            case (state)
                S_IDLE: begin
                    done              <= 1'b0;
                    error_vec_overrun <= 1'b0;
                    push_pending_mask <= {PE_LANES{1'b0}};
                    k_update_pending  <= 1'b0;

                    if (start_pulse) begin
                        vec_ptr            <= {(A_ADDR_W+1){1'b0}};
                        row_group_idx      <= {GROUP_W{1'b0}};
                        block_vec_count    <= 16'd0;
                        lane_active        <= {PE_LANES{1'b0}};
                        block_group_done_r <= 1'b0;
                        block_final_vec_r  <= 1'b0;
                        block_last_r       <= 1'b0;
                        wait_last_group    <= 1'b0;
                        state              <= S_INIT_GROUP;
                    end
                end

                S_INIT_GROUP: begin
                    block_vec_count   <= 16'd0;
                    push_pending_mask <= {PE_LANES{1'b0}};
                    k_update_pending  <= 1'b0;
                    lane_active       <= valid_lane_mask;

                    if ((cfg_m == {ROW_W{1'b0}}) ||
                        (vec_ptr >= cfg_a_vec_count) ||
                        (valid_lane_mask == {PE_LANES{1'b0}})) begin
                        error_vec_overrun <= 1;
                        state <= S_DONE;
                    end else begin
                        state <= S_READ_REQ;
                    end
                end

                S_READ_REQ: begin
                    push_pending_mask <= {PE_LANES{1'b0}};
                    k_update_pending  <= 1'b0;

                    if (vec_ptr >= cfg_a_vec_count || vec_ptr>=A_DEPTH) begin
                        error_vec_overrun <= 1;
                        state <= S_DONE;
                    end else begin
                        a_vec_en   <= 1'b1;
                        a_vec_addr <= vec_ptr[A_ADDR_W-1:0];
                        state      <= S_READ_WAIT;
                    end
                end

                // A_vec_rom is synchronous and this loader registers the read request.
                // WAIT absorbs the ROM latency; LATCH captures dout.
                S_READ_WAIT: begin
                    state <= S_READ_LATCH;
                end

                S_READ_LATCH: begin
                    vec_buf           <= a_vec_data;
                    push_pending_mask <= lane_active;
                    // k_update is a vector-level sideband transaction.
                    // Lane handshakes may complete at different cycles, but the sideband is issued once per compact vector.
                    k_update_pending  <= spmm_mode;
                    state             <= S_PUSH;
                end

                S_PUSH: begin
                    // push_pending_mask turns the per-lane ready/valid bus into
                    // an exactly-once delivery contract for the current vector.
                    push_pending_mask <= push_pending_next;

                    if (k_update_fire)
                        k_update_pending <= 1'b0;

                    if (current_vec_done) begin
                        vec_ptr         <= vec_ptr + {{A_ADDR_W{1'b0}}, 1'b1};
                        lane_active     <= lane_active_after_push;
                        block_vec_count <= block_vec_count + 16'd1;

                        push_pending_mask <= {PE_LANES{1'b0}};
                        k_update_pending  <= 1'b0;

                        if(last_vec_after_push && (!group_done_after_push || ((group_base+ROWS_PER_GROUP)<cfg_m))) begin
                            error_vec_overrun<=1;
                            state<=S_DONE;
                        end else if (spmm_block_end_after_push) begin
                            block_group_done_r <= group_done_after_push;
                            block_final_vec_r  <= last_vec_after_push;
                            block_last_r       <= group_done_after_push && last_group_after_push;
                            wait_last_group    <= group_done_after_push && last_group_after_push;
                            state              <= S_BLOCK_DONE;
                        end else if (mat_mode && group_done_after_push) begin
                            wait_last_group <= last_group_after_push;
                            state           <= S_WAIT_GROUP;
                        end else begin
                            state <= S_READ_REQ;
                        end
                    end
                end

                S_BLOCK_DONE: begin
                    if (a_block_done_ready) begin
                        block_vec_count <= 16'd0;
                        // B has accepted the k-list, not finished replaying it.
                        // Keep next-block A entries out of the PE FIFOs until
                        // the current B replay and all in-flight work drain.
                        state <= S_WAIT_BLOCK;
                    end
                end

                S_WAIT_BLOCK: begin
                    if (spmm_block_retired) begin
                        if (block_group_done_r || block_final_vec_r)
                            state <= S_WAIT_GROUP;
                        else
                            state <= S_READ_REQ;
                    end
                end

                S_WAIT_GROUP: begin
                    if (store_group_ready) begin
                        if (wait_last_group) begin
                            state <= S_DONE;
                        end else begin
                            row_group_idx   <= row_group_idx + {{(GROUP_W-1){1'b0}}, 1'b1};
                            wait_last_group <= 1'b0;
                            state           <= S_INIT_GROUP;
                        end
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
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
        input [3:0] s;
        begin
            case (s)
                S_IDLE:       dbg_state_name = "IDLE";
                S_INIT_GROUP: dbg_state_name = "INIT_GROUP";
                S_READ_REQ:   dbg_state_name = "READ_REQ";
                S_READ_WAIT:  dbg_state_name = "READ_WAIT";
                S_READ_LATCH: dbg_state_name = "READ_LATCH";
                S_PUSH:       dbg_state_name = "PUSH";
                S_BLOCK_DONE: dbg_state_name = "BLOCK_DONE";
                S_WAIT_GROUP: dbg_state_name = "WAIT_GROUP";
                S_DONE:       dbg_state_name = "DONE";
                S_WAIT_BLOCK: dbg_state_name = "WAIT_BLOCK";
                default:      dbg_state_name = "UNKNOWN";
            endcase
        end
    endfunction

    reg [3:0] dbg_state_q;
    integer dbg_stall_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_state_q   <= S_IDLE;
            dbg_stall_cnt <= 0;
        end else begin
            dbg_state_q <= state;

            if (dbg_state_q != state) begin
                $display("[A_LOADER][%0t] state %0s -> %0s | mode=%0d vec_ptr=%0d block_vec=%0d row_group=%0d lane_active=%h push_pending=%h kpend=%0b k_v=%0b k_r=%0b blk_v=%0b blk_r=%0b store_ready=%0b",
                         $time, dbg_state_name(dbg_state_q), dbg_state_name(state),
                         cfg_pe_mode, vec_ptr, block_vec_count, row_group_idx,
                         lane_active, push_pending_mask, k_update_pending,
                         k_update_valid, k_update_ready,
                         a_block_done_valid, a_block_done_ready,
                         store_group_ready);
                dbg_stall_cnt <= 0;
            end else begin
                dbg_stall_cnt <= dbg_stall_cnt + 1;

                if ((state == S_PUSH) && (dbg_stall_cnt % 200 == 199)) begin
                    $display("[A_LOADER][%0t][STALL] S_PUSH mode=%0d vec_ptr=%0d allow_push=%0b pending=%h ready=%h not_ready=%h kpend=%0b k_ready=%0b k_mask=%h eor=%h",
                             $time, cfg_pe_mode, vec_ptr, allow_lane_push,
                             push_pending_mask, a_push_ready,
                             push_pending_mask & ~a_push_ready,
                             k_update_pending, k_update_ready, k_update_mask, eor_mask);
                end

                if ((state == S_BLOCK_DONE) && (dbg_stall_cnt % 200 == 199)) begin
                    $display("[A_LOADER][%0t][STALL] S_BLOCK_DONE last=%0b group_done=%0b final_vec=%0b a_blk_ready=%0b",
                             $time, block_last_r, block_group_done_r,
                             block_final_vec_r, a_block_done_ready);
                end

                if ((state == S_WAIT_GROUP) && (dbg_stall_cnt % 200 == 199)) begin
                    $display("[A_LOADER][%0t][STALL] S_WAIT_GROUP wait_last=%0b store_group_ready=%0b row_group=%0d",
                             $time, wait_last_group, store_group_ready, row_group_idx);
                end
            end

            if (k_update_fire) begin
                $display("[A_LOADER][%0t] k_update_fire vec_ptr=%0d mask=%h k0=%0d k1=%0d k2=%0d k3=%0d",
                         $time, vec_ptr, k_update_mask,
                         k_update_bus[0*K_W +: K_W], k_update_bus[1*K_W +: K_W],
                         k_update_bus[2*K_W +: K_W], k_update_bus[3*K_W +: K_W]);
            end

            if (current_vec_done) begin
                $display("[A_LOADER][%0t] vec_done mode=%0d vec_ptr=%0d next_vec=%0d group_done=%0b block_end=%0b last_vec=%0b lane_after=%h",
                         $time, cfg_pe_mode, vec_ptr,
                         vec_ptr + {{A_ADDR_W{1'b0}}, 1'b1},
                         group_done_after_push, spmm_block_end_after_push,
                         last_vec_after_push, lane_active_after_push);
            end
        end
    end
`endif

endmodule

`default_nettype wire
