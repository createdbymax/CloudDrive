import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

qualification = load('namespace_qualification', 'qualify-namespace-engine.py')
readiness = load('fskit_readiness', 'check-fskit-readiness.py')


class QualificationToolTests(unittest.TestCase):
    def test_percentiles_retain_count_and_reject_invalid_samples(self):
        result = qualification.timing_summary([float(i) for i in range(1, 101)])
        self.assertEqual(result['count'], 100)
        self.assertEqual((result['p50'], result['p95'], result['p99']), (50, 95, 99))
        for values in [[], [-1], [float('nan')], [float('inf')]]:
            with self.assertRaises(ValueError): qualification.timing_summary(values)

    def test_evidence_never_overwrites_existing_results(self):
        with tempfile.TemporaryDirectory() as work:
            path = pathlib.Path(work)/'result.json'
            qualification.write_new_evidence(path, {'status': 'original'})
            with self.assertRaises(FileExistsError): qualification.write_new_evidence(path, {'status': 'replacement'})
            self.assertEqual(json.loads(path.read_text()), {'status': 'original'})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_readiness_missing_extension_never_claims_activation(self):
        def missing_command(_): raise RuntimeError('missing')
        with tempfile.TemporaryDirectory() as work:
            report = readiness.inspect(pathlib.Path(work), run=missing_command, os_version='26.1')
            self.assertEqual(report['status'], 'blocked')
            self.assertTrue(any(item['check'] == 'filesystem-module-resource-contract' and item['status'] == 'blocked' for item in report['checks']))
            self.assertIn('mounted Finder callbacks', report['unverified'])

    def test_older_or_unknown_os_cannot_pass_readiness(self):
        def missing_command(_): raise RuntimeError('missing')
        for version in ['', '15.4', 'unknown']:
            with tempfile.TemporaryDirectory() as work:
                report = readiness.inspect(pathlib.Path(work), run=missing_command, os_version=version)
                self.assertEqual(report['checks'][0]['status'], 'blocked')


if __name__ == '__main__': unittest.main()
