//
//  Common.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//

import IrisCommon
import IrisSearch
import Foundation

class TestingDirectories {
    let databaseName: String = "main"
    let baseURL: URL
    let bundleURL: URL
    let sqliteURL: URL
    let textIndexURL: URL
    //    let imageIndexURL: URL
    
    init() {
        baseURL = FileManager.default.temporaryDirectory.appending(path: "tmp-database-\(UUID())")
        bundleURL = baseURL.appendingPathComponent("\(databaseName).irisdb")
        sqliteURL = bundleURL.appending(path: "map.sqlite")
        textIndexURL = bundleURL.appending(path: "text-index")
        //        imageIndexURL = bundleURL.appending(path: "image-index")
    }
    
    deinit {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

/// Wrap a plain string as the digester would hand it to intake: a single text content unit.
func textContent(_ string: String) -> [EmbeddableContent] {
    return [.text(content: string)]
}

extension DocumentPiece {
    /// Convenience for reading the text payload of a piece in assertions.
    var text: String? {
        if case .text(let content) = content { return content }
        return nil
    }
}
