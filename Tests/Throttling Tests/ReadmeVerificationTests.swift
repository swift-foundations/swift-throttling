//
//  ReadmeVerificationTests.swift
//  swift-throttling
//
//  Tests that verify all README code examples compile and work correctly.
//

import Foundation
import Testing

@testable import Throttling

@Suite("README Verification")
struct ReadmeVerificationTests {

    @Test("Quick Start - Basic Rate Limiting (lines 36-56)")
    func quickStartBasicRateLimiting() async {
        // Create a rate limiter: 5 attempts per minute, 100 per hour
        let rateLimiter = RateLimiter<String>(
            windows: [
                .minutes(1, maxAttempts: 5),
                .hours(1, maxAttempts: 100),
            ]
        )

        // Check rate limit
        let result = await rateLimiter.checkLimit("user123")
        if result.isAllowed {
            await rateLimiter.recordAttempt("user123")
            // Process request
        } else {
            // Rate limited
            print("Retry after: \(String(describing: result.nextAllowedAttempt))")
        }

        #expect(result.isAllowed)
    }

    @Test("Quick Start - Request Pacing (lines 60-72)")
    func quickStartRequestPacing() async {
        // Create a pacer for 10 requests per second
        let pacer = RequestPacer<String>(targetRate: 10.0)

        // Schedule a request
        let result = await pacer.scheduleRequest("api-client")
        if result.delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(result.delay * 1_000_000_000))
        }
        // Make request

        #expect(result.isAllowed)
    }

    @Test("Quick Start - Combined Throttling (lines 76-97)")
    func quickStartCombinedThrottling() async {
        // Combine rate limiting and pacing
        let client = ThrottledClient<String>(
            windows: [.seconds(1, maxAttempts: 10)],
            targetRate: 5.0
        )

        let result = await client.acquire("user123")
        if result.canProceed {
            try? await result.waitUntilReady()
            // Make request

            // Record outcome
            let success = true
            if success {
                await client.recordSuccess("user123")
            } else {
                await client.recordFailure("user123")
            }
        }

        #expect(result.canProceed)
    }

    @Test("Usage - Multiple Time Windows (lines 105-113)")
    func usageMultipleTimeWindows() async {
        let apiLimiter = RateLimiter<String>(
            windows: [
                .minutes(1, maxAttempts: 60),  // Burst protection
                .hours(1, maxAttempts: 1000),  // Hourly limit
                .hours(24, maxAttempts: 10000),  // Daily limit
            ]
        )

        let result = await apiLimiter.checkLimit("test-key")
        #expect(result.isAllowed)
    }

    @Test("Usage - Exponential Backoff (lines 121-131)")
    func usageExponentialBackoff() async {
        let limiter = RateLimiter<String>(
            windows: [.minutes(15, maxAttempts: 3)],
            backoffMultiplier: 2.0
        )

        // After consecutive failures:
        // 1st failure: 30 minute backoff (2^1 * 15 min)
        // 2nd failure: 60 minute backoff (2^2 * 15 min)
        // 3rd failure: 120 minute backoff (2^3 * 15 min)

        let result = await limiter.checkLimit("test-key")
        #expect(result.isAllowed)
    }

    @Test("Usage - Metrics Collection (lines 137-144)")
    func usageMetricsCollection() async {
        let limiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 10)],
            metricsCallback: { key, result in
                print("Key: \(key), Allowed: \(result.isAllowed)")
            }
        )

        let result = await limiter.checkLimit("test-key")
        #expect(result.isAllowed)
    }

    @Test("Usage - Custom Key Types (lines 148-160)")
    func usageCustomKeyTypes() async {
        struct UserContext: Hashable, Sendable {
            let userId: String
            let endpoint: String
        }

        let limiter = RateLimiter<UserContext>(
            windows: [.minutes(1, maxAttempts: 10)]
        )

        let context = UserContext(userId: "123", endpoint: "/api/data")
        let result = await limiter.checkLimit(context)

        #expect(result.isAllowed)
    }

    @Test("API Reference - WindowConfig")
    func apiReferenceWindowConfig() {
        let seconds = RateLimiter<String>.WindowConfig.seconds(30, maxAttempts: 5)
        let minutes = RateLimiter<String>.WindowConfig.minutes(1, maxAttempts: 10)
        let hours = RateLimiter<String>.WindowConfig.hours(1, maxAttempts: 100)
        let custom = RateLimiter<String>.WindowConfig(duration: 45, maxAttempts: 3)

        #expect(seconds.duration == 30)
        #expect(minutes.duration == 60)
        #expect(hours.duration == 3600)
        #expect(custom.duration == 45)
    }

    @Test("API Reference - RateLimiter Init")
    func apiReferenceRateLimiterInit() async {
        let limiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 10)],
            maxCacheSize: 10000,
            backoffMultiplier: 2.0,
            metricsCallback: { _, _ in
                // Optional callback
            }
        )

        let result = await limiter.checkLimit("test")
        #expect(result.isAllowed)
    }

    @Test("API Reference - RateLimiter Methods")
    func apiReferenceRateLimiterMethods() async {
        let limiter = RateLimiter<String>(
            windows: [.minutes(1, maxAttempts: 3)]
        )

        let key = "test-key"

        // Check limit
        let result = await limiter.checkLimit(key)
        #expect(result.isAllowed)

        // Record attempt
        await limiter.recordAttempt(key)

        // Record success
        await limiter.recordSuccess(key)

        // Record failure
        await limiter.recordFailure(key)

        // Reset
        await limiter.reset(key)
    }

    @Test("API Reference - RequestPacer Init")
    func apiReferenceRequestPacerInit() async {
        let pacer = RequestPacer<String>(
            targetRate: 10.0,
            rateLimiter: nil,
            allowCatchUp: false
        )

        let result = await pacer.scheduleRequest("test")
        #expect(result.isAllowed)
    }

    @Test("API Reference - RequestPacer Methods")
    func apiReferenceRequestPacerMethods() async {
        let pacer = RequestPacer<String>(targetRate: 10.0)

        let result = await pacer.scheduleRequest("test-key")
        #expect(result.isAllowed)

        await pacer.reset("test-key")
    }

    @Test("API Reference - ThrottledClient Init")
    func apiReferenceThrottledClientInit() async {
        // First constructor
        let client1 = ThrottledClient<String>(
            rateLimiter: RateLimiter(windows: [.minutes(1, maxAttempts: 10)]),
            pacer: RequestPacer(targetRate: 10.0)
        )

        let result1 = await client1.acquire("test")
        #expect(result1.canProceed)

        // Second constructor
        let client2 = ThrottledClient<String>(
            windows: [.minutes(1, maxAttempts: 10)],
            targetRate: 10.0,
            backoffMultiplier: 2.0
        )

        let result2 = await client2.acquire("test")
        #expect(result2.canProceed)
    }

    @Test("API Reference - ThrottledClient Methods")
    func apiReferenceThrottledClientMethods() async {
        let client = ThrottledClient<String>(
            windows: [.minutes(1, maxAttempts: 10)],
            targetRate: 10.0
        )

        let key = "test-key"

        // Acquire
        let result = await client.acquire(key)
        #expect(result.canProceed)

        // Record success
        await client.recordSuccess(key)

        // Record failure
        await client.recordFailure(key)

        // Reset
        await client.reset(key)
    }
}
