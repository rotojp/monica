import SwiftUI

/// All tasks across the account. Completing a task here writes straight to
/// the Monica server; the mirrored reminder follows on the next sync.
struct TasksView: View {
    @Environment(AppModel.self) private var model

    @State private var tasks: [MonicaTask] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var openTasks: [MonicaTask] { tasks.filter { !$0.isCompleted } }
    private var completedTasks: [MonicaTask] { tasks.filter(\.isCompleted) }

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage, tasks.isEmpty {
                    ErrorBanner(message: errorMessage) { Task { await load() } }
                } else if tasks.isEmpty && isLoading {
                    ProgressView("Loading tasks…")
                } else if tasks.isEmpty {
                    ContentUnavailableView(
                        "No tasks",
                        systemImage: "checklist",
                        description: Text("Tasks you add in Monica (or from a contact's page here) show up in this list and in the Reminders app.")
                    )
                } else {
                    List {
                        if !openTasks.isEmpty {
                            Section("To do") {
                                ForEach(openTasks) { task in
                                    TaskRow(task: task) { toggle(task) }
                                }
                            }
                        }
                        if !completedTasks.isEmpty {
                            Section("Completed") {
                                ForEach(completedTasks) { task in
                                    TaskRow(task: task) { toggle(task) }
                                }
                            }
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Tasks")
            .task { await load() }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        isLoading = true
        errorMessage = nil
        do {
            tasks = try await client.fetchAllTasks()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func toggle(_ task: MonicaTask) {
        guard let client = model.client else { return }
        Task {
            do {
                try await client.updateTask(
                    task,
                    title: task.title ?? "Task",
                    completed: !task.isCompleted
                )
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct TaskRow: View {
    let task: MonicaTask
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title ?? "Task")
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                if let contact = task.contact {
                    Text(contact.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
