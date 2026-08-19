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
    public var documentLog: DocumentLogFile
    
    private static let syncThreshold: Int = 32
    
    /// How many changes have happened since the last sync to disk
    private var changesSinceLastSync: Int = 0

    private var url: URL
    
    private init(generation: UInt64, url: URL) throws {
        self.generation = generation
        self.url = url
    
        let vectorStoreURL = url.appending(path: "vec.bin")
        self.vectorStore = try VectorStoreFile(url: vectorStoreURL)
        
        let slotMapURL = url.appending(path: "slot.bin")
        self.slotMap = try SlotMapFile(url: slotMapURL)
        
        let docMapURL = url.appending(path: "doc.bin")
        self.documentLog = try DocumentLogFile(url: docMapURL, maximumSlotCount: slotMap.count)
    }
}

extension DatabaseGeneration {
    public func submit(embeddings: [[Float]], ids: [UInt64], documentUUID: UUID, documentID: UInt64) throws {
        // Get slots that the embeddings can go into by adding their ids to the slot map.
        let slots = try slotMap.append(contentsOf: ids)
        
        // Expand the vector store to fit the new slots
        try vectorStore.reserve(upTo: slots.upperBound)
        
        // Write the vectors to into the start of their slot range.
        _ = try vectorStore.write(vectors: embeddings, at: slots.lowerBound)

        // Tell the document log that the region of slots has become live.
        try documentLog.append(uuid: documentUUID, documentID: documentID, slots: slots, live: true)
        
        // Update the number of changes
        changesSinceLastSync += 1
        
        // Check to see if we need to synchronize
        if changesSinceLastSync >= Self.syncThreshold {
            try synchronize()
        }
    }
    
    func delete(documentUUID: UUID, documentID: Int64, pieceIDs: [Int]) throws {
        // Find the slot ranges for the document. This will throw if the document has no range.
        let range = try documentLog.range(for: documentUUID)
        
        // Remove the ranges from the slot map so they will be ignored in any searches.
        try slotMap.tombstone(range: range)
        
        // Append a log to the document log that marks the document as no longer live.
        _ = try documentLog.append(uuid:documentUUID, documentID: UInt64(documentID), slots: range, live: false)
        
        // Update the number of changes
        changesSinceLastSync += 1
        
        // Check to see if we need to synchronize
        if changesSinceLastSync >= Self.syncThreshold {
            try synchronize()
        }
    }
    
    func synchronize() throws {
        // First step of synchronization is to synchronize all of the content to disk. If any one of these fail, the slot map commit will not go through.
        // If the slot map is not committed, any appends to the database will be intentionally lost on next load, then deleted during compaction.
        try vectorStore.synchronize()
        try slotMap.synchronizeFile()
        try documentLog.synchronizeFile()

        // Mark the changes synced as complete by writing the header and updating the durable tracker.
        try slotMap.commit()
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
        _ = try DocumentLogFile.new(at: docMapURL, maximumSlotCount: 0)

        return try DatabaseGeneration(generation: generation, url: generationURL)
    }
}

