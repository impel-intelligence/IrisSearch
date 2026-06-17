//
//  ProtocolTests.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/17/26.
//

import Testing
@testable import Digester
import Foundation
import UniformTypeIdentifiers

@Test("Ensure the text digester is returned by the factory is correct for various text UTTypes.", arguments: [
    UTType.plainText,
    UTType.cHeader,
    UTType.cSource,
    UTType.swiftSource,
]) func testTxtDigesterReturned(type: UTType) throws {
    let returnedDigester = try DigesterFactory.digester(for: type)
    #expect(TXTDigester().id == returnedDigester.id)
}


@Test("Ensure the pdf digester is returned by the factory is correct for various pdf UTTypes.", arguments: [
    UTType.pdf,
    UTType("com.adobe.pdf")!,
]) func testPDFDigesterReturned(type: UTType) throws {
    let returnedDigester = try DigesterFactory.digester(for: type)
    #expect(PDFDigester().id == returnedDigester.id)
}
