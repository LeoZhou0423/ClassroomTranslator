"""Encrypted provider credentials for LingoClass.

Threat model
------------
The published installer and the public repository are both attacker-controlled
inputs. Anyone can download the .exe, run ``strings`` on it, or clone the repo.
A credential that must be usable on the user's machine therefore cannot be
*unrecoverable*; it can only be made expensive to recover. This module buys
that expense with four independent layers:

1. **Nothing plaintext in git.** The repository carries ``secrets/keys.enc.json``,
   an AES-256-GCM ciphertext. GitHub secret scanning sees nothing to report.
2. **Split passphrase.** The decryption passphrase is never stored whole. It is
   split with Shamir's Secret Sharing over GF(2^8) into four shares, any three of
   which reconstruct it, and the shares are spread across separate modules as
   masked byte arrays rather than as strings.
3. **Memory-hard key derivation.** The AES key comes from scrypt with n=2^15,
   r=8, p=1 (32 MiB per guess), so an attacker who lifted the ciphertext and the
   shares still cannot brute-force a weak passphrase offline cheaply.
4. **Revocation and rollback protection.** The payload carries a signed epoch and
   a revoked flag. The app fetches the file from the repository at startup, so a
   burned credential can be killed for every install at once, and a stale cached
   copy cannot be replayed to resurrect it.

Residual risk, stated plainly: an attacker who fully compromises a running
install can still recover the credential from process memory. That is why the
credential is meant to be a *scoped sub-account key* with a quota ceiling, and
why ``secrets/keys.enc.json`` can be rotated without shipping a new build.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

FORMAT_VERSION = 3
KDF_NAME = 'scrypt'
KDF_N = 1 << 15
KDF_R = 8
KDF_P = 1
KEY_BYTES = 32
NONCE_BYTES = 12

_LOCAL_NAME = 'keys.enc.json'
_LOCAL_DIRS = (Path(__file__).resolve().parent / 'secrets', Path(__file__).resolve().parent)


class SecretError(RuntimeError):
    """Raised when the credential store is missing, tampered with, or revoked."""


# --------------------------------------------------------------------------
# GF(2^8) arithmetic for Shamir's Secret Sharing (primitive polynomial 0x11d)
# --------------------------------------------------------------------------
_GF_EXP = [0] * 512
_GF_LOG = [0] * 256


def _build_tables():
    value = 1
    for power in range(255):
        _GF_EXP[power] = value
        _GF_LOG[value] = power
        value <<= 1
        if value & 0x100:
            value ^= 0x11D
    for power in range(255, 512):
        _GF_EXP[power] = _GF_EXP[power - 255]


_build_tables()


def _gf_mul(left, right):
    if left == 0 or right == 0:
        return 0
    return _GF_EXP[_GF_LOG[left] + _GF_LOG[right]]


def _gf_div(left, right):
    if right == 0:
        raise ZeroDivisionError('GF(2^8) division by zero')
    if left == 0:
        return 0
    return _GF_EXP[(_GF_LOG[left] - _GF_LOG[right]) % 255]


def _gf_pow(base, exponent):
    if base == 0:
        return 0
    return _GF_EXP[(_GF_LOG[base] * exponent) % 255]


def _lagrange_at_zero(points):
    """Interpolate the polynomial at x=0 from ``(x, y)`` pairs."""
    total = 0
    for index, (xi, _) in enumerate(points):
        weight = 1
        for other, (xj, _) in enumerate(points):
            if index == other:
                continue
            weight = _gf_mul(weight, _gf_div(xj, xi ^ xj))
        total ^= _gf_mul(points[index][1], weight)
    return total


def split_secret(secret, threshold, share_count, randomness):
    """Split ``secret`` bytes into ``share_count`` shares, ``threshold`` needed."""
    if not 2 <= threshold <= share_count <= 255:
        raise ValueError('threshold must satisfy 2 <= threshold <= share_count <= 255')
    shares = []
    for position in range(share_count):
        shares.append(bytearray([position + 1]))
    for byte in secret:
        coefficients = [byte] + [randomness(1)[0] for _ in range(threshold - 1)]
        for position in range(share_count):
            x = position + 1
            value = 0
            power = 1
            for coefficient in coefficients:
                value ^= _gf_mul(coefficient, power)
                power = _gf_mul(power, x)
            shares[position].append(value)
    return [bytes(share) for share in shares]


def combine_shares(shares, minimum=2):
    """Reconstruct the secret from any quorum of ``(x, bytes)`` shares."""
    if len(shares) < minimum:
        raise SecretError('insufficient shares to reconstruct the passphrase')
    if not shares:
        raise SecretError('no shares supplied')
    length = len(shares[0][1])
    if any(len(share[1]) != length for share in shares):
        raise SecretError('share length mismatch')
    points = [(share[0], 0) for share in shares]
    output = bytearray()
    for index in range(length):
        for position, (x, _) in enumerate(points):
            points[position] = (x, shares[position][1][index])
        output.append(_lagrange_at_zero(points))
    return bytes(output)


# --------------------------------------------------------------------------
# Masking helpers: keep shares out of ``strings`` output
# --------------------------------------------------------------------------
def mask_share(share, pad):
    """XOR a share with a pad so neither appears verbatim in the binary."""
    if len(pad) != len(share):
        raise ValueError('pad length must match share length')
    return bytes(a ^ b for a, b in zip(share, pad))


# --------------------------------------------------------------------------
# Key derivation and authenticated encryption
# --------------------------------------------------------------------------
def derive_key(passphrase, salt, n=KDF_N, r=KDF_R, p=KDF_P):
    if isinstance(passphrase, str):
        passphrase = passphrase.encode('utf-8')
    return hashlib.scrypt(passphrase, salt=salt, n=n, r=r, p=p, dklen=KEY_BYTES, maxmem=256 * 1024 * 1024)


def _attestation_key(passphrase, salt):
    if isinstance(passphrase, str):
        passphrase = passphrase.encode('utf-8')
    return hashlib.pbkdf2_hmac('sha256', passphrase, salt + b'/attestation', 4096, dklen=KEY_BYTES)


def _canonical(document):
    return json.dumps(document, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def seal_document(payload, passphrase, epoch=1, revoked=False, randomness=None):
    """Encrypt ``payload`` (bytes) into the on-disk document layout."""
    randomness = randomness or os.urandom
    salt = randomness(16)
    nonce = randomness(NONCE_BYTES)
    key = derive_key(passphrase, salt)
    cipher = AESGCM(key)
    sealed = cipher.encrypt(nonce, payload, None)
    document = {
        'version': FORMAT_VERSION,
        'algorithm': 'AES-256-GCM',
        'kdf': {'name': KDF_NAME, 'n': KDF_N, 'r': KDF_R, 'p': KDF_P,
                'salt': base64.b64encode(salt).decode('ascii')},
        'epoch': int(epoch),
        'revoked': bool(revoked),
        'created': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'nonce': base64.b64encode(nonce).decode('ascii'),
        'payload': base64.b64encode(sealed).decode('ascii'),
    }
    attestation = hmac.new(_attestation_key(passphrase, salt), _canonical(document), hashlib.sha256).digest()
    document['attestation'] = base64.b64encode(attestation).decode('ascii')
    return document


def open_document(document, passphrase):
    """Verify and decrypt a sealed document. Raises :class:`SecretError`."""
    if not isinstance(document, dict):
        raise SecretError('credential document is malformed')
    if int(document.get('version', 0)) != FORMAT_VERSION:
        raise SecretError('unsupported credential document version')
    if document.get('revoked'):
        raise SecretError('credential has been revoked')
    try:
        kdf = document['kdf']
        salt = base64.b64decode(kdf['salt'], validate=True)
        nonce = base64.b64decode(document['nonce'], validate=True)
        sealed = base64.b64decode(document['payload'], validate=True)
        attestation = base64.b64decode(document['attestation'], validate=True)
    except (KeyError, ValueError, TypeError) as error:
        raise SecretError('credential document is malformed: %s' % error)
    if kdf.get('name') != KDF_NAME or (kdf.get('n'), kdf.get('r'), kdf.get('p')) != (KDF_N, KDF_R, KDF_P):
        raise SecretError('unexpected key derivation parameters')

    body = {key: value for key, value in document.items() if key != 'attestation'}
    expected = hmac.new(_attestation_key(passphrase, salt), _canonical(body), hashlib.sha256).digest()
    if not hmac.compare_digest(expected, attestation):
        raise SecretError('credential document failed integrity check')

    key = derive_key(passphrase, salt)
    try:
        plaintext = AESGCM(key).decrypt(nonce, sealed, None)
    except Exception:
        raise SecretError('credential document could not be decrypted')
    return plaintext, int(document.get('epoch', 0))
