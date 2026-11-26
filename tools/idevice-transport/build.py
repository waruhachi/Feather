"""Build KorSign's iPhone transport from the same idevice revision Feather pins."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

VERSION = 'v0.1.68'
REVISION = 'd32c8189c51c2789496b0768039419c3705498c3'
ORIGIN = 'https://github.com/jkcoxson/idevice.git'
BASE_SHA = 'c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7'
PATCHES = Path(__file__).resolve().parent
EXPECTED = {'ffi/src/tunnel_provider.rs', 'idevice/src/remote_pairing/tls_psk.rs'}


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def output(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def build(cache):
    cache.mkdir(parents=True, exist_ok=True)
    source = cache / f'source-{VERSION}'
    if not source.exists():
        with tempfile.TemporaryDirectory(dir=cache) as stage:
            checkout = Path(stage) / 'source'
            run('git', 'clone', '--depth', '1', '--branch', VERSION, ORIGIN, checkout)
            checkout.rename(source)

    if output('git', 'rev-parse', 'HEAD', cwd=source) != REVISION:
        raise SystemExit('Unexpected idevice source revision')
    patch = PATCHES / 'transport.patch'
    if subprocess.run(
        ('git', 'apply', '--reverse', '--check', patch), cwd=source, capture_output=True
    ).returncode:
        run('git', 'apply', '--check', patch, cwd=source)
        run('git', 'apply', patch, cwd=source)
    if set(output('git', 'diff', '--name-only', cwd=source).splitlines()) != EXPECTED:
        raise SystemExit('Unexpected changes in the idevice transport source')

    rust = ('rustup', 'run', 'stable', 'cargo')
    mac_sdk = output('xcrun', '--sdk', 'macosx', '--show-sdk-path')
    run(*rust, 'test', '--locked', '-p', 'idevice', '--lib', '--features', 'full', 'write_tests',
        cwd=source, env=dict(os.environ, SDKROOT=mac_sdk))
    sdk = output('xcrun', '--sdk', 'iphoneos', '--show-sdk-path')
    # Emit native objects so Xcode does not have to read Rust's LLVM bitcode.
    env = dict(
        os.environ,
        SDKROOT=sdk,
        BINDGEN_EXTRA_CLANG_ARGS='--sysroot=' + sdk,
        IPHONEOS_DEPLOYMENT_TARGET='16.0',
        CARGO_PROFILE_RELEASE_LTO='off',
        CARGO_PROFILE_RELEASE_CODEGEN_UNITS='16',
    )
    run(*rust, 'build', '--locked', '--release', '--target', 'aarch64-apple-ios', '-p', 'idevice-ffi',
        cwd=source, env=env)
    artifact = source / 'target/aarch64-apple-ios/release/libidevice_ffi.a'
    run('xcrun', 'lipo', artifact, '-verify_arch', 'arm64')
    (cache / VERSION).mkdir(exist_ok=True)
    shutil.copy2(artifact, cache / VERSION / artifact.name)


def install(cache, derived_data):
    path = derived_data / 'SourcePackages/artifacts/idevicekitten/IDevice/IDevice.xcframework'
    library = path / 'ios-arm64/libidevice_ffi.a'
    if not library.is_file() or not (path / 'ios-arm64/Headers/idevice.h').is_file():
        raise SystemExit('Resolve Feather’s pinned Swift packages before installing the transport')
    artifact = cache / VERSION / library.name
    if not artifact.is_file():
        raise SystemExit('Build the transport before installing it')
    state = derived_data / 'SourcePackages/workspace-state.json'
    if not state.is_file() or BASE_SHA not in state.read_text():
        raise SystemExit('The resolved iDevice XCFramework does not match the expected checksum')
    def digest(file):
        with file.open('rb') as source:
            return hashlib.file_digest(source, 'sha256').digest()

    if digest(artifact) == digest(library):
        return
    with tempfile.NamedTemporaryFile(dir=library.parent) as stage:
        temp = Path(stage.name).with_suffix('.a')
        try:
            shutil.copy2(artifact, temp)
            temp.replace(library)
        finally:
            temp.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--install-in', type=Path)
    args = parser.parse_args()
    if args.install_in:
        install(args.cache, args.install_in)
    else:
        build(args.cache)
