"""Compare nonempty output dumps to a Golden reference without truncating lengths."""
import argparse
import json
import math
from pathlib import Path
import re
import sys


def load_values(path, data_format, bits):
    text = path.read_text(encoding='utf-8')
    if data_format == 'hex':
        tokens = ' '.join(line.split('#', 1)[0] for line in text.splitlines()).split()
        if not all(re.fullmatch(r'(?:0[xX])?[0-9a-fA-F]+', token) for token in tokens):
            raise ValueError('Hex input requires unsigned hex words; x/z and address markers are unsupported.')
        values = [int(token, 16) for token in tokens]
        if any(value >= (1 << bits) for value in values):
            raise ValueError('Hex word exceeds the declared bit width.')
    else:
        values = json.loads(text)
        if not isinstance(values, list) or any(type(v) not in (int, float) for v in values):
            raise ValueError('JSON input must be a flat numeric array; booleans are not numbers here.')
        if any(isinstance(v, float) and not math.isfinite(v) for v in values):
            raise ValueError('Nonfinite JSON values require an explicit project-specific comparison policy.')
    if not values:
        raise ValueError('Empty result/reference is not a passing test.')
    return values


def compare(actual, expected, mode='exact', atol=0.0, rtol=0.0):
    if not actual or not expected:
        raise ValueError('Empty arrays are unsupported.')
    differences = []
    max_error = 0
    for index, (value, want) in enumerate(zip(actual, expected)):
        error = abs(value - want)
        max_error = max(max_error, error)
        if mode == 'exact':
            good = value == want
        else:
            from decimal import Decimal
            dv = Decimal(value) if isinstance(value, int) else Decimal.from_float(value)
            dw = Decimal(want) if isinstance(want, int) else Decimal.from_float(want)
            good = abs(dv-dw) <= Decimal.from_float(float(atol)) + Decimal.from_float(float(rtol))*abs(dw)
        if not good:
            differences.append(dict(index=index, actual=value, expected=want))
    missing_or_extra = abs(len(actual) - len(expected))
    mismatches = len(differences) + missing_or_extra
    return dict(passed=mismatches == 0, actual_values=len(actual), expected_values=len(expected),
                length_match=len(actual) == len(expected), mismatches=mismatches,
                missing_or_extra=missing_or_extra, first_differences=differences[:10],
                max_abs_error_on_overlap=max_error if not isinstance(max_error,float) or math.isfinite(max_error) else None, mode=mode, atol=atol, rtol=rtol)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--actual', type=Path, required=True)
    parser.add_argument('--golden', type=Path, required=True)
    parser.add_argument('--format', choices=['hex', 'json'], required=True)
    parser.add_argument('--bits', type=int, default=32, help='Unsigned hex word width; no float decoding')
    parser.add_argument('--mode', choices=['exact', 'numeric'], default='exact')
    parser.add_argument('--atol', type=float, default=0.0)
    parser.add_argument('--rtol', type=float, default=0.0)
    parser.add_argument('--source-kind', choices=['unspecified', 'simulation', 'board', 'example'],
                        default='unspecified', help='User declaration only; not authenticated')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    if not 1 <= args.bits <= 4096:
        parser.error('bits must be between 1 and 4096')
    if not all(math.isfinite(v) and v >= 0 for v in (args.atol, args.rtol)):
        parser.error('Tolerances must be finite and nonnegative')
    if args.format == 'hex' and args.mode != 'exact':
        parser.error('Hex is bit-pattern comparison only; decode numeric values to JSON first')
    if args.mode == 'exact' and (args.atol != 0 or args.rtol != 0):
        parser.error('Exact mode does not use tolerances')
    try:
        actual = load_values(args.actual, args.format, args.bits)
        expected = load_values(args.golden, args.format, args.bits)
        report = compare(actual, expected, args.mode, args.atol, args.rtol)
    except (OSError, ValueError) as error:
        parser.exit(2, 'Input error: {}\n'.format(error))
    report.update(actual=str(args.actual), golden=str(args.golden),
                  source_kind_declared=args.source_kind, source_authenticated=False,
                  scope='File comparison only; does not establish real-board execution')
    payload = json.dumps(report, indent=2, ensure_ascii=True)
    if args.report:
        args.report.write_text(payload + '\n', encoding='utf-8')
    print(payload)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
