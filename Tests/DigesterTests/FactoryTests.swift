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

struct FactoryTests {
    @Test("Ensure the text digester is returned by the factory is correct for various text UTTypes.", arguments: [
        UTType.plainText,
        UTType.cHeader,
        UTType.cSource,
        UTType.swiftSource,
        UTType("com.unknown.md")!
    ]) func testTxtDigesterReturned(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: TXTDigester()) == type(of: returnedDigester))
    }
    
    
    @Test("Ensure the pdf digester is returned by the factory is correct for various pdf UTTypes.", arguments: [
        UTType.pdf,
        UTType("com.adobe.pdf")!,
    ]) func testPDFDigesterReturned(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: PDFDigester()) == type(of: returnedDigester))
    }
}
