import datetime
import hashlib
import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
spec = importlib.util.spec_from_file_location('provision_fskit', ROOT/'scripts/provision-fskit.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class FSKitProvisioningTests(unittest.TestCase):
    def test_generated_profile_must_authorize_pinned_certificate_and_same_team(self):
        certificate = b'synthetic certificate fixture'
        profile = {'TeamIdentifier': ['TEAM123456'], 'ExpirationDate': datetime.datetime(2030, 1, 1),
                   'DeveloperCertificates': [certificate], 'Entitlements': {
                       'com.apple.application-identifier': 'TEAM123456.local.bucketdrive.app.filesystem',
                       'com.apple.developer.fskit.fsmodule': True}}
        module.validate_generated_profile(profile, 'TEAM123456', hashlib.sha1(certificate).hexdigest())
        with self.assertRaises(RuntimeError): module.validate_generated_profile(profile, 'OTHER12345', hashlib.sha1(certificate).hexdigest())
        with self.assertRaises(RuntimeError): module.validate_generated_profile(profile, 'TEAM123456', '0'*40)

    def test_account_absence_is_distinguished_from_signing_conflict(self):
        self.assertEqual(module.failure_code('No Accounts: Add a new account. No profiles for app'), 'xcode-account-sign-in-required')
        self.assertEqual(module.failure_code('has conflicting provisioning settings'), 'conflicting-signing-settings')
        self.assertEqual(module.failure_code("No profiles for 'app'"), 'matching-profile-unavailable')

    def test_command_cannot_inject_other_target_or_explicit_certificate(self):
        command = module.build_command('TEAM123456', pathlib.Path('/tmp/synthetic'))
        self.assertIn('CODE_SIGN_IDENTITY=Apple Development', command)
        self.assertEqual(command[command.index('-target')+1], 'CloudDriveFS')
        self.assertNotIn('-allowProvisioningDeviceRegistration', command)
        with self.assertRaises(ValueError): module.build_command('TEAM123456 OTHER=bad', pathlib.Path('/tmp/synthetic'))
