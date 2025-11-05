//
//  RequestPacer.swift
//  swift-ratelimiter
//
//  Created by Coen ten Thije Boonkkamp on 19/12/2024.
//

import Foundation

/// A request pacer that schedules requests to maintain a target rate and avoid burst traffic.
///
/// `RequestPacer` distributes requests evenly over time to prevent overwhelming APIs with
/// burst traffic. Unlike rate limiting which enforces hard limits, pacing proactively
/// schedules requests to maintain a smooth, consistent rate.
///
/// ## Features
///
/// - **Smooth Distribution**: Evenly spaces requests over time
/// - **Burst Prevention**: Avoids triggering API burst detection
/// - **Optional Rate Limiting**: Can compose with `RateLimiter` for combined protection
/// - **Per-Key Scheduling**: Independent pacing for different keys
/// - **Thread-Safe**: Built with Swift's actor model
///
/// ## Basic Usage
///
/// ```swift
/// // Create a pacer for 25 requests per second
/// let pacer = RequestPacer<String>(targetRate: 25.0)
///
/// // Schedule a request
/// let schedule = await pacer.scheduleRequest("api-key")
///
/// // Wait until it's time to proceed
/// await schedule.waitUntilReady()
///
/// // Make the API request
/// makeRequest()
/// ```
///
/// ## With Rate Limiting
///
/// ```swift
/// let rateLimiter = RateLimiter<String>(
///     windows: [.seconds(1, maxAttempts: 25)]
/// )
///
/// let pacer = RequestPacer<String>(
///     targetRate: 25.0,
///     rateLimiter: rateLimiter
/// )
///
/// let schedule = await pacer.scheduleRequest("api-key")
/// if schedule.isAllowed {
///     await schedule.waitUntilReady()
///     makeRequest()
/// }
/// ```
public actor RequestPacer<Key: Hashable & Sendable>: Sendable {

    /// The result of scheduling a request.
    public struct ScheduleResult: Sendable {
        /// Whether the request is allowed (always true unless rate limiter denies it).
        public let isAllowed: Bool

        /// When the request should proceed.
        public let scheduledTime: Date

        /// How long to wait from now until the scheduled time.
        public let delay: TimeInterval

        /// Rate limit information if a rate limiter is configured.
        public let rateLimitInfo: RateLimiter<Key>.RateLimitResult?

        /// Waits until the scheduled time has arrived.
        ///
        /// This method will sleep until it's time for the request to proceed,
        /// ensuring proper pacing between requests.
        @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
        public func waitUntilReady() async throws {
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Configuration for request pacing behavior.
    public struct Config: Sendable {
        /// The target number of requests per second.
        public let targetRate: Double

        /// Optional rate limiter for enforcing hard limits alongside pacing.
        public let rateLimiter: RateLimiter<Key>?

        /// Whether to allow bursts up to the rate limit when requests are behind schedule.
        /// When false, strictly maintains even spacing regardless of timing.
        public let allowCatchUp: Bool

        /// Creates a pacing configuration.
        ///
        /// - Parameters:
        ///   - targetRate: The target number of requests per second.
        ///   - rateLimiter: Optional rate limiter for combined protection.
        ///   - allowCatchUp: Whether to allow faster requests when behind schedule. Defaults to false.
        public init(
            targetRate: Double,
            rateLimiter: RateLimiter<Key>? = nil,
            allowCatchUp: Bool = false
        ) {
            self.targetRate = targetRate
            self.rateLimiter = rateLimiter
            self.allowCatchUp = allowCatchUp
        }
    }

    private struct ScheduleInfo {
        var lastScheduledTime: Date?
        var requestCount: Int = 0
    }

    private let config: Config
    private let minSpacing: TimeInterval
    private var schedules: [Key: ScheduleInfo] = [:]

    /// Creates a request pacer with the specified target rate.
    ///
    /// - Parameters:
    ///   - targetRate: The target number of requests per second.
    ///   - rateLimiter: Optional rate limiter for enforcing hard limits alongside pacing.
    ///   - allowCatchUp: Whether to allow faster requests when behind schedule. Defaults to false.
    public init(
        targetRate: Double,
        rateLimiter: RateLimiter<Key>? = nil,
        allowCatchUp: Bool = false
    ) {
        self.config = Config(
            targetRate: targetRate,
            rateLimiter: rateLimiter,
            allowCatchUp: allowCatchUp
        )
        self.minSpacing = 1.0 / targetRate
    }

    /// Creates a request pacer with the specified configuration.
    ///
    /// - Parameter config: The pacing configuration.
    public init(config: Config) {
        self.config = config
        self.minSpacing = 1.0 / config.targetRate
    }

    /// Schedules a request for the specified key.
    ///
    /// This method calculates when the request should proceed based on the target rate
    /// and previous requests for the same key. If a rate limiter is configured, it also
    /// checks rate limits before scheduling.
    ///
    /// - Parameters:
    ///   - key: The unique identifier for pacing (e.g., API key, user ID).
    ///   - timestamp: The current timestamp. Defaults to the current time.
    ///
    /// - Returns: A `ScheduleResult` containing timing information and rate limit status.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let pacer = RequestPacer<String>(targetRate: 10.0) // 10 req/sec
    ///
    /// // Schedule multiple requests
    /// for i in 1...20 {
    ///     let schedule = await pacer.scheduleRequest("api-key")
    ///
    ///     Task {
    ///         await schedule.waitUntilReady()
    ///         print("Request \(i) executing at \(Date())")
    ///     }
    /// }
    /// ```
    public func scheduleRequest(
        _ key: Key,
        timestamp: Date = Date()
    ) async -> ScheduleResult {
        // Check rate limits first if configured
        let rateLimitResult: RateLimiter<Key>.RateLimitResult?
        if let rateLimiter = config.rateLimiter {
            rateLimitResult = await rateLimiter.checkLimit(key, timestamp: timestamp)

            // If rate limited, return immediately without scheduling
            if !rateLimitResult!.isAllowed {
                return ScheduleResult(
                    isAllowed: false,
                    scheduledTime: timestamp,
                    delay: 0,
                    rateLimitInfo: rateLimitResult
                )
            }

            // Record the attempt since it's allowed
            await rateLimiter.recordAttempt(key, timestamp: timestamp)
        } else {
            rateLimitResult = nil
        }

        // Calculate pacing schedule
        var info = schedules[key] ?? ScheduleInfo()

        let scheduledTime: Date
        if let lastScheduled = info.lastScheduledTime {
            if config.allowCatchUp {
                // Allow catching up if we're behind schedule
                scheduledTime = max(timestamp, lastScheduled.addingTimeInterval(minSpacing))
            } else {
                // Strict pacing - always maintain minimum spacing from last scheduled time
                scheduledTime = lastScheduled.addingTimeInterval(minSpacing)
            }
        } else {
            // First request for this key - schedule immediately
            scheduledTime = timestamp
        }

        info.lastScheduledTime = scheduledTime
        info.requestCount += 1
        schedules[key] = info

        let delay = max(0, scheduledTime.timeIntervalSince(timestamp))

        return ScheduleResult(
            isAllowed: true,
            scheduledTime: scheduledTime,
            delay: delay,
            rateLimitInfo: rateLimitResult
        )
    }

    /// Resets the pacing schedule for the specified key.
    ///
    /// This clears all scheduling information for the key, allowing the next request
    /// to proceed immediately without pacing delays.
    ///
    /// - Parameter key: The unique identifier to reset.
    public func reset(_ key: Key) async {
        schedules.removeValue(forKey: key)
    }

    /// Resets all pacing schedules.
    ///
    /// This clears all scheduling information for all keys.
    public func resetAll() async {
        schedules.removeAll()
    }

    /// Gets the current request count for a key.
    ///
    /// - Parameter key: The unique identifier to query.
    /// - Returns: The number of requests scheduled for this key, or 0 if not found.
    public func getRequestCount(_ key: Key) async -> Int {
        schedules[key]?.requestCount ?? 0
    }
}
