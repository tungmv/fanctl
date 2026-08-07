import Testing
@testable import FandCore

@Suite struct ControlTests {

    @Test func releaseFtstDecision() {
        // Not held → never release.
        #expect(!ControlLogic.shouldReleaseFtst(held: false, anyDesiredManual: false, anyHardwareManual: false))
        // Held but someone is still manual → keep holding.
        #expect(!ControlLogic.shouldReleaseFtst(held: true, anyDesiredManual: true, anyHardwareManual: false))
        #expect(!ControlLogic.shouldReleaseFtst(held: true, anyDesiredManual: false, anyHardwareManual: true))
        #expect(!ControlLogic.shouldReleaseFtst(held: true, anyDesiredManual: true, anyHardwareManual: true))
        // Held and nobody manual → release.
        #expect(ControlLogic.shouldReleaseFtst(held: true, anyDesiredManual: false, anyHardwareManual: false))
    }

    @Test func resolveIndices() throws {
        #expect(try ControlLogic.resolveIndices(fan: nil, count: 2).get() == [0, 1])
        #expect(try ControlLogic.resolveIndices(fan: 0, count: 2).get() == [0])
        #expect(try ControlLogic.resolveIndices(fan: 1, count: 2).get() == [1])
        #expect(try ControlLogic.resolveIndices(fan: nil, count: 0).get() == [])

        guard case .failure(let e) = ControlLogic.resolveIndices(fan: 5, count: 2) else {
            Issue.record("expected failure for out-of-range index")
            return
        }
        #expect(e.description.contains("no fan with index 5"))

        guard case .failure = ControlLogic.resolveIndices(fan: -1, count: 2) else {
            Issue.record("expected failure for negative index")
            return
        }
    }

    @Test func outcomeSuccess() {
        let o = CommandOutcome()
        o.finish(.success("hello"))
        guard case .success(let msg) = o.wait(timeout: 1) else {
            Issue.record("expected success")
            return
        }
        #expect(msg == "hello")
        // Waiting again is idempotent.
        guard case .success(let msg2) = o.wait(timeout: 1) else {
            Issue.record("expected success on second wait")
            return
        }
        #expect(msg2 == "hello")
    }

    @Test func outcomeFailure() {
        let o = CommandOutcome()
        o.finish(.failure(.smcResult(0x82)))
        guard case .failure(let e) = o.wait(timeout: 1) else {
            Issue.record("expected failure")
            return
        }
        #expect(e.description == "rejected by thermal manager (SMC 0x82)")
    }

    @Test func outcomeTimeout() {
        let o = CommandOutcome()
        #expect(o.wait(timeout: 0.05) == nil)
    }

    @Test func desiredEquatable() {
        #expect(Desired.untouched == Desired.untouched)
        #expect(Desired.auto == Desired.auto)
        #expect(Desired.manual(2000) == Desired.manual(2000))
        #expect(Desired.manual(2000) != Desired.manual(3000))
        #expect(Desired.manual(2000) != Desired.auto)
    }

    // MARK: temps

    @Test func plausibleTemp() {
        #expect(Temps.isPlausible(15))
        #expect(Temps.isPlausible(35.5))
        #expect(Temps.isPlausible(115))
        #expect(!Temps.isPlausible(14.9))
        #expect(!Temps.isPlausible(115.1))
        #expect(!Temps.isPlausible(-40))
    }
}
