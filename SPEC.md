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

Two engines behind `TranscriptionProvider`, selected by the **Identify speakers** setting.
The engine that actually ran is recorded on each recording, because the setting can change
afterwards and the UI must not claim speaker labels a transcript doesn't have.

### On-device (`OnDeviceTranscriber`)

- Apple `SpeechAnalyzer`, built for long-form audio.
- Free, offline, private — no audio leaves the device.
- **No speaker labels.** The engine returns a single undifferentiated stream.
- Used whenever the setting is off, or when it's on but no API key is configured.

### Speaker-aware (`SpeakerAwareTranscriber`)

- Sends audio to an audio-capable model via OpenRouter (default
  `google/gemini-2.5-flash`), which returns speaker-attributed turns.
- **This is inference, not acoustic diarization.** The model distinguishes speakers from
  voice characteristics and conversational cues rather than clustering voice embeddings
  the way a dedicated STT service does. Good with a few clearly-alternating speakers;
  degrades with crosstalk, similar voices, or large groups.
- ~1¢ per hour, versus ~26¢ for Deepgram — the tradeoff bought for that price is accuracy
  on hard audio, and one API key instead of two.
- **Audio is uploaded.** This is the only setting that changes what leaves the device, and
  the UI says so directly rather than burying it.

### Upload preparation (`AudioTranscoder`)

Audio must be base64-inlined in the request body, which inflates it ~33%. Recordings are
re-encoded to 16 kHz mono at 24 kbps (2.6× smaller, verified) and split into 15-minute
chunks, giving request bodies of roughly 2.4 MB. An hour is four chunks.

Chunks are sent sequentially, not concurrently: each is told which speakers earlier chunks
established so labels stay consistent across seams instead of renumbering.

Segment timings on this path are approximate — turns are distributed across a chunk's span
in proportion to length, since the model doesn't return reliable timestamps. Accurate
enough for ordering, not for seeking, which is why the transcript view has no tap-to-seek.

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

### Transcript view

A dedicated screen, reached from the detail view, with two modes:

- **Speakers** — colour-coded turns, consecutive same-speaker segments merged, with a
  legend of everyone in the recording. Only offered when the transcript actually has more
  than one speaker.
- **Plain text** — continuous text, for copying, reading a monologue, or checking what the
  summarizer actually saw.

Both support find-in-transcript with match highlighting. The footer states which engine
produced the transcript and, for the speaker-aware path, warns that labels are inferred.

### Redaction — removing parts of a recording

Segments are typically removed for privacy: crosstalk, a side conversation, someone
reading a password aloud. So removal is **destructive by design** — the point is that the
content stops existing.

Selecting segments and confirming will:

1. delete the segment text from the transcript,
2. cut the corresponding audio out of the recording, overwriting the file in place,
3. shift surviving segment timestamps onto the shortened timeline,
4. update the duration and offer to regenerate the summary.

There is **no undo and no backup copy**. A confirmation dialog states this and names how
much audio will be cut before anything happens.

#### Timing accuracy is the safety-critical part

Cutting at the wrong offset is a *silent* privacy failure: the user believes the sensitive
audio is destroyed while it is still in the file. `SegmentTimingSource` guards against
this:

| Source | Origin | Safe to cut? |
|---|---|---|
| `exact` | real `CMTimeRange` from the on-device engine | yes |
| `estimated` | proportional within a 15-minute chunk — can be tens of seconds out | **no** |
| `aligned` | cloud segments matched against on-device timings | yes |

Speaker-aware transcripts start as `estimated`, so redaction **cannot** run on them
directly. `RedactionService` first performs forced alignment: it re-transcribes the audio
with the on-device engine to obtain true time ranges, then `TranscriptAligner` transfers
those timings onto the speaker segments.

#### How alignment works, and why not the obvious way

The first implementation walked both word sequences with two pointers, matching greedily
within a lookahead window. It failed on real audio. Two engines disagree on 5–15% of
words, and each disagreement let the walk match a common word ("the", "and") far ahead of
where it belonged; the pointer jumped, skipped everything between, and the error compounded.
Measured against a real 285-second recording:

| Word error rate | Greedy walk | Trigram anchoring |
|---|---|---|
| 0% | 1.9s mean error | 1.9s |
| 5% | **refused** | 2.2s |
| 10% | **accepted, 75s out** | 3.4s |
| 15% | **refused** | 5.0s |
| 25% | **refused** | 6.7s |

The 10% row is the one that mattered: it passed the confidence check while being wrong by
over a minute — precisely the silent failure this mechanism exists to prevent. Word match
ratio turned out to be a poor proxy for timing accuracy, because a desynced walk still
racks up matches on common words.

The current implementation anchors on **trigrams shared by both transcripts**, reduced to a
strictly increasing sequence by a longest-increasing-subsequence pass, with positions
between anchors interpolated. A repeated word is ambiguous; a three-word sequence rarely
is, and the monotonicity filter discards any pairing inconsistent with the surrounding
order. Repeats are tolerated up to a cap rather than requiring global uniqueness — ordinary
speech reuses stock phrases constantly, and demanding unique trigrams refuses real meetings.

Confidence is judged on anchor count, coverage, and the **longest unanchored run in words**
— an absolute bound, since what degrades interpolation is the distance between surrounding
anchors, not how large that gap looks relative to the whole recording.

End-to-end, cutting an aligned range and re-transcribing the result lands within 0–3 words
of the intended position at 5–15% word error rate.

#### When alignment is refused

Nothing is cut. The on-device transcript produced during the attempt is retained, and the
user is offered it as a way forward: its timings are exact, so redaction works, at the cost
of the speaker labels. For a feature about removing sensitive audio, cutting accurately
beats knowing who said it.

#### Cutting

`AudioEditor` pads every removed range by 200 ms on each side, merges overlaps, builds an
`AVMutableComposition` of the surviving spans, re-encodes at the capture settings, and
swaps the file in with an atomic `replaceItemAt`. The padding errs toward **over**-removal:
clipping a syllable off a neighbouring word is a far better outcome than leaving the tail
of what the user wanted gone.

Removing the entire recording is refused — delete it instead.

#### What survives

Only counts: `redactedSegmentCount` and `redactedDuration`, so the UI and exports can
disclose that the recording is no longer complete. These deliberately survive
re-transcription, because destroyed audio stays destroyed.

After redaction the app **offers** to regenerate the summary rather than doing it
automatically — regeneration costs money, and spending it because a user declined the
prompt would be wrong. Declining leaves a persistent "Summary is out of date" banner,
tracked by `summaryNeedsRefresh`.

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

## Apple Watch

A standalone watchOS app that records with the **Watch's own microphone** and sends the
audio to the phone for processing. Recording started on the phone uses the phone mic;
recording started on the Watch uses the Watch mic. There is no remote control in either
direction — each device records itself.

This sidesteps the problem that got the Watch deferred from v1. The original plan was for
the Watch to *start a recording on the phone*, which needs iOS to wake the app and begin
mic capture from the background — heavily restricted, and the reason it was cut. Recording
locally needs none of that.

### What the Watch can and cannot do

`AVAudioRecorder` is available on watchOS, so capture works. **`Speech.framework` does not
exist on watchOS**, so the Watch cannot transcribe — which is why the audio goes to the
phone rather than being processed in place.

### Transfer

`WCSession.transferFile` rather than `sendMessage`: it queues on disk, survives the phone
being out of range or its app not running, retries on the system's schedule, and causes iOS
to launch the app in the background to receive. Record on a walk with the phone at home and
the audio arrives — and starts transcribing — when back in range.

Metadata carries the recording id, start time, duration, and source. The id is generated on
the Watch and reused as the `Recording` id, so a transfer the system retries and delivers
twice is recognised instead of becoming a duplicate.

The inbox file must be moved **synchronously** inside `didReceive` — it is deleted as soon
as that method returns, so hopping to the main actor first would race the deletion and lose
the recording. The Watch's copy is deleted only once the transfer is confirmed delivered.

`RecordingFormat` is shared by both targets so Watch and phone audio are byte-format
identical. Everything downstream — transcription, upload chunking, redaction's re-encode —
was written against those values, and a Watch file that quietly differed in sample rate
would misbehave far later in the pipeline.

### Known limitation

**Recording may stop when the wrist drops.** watchOS suspends apps that stop being
frontmost; `WKExtendedRuntimeSession` lists `ResignedFrontmost` as an invalidation reason.
The `audio` background mode is declared, which is the mechanism to try, but how far it
actually gets is not something the SDK settles — it needs testing on a real Watch. If it
proves insufficient, the usual workaround is holding a workout session to keep the app
alive, at the cost of a HealthKit permission and a workout appearing in Fitness.

## Explicitly out of scope for v1
- Dedicated STT providers with true acoustic diarization (Deepgram, AssemblyAI). The
  `TranscriptionProvider` seam is what would make adding one cheap if inferred speaker
  labels prove insufficient.
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
