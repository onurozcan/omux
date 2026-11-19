import SwiftUI
import XCTest
@testable import omux
@testable import OmuxCore

final class PaneLayoutTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testSplittingPutsTheNewPaneAfterOrBefore() {
        let right = PaneLayout.session(a).splitting(a, with: b, axis: .horizontal)
        XCTAssertEqual(right, .split(axis: .horizontal, first: .session(a), second: .session(b)))
        let above = PaneLayout.session(a).splitting(a, with: b, axis: .vertical, before: true)
        XCTAssertEqual(above, .split(axis: .vertical, first: .session(b), second: .session(a)))
        // Deep in the tree, and only the named pane.
        let tree = right.splitting(b, with: c, axis: .vertical)
        XCTAssertEqual(tree.ids, [a, b, c])
        XCTAssertEqual(tree, .split(axis: .horizontal, first: .session(a),
                                    second: .split(axis: .vertical, first: .session(b), second: .session(c))))
        XCTAssertEqual(tree.splitting(d, with: a, axis: .horizontal), tree, "an unknown pane changes nothing")
    }

    func testRemovingCollapsesTheSplit() {
        let tree = PaneLayout.session(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        XCTAssertEqual(tree.removing(c), .split(axis: .horizontal, first: .session(a), second: .session(b)))
        XCTAssertEqual(tree.removing(a), .split(axis: .vertical, first: .session(b), second: .session(c)))
        XCTAssertEqual(tree.removing(b)?.ids, [a, c])
        XCTAssertNil(PaneLayout.session(a).removing(a))
        XCTAssertEqual(tree.removing(d), tree)
    }

    func testMovingToAnEdge() {
        let tree = PaneLayout.session(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        // c goes to the left of a: a's pane splits horizontally with c first.
        let moved = tree.moving(c, to: a, edge: .leading)
        XCTAssertEqual(moved, .split(axis: .horizontal,
                                     first: .split(axis: .horizontal, first: .session(c), second: .session(a)),
                                     second: .session(b)))
        XCTAssertEqual(tree.moving(a, to: b, edge: .bottom).ids, [b, a, c])
        XCTAssertEqual(tree.moving(a, to: a, edge: .top), tree, "onto itself changes nothing")
        XCTAssertEqual(tree.moving(d, to: a, edge: .top), tree)
        XCTAssertEqual(tree.moving(a, to: d, edge: .top), tree)
        XCTAssertEqual(Set(tree.moving(c, to: a, edge: .trailing).ids), Set(tree.ids), "nothing is lost in a move")
    }

    func testKeepingDropsClosedSessions() {
        let tree = PaneLayout.session(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        XCTAssertEqual(tree.keeping { $0 != b }, .split(axis: .horizontal, first: .session(a), second: .session(c)))
        XCTAssertEqual(tree.keeping { $0 == c }, .session(c))
        XCTAssertNil(tree.keeping { _ in false })
    }

    func testDropEdgeIsTheNearestSide() {
        let size = CGSize(width: 800, height: 200)
        XCTAssertEqual(PaneDropDelegate.edge(at: CGPoint(x: 20, y: 100), in: size), .leading)
        XCTAssertEqual(PaneDropDelegate.edge(at: CGPoint(x: 780, y: 100), in: size), .trailing)
        XCTAssertEqual(PaneDropDelegate.edge(at: CGPoint(x: 400, y: 10), in: size), .top)
        XCTAssertEqual(PaneDropDelegate.edge(at: CGPoint(x: 400, y: 190), in: size), .bottom)
        // Shares, not pixels: 60 px from the left of a wide pane is still nearer the left than
        // 60 px from the top of a short one.
        XCTAssertEqual(PaneDropDelegate.edge(at: CGPoint(x: 60, y: 60), in: size), .leading)
    }

    func testLayoutRoundTripsThroughTheWorkspace() throws {
        let tree = PaneLayout.session(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        let project = UUID()
        let data = try JSONEncoder().encode(Workspace(groups: [], selectedTabID: a, layouts: [project.uuidString: tree]))
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: data).layouts[project.uuidString], tree)
        // Older files have no layouts; a broken one doesn't take the workspace down with it.
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: Data(#"{"groups":[]}"#.utf8)).layouts, [:])
        let broken = try JSONDecoder().decode(Workspace.self, from: Data(#"{"groups":[],"layouts":{"x":{"axis":"diagonal"}}}"#.utf8))
        XCTAssertEqual(broken.layouts, [:])
        // The single layout of the previous beta lands on its first session's project.
        var group = TabGroup(name: "p")
        group.tabs = [TabItem(name: "a"), TabItem(name: "b")]
        let legacy = PaneLayout.session(group.tabs[0].id).splitting(group.tabs[0].id, with: group.tabs[1].id, axis: .horizontal)
        let old = try JSONEncoder().encode(["groups": AnyEncodable([group]), "layout": AnyEncodable(legacy)])
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: old).layouts[group.id.uuidString], legacy)
    }

    func testResizingByPathIsClamped() {
        let tree = PaneLayout.session(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        guard case .split(_, let outer, _, let inner) = tree.resizing([], to: 0.3), case .split(_, let innerFraction, _, _) = inner else {
            return XCTFail("shape changed")
        }
        XCTAssertEqual(outer, 0.3)
        XCTAssertEqual(innerFraction, 0.5, "only the addressed split changes")
        guard case .split(_, let outer2, _, let inner2) = tree.resizing([true], to: 0.99), case .split(_, let innerFraction2, _, _) = inner2 else {
            return XCTFail("shape changed")
        }
        XCTAssertEqual(outer2, 0.5)
        XCTAssertEqual(innerFraction2, 0.85, "clamped so neither half can vanish")
        XCTAssertEqual(tree.resizing([false], to: 0.2), tree, "a leaf has nothing to resize")
        XCTAssertEqual(tree.resizing([], to: 0.3).ids, tree.ids)
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
