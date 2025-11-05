import Foundation
import Testing

@testable import Throttling

@Test("Verify checkLimit is read-only and recordAttempt increments")
func testCheckLimitReadOnlyAndRecordAttempt() async {
    let limiter = RateLimiter<String>(
        windows: [.seconds(10, maxAttempts: 3)]
    )

    // Multiple checkLimit calls should not increment
    let check1 = await limiter.checkLimit("test")
    let check2 = await limiter.checkLimit("test")
    let check3 = await limiter.checkLimit("test")

    #expect(check1.currentAttempts == 0)
    #expect(check2.currentAttempts == 0)
    #expect(check3.currentAttempts == 0)
    #expect(check1.isAllowed == true)
    #expect(check2.isAllowed == true)
    #expect(check3.isAllowed == true)

    // Now record an actual attempt
    await limiter.recordAttempt("test")

    // Check should now show 1 attempt
    let check4 = await limiter.checkLimit("test")
    #expect(check4.currentAttempts == 1)
    #expect(check4.remainingAttempts == 2)
    #expect(check4.isAllowed == true)

    // Record two more attempts to reach limit
    await limiter.recordAttempt("test")
    await limiter.recordAttempt("test")

    // Should now be at limit
    let check5 = await limiter.checkLimit("test")
    #expect(check5.currentAttempts == 3)
    #expect(check5.remainingAttempts == 0)
    #expect(check5.isAllowed == false)  // Exceeded limit
}

@Test("Verify proper usage pattern prevents double-counting")
func testProperUsagePatternNoDoubleCounting() async {
    let limiter = RateLimiter<String>(
        windows: [.seconds(10, maxAttempts: 5)]
    )

    // Simulate the correct usage pattern
    for i in 1...3 {
        // Check if allowed
        let checkResult = await limiter.checkLimit("user")
        #expect(checkResult.isAllowed == true)
        #expect(checkResult.currentAttempts == i - 1)

        // Record the attempt
        await limiter.recordAttempt("user")

        // Verify the count incremented
        let verifyResult = await limiter.checkLimit("user")
        #expect(verifyResult.currentAttempts == i)
    }

    // After 3 attempts, should still have 2 remaining
    let finalCheck = await limiter.checkLimit("user")
    #expect(finalCheck.currentAttempts == 3)
    #expect(finalCheck.remainingAttempts == 2)
    #expect(finalCheck.isAllowed == true)
}

@Test("Verify failure tracking still works with new pattern")
func testFailureTrackingWithNewPattern() async {
    let limiter = RateLimiter<String>(
        windows: [.seconds(10, maxAttempts: 5)]
    )

    // First attempt - success
    var check = await limiter.checkLimit("user")
    #expect(check.isAllowed == true)
    await limiter.recordAttempt("user")
    await limiter.recordSuccess("user")

    // Second attempt - failure
    check = await limiter.checkLimit("user")
    #expect(check.isAllowed == true)
    #expect(check.currentAttempts == 1)
    await limiter.recordAttempt("user")
    await limiter.recordFailure("user")

    // Third attempt - should be blocked due to consecutive failure
    check = await limiter.checkLimit("user")
    #expect(check.isAllowed == false)  // Blocked by backoff
    #expect(check.backoffInterval != nil)
    #expect(check.currentAttempts == 2)
}
