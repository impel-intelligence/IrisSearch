//
//  Generation.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation
import UniformTypeIdentifiers

enum DatabaseGenerationError: Error {
    case noGenerationExists(url: URL)
    case notADirectory(url: URL)
}

final class DatabaseGeneration {
    public var generation: UInt64
    
    private var url: URL
    
    private var vectorStore: VectorStoreFile
    private var slotMap: SlotMapFile
    private var documentMap: DocumentMapFile
    
    /// <#Description#>
    /// - Parameters:
    ///   - generation: <#generation description#>
    ///   - url: <#url description#>
    private init(generation: UInt64, url: URL) throws {
        self.generation = generation
        self.url = url
    
        let vectorStoreURL = url.appending(path: "vec.bin")
        self.vectorStore = try VectorStoreFile(url: vectorStoreURL)
        
        let slotMapURL = url.appending(path: "slot.bin")
        self.slotMap = try SlotMapFile(url: slotMapURL)
        
        let docMapURL = url.appending(path: "doc.bin")
        self.documentMap = try DocumentMapFile(url: docMapURL, maximumSlotCount: slotMap.header.count)
    }
    
    /// Find the current generation in a parent directory
    /// - Parameter parentDirectory: The directory to search for generations in.
    static func detect(in parentDirectory: URL) throws -> UInt64? {
        let genFolders = try FileManager.default.contentsOfDirectory(at: parentDirectory, includingPropertiesForKeys: [.isDirectoryKey]).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false && url.lastPathComponent.contains("gen-")
        }
        
        guard !genFolders.isEmpty else { return nil }
        
        // Grab all of the generation integers
        let generations = genFolders.compactMap({ UInt64($0.lastPathComponent.trimmingPrefix("gen-")) })
                
        return generations.max()
    }

    /// Load a database generation at the given parent directory
    /// - Parameters:
    ///   - generation: The database generation to load.
    ///   - parentDirectory: The parent to look for the generation in.
    /// - Returns: A DatabaseGeneration loaded from the parent directory.
    static func load(generation: UInt64, in parentDirectory: URL) throws -> DatabaseGeneration {
        let generationURL: URL = parentDirectory.appendingPathComponent("gen-\(generation)", conformingTo: .directory)
        
        var isDirectory: ObjCBool = false
        
        guard FileManager.default.fileExists(atPath: generationURL.path(percentEncoded: false), isDirectory: &isDirectory) else {
            throw DatabaseGenerationError.noGenerationExists(url: generationURL)
        }
        
        guard isDirectory.boolValue else { throw DatabaseGenerationError.notADirectory(url: generationURL) }
        
        return try DatabaseGeneration(generation: generation, url: generationURL)
    }
    
    /// Create a new database generation at the given parent directory
    /// - Parameters:
    ///   - parentDirectory: <#parentDirectory description#>
    ///   - generation: <#generation description#>
    ///   - dimensions: <#dimensions description#>
    /// - Returns: <#description#>
    static func new(at parentDirectory: URL, generation: UInt64, dimensions: UInt64) throws -> DatabaseGeneration {
        let generationURL: URL = parentDirectory.appendingPathComponent("gen-\(generation)", conformingTo: .directory)
        
        try FileManager.default.createDirectory(at: generationURL, withIntermediateDirectories: true)
        
        let vectorStoreURL = generationURL.appending(path: "vec.bin")
        _ = try VectorStoreFile.new(at: vectorStoreURL, dimensions: dimensions)
        
        let slotMapURL = generationURL.appending(path: "slot.bin")
        _ = try SlotMapFile.new(at: slotMapURL)
        
        let docMapURL = generationURL.appending(path: "doc.bin")
        _ = try DocumentMapFile.new(at: docMapURL, maximumSlotCount: 0)

        return try DatabaseGeneration(generation: generation, url: generationURL)
    }
}
