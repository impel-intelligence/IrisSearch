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
        UTType.swiftSource
    ]) func testTxtDigesterReturned(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: TXTDigester()) == type(of: returnedDigester))
    }
    
    @Test("Ensure the text digester is retruned by the factory for all of its core types.", arguments: TXTDigester.fileTypes)
    func testTxtDigesterDefaultTypes(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: TXTDigester()) == type(of: returnedDigester))
    }
    
    @Test("Ensure the markdown digester is returned by the factory is correct for various text UTTypes.", arguments: [
        UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    ]) func testMarkdownReturned(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: MarkdownDigester()) == type(of: returnedDigester))
    }
    
    @Test("Ensure the text digester is retruned by the factory for all of its core types.", arguments: MarkdownDigester.fileTypes)
    func testMarkdownDigesterDefaultTypes(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: MarkdownDigester()) == type(of: returnedDigester))
    }


    @Test("Ensure the pdf digester is returned by the factory is correct for various pdf UTTypes.", arguments: [
        UTType.pdf,
        UTType("com.adobe.pdf")!,
    ]) func testPDFDigesterReturned(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: PDFDigester()) == type(of: returnedDigester))
    }
    
    @Test("Ensure the pdf digester is retruned by the factory for all of its core types.", arguments: PDFDigester.fileTypes)
    func testPDFDigesterDefaultTypes(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: PDFDigester()) == type(of: returnedDigester))
    }

    @Test("Ensure the HTML/XML digester is returned by the factory for HTML and XML UTTypes.", arguments: [
        UTType.html,
        UTType.xml,
    ]) func testHTMLandXMLDigesterReturned(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: HTMLandXMLDigester()) == type(of: returnedDigester))
    }
    
    @Test("Ensure the html and xml digester is retruned by the factory for all of its core types.", arguments: HTMLandXMLDigester.fileTypes)
    func testHTMLandXMLDigesterDefaultTypes(utType: UTType) throws {
        let returnedDigester = try DigesterFactory.digester(for: utType)
        #expect(type(of: HTMLandXMLDigester()) == type(of: returnedDigester))
    }

    @Test("Ensure overlapping types pick the right factory")
    func testOverlappingTypes() throws {
        // .html is a descendent of .text. This used to make the DigesterFactory return the TXTDigester, so this tests make sure that no longer happens.
        let returnedDigester = try DigesterFactory.digester(for: .html)
        #expect(type(of: HTMLandXMLDigester()) == type(of: returnedDigester))
    }
    
    @Test("Make sure that the no digester error is thrown when there is an unsupported type")
    func testNoDigesterFOund() throws {
        #expect(throws: DigestionError.self) {
            try DigesterFactory.digester(for: .font)
        }
    }
}
