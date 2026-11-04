import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2]/'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('package_app', SCRIPTS/'package-app.py')
package_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_app)


class BackendNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.backend = root/'rclone'; self.backend.write_bytes(b'synthetic executable')
        self.notices = root/'backend-notices'; self.notices.mkdir()
        (self.notices/'LICENSE').write_text('synthetic fixture notice')
        self.manifest = {'backendSHA256': self.sha(self.backend),
                         'files': {'LICENSE': self.sha(self.notices/'LICENSE')}}
        self.save()

    def sha(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def save(self):
        (self.notices/'MANIFEST.json').write_text(json.dumps(self.manifest))

    def test_matching_bundle_is_accepted(self):
        self.assertEqual(package_app.validate_backend_notices(self.backend), self.notices)

    def test_changed_backend_cannot_reuse_notices(self):
        self.backend.write_bytes(b'different executable')
        with self.assertRaisesRegex(RuntimeError, 'do not match'):
            package_app.validate_backend_notices(self.backend)

    def test_changed_notice_blocks_packaging(self):
        (self.notices/'LICENSE').write_text('modified notice')
        with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
            package_app.validate_backend_notices(self.backend)

    def test_manifest_cannot_reference_files_outside_bundle(self):
        self.manifest['files'] = {'../rclone': self.sha(self.backend)}; self.save()
        with self.assertRaisesRegex(RuntimeError, 'Invalid backend notice path'):
            package_app.validate_backend_notices(self.backend)

    def test_missing_notice_blocks_packaging(self):
        (self.notices/'LICENSE').unlink()
        with self.assertRaises(FileNotFoundError):
            package_app.validate_backend_notices(self.backend)
