import os
import pathlib
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
import finder_packaging

class FinderPackagingTests(unittest.TestCase):
    def test_identity_and_extension_point_must_match(self):
        info = plistlib.loads((ROOT/'Sources/CloudDriveFinder/Info.plist').read_bytes())
        finder_packaging.validate_info(info)
        info['NSExtension']['NSExtensionPointIdentifier'] = 'other'
        with self.assertRaises(RuntimeError): finder_packaging.validate_info(info)

    def test_requested_missing_extension_does_not_silently_skip(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'CLOUDDRIVE_INCLUDE_FINDER': '1'}, clear=True):
            root = pathlib.Path(directory)
            with self.assertRaises(RuntimeError): finder_packaging.embed_extension(root/'App.app', root/'products', ROOT, '1.0.0', '1', None)

    def test_disabled_extension_does_not_need_signer_or_source(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            root = pathlib.Path(directory)
            self.assertIsNone(finder_packaging.embed_extension(root/'App.app', root/'products', ROOT, '1.0.0', '1', None))
