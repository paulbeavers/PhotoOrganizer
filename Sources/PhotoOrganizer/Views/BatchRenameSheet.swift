import PhotoOrganizerCore
import SwiftUI

/// Renames one or many photos from a template, previewing every new name before anything changes.
struct BatchRenameSheet: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]

    @AppStorage("renameTemplate") private var savedTemplate = "{date:yyyyMMdd}_{n:4}"
    @State private var template = ""
    @State private var startNumber = 1
    @State private var plan: RenamePlan?

    private static let tokens: [(token: String, help: String)] = [
        ("{name}", "Original name"),
        ("{n:4}", "Sequence number, 4 digits"),
        ("{date}", "Capture date (yyyy-MM-dd)"),
        ("{date:yyyyMMdd}", "Capture date, custom format"),
        ("{time}", "Capture time (HHmmss)"),
        ("{camera}", "Camera model"),
        ("{folder}", "Folder name"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(urls.count == 1 ? "Rename Photo" : "Rename \(urls.count) Photos").font(.headline)

            TextField("Template", text: $template)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            HStack(spacing: 6) {
                ForEach(Self.tokens, id: \.token) { item in
                    Button(item.token) { template += item.token }
                        .help(item.help)
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            HStack {
                Stepper("Start numbering at \(startNumber)", value: $startNumber, in: 0...999_999)
                Spacer()
                Text("Extensions are kept. RAW+JPEG pairs get the same name and keep their shared sidecar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            preview

            if let problems = plan?.problems, !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems.prefix(5), id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    guard let plan else { return }
                    savedTemplate = template
                    browser.rename(plan.items)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || !(plan?.problems.isEmpty ?? false) || plan?.items.allSatisfy(\.isUnchanged) == true)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .onAppear {
            // A single photo starts from its current name; batches from the last template used.
            template = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : savedTemplate
        }
        .task(id: "\(template)|\(startNumber)") {
            let urls = urls, template = template, start = startNumber
            try? await Task.sleep(for: .milliseconds(150))  // debounce typing
            guard !Task.isCancelled else { return }
            plan = await Task.detached(priority: .userInitiated) {
                RenamePlan(urls: urls, template: template, startNumber: start)
            }.value
        }
    }

    private var preview: some View {
        Table(plan?.items ?? []) {
            TableColumn("Current Name") { item in
                Text(item.oldNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            TableColumn("New Name") { item in
                Text(item.newNames.joined(separator: ", "))
                    .foregroundStyle(item.isUnchanged ? .secondary : .primary)
            }
        }
        .overlay {
            if plan == nil { ProgressView() }
        }
    }
}
