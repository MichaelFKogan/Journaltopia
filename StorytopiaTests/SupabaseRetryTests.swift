import XCTest
import Supabase
@testable import Storytopia

/// Covers `SupabaseRetry`: how many times it tries, which failures earn another attempt, and which
/// ones have to fail straight through to the caller.
///
/// The real backoff adds up to ~6s, so every test that walks the schedule injects a recording sleep
/// instead of waiting. The one exception is `testRealSleepIsCancellable`, which needs the real
/// `Task.sleep` to prove cancellation actually interrupts a backoff in flight.
@MainActor
final class SupabaseRetryTests: XCTestCase {

    // MARK: - Helpers

    private enum StubError: Error, Equatable, TransientCloudFailure {
        case droppedConnection
        case rejectedRow

        var isTransientCloudFailure: Bool {
            self == .droppedConnection
        }
    }

    /// Records what the retry loop asked to wait for instead of actually waiting.
    private final class SleepRecorder {
        private(set) var delays: [Double] = []

        func sleep(_ seconds: Double) async throws {
            delays.append(seconds)
        }
    }

    private func httpError(statusCode: Int) -> HTTPError {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.supabase.co/rest/v1/entries")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return HTTPError(data: Data(), response: response)
    }

    /// Asserts a delay sits inside the ±25% jitter window around its scheduled value.
    private func assertJittered(
        _ delay: Double,
        around base: Double,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(delay, base * 0.75, "delay \(delay) below jitter floor", line: line)
        XCTAssertLessThanOrEqual(delay, base * 1.25, "delay \(delay) above jitter ceiling", line: line)
    }

    // MARK: - Attempt counting

    func testTransientFailureIsRetriedUntilTheAttemptBudgetRunsOut() async {
        let recorder = SleepRecorder()
        var attempts = 0

        do {
            _ = try await SupabaseRetry.withRetry("test", sleep: recorder.sleep) {
                attempts += 1
                throw StubError.droppedConnection
            }
            XCTFail("Expected the exhausted retry to rethrow")
        } catch {
            XCTAssertEqual(error as? StubError, .droppedConnection, "the caller should see the original error")
        }

        XCTAssertEqual(attempts, 4, "one initial attempt plus three retries")
        XCTAssertEqual(attempts, SupabaseRetry.defaultMaxAttempts)
    }

    func testExhaustedRetriesWalkTheWholeBackoffSchedule() async {
        let recorder = SleepRecorder()

        _ = try? await SupabaseRetry.withRetry("test", sleep: recorder.sleep) {
            throw StubError.droppedConnection
        }

        XCTAssertEqual(recorder.delays.count, 3, "three retries means three waits")
        XCTAssertEqual(recorder.delays.count, SupabaseRetry.backoffSeconds.count, "every scheduled delay is used")

        assertJittered(recorder.delays[0], around: 0.5)
        assertJittered(recorder.delays[1], around: 1.5)
        assertJittered(recorder.delays[2], around: 4)
    }

    func testDelaysAreJitteredRatherThanFixed() async {
        var firstDelays: Set<Double> = []

        for _ in 0..<12 {
            let recorder = SleepRecorder()
            _ = try? await SupabaseRetry.withRetry("test", maxAttempts: 2, sleep: recorder.sleep) {
                throw StubError.droppedConnection
            }
            firstDelays.insert(recorder.delays[0])
        }

        XCTAssertGreaterThan(firstDelays.count, 1, "jitter should spread the delay, not repeat one value")
    }

    // MARK: - Success paths

    func testSuccessOnTheFirstAttemptNeverSleeps() async throws {
        let recorder = SleepRecorder()
        var attempts = 0

        let result = try await SupabaseRetry.withRetry("test", sleep: recorder.sleep) { () -> String in
            attempts += 1
            return "saved"
        }

        XCTAssertEqual(result, "saved")
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(recorder.delays.isEmpty, "the happy path must not add latency")
    }

    func testEventualSuccessReturnsTheValueAndStopsRetrying() async throws {
        let recorder = SleepRecorder()
        var attempts = 0

        let result = try await SupabaseRetry.withRetry("test", sleep: recorder.sleep) { () -> String in
            attempts += 1
            if attempts < 3 {
                throw StubError.droppedConnection
            }
            return "saved"
        }

        XCTAssertEqual(result, "saved")
        XCTAssertEqual(attempts, 3, "should stop the moment it succeeds")
        XCTAssertEqual(recorder.delays.count, 2, "only the two failures before success cost a wait")
    }

    // MARK: - Non-transient failures fail immediately

    func testNonTransientFailureIsNotRetried() async {
        let recorder = SleepRecorder()
        var attempts = 0

        do {
            _ = try await SupabaseRetry.withRetry("test", sleep: recorder.sleep) {
                attempts += 1
                throw StubError.rejectedRow
            }
            XCTFail("Expected the rejection to propagate")
        } catch {
            XCTAssertEqual(error as? StubError, .rejectedRow, "the error must reach the caller unchanged")
        }

        XCTAssertEqual(attempts, 1, "a rejected request fails on the first attempt")
        XCTAssertTrue(recorder.delays.isEmpty, "no waiting for an answer that will not change")
    }

    func testAuthAndValidationErrorsAreNotRetried() async {
        let nonRetryable: [Error] = [
            JournalEntryRepositoryError.notAuthenticated,
            JournalEntryRepositoryError.emptyTitleAndContent,
            JournalEntryRepositoryError.operationFailed,
            SupabaseEntryThumbnailError.invalidImage,
            SupabaseReferencePhotoError.invalidImage,
            SupabaseEntryCharacterError.syncFailed,
            StoryJournalRepositoryError.notAuthenticated
        ]

        for error in nonRetryable {
            var attempts = 0
            let recorder = SleepRecorder()

            _ = try? await SupabaseRetry.withRetry("test", sleep: recorder.sleep) {
                attempts += 1
                throw error
            }

            XCTAssertEqual(attempts, 1, "\(error) must fail immediately")
            XCTAssertFalse(SupabaseRetry.isTransient(error), "\(error) must not classify as transient")
        }
    }

    func test4xxIsNotRetried() async {
        for statusCode in [400, 401, 403, 404, 409, 422, 429] {
            var attempts = 0
            let recorder = SleepRecorder()
            let error = httpError(statusCode: statusCode)

            _ = try? await SupabaseRetry.withRetry("test", sleep: recorder.sleep) {
                attempts += 1
                throw error
            }

            XCTAssertEqual(attempts, 1, "HTTP \(statusCode) must fail on the first attempt")
            XCTAssertFalse(SupabaseRetry.isTransient(error), "HTTP \(statusCode) must not classify as transient")
        }
    }

    // MARK: - Transient failures are retried

    func test5xxIsRetried() async {
        for statusCode in [500, 502, 503, 504] {
            var attempts = 0
            let recorder = SleepRecorder()
            let error = httpError(statusCode: statusCode)

            _ = try? await SupabaseRetry.withRetry("test", sleep: recorder.sleep) {
                attempts += 1
                throw error
            }

            XCTAssertEqual(attempts, 4, "HTTP \(statusCode) should use the full attempt budget")
            XCTAssertTrue(SupabaseRetry.isTransient(error), "HTTP \(statusCode) must classify as transient")
        }
    }

    func testStorageErrorIsClassifiedByStatusCode() {
        XCTAssertTrue(SupabaseRetry.isTransient(StorageError(statusCode: "503", message: "unavailable")))
        XCTAssertTrue(SupabaseRetry.isTransient(StorageError(statusCode: "500", message: "internal")))
        XCTAssertFalse(SupabaseRetry.isTransient(StorageError(statusCode: "404", message: "not found")))
        XCTAssertFalse(SupabaseRetry.isTransient(StorageError(statusCode: "403", message: "denied")))
        XCTAssertFalse(SupabaseRetry.isTransient(StorageError(statusCode: nil, message: "unknown")))
    }

    func testNetworkURLErrorsAreRetried() async {
        let transientCodes: [URLError.Code] = [
            .timedOut,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet
        ]

        for code in transientCodes {
            var attempts = 0
            let recorder = SleepRecorder()
            let error = URLError(code)

            _ = try? await SupabaseRetry.withRetry("test", sleep: recorder.sleep) {
                attempts += 1
                throw error
            }

            XCTAssertEqual(attempts, 4, "URLError \(code) should be retried")
            XCTAssertTrue(SupabaseRetry.isTransient(error), "URLError \(code) must classify as transient")
        }
    }

    func testNonNetworkURLErrorsAreNotRetried() {
        let permanentCodes: [URLError.Code] = [
            .badURL,
            .unsupportedURL,
            .userAuthenticationRequired,
            .noPermissionsToReadFile,
            .serverCertificateUntrusted
        ]

        for code in permanentCodes {
            XCTAssertFalse(SupabaseRetry.isTransient(URLError(code)), "URLError \(code) must not be retried")
        }
    }

    func testPostgrestConnectionFailuresAreRetriedButRejectionsAreNot() {
        let connectionFailures = [
            PostgrestError(code: "08006", message: "connection failure"),
            PostgrestError(code: "08003", message: "connection does not exist"),
            PostgrestError(code: "53300", message: "too many connections"),
            PostgrestError(code: "57P01", message: "terminating connection due to administrator command"),
            PostgrestError(code: "40001", message: "could not serialize access"),
            PostgrestError(code: "57014", message: "canceling statement due to statement timeout"),
            PostgrestError(code: "PGRST001", message: "could not connect to the database")
        ]

        for error in connectionFailures {
            XCTAssertTrue(
                SupabaseRetry.isTransient(error),
                "SQLSTATE \(error.code ?? "?") should be retried"
            )
        }

        let rejections = [
            PostgrestError(code: "42501", message: "new row violates row-level security policy"),
            PostgrestError(code: "23505", message: "duplicate key value violates unique constraint"),
            PostgrestError(code: "23503", message: "violates foreign key constraint"),
            PostgrestError(code: "22P02", message: "invalid input syntax for type uuid"),
            PostgrestError(code: "PGRST116", message: "results contain 0 rows")
        ]

        for error in rejections {
            XCTAssertFalse(
                SupabaseRetry.isTransient(error),
                "SQLSTATE \(error.code ?? "?") must fail immediately"
            )
        }
    }

    // MARK: - Cancellation

    func testCancellationErrorIsNeverTreatedAsTransient() {
        XCTAssertFalse(SupabaseRetry.isTransient(CancellationError()))
    }

    func testCancellationDuringBackoffStopsRetrying() async {
        var attempts = 0

        do {
            _ = try await SupabaseRetry.withRetry(
                "test",
                sleep: { _ in throw CancellationError() }
            ) {
                attempts += 1
                throw StubError.droppedConnection
            }
            XCTFail("Expected cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError, "cancellation must surface, not be swallowed as a retry")
        }

        XCTAssertEqual(attempts, 1, "a cancelled backoff must not start another attempt")
    }

    func testCancellingTheSurroundingTaskInterruptsARealBackoff() async {
        // Uses the real Task.sleep so this exercises the shipped backoff, not the injected one.
        let attempts = Counter()

        let task = Task { @MainActor in
            try await SupabaseRetry.withRetry("test") {
                await attempts.increment()
                throw StubError.droppedConnection
            }
        }

        // Let the first attempt fail and the task settle into its ~0.5s backoff, then cancel.
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("Expected the cancelled retry to throw")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }

        let finalCount = await attempts.value
        XCTAssertEqual(finalCount, 1, "cancellation should land during the first backoff, before attempt 2")
    }

    private actor Counter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    // MARK: - Schedule invariants

    func testAttemptBudgetAndBackoffScheduleCannotDrift() {
        XCTAssertEqual(
            SupabaseRetry.defaultMaxAttempts,
            SupabaseRetry.backoffSeconds.count + 1,
            "every retry needs exactly one scheduled delay behind it"
        )
        XCTAssertEqual(SupabaseRetry.backoffSeconds, [0.5, 1.5, 4])
    }

    func testCustomAttemptBudgetIsHonoured() async {
        for budget in 1...4 {
            var attempts = 0
            let recorder = SleepRecorder()

            _ = try? await SupabaseRetry.withRetry("test", maxAttempts: budget, sleep: recorder.sleep) {
                attempts += 1
                throw StubError.droppedConnection
            }

            XCTAssertEqual(attempts, budget)
            XCTAssertEqual(recorder.delays.count, budget - 1)
        }
    }
}
