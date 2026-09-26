import SwiftUI

struct HomeView: View {
    private enum Destination: Hashable {
        case courses
        case history
        case settings
        case course(UUID)
    }

    @Environment(HistoryStore.self) private var historyStore
    @State private var selection: Destination? = .courses
    @State private var showNewCourse = false
    @State private var courseToDelete: Course?
    @State private var settingsTranslationManager = TranslationManager()
    /// UX-01：录音中拦截侧栏切换后，给一条 2.5 秒的提示条。
    @State private var showRecordingLockHint = false

    /// 录音是否正在进行（starting/recording/paused/interrupted/收尾保存）。
    /// 在 body 里读一次即可建立 observation，录音页写入时这里会自动刷新。
    private var isRecordingLocked: Bool { RecordingActivity.shared.isActive }

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding(locked: isRecordingLocked)) {
                Section {
                    Label("Courses", systemImage: "books.vertical").tag(Destination.courses)
                    Label("All Recordings", systemImage: "clock.arrow.circlepath").tag(Destination.history)
                    Label("Settings", systemImage: "gearshape").tag(Destination.settings)
                }

                Section("My Courses") {
                    ForEach(historyStore.courses) { course in
                        HStack {
                            Image(systemName: "book.fill").foregroundColor(.accentColor)
                            VStack(alignment: .leading) {
                                Text(course.name)
                                // task-8：排课描述（每周/每月/单次；老数据回退 createdAt）。
                                Text(course.scheduleDescription)
                                    .font(.caption).foregroundColor(.secondary)
                                Text("\(historyStore.recordsForCourse(course).count) recordings")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .tag(Destination.course(course.id))
                        .contextMenu {
                            Button("Delete Course", role: .destructive) {
                                courseToDelete = course
                            }
                        }
                    }
                }
            }
            .navigationTitle("LingoClass")
            // 录音中把侧栏整体置灰（仍可点击，点击会被 selectionBinding 拦下并提示）。
            .opacity(isRecordingLocked ? 0.55 : 1)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewCourse = true } label: { Label("New Course", systemImage: "plus") }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 260)
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) {
            if showRecordingLockHint {
                Label(
                    String(localized: "Recording in progress. End the recording first."),
                    systemImage: "mic.circle.fill"
                )
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 28)
            }
        }
        // id 变化会取消上一次计时，保证同一时刻只有一条提示在跑。
        .task(id: showRecordingLockHint) {
            guard showRecordingLockHint else { return }
            try? await Task.sleep(for: .seconds(2.5))
            showRecordingLockHint = false
        }
        .sheet(isPresented: $showNewCourse) {
            NewCourseView { course in
                showNewCourse = false
                selection = .course(course.id)
            }
        }
        .confirmationDialog("Delete Course", isPresented: Binding(
            get: { courseToDelete != nil }, set: { if !$0 { courseToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let courseToDelete {
                    // deleteCourse 之后 courseToDelete 已失效，先留下 id。
                    let courseID = courseToDelete.id
                    historyStore.deleteCourse(courseToDelete)
                    if selection == .course(courseID) { selection = .courses }
                }
                courseToDelete = nil
            }
            Button("Cancel", role: .cancel) { courseToDelete = nil }
        } message: {
            Text("Are you sure you want to delete this course? All recordings will be removed.")
        }
        .modifier(TranslationSessionCompat(manager: settingsTranslationManager))
        .alert("Storage Error", isPresented: Binding(
            get: { !historyStore.lastErrorMessage.isEmpty },
            set: { if !$0 { historyStore.lastErrorMessage = "" } }
        )) {
            Button("OK") { historyStore.lastErrorMessage = "" }
        } message: {
            Text(historyStore.lastErrorMessage)
        }
    }

    /// 录音进行中把 selection 的写入拦下来：不切换、不卸载录音页，只弹一条提示。
    private func selectionBinding(locked: Bool) -> Binding<Destination?> {
        Binding(
            get: { selection },
            set: { newValue in
                guard !locked || newValue == selection else {
                    showRecordingLockHint = true
                    return
                }
                selection = newValue
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .course(let id):
            if let course = historyStore.courses.first(where: { $0.id == id }) {
                CourseDetailView(course: course) { selection = .courses }
            } else {
                coursesOverview
            }
        case .history:
            HistoryView(showsDoneButton: false)
        case .settings:
            SettingsView(translationManager: settingsTranslationManager, showsDoneButton: false)
        case .courses, .none:
            coursesOverview
        }
    }

    private var coursesOverview: some View {
        VStack(spacing: 18) {
            if historyStore.courses.isEmpty {
                ContentUnavailableView("No Courses Yet", systemImage: "book.closed", description: Text("Create a course to start translating lectures."))
                Button("New Course") { showNewCourse = true }.buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "books.vertical.fill").font(.system(size: 48)).foregroundColor(.accentColor)
                Text("Select a course from the sidebar").font(.title2)
                Text("Each new recording is saved as a separate transcript.").foregroundColor(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
