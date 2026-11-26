# Adapted from KorSign’s build-time TLS refresh (GPL-3.0).
"""Refresh build-time TLS resources without discarding the working set (macOS)."""
import argparse
import ctypes
import json
import os
import re
import ssl
import subprocess
import tempfile
from pathlib import Path


def replace_directory(candidate, destination):
    if destination.is_symlink():
        raise ValueError('Dependency directory must not be a symlink')
    if not destination.exists():
        candidate.rename(destination)
        return
    # macOS atomic directory exchange: never expose a missing or half-updated set.
    rename = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(candidate), os.fsencode(destination), 0x00000002):  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    # The previous directory is now at candidate and is cleaned with the staging tree.


def refresh(url, destination):
    destination = destination.absolute()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.feather-tls-', dir=destination.parent) as directory:
        work = Path(directory)
        pack = work / 'pack.json'
        subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location',
                        '--proto', '=https', '--proto-redir', '=https', '--max-time', '60',
                        '--output', str(pack), url], check=True)
        data = json.loads(pack.read_text())
        cert, ca, key1, key2 = (data[name] for name in ('cert', 'ca', 'key1', 'key2'))
        hostname = data['info']['domains']['commonName']
        if not all(isinstance(value, str) and value.strip()
                   for value in (cert, ca, key1, key2, hostname)):
            raise ValueError('Missing certificate pack fields')
        hostname = hostname.strip()
        if not re.fullmatch(r'(?:\*\.)?[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', hostname):
            raise ValueError('Invalid certificate hostname')
        candidate = work / 'deps'
        candidate.mkdir()
        (candidate / 'server.crt').write_text(cert.rstrip() + '\n' + ca.rstrip() + '\n')
        (candidate / 'server.pem').write_text(key1 + key2)
        (candidate / 'server.pem').chmod(0o600)
        (candidate / 'commonName.txt').write_text(hostname + '\n')
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        # Parse both fields separately so a valid CA cannot hide a broken leaf.
        context.load_verify_locations(cadata=cert)
        context.load_verify_locations(cadata=ca)
        subprocess.run(['openssl', 'x509', '-in', str(candidate / 'server.crt'),
                        '-noout', '-checkend', '0'], check=True)
        context.load_cert_chain(candidate / 'server.crt', candidate / 'server.pem', password=lambda: '')
        replace_directory(candidate, destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    refresh(args.url, args.output)
    print('Server dependencies validated and replaced')
