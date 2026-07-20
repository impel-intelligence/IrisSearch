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
import TestUtilities

@Test("Make sure headers are properly broken.", arguments: [
    Bundle.module.url(forResource: "headers", withExtension: "html", subdirectory: "Test Documents/html")!
]) func testHTMLLoading(txtFile: URL) throws {
    let digestor = HTMLandXMLDigester()
    let digest = try digestor.digest(file: txtFile, contextSize: 512)
    
    
}
