import XCTest
@testable import omux

/// Screens captured from Claude Code 2.1.319's question dialog.
final class QuestionScreenTests: XCTestCase {
    private let questions = [
        Question(text: "When Claude Code asks several questions at once, how should the transcript card present them?", header: "Layout",
                 options: ["All at once (Recommended)", "One at a time"], descriptions: ["Every question…", "The card shows…"], multi: false),
        Question(text: "Which other parts of the question dialog should the card handle?", header: "Features",
                 options: ["Multi-select questions", "Type my own answer", "Chat about this"], multi: true),
    ]

    private let singleSelect = """
    ⏺ Background command completed (exit code 0)
    ─────────────────────────────────────────────────
    ←  ☐ Layout  ☐ Features  ✔ Submit  →
    │ When Claude Code asks several questions at once, how should the transcript card present them?
    ❯ 1. All at once (Recommended)
         Every question in the card with its own buttons; the answers are sent together when the last one is picked.
      2. One at a time
         The card shows the current question and moves to the next after each pick, like the terminal.
      3. Type something.
    ─────────────────────────────────────────────────
      4. Chat about this
    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

    private let multiSelect = """
    ─────────────────────────────────────────────────
    ←  ☒ Layout  ☐ Features  ✔ Submit  →
    │ Which other parts of the question dialog should the card handle?
      1. [x] Multi-select questions
             Tick several options and confirm.
    ❯ 2. [ ] Type my own answer
             A text field for the 'Other' choice.
      3. [ ] Chat about this
             A button that rejects the questions.
      4. [ ] Type something
         Submit
    ─────────────────────────────────────────────────
      5. Chat about this
    Enter to select · ↑/↓ to navigate · Esc to cancel
    """

    private let review = """
    ─────────────────────────────────────────────────
    ←  ☒ Layout  ☒ Features  ✔ Submit  →
    Review your answers
     │ ● When Claude Code asks several questions at once, how should the transcript card present them?
       → One at a time
     ● Which other parts of the question dialog should the card handle?
       → Type my own answer
    Ready to submit your answers?
    ❯ 1. Submit answers
      2. Cancel
    """

    private func lines(_ screen: String) -> [String] { screen.components(separatedBy: "\n") }

    func testTheFirstQuestionWithItsRowsAndHighlight() throws {
        let dialog = try XCTUnwrap(QuestionScreen.parse(lines(singleSelect), questions: questions))
        XCTAssertEqual(dialog.page, .question(0))
        XCTAssertEqual(dialog.answered, [false, false])
        XCTAssertEqual(dialog.rows.map(\.kind), [.option(0), .option(1), .type, .chat])
        XCTAssertEqual(dialog.rows.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(dialog.cursor, 0)
        XCTAssertEqual(dialog.rows.compactMap(\.checked), [], "a single-select question has no boxes")
        XCTAssertEqual(QuestionScreen.keys(from: 0, to: 1), "\u{1b}[B")
        XCTAssertEqual(QuestionScreen.keys(from: 0, to: 3), "\u{1b}[B\u{1b}[B\u{1b}[B")
    }

    /// The option labelled like the dialog's own "Chat about this" row is still an option.
    func testAMultiSelectQuestionWithTicksAndItsSubmitRow() throws {
        let dialog = try XCTUnwrap(QuestionScreen.parse(lines(multiSelect), questions: questions))
        XCTAssertEqual(dialog.page, .question(1))
        XCTAssertEqual(dialog.answered, [true, false])
        XCTAssertEqual(dialog.rows.map(\.kind), [.option(0), .option(1), .option(2), .type, .submit, .chat])
        XCTAssertEqual(dialog.rows.map(\.checked), [true, false, false, false, nil, nil])
        XCTAssertEqual(dialog.rows.map(\.number), [1, 2, 3, 4, nil, 5])
        XCTAssertEqual(dialog.cursor, 1)
        XCTAssertEqual(QuestionScreen.keys(from: 1, to: 4), "\u{1b}[B\u{1b}[B\u{1b}[B")
        XCTAssertEqual(QuestionScreen.keys(from: 1, to: 0), "\u{1b}[A")
    }

    func testTheReviewPage() throws {
        let dialog = try XCTUnwrap(QuestionScreen.parse(lines(review), questions: questions))
        XCTAssertEqual(dialog.page, .review)
        XCTAssertEqual(dialog.rows.map(\.kind), [.submitAnswers, .cancel])
        XCTAssertEqual(dialog.cursor, 0)
        XCTAssertEqual(dialog.review.count, 2)
        XCTAssertTrue(dialog.review[0].hasSuffix("→ One at a time"))
        XCTAssertTrue(dialog.review[1].hasSuffix("→ Type my own answer"))
    }

    func testNoDialogWhenTheScreenShowsNone() {
        XCTAssertNil(QuestionScreen.parse(["❯ ", "  ~/omux  main"], questions: questions))
    }
}
