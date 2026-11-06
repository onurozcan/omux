import XCTest
@testable import omux

final class PermissionPromptTests: XCTestCase {
    private func runtime(_ message: String?, provider: SessionProvider? = .claude) -> TabRuntime {
        var rt = TabRuntime()
        rt.provider = provider
        rt.statusState = .blocked
        rt.statusKind = "permission"
        rt.statusDetail = message
        return rt
    }

    /// Allow/Deny answer tool prompts; Claude Code reports other dialogs as "permission" too,
    /// and their first option isn't a plain yes.
    func testOnlyToolPromptsGetAllowAndDeny() {
        XCTAssertTrue(runtime("approve Write: /tmp/x.txt").awaitsPermission)
        XCTAssertTrue(runtime("approve Bash: ls -la").awaitsPermission)
        XCTAssertTrue(runtime("approve mcp__github__create_issue: x").awaitsPermission)
        XCTAssertTrue(runtime(nil).awaitsPermission)
        // Claude Code's generic label, used when it has no description for the call.
        XCTAssertTrue(runtime("permission prompt").awaitsPermission)
        XCTAssertFalse(runtime("awaiting input").awaitsPermission)
        XCTAssertFalse(runtime("awaiting input: build-bot").awaitsPermission)
        XCTAssertFalse(runtime("approve plan").awaitsPermission)
        XCTAssertFalse(runtime("approve message from build-bot").awaitsPermission)
        XCTAssertTrue(runtime("Approve file changes in Codex", provider: .codex).awaitsPermission)
    }
}
