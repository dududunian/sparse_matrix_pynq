#!/usr/bin/env python3
"""
Generate compact-CSV testcases for the SystemVerilog SpMM / matrix ADD-SUB PE.

The generator owns the software-side contract for RTL initialization files:
matrix rows are converted to 64-lane compact vectors, pointer/value ROM images
are emitted with stable filenames, and case.json records the configuration used
by simulation, checking and visualization tools.

Generated files under testcase/<case>/ by default:
  - a_row_order.hex
  - a_vec.hex
  - b_chunk_ptr.hex
  - b_val.hex
  - golden_c.hex
  - case.json
  - aliases:
      a_compact_vec.hex
      b_row_ptr.hex
      b_val_pack.hex

Typical usage:
  python3 tools/gen_matrix.py --case add128 --mode add --M 128 --N 128 --K 128 --W 8 --pattern random
  python3 tools/gen_matrix.py --case spmm_brow --mode spmm --M 128 --N 256 --K 128 --W 8 --pattern b_row_nnz --b-row-nnz 0:0,1:64,2:65,3:128,4:129
  python3 tools/gen_matrix.py --suite pressure
  python3 tools/gen_matrix.py --suite-list pressure
"""

from __future__ import annotations

import argparse
import json
import math
import random
import shutil
import struct
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

PE_LANES = 64
WORD_W = 32
VEC_WORDS = 66
VEC_HEX_DIGITS = VEC_WORDS * 8
FP16_ZERO = "0000"

Entry = Tuple[int, str]  # (column/k index, fp16 hex string)
Rows = List[List[Entry]]


# -----------------------------------------------------------------------------
# FP16 helpers.
# -----------------------------------------------------------------------------

def f16_to_hex(value: float) -> str:
    """Round Python float to IEEE-754 binary16 and return four hex digits."""
    try:
        raw = struct.pack(">e", float(value))
    except OverflowError:
        raw = struct.pack(">e", math.copysign(65504.0, float(value)))
    return raw.hex().upper()


def normalize_hex_word(s: str, digits: Optional[int] = None) -> str:
    s = str(s).strip()
    if s.lower().startswith("0x"):
        s = s[2:]
    s = s.replace("_", "")
    if not s:
        s = "0"
    value = int(s, 16)
    if digits is None:
        return f"{value:X}"
    mask = (1 << (4 * digits)) - 1
    return f"{value & mask:0{digits}X}"


def hex_to_f16(hex4: str) -> float:
    hex4 = normalize_hex_word(hex4, 4)
    return float(struct.unpack(">e", bytes.fromhex(hex4))[0])


def f16_add_hex(a_hex: str, b_hex: str) -> str:
    return f16_to_hex(hex_to_f16(a_hex) + hex_to_f16(b_hex))


def f16_sub_hex(a_hex: str, b_hex: str) -> str:
    return f16_to_hex(hex_to_f16(a_hex) - hex_to_f16(b_hex))


def f16_mul_hex(a_hex: str, b_hex: str) -> str:
    return f16_to_hex(hex_to_f16(a_hex) * hex_to_f16(b_hex))


def f16_neg_hex(a_hex: str) -> str:
    word = int(normalize_hex_word(a_hex, 4), 16) ^ 0x8000
    return f"{word:04X}"


def val_for(row: int, col: int, scale: float = 1.0) -> str:
    """Deterministic nonzero FP16 value used by named stress patterns."""
    base = [0.5, 1.0, 1.5, 2.0, -0.5, -1.0, -1.5, -2.0]
    return f16_to_hex(base[(row * 7 + col * 3) % len(base)] * scale)


def nonzero_random_value(rng: random.Random) -> str:
    return f16_to_hex(rng.choice([-2.0, -1.5, -1.0, -0.5, 0.5, 1.0, 1.5, 2.0]))


# -----------------------------------------------------------------------------
# Packing helpers.
# -----------------------------------------------------------------------------

def pack_words_32(words: Sequence[int]) -> str:
    """Pack word0 at low bits, word65 at high bits; return high-to-low hex."""
    if len(words) != VEC_WORDS:
        raise ValueError(f"Expected {VEC_WORDS} 32-bit words, got {len(words)}")
    value = 0
    for i, word in enumerate(words):
        if word < 0 or word > 0xFFFFFFFF:
            raise ValueError(f"word[{i}] out of range: {word}")
        value |= int(word) << (32 * i)
    return f"{value:0{VEC_HEX_DIGITS}X}"


def entry_word(index: int, val_hex: str) -> int:
    return ((int(index) & 0xFFFF) << 16) | int(normalize_hex_word(val_hex, 4), 16)


def write_lines(path: Path, lines: Iterable[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for line in lines:
            f.write(str(line).strip() + "\n")


def copy_alias(src: Path, dst: Path) -> None:
    if src.resolve() != dst.resolve():
        shutil.copyfile(src, dst)


# -----------------------------------------------------------------------------
# Sparse row construction.
# -----------------------------------------------------------------------------

def sorted_unique_entries(entries: Iterable[Entry]) -> List[Entry]:
    d: Dict[int, str] = {}
    for c, h in entries:
        if h != FP16_ZERO:
            d[int(c)] = normalize_hex_word(h, 4)
    return sorted(d.items(), key=lambda x: x[0])


def random_sparse_rows(num_rows: int, num_cols: int, density: float, rng: random.Random,
                       ensure_some: bool = False, max_nnz_per_row: Optional[int] = None) -> Rows:
    """Scalable random sparse rows. Does not scan all columns for sparse cases."""
    density = max(0.0, min(1.0, float(density)))
    rows: Rows = []
    avg = density * num_cols
    for r in range(num_rows):
        if density == 0.0 or num_cols == 0:
            nnz = 0
        elif density >= 0.35 and num_cols <= 4096:
            cols = [c for c in range(num_cols) if rng.random() < density]
            nnz = len(cols)
            if max_nnz_per_row is not None:
                cols = cols[:max_nnz_per_row]
            rows.append(sorted_unique_entries((c, nonzero_random_value(rng)) for c in cols))
            continue
        else:
            lo = max(0, int(avg * 0.5))
            hi = max(lo, int(avg * 1.5) + 1)
            nnz = rng.randint(lo, hi)
        if ensure_some and num_cols > 0:
            nnz = max(1, nnz)
        if max_nnz_per_row is not None:
            nnz = min(nnz, max_nnz_per_row)
        nnz = min(num_cols, nnz)
        cols = sorted(rng.sample(range(num_cols), nnz)) if nnz > 0 else []
        rows.append(sorted_unique_entries((c, nonzero_random_value(rng)) for c in cols))
    return rows


def zero_rows(num_rows: int) -> Rows:
    return [[] for _ in range(num_rows)]


def diagonal_rows(num_rows: int, num_cols: int, identity: bool = False, scale: float = 1.0) -> Rows:
    rows: Rows = []
    for r in range(num_rows):
        if r < num_cols:
            v = f16_to_hex(1.0 if identity else scale * (1.0 + (r % 4) * 0.5))
            rows.append([(r, v)])
        else:
            rows.append([])
    return rows


def fixed_cols_rows(num_rows: int, num_cols: int, cols: Sequence[int], scale: float = 1.0) -> Rows:
    valid_cols = [c for c in cols if 0 <= c < num_cols]
    rows: Rows = []
    for r in range(num_rows):
        rows.append(sorted_unique_entries((c, val_for(r, c, scale)) for c in valid_cols))
    return rows


def patterned_rows(num_rows: int, num_cols: int, nnz_per_row: int, offset: int = 0,
                   stride: int = 7, scale: float = 1.0) -> Rows:
    rows: Rows = []
    if num_cols <= 0:
        return zero_rows(num_rows)
    for r in range(num_rows):
        cols: List[int] = []
        start = (offset + r * stride) % num_cols
        step = max(1, num_cols // max(1, nnz_per_row))
        x = start
        while len(cols) < min(nnz_per_row, num_cols):
            if x not in cols:
                cols.append(x)
            x = (x + step) % num_cols
        rows.append(sorted_unique_entries((c, val_for(r, c, scale)) for c in cols))
    return rows


def apply_empty_rows(rows: Rows, every: int = 5, first: int = 0) -> None:
    if every <= 0:
        return
    for r in range(first, len(rows), every):
        rows[r] = []


def make_spmm_matrices(args: argparse.Namespace, rng: random.Random) -> Tuple[Rows, Rows]:
    M, N, K = args.M, args.N, args.K
    p = args.pattern

    if p in ("zero", "all_zero"):
        return zero_rows(M), zero_rows(K)

    if p in ("identity", "unit"):
        return diagonal_rows(M, K, identity=True), diagonal_rows(K, N, identity=True)

    if p == "diagonal":
        return diagonal_rows(M, K, identity=False, scale=1.0), diagonal_rows(K, N, identity=False, scale=1.0)

    if p == "a_diag":
        return diagonal_rows(M, K, identity=False, scale=1.0), random_sparse_rows(K, N, args.density_b, rng, args.ensure_some)

    if p == "b_diag":
        return random_sparse_rows(M, K, args.density_a, rng, args.ensure_some), diagonal_rows(K, N, identity=False, scale=1.0)

    if p in ("empty_rows", "a_empty_rows"):
        a = random_sparse_rows(M, K, args.density_a, rng, ensure_some=True)
        b = random_sparse_rows(K, N, args.density_b, rng, ensure_some=True)
        apply_empty_rows(a, every=max(2, args.empty_every), first=0)
        return a, b

    if p == "b_empty_rows":
        a = random_sparse_rows(M, K, args.density_a, rng, ensure_some=True)
        b = random_sparse_rows(K, N, args.density_b, rng, ensure_some=True)
        apply_empty_rows(b, every=max(2, args.empty_every), first=0)
        return a, b

    if p == "b_row_nnz":
        # Exercise B row chunk boundaries such as 0, 64, 65 and 128 entries.
        spec = parse_row_nnz_spec(args.b_row_nnz) or {0: 0, 1: 64, 2: 65, 3: 128, 4: 129}
        b = zero_rows(K)
        for k, count in spec.items():
            if 0 <= k < K:
                cols = list(range(min(count, N)))
                b[k] = [(c, val_for(k, c)) for c in cols]
        keys = sorted([k for k in spec if 0 <= k < K])
        if not keys:
            keys = [0]
        a: Rows = []
        for r in range(M):
            entries = []
            for t, k in enumerate(keys):
                # Keep A nonzero so the selected B rows are actually requested.
                entries.append((k, val_for(r, k)))
            a.append(sorted_unique_entries(entries))
        return a, b

    if p in ("multiblock", "multi_block"):
        # Each row has more A entries than W, and K normally >64, forcing
        # multiple k_update/a_block_done rounds.
        nnz_a = max(args.W + 2, min(K, args.multi_a_nnz))
        a = patterned_rows(M, K, nnz_a, offset=0, stride=3, scale=1.0)
        b = patterned_rows(K, N, max(1, min(args.multi_b_nnz, N)), offset=1, stride=5, scale=1.0)
        return a, b

    if p in ("reorder", "row_reorder"):
        # Build four clusters with similar k sets but scrambled row order.
        clusters = [
            [0, 1, 2, 3],
            [16, 17, 18, 19],
            [32, 33, 34, 35],
            [64, 65, 66, 67],
        ]
        clusters = [[c for c in cs if c < K] for cs in clusters]
        a = []
        order = list(range(M))
        rng.shuffle(order)
        for r in range(M):
            cs = clusters[(r * 3 + 1) % len(clusters)] or [r % K]
            a.append(sorted_unique_entries((c, val_for(r, c)) for c in cs))
        # Scramble rows so row_order has visible effect.
        rng.shuffle(a)
        b = patterned_rows(K, N, max(1, min(args.multi_b_nnz, N)), offset=0, stride=11, scale=1.0)
        return a, b

    if p in ("small", "manual_small"):
        a = zero_rows(M)
        b = zero_rows(K)
        for r in range(M):
            for k in range(min(K, 3)):
                if (r + k) % 2 == 0:
                    a[r].append((k, val_for(r, k)))
        for k in range(K):
            for c in range(min(N, 3)):
                if (k + c) % 2 == 0:
                    b[k].append((c, val_for(k, c)))
        return [sorted_unique_entries(x) for x in a], [sorted_unique_entries(x) for x in b]

    # Random sparse matrices are the baseline when no named pattern is selected.
    return (
        random_sparse_rows(M, K, args.density_a, rng, args.ensure_some, args.max_nnz_a),
        random_sparse_rows(K, N, args.density_b, rng, args.ensure_some, args.max_nnz_b),
    )


def make_addsub_matrices(args: argparse.Namespace, rng: random.Random) -> Tuple[Rows, Rows]:
    M, N = args.M, args.N
    p = args.pattern

    if p in ("zero", "all_zero"):
        return zero_rows(M), zero_rows(M)

    if p in ("identity", "unit"):
        return diagonal_rows(M, N, identity=True), diagonal_rows(M, N, identity=True)

    if p == "diagonal":
        return diagonal_rows(M, N, identity=False, scale=1.0), diagonal_rows(M, N, identity=False, scale=0.5)

    if p == "a_diag":
        return diagonal_rows(M, N, identity=False, scale=1.0), random_sparse_rows(M, N, args.density_b, rng, args.ensure_some)

    if p == "b_diag":
        return random_sparse_rows(M, N, args.density_a, rng, args.ensure_some), diagonal_rows(M, N, identity=False, scale=1.0)

    if p in ("same_cols", "same_columns"):
        cols = list(range(0, min(N, max(1, args.same_cols_n)), max(1, args.same_cols_step)))
        if not cols:
            cols = [0]
        a = fixed_cols_rows(M, N, cols, scale=1.0)
        b = fixed_cols_rows(M, N, cols, scale=0.5)
        return a, b

    if p in ("disjoint_cols", "disjoint_columns"):
        a_cols = list(range(0, min(N, args.disjoint_span), 2))
        b_cols = list(range(1, min(N, args.disjoint_span), 2))
        if not a_cols:
            a_cols = [0] if N > 0 else []
        if not b_cols:
            b_cols = [1] if N > 1 else []
        return fixed_cols_rows(M, N, a_cols, scale=1.0), fixed_cols_rows(M, N, b_cols, scale=1.0)

    if p == "a_empty_rows":
        a = random_sparse_rows(M, N, args.density_a, rng, ensure_some=True)
        b = random_sparse_rows(M, N, args.density_b, rng, ensure_some=True)
        apply_empty_rows(a, every=max(2, args.empty_every), first=0)
        return a, b

    if p == "b_empty_rows":
        a = random_sparse_rows(M, N, args.density_a, rng, ensure_some=True)
        b = random_sparse_rows(M, N, args.density_b, rng, ensure_some=True)
        apply_empty_rows(b, every=max(2, args.empty_every), first=0)
        return a, b

    if p == "b_only":
        return zero_rows(M), patterned_rows(M, N, max(1, args.b_only_nnz), offset=0, stride=5, scale=1.0)

    if p in ("cancel", "sub_cancel"):
        a = patterned_rows(M, N, max(1, args.cancel_nnz), offset=0, stride=3, scale=1.0)
        # Same exact entries; SUB golden should become all zero.
        b = [[(c, h) for c, h in row] for row in a]
        return a, b

    if p in ("partial_group", "partial"):
        return (
            random_sparse_rows(M, N, args.density_a, rng, ensure_some=True),
            random_sparse_rows(M, N, args.density_b, rng, ensure_some=True),
        )

    if p in ("small", "manual_small"):
        a = zero_rows(M)
        b = zero_rows(M)
        for r in range(M):
            for c in range(min(N, 4)):
                if (r + c) % 2 == 0:
                    a[r].append((c, val_for(r, c)))
                if (r + c) % 3 == 0:
                    b[r].append((c, val_for(r, c, scale=0.5)))
        return [sorted_unique_entries(x) for x in a], [sorted_unique_entries(x) for x in b]

    return (
        random_sparse_rows(M, N, args.density_a, rng, args.ensure_some, args.max_nnz_a),
        random_sparse_rows(M, N, args.density_b, rng, args.ensure_some, args.max_nnz_b),
    )


def parse_row_nnz_spec(spec: str) -> Dict[int, int]:
    out: Dict[int, int] = {}
    if not spec:
        return out
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" not in part:
            raise ValueError(f"Bad --b-row-nnz item: {part}, expected k:nnz")
        k, nnz = part.split(":", 1)
        out[int(k)] = int(nnz)
    return out


# -----------------------------------------------------------------------------
# CSV encoders.
# -----------------------------------------------------------------------------

def row_signature(row: List[Entry]) -> Tuple[int, int, int, Tuple[int, ...]]:
    if not row:
        return (0xFFFF, 0xFFFF, 0, ())
    cols = [c for c, _ in row]
    return (
        cols[0],
        cols[1] if len(cols) > 1 else 0xFFFF,
        len(cols),
        tuple(cols[:8]),
    )


def build_row_order(a_rows: Rows, mode: str, lanes: int = PE_LANES) -> List[int]:
    m = len(a_rows)
    padded_m = int(math.ceil(max(1, m) / lanes) * lanes)

    if mode in ("add", "sub"):
        return list(range(m)) + [0] * (padded_m - m)

    # SPMM clusters rows with similar sparse patterns so row_order has a stable
    # and reproducible effect across generated cases.
    real_rows = list(range(m))
    nonempty = [r for r in real_rows if a_rows[r]]
    empty = [r for r in real_rows if not a_rows[r]]
    nonempty.sort(key=lambda r: row_signature(a_rows[r]))
    order = nonempty + empty
    return order + [0] * (padded_m - len(order))


def encode_compact_csv_from_order(rows: Rows, row_order: Sequence[int], m: int,
                                  lanes: int = PE_LANES) -> Tuple[List[str], List[int]]:
    lines: List[str] = []
    group_vec_counts: List[int] = []
    groups = int(math.ceil(max(1, len(row_order)) / lanes))

    for g in range(groups):
        base = g * lanes
        lane_entries: List[List[Entry]] = []
        for p in range(lanes):
            rr = base + p
            if rr < m:
                lane_entries.append(rows[row_order[rr]])
            else:
                lane_entries.append([])

        max_len = max([len(x) for x in lane_entries] + [0])
        vec_count = max(1, max_len)
        group_vec_counts.append(vec_count)

        for t in range(vec_count):
            words = [0] * VEC_WORDS
            eor_mask = 0
            for p, entries in enumerate(lane_entries):
                if t < len(entries):
                    idx, val_hex = entries[t]
                    words[2 + p] = entry_word(idx, val_hex)
                    if t == len(entries) - 1:
                        eor_mask |= (1 << p)
                else:
                    words[2 + p] = 0
                    if len(entries) == 0 and t == 0:
                        eor_mask |= (1 << p)
            words[0] = eor_mask & 0xFFFFFFFF
            words[1] = (eor_mask >> 32) & 0xFFFFFFFF
            lines.append(pack_words_32(words))

    return lines, group_vec_counts


def encode_compact_csv_identity(rows: Rows, lanes: int = PE_LANES) -> Tuple[List[str], List[int]]:
    m = len(rows)
    padded_m = int(math.ceil(max(1, m) / lanes) * lanes)
    order = list(range(m)) + [0] * (padded_m - m)
    return encode_compact_csv_from_order(rows, order, m, lanes)


def encode_b_spmm_chunks(b_rows: Rows, lanes: int = PE_LANES) -> Tuple[List[str], List[int]]:
    lines: List[str] = []
    ptr: List[int] = [0]
    for row in b_rows:
        if row:
            for start in range(0, len(row), lanes):
                words = [0] * VEC_WORDS
                for i, (col, val_hex) in enumerate(row[start:start + lanes]):
                    words[2 + i] = entry_word(col, val_hex)
                lines.append(pack_words_32(words))
        ptr.append(len(lines))
    return lines, ptr


# -----------------------------------------------------------------------------
# Golden model and JSON.
# -----------------------------------------------------------------------------

def rows_to_coo(rows: Rows, limit: Optional[int] = None) -> List[Dict[str, object]]:
    coo: List[Dict[str, object]] = []
    cnt = 0
    for r, row in enumerate(rows):
        for c, h in row:
            if limit is not None and cnt >= limit:
                return coo
            coo.append({"r": r, "c": c, "h": normalize_hex_word(h, 4), "v": hex_to_f16(h)})
            cnt += 1
    return coo


def dense_zero_hex(rows: int, cols: int) -> List[List[str]]:
    return [[FP16_ZERO for _ in range(cols)] for _ in range(rows)]


def build_golden_spmm(a_rows: Rows, b_rows: Rows, m: int, n: int) -> List[List[str]]:
    c = dense_zero_hex(m, n)
    for i in range(m):
        for k, a_hex in a_rows[i]:
            if 0 <= k < len(b_rows):
                for j, b_hex in b_rows[k]:
                    c[i][j] = f16_add_hex(c[i][j], f16_mul_hex(a_hex, b_hex))
    return c


def row_to_dict(row: List[Entry]) -> Dict[int, str]:
    return {c: h for c, h in row}


def build_golden_addsub(a_rows: Rows, b_rows: Rows, m: int, n: int, mode: str) -> List[List[str]]:
    c = dense_zero_hex(m, n)
    for i in range(m):
        ad = row_to_dict(a_rows[i])
        bd = row_to_dict(b_rows[i])
        for col in sorted(set(ad) | set(bd)):
            ah = ad.get(col, FP16_ZERO)
            bh = bd.get(col, FP16_ZERO)
            c[i][col] = f16_add_hex(ah, bh) if mode == "add" else f16_sub_hex(ah, bh)
    return c


def dense_to_hex_lines(mat: List[List[str]]) -> List[str]:
    return [normalize_hex_word(x, 4) for row in mat for x in row]


def dense_to_coo(mat: List[List[str]], limit: Optional[int] = None) -> List[Dict[str, object]]:
    coo: List[Dict[str, object]] = []
    cnt = 0
    for r, row in enumerate(mat):
        for c, h in enumerate(row):
            h = normalize_hex_word(h, 4)
            if h != FP16_ZERO:
                if limit is not None and cnt >= limit:
                    return coo
                coo.append({"r": r, "c": c, "h": h, "v": hex_to_f16(h)})
                cnt += 1
    return coo


def ptr_to_hex_lines(ptr: Sequence[int]) -> List[str]:
    return [f"{int(x) & 0xFFFFFFFF:08X}" for x in ptr]


def row_order_to_hex_lines(order: Sequence[int]) -> List[str]:
    return [f"{int(x) & 0xFFFF:04X}" for x in order]


def generate_one(args: argparse.Namespace) -> Dict[str, object]:
    mode = args.mode.lower()
    rng = random.Random(args.seed)

    outdir = Path(args.outbase) / args.case
    outdir.mkdir(parents=True, exist_ok=True)
    result_dir = Path(args.testbase) / args.case
    result_dir.mkdir(parents=True, exist_ok=True)
    result_path = result_dir / "result.hex"

    if mode == "spmm":
        a_rows, b_rows = make_spmm_matrices(args, rng)
        row_order = build_row_order(a_rows, mode="spmm")
        a_vec_lines, a_group_vec_counts = encode_compact_csv_from_order(a_rows, row_order, args.M)
        b_val_lines, b_ptr = encode_b_spmm_chunks(b_rows)
        golden = build_golden_spmm(a_rows, b_rows, args.M, args.N)
        b_group_vec_counts: List[int] = []
        b_logical = "spmm_row_chunks"
    else:
        a_rows, b_rows = make_addsub_matrices(args, rng)
        row_order = build_row_order(a_rows, mode=mode)
        a_vec_lines, a_group_vec_counts = encode_compact_csv_identity(a_rows)
        b_val_lines, b_group_vec_counts = encode_compact_csv_identity(b_rows)
        # ADD/SUB B_loader reads B_val_rom sequentially.  Pointer aliases remain
        # in the testcase for tool compatibility and file-name consistency.
        b_ptr = [0]
        acc = 0
        for cnt in b_group_vec_counts:
            acc += cnt
            b_ptr.append(acc)
        golden = build_golden_addsub(a_rows, b_rows, args.M, args.N, mode)
        b_logical = "identity_compact_csv"

    a_row_order_path = outdir / "a_row_order.hex"
    a_vec_path = outdir / "a_vec.hex"
    b_ptr_path = outdir / "b_chunk_ptr.hex"
    b_val_path = outdir / "b_val.hex"
    golden_path = outdir / "golden_c.hex"
    case_json_path = outdir / "case.json"

    write_lines(a_row_order_path, row_order_to_hex_lines(row_order))
    write_lines(a_vec_path, a_vec_lines)
    write_lines(b_ptr_path, ptr_to_hex_lines(b_ptr))
    write_lines(b_val_path, b_val_lines)
    write_lines(golden_path, dense_to_hex_lines(golden))

    copy_alias(a_vec_path, outdir / "a_compact_vec.hex")
    copy_alias(b_ptr_path, outdir / "b_row_ptr.hex")
    copy_alias(b_val_path, outdir / "b_val_pack.hex")

    a_nnz = sum(len(r) for r in a_rows)
    b_nnz = sum(len(r) for r in b_rows)
    c_nnz = sum(1 for row in golden for h in row if normalize_hex_word(h, 4) != FP16_ZERO)
    padded_m = int(math.ceil(args.M / PE_LANES) * PE_LANES)
    groups = padded_m // PE_LANES

    coo_limit = None if args.full_json_coo else args.max_json_coo

    case_info = {
        "case": args.case,
        "mode": mode,
        "pattern": args.pattern,
        "M": args.M,
        "N": args.N,
        "K": args.K,
        "W": args.W,
        "seed": args.seed,
        "density_a": args.density_a,
        "density_b": args.density_b,
        "pe_lanes": PE_LANES,
        "vec_words": VEC_WORDS,
        "vec_bits": VEC_WORDS * 32,
        "files": {
            "a_row_order": "a_row_order.hex",
            "a_vec": "a_vec.hex",
            "b_chunk_ptr": "b_chunk_ptr.hex",
            "b_val": "b_val.hex",
            "golden_c": "golden_c.hex",
            "result_hex": str(result_path.as_posix()),
            "visualize_dir": str(result_dir.as_posix()),
            "rtl_alias_a_vec": "a_compact_vec.hex",
            "rtl_alias_b_ptr": "b_row_ptr.hex",
            "rtl_alias_b_val": "b_val_pack.hex",
        },
        "rtl_config": {
            "cfg_m": args.M,
            "cfg_n": args.N,
            "cfg_k": args.K,
            "cfg_block_vecs": args.W,
            "cfg_a_vec_count": len(a_vec_lines),
            "cfg_b_spmm_ptr_base": 0,
            "cfg_b_add_ptr_base": 0,
            "cfg_pe_mode": {"spmm": 0, "add": 1, "sub": 2}[mode],
        },
        "formats": {
            "a_vec": "compact_csv_66x32_word0_1_eor_word2_65_entries",
            "b_val": b_logical,
            "b_ptr_unit": "chunk_or_vector_address",
            "addsub_b_ptr_note": "ADD/SUB B_loader should read b_val sequentially; b_ptr is emitted only for compatibility.",
        },
        "stats": {
            "groups": groups,
            "a_nnz": a_nnz,
            "b_nnz": b_nnz,
            "c_nnz": c_nnz,
            "a_vec_count": len(a_vec_lines),
            "b_val_word_count": len(b_val_lines),
            "b_ptr_count": len(b_ptr),
            "a_group_vec_counts": a_group_vec_counts,
            "b_group_vec_counts": b_group_vec_counts,
            "a_lane_fill_rate": (a_nnz / (len(a_vec_lines) * PE_LANES)) if a_vec_lines else 0.0,
        },
        "json_note": {
            "coo_truncated": (coo_limit is not None and (a_nnz > coo_limit or b_nnz > coo_limit or c_nnz > coo_limit)),
            "max_json_coo": coo_limit,
        },
        "row_order": row_order[:padded_m],
        "A_coo": rows_to_coo(a_rows, coo_limit),
        "B_coo": rows_to_coo(b_rows, coo_limit),
        "C_golden_coo": dense_to_coo(golden, coo_limit),
    }

    with case_json_path.open("w", encoding="utf-8") as f:
        json.dump(case_info, f, indent=2, ensure_ascii=False)

    return case_info


# -----------------------------------------------------------------------------
# Suite presets.
# -----------------------------------------------------------------------------

def preset(case: str, mode: str, M: int, N: int, K: int, W: int, pattern: str,
           seed: int = 1, density_a: float = 0.08, density_b: float = 0.08,
           extra: Optional[Dict[str, object]] = None) -> Dict[str, object]:
    d: Dict[str, object] = {
        "case": case,
        "mode": mode,
        "M": M,
        "N": N,
        "K": K,
        "W": W,
        "pattern": pattern,
        "seed": seed,
        "density_a": density_a,
        "density_b": density_b,
    }
    if extra:
        d.update(extra)
    return d


SUITES: Dict[str, List[Dict[str, object]]] = {
    "pressure": [
        # SpMM datapath and block-boundary cases.
        preset("spmm_small4_manual", "spmm", 4, 4, 4, 2, "manual_small", 11),
        preset("spmm_small8_manual", "spmm", 8, 8, 8, 2, "manual_small", 12),
        preset("spmm_zero64", "spmm", 64, 64, 64, 4, "zero", 13),
        preset("spmm_identity64", "spmm", 64, 64, 64, 4, "identity", 14),
        preset("spmm_diagonal128", "spmm", 128, 128, 128, 8, "diagonal", 15),
        preset("spmm_a_diag128", "spmm", 128, 128, 128, 8, "a_diag", 16, density_b=0.08),
        preset("spmm_b_diag128", "spmm", 128, 128, 128, 8, "b_diag", 17, density_a=0.08),
        preset("spmm_empty_rows128", "spmm", 128, 128, 128, 8, "empty_rows", 18, extra={"empty_every": 5}),
        preset("spmm_M70_partial", "spmm", 70, 128, 128, 8, "random", 19, 0.10, 0.06),
        preset("spmm_M127_partial", "spmm", 127, 128, 128, 8, "random", 20, 0.08, 0.06),
        preset("spmm_brow_nnz_0_64_65_128_129", "spmm", 128, 256, 128, 8, "b_row_nnz", 21,
               extra={"b_row_nnz": "0:0,1:64,2:65,3:128,4:129"}),
        preset("spmm_K128_W4_multiblock", "spmm", 128, 128, 128, 4, "multiblock", 22,
               extra={"multi_a_nnz": 18, "multi_b_nnz": 8}),
        preset("spmm_K256_W8_multiblock", "spmm", 128, 256, 256, 8, "multiblock", 23,
               extra={"multi_a_nnz": 24, "multi_b_nnz": 6}),
        preset("spmm_row_reorder128", "spmm", 128, 128, 128, 8, "reorder", 24),

        # Matrix ADD sparse merge cases.
        preset("add_small8_manual", "add", 8, 8, 8, 2, "manual_small", 31),
        preset("add_same_cols128", "add", 128, 128, 128, 8, "same_cols", 32,
               extra={"same_cols_n": 16, "same_cols_step": 2}),
        preset("add_disjoint_cols128", "add", 128, 128, 128, 8, "disjoint_cols", 33,
               extra={"disjoint_span": 32}),
        preset("add_a_empty_rows128", "add", 128, 128, 128, 8, "a_empty_rows", 34, 0.10, 0.10,
               extra={"empty_every": 4}),
        preset("add_b_empty_rows128", "add", 128, 128, 128, 8, "b_empty_rows", 35, 0.10, 0.10,
               extra={"empty_every": 4}),
        preset("add_b_only128", "add", 128, 128, 128, 8, "b_only", 36, extra={"b_only_nnz": 6}),
        preset("add_M70_partial", "add", 70, 128, 128, 8, "partial_group", 37, 0.10, 0.10),
        preset("add_M127_partial", "add", 127, 128, 128, 8, "partial_group", 38, 0.10, 0.10),

        # Matrix SUB sparse merge cases.
        preset("sub_small8_manual", "sub", 8, 8, 8, 2, "manual_small", 41),
        preset("sub_same_cols128", "sub", 128, 128, 128, 8, "same_cols", 42,
               extra={"same_cols_n": 16, "same_cols_step": 2}),
        preset("sub_disjoint_cols128", "sub", 128, 128, 128, 8, "disjoint_cols", 43,
               extra={"disjoint_span": 32}),
        preset("sub_b_only128", "sub", 128, 128, 128, 8, "b_only", 44, extra={"b_only_nnz": 6}),
        preset("sub_cancel128", "sub", 128, 128, 128, 8, "cancel", 45, extra={"cancel_nnz": 8}),
        preset("sub_M70_partial", "sub", 70, 128, 128, 8, "partial_group", 46, 0.10, 0.10),
    ]
}


def add_common_generation_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--case", help="case name / output subdirectory")
    p.add_argument("--M", type=int, help="rows of A/C")
    p.add_argument("--N", type=int, help="cols of B/C; cols of A/B for ADD/SUB")
    p.add_argument("--K", type=int, help="inner dimension for SPMM; kept for ADD/SUB config compatibility")
    p.add_argument("--W", type=int, help="BLOCK_VECS for SPMM")
    p.add_argument("--mode", choices=["spmm", "add", "sub", "SPMM", "ADD", "SUB"], help="operation mode")
    p.add_argument("--outbase", default="testcase", help="base testcase directory")
    p.add_argument("--testbase", default="test_result", help="base test result directory")
    p.add_argument("--seed", type=int, default=1, help="random seed")
    p.add_argument("--density-a", type=float, default=0.08, help="A sparse density for random-like patterns")
    p.add_argument("--density-b", type=float, default=0.08, help="B sparse density for random-like patterns")
    p.add_argument("--ensure-some", action="store_true", help="force each generated random row to contain at least one nonzero")
    p.add_argument("--pattern", default="random", choices=[
        "random",
        "zero", "all_zero",
        "identity", "unit",
        "diagonal", "a_diag", "b_diag",
        "empty_rows", "a_empty_rows", "b_empty_rows",
        "b_row_nnz",
        "multiblock", "multi_block",
        "reorder", "row_reorder",
        "same_cols", "same_columns",
        "disjoint_cols", "disjoint_columns",
        "b_only",
        "cancel", "sub_cancel",
        "partial_group", "partial",
        "small", "manual_small",
    ], help="deterministic stress pattern")
    p.add_argument("--max-nnz-a", type=int, default=None, help="optional cap on random A nnz per row")
    p.add_argument("--max-nnz-b", type=int, default=None, help="optional cap on random B nnz per row")
    p.add_argument("--empty-every", type=int, default=5, help="make every Nth row empty for empty-row patterns")
    p.add_argument("--b-row-nnz", default="", help="SPMM pattern b_row_nnz spec, e.g. 0:0,1:64,2:65,3:128,4:129")
    p.add_argument("--multi-a-nnz", type=int, default=18, help="A nnz per row for multiblock pattern")
    p.add_argument("--multi-b-nnz", type=int, default=8, help="B nnz per row for multiblock/reorder pattern")
    p.add_argument("--same-cols-n", type=int, default=16, help="span used by same_cols pattern")
    p.add_argument("--same-cols-step", type=int, default=2, help="column step used by same_cols pattern")
    p.add_argument("--disjoint-span", type=int, default=32, help="column span used by disjoint_cols pattern")
    p.add_argument("--b-only-nnz", type=int, default=6, help="B nnz per row for b_only pattern")
    p.add_argument("--cancel-nnz", type=int, default=8, help="nnz per row for sub cancel pattern")
    p.add_argument("--max-json-coo", type=int, default=200000, help="max COO entries stored per A/B/C in case.json")
    p.add_argument("--full-json-coo", action="store_true", help="store full COO arrays in case.json even for huge cases")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Generate compact-CSV SpMM/ADD/SUB testcase")
    add_common_generation_args(p)
    p.add_argument("--suite", choices=sorted(SUITES.keys()), help="generate a named stress suite")
    p.add_argument("--suite-list", choices=sorted(SUITES.keys()), help="print case names in a named suite and exit")
    return p.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.suite or args.suite_list:
        return
    missing = [k for k in ("case", "M", "N", "K", "W", "mode") if getattr(args, k) is None]
    if missing:
        raise SystemExit(f"Missing required arguments for single-case generation: {', '.join(missing)}")
    if args.M <= 0 or args.N <= 0 or args.K <= 0 or args.W <= 0:
        raise SystemExit("M, N, K and W must be positive")
    if args.M > 65535 or args.N > 65535 or args.K > 65535:
        raise SystemExit("M, N, K must fit in 16-bit indices for the current RTL format")


def namespace_from_preset(base_args: argparse.Namespace, d: Dict[str, object]) -> argparse.Namespace:
    merged = vars(base_args).copy()
    merged.update(d)
    # Clear suite controls before generating each preset case.
    merged["suite"] = None
    merged["suite_list"] = None
    return argparse.Namespace(**merged)


def main() -> None:
    args = parse_args()

    if args.suite_list:
        for d in SUITES[args.suite_list]:
            print(d["case"])
        return

    validate_args(args)

    if args.suite:
        manifest = []
        for d in SUITES[args.suite]:
            one_args = namespace_from_preset(args, d)
            info = generate_one(one_args)
            manifest.append({
                "case": info["case"],
                "mode": info["mode"],
                "pattern": info["pattern"],
                "M": info["M"],
                "N": info["N"],
                "K": info["K"],
                "W": info["W"],
                "a_vec_count": info["stats"]["a_vec_count"],
                "b_val_word_count": info["stats"]["b_val_word_count"],
                "c_nnz": info["stats"]["c_nnz"],
            })
            print(f"[SUITE] generated {info['case']} mode={info['mode']} pattern={info['pattern']}")
        outbase = Path(args.outbase)
        outbase.mkdir(parents=True, exist_ok=True)
        with (outbase / f"{args.suite}_manifest.json").open("w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
        print(f"[SUITE] wrote {outbase / f'{args.suite}_manifest.json'}")
        return

    info = generate_one(args)
    print(f"Generated case: {info['case']}")
    print(f"  mode={info['mode']} pattern={info['pattern']} M={info['M']} N={info['N']} K={info['K']} W={info['W']}")
    print(f"  output={Path(args.outbase) / args.case}")
    print(f"  result={info['files']['result_hex']}")
    print(f"  A nnz={info['stats']['a_nnz']}, A vectors={info['stats']['a_vec_count']}, lane fill={info['stats']['a_lane_fill_rate']:.3f}")
    print(f"  B nnz={info['stats']['b_nnz']}, B packed/vector words={info['stats']['b_val_word_count']}, B ptr entries={info['stats']['b_ptr_count']}")
    print(f"  C nnz={info['stats']['c_nnz']}")
    print("  RTL config:")
    for k, v in info["rtl_config"].items():
        print(f"    {k} = {v}")


if __name__ == "__main__":
    main()
