import AppKit
import CmuxFoundation
import SwiftUI

struct AboutPanelView: View {
    let showLicenses: () -> Void

    @Environment(\.openURL) private var openURL

    private let repository = "https://github.com/xhqing/cmux"
    private var githubURL: URL? { URL(string: repository) }
    private let docsURL = URL(string: "https://cmux.com/docs")

    /// Our own release version (`VERSION`, e.g. `0.65.2.2-xhqing.12`).
    ///
    /// `CFBundleShortVersionString` has to stay numeric-only for Apple tooling, so the
    /// build injects the full string under `CMUXVersion`; older builds that predate that
    /// key fall back to the numeric bundle version.
    private var version: String? {
        if let value = Bundle.main.infoDictionary?["CMUXVersion"] as? String, !value.isEmpty {
            return value
        }
        let env = ProcessInfo.processInfo.environment["CMUX_VERSION"] ?? ""
        if !env.isEmpty {
            return env
        }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? {
        if let value = Bundle.main.infoDictionary?["CMUXCommit"] as? String, !value.isEmpty {
            return value
        }
        let env = ProcessInfo.processInfo.environment["CMUX_COMMIT"] ?? ""
        return env.isEmpty ? nil : env
    }
    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text(String(localized: "about.appName", defaultValue: "cmux"))
                        .cmuxFont(.title)
                        .bold()
                    Text(String(localized: "about.description", defaultValue: "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS."))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .cmuxFont(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: String(localized: "about.version", defaultValue: "Version"), text: version)
                    }
                    if let build {
                        AboutPropertyRow(label: String(localized: "about.build", defaultValue: "Build"), text: build)
                    }
                    let commitText = commit ?? "—"
                    let commitURL = commit.flatMap { hash in
                        URL(string: "\(repository)/commit/\(hash)")
                    }
                    AboutPropertyRow(label: String(localized: "about.commit", defaultValue: "Commit"), text: commitText, url: commitURL)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button(String(localized: "about.docs", defaultValue: "Docs")) {
                            openURL(url)
                        }
                    }
                    if let url = githubURL {
                        Button(String(localized: "about.github", defaultValue: "GitHub")) {
                            openURL(url)
                        }
                    }
                    Button(String(localized: "about.licenses", defaultValue: "Licenses")) {
                        showLicenses()
                    }
                }

                if let copy = copyright, !copy.isEmpty {
                    Text(copy)
                        .cmuxFont(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(AboutVisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }
}
