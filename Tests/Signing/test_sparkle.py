import base64
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]/'scripts'))
from sparkle_config import update_metadata, configured_environment
import signing
from unittest import mock


class SparkleConfigTests(unittest.TestCase):
    def test_unconfigured_build_cannot_automatically_update(self):
        data = update_metadata({})
        self.assertNotIn('SUFeedURL', data)
        self.assertFalse(data['SUAllowsAutomaticUpdates'])

    def test_incomplete_or_insecure_release_config_is_rejected(self):
        key = base64.b64encode(bytes(32)).decode()
        for env in [{'CLOUDDRIVE_RELEASE': '1'}, {'CLOUDDRIVE_SPARKLE_PUBLIC_KEY': key},
                    {'CLOUDDRIVE_SPARKLE_FEED_URL': 'https://example.com/appcast.xml'},
                    {'CLOUDDRIVE_SPARKLE_FEED_URL': 'http://example.com/appcast.xml', 'CLOUDDRIVE_SPARKLE_PUBLIC_KEY': key},
                    {'CLOUDDRIVE_SPARKLE_FEED_URL': 'https://user:secret@example.com/feed', 'CLOUDDRIVE_SPARKLE_PUBLIC_KEY': key}]:
            with self.subTest(env=list(env)):
                with self.assertRaises(ValueError): update_metadata(env)

    def test_owner_defaults_and_explicit_opt_out(self):
        data = update_metadata(configured_environment({}))
        self.assertEqual(data['SUFeedURL'], 'https://github.com/createdbymax/CloudDrive/releases/latest/download/appcast.xml')
        self.assertEqual(len(base64.b64decode(data['SUPublicEDKey'])), 32)
        disabled = update_metadata(configured_environment({'CLOUDDRIVE_DISABLE_UPDATES': '1'}))
        self.assertNotIn('SUFeedURL', disabled)
        with self.assertRaises(ValueError):
            configured_environment({'CLOUDDRIVE_SPARKLE_FEED_URL': 'https://example.com/feed'})

    def test_configured_build_requires_user_approval(self):
        data = update_metadata({'CLOUDDRIVE_SPARKLE_FEED_URL': 'https://github.com/owner/repo/releases/latest/download/appcast.xml',
                                'CLOUDDRIVE_SPARKLE_PUBLIC_KEY': base64.b64encode(bytes(32)).decode()})
        self.assertFalse(data['SUAllowsAutomaticUpdates'])
        self.assertFalse(data['SUAutomaticallyUpdate'])
        self.assertFalse(data['SUEnableAutomaticChecks'])


class ReleaseSigningTests(unittest.TestCase):
    def test_distribution_signing_requires_runtime_and_timestamp(self):
        with mock.patch.dict(signing.os.environ, {'CLOUDDRIVE_RELEASE': '1'}):
            args = signing.codesign_args('fixture')
            self.assertIn('runtime', args)
            self.assertIn('--timestamp', args)
            self.assertNotIn('--timestamp=none', args)

    def test_development_signing_remains_local(self):
        with mock.patch.dict(signing.os.environ, {'CLOUDDRIVE_RELEASE': '0'}):
            args = signing.codesign_args('fixture')
            self.assertIn('--timestamp=none', args)
            self.assertNotIn('--options', args)
