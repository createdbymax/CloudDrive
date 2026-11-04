import importlib.util, pathlib, unittest
from unittest import mock
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('signing',ROOT/'scripts/signing.py')
signing=importlib.util.module_from_spec(spec);spec.loader.exec_module(signing)

class SigningTests(unittest.TestCase):
    def test_forced_ui_preview_never_queries_keychain_or_baseline(self):
        with mock.patch.dict(signing.os.environ, {'CLOUDDRIVE_ADHOC_ONLY': '1'}), \
             mock.patch.object(signing, 'run', side_effect=AssertionError('Keychain must not be queried')) as run, \
             mock.patch.object(signing, 'BASELINE') as baseline:
            baseline.exists.side_effect = AssertionError('Preview must not inspect the certificate baseline')
            self.assertEqual(signing.selection(), '-')
            run.assert_not_called()
            baseline.exists.assert_not_called()
    def test_missing_identity_does_not_silently_choose_adhoc(self):
        with self.assertRaises(signing.SigningError):signing.select_identity([])
        self.assertEqual(signing.select_identity([],allow_adhoc=True),'-')
    def test_pin_and_ambiguous_selection(self):
        identities=[('A'*40,'Apple Development: Fixture'),('B'*40,'Developer ID Application: Fixture')]
        with self.assertRaises(signing.SigningError):signing.select_identity(identities)
        self.assertEqual(signing.select_identity(identities,requested='a'*40),'A'*40)
        with self.assertRaises(signing.SigningError):signing.select_identity(identities,requested='Fixture')
        with self.assertRaises(signing.SigningError):signing.select_identity(identities,requested='C'*40)
    def test_baseline_does_not_silently_change_channel(self):
        ids=[('A'*40,'Apple Development: Fixture'),('B'*40,'Developer ID Application: Fixture')]
        self.assertEqual(signing.select_identity(ids,baseline={'certificateSHA1':'A'*40}),'A'*40)
        with self.assertRaises(signing.SigningError):signing.select_identity(ids[1:],allow_adhoc=True,baseline={'certificateSHA1':'A'*40})
    def test_reject_weak_requirements(self):
        for dr in ['cdhash H"123"','identifier "local.bucketdrive.app"','identifier "other" and anchor apple generic']:
            with self.assertRaises(signing.SigningError):signing.validate_stable_requirement(dr)
        signing.validate_stable_requirement('identifier "local.bucketdrive.app" and anchor apple generic and certificate leaf[subject.OU] = "FIXTURE"')
    def test_parse_only_valid_security_identity_lines(self):
        text='  1) '+('A'*40)+' "Apple Development: Fixture"\n  1 valid identities found\n'
        self.assertEqual(signing.parse_identities(text),[('A'*40,'Apple Development: Fixture')])
        self.assertEqual(signing.parse_identities('     0 valid identities found'),[])
    def test_requirement_extraction(self):
        self.assertEqual(signing.designated_requirement('Executable=/fixture\ndesignated => cdhash H"abc"\n'),'cdhash H"abc"')
        self.assertEqual(signing.designated_requirement('Executable=/fixture\n# designated => cdhash H"abc"\n'),'cdhash H"abc"')
    def test_matching_but_invalid_identity_explains_chain_without_using_it(self):
        matching='  1) '+('A'*40)+' "Apple Development: Fixture"\n'
        with mock.patch.dict(signing.os.environ,{},clear=True), mock.patch.object(signing,'run',side_effect=['0 valid identities found',matching]):
            with self.assertRaisesRegex(signing.SigningError,'certificate chain'):
                signing.selection()
    def test_duplicate_keychain_rows_are_one_certificate(self):
        line='  1) '+('A'*40)+' "Apple Development: Fixture"\n'
        identities=signing.parse_identities(line+line)
        self.assertEqual(len(identities),1)
        self.assertEqual(signing.select_identity(identities,requested='A'*40),'A'*40)

if __name__=='__main__':unittest.main()
