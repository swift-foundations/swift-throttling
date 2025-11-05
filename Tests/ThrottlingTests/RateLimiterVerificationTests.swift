import Foundation
import Testing

@testable import Throttling

@Test("RateLimiter checkLimit should be read-only and not increment attempts")
func testCheckLimitIsReadOnly() async {
    let limiter = RateLimiter<String>(
        windows: [.seconds(10, maxAttempts: 3)]
    )

    // First check - should be allowed with 0 attempts
    let result1 = await limiter.checkLimit("test")
    #expect(result1.isAllowed == true)
    #expect(result1.currentAttempts == 0)
    #expect(result1.remainingAttempts == 3)

    // Second check - should still show 0 attempts (no auto-increment)
    let result2 = await limiter.checkLimit("test")
    #expect(result2.isAllowed == true)
    #expect(result2.currentAttempts == 0)
    #expect(result2.remainingAttempts == 3)

    // Third check - still 0 attempts
    let result3 = await limiter.checkLimit("test")
    #expect(result3.isAllowed == true)
    #expect(result3.currentAttempts == 0)
    #expect(result3.remainingAttempts == 3)
}

@Test("RateLimiter recordAttempt should increment counter")
func testRecordAttemptIncrementsCounter() async {
    let limiter = RateLimiter<String>(
        windows: [.seconds(10, maxAttempts: 3)]
    )

    // Check initial state
    let result1 = await limiter.checkLimit("test")
    #expect(result1.currentAttempts == 0)

    // Record an attempt
    await limiter.recordAttempt("test")

    // Check should now show 1 attempt
    let result2 = await limiter.checkLimit("test")
    #expect(result2.isAllowed == true)
    #expect(result2.currentAttempts == 1)
    #expect(result2.remainingAttempts == 2)

    // Record another attempt
    await limiter.recordAttempt("test")

    // Check should now show 2 attempts
    let result3 = await limiter.checkLimit("test")
    #expect(result3.isAllowed == true)
    #expect(result3.currentAttempts == 2)
    #expect(result3.remainingAttempts == 1)
}

@Test("RateLimiter proper usage pattern prevents double-counting")
func testProperUsagePattern() async {
    let limiter = RateLimiter<String>(
        windows: [.seconds(10, maxAttempts: 3)]
    )

    // Simulate proper usage pattern
    // Attempt 1: Success
    var result = await limiter.checkLimit("user123")
    #expect(result.isAllowed == true)
    #expect(result.currentAttempts == 0)

    await limiter.recordAttempt("user123")
    await limiter.recordSuccess("user123")

    // Attempt 2: Failure
    result = await limiter.checkLimit("user123")
    #expect(result.isAllowed == true)
    #expect(result.currentAttempts == 1)

    await limiter.recordAttempt("user123")
    await limiter.recordFailure("user123")

    // Attempt 3: Check should show backoff due to failure
    result = await limiter.checkLimit("user123")
    #expect(result.isAllowed == false)  // Due to consecutive failure
    #expect(result.currentAttempts == 2)
    #expect(result.backoffInterval != nil)
}

@Test("RateLimiter rate limit enforcement works correctly")
func testRateLimitEnforcement() async {
    let limiter = RateLimiter<String>(
        windows: [.seconds(10, maxAttempts: 2)]
    )

    // First attempt
    var result = await limiter.checkLimit("test")
    #expect(result.isAllowed == true)
    await limiter.recordAttempt("test")

    // Second attempt
    result = await limiter.checkLimit("test")
    #expect(result.isAllowed == true)
    await limiter.recordAttempt("test")

    // Third attempt - should be blocked (exceeded limit)
    result = await limiter.checkLimit("test")
    #expect(result.isAllowed == false)
    #expect(result.currentAttempts == 2)
    #expect(result.remainingAttempts == 0)
}
