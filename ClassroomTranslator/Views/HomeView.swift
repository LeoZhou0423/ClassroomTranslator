import SwiftUI

struct HomeView: View {
    @Environment(HistoryStore.self) private var historyStore
    @State private var showNewCourse = false
    @State private var selectedCourse: Course?
    @State private var navigateToCourse = false
    @State private var courseToDelete: Course?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if historyStore.courses.isEmpty {
                    emptyState
                } else {
                    courseList
                }
            }
            .navigationTitle("My Courses")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showNewCourse = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(isPresented: $showNewCourse) {
                NewCourseView(onCreate: { course in
                    selectedCourse = course
                    navigateToCourse = true
                })
            }
            .navigationDestination(isPresented: $navigateToCourse) {
                if let course = selectedCourse {
                    CourseDetailView(course: course)
                }
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
                Label("New Course", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var courseList: some View {
        List {
            ForEach(historyStore.courses) { course in
                Button(action: {
                    selectedCourse = course
                    navigateToCourse = true
                }) {
                    courseRow(course)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive, action: {
                        courseToDelete = course
                        showDeleteConfirm = true
                    }) {
                        Label("Delete Course", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deleteCourses)
        }
        .listStyle(.inset)
        .confirmationDialog(
            "Delete Course",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let course = courseToDelete {
                    historyStore.deleteCourse(course)
                    courseToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { courseToDelete = nil }
        } message: {
            Text("Are you sure you want to delete this course? All recordings will be removed.")
        }
    }

    private func courseRow(_ course: Course) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "book.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name)
                        .font(.title3).bold()
                    Text(course.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 16) {
                Label(course.accentName, systemImage: "waveform")
                Label("\(historyStore.recordsForCourse(course).count) 次录音",
                      systemImage: "mic.fill")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
    }

    private func deleteCourses(at offsets: IndexSet) {
        for index in offsets {
            historyStore.deleteCourse(historyStore.courses[index])
        }
    }
}
