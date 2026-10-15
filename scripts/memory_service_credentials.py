"""Private, machine-local Hindsight credential; never placed in workspace data."""
import os
from pathlib import Path
import re
import secrets
import stat


STORAGE_ID_CHARACTERS = "abcdefghijklmnopqrstuvwxyz0123456789-"


def valid_storage_id(value):
    return bool(value) and all(c in STORAGE_ID_CHARACTERS for c in value)


def private_directory(path, create=False, forbidden=0o077, repair=True):
    """Require a real directory owned by this account without the `forbidden` permission bits.

    Unlike mkdir(mode=...), this also covers a directory that already exists. Bits are cleared
    (through the opened descriptor, so a swapped path cannot redirect it) when this account
    owns the directory; a directory owned by anyone else is always refused.
    """
    path = Path(path)
    if create:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        raise
    except OSError as error:
        raise RuntimeError(f"{path} must be a real directory (not a symbolic link): {error.strerror}") from error
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid():
            raise RuntimeError(f"{path} must be owned by this account")
        if info.st_mode & forbidden:
            if not repair:
                raise RuntimeError(f"{path} has unsafe permissions; restrict it to this account")
            os.fchmod(fd, stat.S_IMODE(info.st_mode) & ~forbidden)
    finally:
        os.close(fd)


def private_file(path, missing_ok=False):
    """Require a regular file owned by this account; clear group/world access when needed."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        if missing_ok:
            return
        raise
    except OSError as error:
        raise RuntimeError(f"{path} must be a regular file (not a symbolic link): {error.strerror}") from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise RuntimeError(f"{path} must be a regular file owned by this account")
        if info.st_mode & 0o077:
            os.fchmod(fd, stat.S_IMODE(info.st_mode) & ~0o077)
    finally:
        os.close(fd)


def secure_pg0(storage_id=None, root=None):
    """Keep pg0's state (instance.json holds the PostgreSQL password in plaintext) private.

    Enforces 0700 on ~/.pg0, its instances directory and each instance directory, and 0600 on
    each instance.json; refuses anything not owned by this account or reached through a symlink.
    Pass `storage_id` to limit the walk to one instance.

    What this cannot do: pg0 is configured only through the pg0://<name> URL Hindsight receives,
    so these scripts cannot change its pg_hba.conf (a loopback `password` rule, i.e. cleartext
    auth over 127.0.0.1) or listen_addresses, nor move it to a Unix socket. Filesystem privacy of
    the credential is the control available here; loopback TCP stays reachable by other local users.
    """
    root = Path(root) if root else Path.home() / ".pg0"
    private_directory(root, create=True)
    instances = root / "instances"
    try:
        private_directory(instances)
    except FileNotFoundError:
        return
    if storage_id is not None and not valid_storage_id(storage_id):
        raise RuntimeError("Invalid storage instance identifier")
    names = [storage_id] if storage_id else sorted(entry.name for entry in instances.iterdir())
    for name in names:
        directory = instances / name
        try:
            if stat.S_ISREG(directory.lstat().st_mode):
                continue  # stray file such as .DS_Store
            private_directory(directory)
        except FileNotFoundError:
            continue
        private_file(directory / "instance.json", missing_ok=True)


def api_token():
    directory = Path.home() / "Library/Application Support/Facienda/memory-service"
    private_directory(directory, create=True)
    path = directory / "api-token"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(fd, "w") as stream:
            stream.write(secrets.token_urlsafe(48))
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, "r") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or not 32 <= info.st_size <= 257:
            raise RuntimeError("Memory credential must be a private file owned by this account")
        token = stream.read(258).strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        raise RuntimeError("Invalid memory service credential")
    return token
