# Voice Recorder — v1 Spec

Record audio on iPhone, transcribe it on-device, and generate an AI summary via OpenRouter
using a key the user supplies.

## Platform & tooling

- **iOS 26+**, iPhone only. SwiftUI + SwiftData.
- Xcode 26.6 (iOS 26.5 SDK).
- Project generated with **XcodeGen** from a checked-in `project.yml`.
- Distribution: personal sideload. No App Store review requirements in v1.

## Architecture

```
Recorder ──▶ AudioFile ──▶ TranscriptionProvider ──▶ Transcript ──▶ SummarizationService ──▶ Summary
             (.m4a)        (protocol)                              (OpenRouter)
```

`TranscriptionProvider` is a protocol with one v1 implementation, `OnDeviceTranscriber`
(Apple `SpeechAnalyzer` / `SpeechTranscriber`). A cloud implementation is deliberately
deferred but the seam exists so it can be added without touching the pipeline, UI, or
storage layer.

### Recording states

Each recording is a SwiftData model carrying an explicit status:

`recording → recorded → transcribing → transcribed → summarizing → complete`

Plus terminal-but-recoverable failures: `transcriptionFailed`, `summarizationFailed`.

Rules:
- A failure at any stage **never** destroys the audio or an already-produced transcript.
- Each failed stage is individually retryable from the UI.
- Re-summarizing (different template or model) reuses the cached transcript — it does not
  re-transcribe.

## Capture

- iPhone mic, mono AAC `.m4a` (~25 MB/hour).
- Target: reliable handling of recordings up to ~1 hour.
- `UIBackgroundModes: audio` — recording continues when the app is backgrounded or the
  screen is locked.
- Audio session interruptions (incoming call, Siri) auto-pause and auto-resume where the
  system permits.
- Audio is written progressively to disk, so a crash or force-quit leaves a playable
  partial file rather than nothing.
- Record screen shows elapsed time and a live waveform. **No live transcript** — text
  appears after stop.

## Transcription

- On-device via `SpeechAnalyzer`, which is built for long-form audio.
- Runs automatically when the user stops recording.
- Free, offline, and private — no audio leaves the device on this path.
- **No speaker labels.** Apple's on-device engine returns a single undifferentiated text
  stream. Diarization requires a cloud provider and is out of scope for v1; the
  `TranscriptionProvider` seam is what makes adding it later cheap.

## Summarization

Automatic once transcription completes, **if** a key is present. Manual "Regenerate"
always available.

One OpenRouter call produces:

- an **AI-generated title** (replaces "New Recording 3")
- a prose **summary**
- **key points**
- **action items**

### Templates

Four built-ins, each a system prompt plus expected output sections:

| Template | Emphasis |
|---|---|
| Meeting | decisions, owners, action items |
| Lecture | concepts, structure, takeaways |
| Interview | questions, responses, quotable material |
| Quick Memo | terse — just the point |

Plus a **Custom** template with a user-editable prompt, editable in Settings.

## Library

- List of recordings with title, date, duration, and status.
- **Full-text search** across titles, transcripts, and summaries.
- Playback with scrubbing.
- Rename, delete.
- **Export / share sheet**: audio file, transcript as plain text, summary as Markdown.

## Settings

- **OpenRouter API key**, stored in the **Keychain** (never `UserDefaults`, never logged).
  Masked entry field with paste support, and a **Test key** button that validates against
  OpenRouter before the user trusts it.
- **Model picker**: a short curated list plus a free-text field accepting any OpenRouter
  model ID. The curated ids were verified against OpenRouter's live `/api/v1/models`
  catalog: `google/gemini-2.5-flash` (default), `openai/gpt-5-mini`,
  `anthropic/claude-haiku-4.5`, `anthropic/claude-sonnet-4.5`. All four have ≥200k
  context, so a one-hour transcript summarizes in a single call — no chunking needed.
- Custom template prompt editor.

## Behavior with no API key

Recording, transcription, playback, search, and export all work fully. Only the summary is
gated — its card shows a prompt to add a key in Settings. The app is useful before it is
configured.

## Cost calibration

An hour of speech is roughly 13k input tokens and ~1k output — cents per summary on a
mid-tier model. Transcription is free (on-device).

## Explicitly out of scope for v1

- **Apple Watch app** — deferred to a future version.
- Cloud STT and speaker labels (protocol seam only).
- Chat / follow-up Q&A against a transcript.
- iCloud sync — storage is local-only.
- Tags and folders.
- Complications, Live Activities.
- Importing pre-existing audio files.

## Known setup requirement

`xcode-select` points at Command Line Tools rather than Xcode. Builds work around this
with a `DEVELOPER_DIR` override (see the README), but Xcode itself and the simulator
tooling need the real fix:

```
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```
