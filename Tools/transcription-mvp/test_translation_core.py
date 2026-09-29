import time
import unittest

from translation_core import LatestTranslationWorker, TranslationBlock, render_translations


class FakeBackend:
    def translate(self, text):
        time.sleep(0.02)
        return {"Hello.": "你好。", "Next.": "下一句。"}[text]


class TranslationCoreTests(unittest.TestCase):
    def test_downloaded_model_translates_to_simplified_chinese(self):
        from pathlib import Path
        from translation_core import OpusTranslator

        model_dir = Path(__file__).parent / "models" / "opus-mt-en-zh-ct2"
        if not (model_dir / "model.bin").is_file():
            self.skipTest("translation model is not downloaded")
        translator = OpusTranslator(model_dir)
        self.assertEqual(translator.translate("What is love?"), "爱是什么?")

    def test_render_preserves_speaker_label(self):
        blocks = [TranslationBlock("教授", "Hello."), TranslationBlock("学生", "Next.")]
        self.assertEqual(render_translations(blocks, ["你好。", "下一句。"]), "教授: 你好。\n学生: 下一句。")

    def test_only_latest_snapshot_is_published(self):
        results = []
        worker = LatestTranslationWorker(FakeBackend(), results.append, self.fail)
        worker.submit([TranslationBlock("教授", "Hello.")])
        worker.submit([TranslationBlock("学生", "Next.")])
        time.sleep(0.12)
        worker.close()
        self.assertEqual(results, ["学生: 下一句。"]) 


if __name__ == "__main__":
    unittest.main()
