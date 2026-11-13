import AppKit
import XCTest
@testable import omux
@testable import OmuxCore

final class TerminalAttachmentTests: XCTestCase {
    @MainActor
    func testScreenshotPasteAndDropPreserveSeparateImages() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        board.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        let first = try XCTUnwrap(TermView.attachmentText(from: board, directory: directory))
        let second = try XCTUnwrap(TermView.attachmentText(from: board, preferText: false, directory: directory))
        XCTAssertNotEqual(first, second)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files { XCTAssertNotNil(NSImage(contentsOf: file)) }

        board.setString("Copied caption", forType: .string)
        XCTAssertNil(try TermView.attachmentText(from: board, directory: directory))
        XCTAssertNotNil(try TermView.attachmentText(from: board, preferText: false, directory: directory))
    }

    @MainActor
    func testFilePathsAndPlainText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/screen shot.png")])
        XCTAssertEqual(try TermView.attachmentText(from: board), "/tmp/screen\\ shot.png ")
        // Unescaped, zsh and bash read "!v2" as history expansion: "event not found".
        XCTAssertEqual(TermView.shellEscaped([URL(fileURLWithPath: "/tmp/shot!v2.png")]), "/tmp/shot\\!v2.png")
        board.clearContents()
        board.setString("hello", forType: .string)
        XCTAssertNil(try TermView.attachmentText(from: board))
    }

    /// A newline or CR in a dropped file's name used to reach the shell as is, so Return ran
    /// the rest of the name as a second command. Each path must read back as one word.
    func testControlCharactersInNamesStayInOneWord() throws {
        let paths = ["/tmp/shot\ntouch\tPWNED.png", "/tmp/shot\rtouch PWNED", "/tmp/a\u{1b}b\u{7f}", "/tmp/a b'c$(x)!.png"]
        // Run in an empty folder, so a regression can't leave PWNED files anywhere else.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for shell in ["/bin/zsh", "/bin/bash"] {
            for path in paths {
                let escaped = TermView.shellEscaped([URL(fileURLWithPath: path)])
                XCTAssertFalse(escaped.contains("\n") || escaped.contains("\r"), escaped)
                let process = Process()
                process.currentDirectoryURL = dir
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", "printf '%s|' " + escaped]
                let out = Pipe()
                process.standardOutput = out
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(String(decoding: data, as: UTF8.self), path + "|", "\(shell): \(escaped)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// A file name holding ESC[201~ would end the paste, and the lines after it would submit.
    func testPastedTextCannotEndThePaste() {
        let pasted = TermView.bracketedPaste("- a\u{1b}[201~\ntouch PWNED\n.txt: look")
        XCTAssertEqual(pasted, "\u{1b}[200~- a[201~\ntouch PWNED\n.txt: look\u{1b}[201~")
        XCTAssertEqual(pasted.components(separatedBy: "\u{1b}[201~").count, 2)
    }

    @MainActor
    func testImageWriteFailureIsReported() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        board.writeObjects([image])
        XCTAssertThrowsError(try TermView.attachmentText(from: board, directory: URL(fileURLWithPath: "/dev/null/images")))
    }

    @MainActor
    func testDropAcceptsPromisedFiles() {
        let view = TermView(tabID: UUID())
        for type in NSFilePromiseReceiver.readableDraggedTypes {
            XCTAssertTrue(view.registeredDraggedTypes.contains(NSPasteboard.PasteboardType(type)))
        }
    }
}
