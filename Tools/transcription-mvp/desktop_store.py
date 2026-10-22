"""Shared course library and existing MVP recording index."""

import re
import threading
import uuid
from datetime import datetime
from pathlib import Path

from app_errors import AppError
from json_storage import atomic_write_json, read_json


class DesktopStore:
    @staticmethod
    def schedule_fields(value):
        weekday = int(value.get("scheduleWeekday", 1))
        monthday = int(value.get("scheduleMonthDay", 1))
        clock = value.get("scheduleTime", "09:00")
        if (
            not 0 <= weekday <= 6
            or not 1 <= monthday <= 31
            or not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", str(clock))
        ):
            raise ValueError("课程日期或时间无效")
        return {"scheduleWeekday": weekday, "scheduleMonthDay": monthday, "scheduleTime": clock}

    def __init__(self, root):
        self.root = Path(root)
        self.path = self.root / "library.json"
        self.lock = threading.RLock()

    def _read(self):
        if not self.path.exists():
            return {"courses": [], "settings": {}}
        value = read_json(self.path)
        if (
            not isinstance(value, dict)
            or not isinstance(value.get("courses"), list)
            or not isinstance(value.get("settings"), dict)
        ):
            raise AppError("DATA_CORRUPT", "课程库结构异常，已保留原文件，请从备份恢复。", 500)
        return value

    def _write(self, data):
        if self.path.exists():
            atomic_write_json(self.path.with_suffix(".json.bak"), self._read(), durable=True)
        atomic_write_json(self.path, data, durable=True)

    def settings(self):
        with self.lock:
            return {
                "model": "small",
                "device": None,
                "font_size": 15,
                "auto_scroll": True,
                "noise_reduction": True,
                "background_filter": True,
                "course_terms": "",
                **self._read().get("settings", {}),
                "realtime_preview": False,
            }

    def update_settings(self, settings):
        if not isinstance(settings, dict):
            raise ValueError("设置必须是对象")
        for field in ("auto_scroll", "noise_reduction", "background_filter"):
            if field in settings and not isinstance(settings[field], bool):
                raise ValueError("开关设置必须为开启或关闭")
        if "font_size" in settings and (
            type(settings["font_size"]) is not int or not 10 <= settings["font_size"] <= 40
        ):
            raise ValueError("字号必须在 10 到 40 之间")
        if "model" in settings and settings["model"] not in ("tiny", "base", "small", "small.en"):
            raise ValueError("语音模型无效")
        if (
            "device" in settings
            and settings["device"] is not None
            and (type(settings["device"]) is not int or settings["device"] < 0)
        ):
            raise ValueError("麦克风设置无效")
        if "course_terms" in settings and (
            not isinstance(settings["course_terms"], str) or len(settings["course_terms"]) > 8000
        ):
            raise ValueError("课程术语不能超过 8000 个字符")
        allowed = {
            "model",
            "device",
            "font_size",
            "auto_scroll",
            "translation_endpoint",
            "noise_reduction",
            "course_terms",
            "background_filter",
        }
        with self.lock:
            data = self._read()
            data["settings"].update({k: v for k, v in settings.items() if k in allowed})
            self._write(data)
        return self.settings()

    def create_course(self, value):
        name = str(value.get("name", "")).strip()
        if not name or len(name) > 150:
            raise ValueError("请输入有效的课程名称")
        course = {
            "id": str(uuid.uuid4()),
            "name": name,
            "accentCode": value.get("accentCode", "auto"),
            "targetLanguageCode": "zh-Hans",
            "createdAt": datetime.now().isoformat(),
            "scheduleType": value.get("scheduleType", "single"),
            "scheduleDate": value.get("scheduleDate", ""),
        }
        if course["scheduleType"] not in ("single", "daily", "weekly", "monthly"):
            raise ValueError("课程重复方式无效")
        course.update(self.schedule_fields(value))
        with self.lock:
            data = self._read()
            data["courses"].append(course)
            self._write(data)
        return course

    def edit_course(self, identifier, value):
        with self.lock:
            data = self._read()
            course = next((c for c in data["courses"] if c["id"] == identifier), None)
            if course is None:
                raise ValueError("课程不存在")
            name = str(value.get("name", course["name"])).strip()
            if not name or len(name) > 150:
                raise ValueError("请输入有效的课程名称")
            repeat = value.get("scheduleType", course.get("scheduleType", "single"))
            if repeat not in ("single", "daily", "weekly", "monthly"):
                raise ValueError("课程重复方式无效")
            schedule = self.schedule_fields({**course, **value})
            course.update(
                name=name,
                scheduleType=repeat,
                scheduleDate=value.get("scheduleDate", course.get("scheduleDate", "")),
                accentCode=value.get("accentCode", course.get("accentCode", "auto")),
            )
            course.update(schedule)
            self._write(data)
            return course

    def delete_course(self, identifier):
        with self.lock:
            data = self._read()
            if not any(c["id"] == identifier for c in data["courses"]):
                raise ValueError("课程不存在")
            data["courses"] = [c for c in data["courses"] if c["id"] != identifier]
            self._write(data)
        return {"ok": True}

    def rename_record(self, identifier, title):
        title = str(title).strip()
        if not title or len(title) > 150:
            raise ValueError("请输入有效的课堂记录名称")
        self.record_path(identifier)
        with self.lock:
            data = self._read()
            data.setdefault("record_titles", {})[identifier] = title
            self._write(data)
        return {"id": identifier, "title": title}

    def record_path(self, identifier):
        if not re.fullmatch(r"\d{8}-\d{6}-[a-z0-9]+", identifier):
            raise ValueError("录音记录编号无效")
        path = self.root / "sessions" / identifier
        if not path.is_dir():
            raise ValueError("录音记录不存在")
        return path

    def record(self, identifier):
        path = self.record_path(identifier)
        result = path / "result.json"
        if not result.exists():
            raise ValueError("录音尚未保存")
        record = read_json(result)
        if not isinstance(record, dict) or not isinstance(record.get("rows", []), list):
            raise AppError("DATA_CORRUPT", "课堂记录结构异常，已保留原文件。", 500)
        language = path / "language.json"
        if language.exists():
            record["language_rows"] = read_json(language)
        speakers = path / "speakers.json"
        if speakers.exists():
            record["speaker_rows"] = read_json(speakers)
        summary = path / "summary.json"
        if summary.exists():
            from classroom_summary import read_summary

            record["summary"] = read_summary(path)
        revision = path / "revision.json"
        if revision.exists():
            from classroom_revision import read_revision

            record["revision"] = read_revision(path)
        record["id"] = identifier
        edits = path / "content-edits.json"
        if edits.exists():
            record["content_edits"] = read_json(edits)
        classroom = path / "classroom-edits.json"
        if classroom.exists():
            manual = read_json(classroom)
            record["content_edits"] = {**record.get("content_edits", {}), **manual.get("rows", {})}
            record["speaker_names"] = manual.get("speaker_names", {})
        return record

    def edit_classroom(self, identifier, rows, speaker_names):
        with self.lock:
            record = self.record(identifier)
            valid = {r["id"] for r in record.get("rows", [])}
            edits = dict(record.get("content_edits", {}))
            for row in rows:
                if row["id"] not in valid:
                    raise ValueError("课堂段落不存在")
                original = str(row.get("original", "")).strip()
                translated = str(row.get("translated", "")).strip()
                if not original or max(len(original), len(translated)) > 20000:
                    raise ValueError("课堂内容无效")
                edits[row["id"]] = {"original": original, "translated": translated}
            known = {
                str(r["speaker_id"])
                for r in record.get("speaker_rows", {}).values()
                if r.get("speaker_id") is not None
            }
            names = dict(record.get("speaker_names", {}))
            for speaker, name in speaker_names.items():
                if speaker not in known:
                    raise ValueError("说话人身份不存在")
                name = str(name).strip()
                if not name or len(name) > 150:
                    raise ValueError("说话人姓名无效")
                names[speaker] = name
            path = self.record_path(identifier) / "classroom-edits.json"
            atomic_write_json(path, {"rows": edits, "speaker_names": names}, durable=True)
            return self.record(identifier)

    def edit_content(self, identifier, row_id, value):
        with self.lock:
            record = self.record(identifier)
            if row_id not in {row["id"] for row in record.get("rows", [])}:
                raise ValueError("课堂段落不存在")
            fields = {
                key: str(value.get(key, "")).strip()
                for key in ("speaker", "original", "translated")
            }
            if (
                not fields["original"]
                or len(fields["speaker"]) > 150
                or any(len(fields[k]) > 20000 for k in ("original", "translated"))
            ):
                raise ValueError("请输入有效的姓名和课堂内容")
            path = self.record_path(identifier) / "content-edits.json"
            edits = record.get("content_edits", {})
            edits[row_id] = fields
            atomic_write_json(path, edits, durable=True)
            return self.record(identifier)

    def library(self):
        with self.lock:
            data = self._read()
        records = []
        warnings = []
        sessions = self.root / "sessions"
        for directory in sorted(sessions.glob("*"), reverse=True) if sessions.exists() else []:
            if not (directory / "result.json").is_file():
                continue
            try:
                result = read_json(directory / "result.json")
                config = result.get("config", {})
                text = result.get("transcript", "")
                if not text.strip():
                    continue
                records.append(
                    {
                        "id": directory.name,
                        "course_id": config.get("course_id"),
                        "title": data.get("record_titles", {}).get(directory.name)
                        or ("【" + config.get("course_name", "课堂") + "】" + directory.name[:8]),
                        "date": datetime.strptime(directory.name[:15], "%Y%m%d-%H%M%S").isoformat(),
                        "duration": result.get("metrics", {}).get("captured_seconds", 0),
                        "preview": text[:220],
                    }
                )
            except (ValueError, OSError, TypeError, AppError):
                warnings.append(
                    {
                        "code": "RECORD_UNAVAILABLE",
                        "record_id": directory.name,
                        "message": "一条课堂记录无法读取，已保留原文件，其他记录不受影响。",
                    }
                )
                continue
        return {
            "courses": data["courses"],
            "records": records,
            "settings": self.settings(),
            "warnings": warnings,
        }
