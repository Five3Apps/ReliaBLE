//
//  ConnectionState.swift
//  ReliaBLE
//
//  Copyright (c) 2026 Five3 Apps, LLC <justin@five3apps.com>
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

import Foundation

/// The connection state of a single peripheral tracked by the library.
///
/// ``ConnectionState`` is a finite, `Sendable` enumeration. Every non-terminal state change
/// is emitted on ``ReliaBLEManager/connectionStateChanges``; the two terminal states carry an
/// optional ``PeripheralError`` reason that the integrating app can surface.
public enum ConnectionState: Sendable, Equatable, Hashable {
    /// A connection request has been issued and is in flight.
    case connecting
    /// A reconnection is in progress.
    ///
    /// For ``ReconnectSource/library``, a `nil` `attempt` / `nextRetryAt` means the link is
    /// **waiting for the radio** — projected when a demanded link's radio drops, or when a
    /// reconnect-wanting manual-connect hold is registered while the radio is not yet usable, and
    /// held until a connect is issued, the ladder supplies real values, the link succeeds, or demand
    /// clears — not yet on the backoff ladder. A ladder step that has actually armed carries
    /// **real** values: `attempt >= 1` and a concrete `nextRetryAt`. ``ReconnectSource/system``
    /// is iOS reconnecting at the daemon level; the library is not involved and always exposes
    /// `nil` for both.
    case reconnecting(source: ReconnectSource, attempt: Int?, nextRetryAt: Date?)
    /// The peripheral is currently connected.
    case connected
    /// A disconnection request has been issued and is in flight.
    case disconnecting
    /// The peripheral has disconnected.
    ///
    /// The `reason` is `nil` for a clean, explicit disconnect and non-`nil` for an unexpected
    /// drop from CoreBluetooth. Idle-grace teardown also surfaces as an intentional
    /// `reason: nil` — deliberately indistinguishable from an app-initiated disconnect to the
    /// reconnect policy (FR-11.5 "intentional").
    case disconnected(reason: PeripheralError?)
    /// A connection attempt has failed.
    ///
    /// The `reason` carries a ``PeripheralError`` mapped from the underlying `CBError` so the
    /// integrating app can react to addressable failures without importing CoreBluetooth.
    case failed(reason: PeripheralError?)
}

/// Identifies which tier is driving a reconnection.
public enum ReconnectSource: Sendable, Equatable, Hashable {
    /// The iOS daemon-level auto-reconnect (`CBConnectPeripheralOptionEnableAutoReconnect`)
    /// is in control. The library does not schedule its own retries while the system is
    /// attempting recovery.
    case system
    /// The library-side exponential-backoff ladder has armed. `attempt` and `nextRetryAt`
    /// are populated on the ``ConnectionState/reconnecting(source:attempt:nextRetryAt:)``
    /// case.
    case library
}

/// A single connection-state transition emitted on ``ReliaBLEManager/connectionStateChanges``.
///
/// Each element pairs the ``Peripheral/id`` of the peripheral with its new ``ConnectionState``.
/// A subscriber that only cares about one peripheral filters with
/// `where $0.peripheralId == targetId`.
public struct ConnectionStateChange: Sendable, Equatable, Hashable {
    /// The ``Peripheral/id`` of the handle whose connection state changed.
///
/// Filter the stream with `change.peripheralId == peripheral.id` to observe a single
/// peripheral.
    public let peripheralId: String
    /// The new connection state.
    public let state: ConnectionState
}
