//
//  RateLimiter.swift
//  swift-ratelimiter
//
//  Created by Coen ten Thije Boonkkamp on 19/12/2024.
//

import Foundation

/// A powerful, actor-based rate limiter providing multi-window rate limiting with exponential backoff.
///
/// `RateLimiter` is designed for high-performance, security-first rate limiting scenarios. It supports
/// multiple time windows, exponential backoff for consecutive failures, comprehensive metrics collection,
/// and follows industry-standard patterns used by platforms like GitHub, AWS, and Stripe.
///
/// ## Features
///
/// - **Thread-Safe**: Built with Swift's actor model for concurrent access
/// - **Multi-Window**: Support layered rate limits (e.g., 5/min AND 100/hour)
/// - **Security-First**: Immediate exponential backoff on consecutive failures
/// - **Memory Efficient**: Bounded cache with LRU eviction
/// - **Generic Design**: Works with any `Hashable & Sendable` key type
/// - **Metrics Ready**: Built-in monitoring and analytics hooks
///
/// ## Basic Usage
///
/// ```swift
/// // Create a simple rate limiter
/// let limiter = RateLimiter<String>(
///     windows: [.minutes(1, maxAttempts: 10)]
/// )
///
/// // Check rate limit
/// let result = await limiter.checkLimit("user123")
/// if result.isAllowed {
///     // Process request
/// } else {
///     // Handle rate limit exceeded
///     print("Rate limited. Retry after: \(result.backoffInterval ?? 0) seconds")
/// }
/// ```
///
/// ## Multi-Window Rate Limiting
///
/// Layer multiple time windows for comprehensive protection:
///
/// ```swift
/// let apiLimiter = RateLimiter<String>(
///     windows: [
///         .minutes(1, maxAttempts: 60),    // Burst protection
///         .hours(1, maxAttempts: 1000),    // Hourly limit
///         .hours(24, maxAttempts: 10000)   // Daily limit
///     ]
/// )
/// ```
///
/// ## Security Features
///
/// The rate limiter implements security-first principles:
///
/// - **Immediate Backoff**: Any consecutive failure triggers exponential penalties
/// - **Progressive Penalties**: Each failure increases backoff duration exponentially
/// - **Attack Prevention**: Stops brute force and credential stuffing attacks
/// - **Memory Protection**: Bounded cache prevents memory exhaustion
///
/// ## Topics
///
/// ### Creating Rate Limiters
///
/// - ``init(windows:maxCacheSize:backoffMultiplier:metricsCallback:)``
/// - ``WindowConfig``
///
/// ### Checking Limits
///
/// - ``checkLimit(_:timestamp:)``
/// - ``RateLimitResult``
///
/// ### Recording Results
///
/// - ``recordSuccess(_:)``
/// - ``recordFailure(_:)``
/// - ``reset(_:)``
///
/// ### Window Configuration
///
/// - ``WindowConfig/minutes(_:maxAttempts:)``
/// - ``WindowConfig/hours(_:maxAttempts:)``
public actor RateLimiter<Key: Hashable & Sendable>: Sendable {

    /// Configuration for a rate limiting time window.
    ///
    /// A `WindowConfig` defines a time period and the maximum number of attempts allowed within that period.
    /// Multiple windows can be layered to create sophisticated rate limiting policies.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Create different window configurations
    /// let burst = WindowConfig.minutes(1, maxAttempts: 10)
    /// let hourly = WindowConfig.hours(1, maxAttempts: 1000)
    /// let daily = WindowConfig(duration: 86400, maxAttempts: 10000)
    /// ```
    ///
    /// ## Window Sorting
    ///
    /// Windows are automatically sorted by duration when passed to ``RateLimiter/init(windows:maxCacheSize:backoffMultiplier:metricsCallback:)``.
    /// The shortest window is checked first, ensuring the most restrictive limit applies.
    public struct WindowConfig: Sendable {
        /// The duration of the time window in seconds.
        let duration: TimeInterval

        /// The maximum number of attempts allowed within this window.
        let maxAttempts: Int

        /// Creates a window configuration for a specified number of minutes.
        ///
        /// - Parameters:
        ///   - seconds: The number of seconds for the window duration.
        ///   - maxAttempts: The maximum attempts allowed in this window.
        /// - Returns: A configured window for the specified duration.
        ///
        /// ## Example
        ///
        /// ```swift
        /// // Allow 5 attempts per minute
        /// let windowConfig = WindowConfig.seconds(1, maxAttempts: 5)
        /// ```
        public static func seconds(_ seconds: Int, maxAttempts: Int) -> WindowConfig {
            WindowConfig(duration: TimeInterval(seconds), maxAttempts: maxAttempts)
        }

        /// Creates a window configuration for a specified number of minutes.
        ///
        /// - Parameters:
        ///   - minutes: The number of minutes for the window duration.
        ///   - maxAttempts: The maximum attempts allowed in this window.
        /// - Returns: A configured window for the specified duration.
        ///
        /// ## Example
        ///
        /// ```swift
        /// // Allow 5 attempts per minute
        /// let windowConfig = WindowConfig.minutes(1, maxAttempts: 5)
        /// ```
        public static func minutes(_ minutes: Int, maxAttempts: Int) -> WindowConfig {
            WindowConfig(duration: TimeInterval(minutes * 60), maxAttempts: maxAttempts)
        }

        /// Creates a window configuration for a specified number of hours.
        ///
        /// - Parameters:
        ///   - hours: The number of hours for the window duration.
        ///   - maxAttempts: The maximum attempts allowed in this window.
        /// - Returns: A configured window for the specified duration.
        ///
        /// ## Example
        ///
        /// ```swift
        /// // Allow 100 attempts per hour
        /// let windowConfig = WindowConfig.hours(1, maxAttempts: 100)
        /// ```
        public static func hours(_ hours: Int, maxAttempts: Int) -> WindowConfig {
            WindowConfig(duration: TimeInterval(hours * 3600), maxAttempts: maxAttempts)
        }

        /// Creates a custom window configuration with a specific duration.
        ///
        /// - Parameters:
        ///   - duration: The window duration in seconds.
        ///   - maxAttempts: The maximum attempts allowed in this window.
        ///
        /// ## Example
        ///
        /// ```swift
        /// // Allow 50 attempts per 30 seconds
        /// let windowConfig = WindowConfig(duration: 30, maxAttempts: 50)
        /// ```
        public init(duration: TimeInterval, maxAttempts: Int) {
            self.duration = duration
            self.maxAttempts = maxAttempts
        }
    }

    struct AttemptInfo: Sendable {
        let windowStart: Date
        var attempts: Int
        var consecutiveFailures: Int
        let timestamp: Date
    }

    /// The result of a rate limit check, containing the decision and relevant metadata.
    ///
    /// This structure provides comprehensive information about a rate limit decision, including whether
    /// the request should be allowed, current usage statistics, and timing information for when the
    /// next request could be made.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let result = await rateLimiter.checkLimit("user123")
    ///
    /// if result.isAllowed {
    ///     print("✅ Request allowed")
    ///     print("📊 Used \(result.currentAttempts), \(result.remainingAttempts) remaining")
    /// } else {
    ///     print("❌ Request blocked")
    ///     if let backoff = result.backoffInterval {
    ///         print("⏰ Backoff required: \(backoff) seconds")
    ///     }
    ///     if let nextAttempt = result.nextAllowedAttempt {
    ///         print("🕐 Try again at: \(nextAttempt)")
    ///     }
    /// }
    /// ```
    public struct RateLimitResult: Sendable {
        /// Whether the request should be allowed to proceed.
        ///
        /// `true` indicates the request is within rate limits and not subject to backoff penalties.
        /// `false` indicates the request should be rejected due to rate limits or consecutive failures.
        public let isAllowed: Bool

        /// The current number of attempts within the most restrictive time window.
        ///
        /// This reflects the attempt count in the shortest configured window, providing
        /// immediate visibility into current usage patterns.
        public let currentAttempts: Int

        /// The number of attempts remaining before hitting the rate limit.
        ///
        /// Based on the most restrictive window that would be exceeded next.
        /// When `isAllowed` is `false`, this is typically 0.
        public let remainingAttempts: Int

        /// The earliest time when the next attempt would be allowed based on window expiration.
        ///
        /// `nil` when `isAllowed` is `true`. When rate limited, this indicates when the current
        /// time window will expire, allowing new attempts.
        public let nextAllowedAttempt: Date?

        /// The current backoff duration in seconds due to consecutive failures.
        ///
        /// `nil` when there are no consecutive failures. When present, this represents the
        /// exponential backoff penalty that should be applied before the next attempt.
        /// This backoff is in addition to any window-based rate limits.
        public let backoffInterval: TimeInterval?
    }

    private let windows: [WindowConfig]
    private let maxCacheSize: Int
    private let backoffMultiplier: Double
    private var attemptsByKey: Storage<[AttemptInfo]>
    private let metricsCallback: (@Sendable (Key, RateLimitResult) async -> Void)?

    /// Initializes a new rate limiter with the specified configuration.
    ///
    /// - Parameters:
    ///   - windows: An array of window configurations that define different time periods and their respective attempt limits.
    ///             These windows are sorted by duration in ascending order internally. Multiple windows allow for layered
    ///             rate limiting (e.g., "5 attempts per minute AND 100 attempts per hour").
    ///   - maxCacheSize: The maximum number of unique keys to track simultaneously. When exceeded, least recently used entries
    ///                  are evicted. Defaults to 10000.
    ///   - backoffMultiplier: The factor by which the backoff duration increases after each consecutive failure.
    ///                       For example, with a multiplier of 2.0 and a window of 1 hour, consecutive failures would
    ///                       result in backoff times of 2h, 4h, 8h, etc. Defaults to 2.0.
    ///   - metricsCallback: An optional async closure that's called after each rate limit check, receiving the key and result.
    ///                      Useful for monitoring and analytics. Defaults to nil.
    ///
    /// - Note: The windows array must not be empty. Windows are automatically sorted by duration to ensure consistent
    ///         rate limiting behavior.
    ///
    /// Example usage:
    /// ```swift
    /// let rateLimiter = RateLimiter<String>(
    ///     windows: [
    ///         .minutes(1, maxAttempts: 5),
    ///         .hours(1, maxAttempts: 100)
    ///     ],
    ///     maxCacheSize: 5000,
    ///     backoffMultiplier: 3.0
    /// )
    public init(
        windows: [WindowConfig],
        maxCacheSize: Int = 10000,
        backoffMultiplier: Double = 2.0,
        metricsCallback: (@Sendable (Key, RateLimitResult) async -> Void)? = nil
    ) {
        self.windows = windows.sorted(by: { $0.duration < $1.duration })
        self.maxCacheSize = maxCacheSize
        self.backoffMultiplier = backoffMultiplier
        self.attemptsByKey = Storage(capacity: maxCacheSize)
        self.metricsCallback = metricsCallback
    }

    /// Checks whether a request should be allowed based on current rate limits and backoff status.
    ///
    /// This is the core method of the rate limiter. It evaluates all configured windows and applies
    /// security-first backoff policies to determine if a request should proceed.
    ///
    /// - Parameters:
    ///   - key: The unique identifier for the rate limit check (e.g., user ID, API key, IP address).
    ///   - timestamp: The timestamp for this check. Defaults to the current time from the dependency system.
    ///                Useful for testing scenarios where time needs to be controlled.
    ///
    /// - Returns: A ``RateLimitResult`` containing the decision and relevant metadata including backoff times,
    ///           remaining attempts, and when the next attempt would be allowed.
    ///
    /// ## Behavior
    ///
    /// The method applies a security-first approach:
    /// 1. **Immediate Backoff**: If there are consecutive failures, applies exponential backoff regardless of rate limits
    /// 2. **Multi-Window Validation**: Checks all configured windows in ascending duration order
    /// 3. **Automatic Cleanup**: Removes expired window data to maintain memory efficiency
    /// 4. **Metrics Integration**: Calls the optional metrics callback with results
    ///
    /// ## Example
    ///
    /// ```swift
    /// let result = await rateLimiter.checkLimit("user123")
    ///
    /// if result.isAllowed {
    ///     // Process the request
    ///     print("Request allowed. Remaining: \(result.remainingAttempts)")
    /// } else {
    ///     // Handle rate limiting
    ///     if let backoff = result.backoffInterval {
    ///         print("Backoff required: \(backoff) seconds")
    ///     }
    ///     print("Try again at: \(result.nextAllowedAttempt)")
    /// }
    /// ```
    ///
    /// - Note: This method is read-only and does not increment attempt counts.
    ///         Call ``recordAttempt(_:)`` after checking but before performing the operation.
    ///         For failed requests, call ``recordFailure(_:)`` to trigger backoff penalties.
    public func checkLimit(
        _ key: Key,
        timestamp: Date = Date()
    ) async -> RateLimitResult {
        await cleanup(before: timestamp)

        let infos = getCurrentWindows(key: key, timestamp: timestamp)

        // Check for consecutive failures with backoff only when rate limit is also exceeded
        if let firstInfo = infos.first,
            firstInfo.consecutiveFailures > 0,
            firstInfo.attempts >= windows[0].maxAttempts
        {
            let backoff = calculateBackoff(consecutiveFailures: firstInfo.consecutiveFailures)
            let nextWindow = firstInfo.windowStart.addingTimeInterval(windows[0].duration)

            let result = RateLimitResult(
                isAllowed: false,
                currentAttempts: firstInfo.attempts,
                remainingAttempts: 0,
                nextAllowedAttempt: nextWindow,
                backoffInterval: backoff
            )

            await metricsCallback?(key, result)
            return result
        }

        // Check each window's limits
        for (windowConfig, info) in zip(windows, infos) {
            if info.attempts >= windowConfig.maxAttempts {
                let nextWindow = info.windowStart.addingTimeInterval(windowConfig.duration)

                let backoff =
                    info.consecutiveFailures > 0
                    ? calculateBackoff(consecutiveFailures: info.consecutiveFailures) : nil

                let result = RateLimitResult(
                    isAllowed: false,
                    currentAttempts: info.attempts,
                    remainingAttempts: 0,
                    nextAllowedAttempt: nextWindow,
                    backoffInterval: backoff
                )

                await metricsCallback?(key, result)

                return result
            }
        }

        let result = RateLimitResult(
            isAllowed: true,
            currentAttempts: infos[0].attempts,
            remainingAttempts: windows[0].maxAttempts - infos[0].attempts,
            nextAllowedAttempt: nil,
            backoffInterval: nil
        )

        await metricsCallback?(key, result)
        return result
    }

    /// Records an actual attempt for the specified key, incrementing the attempt count.
    ///
    /// Call this method AFTER checking the rate limit and BEFORE attempting the operation.
    /// This separates the checking phase from the recording phase, preventing double-counting.
    ///
    /// - Parameter key: The unique identifier for which to record the attempt.
    ///
    /// ## Usage Pattern
    ///
    /// ```swift
    /// // First, check if allowed
    /// let result = await rateLimiter.checkLimit("user123")
    ///
    /// if result.isAllowed {
    ///     // Record that we're making an attempt
    ///     await rateLimiter.recordAttempt("user123")
    ///
    ///     // Now perform the actual operation
    ///     let success = await performOperation()
    ///
    ///     if success {
    ///         await rateLimiter.recordSuccess("user123")
    ///     } else {
    ///         await rateLimiter.recordFailure("user123")
    ///     }
    /// }
    /// ```
    public func recordAttempt(_ key: Key, timestamp: Date = Date()) async {
        await cleanup(before: timestamp)

        var infos = getCurrentWindows(key: key, timestamp: timestamp)
        for i in 0..<infos.count {
            infos[i].attempts += 1
        }
        attemptsByKey.setValue(infos, for: key)
    }

    /// Records a failed operation for the specified key, incrementing consecutive failure count.
    ///
    /// Call this method after a failed authentication, invalid request, or any operation that should
    /// trigger exponential backoff. Each consecutive failure increases the backoff duration exponentially.
    ///
    /// - Parameter key: The unique identifier for which to record the failure.
    ///
    /// ## Usage Pattern
    ///
    /// ```swift
    /// let result = await rateLimiter.checkLimit("user123")
    ///
    /// if result.isAllowed {
    ///     // Attempt the operation
    ///     let success = await performOperation()
    ///
    ///     if success {
    ///         await rateLimiter.recordSuccess("user123")
    ///     } else {
    ///         await rateLimiter.recordFailure("user123") // Triggers backoff
    ///     }
    /// }
    /// ```
    ///
    /// ## Security Impact
    ///
    /// Recording failures enables the security-first backoff system:
    /// - **1st failure**: Backoff = `backoffMultiplier^1 * shortestWindowDuration`
    /// - **2nd failure**: Backoff = `backoffMultiplier^2 * shortestWindowDuration`
    /// - **3rd failure**: Backoff = `backoffMultiplier^3 * shortestWindowDuration`
    /// - And so on...
    ///
    /// - Note: Failures persist across different time windows until explicitly cleared with ``recordSuccess(_:)``
    ///         or ``reset(_:)``.
    public func recordFailure(_ key: Key) async {
        guard var infos = attemptsByKey.cachedValue(for: key) else { return }
        for i in 0..<infos.count {
            infos[i].consecutiveFailures += 1
        }
        attemptsByKey.setValue(infos, for: key)
    }

    /// Records a successful operation for the specified key, resetting consecutive failure count to zero.
    ///
    /// Call this method after a successful authentication, valid request, or any operation that should
    /// clear the exponential backoff penalties. This immediately removes any backoff restrictions.
    ///
    /// - Parameter key: The unique identifier for which to record the success.
    ///
    /// ## Usage Pattern
    ///
    /// ```swift
    /// let result = await rateLimiter.checkLimit("user123")
    ///
    /// if result.isAllowed {
    ///     // Attempt the operation
    ///     let success = await performOperation()
    ///
    ///     if success {
    ///         await rateLimiter.recordSuccess("user123") // Clears backoff
    ///     } else {
    ///         await rateLimiter.recordFailure("user123")
    ///     }
    /// }
    /// ```
    ///
    /// ## Security Impact
    ///
    /// Recording success provides a path to redemption from backoff penalties:
    /// - **Immediate Relief**: Consecutive failure count resets to 0
    /// - **Normal Operation**: Subsequent requests are subject only to standard rate limits
    /// - **Trust Building**: Successful operations demonstrate legitimate usage
    ///
    /// - Note: This only clears consecutive failures, not the attempt counts within time windows.
    ///         Rate limits still apply based on the configured windows.
    public func recordSuccess(_ key: Key) async {
        guard var infos = attemptsByKey.cachedValue(for: key) else { return }
        for i in 0..<infos.count {
            infos[i].consecutiveFailures = 0
        }
        attemptsByKey.setValue(infos, for: key)
    }

    /// Completely resets all rate limiting data for the specified key.
    ///
    /// This method removes all tracking information for a key, including attempt counts across all time windows
    /// and consecutive failure counts. Use this for administrative resets or when a key should start fresh.
    ///
    /// - Parameter key: The unique identifier for which to reset all data.
    ///
    /// ## Usage Pattern
    ///
    /// ```swift
    /// // Administrative reset for a user
    /// await rateLimiter.reset("user123")
    ///
    /// // User can now make requests as if they never used the system
    /// let result = await rateLimiter.checkLimit("user123")
    /// // result.currentAttempts will be 0 for all windows
    /// ```
    ///
    /// ## When to Use
    ///
    /// - **Administrative Actions**: Manually clearing a user's rate limit history
    /// - **Account Recovery**: Resetting limits after resolving account issues
    /// - **Testing**: Clearing state between test scenarios
    /// - **Policy Changes**: Starting fresh after rate limit configuration updates
    /// - **False Positives**: Clearing limits incorrectly applied to legitimate users
    ///
    /// - Warning: This completely removes the key from internal tracking. The next request will be treated
    ///           as if it's the first request ever made by this key.
    public func reset(_ key: Key) async {
        _ = attemptsByKey.removeValue(for: key)
    }

    private func getCurrentWindows(key: Key, timestamp: Date) -> [AttemptInfo] {
        let existing = attemptsByKey.cachedValue(for: key) ?? []
        var result: [AttemptInfo] = []

        for (i, window) in windows.enumerated() {
            let windowStart = getWindowStart(for: timestamp, duration: window.duration)

            if i < existing.count && existing[i].windowStart == windowStart {
                result.append(existing[i])
            } else {
                result.append(
                    AttemptInfo(
                        windowStart: windowStart,
                        attempts: 0,
                        consecutiveFailures: existing.first?.consecutiveFailures ?? 0,
                        timestamp: timestamp
                    )
                )
            }
        }

        return result
    }

    private func getWindowStart(for date: Date, duration: TimeInterval) -> Date {
        let windowSeconds = Int(duration)
        let timestamp = Int(date.timeIntervalSince1970)
        let windowStart = timestamp - (timestamp % windowSeconds)
        return Date(timeIntervalSince1970: Double(windowStart))
    }

    private func calculateBackoff(consecutiveFailures: Int) -> TimeInterval? {
        guard consecutiveFailures > 0 else { return nil }
        return pow(backoffMultiplier, Double(consecutiveFailures)) * windows[0].duration
    }

    private func cleanup(before date: Date) async {
        let oldestAllowedDate =
            windows.map { config in
                date.addingTimeInterval(-config.duration)
            }.min() ?? date

        attemptsByKey.filter { _, infos in
            infos.first?.timestamp ?? date > oldestAllowedDate
        }
    }
}
