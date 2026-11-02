// -----------------------------------------------------------------------------
// Shared RTL parameters and payload layouts.
// Default capacities cover the supplied 28-case suite; larger inputs require
// explicit capacity/profile changes and new synthesis/validation evidence.
//
// The architecture uses 64 PE lanes and a unified FIFO payload boundary between
// loaders and PE.  SpMM and matrix ADD/SUB share the same 66x32-bit compact
// vector physical format; the mode selects how the index fields are interpreted.
// -----------------------------------------------------------------------------
`ifndef SPMM_LOADER_DEFS_SVH
`define SPMM_LOADER_DEFS_SVH

`define SPMM_PE_LANES          64
`define SPMM_M_MAX             64
`define SPMM_N_MAX             64
`define SPMM_K_MAX             512

`define SPMM_WORD_W            32
`define SPMM_ROW_W             16
`define SPMM_COL_W             16
`define SPMM_K_W               16
`define SPMM_VAL_W             16
`define SPMM_PTR_W             32
`define SPMM_PTR_INDEX_W       16

`define SPMM_FP16_ZERO         16'h0000
`define SPMM_COL_SENTINEL      16'hffff

`define SPMM_PE_MODE_SPMM      2'd0
`define SPMM_PE_MODE_MAT_ADD   2'd1
`define SPMM_PE_MODE_MAT_SUB   2'd2

// 66 x 32-bit compact vector / wide B chunk.
// A / ADD-SUB B CSV:
//   word0 = eor_mask[31:0]
//   word1 = eor_mask[63:32]
//   word2+i = {idx_or_col[15:0], val[15:0]}
// SPMM B chunk:
//   word0/1 reserved, word2+i = {b_col[15:0], b_val[15:0]}
`define SPMM_VEC_EOR_WORDS     2
`define SPMM_A_VEC_WORDS       (`SPMM_VEC_EOR_WORDS + `SPMM_PE_LANES)
`define SPMM_A_VEC_W           (`SPMM_WORD_W * `SPMM_A_VEC_WORDS)
`define SPMM_B_PACK_WORDS      (`SPMM_VEC_EOR_WORDS + `SPMM_PE_LANES)
`define SPMM_B_PACK_W          (`SPMM_WORD_W * `SPMM_B_PACK_WORDS)
`define SPMM_LANE_ENTRY_W      32

`define SPMM_A_VEC_ADDR_W      9
`define SPMM_A_VEC_DEPTH       512
`define SPMM_GROUP_W           3
`define SPMM_GROUPS_MAX        8
`define SPMM_BLOCK_VECS_DFLT   8

`define SPMM_B_PTR_ADDR_W      10
`define SPMM_B_PTR_DEPTH       1024
`define SPMM_B_VAL_ADDR_W      9
`define SPMM_B_VAL_DEPTH       512
`define SPMM_B_ENTRY_W         (`SPMM_COL_W + `SPMM_VAL_W)

`define SPMM_C_ADDR_W          12
`define SPMM_C_DEPTH           (`SPMM_M_MAX * `SPMM_N_MAX)

`define SPMM_FIFO_DEPTH_DFLT   32
`define SPMM_FIFO_ADDR_W_DFLT  5

`define SPMM_PE_BUF_DEPTH      64
`define SPMM_PE_BUF_ADDR_W     6
`define SPMM_PE_META_DEPTH     64
`define SPMM_PE_META_ADDR_W    6

// A FIFO payload from A_loader to PE:
//   {dummy, eor, idx, val}
// In SpMM mode idx is k_idx; in ADD/SUB mode idx is col_idx.
`define SPMM_A_FIFO_W          (1 + 1 + `SPMM_K_W + `SPMM_VAL_W)

// B FIFO payload from B_loader to PE:
//   {dummy, eor, k_idx, col_idx, val}
// In SpMM mode k_idx is the B row index.  In ADD/SUB mode k_idx is unused.
`define SPMM_B_LANE_FIFO_W     (1 + 1 + `SPMM_K_W + `SPMM_COL_W + `SPMM_VAL_W)

// PE result carries {col,val}; top.sv supplies the row id through lane mapping.
`define SPMM_RESULT_W          (`SPMM_COL_W + `SPMM_VAL_W)

`define SPMM_A_VEC_INIT_FILE   "a_compact_vec.hex"
`define SPMM_A_ROW_INIT_FILE   "a_row_order.hex"
`define SPMM_B_PTR_INIT_FILE   "b_row_ptr.hex"
`define SPMM_B_VAL_INIT_FILE   "b_val_pack.hex"
`define SPMM_C_INIT_FILE       ""

`endif
