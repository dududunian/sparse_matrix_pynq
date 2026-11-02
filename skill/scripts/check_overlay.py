"""Check a traditional PYNQ bit/hwh bundle offline; never programs hardware."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def check(bit, hwh, config=None):
    errors = []
    report = dict(offline_checks_passed=False, declared_pair_verified=False,
                  board_tested=False, files={}, errors=errors)
    if bit.stem != hwh.stem:
        errors.append('The bit/hwh basenames differ.')
    for label, path in [('bit', bit), ('hwh', hwh)]:
        if not path.is_file() or path.stat().st_size == 0:
            errors.append('Missing or empty {} file: {}'.format(label, path))
        else:
            report['files'][label] = dict(path=str(path), bytes=path.stat().st_size,
                                          sha256=sha256(path))
    if 'hwh' in report['files']:
        try:
            root = ET.parse(str(hwh)).getroot()
            if root.tag.rsplit('}', 1)[-1] != 'EDKSYSTEM':
                errors.append('Unsupported HWH root; expected EDKSYSTEM.')
            report['hwh_modules'] = sum(
                node.tag.rsplit('}', 1)[-1] == 'MODULE' for node in root.iter())
            if not report['hwh_modules']:
                errors.append('HWH contains no MODULE nodes.')
        except ET.ParseError as error:
            errors.append('HWH XML parsing failed: {}'.format(error))
    if config is not None:
        if not isinstance(config, dict):
            errors.append('Config must be a JSON object.')
        else:
            matched = []
            for label in ['bit', 'hwh']:
                expected = config.get(label + '_sha256')
                valid = isinstance(expected, str) and re.fullmatch(r'[0-9a-fA-F]{64}', expected)
                actual = report['files'].get(label, {}).get('sha256')
                match = bool(valid and actual == expected.lower())
                matched.append(match)
                if not match:
                    errors.append('Missing, invalid or mismatching {} SHA256.'.format(label))
            report['declared_pair_verified'] = all(matched)
    report['offline_checks_passed'] = not errors
    report['limitations'] = (
        'No bitstream semantic validation, timing approval, PYNQ parsing, download or board test. '
        'Hashes bind files to the supplied declaration, not prove a common build by themselves.')
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bit', type=Path, required=True)
    parser.add_argument('--hwh', type=Path, required=True)
    parser.add_argument('--config', type=Path, help='JSON object with bit_sha256 and hwh_sha256')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    try:
        config = json.loads(args.config.read_text(encoding='utf-8')) if args.config else None
        report = check(args.bit, args.hwh, config)
    except (OSError, ValueError) as error:
        parser.exit(2, 'Input error: {}\n'.format(error))
    payload = json.dumps(report, indent=2, ensure_ascii=True)
    if args.report:
        args.report.write_text(payload + '\n', encoding='utf-8')
    print(payload)
    return 0 if report['offline_checks_passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
