//
//  VectorStoreFile.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/17/26.
//

import Foundation

enum VectorFileError: Error {
    case notEnoughSpaceInFile(requested: Range<Int>, capacity: Int)
    case dimensionMismatch(found: Int, expected: Int)
    case couldNotRebasePointer
    case outOfRange(slot: Int, valid: Range<Int>)
}

enum VectorHeaderError: Error {
    case truncatedFile(found: Int, needed: Int)
    case unsupportedVersion(found: UInt32, supported: UInt32)
    case incorrectMagic
    case invalidDimensions(found: UInt64)
}

final class VectorStoreFile: BinaryFile {
    struct Header: DataExpressible {
        enum Offset {
            static let magic = 0
            static let version = 4
            static let dimensions = 8
            static let generation = 16
        }
        
        static let magic = Array("IVEC".utf8)
        static let version: UInt32 = 1
        static let byteCount: Int = 4096
        
        var dimensions: UInt64
        var generation: UInt64
        
        init(dimensions: UInt64, generation: UInt64) {
            self.dimensions = dimensions
            self.generation = generation
        }
        
        init(bytes: Data) throws {
            // Make sure we have at least the minimum amount of bytes needed for the header.
            guard bytes.count >= Self.byteCount else {
                throw VectorHeaderError.truncatedFile(found: bytes.count, needed: Self.byteCount)
            }
            
            // Array slices are absolute so they require a base to offset reads.
            let base = bytes.startIndex

            let magic = Array(bytes[base..<base + Self.magic.count])
            guard magic == Self.magic else {
                throw VectorHeaderError.incorrectMagic
            }
            
            let version: UInt32 = bytes.load(at: Offset.version)
            guard version == Self.version else {
                throw VectorHeaderError.unsupportedVersion(found: version, supported: Self.version)
            }
            
            let dimensions: UInt64 = bytes.load(at: Offset.dimensions)
            
            // Dimensions of 0 makes no sense, so report an error
            guard dimensions > 0 else {
               throw VectorHeaderError.invalidDimensions(found: dimensions)
           }

            self.dimensions = dimensions
            self.generation = bytes.load(at: Offset.generation)
        }

        func encode(into bytes: inout [UInt8]) {
            let base = bytes.count
            bytes.append(contentsOf: repeatElement(0, count: Self.byteCount))
            bytes.replaceSubrange(base ..< base + Self.magic.count, with: Self.magic)
            bytes.store(Self.version, at: base + Offset.version)
            bytes.store(dimensions, at: base + Offset.dimensions)
            bytes.store(generation, at: base + Offset.generation)
        }
        
        func encoded() -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Self.byteCount)
            encode(into: &bytes)
            return bytes
        }
    }

    let header: Header
    let url: URL
    var mapping: Data
    
    /// The dimensions of the vector store. Proxy for `header.dimensions`
    public var dimensions: Int { Int(header.dimensions) }
    
    /// How big is one vector slot in the file.
    var slotByteCount: Int { dimensions * MemoryLayout<Float>.size }
    
    /// What is the current slot capacity of the file.
    var capacity: Int { max(0, (mapping.count - Header.byteCount) / slotByteCount) }
        
    public override init(url: URL) throws {
        self.url = url
        mapping = try Data(contentsOf: url, options: .alwaysMapped)
        header = try Header(bytes: mapping)
        try super.init(url: url)
    }
    
    /// Creates a new ``VectorStoreFile`` with the given dimensions
    /// - Parameters:
    ///   - url: Where the store should be saved
    ///   - dimensions: The size of vectors that the store supports
    public static func new(at url: URL, dimensions: UInt64, generation: UInt64 = 0) throws -> VectorStoreFile {
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let emptyFile = Header(dimensions: dimensions, generation: generation).encoded()
        let data = Data(emptyFile)
        try data.write(to: url, options: .withoutOverwriting)
        return try VectorStoreFile(url: url)
    }
    
    internal override func write(data: Data, at offset: UInt64) throws {
        try super.write(data: data, at: offset)
        try remap()
    }
    
    internal override func append(data: Data) throws {
        try super.append(data: data)
        try remap()
    }
    
    internal override func scale(to offset: UInt64) throws {
        try super.scale(to: offset)
        try remap()
    }

    /// Remap the `mmap` data whenever an update is performed to the original file
    /// This is because `data` does not automatically update based on changes made to the original file.
    private func remap() throws {
        mapping = try Data(contentsOf: url, options: .alwaysMapped)
    }
}

// MARK: Vector Retrieval
extension VectorStoreFile {
    /// Access the vector matrix of the store.
    /// - Parameter body: A closure to be called with the vector pointer.
    /// - Returns: A pointer directly to the vector portion of the store.
    @inlinable public func withVectorMatrix<R>(body: ((UnsafePointer<Float>) throws -> R)) throws -> R {
        // Make a local reference to the mapping, if the mapping changes we don't want to shift in the middle of this function.
        let retainedMapping = mapping
        return try retainedMapping.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.advanced(by: Header.byteCount).assumingMemoryBound(to: Float.self) else {
                throw VectorFileError.couldNotRebasePointer
            }
            
            return try body(base)
        }
    }
}

// MARK: Vector Insert
extension VectorStoreFile {    
    private func byteOffset(for slot: Int) -> UInt64 {
        return UInt64(Header.byteCount + (slot * slotByteCount))
    }
        
    public func reserve(upTo slot: Int) throws {
        let newOffset = byteOffset(for: slot)
        try self.scale(to: newOffset)
    }

    /// Write the vectors into the VectorStoreFile at the given slot
    /// - Parameters:
    ///   - vectors: The vectors of size `dimension`.
    ///   - slot: The slot number to insert at.
    /// - Returns: The range of slots that the vectors now inhabit.
    public func write(vectors: [[Float]], at slot: Int) throws -> Range<Int> {
        let range = slot..<(slot + vectors.count)

        guard slot >= 0, range.upperBound <= capacity else {
            throw VectorFileError.notEnoughSpaceInFile(requested: range, capacity: capacity)
        }
        
        var flatVectors: [Float] = []
        flatVectors.reserveCapacity(vectors.count * dimensions)
        for vector in vectors {
            guard vector.count == dimensions else {
                throw VectorFileError.dimensionMismatch(found: vector.count, expected: dimensions)
            }
            
            flatVectors.append(contentsOf: vector)
        }
        
        try flatVectors.withUnsafeBytes { buffer in
            try write(data: Data(buffer), at: byteOffset(for: slot))
        }
        
        return range
    }
}
