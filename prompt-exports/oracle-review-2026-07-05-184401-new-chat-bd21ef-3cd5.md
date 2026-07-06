# Oracle Review



## Summary

The reconnect changes add a `ReconnectPolicy`, a public `.reconnecting(attempt:nextRetryAt:)` connection state, actor-side retry scheduling, and four tests intended to validate unexpected-drop recovery, max-attempt give-up, explicit disconnect suppression, and transient connect-failure retry behavior. The test direction is good, but the described helper and setup have a few race/flakiness risks, especially around `AsyncStream` draining, singleton actor state, and bypassing public configuration plumbing.

## Findings

### P1

- **`Tests/ReliaBLETests/ReliaBLEManagerTests.swift` — `drainConnectionStateChanges` can hang or return the timeout result instead of collected events**

  If the helper uses `withTaskGroup` with one child looping over `manager.connectionStateChanges` and another child sleeping for the timeout, be careful: task groups wait for outstanding children before returning. Since `connectionStateChanges` is an open-ended `AsyncStream`, the collector child may never complete unless explicitly cancelled. A common buggy pattern is:

  ```swift
  let result = await group.next()
  return result
  ```

  If the timeout task wins, this either returns an empty timeout result while discarding already-collected events, or hangs while the group waits for the stream collector.

  **Suggestion:** make the timeout task only signal cancellation, then `cancelAll()` and await the collector’s accumulated events. Use an enum result to distinguish timeout from collected values, and ensure the collector exits on cancellation. Alternatively avoid a task group and use a single collector `Task`, sleep for the timeout, cancel the collector, then await its value.

- **`Tests/ReliaBLETests/ReliaBLEManagerTests.swift` / `Sources/ReliaBLE/ReliaBLEManager.swift` — tests bypass the public config path**

  The tests set reconnect behavior directly through:

  ```swift
  await BluetoothActor.shared.setReconnectPolicy(...)
  ```

  That verifies the actor scheduler, but it does not verify that `ReliaBLEConfig.reconnectPolicy` is actually honored by `ReliaBLEManager`. In the provided diff, `ensureInitialized` accepts a policy, but no `ReliaBLEManager` forwarding change is shown. Because `Mock.makeManager` now defaults to disabled and tests enable reconnect through the actor singleton, the tests could pass while production configuration remains broken.

  **Suggestion:** add at least one test that enables reconnect through `ReliaBLEConfig` passed into `Mock.makeManager` / `ReliaBLEManager`, with no direct actor setter. Also ensure `ReliaBLEManager.init` forwards `config.reconnectPolicy` into `ensureInitialized`.

- **`Tests/ReliaBLETests/ReliaBLEManagerTests.swift` — cleanup by setting `enabled = false` does not cancel existing reconnect tasks**

  The described cleanup sets the policy to disabled and sleeps briefly. But `BluetoothActor.setReconnectPolicy(_:)` only assigns the policy; it does not cancel already-scheduled `reconnectTasks` or clear `reconnectAttempts`. A pending retry can still wake up after the test body and call `connect(id:)`, leaking `.connecting` / `.failed` / `.connected` events into the next serialized test.

  **Suggestion:** either update `setReconnectPolicy` so disabling reconnect cancels and clears pending reconnect state, or add a test-only cleanup path that explicitly cancels reconnect tasks. Sleeping is not a reliable synchronization mechanism here.

- **`Tests/ReliaBLETests/ReliaBLEManagerTests.swift` — event collection must start before triggering state changes**

  `connectionStateChanges` has no replay. Any test that calls `connect`, `disconnect`, or `simulateDisconnection()` before starting `drainConnectionStateChanges` can miss synchronously-broadcast states like `.connecting` or `.disconnecting`.

  **Suggestion:** start the drain task before triggering the action under test, then await the drain result. For current-state assertions, use `currentConnectionStates`; for transition assertions, ensure the stream subscription is already active.

### P2

- **`Tests/ReliaBLETests/ReliaBLEManagerTests.swift` — give-up and transient-failure expectations should account for `.connecting`**

  The actor’s retry path calls `connect(id:)`, which broadcasts `.connecting` before the mock later emits `.failed` or `.connected`. The described give-up sequence:

  ```text
  .failed → .reconnecting(1) → .failed → .reconnecting(2) → .failed
  ```

  omits those `.connecting` transitions.

  **Suggestion:** either include `.connecting` in exact sequence assertions or explicitly filter it out before comparing the failure/reconnect ladder.

- **`Tests/ReliaBLETests/ReliaBLEManagerTests.swift` — avoid exact `Date` comparisons for `.reconnecting`**

  `.reconnecting(attempt:nextRetryAt:)` includes a runtime-generated `Date`. Exact equality is fragile and not meaningful for these tests.

  **Suggestion:** pattern-match the case, assert the attempt number, and optionally assert `nextRetryAt` is within a reasonable window based on the tiny test policy.

- **`Tests/ReliaBLETests/ReliaBLEManagerTests.swift` — reset mock connection result explicitly between tests**

  Since `ConnectionTestDelegate.connectionResult` controls async connect callbacks and tests share a serialized singleton-style mock setup, stale success/failure settings can affect later tests if a delayed callback fires.

  **Suggestion:** set `ConnectionTestDelegate.connectionResult` to a known default in teardown/setup for every reconnect test, not only in the test body.