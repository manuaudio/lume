import Testing
import Foundation
@testable import LumeKit

@Suite struct DetachedValueTests {

    @Test func returnsValueWhenNotCancelled() async {
        let v = await detachedValue { 42 }
        #expect(v == 42)
    }

    @Test func defaultsAndPriorityBothDeliver() async {
        let a = await detachedValue(priority: .utility) { "x" }
        #expect(a == "x")
    }

    @Test func returnsNilWhenSurroundingTaskIsCancelled() async {
        // The detached work does NOT inherit cancellation (it's detached), so it
        // completes — but the surrounding task was cancelled, so the helper must
        // discard the value and return nil.
        let task = Task { () -> Int? in
            await detachedValue { () async -> Int in
                // Park long enough for the cancel below to land with margin.
                try? await Task.sleep(for: .milliseconds(200))
                return 42
            }
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }
}
