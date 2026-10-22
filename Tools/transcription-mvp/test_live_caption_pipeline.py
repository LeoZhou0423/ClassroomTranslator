import json
import threading
import unittest
from unittest.mock import Mock, patch

from asr_core import bounded_units, normalized
from live_caption_pipeline import CaptionPipeline, partial_string
from speaker_service import SpeakerService


class StreamedCaptionTests(unittest.TestCase):
    def test_partial_json_handles_split_unicode_and_escaped_quotes(self):
        self.assertEqual(partial_string('{"chinese":"\\u4f', "chinese"), "")
        self.assertEqual(partial_string('{"chinese":"\\u4f60好', "chinese"), "你好")
        self.assertEqual(partial_string('{"english":"Say \\"hello\\".', "english"), 'Say "hello".')

    def test_bilingual_stream_emits_before_request_finishes_and_caches(self):
        service = CaptionPipeline()
        response = Mock(ok=True)
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        document = json.dumps(
            {
                "english": "We study character.",
                "chinese": "我们研究品格。",
                "teacher_probability": 0.98,
                "background_probability": 0,
                "uncertain": False,
            },
            ensure_ascii=False,
        )
        first = document.index("。") + 1
        chunks = [document[:first], document[first:]]
        seen = []

        def lines(chunk_size):
            yield ("data: " + json.dumps({"choices": [{"delta": {"content": chunks[0]}}]})).encode()
            self.assertTrue(seen)
            yield (
                "data: "
                + json.dumps(
                    {
                        "choices": [{"delta": {"content": chunks[1]}}],
                        "usage": {"prompt_tokens": 100, "completion_tokens": 30},
                    }
                )
            ).encode()
            yield b"data: [DONE]"

        response.iter_lines.side_effect = lines
        with patch("live_caption_pipeline.requests.post", return_value=response) as request:
            result = service.process(
                "We study character.",
                "Ethics lecture.",
                [],
                "test",
                "https://example.test",
                lambda en, zh: seen.append((en, zh)),
            )
            self.assertEqual(result["chinese"], "我们研究品格。")
            self.assertTrue(
                service.process(
                    "We study character.",
                    "Ethics lecture.",
                    [],
                    "test",
                    "https://example.test",
                    lambda en, zh: None,
                )["cache_hit"]
            )
            self.assertEqual(request.call_count, 1)

    def test_long_caption_split_preserves_every_word(self):
        text = " ".join("word" + str(i) for i in range(95)) + "."
        units = bounded_units(text)
        self.assertTrue(all(len(part.split()) <= 40 for part in units))
        self.assertEqual(normalized(" ".join(units)), normalized(text))

    def test_lecture_role_hints_are_per_voice_and_need_two_windows(self):
        with patch.object(threading.Thread, "start"):
            service = SpeakerService()
        service.rows = {
            i: {
                "speaker_id": 0 if i < 3 else 1,
                "label": "学生",
                "role": "student",
                "role_score": 0.5,
            }
            for i in range(4)
        }
        hints = {str(i): {"utterance": i, "teacher_probability": 0.98} for i in range(1)}
        self.assertEqual(service.snapshot(hints)[0]["role"], "student")
        hints["1"] = {"utterance": 1, "teacher_probability": 0.89}
        result = service.snapshot(hints)
        self.assertEqual(result[0]["label"], "老师")
        self.assertEqual(result[2]["role"], "teacher")
        self.assertEqual(result[3]["role"], "student")
