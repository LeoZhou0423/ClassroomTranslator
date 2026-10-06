"""Optional local grammar suggestions; never modify the ASR ledger."""
from pathlib import Path
import re
import threading
from difflib import SequenceMatcher

from app_paths import MODEL_ROOT
MODEL_DIR = MODEL_ROOT / 'grammar-t5'


def safe_suggestion(original, candidate):
    """Reject large rewrites, changed numbers, negations or capitalized names."""
    words = lambda s: re.findall(r"[\w']+", s.lower())
    a, b = words(original), words(candidate)
    # Automatic caption edits are deliberately conservative: punctuation,
    # spelling and agreement only. Do not replace verbs or change tense.
    protected = {'say','said','says','is','was','are','were','have','had','will','would','can','could','may','might','do','did'}
    if any(a.count(word)!=b.count(word) for word in protected): return False
    if not b or SequenceMatcher(None, a, b).ratio() < .72:
        return False
    if re.findall(r'\d+(?:\.\d+)?', original) != re.findall(r'\d+(?:\.\d+)?', candidate):
        return False
    for negation in ('not', 'never', 'no', "don't", "won't", "isn't", "can't"):
        if a.count(negation) != b.count(negation):
            return False
    # Sentence-initial capitals are not names; internal capitals are protected.
    names = re.findall(r"(?<![.!?])\s+([A-Z][a-z]+)", original)
    if any(name.lower() not in b for name in names):
        return False
    return True


class GrammarModel:
    def __init__(self):
        self.lock = threading.Lock()
        self.model = self.tokenizer = None
        self.cache = {}

    def correct(self, text):
        with self.lock:
            if self.model is None:
                if not (MODEL_DIR / 'config.json').exists():
                    raise ValueError('语法模型尚未下载')
                import torch
                from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
                torch.set_num_threads(2)
                self.tokenizer = AutoTokenizer.from_pretrained(MODEL_DIR, local_files_only=True)
                self.model = AutoModelForSeq2SeqLM.from_pretrained(MODEL_DIR, local_files_only=True).eval()
            results = []
            import torch
            # Correct contextual blocks, not isolated ASR fragments. No truncation.
            for block in text.splitlines():
                if not block.strip():
                    continue
                if block not in self.cache:
                    inputs = self.tokenizer('grammar: ' + block, return_tensors='pt')
                    if inputs['input_ids'].shape[1] > 256:
                        self.cache[block] = (block, 'too_long')
                    else:
                        with torch.inference_mode():
                            output = self.model.generate(**inputs, num_beams=3, max_new_tokens=320, do_sample=False)
                        candidate = self.tokenizer.decode(output[0], skip_special_tokens=True).strip()
                        accepted = safe_suggestion(block, candidate)
                        self.cache[block] = (candidate if accepted else block, 'accepted' if accepted else 'rejected')
                corrected, status = self.cache[block]
                results.append({'original': block, 'corrected': corrected, 'status': status})
            return results


GRAMMAR = GrammarModel()
