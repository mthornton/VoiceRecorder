import Foundation

/// How trustworthy a segment's `start`/`end` are.
///
/// This exists because cutting audio at the wrong offset is a silent privacy
/// failure: the user believes sensitive audio was destroyed while it is still in
/// the file. Only `exact` and `aligned` timings may drive an edit.
enum SegmentTimingSource: String, Codable, Sendable {
    /// Real `CMTimeRange` values from the on-device engine.
    case exact
    /// Distributed proportionally across a chunk by text length. Fine for
    /// ordering, useless for cutting — can be tens of seconds out.
    case estimated
    /// Cloud segments matched against on-device timings by forced alignment.
    case aligned

    var isSafeForCutting: Bool { self != .estimated }

    var label: String {
        switch self {
        case .exact: return "Exact"
        case .estimated: return "Approximate"
        case .aligned: return "Aligned"
        }
    }
}

/// Assigns accurate times to segments that only have estimates.
///
/// The speaker-aware engine returns ordered turns with no reliable timings. The
/// on-device engine returns real time ranges but no speakers. Running both over
/// the same audio and matching the word sequences gives us the speakers *and*
/// the timings — which is what makes cutting audio safe on the cloud path.
enum TranscriptAligner {
    private struct TimedWord {
        let normalized: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Rewrites `segments` with times taken from `reference`, preserving text
    /// and speakers. Returns nil when alignment is too poor to trust, so the
    /// caller can refuse to cut rather than cut in the wrong place.
    static func align(
        segments: [TranscriptSegment],
        reference: [TranscriptSegment],
        minimumMatchRatio: Double = 0.5
    ) -> [TranscriptSegment]? {
        guard !segments.isEmpty, !reference.isEmpty else { return nil }

        let referenceWords = timedWords(from: reference)
        guard !referenceWords.isEmpty else { return nil }

        // Flatten target words, remembering which segment each came from.
        var targetWords: [(text: String, segment: Int)] = []
        for (index, segment) in segments.enumerated() {
            for word in normalizedWords(segment.text) {
                targetWords.append((word, index))
            }
        }
        guard !targetWords.isEmpty else { return nil }

        // Both transcripts describe the same audio, so their word sequences run
        // roughly in parallel. A monotonic two-pointer walk with a bounded
        // lookahead absorbs the disagreements (mis-hearings, different
        // punctuation, dropped filler) without ever going backwards.
        let lookahead = 40
        var matches: [Int: (first: Int, last: Int)] = [:]
        var matchCount = 0
        var refIndex = 0

        for target in targetWords {
            guard refIndex < referenceWords.count else { break }

            var found: Int?
            let limit = min(refIndex + lookahead, referenceWords.count)
            for candidate in refIndex..<limit where referenceWords[candidate].normalized == target.text {
                found = candidate
                break
            }

            guard let matchedIndex = found else { continue }

            matchCount += 1
            refIndex = matchedIndex + 1

            if let existing = matches[target.segment] {
                matches[target.segment] = (existing.first, matchedIndex)
            } else {
                matches[target.segment] = (matchedIndex, matchedIndex)
            }
        }

        // A poor match usually means the two engines heard very different
        // things — different language, mostly noise, or a failed run. Better to
        // refuse than to hand back confident-looking garbage.
        let ratio = Double(matchCount) / Double(targetWords.count)
        guard ratio >= minimumMatchRatio else { return nil }

        var aligned = segments
        var lastEnd: TimeInterval = 0

        for index in aligned.indices {
            if let match = matches[index] {
                let start = referenceWords[match.first].start
                let end = referenceWords[match.last].end
                aligned[index].start = max(start, lastEnd)
                aligned[index].end = max(end, aligned[index].start)
            } else {
                // Unmatched segment: pin it to the gap between its neighbours
                // rather than leaving a stale estimate in place.
                let nextStart = nextMatchedStart(after: index, matches: matches, words: referenceWords)
                aligned[index].start = lastEnd
                aligned[index].end = max(nextStart ?? lastEnd, lastEnd)
            }
            lastEnd = aligned[index].end
        }

        return aligned
    }

    private static func nextMatchedStart(
        after index: Int,
        matches: [Int: (first: Int, last: Int)],
        words: [TimedWord]
    ) -> TimeInterval? {
        let laterKeys = matches.keys.filter { $0 > index }.sorted()
        guard let next = laterKeys.first, let match = matches[next] else { return nil }
        return words[match.first].start
    }

    /// Splits reference segments into words carrying interpolated times.
    ///
    /// The on-device engine times whole utterances, not words, so times within a
    /// segment are interpolated by character position. Utterances are a few
    /// seconds long, which keeps that error well under a second — as opposed to
    /// the chunk-scale error the estimates carry.
    private static func timedWords(from segments: [TranscriptSegment]) -> [TimedWord] {
        var result: [TimedWord] = []

        for segment in segments {
            let words = normalizedWords(segment.text)
            guard !words.isEmpty else { continue }

            let span = max(segment.end - segment.start, 0)
            let totalCharacters = max(words.reduce(0) { $0 + $1.count }, 1)
            var cursor = segment.start

            for word in words {
                let share = Double(word.count) / Double(totalCharacters)
                let duration = span * share
                result.append(TimedWord(normalized: word, start: cursor, end: cursor + duration))
                cursor += duration
            }
        }

        return result
    }

    /// Lowercased, punctuation-stripped tokens. Both engines punctuate and
    /// capitalize differently, so comparing raw text would match almost nothing.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
