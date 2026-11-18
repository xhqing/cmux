import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser force dark policy")
struct BrowserForceDarkPolicyTests {
    private let page = URL(string: "https://business.facebook.com/business/loginpage/")!

    @Test func disabledPolicyNeverApplies() {
        let policy = BrowserForceDarkPolicy(isEnabled: false)
        #expect(!policy.shouldApply(to: page))
    }

    @Test func appliesToHTTPAndHTTPS() {
        let policy = BrowserForceDarkPolicy(isEnabled: true)
        #expect(policy.shouldApply(to: URL(string: "https://example.com/")!))
        #expect(policy.shouldApply(to: URL(string: "http://example.com/")!))
    }

    @Test func skipsPagesWithoutAWebHost() {
        let policy = BrowserForceDarkPolicy(isEnabled: true)
        #expect(!policy.shouldApply(to: nil))
        #expect(!policy.shouldApply(to: URL(string: "about:blank")!))
        #expect(!policy.shouldApply(to: URL(string: "cmux://diff-viewer/session")!))
        #expect(!policy.shouldApply(to: URL(string: "file:///tmp/page.html")!))
    }

    @Test func exactHostExceptionIsSkipped() {
        let policy = BrowserForceDarkPolicy(
            isEnabled: true,
            excludedHosts: ["business.facebook.com"]
        )
        #expect(!policy.shouldApply(to: page))
        #expect(policy.shouldApply(to: URL(string: "https://www.facebook.com/")!))
    }

    @Test func subdomainOfAnExcludedHostIsSkipped() {
        let policy = BrowserForceDarkPolicy(isEnabled: true, excludedHosts: ["facebook.com"])
        #expect(!policy.shouldApply(to: page))
        #expect(!policy.shouldApply(to: URL(string: "https://facebook.com/")!))
        #expect(policy.shouldApply(to: URL(string: "https://notfacebook.com/")!))
        #expect(policy.shouldApply(to: URL(string: "https://example.com/?next=facebook.com")!))
    }

    @Test func hostMatchingIgnoresCasePortAndTrailingDot() {
        let policy = BrowserForceDarkPolicy(isEnabled: true, excludedHosts: ["Facebook.COM."])
        #expect(!policy.shouldApply(to: URL(string: "https://Business.Facebook.com:443/login")!))
        #expect(BrowserForceDarkPolicy.normalizeHost(" HTTPS://Business.Facebook.com:443/login ") == "business.facebook.com")
        #expect(BrowserForceDarkPolicy.normalizeHost("example.com.") == "example.com")
    }

    @Test func emptyAndDuplicateExceptionsAreIgnored() {
        let policy = BrowserForceDarkPolicy(
            isEnabled: true,
            excludedHosts: ["", "  ", "facebook.com", "FACEBOOK.com", "facebook.com"]
        )
        #expect(!policy.shouldApply(to: page))
        #expect(policy.shouldApply(to: URL(string: "https://example.com/")!))
    }
}
