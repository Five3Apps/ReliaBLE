//
//  ReliaBLEManagerTests.swift
//  ReliaBLETests
//
//  Created by Justin Bergen on 11/18/24.
//
//  Copyright (c) 2024 Five3 Apps, LLC <justin@five3apps.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Testing
@testable import ReliaBLEMock

@Test func reliaBLEManagerIsSendable() async throws {
    let manager = ReliaBLEManager()

    // Capturing the manager in a `Task.detached` closure and exercising every public member is a
    // compile-time proof that `ReliaBLEManager` is `Sendable` — the closure crosses an isolation
    // boundary. The calls run against the mock with no central manager, so they safely no-op or
    // throw, which is irrelevant: this test asserts compilation, not behavior.
    await Task.detached {
        _ = manager.loggingService
        _ = await manager.currentState
        _ = manager.state
        _ = manager.peripheralDiscoveries
        _ = manager.discoveredPeripherals
        try? await manager.authorizeBluetooth()
        await manager.startScanning()
        await manager.startScanning(services: [])
        await manager.stopScanning()
        try? await manager.connect(to: Peripheral(id: "unused"))
    }.value
}

@Test func peripheralIsSendable() async throws {
    let peripheral = Peripheral(id: "sendable-id")

    // Capturing the value in a `Task.detached` closure is a compile-time proof that
    // `Peripheral` is `Sendable` — the closure crosses an isolation boundary.
    let capturedId = await Task.detached { peripheral.id }.value

    #expect(capturedId == "sendable-id")
}

@Test func connectToUnknownPeripheralThrowsNotFound() async throws {
    let manager = ReliaBLEManager()
    let staleSnapshot = Peripheral(id: "never-discovered")

    do {
        try await manager.connect(to: staleSnapshot)
        #expect(false, "Expected PeripheralError.notFound")
    } catch PeripheralError.notFound {
        // expected
    } catch {
        #expect(false, "Expected PeripheralError.notFound, got \(error)")
    }
}

// MARK: - Event Stream Broadcaster

@Test func stateStreamReplaysToConcurrentSubscribers() async throws {
    let manager = ReliaBLEManager()

    // Two independent streams from two separate property accesses.
    var subscriberA = manager.state.makeAsyncIterator()
    var subscriberB = manager.state.makeAsyncIterator()

    // Each subscriber replays the current state as its first element. A shared single stream
    // could not replay to both, so independent replay proves each access mints a distinct stream.
    let replayA = await subscriberA.next()
    let replayB = await subscriberB.next()

    #expect(replayA != nil)
    #expect(replayB != nil)
}

@Test func stateBroadcastReachesAllSubscribers() async throws {
    let manager = ReliaBLEManager()

    var subscriberA = manager.state.makeAsyncIterator()
    var subscriberB = manager.state.makeAsyncIterator()

    // Drain the replayed element. Awaiting it also guarantees both continuations are registered
    // (the replay is yielded during registration), so the broadcast below cannot be missed.
    _ = await subscriberA.next()
    _ = await subscriberB.next()

    // Force a state broadcast through the real actor path; both live subscribers receive it.
    await BluetoothActor.shared.updateState()

    let broadcastA = await subscriberA.next()
    let broadcastB = await subscriberB.next()

    #expect(broadcastA != nil)
    #expect(broadcastB != nil)
}

@Test func peripheralDiscoveriesDoesNotReplay() async throws {
    let manager = ReliaBLEManager()

    // No scanning has occurred and the discoveries feed does not replay, so no event should
    // arrive within a short grace period.
    let event = await firstEvent(from: manager.peripheralDiscoveries, withinNanoseconds: 200_000_000)

    #expect(event == nil)
}

/// Returns the first event from `stream`, or `nil` if none arrives within `nanoseconds`.
private func firstEvent(
    from stream: AsyncStream<PeripheralDiscoveryEvent>,
    withinNanoseconds nanoseconds: UInt64
) async -> PeripheralDiscoveryEvent? {
    await withTaskGroup(of: PeripheralDiscoveryEvent?.self) { group in
        group.addTask {
            for await event in stream {
                return event
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
