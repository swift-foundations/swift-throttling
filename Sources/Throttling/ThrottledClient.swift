//
//  ThrottledClient.swift
//  swift-ratelimiter
//
//  Created by Coen ten Thije Boonkkamp on 19/12/2024.
//

import Foundation

/// A convenience wrapper that combines rate limiting and request pacing for API clients.
///
/// `ThrottledClient` provides a unified interface for managing both rate limits and
/// request pacing, making it easy to build API clients that respect rate limits while
/// avoiding burst traffic.
///
/// ## Features
///
/// - **Combined Protection**: Enforces rate limits while maintaining smooth pacing
/// - **Simple API**: Single method to check if a request should proceed
/// - **Automatic Coordination**: Handles the interaction between rate limiting and pacing
/// - **Flexible Configuration**: Can be used with rate limiting only, pacing only, or both
///
/// ## Usage
///
/// ```swift
/// // Create a throttled client for Stripe API
/// let client = ThrottledClient<String>(
///     rateLimiter: RateLimiter(
///         windows: [
///             .seconds(1, maxAttempts: 25),
///             .minutes(1, maxAttempts: 1500)
///         ]
///     ),
///     pacer: RequestPacer(targetRate: 25.0)
/// )
///
/// // Check if request can proceed
/// let result = await client.acquire("api-key")
///
/// if result.canProceed {
///     // Wait for optimal timing
///     await result.waitUntilReady()
///
///     // Make the API request
///     let response = await makeAPIRequest()
///
///     // Record success or failure
///     if response.isSuccess {
///         await client.recordSuccess("api-key")
///     } else {
///         await client.recordFailure("api-key")
///     }
/// } else {
///     // Handle rate limit exceeded
///     print("Rate limited. Retry after: \(result.retryAfter ?? 0) seconds")
/// }
/// ```
public struct ThrottledClient<Key: Hashable & Sendable>: Sendable {

    /// The result of acquiring permission to make a request.
    public struct AcquisitionResult: Sendable {
        /// Whether the request can proceed (not rate limited).
        public let canProceed: Bool

        /// When the request should execute for optimal pacing.
        public let scheduledTime: Date?

        /// How long to wait before proceeding.
        public let delay: TimeInterval

        /// When to retry if rate limited.
        public let retryAfter: TimeInterval?

        /// The underlying rate limit result.
        public let rateLimitResult: RateLimiter<Key>.RateLimitResult?

        /// The underlying pacing result.
        public let pacingResult: RequestPacer<Key>.ScheduleResult?

        /// Waits until the scheduled time if the request can proceed.
        ///
        /// This method combines the pacing delay with any necessary waiting,
        /// making it easy to respect both rate limits and pacing requirements.
        ///
        /// - Throws: If the task is cancelled while waiting.
        @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
        public func waitUntilReady() async throws {
            guard canProceed, delay > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// The rate limiter for enforcing hard limits.
    public let rateLimiter: RateLimiter<Key>?

    /// The request pacer for smooth traffic distribution.
    public let pacer: RequestPacer<Key>?

    /// Creates a throttled client with both rate limiting and pacing.
    ///
    /// - Parameters:
    ///   - rateLimiter: The rate limiter for enforcing hard limits.
    ///   - pacer: The request pacer for smooth traffic distribution.
    ///
    /// - Note: At least one of `rateLimiter` or `pacer` should be provided.
    public init(
        rateLimiter: RateLimiter<Key>? = nil,
        pacer: RequestPacer<Key>? = nil
    ) {
        self.rateLimiter = rateLimiter
        self.pacer = pacer
    }

    /// Creates a throttled client with convenient configuration.
    ///
    /// This initializer creates both a rate limiter and pacer with common settings.
    ///
    /// - Parameters:
    ///   - windows: Rate limiting windows to enforce.
    ///   - targetRate: Target requests per second for pacing.
    ///   - backoffMultiplier: Multiplier for exponential backoff on failures.
    public init(
        windows: [RateLimiter<Key>.WindowConfig],
        targetRate: Double,
        backoffMultiplier: Double = 2.0
    ) {
        self.rateLimiter = RateLimiter(
            windows: windows,
            backoffMultiplier: backoffMultiplier
        )
        self.pacer = RequestPacer(
            targetRate: targetRate,
            rateLimiter: nil  // Avoid double-checking rate limits
        )
    }

    /// Acquires permission to make a request.
    ///
    /// This method coordinates both rate limiting and pacing to determine if and when
    /// a request should proceed.
    ///
    /// - Parameters:
    ///   - key: The unique identifier for rate limiting and pacing.
    ///   - timestamp: The current timestamp. Defaults to the current time.
    ///
    /// - Returns: An `AcquisitionResult` containing the decision and timing information.
    public func acquire(
        _ key: Key,
        timestamp: Date = Date()
    ) async -> AcquisitionResult {
        // Check rate limits first
        let rateLimitResult: RateLimiter<Key>.RateLimitResult?
        if let rateLimiter = rateLimiter {
            rateLimitResult = await rateLimiter.checkLimit(key, timestamp: timestamp)

            // If rate limited, return immediately
            if !rateLimitResult!.isAllowed {
                let retryAfter =
                    rateLimitResult!.backoffInterval
                    ?? rateLimitResult!.nextAllowedAttempt?.timeIntervalSince(timestamp)

                return AcquisitionResult(
                    canProceed: false,
                    scheduledTime: nil,
                    delay: 0,
                    retryAfter: retryAfter,
                    rateLimitResult: rateLimitResult,
                    pacingResult: nil
                )
            }

            // Record the attempt since it's allowed
            await rateLimiter.recordAttempt(key, timestamp: timestamp)
        } else {
            rateLimitResult = nil
        }

        // Calculate pacing if configured
        let pacingResult: RequestPacer<Key>.ScheduleResult?
        if let pacer = pacer {
            pacingResult = await pacer.scheduleRequest(key, timestamp: timestamp)

            return AcquisitionResult(
                canProceed: true,
                scheduledTime: pacingResult!.scheduledTime,
                delay: pacingResult!.delay,
                retryAfter: nil,
                rateLimitResult: rateLimitResult,
                pacingResult: pacingResult
            )
        } else {
            // No pacing, just rate limiting
            return AcquisitionResult(
                canProceed: true,
                scheduledTime: timestamp,
                delay: 0,
                retryAfter: nil,
                rateLimitResult: rateLimitResult,
                pacingResult: nil
            )
        }
    }

    /// Records a successful request.
    ///
    /// This clears any backoff penalties in the rate limiter.
    ///
    /// - Parameter key: The unique identifier for the successful request.
    public func recordSuccess(_ key: Key) async {
        await rateLimiter?.recordSuccess(key)
    }

    /// Records a failed request.
    ///
    /// This triggers exponential backoff in the rate limiter.
    ///
    /// - Parameter key: The unique identifier for the failed request.
    public func recordFailure(_ key: Key) async {
        await rateLimiter?.recordFailure(key)
    }

    /// Resets all rate limiting and pacing data for a key.
    ///
    /// - Parameter key: The unique identifier to reset.
    public func reset(_ key: Key) async {
        await rateLimiter?.reset(key)
        await pacer?.reset(key)
    }
}
