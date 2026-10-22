"""Crash-safe JSON persistence. Corrupt files are reported, never silently reset."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any

from app_errors import AppError


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise AppError(
            "DATA_CORRUPT",
            f"记录文件 {path.name} 损坏，已保留原文件。请从备份恢复或联系支持。",
            500,
        ) from error


def atomic_write_json(path: Path, value: Any, *, durable: bool = False) -> None:
    """Replace only a fully written temporary file on the same filesystem."""
    content = json.dumps(value, ensure_ascii=False, indent=2)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            if durable:
                os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
