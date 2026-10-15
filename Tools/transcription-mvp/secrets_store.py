"""Runtime access to the encrypted provider credentials.

Resolution order for every provider key:

1. ``LINGOCLASS_<PROVIDER>_KEY`` environment variable (CI, power users).
2. The OS credential store, where a key the user typed into Settings is kept.
3. The encrypted repository document ``secrets/keys.enc.json``, fetched from
   GitHub at startup so a burned credential can be revoked for every install at
   once, with the copy bundled inside the installer as an offline fallback.

Nothing in step 3 is plaintext on disk: the passphrase is split across
:mod:`secrets_shares`, the AES key comes from scrypt, and the result is cached in
the OS credential store rather than in a file this project controls.
"""
import base64
import json
import os
import sys
import threading
import time
from pathlib import Path

import secrets_crypto

REPO_SLUG = os.getenv('LINGOCLASS_SECRETS_REPO', 'LeoZhou0423/ClassroomTranslator')
DEFAULT_REF = os.getenv('LINGOCLASS_SECRETS_REF', 'codex/shared-macos-package')
REMOTE_TIMEOUT = (5, 12)
CACHE_NAME = 'secrets-cache.json'
KEYRING_SERVICE = 'LingoClass'
SHARE_QUORUM = 3

PROVIDER_ALIASES = {
    'bigmodel': ('bigmodel', 'glm', 'zhipu'),
    'mimo': ('mimo', 'xiaomimimo'),
    'qwen': ('qwen', 'dashscope'),
}

_lock = threading.Lock()
_cache = {}
_keyring_cache = {}
_keyring_lock = threading.Lock()
_cache_path = Path(__file__).resolve().parent / CACHE_NAME
_state = {'loaded': False, 'epoch': 0, 'source': None, 'error': None}


class CredentialError(RuntimeError):
    pass


# --------------------------------------------------------------------------
# Tamper resistance
# --------------------------------------------------------------------------
def _debugger_attached():
    """True when a tracer is attached to this process."""
    try:
        if sys.gettrace() is not None:
            return True
    except Exception:
        pass
    if sys.platform.startswith('win'):
        try:
            import ctypes
            if ctypes.windll.kernel32.IsDebuggerPresent():
                return True
            # PEB.BeingDebugged survives a patched IsDebuggerPresent.
            being_debugged = ctypes.c_int32(0)
            ctypes.windll.kernel32.CheckRemoteDebuggerPresent(
                ctypes.windll.kernel32.GetCurrentProcess(), ctypes.byref(being_debugged))
            return bool(being_debugged.value)
        except Exception:
            return False
    if sys.platform == 'darwin':
        try:
            import ctypes
            libc = ctypes.CDLL('libc.dylib', use_errno=True)
            libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint,
                                    ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), None, ctypes.c_size_t]
            request = (ctypes.c_int * 4)(1, 14, 1, 0)  # CTL_KERN, KERN_PROC, KERN_PROC_PID, 0
            size = ctypes.c_size_t(0)
            if libc.sysctl(request, 4, None, ctypes.byref(size), None, 0) == 0 and size.value:
                buffer = ctypes.create_string_buffer(size.value)
                if libc.sysctl(request, 4, buffer, ctypes.byref(size), None, 0) == 0:
                    # struct kinfo_proc: kp_proc.p_flag sits at a fixed offset on
                    # both arm64 and x86_64 for the 64-bit layout.
                    return bool(buffer.raw[24] & 0x00000800)  # P_TRACED
        except Exception:
            return False
    return False


def _library_injected():
    """True when a preloaded library could be intercepting our TLS calls."""
    for variable in ('LD_PRELOAD', 'DYLD_INSERT_LIBRARIES'):
        if os.environ.get(variable):
            return True
    return False


def _tamper_detected():
    if os.getenv('LINGOCLASS_ALLOW_DEBUG') == '1':
        return False
    return _debugger_attached() or _library_injected()


# --------------------------------------------------------------------------
# Passphrase reconstruction
# --------------------------------------------------------------------------
def _reconstruct_passphrase():
    try:
        import secrets_shares
    except Exception as error:  # pragma: no cover - build packaging fault
        raise CredentialError('credential shares are missing: %s' % error)
    shares = secrets_shares.unmasked_shares()
    if len(shares) < SHARE_QUORUM:
        raise CredentialError('insufficient credential shares')
    passphrase = secrets_crypto.combine_shares(shares[:SHARE_QUORUM], minimum=SHARE_QUORUM)
    if not passphrase:
        raise CredentialError('credential passphrase reconstructed empty')
    return bytearray(passphrase)


# --------------------------------------------------------------------------
# Document retrieval
# --------------------------------------------------------------------------
def _remote_url(reference):
    return 'https://raw.githubusercontent.com/%s/%s/secrets/keys.enc.json' % (REPO_SLUG, reference)


def _fetch_remote(reference):
    import requests
    response = requests.get(_remote_url(reference), timeout=REMOTE_TIMEOUT,
                            headers={'Cache-Control': 'no-cache', 'Pragma': 'no-cache'})
    if response.status_code != 200:
        raise CredentialError('remote credential document unavailable (HTTP %s)' % response.status_code)
    return json.loads(response.text)


def _bundled_document():
    for directory in (Path(__file__).resolve().parent / 'secrets', Path(__file__).resolve().parent):
        candidate = directory / 'keys.enc.json'
        if candidate.is_file():
            try:
                return json.loads(candidate.read_text(encoding='utf-8'))
            except (OSError, ValueError) as error:
                raise CredentialError('bundled credential document unreadable: %s' % error)
    raise CredentialError('no bundled credential document')


def _read_cache():
    try:
        return json.loads(_cache_path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None


def _write_cache(document):
    """Keep only the sealed document. The decrypted keys never touch the disk."""
    try:
        temporary = _cache_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(document), encoding='utf-8')
        temporary.replace(_cache_path)
    except OSError:
        pass


def _newer(candidate, current):
    if not current:
        return True
    return int(candidate.get('epoch', 0)) > int(current.get('epoch', 0))


def _load_document(allow_remote=True):
    reference = os.getenv('LINGOCLASS_SECRETS_REF', DEFAULT_REF)
    cached = _read_cache()
    document = None
    if allow_remote and not _tamper_detected():
        try:
            remote = _fetch_remote(reference)
            if _newer(remote, cached):
                document = remote
                _write_cache(remote)
        except Exception:
            document = None
    if document is None:
        document = cached if _newer(cached, None) else None
    if document is None:
        document = _bundled_document()
    return document


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------
def load(refresh=False, allow_remote=True):
    """Decrypt and return the credential mapping, or raise :class:`CredentialError`."""
    with _lock:
        if _cache.get('credentials') and not refresh:
            return _cache['credentials']
        passphrase = _reconstruct_passphrase()
        try:
            document = _load_document(allow_remote=allow_remote)
            payload, epoch = secrets_crypto.open_document(document, bytes(passphrase))
        finally:
            for index in range(len(passphrase)):
                passphrase[index] = 0
        try:
            credentials = json.loads(payload.decode('utf-8'))
        except ValueError as error:
            raise CredentialError('decrypted payload is not valid JSON: %s' % error)
        if not isinstance(credentials, dict):
            raise CredentialError('decrypted payload is not a mapping')
        _cache['credentials'] = credentials
        _cache['epoch'] = epoch
        _cache['source'] = document.get('source', 'repository')
        _state.update(loaded=True, epoch=epoch, error=None)
        return credentials


def state():
    with _lock:
        return dict(_state)


def _canonical(name):
    name = (name or '').strip().lower()
    for canonical, aliases in PROVIDER_ALIASES.items():
        if name in aliases:
            return canonical
    return name


def _from_environment(name):
    for alias in PROVIDER_ALIASES.get(name, (name,)):
        for form in (alias.upper(), alias.upper().replace('-', '_')):
            value = os.getenv('LINGOCLASS_%s_KEY' % form) or os.getenv('%s_API_KEY' % form)
            if value:
                return value.strip()
    return ''


def _from_keyring(name):
    # Status polling must never repeatedly prompt for Keychain authorization.
    # Cache missing/denied results too; retry only after an explicit refresh.
    with _keyring_lock:
        if name in _keyring_cache:
            return _keyring_cache[name]
        value = ''
        try:
            import keyring
            for alias in PROVIDER_ALIASES.get(name, (name,)):
                candidate = keyring.get_password(KEYRING_SERVICE, '%s-api-key' % alias)
                if candidate:
                    value = candidate.strip()
                    break
        except Exception:
            pass
        _keyring_cache[name] = value
        return value


def provider_key(name, refresh=False):
    """Resolve one provider's key, or an empty string when nothing is configured."""
    canonical = _canonical(name)
    if not canonical:
        return ''
    source = _from_environment(canonical)
    if source:
        return source
    if refresh:
        with _keyring_lock:
            _keyring_cache.pop(canonical, None)
    source = _from_keyring(canonical)
    if source:
        return source
    try:
        credentials = load(refresh=refresh)
    except Exception:
        return ''
    for alias in PROVIDER_ALIASES.get(canonical, (canonical,)):
        value = credentials.get(alias)
        if value:
            return str(value).strip()
    return ''


def configured_providers():
    """Names of providers that resolve to a key right now."""
    names = []
    for canonical in PROVIDER_ALIASES:
        if provider_key(canonical):
            names.append(canonical)
    return names


def persist_to_keyring(name, key):
    """Cache a decrypted key in the OS credential store so scrypt runs once."""
    try:
        import keyring
        keyring.set_password(KEYRING_SERVICE, '%s-api-key' % _canonical(name), key)
        with _keyring_lock:
            _keyring_cache[_canonical(name)] = key.strip()
        return True
    except Exception:
        return False


def epoch():
    return _state.get('epoch', 0)


def last_error():
    return _state.get('error')
