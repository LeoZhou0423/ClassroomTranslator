import SwiftUI

struct HomeView: View {
    @Environment(HistoryStore.self) private var historyStore
    @State private var showNewCourse = false

    var body: some View {
        NavigationStack {
            Group {
                if historyStore.courses.isEmpty {
                    emptyState
                } else {
                    courseList
                }
            }
            .navigationTitle(String(localized: "My Courses"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showNewCourse = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewCourse) {
                NewCourseView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.closed")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("No Courses Yet")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Tap + to create your first course")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button(action: { showNewCourse = true }) {
                Label(String(localized: "New Course"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var courseList: some View {
        List {
            ForEach(historyStore.courses) { course in
                NavigationLink(destination: CourseDetailView(course: course)) {
                    courseRow(course)
                }
            }
            .onDelete(perform: deleteCourses)
        }
    }

    private func courseRow(_ course: Course) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(course.name)
                .font(.headline)
            HStack(spacing: 12) {
                Label(course.accentName, systemImage: "waveform")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label("\(historyStore.recordsForCourse(course).count) sessions",
                      systemImage: "doc.text")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(course.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func deleteCourses(at offsets: IndexSet) {
        for index in offsets {
            historyStore.deleteCourse(historyStore.courses[index])
        }
    }
}
