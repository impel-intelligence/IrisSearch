//
//  IrisQuery.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/20/26.
//


public struct IrisQuery: Sendable {
    let text: String
    // imageData: Data

    /// When `true`, the search pipeline logs which retrieval signal(s) (semantic, syntactic piece,
    /// syntactic title/description) surfaced each result and its rank/score in each, through `Log.logger`
    /// at the `.debug` level. Intended for tuning ranking; leave `false` in production.
    let debug: Bool

    /// Creates a query for the search pipeline.
    /// - Parameters:
    ///   - text: The text to search for.
    ///   - debug: When `true`, logs which retrieval signal(s) surfaced each result. Defaults to `false`.
    public init(text: String, debug: Bool = false) {
        self.text = text
        self.debug = debug
    }
}

