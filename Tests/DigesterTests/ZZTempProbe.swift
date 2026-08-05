import Testing
@testable import Digester
import Markdown
import Foundation

struct ZZTempProbe {
    @Test func probe() async throws {
        let url = Bundle.module.url(forResource: "syntax-test", withExtension: "md", subdirectory: "Test Documents/Markdown")!
        let text = try String(contentsOf: url, encoding: .utf8)
        let doc = Document(parsing: text)
        for child in doc.children {
            let r = (child as? BlockMarkup)?.range
            print("BLOCK \(type(of: child)) range=\(String(describing: r))")
        }
    }
}
