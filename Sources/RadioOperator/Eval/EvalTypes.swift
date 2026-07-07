import Foundation

/// Shared Codable models + result types for the eval harness (`--eval`).
/// Spec: V4 vault docs/plans/radio-operator-eval-harness-spec.md v1.1.
/// Serialization delta vs the spec's illustrative YAML: all structured golden
/// files are JSON (meta.json, reference.json, terms.json, gates.json) — the
/// binary has zero dependencies and Codable is the native parser. Golden data
/// lives OUTSIDE this repo (private vault); the harness takes a path.

// MARK: - Golden inputs

struct GoldenMeta: Codable {
    var meeting_id: String
    var strata: [String]
    var environment: String?
    var noise: String?
    var duration_seconds: Int
    var participants: [Participant]
    /// Path to the app-produced note being graded (absolute, or relative to
    /// the meeting directory). Replay-free v1: the hypothesis is the note the
    /// app already wrote.
    var hypothesis_note: String?

    struct Participant: Codable {
        var id: String          // "S1", "S2", ...
        var track: String       // "me" | "them"
        var display: String
        var aliases: [String]
    }
}

struct GoldenReference: Codable {
    var schema_version: String
    var meeting_id: String
    /// Track -> audio path ("me"/"them"), relative to the meeting dir or absolute.
    var audio: [String: String]?
    var segments: [Segment]
    var reference_summary: RefSummary?
    var provenance: Provenance

    struct Segment: Codable {
        var id: Int
        var track: String       // "me" | "them"
        var speaker: String     // participant id ("S1"...)
        var start_s: Double
        var end_s: Double
        var text: String
        var score: Bool
        var terms: [TermTag]?
    }
    struct TermTag: Codable {
        var term: String
        var category: String
    }
    struct RefSummary: Codable {
        var summary_points: [String]
        var decisions: [OwnedItem]
        var action_items: [ActionItem]
    }
    struct OwnedItem: Codable {
        var text: String
        var owner: String?
    }
    struct ActionItem: Codable {
        var task: String
        var owner: String?
        var due: String?
    }
    struct Provenance: Codable {
        var transcript_draft_source: String?
        var human_passes: [HumanPass]?
        var summary_authored_blind: Bool?
        struct HumanPass: Codable {
            var annotator: String
            var date: String
            var full_listen: Bool
        }
    }

    /// Anti-circularity gate: at least one full-listen human pass.
    var isHumanVerified: Bool {
        (provenance.human_passes ?? []).contains { $0.full_listen }
    }

    /// nil when fully gradeable; else why the spec-3.1 gate rejects it. Blind
    /// summary authorship is required whenever a reference summary exists —
    /// a summary corrected from the app's own output anchors the metric to
    /// the model being graded.
    var gradeabilityIssue: String? {
        guard isHumanVerified else { return "no full-listen human pass" }
        if reference_summary != nil, provenance.summary_authored_blind != true {
            return "reference summary not authored blind"
        }
        return nil
    }
}

struct TermsFile: Codable {
    var version: Int
    var terms: [Term]
    struct Term: Codable {
        var canonical: String
        var category: String    // brand|person|product|place|money|number|org
        var aliases: [String]?
        var match: String?      // "exact" (default) | "money"
    }
}

// MARK: - Parsed hypothesis (the app's markdown note)

struct HypNote {
    var frontmatter: [String: String]     // raw scalar values, unquoted
    var hasFrontmatter: Bool
    /// Ordered H2 headings as they appear in the body.
    var headings: [String]
    var transcript: [Line]
    var summaryBullets: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    /// True when the note is an app meeting note (frontmatter present and
    /// source == "Radio Operator"). Foreign files are excluded from grading.
    var isMeetingNote: Bool

    struct Line {
        var speaker: String     // literal token between ** ** ("Me"/"Them"/other)
        var timestamp: String   // "HH:MM:SS" as written
        var tRel: Double        // seconds since first transcript line (rollover-safe)
        var text: String
    }
    struct ActionItem {
        var raw: String
        var task: String        // raw minus owner/due decorations
        var owner: String?      // as written, un-canonicalized
        var due: String?
        var checked: Bool
    }
}

// MARK: - Roster (owner canonicalization)

struct RosterMap {
    /// normalized alias -> participant id
    var aliasToId: [String: String]
    var idToDisplay: [String: String]
    var isTwoParty: Bool
    /// participant id for the "me" track (S1 by convention)
    var meId: String?
    /// sole non-self participant id when 2-party, else nil
    var themId: String?

    init(meta: GoldenMeta) {
        var a: [String: String] = [:]
        var d: [String: String] = [:]
        for p in meta.participants {
            d[p.id] = p.display
            for alias in p.aliases + [p.display, p.id] {
                a[EvalNormalizer.normalizedString(alias)] = p.id
            }
        }
        aliasToId = a
        idToDisplay = d
        let them = meta.participants.filter { $0.track == "them" }
        isTwoParty = them.count == 1
        meId = meta.participants.first { $0.track == "me" }?.id
        themId = isTwoParty ? them.first?.id : nil
    }

    /// Resolve an owner string to a participant id, or nil (unknown = phantom).
    func resolve(_ owner: String) -> String? {
        aliasToId[EvalNormalizer.normalizedString(owner)]
    }
}

// MARK: - Metric results

struct TrackWER {
    var track: String
    var score: WordErrorRate.Score?   // nil = Not Applicable (no scored ref for track)
    var notApplicableReason: String?
}

struct AttributionResult {
    /// nil when not gradeable (e.g. no scored reference tokens).
    var accuracy: Double?
    var alignedTokens: Int
    var correctTokens: Int
    var collapseFlag: Bool
    var collapseDetail: String?
    /// Diagnostic: fraction of hyp tokens on each track that match the OTHER
    /// party's reference speech (±3 s window, similarity ≥ 0.8).
    var bleedRateMe: Double?
    var bleedRateThem: Double?
}

struct TermResult {
    var total: Int
    var correct: Int
    var perCategory: [String: (total: Int, correct: Int)]
    var misses: [String]              // "canonical @ segment-id" for the report
    var accuracy: Double? { total == 0 ? nil : Double(correct) / Double(total) }
}

struct F1Result {
    var precision: Double?
    var recall: Double?
    var f1: Double?
    var matched: Int
    var refCount: Int
    var hypCount: Int
    /// F1 recomputed at alternate similarity thresholds (keyed "0.5"/"0.7").
    var sensitivity: [String: Double]
    /// Matched-pair counts per threshold key — lets the runner pool
    /// cross-meeting sensitivity instead of averaging per-meeting F1s.
    var matchedAt: [String: Int]
}

struct HallucResult {
    var tier1Phantom: Int
    var tier2Misassigned: Int
    var hypItemsWithOwner: Int
    var offenders: [String]
    var rate: Double? {
        hypItemsWithOwner == 0 ? nil
            : Double(tier1Phantom + tier2Misassigned) / Double(hypItemsWithOwner)
    }
}

struct ValidityResult {
    var checks: [Check]
    var pass: Bool { checks.allSatisfy { $0.pass || !$0.applicable } }
    struct Check {
        var id: String        // "V1"..."V5"
        var applicable: Bool
        var pass: Bool
        var detail: String
    }
}

struct MeetingDiagnostics {
    var meLineCount: Int
    var themLineCount: Int
    /// Audio files < 1 KB with a nonzero meeting duration: capture-level loss.
    var stubAudioTracks: [String]
    var referenceHumanVerified: Bool
}

// MARK: - Gates / baseline / report (repo-side JSON)

struct GatesFile: Codable {
    var egress_posture: String            // "declared-egress" | "local-only"
    var epsilons: [String: Double]        // metric key -> allowed regression
    /// metric key -> phase tag; hard gates switch on when the phase ships.
    var hard_gates: [String: String]
}

struct BaselineFile: Codable {
    var metrics: [String: Double]
    var run_id: String
    var hardware_tier: String?
    var normalizer_version: String
    var terms_version: Int
    var draft: Bool?                      // draft baselines never gate
}

struct EvalReport: Codable {
    var schema_version: String
    var run: Run
    var metrics: [String: Metric]
    var per_meeting: [PerMeeting]
    var grade: Grade
    var gating: Gating

    struct Run: Codable {
        var timestamp: String
        var git_sha: String
        var harness_version: String
        var normalizer_version: String
        var terms_version: Int
        var draft_references: Bool
        var golden_dir: String
    }
    struct Metric: Codable {
        var value: Double?
        var band: String?                 // "A+","A","B","C","F","N/A"
        var aplus_bar: Double?
        var baseline: Double?
        var regressed: Bool?
        var detail: String?
    }
    struct PerMeeting: Codable {
        var meeting_id: String
        var strata: [String]
        var wer_me: Double?
        var wer_them: Double?
        var attribution: Double?
        var collapse: Bool
        var bleed_me: Double?
        var bleed_them: Double?
        var term_accuracy: Double?
        var action_item_f1: Double?
        var validity_pass: Bool?
        var notes: String?
    }
    struct Grade: Codable {
        var composite_gpa: Double?
        var letter: String                // "DRAFT (not gradeable)" in draft mode
        var caps_applied: [String]
        var all_aplus_bars_met: Bool
    }
    struct Gating: Codable {
        var hard_fails: [String]
        var regressions: [String]
        var exit_code: Int
    }
}

/// Exit codes per spec §5.2.
enum EvalExit: Int32 {
    case pass = 0
    case regression = 1
    case hardGate = 2
    case infra = 3
    case integrity = 4
}
