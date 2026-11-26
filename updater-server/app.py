"""Hosted signing for published Feather releases, adapted from KorSign's updater."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener
from zipfile import BadZipFile, ZipFile

from flask import Flask, abort, jsonify, request, send_file

REPOSITORY = 'waruhachi/Feather'
BUNDLE_ID = 'thewonderofyou.Feather'
TAG = re.compile(r'v[0-9]+\.[0-9]+\.[0-9]+', re.ASCII)
JOB_ID = re.compile(r'[0-9a-f]{48}', re.ASCII)
MAX_IPA = 128 * 1024 * 1024
MAX_PROFILE = 2 * 1024 * 1024
MAX_P12 = 512 * 1024
TTL = 30 * 60
RELEASE_HOSTS = {
    'api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com',
}


class ReleaseRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urlsplit(newurl)
        if target.scheme != 'https' or target.hostname not in RELEASE_HOSTS:
            raise ValueError('unexpected release redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def release_urlopen(url, timeout):
    opener = build_opener(HTTPSHandler(), ReleaseRedirects())
    return opener.open(Request(url, headers={
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'Feather-Hosted-Updater',
    }), timeout=timeout)


def inspect_ipa(path, tag):
    with ZipFile(path) as archive:
        names = [entry for entry in archive.infolist()
                 if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', entry.filename)]
        if len(names) != 1 or names[0].file_size > 1024 * 1024:
            raise ValueError('invalid app metadata')
        if sum(entry.file_size for entry in archive.infolist()) > 1024**3:
            raise ValueError('unpacked release too large')
        info = plistlib.loads(archive.read(names[0]))
        if (not isinstance(info, dict) or info.get('CFBundleIdentifier') != BUNDLE_ID
                or info.get('CFBundleShortVersionString') != tag[1:]
                or not info.get('CFBundleVersion')):
            raise ValueError('unexpected release identity')
        return info


def fetch_release(tag, destination):
    with release_urlopen(f'https://api.github.com/repos/{REPOSITORY}/releases/tags/{tag}', 15) as response:
        raw = response.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError('release metadata too large')
    release = json.loads(raw)
    if release['draft'] or release['prerelease'] or release['tag_name'] != tag:
        raise ValueError('release unavailable')
    expected = f'https://github.com/{REPOSITORY}/releases/download/{tag}/Feather.ipa'
    asset = next((asset for asset in release['assets'] if asset.get('name') == 'Feather.ipa'), None)
    if not asset or asset.get('browser_download_url') != expected or not 0 < asset['size'] <= MAX_IPA:
        raise ValueError('release asset unavailable')

    size = 0
    digest = hashlib.sha256()
    deadline = time.monotonic() + 60
    with release_urlopen(expected, 20) as response, destination.open('xb') as output:
        while chunk := response.read(256 * 1024):
            size += len(chunk)
            if size > asset['size'] or time.monotonic() > deadline:
                raise ValueError('release download exceeded its budget')
            output.write(chunk)
            digest.update(chunk)
    if size != asset['size'] or (asset.get('digest') and asset['digest'] != 'sha256:' + digest.hexdigest()):
        raise ValueError('release failed integrity validation')
    inspect_ipa(destination, tag)


def save_credential(field, maximum_size, path):
    file = request.files.get(field)
    if file is None:
        raise ValueError('credential missing')
    data = file.stream.read(maximum_size + 1)
    if not 0 < len(data) <= maximum_size:
        raise ValueError('credential out of bounds')
    path.write_bytes(data)
    path.chmod(0o600)


def sign_release(signer, workspace, password):
    result = subprocess.run([
        signer, '-f', '-q', '-t', str(workspace), '-k', str(workspace / 'identity.p12'),
        '-p', password, '-m', str(workspace / 'profile.mobileprovision'),
        '-o', str(workspace / 'signed.ipa'), str(workspace / 'input.ipa'),
    ], cwd=workspace, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120, check=False)
    signed = workspace / 'signed.ipa'
    if result.returncode or not signed.is_file() or not 0 < signed.stat().st_size <= MAX_IPA:
        raise ValueError('signing failed')
    return signed


def cleanup(root):
    now = time.time()
    for job in root.iterdir():
        try:
            if JOB_ID.fullmatch(job.name) and job.is_dir() and now - job.stat().st_mtime >= TTL:
                shutil.rmtree(job)
        except FileNotFoundError:
            continue


def create_app(public_url=None, access_token=None, output=None, signer=None):
    public = (public_url or os.environ.get('FEATHER_PUBLIC_URL', '')).rstrip('/')
    secret = access_token or os.environ.get('FEATHER_SIGNING_TOKEN', '')
    base = urlsplit(public)
    if (base.scheme != 'https' or not base.hostname or base.username is not None
            or base.path or base.query or base.fragment):
        raise ValueError('FEATHER_PUBLIC_URL must be an HTTPS origin')
    if len(secret) < 32 or not secret.isascii() or any(char.isspace() for char in secret):
        raise ValueError('FEATHER_SIGNING_TOKEN must be an ASCII token of at least 32 characters')
    root = Path(output or os.environ.get('FEATHER_OUTPUT', '/var/lib/feather-updater')).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    executable = signer or os.environ.get('FEATHER_ZSIGN', '/usr/local/bin/zsign')
    lock = threading.Lock()
    app = Flask(__name__)
    app.config['MAX_CONTENT_LENGTH'] = MAX_P12 + MAX_PROFILE + 64 * 1024
    app.config['MAX_FORM_MEMORY_SIZE'] = 32 * 1024 * 1024
    app.config['MAX_FORM_PARTS'] = 4

    @app.get('/health')
    def health():
        return jsonify(status='ok')

    @app.post('/v1/sign')
    def sign():
        expected = ('Bearer ' + secret).encode()
        value = request.headers.get('Authorization', '').encode()
        if not hmac.compare_digest(value, expected):
            return jsonify(error='unauthorized'), 401
        if not lock.acquire(blocking=False):
            return jsonify(error='busy'), 409

        try:
            tag = request.form.get('tag', '')
            password = request.form.get('password', '')
            if not TAG.fullmatch(tag) or '\x00' in password or len(password.encode()) > 1024:
                return jsonify(error='invalid_request'), 400
            cleanup(root)
            if sum(1 for path in root.iterdir() if JOB_ID.fullmatch(path.name)) >= 10:
                return jsonify(error='busy'), 429

            with tempfile.TemporaryDirectory(prefix='feather-sign-') as temporary:
                work = Path(temporary)
                save_credential('p12', MAX_P12, work / 'identity.p12')
                save_credential('provision', MAX_PROFILE, work / 'profile.mobileprovision')
                fetch_release(tag, work / 'input.ipa')
                signed = sign_release(executable, work, password)
                metadata = inspect_ipa(signed, tag)
                job = secrets.token_hex(24)
                manifest = {'items': [{
                    'assets': [{'kind': 'software-package', 'url': f'{public}/files/{job}/Feather.ipa'}],
                    'metadata': {'bundle-identifier': BUNDLE_ID, 'bundle-version': str(metadata['CFBundleVersion']),
                                 'kind': 'software', 'title': 'Feather'},
                }]}
                with tempfile.TemporaryDirectory(prefix='.stage-', dir=root) as temporary_output:
                    stage = Path(temporary_output) / 'result'
                    stage.mkdir(mode=0o700)
                    shutil.move(signed, stage / 'Feather.ipa')
                    (stage / 'manifest.plist').write_bytes(plistlib.dumps(manifest))
                    stage.rename(root / job)
            return jsonify(manifest=f'{public}/files/{job}/manifest.plist')
        except HTTPError as error:
            return jsonify(error='release_unavailable'), 404 if error.code == 404 else 502
        except (OSError, URLError, ValueError, TypeError, KeyError, BadZipFile, subprocess.TimeoutExpired):
            return jsonify(error='signing_failed'), 422
        finally:
            lock.release()

    @app.get('/files/<job>/<filename>')
    def download(job, filename):
        if not JOB_ID.fullmatch(job) or filename not in ('Feather.ipa', 'manifest.plist'):
            abort(404)
        path = root / job / filename
        if not path.is_file() or time.time() - path.parent.stat().st_mtime >= TTL:
            abort(404)
        response = send_file(path, conditional=True, mimetype=(
            'application/xml' if filename == 'manifest.plist' else 'application/octet-stream'
        ))
        response.headers['Cache-Control'] = 'private, no-store'
        return response

    return app


if __name__ == '__main__':
    import sys
    if sys.argv[1:] != ['cleanup']:
        raise SystemExit('Usage: python app.py cleanup')
    cleanup(Path(os.environ.get('FEATHER_OUTPUT', '/var/lib/feather-updater')))
