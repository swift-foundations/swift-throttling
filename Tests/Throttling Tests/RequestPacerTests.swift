import Foundation
import Testing

@testable import Throttling

@Suite("RequestPacer Tests")
struct RequestPacerTests {

    @Test("Pacing prevents bursts by scheduling requests evenly")
    func testPacingPreventsBursts() async throws {
        let pacer = RequestPacer<String>(targetRate: 25.0)

        var scheduledTimes: [Date] = []

        // Schedule 30 requests simultaneously
        for _ in 1...30 {
            let result = await pacer.scheduleRequest("test")
            #expect(result.isAllowed, "Pacer should always allow requests (no rate limiting)")
            scheduledTimes.append(result.scheduledTime)
        }

        // Check that scheduled times are properly spaced
        let sortedTimes = scheduledTimes.sorted()

        // For 25 req/sec, minimum spacing should be 40ms (1000ms / 25)
        let expectedSpacing = 1.0 / 25.0

        for i in 1..<sortedTimes.count {
            let actualSpacing = sortedTimes[i].timeIntervalSince(sortedTimes[i - 1])
            // Allow small tolerance for floating point precision
            #expect(
                abs(actualSpacing - expectedSpacing) < 0.001,
                "Requests should be spaced \(expectedSpacing)s apart, got \(actualSpacing)"
            )
        }
    }

    @Test("Pacing delay increases for sequential requests")
    func testPacingDelayCalculation() async {
        let pacer = RequestPacer<String>(targetRate: 10.0)

        let fixedTime = Date()

        // First request should have no delay
        let result1 = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        #expect(result1.isAllowed)
        #expect(result1.delay == 0)
        #expect(result1.scheduledTime == fixedTime)

        // Second request at the same time should have a delay (100ms for 10 req/sec)
        let result2 = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        #expect(result2.isAllowed)
        #expect(abs(result2.delay - 0.1) < 0.001, "Delay should be ~0.1s for 10 req/sec")
        #expect(abs(result2.scheduledTime.timeIntervalSince(fixedTime) - 0.1) < 0.001)

        // Third request at the same time should have double the delay
        let result3 = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        #expect(result3.isAllowed)
        #expect(abs(result3.delay - 0.2) < 0.001, "Delay should be ~0.2s for third request")
        #expect(abs(result3.scheduledTime.timeIntervalSince(fixedTime) - 0.2) < 0.001)
    }

    @Test("Pacing with different keys")
    func testPacingWithDifferentKeys() async {
        let pacer = RequestPacer<String>(targetRate: 5.0)

        let fixedTime = Date()

        // First request for user1
        let result1 = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        #expect(result1.scheduledTime == fixedTime)

        // First request for user2 - should have its own independent pacing
        let result2 = await pacer.scheduleRequest("user2", timestamp: fixedTime)
        #expect(result2.scheduledTime == fixedTime, "No delay for first request of different key")
        #expect(result2.delay == 0)

        // Second request for user1 - should be paced
        let result3 = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        #expect(
            abs(result3.scheduledTime.timeIntervalSince(fixedTime) - 0.2) < 0.001,
            "Should be spaced 0.2s (1s / 5 requests)"
        )

        // Second request for user2 - should be independently paced
        let result4 = await pacer.scheduleRequest("user2", timestamp: fixedTime)
        #expect(
            abs(result4.scheduledTime.timeIntervalSince(fixedTime) - 0.2) < 0.001,
            "Should also be spaced 0.2s independently"
        )
    }

    @Test("Pacing works correctly when requests arrive at different times")
    func testPacingWithTimeProgression() async {
        let pacer = RequestPacer<String>(targetRate: 5.0)  // 200ms spacing

        let time1 = Date(timeIntervalSince1970: 1000.0)
        let time2 = Date(timeIntervalSince1970: 1000.15)  // 150ms later
        let time3 = Date(timeIntervalSince1970: 1000.25)  // 250ms later

        // First request at t=0
        let result1 = await pacer.scheduleRequest("user1", timestamp: time1)
        #expect(result1.scheduledTime == time1)
        #expect(result1.delay == 0)

        // Second request at t=150ms - should be scheduled at t=200ms (200ms after first)
        let result2 = await pacer.scheduleRequest("user1", timestamp: time2)
        #expect(
            abs(result2.scheduledTime.timeIntervalSince(time1) - 0.2) < 0.001,
            "Should be scheduled 200ms after first request"
        )
        #expect(
            abs(result2.delay - 0.05) < 0.001,
            "Should wait 50ms (200ms - 150ms)"
        )

        // Third request at t=250ms - should be scheduled at t=400ms (200ms after second)
        let result3 = await pacer.scheduleRequest("user1", timestamp: time3)
        #expect(
            abs(result3.scheduledTime.timeIntervalSince(time1) - 0.4) < 0.001,
            "Should be scheduled 400ms after first request"
        )
        #expect(
            abs(result3.delay - 0.15) < 0.001,
            "Should wait 150ms (400ms - 250ms)"
        )
    }

    @Test("Pacing with rate limiter integration")
    func testPacingWithRateLimiter() async {
        let rateLimiter = RateLimiter<String>(
            windows: [.seconds(1, maxAttempts: 3)]
        )

        let pacer = RequestPacer<String>(
            targetRate: 5.0,
            rateLimiter: rateLimiter
        )

        let fixedTime = Date()

        // First 3 requests should be allowed with pacing
        for i in 1...3 {
            let result = await pacer.scheduleRequest("user1", timestamp: fixedTime)
            #expect(result.isAllowed, "Request \(i) should be allowed")
            #expect(result.rateLimitInfo?.isAllowed == true)
        }

        // 4th request should be blocked by rate limiter
        let result4 = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        #expect(!result4.isAllowed, "Should be blocked by rate limiter")
        #expect(result4.rateLimitInfo?.isAllowed == false)
        #expect(result4.delay == 0, "No pacing delay when rate limited")
    }

    @Test("Reset functionality")
    func testReset() async {
        let pacer = RequestPacer<String>(targetRate: 5.0)

        let fixedTime = Date()

        // Make some requests
        _ = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        let result1 = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        #expect(result1.delay > 0, "Second request should have delay")

        // Reset the key
        await pacer.reset("user1")

        // Next request should have no delay
        let result2 = await pacer.scheduleRequest("user1", timestamp: fixedTime)
        #expect(result2.delay == 0, "Should have no delay after reset")
        #expect(result2.scheduledTime == fixedTime)
    }

    @Test("Request counting")
    func testRequestCounting() async {
        let pacer = RequestPacer<String>(targetRate: 10.0)

        // Initially should be 0
        let count0 = await pacer.getRequestCount("user1")
        #expect(count0 == 0)

        // Make 3 requests
        for _ in 1...3 {
            _ = await pacer.scheduleRequest("user1")
        }

        let count3 = await pacer.getRequestCount("user1")
        #expect(count3 == 3)

        // Different key should have separate count
        let count0Other = await pacer.getRequestCount("user2")
        #expect(count0Other == 0)
    }

    @Test("Allow catch-up mode")
    func testAllowCatchUp() async {
        let pacerStrict = RequestPacer<String>(
            targetRate: 5.0,
            allowCatchUp: false
        )

        let pacerCatchUp = RequestPacer<String>(
            targetRate: 5.0,
            allowCatchUp: true
        )

        let time1 = Date(timeIntervalSince1970: 1000.0)
        let time2 = Date(timeIntervalSince1970: 1001.0)  // 1 second later

        // Make first request
        _ = await pacerStrict.scheduleRequest("user1", timestamp: time1)
        _ = await pacerCatchUp.scheduleRequest("user1", timestamp: time1)

        // Second request much later
        let strictResult = await pacerStrict.scheduleRequest("user1", timestamp: time2)
        let catchUpResult = await pacerCatchUp.scheduleRequest("user1", timestamp: time2)

        // Strict mode should still enforce spacing from last scheduled time
        #expect(
            abs(strictResult.scheduledTime.timeIntervalSince(time1) - 0.2) < 0.001,
            "Strict mode maintains spacing from last scheduled"
        )

        // Catch-up mode should allow immediate execution
        #expect(
            catchUpResult.scheduledTime == time2,
            "Catch-up mode allows immediate execution when behind"
        )
        #expect(catchUpResult.delay == 0)
    }

    @Test("Wait until ready functionality")
    func testWaitUntilReady() async throws {
        let pacer = RequestPacer<String>(targetRate: 20.0)  // 50ms spacing

        let start = Date()

        // Schedule two requests
        let result1 = await pacer.scheduleRequest("user1")
        let result2 = await pacer.scheduleRequest("user1")

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
}
