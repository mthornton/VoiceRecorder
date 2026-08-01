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
///
/// ## Why anchors rather than a sequential word walk
///
/// The obvious approach — walk both sequences with two pointers, matching words
/// as you go — fails badly on real transcripts. Two engines disagree on maybe
/// 5–15% of words, and every disagreement lets the walk match a common word
/// ("the", "and") far ahead of where it should. The pointer jumps, skips the
/// words in between, and the error compounds for the rest of the recording.
/// Measured on a 285-second recording, that approach either refused outright at
/// a 5% word error rate or — worse — accepted an alignment that was 75 seconds
/// out at 10%, which is exactly the silent failure this whole mechanism exists
/// to prevent.
///
/// Anchoring on *trigrams that occur exactly once in both transcripts* removes
/// that failure mode. A repeated word is ambiguous; a unique three-word sequence
/// essentially never is. Anchors are then forced into a strictly increasing
/// sequence, so a spurious match cannot drag everything after it out of place,
/// and positions between anchors are interpolated.
enum TranscriptAligner {
    private struct TimedWord {
        let normalized: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Quality {
        /// Matched trigram anchors surviving the monotonicity filter.
        let anchorCount: Int
        /// Fraction of the transcript lying between the first and last anchor.
        /// Outside that span, positions are extrapolated rather than measured.
        let coverage: Double
        /// Longest run of words with no anchor. Positions inside a gap are
        /// interpolated, so this bounds how wrong any single position can be.
        let largestGapWords: Int
    }

    /// Minimum anchors before alignment is worth trusting at all.
    static let minimumAnchors = 3
    /// Anchors must span at least this much of the transcript.
    static let minimumCoverage = 0.6
    /// Longest tolerable unanchored run, in words.
    ///
    /// Measured in words rather than as a fraction on purpose: what degrades
    /// interpolation is the absolute distance between the anchors either side,
    /// not how big that gap looks relative to the whole recording. Forty words
    /// is roughly fifteen seconds of speech, across which linear interpolation
    /// stays comfortably inside the cut's safety margin.
    static let maximumGapWords = 40

    /// Rewrites `segments` with times taken from `reference`, preserving text
    /// and speakers. Returns nil when the match is too weak to trust, so the
    /// caller refuses to cut rather than cutting in the wrong place.
    static func align(
        segments: [TranscriptSegment],
        reference: [TranscriptSegment]
    ) -> [TranscriptSegment]? {
        alignWithQuality(segments: segments, reference: reference)?.segments
    }

    /// Same as `align`, but also reports why it succeeded — useful for
    /// diagnosing a refusal.
    static func alignWithQuality(
        segments: [TranscriptSegment],
        reference: [TranscriptSegment]
    ) -> (segments: [TranscriptSegment], quality: Quality)? {
        guard !segments.isEmpty, !reference.isEmpty else { return nil }

        let referenceWords = timedWords(from: reference)
        guard referenceWords.count >= 3 else { return nil }

        var targetWords: [String] = []
        var wordRanges: [(first: Int, last: Int)?] = []
        for segment in segments {
            let words = normalizedWords(segment.text)
            if words.isEmpty {
                wordRanges.append(nil)
            } else {
                wordRanges.append((targetWords.count, targetWords.count + words.count - 1))
                targetWords.append(contentsOf: words)
            }
        }
        guard targetWords.count >= 3 else { return nil }

        let anchors = monotonicAnchors(
            target: targetWords,
            reference: referenceWords.map(\.normalized)
        )

        let quality = assess(anchors: anchors, targetCount: targetWords.count)
        guard quality.anchorCount >= minimumAnchors,
              quality.coverage >= minimumCoverage,
              quality.largestGapWords <= maximumGapWords
        else { return nil }

        // Piecewise-linear map from target word position to reference word
        // position, exact at every anchor and interpolated between them.
        func referencePosition(for index: Int) -> Double {
            if index <= anchors[0].target {
                let scale = anchors[0].target > 0
                    ? Double(anchors[0].reference) / Double(anchors[0].target)
                    : 1
                return Double(index) * scale
            }
            if let last = anchors.last, index >= last.target {
                let remainingTarget = Double(targetWords.count - last.target)
                let remainingReference = Double(referenceWords.count - last.reference)
                let scale = remainingTarget > 0 ? remainingReference / remainingTarget : 1
                return Double(last.reference) + Double(index - last.target) * scale
            }

            var lower = anchors[0]
            for anchor in anchors {
                if anchor.target <= index { lower = anchor } else { break }
            }
            guard let upper = anchors.first(where: { $0.target > index }) else {
                return Double(lower.reference)
            }

            let span = Double(upper.target - lower.target)
            let progress = span > 0 ? Double(index - lower.target) / span : 0
            return Double(lower.reference)
                + progress * Double(upper.reference - lower.reference)
        }

        func time(at position: Double, useEnd: Bool) -> TimeInterval {
            let clamped = min(max(position, 0), Double(referenceWords.count - 1))
            let word = referenceWords[Int(clamped.rounded())]
            return useEnd ? word.end : word.start
        }

        var aligned = segments
        var lastEnd: TimeInterval = 0

        for index in aligned.indices {
            guard let range = wordRanges[index] else {
                aligned[index].start = lastEnd
                aligned[index].end = lastEnd
                continue
            }

            let start = time(at: referencePosition(for: range.first), useEnd: false)
            let end = time(at: referencePosition(for: range.last), useEnd: true)

            aligned[index].start = max(start, lastEnd)
            aligned[index].end = max(end, aligned[index].start)
            lastEnd = aligned[index].end
        }

        return (aligned, quality)
    }

    // MARK: - Anchoring

    private struct Anchor {
        let target: Int
        let reference: Int
    }

    /// Trigrams shared by both transcripts, reduced to a strictly increasing
    /// sequence of positions.
    ///
    /// Requiring globally unique trigrams sounds safer but fails on ordinary
    /// speech: people repeat stock phrases constantly, and a meeting where
    /// everyone says "the migration timeline" a dozen times yields almost no
    /// unique trigram at all. So repeats are allowed, up to a cap, and the
    /// ambiguity is resolved by the monotonicity filter below — a repeated
    /// trigram contributes several candidate positions, and only the one
    /// consistent with the surrounding order survives.
    private static let maximumRepeats = 4
    private static let maximumCandidatePairs = 200_000

    private static func monotonicAnchors(target: [String], reference: [String]) -> [Anchor] {
        var pairs = candidatePairs(target: target, reference: reference, repeats: maximumRepeats)

        // Pathologically repetitive input could otherwise explode; fall back to
        // strictly unique trigrams, which is cheap and still correct.
        if pairs.count > maximumCandidatePairs {
            pairs = candidatePairs(target: target, reference: reference, repeats: 1)
        }
        guard !pairs.isEmpty else { return [] }

        // Ascending by target, descending by reference on ties. That ordering
        // makes a strictly-increasing run over reference positions pick at most
        // one candidate per target position.
        pairs.sort {
            $0.target != $1.target ? $0.target < $1.target : $0.reference > $1.reference
        }

        return longestIncreasingByReference(pairs)
    }

    private static func candidatePairs(
        target: [String],
        reference: [String],
        repeats: Int
    ) -> [Anchor] {
        let targetTrigrams = trigramPositions(target, maximumRepeats: repeats)
        let referenceTrigrams = trigramPositions(reference, maximumRepeats: repeats)

        var pairs: [Anchor] = []
        for (key, targetIndices) in targetTrigrams {
            guard let referenceIndices = referenceTrigrams[key] else { continue }
            for targetIndex in targetIndices {
                for referenceIndex in referenceIndices {
                    pairs.append(Anchor(target: targetIndex, reference: referenceIndex))
                }
            }
        }
        return pairs
    }

    /// Trigram → every position it occurs at, dropping trigrams so common that
    /// they carry no positional information.
    private static func trigramPositions(_ words: [String], maximumRepeats: Int) -> [String: [Int]] {
        guard words.count >= 3 else { return [:] }

        var positions: [String: [Int]] = [:]
        for index in 0...(words.count - 3) {
            let key = words[index] + " " + words[index + 1] + " " + words[index + 2]
            positions[key, default: []].append(index)
        }

        return positions.filter { $0.value.count <= maximumRepeats }
    }

    /// Patience-style longest increasing subsequence, O(n log n).
    private static func longestIncreasingByReference(_ pairs: [Anchor]) -> [Anchor] {
        guard !pairs.isEmpty else { return [] }

        var tailIndices: [Int] = []
        var predecessors = [Int](repeating: -1, count: pairs.count)

        for (index, pair) in pairs.enumerated() {
            var low = 0
            var high = tailIndices.count
            while low < high {
                let mid = (low + high) / 2
                if pairs[tailIndices[mid]].reference < pair.reference {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            if low > 0 { predecessors[index] = tailIndices[low - 1] }
            if low == tailIndices.count {
                tailIndices.append(index)
            } else {
                tailIndices[low] = index
            }
        }

        var result: [Anchor] = []
        var cursor = tailIndices.last ?? -1
        while cursor >= 0 {
            result.append(pairs[cursor])
            cursor = predecessors[cursor]
        }
        return result.reversed()
    }

    // MARK: - Quality

    private static func assess(anchors: [Anchor], targetCount: Int) -> Quality {
        guard let first = anchors.first, let last = anchors.last, targetCount > 0 else {
            return Quality(anchorCount: anchors.count, coverage: 0, largestGapWords: Int.max)
        }

        let coverage = Double(last.target - first.target) / Double(targetCount)

        // Gaps include the unanchored head and tail, which are extrapolated and
        // therefore just as untrustworthy as an interior gap.
        var largestGap = max(first.target, targetCount - 1 - last.target)
        for index in 1..<max(anchors.count, 1) {
            largestGap = max(largestGap, anchors[index].target - anchors[index - 1].target)
        }

        return Quality(
            anchorCount: anchors.count,
            coverage: coverage,
            largestGapWords: largestGap
        )
    }

    // MARK: - Words

    /// Splits reference segments into words carrying interpolated times.
    ///
    /// The on-device engine times whole utterances, so times within a segment
    /// are interpolated by character position. In practice it emits very short
    /// segments — often single words — which keeps that error small.
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
