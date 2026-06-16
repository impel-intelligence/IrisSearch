//
//  ResultsRanker.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/15/26.
//

protocol ResultsRanker {
    func rank(documents: [IrisDocument], query: String) -> [IrisDocument]
}
