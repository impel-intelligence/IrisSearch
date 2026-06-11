//
//  DigesterTests.swift
//  DigesterTests
//
//  by Taylor Lineman on 6/10/26.
//

import Testing
@testable import Digester
import Foundation

struct PDFArgument {
    var url: URL
    var numberOfPages: Int
    var bodyText: String
}

@Test("Ensure pdf digester can process PDFs", arguments: [
    PDFArgument(
        url: Bundle.module.url(forResource: "simple-pdf-feature-test", withExtension: "pdf", subdirectory: "Test Documents/pdf")!,
        numberOfPages: 3,
        bodyText: """
            PDF Feature Test Document
            This page contains native (born-digital) text, an embedded raster image,
            and a vector chart drawn with PDF path operators. The text on this page is
            fully selectable and extractable. Page 2 is a simulated scan with an OCR
            text layer. Page 3 is a simulated scan with NO text layer.
            Vector Bar Chart (Q1-Q4)
            130
            95
            65
            40
            Figure 1: Embedded raster image
            Q1
            Q2
            Q3
            Figure 2: Vector chart (paths, no raster)
            Q4
            Additional body text for extraction testing. The quick brown fox jumps over
            the lazy dog. 0123456789. Special characters: @#$%&*() — em dash, “quotes”.
            Scanned Page - With OCR Layer
            This page simulates a scanned document. It was rendered to a
            raster image with noise, blur, and a slight rotation, then run
            through the Tesseract OCR engine. An invisible text layer was
            placed over the image, so this text is searchable and can be
            selected and copied even though the page itself is a picture.
            OCR test phrases: The quick brown fox jumps over the lazy dog.
            Numbers: 1234567890. Date: June 10, 2026. Amount: $4,815.16
            """
    ),
    PDFArgument(
        url: Bundle.module.url(forResource: "pdf-ingestion-test-suite", withExtension: "pdf", subdirectory: "Test Documents/pdf")!,
        numberOfPages: 10,
        bodyText: """
            PDF Ingestion Test Suite — CONFIDENTIAL Doc ID: ING-2026-001
            1. Text & Typography
            Base-14 font (Helvetica). Standard selectable text for baseline extraction.
            Times-Roman serif sample with punctuation: “smart quotes”, ‘single’, em—dash, en–dash.
            Courier monospaced sample: SELECT * FROM users WHERE id = 42;
            Bold weight sample (Helvetica-Bold).
            Italic sample (Helvetica-Oblique).
            Embedded TrueType font (DejaVu Sans).
            Tiny 6pt text — readability/threshold test. Large 24pt heading text
            Ligature test (precomposed): finance flowchart oﬃce — vs plain: finance flowchart office
            Diacritics: naïve façade jalapeño Größenwahn smörgåsbord crème brûlée Łódź
            Greek: Αλφάβητο — αβγδεζηθικλμνξοπρστυφχψω · Δx ≈ 0.001
            Cyrillic: Съешь же ещё этих мягких французских булок
            םלוע םולש :)Hebrew (RTL, logical order test
            CJK (CID font): 简体中文测试文档 — 你好世界 1234
            Math/symbols: ∑ᵢ xᵢ ≈ ∫ f(x)dx · √2 ≤ π · α²+β² · © ® ™ § ¶ µ
            Currency & entities: €1.234,56 · £99.99 · ¥10,000 · $4,815.16 · 25 %
            Entities: taylor@tryimpel.com · +1 (555) 867-5309 · 2026-06-10 · ISBN 978-3-16-148410-0
            Super/subscript: E = mc2 · H2 O · footnote marker¹
            ¹ This is the footnote text, in smaller type at a distance from its marker.
            Letter-spaced text (charSpace):
            S P A C E D O U T T E X T
            Page 1 of 10
            PDF Ingestion Test Suite — CONFIDENTIAL Doc ID: ING-2026-001
            2. Layout: Columns, Lists, Hyphenation
            This page tests reading-order re-
            construction. The body is set in
            two columns; a correct ingestion
            pipeline should read all of col-
            umn one before column two.
            Note the hyphenated words bro-
            ken across line endings: they
            should ideally be rejoined into
            single tokens (reconstruction,
            column, broken).
            COLUMN ONE ENDS HERE.
            COLUMN TWO STARTS HERE.
            If this sentence appears before
            the end of column one in your
            extracted output, the extractor
            is reading in raster order rather
            than column order.
            A quotation block follows, in-
            dented and italic:
            “The block quotation is indented
            from both margins and italicized.”
            Bulleted list:
            • First bullet item
            • Second bullet item with wrap-around text continuing on
            • Third bullet item
            Numbered list with nesting:
            1. Top-level item one
            2. Top-level item two
            a. Nested item alpha
            b. Nested item beta
            3. Top-level item three
            Checkbox-style list (glyphs):
            ☑ Completed task
            ☐ Incomplete task
            ✗ Cancelled task
            Page 2 of 10
            PDF Ingestion Test Suite — CONFIDENTIAL 3. Tables
            Region Q1 Q2 Q3 Q4 North 1,200 1,350 1,100 1,800 South 950 1,020 1,340 1,560 East 780 890 1,005 1,230 West 1,500 1,420 1,610 1,975 Table 1: Bordered table with header row, right-aligned numerics, zebra striping.
            Merged header spanning all columns
            Category 2025 2026
            10.2M 12.8M
            Revenue (spans 2 rows)
            8.1M 9.9M
            Costs 6.5M 7.0M
            Table 2: Merged cells — column span (row 1) and row span (Revenue).
            Table 3: Borderless, whitespace-aligned (hardest to detect):
            ITEM QTY UNIT PRICE AMOUNT
            Widget A 3 $19.99 $59.97
            Gadget B 12 $4.50 $54.00
            Doohickey C 1 $129.00 $129.00
            SUBTOTAL $242.97
            TAX 8.5% $20.65
            TOTAL $263.62
            Page 3 of 10
            Doc ID: ING-2026-001
            Total
            5,450
            4,870
            3,905
            6,505
            PDF Ingestion Test Suite — CONFIDENTIAL Doc ID: ING-2026-001
            4. Images, Vector Graphics & Hidden Text
            Fig 1: PNG (Flate) Fig 2: JPEG (DCT) 45%
            30% 25%
            Fig 4: Vector pie chart (wedges) WATERMARK
            Fig 3: PNG with alpha over watermark
            Vertical text rotated 90 degrees
            Fig 5: Vector polyline
            HIDDEN-WHITE-TEXT-TOKEN-77341 (white on white, invisible to eye)
            The line above this one contains white (invisible) text with token 77341.
            Diagonal text at 30 degrees
            INVISIBLE-RENDERMODE3-TOKEN-88452
            Above this line: text drawn with render mode 3 (token 88452).
            FIRST sentence by reading order, drawn SECOND in the content stream.
            SECOND sentence by reading order, drawn FIRST in the content stream.
            Page 4 of 10
            5. Landscape A4 Page (mixed page sizes/orientations)
            This page is A4 landscape while the rest of the document is US Letter portrait.
            Ingestion systems should handle per-page MediaBox differences. A wide table follows:
            Month Jan Feb Mar Apr May Jun Jul Aug Sep Sales 1,463 1,108 1,608 898 948 1,897 992 1,548 1,993 Returns 14 21 65 63 18 40 21 80 64 Page 5 of 10
            Oct 918 17 Nov 1,839 82 Dec
            1,239
            25
            6. Page with /Rotate 90 in page dictionary
            The page object carries /Rotate 90. Viewers display this page upright, but the
            underlying text matrix is rotated. Extractors that ignore /Rotate will produce
            rotated coordinates or garbled ordering for this page.
            ROTATION-TEST-TOKEN-55129
            PDF Ingestion Test Suite — CONFIDENTIAL Doc ID: ING-2026-001
            7. Interactive Form Fields (AcroForm)
            Full name (text field, pre-filled):
            Comments (multiline, pre-filled):
            Subscribe (checkbox, CHECKED):
            Accept terms (checkbox, UNCHECKED):
            Priority (radio group, 'medium' selected): low medium high
            Department (dropdown, 'Engineering' selected):
            Ingestion check: field names, types, current values, and selected states should all be readable.
            Page 7 of 10
            PDF Ingestion Test Suite — CONFIDENTIAL Doc ID: ING-2026-001
            8. Hyperlinks & Annotations
            External hyperlink: https://www.anthropic.com (clickable)
            Internal link: jump to Section 3 (Tables) — clickable
            mailto link: mailto:taylor@tryimpel.com
            A sticky-note (Text) annotation is anchored to the right of this line. →
            This sentence is covered by a yellow HIGHLIGHT annotation.
            Annotation text lives OUTSIDE the content stream — extractors must read /Annots.
            Page 8 of 10
            Scanned Page - With OCR Layer
            This simulated scan was processed with the Tesseract OCR
            engine, which placed an invisible text layer over the image.
            Text on this page is searchable and extractable, though OCR
            confidence varies and minor errors are possible by design.
            Pangram: The quick brown fox jumps over the lazy dog.
            Amount: $4,815.16 / Invoice 2026-0610 / PO #88231
            """)
//
]) func testPDFDigester(pdfFile: PDFArgument) async throws {
    let digestor = PDFDigester()
    let digest = try await digestor.digest(file: pdfFile.url)
        
    let images = digest.filter { content in
        switch content {
        case .image:
            return true
        default:
            return false
        }
    }
    
    #expect(images.count == pdfFile.numberOfPages, "The number of images should match the number of PDF pages.")
    
    guard case let .text(pdfContent) = digest.first else {
        #expect(Bool(false), "The first content should be text")
        return
    }

    #expect(pdfContent.trimmingCharacters(in: .newlines) == pdfFile.bodyText.trimmingCharacters(in: .newlines), "The body text should match the tested text.")
}
