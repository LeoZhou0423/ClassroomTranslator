#!/usr/bin/env python3
"""Minimal SSH helper for the training box (paramiko).

Credentials come from environment variables — never hardcode secrets.
  export TRAIN_SSH_HOST=... TRAIN_SSH_PORT=... TRAIN_SSH_USER=... TRAIN_SSH_PASSWORD=...
"""
from __future__ import annotations

import argparse
import os
import sys

import paramiko


def _require(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing env {name}")
    return value


def run(cmd: str, timeout: int = 120) -> tuple[int, str, str]:
    host = _require("TRAIN_SSH_HOST")
    port = int(os.environ.get("TRAIN_SSH_PORT", "22"))
    user = _require("TRAIN_SSH_USER")
    password = _require("TRAIN_SSH_PASSWORD")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(host, port=port, username=user, password=password, timeout=30)
    try:
        stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        code = stdout.channel.recv_exit_status()
        return code, out, err
    finally:
        client.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", nargs="?", default="uname -a; nvidia-smi | head -20; python3 --version; df -h / | tail -1")
    args = ap.parse_args()
    code, out, err = run(args.cmd)
    sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
