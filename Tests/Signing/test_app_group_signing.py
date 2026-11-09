import pathlib
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]/'scripts'))
import signing

class AppGroupSigningTests(unittest.TestCase):
    def test_group_is_team_scoped_without_keychain_or_sandbox_exceptions(self):
        self.assertEqual(signing.app_group_entitlements('EGEBBVL76D'), {
            'com.apple.security.application-groups': ['EGEBBVL76D.cd']})
        for invalid in ['', 'OTHER', 'TEAM.*', 'EGEBBVL76D.cd']:
            with self.assertRaises(signing.SigningError): signing.app_group_entitlements(invalid)

    def test_adhoc_and_mismatched_signature_team_are_rejected(self):
        with self.assertRaises(signing.SigningError):
            signing.sign_target(pathlib.Path('/tmp/fixture'), 'fixture', '-', 'EGEBBVL76D')
        with patch.object(signing, 'run', return_value='TeamIdentifier=OTHERTEAM1'):
            with self.assertRaises(signing.SigningError):
                signing.sign_target(pathlib.Path('/tmp/fixture'), 'fixture', 'A'*40, 'EGEBBVL76D')
