import AppKit
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI

struct ConfigSettingsView: View {
    static let windowID = "config-editor"

    @State private var snapshot: ConfigSourceSnapshot = ConfigSource.cmux.snapshot(environment: .live())
    @State private var cmuxDraft = ""
    @State private var cmuxLastLoadedContents = ""
    @State private var statusMessage = ""
    @State private var statusIsError = false

    private var hasUnsavedCmuxChanges: Bool {
        cmuxDraft != cmuxLastLoadedContents
    }

    private var currentBannerText: String {
        String(
            localized: "settings.config.banner.cmux",
            defaultValue: "This is the cmux config file. Edit it here, then Save to reload cmux."
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshot.displayPaths, id: \.self) { path in
                    Text(verbatim: path)
                        .cmuxFont(size: 12, weight: .regular, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .copyOnlyTextSelection(for: path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ConfigSettingsBanner(text: currentBannerText)

            ConfigSettingsTextView(text: $cmuxDraft, isEditable: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(editorBackground)
                .accessibilityIdentifier("ConfigSettingsCmuxEditor")
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .cmuxFont(.caption)
                        .foregroundColor(statusIsError ? .red : .secondary)
                }

                Spacer(minLength: 0)

                Button(String(localized: "settings.config.action.openEditor", defaultValue: "Open in Editor…")) {
                    openCurrentSourceInEditor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(String(localized: "settings.config.action.revealFinder", defaultValue: "Reveal in Finder")) {
                    revealCurrentSourceInFinder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(String(localized: "settings.config.action.reload", defaultValue: "Reload")) {
                    reloadFromDisk()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(String(localized: "settings.config.action.save", defaultValue: "Save")) {
                    saveCmuxConfig()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasUnsavedCmuxChanges)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .background(
            WindowAccessor { window in
                configureWindow(window)
            }
        )
        .onAppear {
            refreshSnapshots(preserveCmuxDraft: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshSnapshots(preserveCmuxDraft: true)
        }
    }

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .textBackgroundColor))
    }

    private var openEditorButtonTitle: String {
        String(localized: "settings.config.action.openEditor", defaultValue: "Open in Editor…")
    }

    private var revealFinderButtonTitle: String {
        String(localized: "settings.config.action.revealFinder", defaultValue: "Reveal in Finder")
    }

    private func configureWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cmux.configEditor")
        window.minSize = NSSize(width: 700, height: 500)
        window.tabbingMode = .disallowed
        window.animationBehavior = .utilityWindow
        // The Config editor is a top-level peer window, not a floating
        // inspector: clicking the main window must be able to raise it above
        // the editor (https://github.com/manaflow-ai/cmux/issues/5081).
        window.adoptCmuxPeerWindowLevel()
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }

    private func refreshSnapshots(preserveCmuxDraft: Bool) {
        let wasDirty = hasUnsavedCmuxChanges
        let environment = ConfigSourceEnvironment.live()
        let newSnapshot = ConfigSource.cmux.snapshot(environment: environment)
        snapshot = newSnapshot

        if !preserveCmuxDraft || !wasDirty {
            cmuxDraft = newSnapshot.contents
        }
        cmuxLastLoadedContents = newSnapshot.contents
    }

    private func reloadFromDisk() {
        refreshSnapshots(preserveCmuxDraft: false)
        let completion: GhosttyApp.ConfigurationReloadCompletion = {
            statusMessage = String(
                localized: "settings.config.status.reloaded",
                defaultValue:
                    "Reloaded configuration from disk."
            )
            statusIsError = false
        }
        let completionWasAdmitted: Bool
        if let appDelegate = AppDelegate.shared {
            completionWasAdmitted =
                appDelegate.reloadConfiguration(
                    source: "settings.configWindow.reload",
                    completion: completion
                )
        } else {
            completionWasAdmitted =
                GhosttyApp.shared.reloadConfiguration(
                    source: "settings.configWindow.reload",
                    completion: completion
                )
        }
        if !completionWasAdmitted {
            reportReloadAdmissionFailure()
        }
    }

    private func saveCmuxConfig() {
        let environment = ConfigSourceEnvironment.live()

        do {
            try environment.writeCmuxConfigContents(cmuxDraft)
            cmuxLastLoadedContents = cmuxDraft
            refreshSnapshots(preserveCmuxDraft: true)
            let completion:
                GhosttyApp.ConfigurationReloadCompletion = {
                    statusMessage = String(
                        localized:
                            "settings.config.status.saved",
                        defaultValue:
                            "Saved to cmux config and reloaded."
                    )
                    statusIsError = false
                }
            let completionWasAdmitted: Bool
            if let appDelegate = AppDelegate.shared {
                completionWasAdmitted =
                    appDelegate.reloadConfiguration(
                        source: "settings.configWindow.save",
                        completion: completion
                    )
            } else {
                completionWasAdmitted =
                    GhosttyApp.shared.reloadConfiguration(
                        source: "settings.configWindow.save",
                        completion: completion
                    )
            }
            if !completionWasAdmitted {
                reportReloadAdmissionFailure()
            }
        } catch {
            NSSound.beep()
            statusMessage = String(
                localized: "settings.config.status.saveFailed",
                defaultValue: "Couldn't save the cmux config."
            )
            statusIsError = true
        }
    }

    private func reportReloadAdmissionFailure() {
        statusMessage = String(
            localized:
                "settings.config.status.reloadBusy",
            defaultValue:
                "Reload queued; too many requests are pending to confirm completion."
        )
        statusIsError = true
    }

    private func openCurrentSourceInEditor() {
        guard let url = materializedCmuxConfigURL() else { return }
        PreferredEditorService(defaults: .standard).open(url)
    }

    private func revealCurrentSourceInFinder() {
        guard let url = materializedCmuxConfigURL() else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func materializedCmuxConfigURL() -> URL? {
        let environment = ConfigSourceEnvironment.live()
        do {
            return try environment.materializeCmuxConfigFileIfNeeded()
        } catch {
            NSSound.beep()
            statusMessage = String(
                localized: "settings.config.status.openFailed",
                defaultValue: "Couldn't open the cmux config."
            )
            statusIsError = true
            return nil
        }
    }
}

private struct ConfigSettingsBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .cmuxFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct ConfigSettingsTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.string = text
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = context.coordinator
        context.coordinator.installGlobalFontObserver(for: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text

        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        context.coordinator.applyGlobalFont(to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var globalFontObserver: GlobalFontMagnificationChangeObserver?

        init(text: Binding<String>) {
            self.text = text
        }

        func installGlobalFontObserver(for textView: NSTextView) {
            applyGlobalFont(to: textView)
            globalFontObserver = GlobalFontMagnificationChangeObserver { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyGlobalFont(to: textView)
            }
        }

        func applyGlobalFont(to textView: NSTextView) {
            textView.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
