import Foundation
import Testing

@testable import Throttling

@Suite("RateLimiter Tests")
struct RateLimiterTests {
    @Test(
        "Basic rate limit functionality"
    )
    func testBasicRateLimit() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 2)]
        )

        let result1 = await rateLimiter.checkLimit("user1")
        #expect(result1.isAllowed)
        #expect(result1.currentAttempts == 0)
        #expect(result1.remainingAttempts == 2)
        await rateLimiter.recordAttempt("user1")

        let result2 = await rateLimiter.checkLimit("user1")
        #expect(result2.isAllowed)
        #expect(result2.currentAttempts == 1)
        #expect(result2.remainingAttempts == 1)
        await rateLimiter.recordAttempt("user1")

        let result3 = await rateLimiter.checkLimit("user1")
        #expect(!result3.isAllowed)
        #expect(result3.currentAttempts == 2)
        #expect(result3.remainingAttempts == 0)
        #expect(result3.nextAllowedAttempt != nil)
    }

    @Test("Multiple windows rate limiting")
    func testMultipleWindows() async {
        let rateLimiter = RateLimiter<String>(
            windows: [
                .minutes(1, maxAttempts: 3),
                .hours(1, maxAttempts: 10),
            ]
        )

        // First 3 attempts should be allowed
        for i in 1...3 {
            let result = await rateLimiter.checkLimit("user1")
            #expect(result.isAllowed, "Attempt \(i) should be allowed")
            await rateLimiter.recordAttempt("user1")
        }

        // 4th attempt should be blocked by 1-minute window
        let result4 = await rateLimiter.checkLimit("user1")
        #expect(!result4.isAllowed)
    }

    @Test("Different keys have separate limits")
    func testDifferentKeys() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 1)]
        )

        let result1 = await rateLimiter.checkLimit("user1")
        #expect(result1.isAllowed)
        await rateLimiter.recordAttempt("user1")

        let result2 = await rateLimiter.checkLimit("user2")
        #expect(result2.isAllowed)
        await rateLimiter.recordAttempt("user2")

        // Both users should be at their limit now
        let result3 = await rateLimiter.checkLimit("user1")
        #expect(!result3.isAllowed)

        let result4 = await rateLimiter.checkLimit("user2")
        #expect(!result4.isAllowed)
    }

    @Test("Success and failure tracking with backoff")
    func testSuccessAndFailureTracking() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 3)],
            backoffMultiplier: 2.0
        )

        // Make attempts to reach the limit
        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")
        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")
        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")

        // Record a failure when at limit
        await rateLimiter.recordFailure("user1")

        // Check that backoff is calculated when at limit with failures
        let result = await rateLimiter.checkLimit("user1")
        #expect(!result.isAllowed)
        #expect(result.backoffInterval != nil)

        // Record success to reset consecutive failures
        await rateLimiter.recordSuccess("user1")
    }

    @Test("Reset key functionality")
    func testReset() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 1)]
        )

        // Exhaust the limit
        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")
        let result1 = await rateLimiter.checkLimit("user1")
        #expect(!result1.isAllowed)

        // Reset the key
        await rateLimiter.reset("user1")

        // Should be allowed again
        let result2 = await rateLimiter.checkLimit("user1")
        #expect(result2.isAllowed)
    }

    @Test("Window configuration helpers")
    func testWindowConfigHelpers() {
        let minuteConfig = RateLimiter<String>.WindowConfig.minutes(5, maxAttempts: 10)
        #expect(minuteConfig.duration == 300)  // 5 * 60
        #expect(minuteConfig.maxAttempts == 10)

        let hourConfig = RateLimiter<String>.WindowConfig.hours(2, maxAttempts: 100)
        #expect(hourConfig.duration == 7200)  // 2 * 3600
        #expect(hourConfig.maxAttempts == 100)
    }

    @Test("Metrics callback functionality")
    func testMetricsCallback() async {
        actor ResultsCollector {
            var results: [(String, RateLimiter<String>.RateLimitResult)] = []

            func append(_ key: String, _ result: RateLimiter<String>.RateLimitResult) {
                results.append((key, result))
            }

            func getResults() -> [(String, RateLimiter<String>.RateLimitResult)] {
                results
            }
        }

        let collector = ResultsCollector()

        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 1)],
            metricsCallback: { key, result in
                await collector.append(key, result)
            }
        )

        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")
        _ = await rateLimiter.checkLimit("user1")

        let capturedResults = await collector.getResults()
        #expect(capturedResults.count == 2)
        #expect(capturedResults[0].0 == "user1")
        #expect(capturedResults[0].1.isAllowed)
        #expect(capturedResults[1].0 == "user1")
        #expect(!capturedResults[1].1.isAllowed)
    }

    @Test("Window sorting by duration")
    func testWindowSorting() async {
        // Windows should be automatically sorted by duration
        let rateLimiter = RateLimiter<String>(
            windows: [
                .hours(1, maxAttempts: 100),
                .minutes(1, maxAttempts: 5),
                .minutes(10, maxAttempts: 20),
            ]
        )

        // The 1-minute window (shortest) should be the limiting factor
        for i in 1...5 {
            let result = await rateLimiter.checkLimit("user1")
            #expect(result.isAllowed, "Attempt \(i) should be allowed")
            await rateLimiter.recordAttempt("user1")
        }

        let result6 = await rateLimiter.checkLimit("user1")
        #expect(!result6.isAllowed)
    }

    @Test("Backoff calculation with consecutive failures")
    func testBackoffCalculation() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 1)],
            backoffMultiplier: 3.0
        )

        // Exhaust limit
        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")

        // Record consecutive failures
        await rateLimiter.recordFailure("user1")
        await rateLimiter.recordFailure("user1")

        let result = await rateLimiter.checkLimit("user1")
        #expect(!result.isAllowed)

        // Backoff should be 3^2 * 60 = 540 seconds
        #expect(result.backoffInterval == 540.0)
    }

    @Test("Time-based window boundaries")
    func testTimeBasedWindowBoundaries() async {
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)  // Fixed timestamp for testing

        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 2)]
        )

        // Make attempts at the fixed time
        let result1 = await rateLimiter.checkLimit("user1", timestamp: fixedDate)
        #expect(result1.isAllowed)
        await rateLimiter.recordAttempt("user1", timestamp: fixedDate)

        let result2 = await rateLimiter.checkLimit("user1", timestamp: fixedDate)
        #expect(result2.isAllowed)
        await rateLimiter.recordAttempt("user1", timestamp: fixedDate)

        // Third attempt should be blocked
        let result3 = await rateLimiter.checkLimit("user1", timestamp: fixedDate)
        #expect(!result3.isAllowed)

        // Move to next minute window
        let nextMinute = fixedDate.addingTimeInterval(60)
        let result4 = await rateLimiter.checkLimit("user1", timestamp: nextMinute)
        #expect(result4.isAllowed)
    }

    @Test("Cache capacity and LRU eviction")
    func testCacheCapacityAndEviction() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 1)],
            maxCacheSize: 2  // Very small cache for testing
        )

        // Fill cache with 2 keys
        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")
        _ = await rateLimiter.checkLimit("user2")
        await rateLimiter.recordAttempt("user2")

        // Add third key - should evict least recently used (user1)
        _ = await rateLimiter.checkLimit("user3")
        await rateLimiter.recordAttempt("user3")

        // user1 should be evicted, so should be allowed again
        let result = await rateLimiter.checkLimit("user1")
        #expect(result.isAllowed)
        #expect(result.currentAttempts == 0)  // Fresh start since evicted
    }

    @Test("Backoff reset after success")
    func testBackoffResetAfterSuccess() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 2)]
        )

        // Use up attempts
        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")
        _ = await rateLimiter.checkLimit("user1")
        await rateLimiter.recordAttempt("user1")

        // Record multiple failures
        await rateLimiter.recordFailure("user1")
        await rateLimiter.recordFailure("user1")

        // Should be blocked due to backoff
        let blockedResult = await rateLimiter.checkLimit("user1")
        #expect(!blockedResult.isAllowed)
        #expect(blockedResult.backoffInterval != nil)

        // Record success to reset consecutive failures
        await rateLimiter.recordSuccess("user1")

        // Should still be blocked by rate limit, but no backoff
        let result = await rateLimiter.checkLimit("user1")
        #expect(!result.isAllowed)
        #expect(result.backoffInterval == nil)  // Backoff cleared
    }

    @Test("Concurrent access to same key")
    func testConcurrentAccess() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 5)]
        )

        // With the new read-only checkLimit, concurrent checks all see the same state
        // This test verifies that checkLimit is thread-safe and read-only
        await withTaskGroup(of: Bool.self) { group in
            var allowedCount = 0

            // Launch 10 concurrent checks (without recording)
            for _ in 1...10 {
                group.addTask {
                    let result = await rateLimiter.checkLimit("user1")
                    return result.isAllowed
                }
            }

            // Count how many were allowed
            for await isAllowed in group {
                if isAllowed {
                    allowedCount += 1
                }
            }

            // All should be allowed since checkLimit is read-only
            #expect(allowedCount == 10)
        }

        // Now test sequential recording
        for i in 1...5 {
            let result = await rateLimiter.checkLimit("user1")
            #expect(result.isAllowed, "Attempt \(i) should be allowed")
            await rateLimiter.recordAttempt("user1")
        }

        // 6th attempt should be blocked
        let result = await rateLimiter.checkLimit("user1")
        #expect(!result.isAllowed)
    }

    @Test("Mixed success and failure patterns")
    func testMixedSuccessFailurePatterns() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 5)],
            backoffMultiplier: 2.0
        )

        // Make attempts to reach the limit
        for _ in 1...5 {
            _ = await rateLimiter.checkLimit("user1")
            await rateLimiter.recordAttempt("user1")
        }

        // Failure -> Success -> Failure pattern
        await rateLimiter.recordFailure("user1")
        await rateLimiter.recordSuccess("user1")  // Should reset consecutive failures to 0
        await rateLimiter.recordFailure("user1")  // Now 1 consecutive failure again

        // Should be blocked due to rate limit and have backoff
        let result = await rateLimiter.checkLimit("user1")
        #expect(!result.isAllowed)
        #expect(result.backoffInterval != nil)
        #expect(result.backoffInterval == 120.0)  // 2^1 * 60 = 120 seconds for 1 consecutive failure
    }

    @Test("Different key types")
    func testDifferentKeyTypes() async {
        // Test with UUID keys
        let uuidRateLimiter = RateLimiter<UUID>(
            windows: [.minutes(1, maxAttempts: 1)]
        )

        let userId = UUID()
        let result1 = await uuidRateLimiter.checkLimit(userId)
        #expect(result1.isAllowed)
        await uuidRateLimiter.recordAttempt(userId)

        let result2 = await uuidRateLimiter.checkLimit(userId)
        #expect(!result2.isAllowed)

        // Test with Int keys
        let intRateLimiter = RateLimiter<Int>(
            windows: [.minutes(1, maxAttempts: 1)]
        )

        let result3 = await intRateLimiter.checkLimit(123)
        #expect(result3.isAllowed)
        await intRateLimiter.recordAttempt(123)

        let result4 = await intRateLimiter.checkLimit(123)
        #expect(!result4.isAllowed)
    }

    @Test("Metrics callback error handling")
    func testMetricsCallbackErrorHandling() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 1)],
            metricsCallback: { _, _ in
                // Simulate async callback that might throw
                // Rate limiter should continue to work even if callback has issues
            }
        )

        // Should work normally despite metrics callback
        let result1 = await rateLimiter.checkLimit("user1")
        #expect(result1.isAllowed)
        await rateLimiter.recordAttempt("user1")

        let result2 = await rateLimiter.checkLimit("user1")
        #expect(!result2.isAllowed)
    }

}
