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

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewCourse = true } label: { Label("New Course", systemImage: "plus") }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 260)
        } detail: {
            detail
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
                    historyStore.deleteCourse(courseToDelete)
                    if selection == .course(courseToDelete.id) { selection = .courses }
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
