# Critique: connection-lifecycle-stream-2026-06-30 plan

## Top 3 under-specified seams

1. **Delegate shim peripheral-id resolution for connect/disconnect/fail callbacks** (`BluetoothActor.swift:628` shim, `DelegateEvent` at `:55`, handlers at `:290`).  
   Plan says the three new shim methods will “yield … by peripheral id”. The existing `handlePeripheralDiscovered` resolves `Peripheral.id` via the `name` property of the discovered peripheral (or a fallback). The `didConnect`/`didDisconnectPeripheral`/`didFailToConnect` callbacks receive a `CBPeripheral`, but the plan never states whether the shim will:
   - look the peripheral up in `cbPeripherals` by its object identity or identifier,
   - read `.name` the same way the discovery path does, or
   - guarantee the `CBPeripheral` is already present in `cbPeripherals` before the callback fires.  
   This is the single most load-bearing missing detail; the entire registry update and broadcast path depends on it.

2. **Optimistic `.connecting`/`.disconnecting` broadcast vs. delegate-callback ordering** (`connect(id:)` at `:604`, new `disconnect(id:)`, new handlers).  
   Plan says “optimistically set `.connecting` + broadcast … before calling `central.connect`”. No mention of what happens if the subsequent delegate callback arrives *before* the broadcast continuation has been processed by a subscriber, or if two rapid `connect`/`disconnect` calls interleave. The existing broadcaster has no ordering or serialisation guarantee beyond the actor itself; the plan does not address whether an explicit “pending” state or a small internal queue is required.

3. **Error mapping surface and `PeripheralError` case list** (`Models/PeripheralError.swift`).  
   Plan states a private `CBError → PeripheralError` mapper will be added and that raw `Error` never leaks. It does not list the concrete new cases, nor whether the mapper is exhaustive or falls back to `.unknown`. This directly affects the public `ConnectionState` enum cases that carry `reason: PeripheralError?`.

## Contradictions / missing dependencies

- None. The plan is internally consistent and correctly identifies the prior stream pattern it must copy.

## Risk of over-planning

- **Work Item 5 (mock investigation)** is written as a full investigation task inside the implementation phase. It should be reduced to a one-line note: “use whatever `CBMPeripheralSpec` connection delegate or `simulate*` surface the existing test harness already exercises.” The rest is discovery noise that belongs in the commit message, not the plan.
- **Work Item 7 (DocC)** can be dropped; the GettingStarted example is a one-paragraph addition that does not justify its own work item.

## Questions whose answers change implementation order

- “How exactly will the delegate shim obtain the `Peripheral.id` string from the `CBPeripheral` passed to `didConnect`/`didDisconnect`/`didFailToConnect`?”  
  Answer determines whether the delegate methods can be written first or whether the id-resolution helper must be extracted/refactored before any delegate work begins. If the answer is “the peripheral is already in `cbPeripherals` by the time the callback fires”, the order is safe; otherwise the id-resolution logic must be done *before* the delegate methods are added.

---

*Spot-checked `BluetoothActor.swift:489` (handlePeripheralDiscovered) — confirmed name-based id resolution is the only existing path.*