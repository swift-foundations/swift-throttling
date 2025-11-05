import Foundation
import Testing

@testable import Throttling

@Suite("ThrottledClient Integration Tests")
struct ThrottledClientTests {

    @Test("ThrottledClient with both rate limiting and pacing")
    func testCombinedFunctionality() async {
        let client = ThrottledClient<String>(
            windows: [.seconds(1, maxAttempts: 5)],
            targetRate: 5.0
        )

        let fixedTime = Date()

        // First 5 requests should be allowed with proper pacing
        var results: [ThrottledClient<String>.AcquisitionResult] = []
        for _ in 1...6 {
            let result = await client.acquire("user1", timestamp: fixedTime)
            results.append(result)
        }

        // First 5 should proceed with pacing
        for i in 0..<5 {
            #expect(results[i].canProceed, "Request \(i+1) should be allowed")
            if i > 0 {
                #expect(results[i].delay > 0, "Should have pacing delay")
            }
        }

        // 6th request should be rate limited
        #expect(!results[5].canProceed, "6th request should be rate limited")
        #expect(results[5].retryAfter != nil, "Should have retry information")
    }

    @Test("ThrottledClient with rate limiting only")
    func testRateLimitingOnly() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.seconds(1, maxAttempts: 3)]
        )

        let client = ThrottledClient<String>(
            rateLimiter: rateLimiter,
            pacer: nil
        )

        let fixedTime = Date()

        // Should allow 3 requests without pacing
        for i in 1...3 {
            let result = await client.acquire("user1", timestamp: fixedTime)
            #expect(result.canProceed, "Request \(i) should be allowed")
            #expect(result.delay == 0, "No pacing delay without pacer")
        }

        // 4th should be blocked
        let result4 = await client.acquire("user1", timestamp: fixedTime)
        #expect(!result4.canProceed, "4th request should be blocked")
    }

    @Test("ThrottledClient with pacing only")
    func testPacingOnly() async {
        let pacer = RequestPacer<String>(targetRate: 10.0)

        let client = ThrottledClient<String>(
            rateLimiter: nil,
            pacer: pacer
        )

        let fixedTime = Date()

        // All requests should be allowed with pacing
        for i in 1...20 {
            let result = await client.acquire("user1", timestamp: fixedTime)
            #expect(result.canProceed, "Request \(i) should be allowed (no rate limiting)")

            if i > 1 {
                #expect(result.delay > 0, "Should have pacing delay after first request")
                #expect(
                    abs(result.delay - (Double(i - 1) * 0.1)) < 0.001,
                    "Delay should be ~\(Double(i-1) * 0.1)s"
                )
            }
        }
    }

    @Test("Success and failure recording")
    func testSuccessFailureRecording() async {
        let client = ThrottledClient<String>(
            windows: [.seconds(1, maxAttempts: 5)],
            targetRate: 5.0,
            backoffMultiplier: 2.0
        )

        let fixedTime = Date()

        // Make requests to reach the limit
        for _ in 1...5 {
            let result = await client.acquire("user1", timestamp: fixedTime)
            #expect(result.canProceed)
        }

        // Record failure when at limit
        await client.recordFailure("user1")

        // Next request should be blocked due to rate limit and backoff
        let result2 = await client.acquire("user1", timestamp: fixedTime)
        #expect(!result2.canProceed, "Should be blocked by rate limit and backoff")
        #expect(result2.retryAfter != nil)

        // Record success to clear backoff
        await client.recordSuccess("user1")

        // Should still be blocked by rate limit (5 of 5 attempts used) but no backoff
        let result3 = await client.acquire("user1", timestamp: fixedTime.addingTimeInterval(0.1))
        #expect(!result3.canProceed, "Should still be blocked by rate limit")
        #expect(result3.rateLimitResult?.backoffInterval == nil, "Backoff should be cleared")
    }

    @Test("Reset functionality")
    func testReset() async {
        let client = ThrottledClient<String>(
            windows: [.seconds(1, maxAttempts: 2)],
            targetRate: 10.0
        )

        let fixedTime = Date()

        // Exhaust rate limit
        _ = await client.acquire("user1", timestamp: fixedTime)
        _ = await client.acquire("user1", timestamp: fixedTime)

        let blocked = await client.acquire("user1", timestamp: fixedTime)
        #expect(!blocked.canProceed, "Should be rate limited")

        // Reset
        await client.reset("user1")

        // Should be allowed again
        let result = await client.acquire("user1", timestamp: fixedTime)
        #expect(result.canProceed, "Should be allowed after reset")
        #expect(result.delay == 0, "Should have no delay after reset")
    }

    @Test("Wait until ready integration")
    func testWaitUntilReady() async throws {
        let client = ThrottledClient<String>(
            windows: [.seconds(1, maxAttempts: 10)],
            targetRate: 20.0  // 50ms spacing
        )

        let start = Date()

        // Schedule two requests
        let result1 = await client.acquire("user1")
        let result2 = await client.acquire("user1")

        #expect(result1.canProceed)
        #expect(result2.canProceed)

        // First should be immediate
        try await result1.waitUntilReady()
        let elapsed1 = Date().timeIntervalSince(start)
        #expect(elapsed1 < 0.01, "First request should be immediate")

        // Second should wait ~50ms (with tolerance for CI runners)
        try await result2.waitUntilReady()
        let elapsed2 = Date().timeIntervalSince(start)
        #expect(
            elapsed2 >= 0.04 && elapsed2 < 0.2,
            "Second request should wait ~50ms, got \(elapsed2)"
        )
    }

    @Test("Multiple keys with ThrottledClient")
    func testMultipleKeys() async {
        let client = ThrottledClient<String>(
            windows: [.seconds(1, maxAttempts: 2)],
            targetRate: 5.0
        )

        let fixedTime = Date()

        // Different keys should have independent limits and pacing
        let user1Result1 = await client.acquire("user1", timestamp: fixedTime)
        let user2Result1 = await client.acquire("user2", timestamp: fixedTime)

        #expect(user1Result1.canProceed)
        #expect(user1Result1.delay == 0, "First request for user1 should have no delay")

        #expect(user2Result1.canProceed)
        #expect(user2Result1.delay == 0, "First request for user2 should have no delay")

        // Second requests should be paced
        let user1Result2 = await client.acquire("user1", timestamp: fixedTime)
        let user2Result2 = await client.acquire("user2", timestamp: fixedTime)

        #expect(user1Result2.canProceed)
        #expect(abs(user1Result2.delay - 0.2) < 0.001, "Should have 0.2s delay")

        #expect(user2Result2.canProceed)
        #expect(abs(user2Result2.delay - 0.2) < 0.001, "Should have 0.2s delay")

        // Third request for user1 should be rate limited
        let user1Result3 = await client.acquire("user1", timestamp: fixedTime)
        #expect(!user1Result3.canProceed, "Should be rate limited after 2 requests")

        // User2 can still make one more request
        let user2Result3 = await client.acquire("user2", timestamp: fixedTime)
        #expect(!user2Result3.canProceed, "User2 should also be rate limited after 2 requests")
    }

    @Test("Retry after calculation")
    func testRetryAfterCalculation() async {
        let client = ThrottledClient<String>(
            windows: [.seconds(2, maxAttempts: 1)],
            targetRate: 10.0,
            backoffMultiplier: 3.0
        )

        let fixedTime = Date(timeIntervalSince1970: 1000.0)

        // First request allowed
        _ = await client.acquire("user1", timestamp: fixedTime)

        // Second request blocked by rate limit
        let blocked1 = await client.acquire("user1", timestamp: fixedTime)
        #expect(!blocked1.canProceed)
        #expect(blocked1.retryAfter != nil)
        // Should retry after window expires (2 seconds)
        #expect(abs(blocked1.retryAfter! - 2.0) < 0.1)

        // Record a failure for backoff
        await client.recordFailure("user1")

        // Now check retry after with backoff
        let blocked2 = await client.acquire("user1", timestamp: fixedTime)
        #expect(!blocked2.canProceed)
        #expect(blocked2.retryAfter != nil)
        // Should have backoff applied (3^1 * 2 = 6 seconds)
        #expect(abs(blocked2.retryAfter! - 6.0) < 0.1)
    }
}
