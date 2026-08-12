//
//  empty.swift
//  IrisSearch
//
//  Created by Taylor Lineman on 6/10/26.
//

import IrisCommon
import UniformTypeIdentifiers

/// A standard error returned by a ``FileDigester`` during digestion.
public enum DigestionError: Error {
    /// The file was not readable. This is most likely because the file does not exist on disk. If the library
    /// is running in an App Sandbox, this can also be because the URL is not properly security scoped.
    /// See ``FileDigester/digest(file:contextSize:)`` for information on security scoping
    /// urls.
    case fileNotReadable
    /// The provided file has no data.
    case emptyFile
    /// The provided URL is not a a local file URL.
    case notAFileURL
    /// The extension on the file does not match the content type it declares. This is a safety measure,
    /// and may throw false flags.
    case incorrectExtension
    /// The file `type` is not valid for ``FileDigester`` that is being used.
    case fileTypeNotValid(type: UTType)
    /// There is no ``FileDigester`` that can properly handle the `type.`
    case noAvailableDigester(type: UTType)
}

/// A protocol for an object that can create `EmbeddableContent` that respects
/// document structure.
///
/// Each concrete ``FileDigester`` has a set of ``fileTypes`` that it can properly handle.
/// "Handling" a `UTType` means that the digester will produce EmbeddableContent that properly
/// represents the structure of the document, and the content that it contains (images, text, etc..).
public protocol FileDigester: Sendable, Identifiable {
    /// The `UTTypes` that can be properly handled by this ``FileDigester``.
    static var fileTypes: [UTType] { get }
    
    /// A standard initializer for a ``FileDigester``.
    init()
    
    
    /// Creates an array of `EmbeddableContent` that represents the
    /// documents content and structure. `EmbeddableContent` pieces are
    /// document positioning aware, allowing end-clients to point an
    /// `EmbeddableContent` instance back to its original document position.
    ///
    /// This function does not attempt to gain security scoping for the provided URL. Security scoping
    /// urls is required for Sandboxed applications, and must be done at the call-site.
    ///
    /// ```swift
    /// // Gain access to the url's security scope
    /// guard url.startAccessingSecurityScopedResource() else { return }
    /// // Use a defer to stop accessing the security scope, defer is preferred
    /// // because it will still run after a thrown error.
    /// defer { url.stopAccessingSecurityScopedResource() }
    /// try await digester.digest(file: url, contextSize: 512)
    /// ```
    ///
    /// - Parameters:
    ///   - file: The file URL to the document that should be digested.
    ///   - contextSize: The maximum size of any single `EmbeddableContent`
    /// - Returns: An array of  `EmbeddableContent` that represents the
    ///            document content and structure. Each piece of content is traceable to its original
    ///            document position.
    func digest(file: URL, contextSize: Int) async throws -> [EmbeddableContent]
}

extension FileDigester {
    /// Check to see if a UTType conforms to at least one type in ``fileTypes``.
    ///
    /// - Parameter type: The type to check conformance for.
    /// - Returns: True if the type conforms to at least one type in ``fileTypes``.
    static func isValidType(_ type: UTType) -> Bool {
        return Self.fileTypes.contains(where: { type.conforms(to: $0) })
    }
    
    /// Validate that a URL is a local URL and not an external resource (https, ftp, etc...)
    ///
    /// - Parameter url: The url to validate.
    /// - Returns: Nothing, but this function will throw an error depending on the validation step that
    ///            failed.
    static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL else { throw DigestionError.notAFileURL }
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else { throw DigestionError.fileNotReadable }
        guard let fileType = UTType(filenameExtension: url.pathExtension) else { throw DigestionError.incorrectExtension }
        guard isValidType(fileType) else { throw DigestionError.fileTypeNotValid(type: fileType)}
    }
}
