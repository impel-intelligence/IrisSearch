//
//  ModelConfiguration.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 7/23/26.
//

import Foundation

struct ModelConfiguration: Codable, Sendable {
    let tokenizerClass: String
    
    let maximumInputCharactersPerWord: Int
    let cleanText: Bool
    let handleChineseCharacters: Bool
    let stripAccents: Bool?
    let lowercase: Bool
    
    let searchPrefix: String?
    
    static func load(from url: URL) throws -> ModelConfiguration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ModelConfiguration.self, from: data)
    }
}
