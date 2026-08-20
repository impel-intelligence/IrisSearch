//
//  FileDurability.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 8/20/26.
//

import Foundation
import System

enum FileDurability {
    static func fullSync(handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) != -1 else {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
    
    static func fullSync(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try fullSync(handle: handle)
    }
    
    /// Makes a directory entry durable — the *name*, not the contents of what it names.
    ///
    /// This is what commits a rename. `atomicallyReplaceCurrentPointer` writes `current.tmp` and renames
    /// it over `current`; the rename is atomic, but until the directory itself is fsynced a crash can
    /// lose the new name even though the bytes it points at are safely on disk. Same reason a freshly
    /// created generation directory needs one before anything references it.
    ///
    /// - Note: One of the three calls that must drop below Foundation. There is no `FileHandle` for a
    ///   directory, so this opens a descriptor directly. Unlike `fullSync`, it is plain POSIX and works
    ///   on Linux as well as Darwin — `F_FULLFSYNC` is the Darwin-only one.
    ///
    ///   - Authored by: Claude Opus 5 (Anthropic) on  2026-08-20
    static func syncDirectory(_ url: URL) throws {
        // O_DIRECTORY so a path that is not a directory fails here rather than silently fsyncing a file
        // and reporting success for a durability guarantee that was never made.
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
        guard descriptor != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        
        // fsync, not F_FULLFSYNC: this is flushing a directory entry, and the device write cache that
        // F_FULLFSYNC exists to defeat is not in the path for metadata here.
        guard fsync(descriptor) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
