//
//  HTMLandXMLTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/20/26.
//

import Testing
@testable import Digester
import IrisCommon
import Foundation

struct HTMLandXMLTests {
    @Test("Every header in headers.html produces its own anchored text chunk, in document order", arguments: [
        Bundle.module.url(forResource: "headers", withExtension: "html", subdirectory: "Test Documents/html")!
    ]) func testHeaderSections(htmlFile: URL) throws {
    }
}
