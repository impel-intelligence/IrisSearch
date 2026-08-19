//
//  Generation.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/18/26.
//

import Foundation
import UniformTypeIdentifiers

enum DatabaseGenerationError: Error, Equatable {
    case noGenerationExists(url: URL)
    case notADirectory(url: URL)
}

final class DatabaseGeneration {
    public var generation: UInt64
    public var vectorStore: VectorStoreFile
    public var slotMap: SlotMapFile
    public var documentMap: DocumentMapFile
    
    private static let syncThreshold: Int = 32
    
    /// How many appends have happened since the last sync to disk
    private var appendsSinceSync: Int = 0
    
    /// The count of slots that have been confirmed to be synced to disk.
    private var durableSlotCount: Int = 0

    private var url: URL
    
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
        self.documentMap = try DocumentMapFile(url: docMapURL, maximumSlotCount: slotMap.map.count)
    }
   
}

extension DatabaseGeneration {
    public func submit(embeddings: [[Float]], ids: [UInt64], documentUUID: UUID, documentID: UInt64) throws {
        let slots = slotMap.append(contentsOf: ids)
        
        try vectorStore.reserve(upTo: slots.upperBound)
        _ = try vectorStore.write(vectors: embeddings, at: slots.lowerBound)

        try documentMap.append(uuid: documentUUID, documentID: documentID, slots: slots, live: true)
        appendsSinceSync += 1
        
        if appendsSinceSync >= Self.syncThreshold {
            try synchronize()
        }
    }
    
    func delete(documentUUID: UUID, documentID: Int64, pieceIDs: [Int]) throws {
        let range = try documentMap.remove(uuid:documentUUID, documentID: UInt64(documentID))
        slotMap.tombstone(range: range)
        appendsSinceSync += 1
        
        if appendsSinceSync > Self.syncThreshold {
            try synchronize()
        }
    }
    
    func synchronize() throws {
        try vectorStore.synchronize()
        try slotMap.file.synchronize()
        try documentMap.file.synchronize()

        durableSlotCount = slotMap.map.count
    }
}


// MARK: Creation & Loading
extension DatabaseGeneration {
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
        
        // A safeguard, but realistically can never be triggered since generationURL is set to a .directory and the fileExists will fail if it is not a directory.
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
