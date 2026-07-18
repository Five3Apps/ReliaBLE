# ReliaBLE

## Overview

ReliaBLE is a Swift package that provides a reliable, modern, yet easy to use interface for developers building apps that interact with peripheral devices over Bluetooth Low Energy (BLE).

It is a **device-protocol-agnostic BLE Central core**: the library owns link lifecycle, GATT discovery/readiness, and command execution machinery; the integrating app owns domain packet content (framing, CRC, application semantics). Primary targets are **wearables, IoT sensors, and smart-home** accessories—apps that think in **“my devices”** first. Generic scanner UIs are supported but secondary.

The library is **unshipped** and under active development. This PRD is the **v1 target**. The package is not intended for production use until the requirements herein are implemented. Checkmarks (✅) mark areas that already match the target in current code; unmarked items remain open.

## High-level Requirements

- Open-source package designed to be integrated into many iOS applications.
- Primary focus on reliability of communication (connection **and** discovery-ready **and** command completion).
- Exposes a public interface that is easy for developers who may have little CoreBluetooth experience: **device-centric** (`Peripheral`) rather than central-manager-shaped for day-to-day work.
- No UI.
- Acts as a BLE Central using CoreBluetooth; never vends live CoreBluetooth objects to the app.
- Supports background scanning and state restoration.
- Provides a **command**-style protocol for peripheral I/O, with dependencies (after GATT readiness exists).
- Supports simultaneous use of multiple peripherals.
- Supports non-secure use, BLE security features, and hooks for application-layer security.
- Modern Swift 6 architecture (strict concurrency); single internal isolation domain for CoreBluetooth.
- High test coverage (including CoreBluetooth mocking).
- Leaves the type name **`Device`** free for integrating apps (e.g. multi-transport BLE + Matter + Wi‑Fi models).


## Architecture (normative product shape)

### Public types

| Type | Role |
|---|---|
| **`ReliaBLEManager`** | Façade: authorization, Bluetooth state, scanning, peripheral registry, configuration. |
| **`Peripheral`** | Long-lived **control handle**, interned by id per manager. Primary type for wearables/IoT: sticky discovery filter, connection/readiness, command queue, Advanced connect/disconnect, last-seen / last-advertisement metadata. |
| **`DiscoveredPeripheral`** | Sendable **scan snapshot** (advertisement, rssi, lastSeen, id, …). Manager-stamped. Exposes **`peripheral`** syntactic sugar resolving to the interned `Peripheral` handle. |

- Live `CBPeripheral` / GATT objects remain inside the library’s Bluetooth isolation domain only.
- **Known id:** `manager.peripheral(id:)` creates or returns a handle before any scan; a later matching discovery binds the live radio to that same handle.
- **“My devices” UI:** tracked `Peripheral` handles enriched with last discovery metadata (option A). **Do not** vend synthetic/fake `DiscoveredPeripheral` rows for offline bound devices.
- **“Nearby” UI:** real `DiscoveredPeripheral` stream only (scanner / provisioning).
- Optional later: thin `PeripheralUpdate` stream events (option B)—not a third control type.

Detail and rationale: `docs/designs/discovered-peripheral-vs-peripheral-2026-07-15.md`.

### Connection model (work-driven primary)

- **Primary path:** work drives the link. A non-empty per-`Peripheral` command queue causes auto-connect (and discovery to *ready* when required). When the queue is empty and there is no Advanced app hold, start **idle disconnect** (global config, **default 5 seconds**).
- **Advanced app hold:** `Peripheral.connect(autoReconnect:)` / `disconnect()` suppress idle teardown while held. Documented as Advanced; expected to be rare. Same ensure-linked path as work-driven connect—not a second connection stack or either-or mode enum.
- **Reconnect (Approach B):**
  - **Tier-0** (OS `CBConnectPeripheralOptionEnableAutoReconnect`): enabled on work-driven connects while the link is up; **ended** when idle teardown or intentional disconnect cancels the connection.
  - **Tier-1** (library exponential-backoff ladder): armed on unexpected disconnect **only while** the command queue is non-empty (or Advanced hold with reconnect desired). Disarmed when the queue is empty and there is no such hold.
  - Accepted gap: during the idle grace window, Tier-0 may reconnect once with an empty queue; if still quiet and no hold, cancel again.
- **PoweredOn:** work submission (scan, connect, command/`run`) **awaits** a usable radio (`PoweredOn`) rather than silently no-op’ing. Terminal states (unauthorized, unsupported, powered off per policy) **fail** promptly with typed errors. Bluetooth state remains observable for UI gating.
- Manager-level `connect(to:)` as the primary app API is a **refactor target**: connect/disconnect/run/discovery belong on **`Peripheral`**.

### Implementation sequencing (v1)

1. Public type split + registry (`Peripheral` / `DiscoveredPeripheral`) and demotion of manager-only connect.
2. Work-driven link rules + idle teardown + Approach B reconnect + PoweredOn await.
3. **FR-10** GATT discovery/readiness/subscriptions on `Peripheral`.
4. **FR-4 / FR-5** commands (serial per-peripheral queue first; dependencies/prioritization after).
5. FR-6, FR-7, FR-8.5, and remaining polish as needed.

**Commands (FR-4/FR-5) must not ship before FR-10.** A re-established link is not sufficient for I/O until discovery-*ready* (FR-1.2, FR-10).


## Detailed Requirements

### Functional Requirements

1. Reliability of Communication:

- FR-1.1: Implement error detection and correction mechanisms for each BLE transaction (command/watchdog layer; builds on FR-4/FR-5 after FR-10).
- FR-1.2: Ensure automatic reconnection per the connection model (Approach B: Tier-0 while linked on work-driven connects; Tier-1 ladder with exponential backoff while work is pending or Advanced hold requests reconnect). On reconnection, services and characteristics must be re-discovered rather than reused, as part of returning to a discovery-*ready* state (FR-10.6, FR-10.3); a re-established link alone is not sufficient to resume characteristic I/O. Command-layer reconnect-and-rerun (FR-4/FR-5) depends on this ready transition rather than treating "connected again" as enough. (Tier-1 backoff substrate exists; queue/hold gating, idle cancel of Tier-0, and discovery re-run remain open.)
- FR-1.3: Provide status updates on connection stability and data transmission integrity.
    - ✅ FR-1.3.1: Provide status updates on connection stability (e.g. connected, disconnected, reconnecting), exposed in a device-centric way on `Peripheral` (and/or equivalent streams) as the type model lands.
    - FR-1.3.2: Provide status updates on data transmission integrity (command/transaction layer).
- FR-1.4: **PoweredOn gating for work:** Scan, connect, and command submission must await `PoweredOn` (or equivalent usable state) instead of silently no-op’ing when the radio is not ready. Terminal unusable states fail with typed errors. Observability of Bluetooth state for UI remains required.
- FR-1.5: **Idle disconnect:** When a `Peripheral` has no pending/queued commands and no Advanced app hold, disconnect after a configurable idle interval. Default interval is **5 seconds**. Configuration is **global** (not per-peripheral) unless a future requirement explicitly adds per-device overrides.


2. Public Interface for Easy Integration:

- FR-2.1: Design a clear, documented API for developers to interact with BLE functionality without UI components, centered on **`Peripheral`** for device work and **`ReliaBLEManager`** for process-wide concerns (auth, scan, registry).
- FR-2.2: Include example usage showing: known-id `Peripheral`, scan → `DiscoveredPeripheral.peripheral`, work-driven `run` (when commands exist), Advanced connect, and discovery readiness—without requiring CoreBluetooth expertise.
- FR-2.3: Provide streams (or equivalent) for asynchronous events:
    - ✅ FR-2.3.1: Connection-state changes (connection, disconnection, connection failure / reconnecting). Migrate primary consumption to `Peripheral` as the handle model lands.
    - FR-2.3.2: Data received from peripherals (command/notify path after FR-4/FR-10).
    - FR-2.3.3: Discovery/readiness changes distinct from connection state (FR-10.3.2).
- FR-2.4: **Public type model:**
    - FR-2.4.1: **`Peripheral`** is a long-lived handle interned by id per manager. It is the unit of connection policy, GATT discovery filter, readiness, subscriptions, command queue, and Advanced connect/disconnect.
    - FR-2.4.2: **`DiscoveredPeripheral`** is a Sendable scan snapshot (advertisement metadata). It must not be the only way to obtain a `Peripheral`.
    - FR-2.4.3: **`DiscoveredPeripheral.peripheral`** (or equivalent sugar) resolves to the interned handle via the vending manager (manager-stamped discovery).
    - FR-2.4.4: **`manager.peripheral(id:)`** (or equivalent) creates or returns a handle for a known id before any advertisement is seen; later discovery binds the live radio to that handle.
    - FR-2.4.5: Support a **tracked / “my devices”** view of handles with last-discovery metadata on `Peripheral` (rssi, lastSeen, optional last advertisement). Do not invent fake `DiscoveredPeripheral` entries for offline devices. Raw discovery streams remain for nearby/scanner UX.
    - FR-2.4.6: Do not use the public type name **`Device`** for library types (reserved for integrating apps, e.g. multi-transport).
    - FR-2.4.7: Never expose live CoreBluetooth objects (`CBPeripheral`, `CBService`, `CBCharacteristic`, etc.) in the public API.
- FR-2.5: **API placement:** Connect, disconnect, discovery filter, readiness observation, subscriptions, and command `run` are exposed on **`Peripheral`**. `ReliaBLEManager` owns authorization, Bluetooth state, scanning start/stop, and handle registry. Manager-only connect as the primary documented path is a temporary milestone to be refactored away.


3. BLE Central Using CoreBluetooth:

- ✅ FR-3.1: Use CBCentralManager to manage BLE central activities.
- ✅ FR-3.2: Implement scanning for peripherals with customizable scan options (e.g., services, UUIDs).
- FR-3.3: Isolate all CoreBluetooth usage in a single internal concurrency domain (e.g. `@BluetoothActor`); public façades remain callable without forcing `@MainActor`.
- FR-3.4: Lazy central setup under app-controlled authorization, except where state restoration requires eager setup when a restore identifier is configured and authorization is already granted.


4. Command Style Protocol for Interacting with Peripherals:

**Depends on FR-10.** Do not implement command execution against characteristics before discovery readiness exists.

- FR-4.1: Define a flexible command protocol where the content and functionality of commands are provided by the integrating app. Commands are submitted on a **`Peripheral`** (e.g. `run`). Commands target services and characteristics by UUID (`CBUUID`), and may only execute when that peripheral is discovery-*ready* for the targeted UUIDs (FR-10.3): targeting an undiscovered or not-ready characteristic must await readiness (bounded by a timeout) while discovery is in progress, or fail fast when discovery has already failed. This gate is inherited from FR-10 so the command queue does not re-litigate discovery.
- FR-4.2: Support various command types:
    - FR-4.2.1: Notify-only (peripherals notify with updates).
    - FR-4.2.2: Read-only (retrieve data from peripherals).
    - FR-4.2.3: Read-write (both read from and write to peripherals).
    - FR-4.2.4: Write-only (send data to peripherals).
- FR-4.3: Implement parsing of responses from peripherals into a usable Swift data structure (app-supplied decode as appropriate).
- FR-4.4: **Work-driven link:** Enqueueing/running a command on a disconnected `Peripheral` must auto-connect (and run discovery to ready as needed) without requiring a prior Advanced `connect`, unless product policy for never-seen ids chooses fail-fast (implementation planning).
- FR-4.5: **Reconnect-and-rerun:** On unexpected disconnect with commands still queued or in flight, after link recovery and return to discovery-*ready*, retry/resume command execution so transient drops do not require the app to re-drive the queue (idempotent command design preferred).
- FR-4.6: **Exactly-once completion:** Each command finishes with a single terminal success or failure (no double completion).
- FR-4.7: **Watchdogs:** Enforce per-step (or per-command) timeouts; streaming/multi-frame commands may reset the watchdog per frame as specified in implementation.


5. Simultaneous Connection to Multiple Devices:

- ✅ FR-5.1: Ensure the system can maintain connections to multiple peripherals concurrently (per-id connection state substrate exists; align with `Peripheral` handles).

- FR-5.2: Implement a **per-`Peripheral`** command execution queue:
    - FR-5.2.1: Schedule commands FIFO on that peripheral unless dependencies dictate otherwise. **Minimum viable queue is serial (one-wide) per peripheral**—ship that before prioritization.
    - FR-5.2.2: Allow commands to declare dependencies, ensuring that dependent commands run only after prerequisites complete successfully.
    - FR-5.2.3: Manage conflicts so commands affecting the same peripheral or characteristic run in a correct order based on dependencies / serial rules.
    - FR-5.2.4: Handle command failures in the queue (skip, retry, or fail dependency chains) with documented policy.
    - FR-5.2.5: Support prioritization so urgent commands may bypass others without breaking dependency chains (**after** serial queue + ready gate + reconnect-and-rerun).


6. Security Options:

- FR-6.1: Support for non-secure mode where no additional encryption is applied.
- FR-6.2: Integration with BLE security features like encryption and man-in-the-middle protection.
- FR-6.3: Provide hooks or interfaces for application layer security, allowing the integrating app to handle encryption/decryption.


7. Data Handling and Chunking:

- FR-7.1: Support commands that handle data larger than a single BLE packet by implementing chunking.
- FR-7.2: Ensure that chunked data can be reassembled correctly at the receiving end, either by the library or the integrating app.


8. Scanning Functionality:

- ✅ FR-8.1: Specific Service Scanning:
    - FR-8.1.1: Allow scanning to be targeted at specific BLE services by providing UUIDs.
    - FR-8.1.2: Provide an API to start, stop, and update the list of services for which to scan, allowing dynamic adjustment during runtime.
    - FR-8.1.3: Option to enable reporting of every advertisement packet (discovery) for detailed tracking, which can be toggled on or off by the integrating app.

- FR-8.2: Support continuous scanning:
    - FR-8.2.1: Allow the library to scan continuously for BLE peripherals, providing real-time updates about nearby devices as **`DiscoveredPeripheral`** values (and/or equivalent), each resolvable to a `Peripheral` handle.
    - FR-8.2.2: Provide an interface for the app to start, stop, and check the status of the continuous scanning process.

- FR-8.3: Background Scanning:
    - FR-8.3.1: Implement background scanning capabilities, ensuring compliance with iOS background execution rules.
    - FR-8.3.2: Notify the integrating app when new devices come into range even when the app is not in the foreground, using appropriate iOS background modes like bluetooth-central.

- ✅ FR-8.4: Processing of Advertisement Data:
    - ✅ FR-8.4.1: Extract and make available manufacturing data from advertisement packets to the integrating app.
    - ✅ FR-8.4.2: Allow the integrating app to parse this data, potentially providing callbacks or data structures for easy access to specific fields like manufacturer-specific data.

- FR-8.5: Unique Identifier from Manufacturing Data:
    - FR-8.5.1: Provide an option for the integrating app to process manufacturing data to derive a unique identifier for each peripheral.
    - FR-8.5.2: Include an API method or property where the integrating app can return this identifier back to the library for more accurate peripheral identification and management.
    - FR-8.5.3: Once identified, maintain this mapping of the unique identifier to the peripheral's BLE address or other identifying characteristics to ensure consistent tracking across sessions or reconnections. Handle interning and discovery matching (FR-2.4, FR-10.6.2) must adopt this identity model when available.

- FR-8.6: Scanning respects FR-1.4 (await PoweredOn / fail terminal states)—no silent no-op when the radio is not ready.


9. Logging Support:

- ✅ FR-9.1: Implement a flexible logging system within the BLE management library:
    - FR-9.1.1: Allow the integrating app to enable or disable logging through a public API.
    - FR-9.1.2: Provide methods for different log levels (e.g., debug, info, warning, error) to log various types of information relevant to BLE operations.
    - FR-9.1.3: Design the logging system so that log messages can be directed to any output the integrating app chooses (console, files, server, etc.):
        - FR-9.1.3.1: Include an API where the integrating app can specify or pass in its own logging handler or callback function to handle log messages.
        - FR-9.1.3.2: Ensure that if no custom handler is provided, logs can default to a standard output like the console or be disabled.

- FR-9.2: Log key events such as:
    - ✅ Connection/disconnection events
    - Command successes or failures
    - ✅ Scanning start/stop
    - Service/characteristic discovery events (discovery start/completion/failure, readiness transitions, GATT table changes, subscription state changes)
    - Idle connect/disconnect and Advanced hold connect/disconnect
    - Security events (e.g., encryption initiation or failure)
    - Data chunking operations


10. Service and Characteristic Discovery and Management:

The layer between establishing a connection and reading or writing data
(FR-4, FR-7). After a peripheral connects, its GATT services and characteristics must be
discovered before any interaction, and that discovered view must be kept correct across
firmware changes and reconnections. This section covers discovery and characteristic setup
only; the movement of application data over characteristics is covered by the command
protocol (FR-4) and chunking (FR-7).

**Discovery is a reliability gate, not merely a catalog.** A peripheral being connected
(FR-1.3.1) is not sufficient for interaction: it is not eligible for command execution or
characteristic I/O until discovery has reached a terminal *ready* state for the app-declared
UUID set. This "connected ≠ ready" invariant (defined in FR-10.3) is the discovery-layer
foundation that the command queue (FR-4, FR-5) and reconnect-and-rerun behavior are expected
to build on; those command-layer mechanics are out of scope for this section and referenced
only where the gate must be honored.

**API surface:** Discovery filter, readiness observation, catalogs, and subscriptions are exposed on **`Peripheral`** (FR-2.4, FR-2.5), not as a global manager API keyed only by bare id strings (ids remain the internal interning key).

- FR-10.1: Service Discovery:
    - FR-10.1.1: Provide an API to discover services on a connected peripheral, requiring the integrating app to declare the specific service UUIDs of interest. Do not expose unfiltered "discover all services" as the default path — Apple explicitly discourages it because enumerating an entire remote GATT table negatively affects battery life and time-to-ready.
    - FR-10.1.2: Support both automatic discovery on connection and explicit, on-demand discovery. The integrating app must declare the desired service/characteristic UUID set as a **sticky filter on `Peripheral`** (e.g. `discoveryFilter`), settable when obtaining the handle and/or before first work. The declaration is mandatory for automatic discovery: if automatic discovery is required with no declared UUID set, that is a hard error (fail-closed), not a silent leave-not-ready — consistent with FR-10.1.1.
    - FR-10.1.3: Expose discovered services to the integrating app as Sendable value snapshots keyed by peripheral identity (FR-10.6.2) and service UUID (CBUUID). Never surface live CoreBluetooth objects.

- FR-10.2: Characteristic and Descriptor Discovery:
    - FR-10.2.1: Provide an API to discover characteristics for a discovered service, allowing the integrating app to declare the characteristic UUIDs of interest. Enforce CoreBluetooth's ordering constraint: services are discovered before characteristics, and characteristics before descriptors.
    - FR-10.2.2: Track per-service discovery completion, correctly handling the separate completion callback fired for each service, and drive the peripheral to the *ready* state (FR-10.3) only once all requested discoveries have completed.
    - FR-10.2.3: Optionally discover descriptors for a characteristic on demand. Descriptor discovery is not required to enable notifications (see FR-10.4.1).
    - FR-10.2.4: Expose discovered characteristics as Sendable value snapshots including metadata: UUID (CBUUID), properties (read, write, write-without-response, notify, indicate), and, when discovered, descriptors.

- FR-10.3: Discovery Lifecycle and Readiness:
    - FR-10.3.1: Model discovery as an explicit, per-peripheral state machine driven entirely by delegate callbacks. Never assume synchronous availability of services or characteristics after initiating discovery.
    - FR-10.3.2: Expose discovery/readiness state on **`Peripheral`** through a feed distinct from the connection-state stream (FR-1.3.1), so that connection-recovery observability and GATT readiness are not conflated. Readiness must be observable and awaitable, reporting progress, completion, and errors. `connected` must never be presented to the app as `ready`.
    - FR-10.3.3: Enforce a configurable discovery timeout so that a stalled or interrupted discovery surfaces as an error rather than an indefinite wait.
    - FR-10.3.4: Handle interrupted or partial discovery: if a peripheral disconnects mid-discovery, treat it as a hard reset of the discovery state — discard partial results and any pending discovery bookkeeping — and re-run discovery on the next connection (see FR-10.6.1). On unexpected disconnect, the app-visible discovery catalog must be invalidated (cleared, or marked stale until the next ready) with explicit, documented timing.
    - FR-10.3.5: Partial-discovery policy is fail-closed. If a declared (required) service or characteristic UUID is absent — narrow filter, wrong firmware, or a stale cache — discovery is a failure: the peripheral does not become ready and the missing UUID(s) are reported. Map non-nil errors from each discovery callback into the library's error type, distinguishing common causes where feasible (e.g., missing-UUID versus disconnection during discovery).
    - FR-10.3.6: Readiness is an enforced gate, not merely an observable signal. Characteristic I/O and command execution (FR-4) against a peripheral must wait until it is ready for the targeted UUIDs: await readiness (bounded by the FR-10.3.3 timeout) while discovery is pending or in progress, and fail fast if discovery has already failed.
    - FR-10.3.7: **Default ready = catalog-ready:** declared services/characteristics have been successfully discovered. Ready does **not** mean every notify-capable characteristic is subscribed. Subscriptions are separate (FR-10.4).

- FR-10.4: Characteristic Subscription Management (Notify/Indicate):
    - FR-10.4.1: Provide an API on **`Peripheral`** to enable and disable notifications or indications using the platform's subscribe mechanism. Never write the Client Characteristic Configuration Descriptor (CCCD, 0x2902) directly — CoreBluetooth manages the CCCD write internally and forbids writing it directly.
    - FR-10.4.2: Confirm the subscription state-change callback before treating a subscription as active, and sequence subscription-enable before issuing any command that causes the peripheral to emit data, so that initial notifications are not lost. Commands that require notify await confirm for **those** characteristic UUIDs; do not block all I/O on unrelated subscriptions. Optional later convenience: auto-subscribe a declared UUID set on the handle, still tracked as intent (FR-10.4.5).
    - FR-10.4.3: Expose subscription state and its changes to the integrating app. Do not rely solely on the platform's `isNotifying` flag, which can lag the actual state.
    - FR-10.4.4: Notifications are unacknowledged at the GATT layer and may be lost or reordered above the link layer; application-layer framing/sequencing of multi-packet notification streams is out of scope for this section and handled per FR-7 (chunking and reassembly) and the command protocol (FR-4).
    - FR-10.4.5: The library tracks requested **subscription intent** per characteristic. After reconnection, state restoration (FR-10.6.3), or `didModifyServices` re-discovery (FR-10.5.1), previously requested subscriptions must be re-armed — or explicitly reported as inactive for the app to re-request. Re-discovery alone does not restore notify/indicate intent, and notify-only integrations (FR-4.2.1) break without this.

- FR-10.5: GATT Cache Invalidation and Re-discovery:
    - FR-10.5.1: On a peripheral GATT-table change (the `didModifyServices` callback), detection alone is insufficient. The library must immediately mark the peripheral *not ready* (re-gating work per FR-10.3.6), park or fail any in-flight discovery-dependent I/O, re-run discovery for the affected (or all declared) services, return to *ready* only after that completes, re-arm subscription intent (FR-10.4.5), and surface the event on the discovery/readiness stream.
    - FR-10.5.2: Treat reconnection following a peripheral firmware update or DFU as requiring full re-discovery; do not trust a previously cached view of services and characteristics.
    - FR-10.5.3: Document the iOS OS-level GATT caching limitation: there is no public API to clear the cache. Reliable cross-connection refresh requires the peripheral to implement the Service Changed characteristic (0x2A05) within the Generic Attribute Service (0x1801) and to bond; otherwise the only fallback is user-driven (toggle Bluetooth, or "Forget This Device"). This is a peripheral-firmware responsibility that the library cannot fully control, and the limitation must be communicated to integrating apps.

- FR-10.6: Reconnection, State Restoration, and Stale-Reference Handling:
    - FR-10.6.1: Re-discover services and characteristics on every new connection. Never reuse a service or characteristic reference obtained from a prior connection. Re-discovery is part of returning to the *ready* state (FR-10.3.6): a re-established link is not sufficient to resume characteristic I/O until discovery completes (see FR-1.2).
    - FR-10.6.2: Internally discard all live CoreBluetooth service/characteristic references on disconnect and reset the discovery state. The app-facing catalog and handle registry are keyed by the library's peripheral identity model (`Peripheral.id`), not by held CoreBluetooth objects and not by `cbIdentifier` alone. (Stable identity from manufacturer data, FR-8.5, is still open; keying must adopt whatever FR-8.5 settles on.) Consistent with invalidation/refresh on Bluetooth power cycling.
    - FR-10.6.3: On CoreBluetooth central state restoration (`willRestoreState`), re-associate restored peripherals to interned **`Peripheral`** handles, discard any prior discovery catalog, re-run discovery for peripherals the app still intends to use, and re-apply subscription intent (FR-10.4.5). A restored link is not ready: the same readiness gate (FR-10.3.6) as a fresh connection applies.


11. Connection Lifecycle on `Peripheral`:

- FR-11.1: **Work-driven connect:** When work requires a link (non-empty command queue, or other library-defined work that needs a connection), the library connects the `Peripheral` without a prior Advanced `connect` call.
- FR-11.2: **Advanced app hold:** `Peripheral.connect(autoReconnect: Bool)` sets an app hold (suppresses idle teardown). `Peripheral.disconnect()` clears the hold and intentionally cancels the connection. The `autoReconnect` flag controls whether Tier-0/Tier-1 apply for that hold, consistent with Approach B. Primary docs emphasize work-driven usage; hold APIs are Advanced.
- FR-11.3: **Idle teardown:** Per FR-1.5—only when queue empty and no app hold; cancel connection (drops Tier-0).
- FR-11.4: **Single state machine:** Work-driven connect and Advanced connect share one ensure-linked implementation (PoweredOn await, connect, discover to ready). No parallel connection stacks.
- FR-11.5: Connection-state observation remains available (FR-1.3.1) and must distinguish intentional disconnect, unexpected drop, and reconnecting where applicable.


### Non-Functional Requirements

1. Modern Swift 6 Architecture:

- ✅ NFR-1.1: Use Swift 6 language features like concurrency with async/await for handling BLE operations.
- ✅ NFR-1.2: Adhere to Swift best practices like protocol-oriented programming and value types where feasible (`DiscoveredPeripheral` and catalogs as values; `Peripheral` may be a class or id-façade—implementation choice—as long as Sendable/isolation contracts hold).
- NFR-1.3: Keep all CoreBluetooth objects inside a single internal isolation domain; public handles forward by id. Do not use per-peripheral actors that own `CBPeripheral`.


2. High Test Coverage:

- ✅ NFR-2.1: Write unit tests for all public API methods, covering at least 80% of code paths.
- ✅ NFR-2.2: Use mocking or simulation for BLE peripherals to facilitate testing in CI environments.
- NFR-2.3: Implement integration tests to verify the system's behavior in real-world scenarios, including multi-device connections, security modes, and data chunking.

3. Performance:

- NFR-3.1: Ensure low latency in command execution and response handling to meet real-time application needs.
- NFR-3.2: Optimize for battery life on iOS devices by minimizing unnecessary BLE activity (including idle disconnect and filtered discovery).


4. Scalability and Maintainability:

- NFR-4.1: Design with future extensibility in mind, allowing easy addition of new command types or security protocols.
- NFR-4.2: Ensure clear separation of concerns: library = link + discovery readiness + command machinery; app = domain protocol/framing.


5. Documentation:

- NFR-5.1: Provide comprehensive documentation for all public APIs, including usage examples, parameters, return values, error handling, command types, discovery readiness, and chunking.
- NFR-5.2: Getting Started emphasizes work-driven `Peripheral` usage for wearables/IoT; Advanced section covers app-hold connect/disconnect and raw scanner flows.
- NFR-5.3: Document OS GATT cache / Service Changed limitations (FR-10.5.3) for integrating apps and firmware partners.


6. Compatibility:

- NFR-6.1: Ensure compatibility with the latest iOS versions and CoreBluetooth API changes.
- NFR-6.2: Consider backward compatibility where it does not compromise security or performance. Pre-1.0 API may break as the `Peripheral` / `DiscoveredPeripheral` refactor lands.


7. Energy Efficiency in Scanning:

- NFR-7.1: Optimize scanning to minimize battery drain, especially when operating in background modes.


8. Compliance and Performance:

- NFR-8.1: Ensure the scanning process adheres to Apple's guidelines for BLE operations, especially in terms of background execution and power management.
- NFR-8.2: Aim for minimal latency in detecting new devices, especially when continuous or background scanning is enabled.


9. Performance with Logging:

- NFR-9.1: Ensure that logging, when enabled, does not significantly impact the performance or real-time capabilities of BLE operations.
- NFR-9.2: Optimize logging for minimal overhead, possibly through techniques like lazy logging where logs are only formatted if logging is enabled.


10. Dependency Management:

- NFR-10.1: Minimize the use of third-party dependencies to reduce complexity and potential security risks. Only integrate dependencies that:
    - Are well-known, widely used, and actively maintained in the open-source community.
    - Provide significant benefits in terms of implementation effort and return on investment (ROI).
- NFR-10.2: Consider the following when selecting dependencies:
    - NFR-10.2.1: Evaluate the necessity of each dependency. If a feature can be implemented with a reasonable amount of code or with built-in iOS APIs, prefer that approach over adding a new dependency.
    - NFR-10.2.2: Assess the maintenance burden, including the frequency and quality of updates, community support, and documentation.
    - NFR-10.2.3: Ensure that dependencies are compatible with the current and foreseeable future versions of Swift and iOS.
- NFR-10.3: Documentation for each used dependency should include:
    - Why it was chosen.
    - How it integrates with the library's architecture.
    - Any known limitations or considerations for usage.
- NFR-10.4: Use Swift Package Manager (SPM) for dependency management to ensure version control, reproducibility, and ease of updates.

11. Continuous Integration



## References (design / investigation)

- `docs/designs/discovered-peripheral-vs-peripheral-2026-07-15.md` — public type split
- `docs/investigations/objc-ble-vs-reliable-architecture-2026-07-15.md` — ObjC Core parity, connection model, FR-10 sequencing
