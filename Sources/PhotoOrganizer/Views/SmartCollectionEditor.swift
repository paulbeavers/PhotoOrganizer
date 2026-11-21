import PhotoOrganizerCore
import SwiftUI

/// Creates or edits a smart collection: a name, where to look, and rules that photos must match.
struct SmartCollectionEditor: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let request: SmartEditorRequest

    @State private var name: String
    @State private var matchAll: Bool
    @State private var rules: [SmartRule]
    /// Cameras, lenses and keywords in the photos (nil while they're being read).
    @State private var found: RuleChoices?

    init(request: SmartEditorRequest) {
        self.request = request
        let collection = request.collection
        let rules = collection.effectiveRules
        _name = State(initialValue: collection.name)
        _matchAll = State(initialValue: rules.matchAll)
        _rules = State(initialValue: rules.rules)
    }

    /// A rule's binding, found by ID. (Not `ForEach($rules)`: its index-based bindings crash when a
    /// removed row's controls read them one last time.)
    private func binding(for rule: SmartRule) -> Binding<SmartRule> {
        let id = rule.id
        return Binding(
            get: { rules.first { $0.id == id } ?? rule },
            set: { new in
                if let index = rules.firstIndex(where: { $0.id == id }) { rules[index] = new }
            })
    }

    private var needsChoices: Bool { rules.contains { [.camera, .lens, .keyword].contains($0.field) } }

    private func choices(for field: SmartField) -> [String]? {
        switch field {
        case .camera: found?.cameras
        case .lens: found?.lenses
        // Keywords.txt is at hand right away; the photos' own keywords join once read.
        case .keyword: found?.keywords ?? RuleChoices.unique(browser.dataFolder.keywords.paths)
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(request.isNew ? "New Smart Collection" : "Edit Smart Collection")
                .font(.headline)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Herons this year"))
                } footer: {
                    Text("Searches every photo in the data folder and in the sidebar folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(rules) { rule in
                        RuleRow(rule: binding(for: rule), choices: choices(for: rule.field),
                                isLoading: found == nil && needsChoices) {
                            rules.removeAll { $0.id == rule.id }
                        }
                    }
                    Button {
                        rules.append(SmartRule(field: .keyword))
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Include photos that match")
                        Picker("", selection: $matchAll) {
                            Text("all").tag(true)
                            Text("any").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("of these rules:")
                    }
                } footer: {
                    if rules.isEmpty {
                        Text("No rules: every photo is included.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        // Read the cameras, lenses and keywords once a rule needs them.
        .task(id: needsChoices) {
            guard needsChoices, found == nil else { return }
            let choices = await browser.smartRuleChoices()
            guard !Task.isCancelled else { return }
            found = choices
        }
    }

    private func save() {
        var collection = request.collection
        collection.name = name.trimmingCharacters(in: .whitespaces)
        collection.rules = SmartRules(matchAll: matchAll, rules: rules)
        collection.folders = []   // smart collections search the data folder and sidebar folders
        browser.saveSmartCollection(collection)
        dismiss()
    }
}

/// One rule: field, condition, and a value control that suits the field.
private struct RuleRow: View {
    @Binding var rule: SmartRule
    /// Cameras or lenses to choose from (camera and lens rules).
    var choices: [String]?
    var isLoading = false
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: Binding(get: { rule.field }, set: { field in
                guard field != rule.field else { return }
                rule = SmartRule(id: rule.id, field: field)   // fresh condition and value for the new field
            })) {
                ForEach(SmartField.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)

            Picker("Condition", selection: Binding(get: { rule.op }, set: { op in
                let wasRelative = rule.op == .inLastDays
                rule.op = op
                // Switching between "in the last N days" and a calendar date changes the value's kind.
                if rule.field.kind == .date, wasRelative != (op == .inLastDays) {
                    rule.value = op == .inLastDays ? "7" : SmartRule.dayFormatter.string(from: Date())
                }
            })) {
                ForEach(rule.field.operators, id: \.self) { Text($0.displayName(for: rule.field)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)

            if rule.op.takesValue {
                valueEditor
            } else {
                Spacer()
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this rule")
        }
    }

    @ViewBuilder private var valueEditor: some View {
        switch rule.field.kind {
        case .text where rule.field == .camera || rule.field == .lens:
            choiceEditor
        case .keyword:
            choiceEditor
        case .text:
            TextField("", text: $rule.value, prompt: Text("text"))
        case .rating:
            Picker("Rating", selection: $rule.value) {
                Text("Unrated").tag("0")
                ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag(String($0)) }
            }
            .labelsHidden()
        case .flag:
            Picker("Flag", selection: $rule.value) {
                Text("Picked").tag("picked")
                Text("Unflagged").tag("unflagged")
                Text("Rejected").tag("rejected")
            }
            .labelsHidden()
        case .label:
            Picker("Label", selection: $rule.value) {
                ForEach(ColorLabel.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .labelsHidden()
        case .fileType:
            Picker("Type", selection: $rule.value) {
                ForEach(SmartFileType.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden()
        case .date:
            if rule.op == .inLastDays {
                HStack(spacing: 4) {
                    TextField("", value: Binding(get: { Int(rule.value) ?? 7 }, set: { rule.value = String(max(1, $0)) }),
                              format: .number)
                        .frame(width: 60)
                    Text("days")
                    Spacer()
                }
            } else {
                DatePicker("", selection: Binding(
                    get: { SmartRule.dayFormatter.date(from: rule.value) ?? Date() },
                    set: { rule.value = SmartRule.dayFormatter.string(from: $0) }),
                    displayedComponents: .date)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension RuleRow {
    /// Camera / lens / keyword: picked from the names found in the photos ("contains" on a camera or
    /// lens is typed, with the names as suggestions).
    @ViewBuilder var choiceEditor: some View {
        let names = choices ?? []
        let noun = switch rule.field {
        case .camera: "cameras"
        case .lens: "lenses"
        default: "keywords"
        }
        let isKeyword = rule.field == .keyword
        if names.isEmpty && isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding \(noun)…").foregroundStyle(.secondary)
                Spacer()
            }
        } else if (rule.op == .is || isKeyword) && !names.isEmpty {
            Picker(rule.field.displayName, selection: $rule.value) {
                if rule.value.isEmpty { Text("Choose…").tag("") }
                if !rule.value.isEmpty && !names.contains(rule.value) {
                    // Saved earlier, no longer in any photo.
                    Text(isKeyword ? Keyword.display(rule.value) : rule.value).tag(rule.value)
                }
                ForEach(names, id: \.self) { name in
                    Text(isKeyword ? Keyword.display(name) : name).tag(name)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 4) {
                TextField("", text: $rule.value,
                          prompt: Text(names.isEmpty ? "No \(noun) found in your photos" : isKeyword ? "e.g. Birds > Heron" : "text"))
                if !names.isEmpty {
                    Menu {
                        ForEach(names, id: \.self) { name in
                            Button(isKeyword ? Keyword.display(name) : name) { rule.value = name }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose from the \(noun) in your photos")
                }
            }
        }
    }
}

/// "Keyword contains Birds and Rating is at least ★★★" for the filter bar.
enum SmartRulesSummary {
    static func text(for rules: SmartRules) -> String {
        guard !rules.rules.isEmpty else { return "Every photo" }
        let parts = rules.rules.map { rule -> String in
            let op = rule.op.displayName(for: rule.field)
            guard rule.op.takesValue else { return "\(rule.field.displayName) \(op)" }
            let value: String
            switch rule.field.kind {
            case .rating: value = rule.value == "0" ? "unrated" : String(repeating: "★", count: Int(rule.value) ?? 0)
            case .fileType: value = SmartFileType(rawValue: rule.value)?.displayName ?? rule.value
            case .date where rule.op == .inLastDays: value = "\(rule.value) days"
            case .keyword: value = Keyword.display(rule.value)
            default: value = rule.value
            }
            return "\(rule.field.displayName) \(op) \(value)"
        }
        return parts.joined(separator: rules.matchAll ? " and " : " or ")
    }
}
