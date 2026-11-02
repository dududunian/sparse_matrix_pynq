"""Offline regression; fixtures are synthetic and do not emulate FPGA execution."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import check_overlay
import compare_golden
import probe_environment


class ReuseTests(unittest.TestCase):
    def setUp(self):
        # Keep temporary files within the writable skill directory.
        self.temp = tempfile.TemporaryDirectory(dir=str(Path(__file__).resolve().parent))
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.write_text(text, encoding='utf-8')
        return path

    def test_overlay_pair_with_declared_hashes(self):
        bit = self.write('example.bit', 'synthetic-bit-fixture-not-hardware')
        hwh = self.write('example.hwh', '<EDKSYSTEM><MODULE INSTANCE="example"/></EDKSYSTEM>')
        config = {key + '_sha256': check_overlay.sha256(path) for key, path in [('bit', bit), ('hwh', hwh)]}
        result = check_overlay.check(bit, hwh, config)
        self.assertTrue(result['offline_checks_passed'])
        self.assertTrue(result['declared_pair_verified'])
        self.assertFalse(result['board_tested'])
        config['bit_sha256'] = '0' * 64
        self.assertFalse(check_overlay.check(bit, hwh, config)['offline_checks_passed'])

    def test_overlay_name_missing_and_malformed(self):
        bit = self.write('one.bit', 'synthetic')
        hwh = self.write('two.hwh', 'not xml')
        self.assertFalse(check_overlay.check(bit, hwh)['offline_checks_passed'])
        self.assertFalse(check_overlay.check(self.root/'missing.bit', hwh)['offline_checks_passed'])

    def test_without_hashes_no_pair_proof(self):
        bit = self.write('a.bit', 'synthetic')
        hwh = self.write('a.hwh', '<EDKSYSTEM><MODULE/></EDKSYSTEM>')
        self.assertFalse(check_overlay.check(bit, hwh)['declared_pair_verified'])

    def test_vector_add_example(self):
        a, b = [1, 2, 3, 4], [4, 3, 2, 1]
        self.assertTrue(compare_golden.compare([x+y for x,y in zip(a,b)], [5]*4)['passed'])

    def test_threshold_example(self):
        source = [-2.0, 0.0, 0.4, 1.3]
        self.assertTrue(compare_golden.compare([int(x > 0) for x in source], [0,0,1,1])['passed'])

    def test_numeric_tolerance_and_mismatch(self):
        self.assertTrue(compare_golden.compare([1.0001], [1.0], 'numeric', 0.001)['passed'])
        self.assertFalse(compare_golden.compare([1.1], [1.0], 'numeric', 0.001)['passed'])

    def test_numeric_overflow_regression(self):
        result=compare_golden.compare([1e308],[-1e308], 'numeric', 0.0, 1.8)
        self.assertFalse(result['passed'])

    def test_length_mismatch_is_failure(self):
        result = compare_golden.compare([1,2], [1,2,3])
        self.assertFalse(result['passed'])
        self.assertEqual(result['mismatches'], 1)

    def test_invalid_hex_and_empty(self):
        for text in ['', 'xxxx', '10000']:
            path = self.write('bad.hex', text)
            with self.assertRaises(ValueError):
                compare_golden.load_values(path, 'hex', 16)

    def test_hex_unsigned_bit_patterns(self):
        path = self.write('data.hex', '3c00 8000\n# comment\n0x0001')
        self.assertEqual(compare_golden.load_values(path, 'hex', 16), [0x3c00,0x8000,1])

    def test_json_nonfinite_and_invalid_shape(self):
        for value in ['[NaN]', '[true]', '[[1,2]]']:
            path = self.write('bad.json', value)
            with self.assertRaises(ValueError):
                compare_golden.load_values(path, 'json', 32)

    def test_cli_codes_and_report(self):
        golden = self.write('golden.json', '[1,2,3]')
        actual = self.write('actual.json', '[1,2,4]')
        report = self.root/'report.json'
        argv = ['--actual',str(actual),'--golden',str(golden),'--format','json','--report',str(report)]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(compare_golden.main(argv), 1)
            actual.write_text('[1,2,3]', encoding='utf-8')
            self.assertEqual(compare_golden.main(argv), 0)
        self.assertFalse(json.loads(report.read_text())['source_authenticated'])

    def test_probe_arm32_arm64_without_hardware_access(self):
        def forbidden(*args, **kwargs):
            raise AssertionError('Hardware APIs must not be instantiated')
        fake = types.SimpleNamespace(__version__='fixture', Overlay=forbidden,
                                     MMIO=forbidden, allocate=forbidden)
        ps = types.SimpleNamespace(Clocks=forbidden)
        for machine in ['armv7l', 'aarch64']:
            with patch.object(probe_environment.platform, 'system', return_value='Linux'), \
                 patch.object(probe_environment.platform, 'machine', return_value=machine), \
                 patch.object(probe_environment.importlib, 'import_module',
                              side_effect=lambda name: fake if name == 'pynq' else ps):
                report = probe_environment.collect()
                self.assertTrue(report['embedded_arm_linux_candidate'])
                self.assertTrue(report['core_apis_importable'])
                self.assertFalse(report['hardware_tested'])

    def test_probe_missing_pynq(self):
        with patch.object(probe_environment.importlib, 'import_module',
                          side_effect=ModuleNotFoundError('synthetic absence')):
            report = probe_environment.collect()
            self.assertFalse(report['core_apis_importable'])
            self.assertIn('pynq', report['errors'])

    def test_probe_refuses_existing_output(self):
        output = self.write('existing.json', 'preserve me')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            probe_environment.main(['--output', str(output)])
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(output.read_text(), 'preserve me')


if __name__ == '__main__':
    unittest.main()
