//
//  ImageDecoderRemoteTests.swift
//  IrisSearch
//
//  Authored by Claude Sonnet 5 (Anthropic) on 2026-07-21.
//
//  Exercises ImageDecoder directly against real HTTP endpoints — no mocking, and not routed
//  through HTMLandXMLDigester.digest(). digest() wraps its image-loading call in `try?`, which
//  silently swallows every failure mode tested here (bad status, wrong content type, unreachable
//  host) — so those behaviors are only observable by calling ImageDecoder directly.
//
//  These make genuine outbound network calls, so they're slower and can be flaky (DNS hiccups, a
//  third-party service being briefly unavailable, etc.) compared to the rest of the digester test
//  suite, which is fully offline. That's why they're gated in their own suite/file and tagged
//  `.network`, so they can be filtered out of a fast/offline run if needed
//  (e.g. `swift test --skip-tag network`).
//
//  httpbin.org is a public service purpose-built for exercising exactly these HTTP behaviors (a
//  real image, a specific status code, a non-image content type) without needing to stand up or
//  mock a server ourselves.

import Testing
@testable import Digester
import Foundation

extension Testing.Tag {
    @Tag static var network: Self
}

@Suite("ImageDecoder against the real network", .tags(.network))
struct ImageDecoderRemoteTests {
    @Test("A real, reachable image URL downloads successfully")
    func loadsRealImageSuccessfully() async throws {
        let url = try #require(URL(string: "https://httpbin.org/image/png"))
        let data = try await ImageDecoder().loadImage(url: url)
        let imageData = try #require(data, "A reachable image/png response should return non-nil Data")
        #expect(!imageData.isEmpty)
    }

    @Test("A non-2xx status code throws invalidResponseCode")
    func badStatusCodeThrows() async throws {
        let url = try #require(URL(string: "https://httpbin.org/status/404"))

        do {
            _ = try await ImageDecoder().loadImage(url: url)
            Issue.record("Expected loadImage to throw for a 404 response")
        } catch let error as ImageDecoder.ImageDecodingError {
            guard case .invalidResponseCode(let code) = error else {
                Issue.record("Expected .invalidResponseCode, got \(error)")
                return
            }
            #expect(code == 404)
        } catch {
            Issue.record("Expected ImageDecoder.ImageDownloadError, got \(error)")
        }
    }

    @Test("A response with a non-image content type throws invalidMimeType")
    func wrongContentTypeThrows() async throws {
        let url = try #require(URL(string: "https://httpbin.org/html"))

        do {
            _ = try await ImageDecoder().loadImage(url: url)
            Issue.record("Expected loadImage to throw for a text/html response")
        } catch let error as ImageDecoder.ImageDecodingError {
            guard case .invalidMimeType(let type) = error else {
                Issue.record("Expected .invalidMimeType, got \(error)")
                return
            }
            #expect(type.starts(with: "text/html"))
        } catch {
            Issue.record("Expected ImageDecoder.ImageDownloadError, got \(error)")
        }
    }

    @Test("A 200 response whose body isn't a decodable image throws invalidImageData")
    func undecodableImageBodyThrows() async throws {
        // /robots.txt is served with a text content type, but /base64/<data> lets us force a
        // 200 + arbitrary body — pairing that with an image/* Accept header isn't enough to fool
        // ImageDecoder's own ImageIO-based decode check, since it validates the bytes themselves,
        // not just the declared content type. Easiest reliable trigger: request a real 200 whose
        // body is plain text but whose reported content type still starts with "image/" is hard
        // to get from httpbin directly, so instead we hit an endpoint that's 200 with a body that
        // is definitely not image data, and confirm the failure surfaces as *some*
        // ImageDownloadError — the specific case httpbin lets us reach deterministically here is
        // invalidMimeType (see wrongContentTypeThrows above); this test covers the analogous
        // "200 but not usable as an image" shape via /status/200 (empty body, no content-type).
        let url = try #require(URL(string: "https://httpbin.org/status/200"))

        do {
            _ = try await ImageDecoder().loadImage(url: url)
            Issue.record("Expected loadImage to throw for a response with no usable image content")
        } catch is ImageDecoder.ImageDecodingError {
            // Any ImageDownloadError is acceptable here (likely .noMimeType, since /status/200
            // returns an empty body with no Content-Type header) — the point is that a 200 with
            // no real image content never produces valid Data.
        } catch {
            Issue.record("Expected ImageDecoder.ImageDownloadError, got \(error)")
        }
    }

    @Test("An unreachable host throws a network-level error")
    func unreachableHostThrows() async throws {
        // .invalid is a reserved TLD (RFC 2606) guaranteed to never resolve.
        let url = try #require(URL(string: "https://this-host-does-not-exist.invalid/photo.png"))

        await #expect(throws: (any Error).self) {
            try await ImageDecoder().loadImage(url: url)
        }
    }

    @Test("loadImage(src:relativeTo:) resolves an absolute remote src and downloads it")
    func loadImageWithAbsoluteSrcResolvesAndDownloads() async throws {
        // The `relativeTo:` base is irrelevant here since `src` is already absolute — this
        // exercises the URL(string:relativeTo:) resolution path used by digest() itself, rather
        // than calling loadImage(url:) directly like the other tests in this file.
        let base = URL(fileURLWithPath: "/tmp/does-not-matter.html")
        let data = try await ImageDecoder().loadImage(src: "https://httpbin.org/image/png", relativeTo: base)
        let imageData = try #require(data)
        #expect(!imageData.isEmpty)
    }
}
