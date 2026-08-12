//
//  SystemInfo.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Darwin
import Foundation

/// A description of the machine a benchmark ran on.
///
/// Timings are only comparable between runs on equivalent hardware, so every result file embeds
/// this so numbers can never be read without their context.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct HostInformation: Codable, Sendable {
    let cpuModel: String
    let logicalCores: Int
    let physicalMemoryBytes: UInt64
    let operatingSystem: String
    let swiftBuildConfiguration: String
    let hostName: String
    let timestamp: Date

    /// Captures the current host's description.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func current() -> HostInformation {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif

        return HostInformation(
            cpuModel: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            logicalCores: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            operatingSystem: "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            swiftBuildConfiguration: configuration,
            hostName: ProcessInfo.processInfo.hostName,
            timestamp: Date()
        )
    }

    /// Reads a string-valued `sysctl` key.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Process and filesystem measurements taken alongside the timings.
///
/// - Authored by: Claude Opus 5 (Anthropic)
enum ResourceUsage {
    /// The process' physical memory footprint, matching what Activity Monitor reports as "Memory".
    ///
    /// - Returns: The footprint in bytes, or `0` if the kernel call failed.
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func memoryFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    /// Total bytes allocated on disk by everything under `url`, following the directory tree.
    ///
    /// Uses allocated size rather than logical size so that the many small per-document FAISS index
    /// files are accounted for at their true on-disk cost.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func directorySizeBytes(at url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// The size of a single file on disk.
    ///
    /// Deliberately goes through `FileManager` rather than `URL.resourceValues`. A `URL` caches the
    /// resource values it has already been asked for, so re-reading the same `URL` instance as a file
    /// grows returns the size it had the first time it was measured.
    ///
    /// - Returns: The file's size in bytes, or `0` if it does not exist.
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func fileSizeBytes(at url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The number of regular files directly inside `url`.
    ///
    /// The FAISS layer writes one index file per document, so this doubles as a file-handle pressure signal.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    static func fileCount(in url: URL) -> Int {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
        return contents?.count ?? 0
    }
}

/// Formats a byte count using binary units.
///
/// - Authored by: Claude Opus 5 (Anthropic)
func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    return unitIndex == 0 ? "\(bytes) B" : String(format: "%.2f %@", value, units[unitIndex])
}
