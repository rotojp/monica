import SwiftUI

// MARK: - List

struct ContactsListView: View {
    @Environment(AppModel.self) private var model

    @State private var contacts: [SyncContact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filtered: [SyncContact] {
        guard !searchText.isEmpty else { return contacts }
        return contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage, contacts.isEmpty {
                    ErrorBanner(message: errorMessage) { Task { await load() } }
                } else if contacts.isEmpty && isLoading {
                    ProgressView("Loading people…")
                } else {
                    List(filtered.sorted { $0.displayName < $1.displayName }) { contact in
                        NavigationLink(value: contact.id) {
                            ContactRow(contact: contact)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search your contacts")
                    .refreshable { await load() }
                }
            }
            .navigationTitle("People")
            .navigationDestination(for: String.self) { id in
                ContactDetailView(contactID: id)
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        isLoading = true
        errorMessage = nil
        do {
            contacts = try await backend.fetchContacts()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct ContactRow: View {
    let contact: SyncContact

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(initials: contact.initials)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(contact.displayName)
                        .font(.body)
                    if contact.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if let subtitle = [contact.jobTitle, contact.company]
                    .compactMap({ $0 })
                    .filter({ !$0.isEmpty })
                    .joined(separator: " · ")
                    .nilIfEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Detail

struct ContactDetailView: View {
    @Environment(AppModel.self) private var model
    let contactID: String

    @State private var contact: SyncContact?
    @State private var tasks: [SyncTask] = []
    @State private var reminders: [SyncReminder] = []
    @State private var activities: [SyncActivity] = []
    @State private var calls: [SyncCall] = []
    @State private var errorMessage: String?
    @State private var showLogCall = false
    @State private var showAddTask = false

    var body: some View {
        Group {
            if let contact {
                detailList(for: contact)
            } else if let errorMessage {
                ErrorBanner(message: errorMessage) { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(contact?.displayName ?? "Contact")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showLogCall) {
            LogCallSheet(contactID: contactID) { await load() }
        }
        .sheet(isPresented: $showAddTask) {
            AddTaskSheet(contactID: contactID) { await load() }
        }
    }

    @ViewBuilder
    private func detailList(for contact: SyncContact) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    InitialsAvatar(initials: contact.initials, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.displayName).font(.title3.bold())
                        if let line = [contact.jobTitle, contact.company]
                            .compactMap({ $0 })
                            .filter({ !$0.isEmpty })
                            .joined(separator: " at ")
                            .nilIfEmpty {
                            Text(line).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                if let webURL = URL(string: contact.webURL) {
                    Link(destination: webURL) {
                        Label("Open in Monica", systemImage: "safari")
                    }
                }
            }

            if !contact.emails.isEmpty || !contact.phones.isEmpty {
                Section("Contact information") {
                    ForEach(contact.emails, id: \.self) { email in
                        if let url = URL(string: "mailto:\(email)") {
                            Link(destination: url) {
                                Label(email, systemImage: "envelope")
                            }
                        }
                    }
                    ForEach(contact.phones, id: \.self) { phone in
                        let dialable = ContactsSyncEngine.normalizedPhone(phone)
                        if let url = URL(string: "tel:\(dialable)"), !dialable.isEmpty {
                            Link(destination: url) {
                                Label(phone, systemImage: "phone")
                            }
                        }
                    }
                }
            }

            if let birthday = contact.birthday {
                Section("Birthday") {
                    Label(birthdayText(birthday), systemImage: "birthday.cake")
                }
            }

            if !contact.addresses.isEmpty {
                Section("Addresses") {
                    ForEach(Array(contact.addresses.enumerated()), id: \.offset) { _, address in
                        let query = address.oneLine
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let url = URL(string: "https://maps.apple.com/?q=\(query)") {
                            Link(destination: url) {
                                Label {
                                    VStack(alignment: .leading) {
                                        if let label = address.label, !label.isEmpty {
                                            Text(label).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(address.oneLine)
                                    }
                                } icon: {
                                    Image(systemName: "mappin.and.ellipse")
                                }
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(tasks) { task in
                    Label(
                        task.title,
                        systemImage: task.isCompleted ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                }
                Button {
                    showAddTask = true
                } label: {
                    Label("Add a task", systemImage: "plus")
                }
            } header: {
                Text("Tasks")
            }

            if !reminders.isEmpty {
                Section("Reminders") {
                    ForEach(reminders) { reminder in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.title)
                            if let next = reminder.nextDate?.nextLocalDate() {
                                Text(next.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(calls) { call in
                    VStack(alignment: .leading, spacing: 2) {
                        if let date = call.date {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(call.content ?? "Call")
                    }
                }
                Button {
                    showLogCall = true
                } label: {
                    Label("Log a call", systemImage: "phone.badge.plus")
                }
            } header: {
                Text("Phone calls")
            }

            if !activities.isEmpty {
                Section("Activities") {
                    ForEach(activities) { activity in
                        VStack(alignment: .leading, spacing: 2) {
                            if let date = activity.date?.nextLocalDate() {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(activity.title)
                        }
                    }
                }
            }
        }
    }

    private func birthdayText(_ birthday: SyncBirthday) -> String {
        var components = DateComponents()
        components.day = birthday.day
        components.month = birthday.month
        components.year = birthday.year
        guard let date = Calendar.current.date(from: components) else {
            return "\(birthday.day).\(birthday.month)."
        }
        if birthday.year != nil {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return date.formatted(.dateTime.day().month(.wide))
    }

    private func load() async {
        guard let backend = model.backend else { return }
        errorMessage = nil
        do {
            async let contactRequest = backend.fetchContact(id: contactID)
            async let tasksRequest = backend.fetchContactTasks(contactID: contactID)
            async let remindersRequest = backend.fetchContactReminders(contactID: contactID)
            async let activitiesRequest = backend.fetchContactActivities(contactID: contactID)
            async let callsRequest = backend.fetchContactCalls(contactID: contactID)
            contact = try await contactRequest
            tasks = (try? await tasksRequest) ?? []
            reminders = (try? await remindersRequest) ?? []
            activities = (try? await activitiesRequest) ?? []
            calls = (try? await callsRequest) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Compose sheets

private struct LogCallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let contactID: String
    let onSaved: () async -> Void

    @State private var content = ""
    @State private var calledAt = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $calledAt, displayedComponents: .date)
                TextField("What did you talk about?", text: $content, axis: .vertical)
                    .lineLimit(4...8)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Log a call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let backend = model.backend else { return }
        isSaving = true
        Task {
            do {
                try await backend.logCall(contactID: contactID, content: content, date: calledAt)
                await onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct AddTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let contactID: String
    let onSaved: () async -> Void

    @State private var title = ""
    @State private var details = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Details (optional)", text: $details, axis: .vertical)
                    .lineLimit(3...6)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add a task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let backend = model.backend else { return }
        isSaving = true
        Task {
            do {
                try await backend.createTask(contactID: contactID, title: title, details: details)
                await onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
