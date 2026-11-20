"""Local per-user pairing state shared by source launchers and the Mac app."""
import os
from pathlib import Path
import secrets


def state_directory():
    default = Path.home() / 'Library/Application Support/WatchSteer'
    folder = Path(os.environ.get('WATCHSTEER_STATE_DIR', default)).expanduser()
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder.chmod(0o700)
    return folder


def pairing_token():
    path = state_directory() / 'pairing-token'
    supplied = os.environ.get('WATCHSTEER_TOKEN')
    token = supplied if supplied is not None else path.read_text().strip() if path.exists() else secrets.token_urlsafe(32)
    if len(token) < 24 or not token.isascii():
        raise ValueError('Invalid pairing token; use at least 24 random ASCII characters')
    if not path.exists():
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as handle:
            handle.write(token + '\n')
    path.chmod(0o600)
    return token
