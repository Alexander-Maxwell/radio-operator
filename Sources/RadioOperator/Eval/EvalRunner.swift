import Foundation
import CryptoKit

/// `RadioOperator --eval <golden-dir>` — grades the app's meeting notes against
/// human-verified references. Spec: V4 docs/plans/radio-operator-eval-harness-spec.md
/// v1.1. Golden data stays outside this (public) repo; pass the directory or set
/// GOLDEN_DIR. Performance metrics (RTF/wall-clock/RSS) are Not Applicable in v1
/// (no replay hook yet); grading renormalizes over the metrics that exist.
///
/// Integrity posture (post-review hardening): corrupt inputs are exit-4 integrity
/// failures, never silent skips; `--allow-draft-references` forgives ONLY
/// unverified provenance; draft runs can neither write nor gate the baseline.
enum EvalRunner {
    static let harnessVersion = "1.1"

    // MARK: - CLI entry

    /// Returns true if an eval was requested and run (caller exits).
    static func handleIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--eval") else { return false }
        let goldenPath: String? = value(after: "--eval", in: args)
            ?? ProcessInfo.processInfo.environment["GOLDEN_DIR"]
        guard let goldenPath, !goldenPath.hasPrefix("--") else {
            FileHandle.standardError.write(Data("usage: RadioOperator --eval <golden-dir> [--allow-draft-references] [--report-dir <dir>] [--subset <meeting-id>] [--write-baseline]\n".utf8))
            exit(EvalExit.infra.rawValue)
        }
        let code = run(
            goldenDir: URL(fileURLWithPath: goldenPath),
            allowDraft: args.contains("--allow-draft-references"),
            reportDir: value(after: "--report-dir", in: args).map(URL.init(fileURLWithPath:)),
            subset: value(after: "--subset", in: args),
            writeBaseline: args.contains("--write-baseline"))
        exit(code)
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }

    // MARK: - Strict loading (corrupt ≠ missing; spec 5.2 exit 4)

    enum Loaded<T> {
        case ok(T)
        case missing
        case corrupt(String)
    }

    static func loadStrict<T: Decodable>(_ url: URL) -> Loaded<T> {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        do { return .ok(try JSONDecoder().decode(T.self, from: data)) }
        catch { return .corrupt("\(url.lastPathComponent): \(error)") }
    }

    /// Repo root for eval/gates.json + eval/baseline.json + git SHA: walk up
    /// from CWD to the first directory containing eval/gates.json or .git,
    /// falling back to the binary's ../../.. (swift build layout), then CWD.
    static func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("eval/gates.json").path)
                || FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let fromBinary = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: fromBinary.appendingPathComponent("eval/gates.json").path) {
            return fromBinary
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // MARK: - Per-meeting computation

    struct MeetingEval {
        var meta: GoldenMeta
        var reference: GoldenReference
        var werMe: TrackWER
        var werThem: TrackWER
        var attribution: AttributionResult
        var terms: TermResult?
        var f1: F1Result?
        var halluc: HallucResult?
        var validity: ValidityResult
        var diagnostics: MeetingDiagnostics
        /// Meetings tagged noisy/accented/code_switching are outside the
        /// clean-speech stratum that carries the WER band (spec 1.2).
        var isCleanStratum: Bool {
            Set(meta.strata).isDisjoint(with: ["noisy", "accented", "code_switching"])
        }
    }

    static func evaluateMeeting(dir: URL, meta: GoldenMeta, reference: GoldenReference,
                                terms: TermsFile?) throws -> MeetingEval {
        let notePath = resolvedPath(meta.hypothesis_note ?? "hypothesis.md", relativeTo: dir)
        let markdown = try String(contentsOf: notePath, encoding: .utf8)
        let note = EvalNoteParser.parse(markdown: markdown)
        let roster = RosterMap(meta: meta)

        var stubTracks: [String] = []
        for (track, rel) in [("me", reference.audio?["me"]), ("them", reference.audio?["them"])] {
            guard let rel else { continue }
            let url = resolvedPath(rel, relativeTo: dir)
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size < 1024, meta.duration_seconds > 0 {
                stubTracks.append(track)
            }
        }

        // A stub track's WER is Not Applicable — a ~100%-deletion score from a
        // capture loss must never be averaged into the aggregate (spec 1.2);
        // the collapse detector and diagnostics carry that failure instead.
        func trackWER(_ track: String) -> TrackWER {
            if stubTracks.contains(track) {
                return TrackWER(track: track, score: nil,
                                notApplicableReason: "stub audio (capture loss)")
            }
            return AttributionMetrics.perTrackWER(reference: reference, hyp: note, track: track)
        }

        return MeetingEval(
            meta: meta,
            reference: reference,
            werMe: trackWER("me"),
            werThem: trackWER("them"),
            attribution: AttributionMetrics.attribution(reference: reference, hyp: note, roster: roster),
            terms: terms.map { TermMetrics.score(reference: reference, hyp: note, terms: $0) },
            f1: reference.reference_summary.map {
                SummaryMetrics.actionItemF1(refItems: $0.action_items, hypItems: note.actionItems, roster: roster)
            },
            halluc: SummaryMetrics.hallucinatedOwners(
                hypActionItems: note.actionItems, hypDecisions: note.decisions,
                refSummary: reference.reference_summary, roster: roster),
            validity: ValidityChecks.check(markdown: markdown, note: note),
            diagnostics: MeetingDiagnostics(
                meLineCount: note.transcript.filter { $0.speaker == "Me" }.count,
                themLineCount: note.transcript.filter { $0.speaker != "Me" }.count,
                stubAudioTracks: stubTracks,
                referenceHumanVerified: reference.gradeabilityIssue == nil))
    }

    private static func resolvedPath(_ path: String, relativeTo dir: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : dir.appendingPathComponent(path).standardizedFileURL
    }

    // MARK: - Manifest (spec 2.3: sha256-pinned audio, coverage minima)

    struct ManifestFile: Codable {
        var complete: Bool
        var meetings: [Entry]
        var minima: [String: Int]?
        struct Entry: Codable {
            var id: String
            var sha256_me: String?
            var sha256_them: String?
        }
    }

    static let defaultMinima: [String: Int] = [
        "two_party": 8, "three_plus": 4, "conference_room": 2,
        "noisy": 2, "accented": 2, "code_switching": 1,
    ]

    static func verifyManifest(_ manifest: ManifestFile, goldenRoot: URL,
                               evals: [MeetingEval], meetingDirs: [String: URL]) -> [String] {
        var failures: [String] = []
        for entry in manifest.meetings {
            guard let dir = meetingDirs[entry.id] else {
                failures.append("manifest lists \(entry.id) but the meeting directory is missing")
                continue
            }
            let ref = evals.first { $0.meta.meeting_id == entry.id }?.reference
            for (track, expected) in [("me", entry.sha256_me), ("them", entry.sha256_them)] {
                guard let expected else { continue }
                guard let rel = ref?.audio?[track] else {
                    failures.append("\(entry.id): manifest pins \(track) audio but reference has no path")
                    continue
                }
                let url = resolvedPath(rel, relativeTo: dir)
                guard let data = try? Data(contentsOf: url) else {
                    failures.append("\(entry.id): pinned \(track) audio missing at \(url.path)")
                    continue
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let want = expected.replacingOccurrences(of: "sha256:", with: "")
                if digest != want {
                    failures.append("\(entry.id): \(track) audio sha256 mismatch")
                }
            }
        }
        if manifest.complete {
            var counts: [String: Int] = [:]
            for e in evals { for s in e.meta.strata { counts[s, default: 0] += 1 } }
            for (stratum, minimum) in manifest.minima ?? defaultMinima {
                if counts[stratum, default: 0] < minimum {
                    failures.append("coverage: stratum \(stratum) has \(counts[stratum, default: 0])/\(minimum) meetings on a complete manifest")
                }
            }
        }
        return failures
    }

    // MARK: - Run

    static func run(goldenDir: URL, allowDraft: Bool, reportDir: URL?,
                    subset: String?, writeBaseline: Bool) -> Int32 {
        let fm = FileManager.default
        let root = repoRoot()
        var warnings: [String] = []
        var hardIntegrity: [String] = []      // never forgiven (spec 5.2 exit 4)
        var provenanceIssues: [String] = []   // forgiven ONLY by --allow-draft-references

        var terms: TermsFile? = nil
        switch loadStrict(goldenDir.appendingPathComponent("terms.json")) as Loaded<TermsFile> {
        case .ok(let t): terms = t
        case .missing: warnings.append("no terms.json in golden dir: term accuracy is N/A")
        case .corrupt(let why): hardIntegrity.append("terms.json corrupt: \(why)")
        }

        var gates: GatesFile? = nil
        switch loadStrict(root.appendingPathComponent("eval/gates.json")) as Loaded<GatesFile> {
        case .ok(let g): gates = g
        case .missing: warnings.append("no eval/gates.json under \(root.path): regression epsilons unavailable, baseline comparison skipped")
        case .corrupt(let why): hardIntegrity.append("eval/gates.json corrupt: \(why)")
        }

        let goldenRoot = goldenDir.appendingPathComponent("golden")
        guard let entries = try? fm.contentsOfDirectory(at: goldenRoot, includingPropertiesForKeys: nil) else {
            print("EVAL INFRA: no golden/ directory under \(goldenDir.path)")
            return EvalExit.infra.rawValue
        }

        var evals: [MeetingEval] = []
        var meetingDirs: [String: URL] = [:]
        var draftRefs = false
        var subsetMatched = false

        for dir in entries.sorted(by: { $0.path < $1.path }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let id = dir.lastPathComponent
            let metaLoaded: Loaded<GoldenMeta> = loadStrict(dir.appendingPathComponent("meta.json"))
            let meta: GoldenMeta
            switch metaLoaded {
            case .missing: continue            // not a meeting dir (reports/, etc.)
            case .corrupt(let why): hardIntegrity.append("\(id)/meta.json corrupt: \(why)"); continue
            case .ok(let m): meta = m
            }
            if let subset { if id != subset { continue }; subsetMatched = true }
            meetingDirs[id] = dir

            var reference: GoldenReference? = nil
            for name in ["reference.json", "reference-draft.json"] {
                switch loadStrict(dir.appendingPathComponent(name)) as Loaded<GoldenReference> {
                case .ok(let r): reference = r
                case .missing: continue
                case .corrupt(let why): hardIntegrity.append("\(id)/\(name) corrupt: \(why)")
                }
                break
            }
            guard let reference else {
                if !hardIntegrity.contains(where: { $0.hasPrefix(id) }) {
                    hardIntegrity.append("\(id): no reference.json / reference-draft.json")
                }
                continue
            }
            if let issue = reference.gradeabilityIssue {
                provenanceIssues.append("\(id): \(issue)")
                if !allowDraft { continue }
                draftRefs = true
            }
            do {
                evals.append(try evaluateMeeting(dir: dir, meta: meta, reference: reference, terms: terms))
            } catch {
                hardIntegrity.append("\(id): hypothesis note unreadable: \(error.localizedDescription)")
            }
        }

        if let subset, !subsetMatched {
            print("EVAL INFRA: --subset \(subset) matched no meeting directory")
            return EvalExit.infra.rawValue
        }
        if !hardIntegrity.isEmpty {
            print("EVAL INTEGRITY (exit 4):\n" + hardIntegrity.joined(separator: "\n"))
            return EvalExit.integrity.rawValue
        }
        if evals.isEmpty {
            print("EVAL INTEGRITY (exit 4): no gradeable meetings."
                  + (provenanceIssues.isEmpty ? "" : "\nProvenance: " + provenanceIssues.joined(separator: "; ")
                     + "\n(re-run with --allow-draft-references for a non-gradeable diagnostic run)"))
            return EvalExit.integrity.rawValue
        }

        switch loadStrict(goldenRoot.appendingPathComponent("manifest.json")) as Loaded<ManifestFile> {
        case .ok(let manifest):
            let failures = verifyManifest(manifest, goldenRoot: goldenRoot, evals: evals, meetingDirs: meetingDirs)
            if !failures.isEmpty {
                print("EVAL INTEGRITY (exit 4):\n" + failures.joined(separator: "\n"))
                return EvalExit.integrity.rawValue
            }
        case .missing: warnings.append("no golden/manifest.json: checksum + coverage integrity layer skipped")
        case .corrupt(let why):
            print("EVAL INTEGRITY (exit 4): manifest.json corrupt: \(why)")
            return EvalExit.integrity.rawValue
        }

        // MARK: Aggregate
        var agg: [String: Double?] = [:]
        func weighted(_ subset: [MeetingEval], _ pick: (MeetingEval) -> Double?) -> Double? {
            var num = 0.0, den = 0.0
            for e in subset {
                guard let v = pick(e), e.meta.duration_seconds > 0 else { continue }
                let w = Double(e.meta.duration_seconds)
                num += v * w; den += w
            }
            return den > 0 ? num / den : nil
        }

        // WER band applies to the clean-speech stratum per track (spec 1.2/4.1);
        // all-strata values are report-only.
        let clean = evals.filter { $0.isCleanStratum }
        agg["wer_me"] = weighted(clean) { $0.werMe.score?.rate }
        agg["wer_them"] = weighted(clean) { $0.werThem.score?.rate }
        agg["wer_worst_track"] = [agg["wer_me"] ?? nil, agg["wer_them"] ?? nil].compactMap { $0 }.max()
        agg["wer_me_all"] = weighted(evals) { $0.werMe.score?.rate }
        agg["wer_them_all"] = weighted(evals) { $0.werThem.score?.rate }
        agg["attribution_2party"] = weighted(evals) { $0.attribution.accuracy }
        agg["bleed_me"] = weighted(evals) { $0.attribution.bleedRateMe }
        agg["bleed_them"] = weighted(evals) { $0.attribution.bleedRateThem }

        // Graded term pool = brand + money + number (spec 1.4). Everything else
        // is report-only, per category.
        let gradedCategories: Set<String> = ["brand", "money", "number"]
        var poolTotal = 0, poolCorrect = 0, allTotal = 0, allCorrect = 0
        var perCategory: [String: (total: Int, correct: Int)] = [:]
        for e in evals {
            guard let t = e.terms else { continue }
            allTotal += t.total; allCorrect += t.correct
            for (cat, c) in t.perCategory {
                perCategory[cat, default: (0, 0)].total += c.total
                perCategory[cat, default: (0, 0)].correct += c.correct
                if gradedCategories.contains(cat) { poolTotal += c.total; poolCorrect += c.correct }
            }
        }
        agg["term_accuracy"] = poolTotal > 0 ? Double(poolCorrect) / Double(poolTotal) : nil
        agg["term_accuracy_all"] = allTotal > 0 ? Double(allCorrect) / Double(allTotal) : nil

        // Pooled micro-F1. Zero and N/A are different signals (spec 1.5): with
        // items on both sides and no matches this is 0.0 (band F), never nil.
        var m = 0, rc = 0, hc = 0
        var matchedAtPool: [String: Int] = [:]
        for e in evals {
            guard let f = e.f1 else { continue }
            m += f.matched; rc += f.refCount; hc += f.hypCount
            for (k, v) in f.matchedAt { matchedAtPool[k, default: 0] += v }
        }
        func pooledF1(_ matched: Int) -> Double? {
            if rc == 0 && hc == 0 { return nil }
            if rc == 0 || hc == 0 { return 0 }
            let p = Double(matched) / Double(hc), r = Double(matched) / Double(rc)
            return (p + r) > 0 ? 2 * p * r / (p + r) : 0
        }
        agg["action_item_f1"] = (rc == 0 && hc == 0) ? nil : pooledF1(m)
        let f1Sensitivity = matchedAtPool.compactMapValues { pooledF1($0) }

        var h12 = 0, hOwned = 0
        for e in evals { if let h = e.halluc { h12 += h.tier1Phantom + h.tier2Misassigned; hOwned += h.hypItemsWithOwner } }
        agg["hallucinated_owner"] = hOwned > 0 ? Double(h12) / Double(hOwned) : nil

        let validityApplicable = evals.filter { $0.validity.checks.contains { $0.applicable } }
        agg["output_validity"] = validityApplicable.isEmpty ? nil
            : Double(validityApplicable.filter { $0.validity.pass }.count) / Double(validityApplicable.count)

        let anyCollapse = evals.contains { $0.attribution.collapseFlag }

        // MARK: Bands, GPA, caps
        var metrics: [String: EvalReport.Metric] = [:]
        var points: [String: Double] = [:]
        for (key, spec) in Self.bandSpecs {
            let v = agg[key] ?? nil
            var band = "N/A"
            if let v { band = spec.band(v) }
            if key == "attribution_2party", anyCollapse { band = "F" }
            var detail = spec.detail(agg, evals)
            if key == "term_accuracy", !perCategory.isEmpty {
                let cats = perCategory.sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value.correct)/\($0.value.total)" }.joined(separator: ", ")
                detail = [detail, "per-category: \(cats)"].compactMap { $0 }.joined(separator: "; ")
            }
            if key == "action_item_f1", !f1Sensitivity.isEmpty {
                let s = f1Sensitivity.sorted { $0.key < $1.key }
                    .map { "F1@\($0.key)=\(fmt($0.value))" }.joined(separator: " ")
                detail = [detail, s].compactMap { $0 }.joined(separator: "; ")
            }
            if key == "wer_worst_track" {
                let extra = "all-strata me=\(fmt(agg["wer_me_all"] ?? nil)) them=\(fmt(agg["wer_them_all"] ?? nil)); clean-stratum meetings: \(clean.count)/\(evals.count)"
                detail = [detail, extra].compactMap { $0 }.joined(separator: "; ")
            }
            metrics[key] = EvalReport.Metric(value: v, band: band, aplus_bar: spec.aplusBar,
                                             baseline: nil, regressed: nil, detail: detail)
            if band != "N/A" { points[key] = Self.gradePoints[band] ?? 0 }
        }
        for key in ["wer_me_all", "wer_them_all", "term_accuracy_all", "bleed_me", "bleed_them"] {
            metrics[key] = EvalReport.Metric(value: agg[key] ?? nil, band: nil, aplus_bar: nil,
                                             baseline: nil, regressed: nil, detail: "report-only diagnostic")
        }

        var gpa: Double? = nil
        var caps: [String] = []
        var letter = "DRAFT (not gradeable)"
        var allBars = false
        if !draftRefs {
            var wsum = 0.0, psum = 0.0
            for (key, w) in Self.gpaWeights where points[key] != nil {
                wsum += w; psum += points[key]! * w
            }
            gpa = wsum > 0 ? psum / wsum : nil
            var capped = gpa ?? 0
            if (agg["hallucinated_owner"] ?? nil).map({ $0 > 0 }) == true { caps.append("hallucinated-owner>0 caps A-"); capped = min(capped, 3.5) }
            if (agg["output_validity"] ?? nil).map({ $0 < 1.0 }) == true { caps.append("validity<100% caps A-"); capped = min(capped, 3.5) }
            if anyCollapse { caps.append("collapse caps C+"); capped = min(capped, 2.15) }
            gpa = capped
            letter = Self.letterFor(gpa: capped)
            allBars = Self.bandSpecs.allSatisfy { key, _ in metrics[key]?.band == "A+" }
            if !allBars, letter == "A+" { letter = "A" }   // min rule (spec 4.2)
        }

        // MARK: Baseline ratchet — draft runs and subset runs neither write nor gate.
        var regressions: [String] = []
        var hardFails: [String] = []
        let baselineURL = root.appendingPathComponent("eval/baseline.json")
        let baselineGatingActive = !draftRefs && subset == nil && gates != nil

        var oldBaseline: BaselineFile? = nil
        switch loadStrict(baselineURL) as Loaded<BaselineFile> {
        case .ok(let b): oldBaseline = b
        case .missing: break
        case .corrupt(let why):
            print("EVAL INTEGRITY (exit 4): eval/baseline.json corrupt: \(why)")
            return EvalExit.integrity.rawValue
        }

        if baselineGatingActive, let baseline = oldBaseline, baseline.draft != true {
            // A normalizer/terms change moves the goalposts: force a re-baseline
            // in the same PR instead of comparing incomparable numbers (spec 5.3).
            if baseline.normalizer_version != EvalNormalizer.version
                || baseline.terms_version != (terms?.version ?? 0) {
                hardFails.append("baseline version mismatch (baseline: normalizer \(baseline.normalizer_version)/terms \(baseline.terms_version); current: \(EvalNormalizer.version)/\(terms?.version ?? 0)) — run make eval-baseline in this PR")
            } else {
                let eps = gates?.epsilons ?? [:]
                // Regression gating covers exactly the keys with committed
                // epsilons — diagnostics ratchet informationally, never gate.
                for (key, e) in eps {
                    guard let base = baseline.metrics[key], let cur = agg[key] ?? nil else { continue }
                    let worse = Self.higherIsBetter.contains(key) ? cur < base - e : cur > base + e
                    if worse { regressions.append("\(key): \(fmt(cur)) vs baseline \(fmt(base))") }
                    metrics[key]?.baseline = base
                    metrics[key]?.regressed = worse
                }
            }
        }

        if writeBaseline {
            if draftRefs {
                warnings.append("REFUSED --write-baseline: draft references can never set the ratchet (spec 3.1/5.3)")
            } else if subset != nil {
                warnings.append("REFUSED --write-baseline: subset runs do not represent the full golden set")
            } else {
                // Per-metric ratchet merge: keep the better committed value; a
                // deliberate lowering requires editing baseline.json by hand
                // with a waiver note in the PR (spec 5.3).
                var merged: [String: Double] = [:]
                if let old = oldBaseline, old.draft != true,
                   old.normalizer_version == EvalNormalizer.version,
                   old.terms_version == (terms?.version ?? 0) {
                    merged = old.metrics
                }
                var kept: [String] = []
                for (k, v) in agg {
                    guard let v else { continue }
                    if let old = merged[k], Self.higherIsBetter.contains(k) ? old > v : (Self.lowerIsBetter.contains(k) ? old < v : false) {
                        kept.append(k)
                    } else {
                        merged[k] = v
                    }
                }
                if !kept.isEmpty { warnings.append("baseline kept better prior values for: \(kept.joined(separator: ", "))") }
                let bl = BaselineFile(metrics: merged, run_id: runStamp(), hardware_tier: nil,
                                      normalizer_version: EvalNormalizer.version,
                                      terms_version: terms?.version ?? 0, draft: false)
                save(bl, to: baselineURL)
            }
        }

        // MARK: Report
        let exitCode: EvalExit = !hardFails.isEmpty ? .hardGate : (!regressions.isEmpty ? .regression : .pass)
        let report = EvalReport(
            schema_version: "1.0",
            run: .init(timestamp: isoNow(), git_sha: gitSHA(in: root), harness_version: harnessVersion,
                       normalizer_version: EvalNormalizer.version, terms_version: terms?.version ?? 0,
                       draft_references: draftRefs, golden_dir: goldenDir.path),
            metrics: metrics,
            per_meeting: evals.map { e in
                .init(meeting_id: e.meta.meeting_id, strata: e.meta.strata,
                      wer_me: e.werMe.score?.rate, wer_them: e.werThem.score?.rate,
                      attribution: e.attribution.accuracy, collapse: e.attribution.collapseFlag,
                      bleed_me: e.attribution.bleedRateMe, bleed_them: e.attribution.bleedRateThem,
                      term_accuracy: e.terms?.accuracy, action_item_f1: e.f1?.f1,
                      validity_pass: e.validity.checks.contains { $0.applicable } ? e.validity.pass : nil,
                      notes: meetingNotes(e))
            },
            grade: .init(composite_gpa: gpa, letter: letter, caps_applied: caps, all_aplus_bars_met: allBars),
            gating: .init(hard_fails: hardFails, regressions: regressions, exit_code: Int(exitCode.rawValue)))

        let outDir = reportDir ?? goldenDir.appendingPathComponent("reports/\(runStamp())")
        do {
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            print("EVAL INFRA: cannot create report dir \(outDir.path): \(error.localizedDescription)")
            return EvalExit.infra.rawValue
        }
        save(report, to: outDir.appendingPathComponent("report.json"))
        let md = renderMarkdown(report: report, evals: evals,
                                warnings: warnings, provenance: provenanceIssues)
        try? md.write(to: outDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print(md)
        print("EVAL-REPORT \(outDir.path) exit=\(exitCode.rawValue)")
        return exitCode.rawValue
    }

    private static func meetingNotes(_ e: MeetingEval) -> String? {
        var bits: [String] = []
        if !e.diagnostics.stubAudioTracks.isEmpty {
            bits.append("CAPTURE LOSS: stub audio (<1KB) on track(s) \(e.diagnostics.stubAudioTracks.joined(separator: ","))")
        }
        if let issue = e.reference.gradeabilityIssue { bits.append("draft reference (\(issue))") }
        if let d = e.attribution.collapseDetail { bits.append(d) }
        if let reason = e.werMe.notApplicableReason { bits.append("wer_me n/a: \(reason)") }
        if let reason = e.werThem.notApplicableReason { bits.append("wer_them n/a: \(reason)") }
        bits.append("lines me=\(e.diagnostics.meLineCount) them=\(e.diagnostics.themLineCount)")
        return bits.isEmpty ? nil : bits.joined(separator: "; ")
    }

    // MARK: - Bands / weights (spec 4.1, 4.2)

    struct BandSpec {
        var aplusBar: Double
        var band: (Double) -> String
        var detail: (_ agg: [String: Double?], _ evals: [MeetingEval]) -> String?
    }

    static let gradePoints: [String: Double] = ["A+": 4.3, "A": 4.0, "B": 3.0, "C": 2.0, "F": 0]
    static let gpaWeights: [String: Double] = [
        "attribution_2party": 18, "wer_worst_track": 16, "term_accuracy": 12,
        "action_item_f1": 16, "hallucinated_owner": 6, "output_validity": 12,
        // rtf 7, wallclock 7, rss 6: Not Applicable in v1; weights renormalize.
    ]
    static let higherIsBetter: Set<String> = [
        "attribution_2party", "term_accuracy", "term_accuracy_all",
        "action_item_f1", "output_validity",
    ]
    static let lowerIsBetter: Set<String> = [
        "wer_me", "wer_them", "wer_worst_track", "wer_me_all", "wer_them_all",
        "hallucinated_owner", "bleed_me", "bleed_them",
    ]

    static let bandSpecs: [String: BandSpec] = [
        "attribution_2party": BandSpec(aplusBar: 0.99, band: {
            $0 >= 0.99 ? "A+" : $0 >= 0.97 ? "A" : $0 >= 0.92 ? "B" : $0 >= 0.80 ? "C" : "F"
        }, detail: { _, evals in
            let c = evals.filter { $0.attribution.collapseFlag }.map { $0.meta.meeting_id }
            return c.isEmpty ? nil : "collapse: \(c.joined(separator: ", "))"
        }),
        "wer_worst_track": BandSpec(aplusBar: 0.08, band: {
            $0 <= 0.08 ? "A+" : $0 <= 0.10 ? "A" : $0 <= 0.15 ? "B" : $0 <= 0.25 ? "C" : "F"
        }, detail: { agg, _ in
            "clean me=\(fmt(agg["wer_me"] ?? nil)) them=\(fmt(agg["wer_them"] ?? nil))"
        }),
        "term_accuracy": BandSpec(aplusBar: 0.98, band: {
            $0 >= 0.98 ? "A+" : $0 >= 0.95 ? "A" : $0 >= 0.88 ? "B" : $0 >= 0.75 ? "C" : "F"
        }, detail: { _, evals in
            let misses = evals.compactMap { $0.terms }.flatMap { $0.misses }
            return misses.isEmpty ? nil : "misses: " + misses.prefix(8).joined(separator: "; ")
        }),
        "action_item_f1": BandSpec(aplusBar: 0.90, band: {
            $0 >= 0.90 ? "A+" : $0 >= 0.85 ? "A" : $0 >= 0.75 ? "B" : $0 >= 0.60 ? "C" : "F"
        }, detail: { _, _ in nil }),
        "hallucinated_owner": BandSpec(aplusBar: 0, band: {
            $0 == 0 ? "A+" : $0 <= 0.01 ? "A" : $0 <= 0.03 ? "B" : $0 <= 0.08 ? "C" : "F"
        }, detail: { _, evals in
            let o = evals.compactMap { $0.halluc }.flatMap { $0.offenders }
            return o.isEmpty ? nil : "offenders: " + o.prefix(6).joined(separator: "; ")
        }),
        "output_validity": BandSpec(aplusBar: 1.0, band: {
            $0 >= 1.0 ? "A+" : $0 >= 0.95 ? "A" : $0 >= 0.85 ? "B" : $0 >= 0.70 ? "C" : "F"
        }, detail: { _, evals in
            let fails = evals.flatMap { e in e.validity.checks.filter { $0.applicable && !$0.pass }
                .map { "\(e.meta.meeting_id):\($0.id) \($0.detail)" } }
            return fails.isEmpty ? nil : fails.prefix(6).joined(separator: "; ")
        }),
    ]

    static func letterFor(gpa: Double) -> String {
        gpa >= 4.15 ? "A+" : gpa >= 3.85 ? "A" : gpa >= 3.50 ? "A-" : gpa >= 3.15 ? "B+"
            : gpa >= 2.85 ? "B" : gpa >= 2.50 ? "B-" : gpa >= 2.15 ? "C+" : gpa >= 1.85 ? "C"
            : gpa >= 1.50 ? "C-" : gpa >= 1.00 ? "D" : "F"
    }

    // MARK: - Rendering / IO helpers

    static func renderMarkdown(report: EvalReport, evals: [MeetingEval],
                               warnings: [String], provenance: [String]) -> String {
        var out = "# Radio Operator eval — \(report.run.timestamp) @ \(report.run.git_sha)\n\n"
        if report.run.draft_references {
            out += "> DRAFT REFERENCES — quality numbers are diagnostic only, not gradeable, no baseline written/compared (anti-circularity, spec 3.1).\n"
            for p in provenance { out += "> - \(p)\n" }
            out += "\n"
        }
        for w in warnings { out += "> WARNING: \(w)\n" }
        if !warnings.isEmpty { out += "\n" }
        out += "Grade: **\(report.grade.letter)**"
        if let g = report.grade.composite_gpa { out += " (GPA \(String(format: "%.2f", g)))" }
        if !report.grade.caps_applied.isEmpty { out += " — caps: \(report.grade.caps_applied.joined(separator: ", "))" }
        out += "\n\n| metric | value | band | A+ bar | detail |\n|---|---|---|---|---|\n"
        for key in bandSpecs.keys.sorted() {
            guard let mt = report.metrics[key] else { continue }
            out += "| \(key) | \(fmt(mt.value)) | \(mt.band ?? "") | \(fmt(mt.aplus_bar)) | \(mt.detail ?? "") |\n"
        }
        let diagKeys = report.metrics.keys.filter { bandSpecs[$0] == nil }.sorted()
        if !diagKeys.isEmpty {
            out += "\nDiagnostics (report-only): "
                + diagKeys.map { "\($0)=\(fmt(report.metrics[$0]?.value ?? nil))" }.joined(separator: " ")
                + "\n"
        }
        out += "\n## Per meeting\n\n| meeting | wer_me | wer_them | attrib | collapse | bleed_me | bleed_them | terms | f1 | validity | notes |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
        for pm in report.per_meeting {
            out += "| \(pm.meeting_id) | \(fmt(pm.wer_me)) | \(fmt(pm.wer_them)) | \(fmt(pm.attribution)) | \(pm.collapse ? "YES" : "no") | \(fmt(pm.bleed_me)) | \(fmt(pm.bleed_them)) | \(fmt(pm.term_accuracy)) | \(fmt(pm.action_item_f1)) | \(pm.validity_pass.map { $0 ? "pass" : "FAIL" } ?? "n/a") | \(pm.notes ?? "") |\n"
        }
        if !report.gating.hard_fails.isEmpty {
            out += "\n## Hard failures (exit 2)\n" + report.gating.hard_fails.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !report.gating.regressions.isEmpty {
            out += "\n## Regressions (exit 1)\n" + report.gating.regressions.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    static func fmt(_ v: Double?) -> String {
        guard let v else { return "n/a" }
        return v == v.rounded() && abs(v) >= 1 ? String(format: "%.0f", v) : String(format: "%.3f", v)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(value) { try? data.write(to: url) }
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func runStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date()) + "-" + gitSHA(in: repoRoot())
    }

    private static func gitSHA(in dir: URL) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["rev-parse", "--short", "HEAD"]
        proc.currentDirectoryURL = dir
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return "unknown" }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "unknown"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
