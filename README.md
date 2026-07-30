# Voice Recorder

Record audio on iPhone, transcribe it on-device, and generate an AI summary.

Transcription runs entirely on the device using Apple's `SpeechAnalyzer` (iOS 26) — audio
never leaves the phone. Only the resulting text is sent to OpenRouter for summarization,
and only if you've added an API key.

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

Recording, transcription, playback, search, and export all work without a key — only
summaries need one.

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

The `TranscriptionProvider` protocol in `Transcription/` is the seam for adding a cloud
speech-to-text provider later — which is also what speaker labels would require, since
Apple's on-device engine returns a single undifferentiated stream.

## Notes

- The first transcription downloads a speech model for your locale (a few hundred MB).
- Recording continues while the app is backgrounded or the screen is locked, and
  auto-pauses for calls and Siri.
- Audio is written progressively, so a crash mid-recording leaves a playable file.
