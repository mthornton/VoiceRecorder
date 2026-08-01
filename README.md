# Voice Recorder

Record audio on iPhone, transcribe it, and generate an AI summary.

Transcription runs one of two ways, controlled by **Identify speakers** in Settings:

- **On** (default) — audio is sent to an audio model via OpenRouter, which returns
  speaker-attributed turns. Roughly a cent per hour. Your audio is uploaded.
- **Off** — Apple's `SpeechAnalyzer` transcribes entirely on the device. Free and private,
  but with no speaker labels; the on-device engine can't tell voices apart.

Speaker labels are inferred by the model rather than produced by acoustic diarization, so
they're reliable with a few clear speakers and less so with crosstalk or large groups.

See [SPEC.md](SPEC.md) for the full v1 scope and what's deliberately out of it.

## Requirements

- Xcode 26.6 or later (iOS 26 SDK)
- iOS 26+ device or simulator
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- An [OpenRouter](https://openrouter.ai/keys) API key, for summaries only

## Setup

Point `xcode-select` at Xcode if it isn't already — this needs your password:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Generate the Xcode project. `VoiceRecorder.xcodeproj` is generated from `project.yml` and
is not tracked in git, so run this after cloning and any time you change `project.yml`:

```bash
xcodegen generate
```

Then open `VoiceRecorder.xcodeproj` and run.

To build from the command line:

```bash
xcodebuild -project VoiceRecorder.xcodeproj -scheme VoiceRecorder -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Using it

Add your OpenRouter key under **Settings → OpenRouter API Key** and tap **Test Key** to
confirm it works before relying on it. The key is stored in the device Keychain.

Recording, on-device transcription, playback, search, and export all work without a key.
Summaries and speaker labels need one — without a key, speaker-aware transcription falls
back to on-device rather than failing.

Open a recording and tap **View Full Transcript** to read it as speaker-attributed turns
or as continuous plain text, with find-in-transcript in both modes.

To remove something sensitive — a password read aloud, a side conversation — use
**⋯ → Remove Parts** and tap the segments to drop.

**This is permanent.** The selected text is deleted from the transcript *and* cut out of
the audio file, which is overwritten in place. There is no undo and no backup copy. You'll
get a confirmation naming how much audio will be cut before anything happens.

On speaker-aware transcripts the app first re-listens to the recording on-device to work
out exactly where those words are, because the speaker-aware timings are only estimates
and cutting on an estimate would leave the sensitive audio in the file. That adds a minute
or two on a long recording. If it can't confidently locate the words, it removes nothing
and tells you.

Afterwards the app offers to regenerate the summary, and flags the existing one as out of
date until you do.

## Layout

```
Sources/VoiceRecorder/
  App/              app entry point and model container
  Models/           SwiftData Recording, summary templates, audio file storage
  Audio/            AVAudioRecorder capture, AVAudioPlayer playback
  Transcription/    TranscriptionProvider protocol + on-device implementation
  Summarization/    OpenRouter client, Keychain, settings, prompt assembly
  Pipeline/         transcribe → summarize orchestration
  Views/            SwiftUI screens
```

The `TranscriptionProvider` protocol in `Transcription/` is the seam between the two
engines. Adding a dedicated STT service with true acoustic diarization (Deepgram,
AssemblyAI) means writing one more conformance and nothing else.

## Notes

- The first on-device transcription downloads a speech model for your locale (a few
  hundred MB).
- Speaker-aware transcription re-encodes audio to 16 kHz mono before upload and sends long
  recordings in 15-minute chunks, so an hour is four sequential requests.
- Redaction pads each cut by 200 ms on both sides. It deliberately errs toward removing a
  little too much rather than too little.
- Recording continues while the app is backgrounded or the screen is locked, and
  auto-pauses for calls and Siri.
- Audio is written progressively, so a crash mid-recording leaves a playable file.
