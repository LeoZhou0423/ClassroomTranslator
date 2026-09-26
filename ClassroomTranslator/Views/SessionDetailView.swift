import SwiftUI

@MainActor
struct SessionDetailView: View {
    private struct DraftSegment: Identifiable {
        let id: UUID
        var original: String
        var translated: String
        /// task-4：说话人显示名（空串 = 无标签；存的是最终显示字符串）。
        var speaker: String
        let originalAtLoad: String
        let timestamp: Date
        let isFinal: Bool
    }

    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let record: TranscriptRecord
    @State private var isEditing = false
    @State private var title: String
    @State private var drafts: [DraftSegment]
    @State private var feedback = ""
    /// VIS-08：footer 反馈的语义分级，替代原来"永远绿色"。
    @State private var feedbackSeverity: FeedbackSeverity = .info
    @State private var translationManager = TranslationManager()
    @State private var isFillingTranslations = false
    /// task-9：编辑态 DatePicker 的日期草稿（init 从 record.date 装载）。
    @State private var sessionDate: Date
    /// task-10：本记录人员映射（昵称/角色）—— 隔离铁律：只落本记录，改动即时存。
    @State private var peopleAliases: [String: SpeakerAlias]
    /// task-10：本记录 segments 出现过的 speaker 标签（首次出现序，init 快照）。
    @State private var peopleLabels: [String]

    private enum FeedbackSeverity {
        case info, success, error

        var color: Color {
            switch self {
            case .info: return .secondary
            case .success: return .green
            case .error: return .red
            }
        }

        var iconName: String {
            switch self {
            case .info: return "info.circle"
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
    }

    private func setFeedback(_ message: String, severity: FeedbackSeverity = .info) {
        feedback = message
        feedbackSeverity = severity
    }

    /// VIS-03：用小标签替代纯颜色编码（WCAG 1.4.1）。
    private func roleTag(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color(nsColor: .labelColor.withAlphaComponent(0.1)), in: Capsule())
            .fixedSize()
    }

    init(record: TranscriptRecord) {
        self.record = record
        _title = State(initialValue: record.title)
        _sessionDate = State(initialValue: record.date)
        _peopleAliases = State(initialValue: record.aliasMap)
        _peopleLabels = State(initialValue: SessionDetailView.uniqueSpeakerLabels(record.segments))
        _drafts = State(initialValue: record.segments.map {
            DraftSegment(id: $0.id, original: $0.original, translated: $0.translated, speaker: $0.speaker ?? "", originalAtLoad: $0.original, timestamp: $0.timestamp, isFinal: $0.isFinal)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if isEditing {
                    TextField("Recording title", text: $title).font(.headline)
                } else {
                    // task-9：标题空/仅空白 → 日期占位回退（SessionDisplay 纯函数）。
                    Text(SessionDisplay.titleText(title: record.title, date: record.date))
                        .font(.headline)
                }
                Spacer()
                if isEditing {
                    // task-9：编辑态 DatePicker 直接改 record.date（save 时落库）。
                    DatePicker("", selection: $sessionDate,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                } else {
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundColor(.secondary)
                }
                if isEditing {
                    Button("Cancel", action: cancelEditing)
                    Button("Save", action: saveChanges).buttonStyle(.borderedProminent)
                } else {
                    Button("Edit") { isEditing = true }
                    Button("Done") { dismiss() }.buttonStyle(.bordered)
                }
            }.padding()

            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // task-10：人员区（本记录内昵称/角色，改动即时存；无标签时隐藏）。
                    if !peopleLabels.isEmpty {
                        peopleSection
                        Divider()
                    }
                    ForEach($drafts) { $segment in
                        VStack(alignment: .leading, spacing: 7) {
                            if isEditing {
                                // task-4：说话人可查看/编辑/清除（清空保存为无标签）。
                                TextField("Speaker", text: $segment.speaker)
                                    .font(.caption)
                                Text("Original").font(.caption).foregroundColor(.secondary)
                                TextEditor(text: $segment.original).frame(minHeight: 58)
                                Text("Translation").font(.caption).foregroundColor(.secondary)
                                TextEditor(text: $segment.translated).frame(minHeight: 58)
                                if segment.original != segment.originalAtLoad || segment.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button("Retranslate this segment") {
                                        Task { await retranslate(segmentID: segment.id) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            } else {
                                // VIS-03：译文才是主内容 —— 字号不低于原文、主文本色；
                                // 原文降为 caption 色。行首标签保证不靠颜色单独编码。
                                // task-4：有说话人标签时独立成标签显示（此处不做文本拼接，
                                // 前缀拼接场景统一走 SpeakerLabels.prefix）。
                                if !segment.speaker.isEmpty {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        roleTag("Speaker")
                                        // task-10：昵称命中显示「王教授」，与人员区编辑即时联动。
                                        Text(SpeakerAliases.resolve(segment.speaker, in: peopleAliases))
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    roleTag("Original")
                                    Text(segment.original)
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                                if !segment.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        roleTag("Translated")
                                        Text(segment.translated)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    if drafts.isEmpty { ContentUnavailableView("No Transcript", systemImage: "text.quote") }
                }.padding()
            }

            Divider()
            HStack {
                // VIS-08：按 info/success/error 分色并配图标；
                // 三元表达式会把字面量推断成 String，必须显式 String(localized:) 才查表。
                HStack(spacing: 4) {
                    if !feedback.isEmpty {
                        Image(systemName: feedbackSeverity.iconName).font(.caption)
                    }
                    Text(feedback.isEmpty
                        ? String(format: String(localized: "%lld segments"), drafts.count)
                        : feedback)
                        .font(.caption)
                }
                .foregroundColor(feedback.isEmpty ? .secondary : feedbackSeverity.color)
                Spacer()
                Button { exportWord() } label: { Label("Export Word", systemImage: "doc.richtext") }
                    .buttonStyle(.borderedProminent).disabled(isEditing)
                if drafts.contains(where: { $0.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    Button { Task { await translateMissingSegments() } } label: {
                        // 三元表达式推断成 String，显式本地化否则中英混排。
                        Label(
                            isFillingTranslations
                                ? String(localized: "Translating…")
                                : String(localized: "Translate Missing"),
                            systemImage: "character.bubble"
                        )
                    }
                    .disabled(isFillingTranslations || isEditing)
                }
                Button { exportText() } label: { Label("Export Text", systemImage: "doc.plaintext") }
                    .buttonStyle(.bordered).disabled(isEditing)
            }.padding()
        }
        .frame(minWidth: 620, minHeight: 480)
        .modifier(TranslationSessionCompat(
            manager: translationManager,
            sourceLanguage: record.course?.accentCode,
            targetLanguage: record.course?.effectiveTargetLanguageCode
        ))
        // UX-06：不再"打开详情就自动批量翻译"—— 只读打开不写库、不弹失败首因；
        // 需要译文时点 footer 的显式按钮，并能看到 x/y 进度。
    }

    private func saveChanges() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // task-9：trim 后原样保存（允许清空 —— 空标题在显示层回退日期占位）。
        record.title = cleanTitle
        // task-9：编辑态 DatePicker 的日期落库。
        record.date = sessionDate
        record.segments = drafts.map {
            TranscriptSegment(
                id: $0.id,
                original: $0.original,
                translated: $0.translated,
                timestamp: $0.timestamp,
                isFinal: $0.isFinal,
                speaker: $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        historyStore.save()
        isEditing = false
        setFeedback(String(localized: "Changes saved"), severity: .success)
    }

    private func cancelEditing() {
        title = record.title
        sessionDate = record.date
        drafts = record.segments.map { DraftSegment(id: $0.id, original: $0.original, translated: $0.translated, speaker: $0.speaker ?? "", originalAtLoad: $0.original, timestamp: $0.timestamp, isFinal: $0.isFinal) }
        isEditing = false
    }

    // MARK: - task-10：人员（本记录昵称/角色；隔离铁律：只落本 TranscriptRecord）

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.headline)
            ForEach(peopleLabels, id: \.self) { label in
                HStack(spacing: 10) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 76, alignment: .leading)
                    TextField("Nickname", text: nicknameBinding(for: label))
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: roleBinding(for: label)) {
                        ForEach(SpeakerRole.allCases) { role in
                            Text(LocalizedStringKey(role.title)).tag(role)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func nicknameBinding(for label: String) -> Binding<String> {
        Binding(
            get: { peopleAliases[label]?.nickname ?? "" },
            set: { newValue in
                var alias = peopleAliases[label] ?? .empty
                alias.nickname = newValue
                peopleAliases[label] = alias
                persistPeople()
            }
        )
    }

    private func roleBinding(for label: String) -> Binding<SpeakerRole> {
        Binding(
            get: { peopleAliases[label]?.role ?? .other },
            set: { newValue in
                var alias = peopleAliases[label] ?? .empty
                alias.role = newValue
                peopleAliases[label] = alias
                persistPeople()
            }
        )
    }

    /// 改动即时存：写回 record.speakerNames（encode 修剪空条目，全空 → nil 清除）。
    private func persistPeople() {
        record.speakerNames = SpeakerAliases.encode(peopleAliases)
        historyStore.save()
    }

    /// 本记录 segments 里出现过的 speaker 标签（首次出现序、trim、去重）。
    private static func uniqueSpeakerLabels(_ segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for segment in segments {
            // speaker 是 String?（旧数据可为 nil）—— nil 不该出现在人员区，直接排除。
            guard let raw = segment.speaker else { continue }
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(label).inserted else { continue }
            ordered.append(label)
        }
        return ordered
    }

    private func exportWord() {
        setFeedback(String(localized: "Choose where to save…"))
        ExportManager.exportWord(record: record) { result in
            switch result {
            case .success:
                feedback = String(localized: "Word document exported")
                feedbackSeverity = .success
            case .failure(let error):
                // UX-07：取消不是错误 —— 清空 footer 回到段数计数，不进错误态。
                let cancelled = ExportManager.isCancellation(error)
                feedback = cancelled ? "" : error.localizedDescription
                feedbackSeverity = cancelled ? .info : .error
            }
        }
    }

    private func exportText() {
        setFeedback(String(localized: "Choose where to save…"))
        ExportManager.exportSingle(record: record) { result in
            switch result {
            case .success:
                feedback = String(localized: "Text document exported")
                feedbackSeverity = .success
            case .failure(let error):
                let cancelled = ExportManager.isCancellation(error)
                feedback = cancelled ? "" : error.localizedDescription
                feedbackSeverity = cancelled ? .info : .error
            }
        }
    }

    private func translateMissingSegments() async {
        guard !isFillingTranslations else { return }
        isFillingTranslations = true
        setFeedback(String(localized: "Translating missing text…"))
        if !translationManager.hasSession {
            translationManager.requestSessionRefresh()
            for _ in 0..<10 where !translationManager.hasSession {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard translationManager.hasSession else {
            isFillingTranslations = false
            setFeedback(String(localized: "Translation service is not ready. Try again."), severity: .error)
            return
        }
        // UX-06 / PSY-05：>2s 的等待必须有进度 —— 翻译 3/12…
        let missing = drafts.indices.filter {
            drafts[$0].translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var completed = 0
        for index in missing {
            completed += 1
            setFeedback(String(
                format: String(localized: "Translating %lld/%lld…"),
                completed,
                missing.count
            ))
            drafts[index].translated = await translationManager.translate(drafts[index].original)
        }
        record.segments = drafts.map {
            TranscriptSegment(
                id: $0.id,
                original: $0.original,
                translated: $0.translated,
                timestamp: $0.timestamp,
                isFinal: $0.isFinal,
                speaker: $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        historyStore.save()
        isFillingTranslations = false
        setFeedback(String(localized: "Translations updated"), severity: .success)
    }

    private func retranslate(segmentID: UUID) async {
        guard let index = drafts.firstIndex(where: { $0.id == segmentID }) else { return }
        setFeedback(String(localized: "Translating…"))
        let translated = await translationManager.translate(drafts[index].original)
        guard !translated.isEmpty else {
            setFeedback(String(localized: "Translation service is not ready. Try again."), severity: .error)
            return
        }
        drafts[index].translated = translated
        setFeedback(String(localized: "Translation updated"), severity: .success)
    }
}
