import XCTest
import Foundation
@testable import ConverterKit

final class XMLTests: XCTestCase {
    func testParseStructureAndEntities() throws {
        let src = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Root attr="1" other="x&amp;y">
          <Child name="a">text &amp; &lt;more&gt;</Child>
          <Child name="b"/>
          <!-- a comment with <fake> tags -->
          <Wrapper><Inner>42</Inner></Wrapper>
        </Root>
        """
        let root = try XML.parse(Data(src.utf8))
        XCTAssertEqual(root.name, "Root")
        XCTAssertEqual(root.attributeText("attr"), "1")
        XCTAssertEqual(root.attributeText("other"), "x&y")

        let children = root.elements(forName: "Child")
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].attributeText("name"), "a")
        XCTAssertEqual(children[0].trimmedText, "text & <more>")
        XCTAssertNil(children[1].trimmedText)

        XCTAssertEqual(root.firstChild("Wrapper")?.childInt("Inner"), 42)
    }

    func testCDATAandNumericEntities() throws {
        let src = "<R><A><![CDATA[raw <x> & y]]></A><B>&#65;&#x42;</B></R>"
        let root = try XML.parse(Data(src.utf8))
        XCTAssertEqual(root.childText("A"), "raw <x> & y")
        XCTAssertEqual(root.childText("B"), "AB")
    }

    func testWriteThenReparse() throws {
        let root = XML("Project").attr("version", "1.0")
        root.leaf("Title", "Hello <World> & \"friends\"")
        let doc = root.document(declaration: "<?xml version=\"1.0\"?>")
        let reparsed = try XML.parse(Data(doc.utf8))
        XCTAssertEqual(reparsed.name, "Project")
        XCTAssertEqual(reparsed.attributeText("version"), "1.0")
        XCTAssertEqual(reparsed.childText("Title"), "Hello <World> & \"friends\"")
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try XML.parse(Data("not xml at all".utf8)))
    }
}
