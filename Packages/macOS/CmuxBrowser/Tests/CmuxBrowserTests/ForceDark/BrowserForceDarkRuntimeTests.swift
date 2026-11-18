import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

@Suite("Browser force dark runtime")
struct BrowserForceDarkRuntimeTests {
    private let page = URL(string: "https://business.facebook.com/business/loginpage/")!

    @Test func bundledLibraryLoads() throws {
        let source = try #require(BrowserForceDarkRuntime.librarySource)
        #expect(source.contains("Dark Reader v4.9.135"))
        #expect(source.contains("exports.enable"))
        #expect(source.contains("exports.disable"))
    }

    @Test func bootstrapSourceContainsLibraryAndEnableCall() throws {
        let policy = BrowserForceDarkPolicy(isEnabled: true)
        let source = try #require(BrowserForceDarkRuntime.bootstrapSource(policy: policy, url: page))
        #expect(source.contains("Dark Reader v4.9.135"))
        #expect(source.contains("DarkReader.enable"))
        #expect(source.contains("\"brightness\""))
        #expect(source.contains("\"excludedHosts\""))
    }

    @Test func bootstrapSourceIsNilWhenDisabled() {
        let policy = BrowserForceDarkPolicy(isEnabled: false)
        #expect(BrowserForceDarkRuntime.bootstrapSource(policy: policy, url: page) == nil)
    }

    @Test func bootstrapSourceIsNilForExcludedHost() {
        let policy = BrowserForceDarkPolicy(isEnabled: true, excludedHosts: ["facebook.com"])
        #expect(BrowserForceDarkRuntime.bootstrapSource(policy: policy, url: page) == nil)
    }

    @Test func userScriptInjectsAtDocumentStartInTheMainFrame() throws {
        let policy = BrowserForceDarkPolicy(isEnabled: true)
        let userScript = try #require(BrowserForceDarkRuntime.makeUserScript(policy: policy, url: page))
        #expect(userScript.injectionTime == .atDocumentStart)
        #expect(userScript.isForMainFrameOnly)
        #expect(userScript.source.contains("DarkReader.enable"))
    }

    @Test func enableAndDisableScriptsCallTheLibraryAPI() {
        #expect(BrowserForceDarkRuntime.enableScript.contains("DarkReader.enable"))
        #expect(BrowserForceDarkRuntime.disableScript.contains("DarkReader.disable"))
    }
}
