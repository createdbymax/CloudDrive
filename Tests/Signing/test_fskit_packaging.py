import datetime
import pathlib
import sys
import unittest
import plistlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]/'scripts'))
import fskit_packaging


class FSKitPackagingTests(unittest.TestCase):
    def test_extension_requires_secured_path_resource_contract(self):
        path = pathlib.Path(__file__).resolve().parents[2]/'Sources/CloudDriveFS/Info.plist'
        info = plistlib.loads(path.read_bytes())
        fskit_packaging.validate_extension_info(info)
        for field, value in [('FSSupportsPathURLs', False),
                             ('FSRequiresSecurityScopedPathURLResources', False),
                             ('FSSupportsBlockResources', True),
                             ('EXExtensionPointIdentifier', 'other')]:
            bad = plistlib.loads(path.read_bytes())
            bad['EXAppExtensionAttributes'][field] = value
            with self.assertRaises(RuntimeError): fskit_packaging.validate_extension_info(bad)
        info['LSMinimumSystemVersion'] = '15.4'
        with self.assertRaises(RuntimeError): fskit_packaging.validate_extension_info(info)

    def profile(self):
        return {'TeamIdentifier': ['TEAM123'],
                'ExpirationDate': datetime.datetime(2030, 1, 1),
                'Entitlements': {'com.apple.application-identifier': 'TEAM123.'+fskit_packaging.EXTENSION_ID,
                                 'com.apple.developer.fskit.fsmodule': True}}

    def test_profile_requires_exact_module_grant(self):
        profile = self.profile()
        self.assertEqual(fskit_packaging.validate_profile_dictionary(profile), 'TEAM123')
        profile['Entitlements'].pop('com.apple.developer.fskit.fsmodule')
        with self.assertRaises(RuntimeError): fskit_packaging.validate_profile_dictionary(profile)

    def test_wildcard_or_other_extension_is_not_authorized(self):
        for identifier in ['TEAM123.*', 'TEAM123.local.another.filesystem', 'OTHERTEAM.'+fskit_packaging.EXTENSION_ID]:
            profile = self.profile(); profile['Entitlements']['com.apple.application-identifier'] = identifier
            with self.assertRaises(RuntimeError): fskit_packaging.validate_profile_dictionary(profile)

    def test_expired_or_ambiguous_profile_fails_closed(self):
        profile = self.profile(); profile['ExpirationDate'] = datetime.datetime(2000, 1, 1)
        with self.assertRaises(RuntimeError): fskit_packaging.validate_profile_dictionary(profile)
        profile = self.profile(); profile['TeamIdentifier'].append('OTHERTEAM')
        with self.assertRaises(RuntimeError): fskit_packaging.validate_profile_dictionary(profile)

    def test_legacy_build_needs_no_profile_and_requested_extension_cannot_silently_fallback(self):
        self.assertIsNone(fskit_packaging.requested_profile({}))
        with self.assertRaises(RuntimeError): fskit_packaging.requested_profile({'CLOUDDRIVE_INCLUDE_FSKIT': '1'})
        with self.assertRaises(RuntimeError): fskit_packaging.requested_profile({'CLOUDDRIVE_INCLUDE_FSKIT': 'true'})


if __name__ == '__main__': unittest.main()
