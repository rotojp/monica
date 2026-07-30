import SwiftUI

// MARK: - List

struct ContactsListView: View {
    @Environment(AppModel.self) private var model

    @State private var contacts: [MonicaContact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filtered: [MonicaContact] {
        let visible = contacts.filter { ($0.isPartial ?? false) == false }
        guard !searchText.isEmpty else { return visible }
        return visible.filter {
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
            .navigationDestination(for: Int.self) { id in
                ContactDetailView(contactID: id)
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        isLoading = true
        errorMessage = nil
        do {
            contacts = try await client.fetchAllContacts()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct ContactRow: View {
    let contact: MonicaContact

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(initials: contact.initials)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(contact.displayName)
                        .font(.body)
                    if contact.isStarred == true {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if let career = contact.information?.career,
                   let subtitle = [career.job, career.company]
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
    let contactID: Int

    @State private var contact: MonicaContact?
    @State private var tasks: [MonicaTask] = []
    @State private var reminders: [MonicaReminder] = []
    @State private var activities: [MonicaActivity] = []
    @State private var calls: [MonicaCall] = []
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
    private func detailList(for contact: MonicaContact) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    InitialsAvatar(initials: contact.initials, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.displayName).font(.title3.bold())
                        if let career = contact.information?.career,
                           let line = [career.job, career.company]
                               .compactMap({ $0 })
                               .filter({ !$0.isEmpty })
                               .joined(separator: " at ")
                               .nilIfEmpty {
                            Text(line).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                if let webURL = model.client?.serverConfig
                    .webURL(forContactID: contact.id, hashID: contact.hashID) {
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

            if let birthdate = contact.information?.dates?.birthdate?.date {
                Section("Birthday") {
                    Label(
                        birthdate.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "birthday.cake"
                    )
                }
            }

            if let addresses = contact.addresses, !addresses.isEmpty {
                Section("Addresses") {
                    ForEach(addresses) { address in
                        let query = address.oneLine
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let url = URL(string: "https://maps.apple.com/?q=\(query)") {
                            Link(destination: url) {
                                Label {
                                    VStack(alignment: .leading) {
                                        if let name = address.name, !name.isEmpty {
                                            Text(name).font(.caption).foregroundStyle(.secondary)
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
                        task.title ?? "Task",
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
                            Text(reminder.title ?? "Reminder")
                            if let next = reminder.nextExpectedDate {
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
                        if let calledAt = call.calledAt {
                            Text(calledAt.formatted(date: .abbreviated, time: .omitted))
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
                            if let happenedAt = activity.happenedAt {
                                Text(happenedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(activity.summary ?? "Activity")
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        errorMessage = nil
        do {
            async let contactRequest = client.fetchContact(id: contactID)
            async let tasksRequest = client.fetchTasks(contactID: contactID)
            async let remindersRequest = client.fetchReminders(contactID: contactID)
            async let activitiesRequest = client.fetchActivities(contactID: contactID)
            async let callsRequest = client.fetchCalls(contactID: contactID)
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

    let contactID: Int
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
        guard let client = model.client else { return }
        isSaving = true
        Task {
            do {
                try await client.createCall(
                    contactID: contactID, content: content, calledAt: calledAt
                )
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

    let contactID: Int
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
        guard let client = model.client else { return }
        isSaving = true
        Task {
            do {
                try await client.createTask(
                    contactID: contactID, title: title, description: details
                )
                await onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
