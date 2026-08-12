//
//  Metrics.swift
//  IrisSearch
//
//  Authored by Claude Opus 5 (Anthropic) on 2026-08-11.
//

import Foundation

/// A summary of a set of timing samples.
///
/// All values are expressed in milliseconds. Percentiles use the nearest-rank method so that a
/// reported percentile is always an observed sample rather than an interpolation between two.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct DurationStats: Codable, Sendable {
    let count: Int
    let totalMilliseconds: Double
    let meanMilliseconds: Double
    let minMilliseconds: Double
    let maxMilliseconds: Double
    let p50Milliseconds: Double
    let p90Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let standardDeviationMilliseconds: Double
    /// Standard deviation as a percentage of the mean. High values mean the measurement is noisy.
    let relativeStandardDeviation: Double

    static let empty = DurationStats(samplesInMilliseconds: [])

    /// Summarizes raw millisecond samples.
    ///
    /// - Parameter samplesInMilliseconds: The measured durations, in milliseconds, in any order.
    /// - Authored by: Claude Opus 5 (Anthropic)
    init(samplesInMilliseconds samples: [Double]) {
        guard !samples.isEmpty else {
            count = 0
            totalMilliseconds = 0
            meanMilliseconds = 0
            minMilliseconds = 0
            maxMilliseconds = 0
            p50Milliseconds = 0
            p90Milliseconds = 0
            p95Milliseconds = 0
            p99Milliseconds = 0
            standardDeviationMilliseconds = 0
            relativeStandardDeviation = 0
            return
        }

        let sorted = samples.sorted()
        let n = Double(sorted.count)
        let total = sorted.reduce(0, +)
        let mean = total / n

        // Sample standard deviation (n - 1) when there is more than one observation.
        let variance = sorted.count > 1
            ? sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
            : 0

        count = sorted.count
        totalMilliseconds = total
        meanMilliseconds = mean
        minMilliseconds = sorted[0]
        maxMilliseconds = sorted[sorted.count - 1]
        p50Milliseconds = DurationStats.percentile(0.50, of: sorted)
        p90Milliseconds = DurationStats.percentile(0.90, of: sorted)
        p95Milliseconds = DurationStats.percentile(0.95, of: sorted)
        p99Milliseconds = DurationStats.percentile(0.99, of: sorted)
        standardDeviationMilliseconds = variance.squareRoot()
        relativeStandardDeviation = mean == 0 ? 0 : (variance.squareRoot() / mean) * 100
    }

    /// Nearest-rank percentile of an already sorted array.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    private static func percentile(_ fraction: Double, of sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

/// Accumulates timing samples for a named measurement.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct SampleCollector {
    private(set) var samplesInMilliseconds: [Double] = []

    mutating func record(_ duration: Duration) {
        samplesInMilliseconds.append(duration.milliseconds)
    }

    mutating func record(milliseconds: Double) {
        samplesInMilliseconds.append(milliseconds)
    }

    var stats: DurationStats { DurationStats(samplesInMilliseconds: samplesInMilliseconds) }
}

extension Duration {
    /// This duration expressed as a floating point count of milliseconds.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    /// This duration expressed as a floating point count of seconds.
    ///
    /// - Authored by: Claude Opus 5 (Anthropic)
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Measures how long an asynchronous operation takes, returning both its value and the elapsed time.
///
/// - Authored by: Claude Opus 5 (Anthropic)
func timed<T>(_ body: () async throws -> T) async rethrows -> (value: T, duration: Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    return (value, clock.now - start)
}

/// The result of fitting `y = a · x^b` to a set of points.
///
/// - Authored by: Claude Opus 5 (Anthropic)
struct PowerLawFit: Sendable {
    let exponent: Double
    let coefficient: Double
    /// Coefficient of determination on the log-log transform, in `0...1`.
    ///
    /// This is what stops a single stray checkpoint from silently rewriting the conclusion. A run
    /// whose smallest corpus size is distorted by first-touch effects still produces an exponent, but
    /// a low `rSquared` says that exponent does not describe the data.
    let rSquared: Double
    let pointCount: Int
}

/// Fits `y = a · x^b` to the supplied points using least squares on the log-log transform.
///
/// The exponent tells you how the measured cost scales: `b ≈ 0` is flat, `b ≈ 1` is linear, `b ≈ 2`
/// is quadratic. Points with a non-positive coordinate are skipped because the log transform is
/// undefined for them.
///
/// - Parameter points: `(x, y)` pairs, typically (vectors in index, milliseconds).
/// - Returns: The fit, or `nil` when there are fewer than two usable points.
/// - Authored by: Claude Opus 5 (Anthropic)
func fitPowerLaw(points: [(x: Double, y: Double)]) -> PowerLawFit? {
    let usable = points.filter { $0.x > 0 && $0.y > 0 }
    guard usable.count >= 2 else { return nil }

    let logs = usable.map { (x: Foundation.log($0.x), y: Foundation.log($0.y)) }
    let n = Double(logs.count)
    let meanX = logs.reduce(0) { $0 + $1.x } / n
    let meanY = logs.reduce(0) { $0 + $1.y } / n

    let covariance = logs.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
    let varianceX = logs.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }

    guard varianceX > 0 else { return nil }

    let exponent = covariance / varianceX
    let intercept = meanY - exponent * meanX

    let residualSumOfSquares = logs.reduce(0) { total, point in
        let predicted = intercept + exponent * point.x
        return total + (point.y - predicted) * (point.y - predicted)
    }
    let totalSumOfSquares = logs.reduce(0) { $0 + ($1.y - meanY) * ($1.y - meanY) }
    let rSquared = totalSumOfSquares > 0 ? 1 - (residualSumOfSquares / totalSumOfSquares) : 1

    return PowerLawFit(
        exponent: exponent,
        coefficient: Foundation.exp(intercept),
        rSquared: rSquared,
        pointCount: usable.count
    )
}
