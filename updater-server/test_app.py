import io
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit
from zipfile import ZipFile

from app import BUNDLE_ID, TTL, create_app, inspect_ipa


class HostedUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / 'output'
        self.token = 'test-only-token-aaaaaaaaaaaaaaaaaaaa'
        self.auth = {'Authorization': 'Bearer ' + self.token}
        self.client = create_app('https://updates.example.com', self.token, self.output).test_client()

    @staticmethod
    def request_data(tag='v2.9.2'):
        return {
            'tag': tag,
            'password': 'synthetic-password',
            'p12': (io.BytesIO(b'certificate fixture'), 'fixture.p12'),
            'provision': (io.BytesIO(b'profile fixture'), 'fixture.mobileprovision'),
        }

    def fake_release(self, tag, destination):
        with ZipFile(destination, 'w') as archive:
            archive.writestr('Payload/Feather.app/Info.plist', plistlib.dumps({
                'CFBundleIdentifier': BUNDLE_ID,
                'CFBundleShortVersionString': tag[1:],
                'CFBundleVersion': '7',
            }))

    def test_requires_authorization_and_stable_tag(self):
        with patch('app.fetch_release') as fetch:
            self.assertEqual(self.client.post('/v1/sign', data=self.request_data()).status_code, 401)
            self.assertEqual(self.client.post('/v1/sign', data=self.request_data('v2.9.2-beta'),
                                              headers=self.auth).status_code, 400)
            self.assertEqual(self.client.post('/v1/sign', data=self.request_data('https://example.org'),
                                              headers=self.auth).status_code, 400)
            fetch.assert_not_called()

    def test_signing_and_manifest_with_expiry(self):
        workspaces = []

        def fake_sign(signer, workspace, password):
            workspaces.append(workspace)
            self.assertEqual(password, 'synthetic-password')
            self.assertEqual((workspace / 'identity.p12').stat().st_mode & 0o777, 0o600)
            signed = workspace / 'signed.ipa'
            shutil.copy2(workspace / 'input.ipa', signed)
            return signed

        with patch('app.fetch_release', side_effect=self.fake_release), patch('app.sign_release', side_effect=fake_sign):
            response = self.client.post('/v1/sign', data=self.request_data(), headers=self.auth)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(workspaces and not workspaces[0].exists())
        url = response.json['manifest']
        self.assertEqual(urlsplit(url).netloc, 'updates.example.com')
        manifest_path = urlsplit(url).path
        manifest = self.client.get(manifest_path)
        self.assertEqual(manifest.status_code, 200)
        self.addCleanup(manifest.close)
        self.assertEqual(manifest.headers['Cache-Control'], 'private, no-store')
        item = plistlib.loads(manifest.data)['items'][0]
        self.assertEqual(item['metadata']['bundle-identifier'], BUNDLE_ID)
        self.assertEqual(item['metadata']['bundle-version'], '7')
        job = manifest_path.split('/')[2]
        self.assertEqual({file.name for file in (self.output / job).iterdir()}, {'Feather.ipa', 'manifest.plist'})
        self.assertEqual(self.client.get(f'/files/{job}/identity.p12').status_code, 404)
        with self.client.get(urlsplit(item['assets'][0]['url']).path) as payload:
            self.assertEqual(payload.status_code, 200)
        old = time.time() - TTL - 1
        os.utime(self.output / job, (old, old))
        self.assertEqual(self.client.get(manifest_path).status_code, 404)

    def test_bad_identity_is_rejected_and_failure_leaves_no_job(self):
        original = self.root / 'release.ipa'
        self.fake_release('v2.9.2', original)
        with self.assertRaises(ValueError):
            inspect_ipa(original, 'v2.9.3')
        with patch('app.fetch_release', side_effect=self.fake_release), patch('app.sign_release', side_effect=ValueError):
            response = self.client.post('/v1/sign', data=self.request_data(), headers=self.auth)
        self.assertEqual(response.status_code, 422)
        self.assertEqual(list(self.output.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
