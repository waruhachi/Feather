# Feather hosted updates

The iOS app’s **Settings → Feather Updates** screen can send a selected signing identity to a server you operate. The server signs only stable `Feather.ipa` assets published by `waruhachi/Feather`. It checks the bundle ID and version before and after signing. The app creates the iOS install link from the returned manifest.

## Run the service

Install Python 3.11+ and build KorSign’s pinned server signer with the included patch. The patch makes the CLI exit unsuccessfully if it cannot write a CMS signature. On Linux, install a C++ compiler, `make`, `pkg-config`, and the OpenSSL development headers, then run the following from this directory.

```sh
git clone https://github.com/korboybeats/Zsign-Package.git /tmp/feather-server-zsign
git -C /tmp/feather-server-zsign checkout --detach df9370f482f7b9f77dab94bbcf80093c24a9c223
git -C /tmp/feather-server-zsign apply --unidiff-zero "$PWD/zsign-cms-failure.patch"
make -C /tmp/feather-server-zsign/build/linux VERSION=df9370f-cms-guard
```

Set `FEATHER_ZSIGN` to the resulting `bin/zsign` executable. Run under a dedicated unprivileged account behind an HTTPS reverse proxy. Make the output directory writable by that account and keep the proxy’s body limit at or below 3 MB. Configure the service environment without saving secrets in the repository.

| Environment variable | Value |
| --- | --- |
| `FEATHER_PUBLIC_URL` | The service’s public HTTPS origin |
| `FEATHER_SIGNING_TOKEN` | A random ASCII bearer token of at least 32 characters |
| `FEATHER_OUTPUT` | Private output directory, defaults to `/var/lib/feather-updater` |
| `FEATHER_ZSIGN` | Path to the signer, defaults to `/usr/local/bin/zsign` |

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
gunicorn --bind 127.0.0.1:8080 --workers 1 --threads 4 --timeout 240 'app:create_app()'
```

Allow `GET /health`, `POST /v1/sign`, and `GET /files/…` through the reverse proxy. Use one worker to keep the signing lock and job limits shared. Disable request body logging and redact the random install-link path in access logs. Use `python app.py cleanup` from the same environment to remove expired outputs during quiet periods. Signed packages and manifests expire after 30 minutes. The submitted certificate, profile, and password are used for the request only. The signer receives the password as a local process argument, so restrict process visibility and access to the signing account.

In Feather, enter the same HTTPS origin and access token, choose the certificate used to sign the installed copy, and confirm the credential upload when signing an update. The built-in update service is for the standard Feather bundle identifier, `thewonderofyou.Feather`. GitHub draft releases are unavailable until published.

The server protocol and CMS patch are adapted from [KorSign 3.0.1 Revision 1](https://github.com/korboybeats/KorSign/tree/v3.0.1-r1).
