import XCTest
@testable import omux
@testable import OmuxHostKit

/// Knowing about machines: which names are machines, what the user's SSH configuration
/// offers, and reading what a look at one found.
final class RemoteMachinesTests: XCTestCase {
    func testWhatMayBeHandedToSSH() {
        for good in ["devbox", "me@10.0.0.5", "user@host.example.com", "[::1]", "a-b_c.d"] { XCTAssertTrue(RemoteMachines.isValid(good), good) }
        // An option in disguise, more than one word, nothing at all.
        for bad in ["-oProxyCommand=evil", "", "two words", "tab\there", "new\nline", String(repeating: "a", count: 300)] {
            XCTAssertFalse(RemoteMachines.isValid(bad), bad.debugDescription)
        }
    }

    func testNamesComeFromTheSSHConfigurationAndWhatItIncludes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omux-ssh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        Include conf.d/*.conf
        Include \(dir.path)/extra

        Host devbox  staging
          HostName 10.0.0.5
        Host *.internal !bastion
          User me
        host=gpu
        Host devbox
        """.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host from-include\n".write(to: dir.appendingPathComponent("conf.d/a.conf"), atomically: true, encoding: .utf8)
        try "Host ignored\n".write(to: dir.appendingPathComponent("conf.d/b.txt"), atomically: true, encoding: .utf8)
        try "Host extra-one\n".write(to: dir.appendingPathComponent("extra"), atomically: true, encoding: .utf8)
        // In the order written, each once, and no patterns.
        XCTAssertEqual(RemoteMachines.configuredHosts(config: dir.appendingPathComponent("config").path),
                       ["from-include", "extra-one", "devbox", "staging", "gpu"])
        XCTAssertEqual(RemoteMachines.configuredHosts(config: dir.appendingPathComponent("missing").path), [])
    }

    func testReadingWhatALookFound() throws {
        let session = SessionInfo(id: "abc", name: "work", directory: "/srv", command: ["/bin/bash", "-l"], started: Date(timeIntervalSince1970: 1_700_000_000),
                                  columns: 80, rows: 24, outputEnd: 10, exited: nil)
        let ended = SessionInfo(id: "def", name: "old", directory: "/srv", command: ["sh"], started: Date(timeIntervalSince1970: 1_700_000_000),
                                columns: 80, rows: 24, outputEnd: 3, exited: 0)
        let json = String(decoding: try JSONEncoder().encode([session, ended]), as: UTF8.self)
        let report = try XCTUnwrap(RemoteMachines.report(from: """
        sys=Linux x86_64
        home=/home/me
        claude=yes
        host=omux-host protocol 1 build 1-2
        sessions=\(json)
        dir=no
        """))
        XCTAssertEqual(report.system, "Linux x86_64")
        XCTAssertTrue(report.supported)
        XCTAssertTrue(report.claude)
        XCTAssertEqual(report.hostVersion, "omux-host protocol 1 build 1-2")
        XCTAssertEqual(report.folderExists, false)
        XCTAssertEqual(report.sessions.map(\.id), ["abc", "def"])
        XCTAssertEqual(report.running.map(\.id), ["abc"])

        let bare = try XCTUnwrap(RemoteMachines.report(from: "sys=Darwin arm64\nhome=/Users/me\nclaude=no\n"))
        XCTAssertFalse(bare.supported)
        XCTAssertNil(bare.hostVersion)
        XCTAssertNil(bare.folderExists)
        XCTAssertNil(RemoteMachines.report(from: ""), "nothing printed is no report")
    }

    func testWhySSHFailedIsSaidPlainly() {
        XCTAssertTrue(RemoteMachines.explain("ssh: Could not resolve hostname devbx: nodename nor servname provided", host: "devbx").contains("No machine is known"))
        XCTAssertTrue(RemoteMachines.explain("me@host: Permission denied (publickey,password).", host: "host").contains("password or a key"))
        XCTAssertTrue(RemoteMachines.explain("Host key verification failed.", host: "h").contains("doesn't know h yet"))
        XCTAssertTrue(RemoteMachines.explain("ssh: connect to host h port 22: Connection refused", host: "h").contains("refused"))
        XCTAssertTrue(RemoteMachines.explain("ssh: connect to host h port 22: Operation timed out", host: "h").contains("didn't answer"))
        XCTAssertEqual(RemoteMachines.explain("", host: "h"), "Couldn't reach h.")
    }

    func testTheProbeNeverLetsAFolderNameRunAsCode() throws {
        let script = RemoteMachines.probeScript(folder: "~/it's $(touch /tmp/pwned) `x`")
        XCTAssertTrue(script.contains(#"D='~/it'\''s $(touch /tmp/pwned) `x`'"#), script)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", "-c", script]
        try check.run(); check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
    }

    func testAFileSentToAMachineKeepsARecognisableSafeName() {
        let name = RemoteMachines.attachmentName(for: URL(fileURLWithPath: "/tmp/Screen Shot $(rm -rf ~) 'x'.png"))
        XCTAssertTrue(name.hasSuffix("-Screen_Shot___rm_-rf_____x_.png"), name)
        XCTAssertNotNil(name.range(of: #"^[0-9a-f]{8}-[A-Za-z0-9._-]+$"#, options: .regularExpression), name)
        XCTAssertNotEqual(name, RemoteMachines.attachmentName(for: URL(fileURLWithPath: "/tmp/Screen Shot $(rm -rf ~) 'x'.png")), "two of one name don't collide")
        XCTAssertTrue(RemoteMachines.attachmentName(for: URL(fileURLWithPath: "/tmp/.env")).hasSuffix("-file.env"))
    }

    /// /machines in the compose box: a card with each machine, how it is and what uses it.
    @MainActor
    func testTheMachinesCard() {
        let machines = RemoteMachines()
        let empty = machines.overview(hosts: [], projects: [:])
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertNotNil(empty.empty)
        let card = machines.overview(hosts: ["devbox"], projects: ["devbox": ["api", "web"]])
        XCTAssertEqual(card.title, "Machines")
        XCTAssertEqual(card.rows.map(\.name), ["devbox"])
        XCTAssertEqual(card.rows.first?.note, "used by api, web")
        XCTAssertEqual(card.rows.first?.detail, "Looking…", "not looked at yet")
        XCTAssertEqual(card.actionID, "machines-open")
    }

    func testTheComposeBoxOffersTheMachineCommands() {
        for list in [CommandIndex.claude, CommandIndex.codex] {
            XCTAssertTrue(["machines", "machine", "remote"].allSatisfy { name in list.contains { $0.name == name } })
        }
    }

    /// Against a real machine, when one is named: OMUX_LIVE_HOST=devbox swift test --filter RemoteMachinesTests
    @MainActor
    func testALiveMachine() async throws {
        guard let host = ProcessInfo.processInfo.environment["OMUX_LIVE_HOST"], !host.isEmpty else { throw XCTSkip("no OMUX_LIVE_HOST") }
        let machines = RemoteMachines()
        let state = await machines.check(host, folder: "/tmp")
        let report = try XCTUnwrap(state.report, "\(state)")
        print("LIVE report:", report)
        XCTAssertFalse(report.system.isEmpty)
        XCTAssertEqual(report.folderExists, true)
        let missing = await machines.check(host, folder: "/no/such/folder/here")
        XCTAssertEqual(missing.report?.folderExists, false)
        let listing = try await RemoteMachines.folders(on: host, in: "/").get()
        print("LIVE folders of /:", listing.names.prefix(8))
        XCTAssertEqual(listing.path, "/")
        XCTAssertTrue(listing.names.contains("tmp") && listing.names.contains("usr"))
        let home = try await RemoteMachines.folders(on: host, in: "~").get()
        XCTAssertEqual(home.path, report.home)
        if case .success = await RemoteMachines.folders(on: host, in: "/no/such/folder") { XCTFail("listed a folder that isn't there") }
        // What the compose box needs there: the folder's files for @, and a file sent over.
        let files = await RemoteMachines.files(on: host, in: "/etc/ssh")
        print("LIVE files:", files.prefix(4))
        XCTAssertTrue(files.contains("ssh_config"))
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("omux up load \(UUID().uuidString).txt")
        try "sent from the Mac\n".write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }
        let uploaded = await RemoteMachines.upload(local, to: host)
        let remote = try XCTUnwrap(uploaded)
        print("LIVE uploaded to:", remote)
        XCTAssertTrue(remote.hasPrefix(report.home + "/.omux/attachments/"))
        let back = await RemoteMachines.run("cat \(remote); rm -f \(remote)", on: host)
        XCTAssertEqual(back.output, "sent from the Mac\n")
        let nowhere = await machines.check("no-such-machine-omux-test.invalid")
        XCTAssertNotNil(nowhere.problem)
        print("LIVE unreachable:", nowhere.problem ?? "")
    }
}
