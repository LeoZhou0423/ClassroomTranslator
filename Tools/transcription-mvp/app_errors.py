"""Stable application errors shared by HTTP, storage, and background tasks."""

from __future__ import annotations

import errno
import json
import logging
import traceback
import uuid
from dataclasses import dataclass

import requests

LOGGER = logging.getLogger("lingoclass")


@dataclass
class AppError(Exception):
    """An actionable, public error; internal exception messages stay private."""

    code: str
    message: str
    status: int = 400
    retryable: bool = False

    def __str__(self) -> str:
        return self.message


def classify_error(error: Exception) -> AppError:
    """Translate implementation failures without leaking paths, keys, or payloads."""
    if isinstance(error, AppError):
        return error
    if isinstance(error, (TimeoutError, requests.Timeout)):
        return AppError("DEADLINE_EXCEEDED", "处理超时，请检查任务状态后重试。", 504, True)
    if isinstance(error, requests.RequestException):
        return AppError("SERVICE_UNAVAILABLE", "暂时无法连接服务，请检查网络后重试。", 503, True)
    if isinstance(error, PermissionError):
        return AppError(
            "STORAGE_PERMISSION_DENIED", "无法保存文件，请检查文件夹权限或选择其他位置。", 500
        )
    if isinstance(error, FileNotFoundError):
        return AppError("NOT_FOUND", "所需文件或课堂记录不存在，请刷新后重试。", 404)
    if isinstance(error, OSError):
        if error.errno == errno.ENOSPC:
            return AppError("STORAGE_FULL", "磁盘空间不足，请释放空间后重试。", 507)
        return AppError(
            "STORAGE_UNAVAILABLE", "读写文件失败，原有内容已保留，请检查磁盘后重试。", 500, True
        )
    if isinstance(error, (json.JSONDecodeError, UnicodeDecodeError)):
        return AppError("INVALID_ARGUMENT", "请求格式无效，请刷新页面后重试。")
    if isinstance(error, KeyError):
        return AppError("INVALID_ARGUMENT", "请求缺少必要信息，请刷新页面后重试。")
    if isinstance(error, (TypeError, ValueError)):
        # ValueErrors raised deliberately by domain validation have useful public text.
        message = (
            str(error)
            if isinstance(error, ValueError)
            and any("\u4e00" <= char <= "\u9fff" for char in str(error))
            else "请求参数无效，请检查输入后重试。"
        )
        return AppError(getattr(error, "code", "INVALID_ARGUMENT").upper(), message)
    return AppError("INTERNAL", "处理遇到异常，原有记录已保留。请重试或提供问题编号。", 500)


def error_response(error: Exception, request_id: str | None = None) -> tuple[int, dict]:
    """Return the compatibility message plus a machine-readable error contract."""
    problem = classify_error(error)
    request_id = request_id or uuid.uuid4().hex[:12]
    if problem.status >= 500:
        # Stack frames aid diagnosis; exception values can contain secrets or classroom text.
        LOGGER.error(
            "request_failed request_id=%s code=%s kind=%s frames=%s",
            request_id,
            problem.code,
            type(error).__name__,
            "".join(traceback.format_tb(error.__traceback__)),
        )
    return problem.status, {
        "error": problem.message,
        "code": problem.code,
        "retryable": problem.retryable,
        "request_id": request_id,
    }
