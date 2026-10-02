# Classroom translation regression

This fixture reproduces the user's 2026-10-02 recording. It is not a claim that
Whisper or either translation model has passed a physical-Mac audio test.

## Text and persistence tests (swift test)

- `During office.` + `hours, you ask some question.` must keep `office hours`
  together, preserving the same segment UUID, timestamp and speaker.
- `The first thing I want to do is invite you.` + `to call me Shelly.` must
  reopen the provisional boundary instead of storing two isolated fragments.
- `That is.` is a dangling discourse fragment, not a meaningful independent
  translation unit. A completed question or a different speaker never merges.
- A revised original clears only its own translation. Neither an in-flight old
  response nor an older pending request may overwrite the newer source.
- Dangling fragments are rendered/saved immediately; translation waits at most
  three seconds for each update, and pause/end explicitly flushes pending text.

## Actual model comparison on the M3 Air (not yet measured)

1. Open Settings -> 翻译引擎 -> TranslateGemma 4B. Install/start Ollama using
   the settings link, then click 下载翻译模型. The app uses only
   `http://127.0.0.1:11434` and `translategemma:4b` (Ollama Q4_K_M, ~3.3 GB).
2. Reenter the recording page so the selected backend is fixed for the session.
3. Play the SAME 63-second recording, with Whisper small, for Apple and
   TranslateGemma. Keep the course name and languages identical.
4. Measure translation meaning separately from ASR errors. Review:
   - 176 is a course number, not a count of classes.
   - `respond to Professor Kagan` means responding when addressed by that title.
   - `office hours` means consultation hours, not a dangling number of hours.
   - `gray and august` means gray-haired and dignified; verify the audio before
     treating `Auguste` as an ASR error.
5. Record `whisper.decode-end seconds`, `translation.begin backend`,
   `translation.end seconds`, first visible English, first visible Chinese,
   peak memory, missing/repeated words, and timing after ten minutes.

Apple Translation has no context/prompt argument in this integration. It receives
unmodified repaired sentence text; TranslateGemma receives course + up to two
recent segments as reference context outside the text to translate. Prompt
compliance and translation accuracy require actual inference testing.

The app keeps Apple as default until the local model is installed and selected;
it does not silently fall back to Apple when the selected local engine fails.
The local integration returns whole-sentence translations, not token streaming.
