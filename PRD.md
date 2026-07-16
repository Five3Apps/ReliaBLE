# ReliaBLE

## Overview

ReliaBLE is a Swift package that provides a reliable, modern, yet easy to use interface for developers building apps that interact with peripheral devices over Bluetooth Low Energy (BLE).

## High-level Requirements

- Open-source package designed to be integrated into many iOS applications.
- Primary focus on reliability of communication.
- Exposes a public interface that is easy for other developers to integrate into a wide variety of iOS apps.
- No UI
- Acts as a BLE Central using CoreBluetooth.
- Supports background scanning.
- Provides the ability to interact with peripherals via a "command" style protocol that allows for dependencies.
- Supports simultaneous connection to multiple devices.
- Supports options to be used non-secure, with BLE security features, or application layer security provided by the application it is integrated into.
- Modern Swift 6 architecture and implementation.
- Includes support for high test coverage.


## Detailed Requirements

### Functional Requirements

1. Reliability of Communication:

- FR-1.1: Implement error detection and correction mechanisms for each BLE transaction.
- FR-1.2: Ensure automatic reconnection attempts with exponential backoff for failed connections. On reconnection, services and characteristics must be re-discovered rather than reused, as part of returning to a discovery-*ready* state (FR-10.6, FR-10.3); a re-established link alone is not sufficient to resume characteristic I/O. Any future command-layer reconnect-and-rerun (FR-4/FR-5) depends on this ready transition rather than treating "connected again" as enough. (Reconnection with exponential backoff is implemented; the discovery re-run tie-in remains open pending FR-10.)
- FR-1.3: Provide status updates on connection stability and data transmission integrity.
    - ✅ FR-1.3.1: Provide status updates on connection stability (e.g. connected, disconnected, reconnecting).
    - FR-1.3.2: Provide status updates on data transmission integrity.


2. Public Interface for Easy Integration:

- FR-2.1: Design a clear, documented API for developers to interact with BLE functionality without UI components.
- FR-2.2: Include example usage in documentation showing how to connect, send commands, and receive responses.
- FR-2.3: Provide delegate methods or callbacks for asynchronous operations like connection changes or data received.
    - ✅ FR-2.3.1: Provide callbacks/streams for connection changes (connection, disconnection, connection failure).
    - FR-2.3.2: Provide callbacks/streams for data received from peripherals.


3. BLE Central Using CoreBluetooth:

- ✅ FR-3.1: Use CBCentralManager to manage BLE central activities.
- ✅ FR-3.2: Implement scanning for peripherals with customizable scan options (e.g., services, UUIDs).


4. Command Style Protocol for Interacting with Peripherals:

- FR-4.1: Define a flexible command protocol where the content and functionality of commands are provided by the integrating app. Commands target services and characteristics by UUID (CBUUID), and may only execute against a peripheral that is discovery-*ready* for the targeted UUIDs (FR-10.3): targeting an undiscovered or not-ready characteristic must await readiness (bounded by a timeout) while discovery is in progress, or fail fast when discovery has already failed. This gate is inherited from FR-10 so the command queue does not re-litigate it.

- FR-4.2: Support various command types:
    - FR-4.2.1: Notify-only (peripherals notify with updates).
    - FR-4.2.2: Read-only (retrieve data from peripherals).
    - FR-4.2.3: Read-write (both read from and write to peripherals).
    - FR-4.2.4: Write-only (send data to peripherals).
- FR-4.3: Implement parsing of responses from peripherals into a usable Swift data structure.


5. Simultaneous Connection to Multiple Devices:

- ✅ FR-5.1: Ensure the system can maintain connections to multiple peripherals concurrently.

- FR-5.2: Implement a queue system for command execution with the following capabilities:
    - FR-5.2.1: Support for scheduling commands in a queue, where commands are executed in FIFO order unless dependencies dictate otherwise.
    - FR-5.2.2: Allow commands to declare dependencies, ensuring that dependent commands are only executed once their prerequisites have completed successfully.
    - FR-5.2.3: Manage conflicts and ensure that commands affecting the same peripheral or characteristic are executed in the correct sequence based on their dependencies.
    - FR-5.2.4: Provide mechanisms to handle command failures within the queue, such as skipping or retrying dependent commands, or marking the entire dependency chain as failed.
    - FR-5.2.5: Support prioritization within the queue to allow for urgent commands to bypass others where necessary without breaking dependency chains.


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
    - FR-8.2.1: Allow the library to scan continuously for BLE peripherals, providing real-time updates to the integrating app about nearby and connectable devices.
    - FR-8.2.2: Provide an interface for the app to start, stop, and check the status of the continuous scanning process.

-  FR-8.3: Background Scanning:
    - FR-8.3.1: Implement background scanning capabilities, ensuring compliance with iOS background execution rules.
    - FR-8.3.2: Notify the integrating app when new devices come into range even when the app is not in the foreground, using appropriate iOS background modes like bluetooth-central.

- ✅ FR-8.4: Processing of Advertisement Data:
    - ✅ FR-8.4.1: Extract and make available manufacturing data from advertisement packets to the integrating app.
    - ✅ FR-8.4.2: Allow the integrating app to parse this data, potentially providing callbacks or data structures for easy access to specific fields like manufacturer-specific data.

-  FR-8.5: Unique Identifier from Manufacturing Data:
    - FR-8.5.1: Provide an option for the integrating app to process manufacturing data to derive a unique identifier for each peripheral.
    - FR-8.5.2: Include an API method or property where the integrating app can return this identifier back to the library for more accurate peripheral identification and management.
    - FR-8.5.3: Once identified, maintain this mapping of the unique identifier to the peripheral's BLE address or other identifying characteristics to ensure consistent tracking across sessions or reconnections.


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
    - Security events (e.g., encryption initiation or failure)
    - Data chunking operations


10. Service and Characteristic Discovery and Management:

The layer between establishing a connection (FR-3, FR-5) and reading or writing data
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

- FR-10.1: Service Discovery:
    - FR-10.1.1: Provide an API to discover services on a connected peripheral, requiring the integrating app to declare the specific service UUIDs of interest. Do not expose unfiltered "discover all services" as the default path — Apple explicitly discourages it because enumerating an entire remote GATT table negatively affects battery life and time-to-ready.
    - FR-10.1.2: Support both automatic discovery on connection and explicit, on-demand discovery. The integrating app must declare the desired service/characteristic UUID set that discovery targets; this declaration is supplied at or around connection (e.g., via `connect` options and/or a sticky per-peripheral registration on the manager) and/or as configuration defaults. The exact API surface is finalized in implementation, but the declaration is mandatory: if automatic discovery is requested with no declared UUID set, that is a hard error (fail-closed), not a silent leave-not-ready — consistent with the "no unfiltered default" rule (FR-10.1.1).
    - FR-10.1.3: Expose discovered services to the integrating app as Sendable value snapshots keyed by peripheral identifier (per the identity model in FR-10.6.2) and service UUID (CBUUID), mirroring the existing peripheral-snapshot pattern. Never surface live CoreBluetooth objects.

- FR-10.2: Characteristic and Descriptor Discovery:
    - FR-10.2.1: Provide an API to discover characteristics for a discovered service, allowing the integrating app to declare the characteristic UUIDs of interest. Enforce CoreBluetooth's ordering constraint: services are discovered before characteristics, and characteristics before descriptors.
    - FR-10.2.2: Track per-service discovery completion, correctly handling the separate completion callback fired for each service, and drive the peripheral to the *ready* state (FR-10.3) only once all requested discoveries have completed.
    - FR-10.2.3: Optionally discover descriptors for a characteristic on demand. Descriptor discovery is not required to enable notifications (see FR-10.4.1).
    - FR-10.2.4: Expose discovered characteristics as Sendable value snapshots including metadata: UUID (CBUUID), properties (read, write, write-without-response, notify, indicate), and, when discovered, descriptors.

- FR-10.3: Discovery Lifecycle and Readiness:
    - FR-10.3.1: Model discovery as an explicit, per-peripheral state machine driven entirely by delegate callbacks. Never assume synchronous availability of services or characteristics after initiating discovery.
    - FR-10.3.2: Expose discovery/readiness state through a feed distinct from the connection-state stream (FR-1.3.1 / `ConnectionState`), so that connection-recovery observability (a library strength) and GATT readiness are not conflated. Readiness must be observable and awaitable (e.g., a discovery/readiness state stream and/or an awaitable ready signal), reporting progress, completion, and errors. `connected` must never be presented to the app as `ready`.
    - FR-10.3.3: Enforce a configurable discovery timeout so that a stalled or interrupted discovery surfaces as an error rather than an indefinite wait.
    - FR-10.3.4: Handle interrupted or partial discovery: if a peripheral disconnects mid-discovery, treat it as a hard reset of the discovery state — discard partial results and any pending discovery bookkeeping — and re-run discovery on the next connection (see FR-10.6.1). On unexpected disconnect, the app-visible discovery snapshot must be invalidated (cleared, or marked stale until the next ready) with explicit, documented timing, matching the existing peripheral-snapshot refresh philosophy.
    - FR-10.3.5: Partial-discovery policy is fail-closed. If a declared (required) service or characteristic UUID is absent — narrow filter, wrong firmware, or a stale cache — discovery is a failure: the peripheral does not become ready and the missing UUID(s) are reported. Map non-nil errors from each discovery callback into the library's error type, distinguishing common causes where feasible (e.g., missing-UUID versus disconnection during discovery).
    - FR-10.3.6: Readiness is an enforced gate, not merely an observable signal. Characteristic I/O and command execution (FR-4, and any future read/write/notify API) against a peripheral must wait until it is ready for the targeted UUIDs: await readiness (bounded by the FR-10.3.3 timeout) while discovery is pending or in progress, and fail fast if discovery has already failed. The full command-queue behavior that consumes this gate is specified in FR-4/FR-5 (out of scope here); this requirement only fixes the gate contract those layers must honor.

- FR-10.4: Characteristic Subscription Management (Notify/Indicate):
    - FR-10.4.1: Provide an API to enable and disable notifications or indications on a characteristic using the platform's subscribe mechanism. Never write the Client Characteristic Configuration Descriptor (CCCD, 0x2902) directly — CoreBluetooth manages the CCCD write internally and forbids writing it directly.
    - FR-10.4.2: Confirm the subscription state-change callback before treating a subscription as active, and sequence subscription-enable before issuing any command that causes the peripheral to emit data, so that initial notifications are not lost. Where a peripheral's readiness depends on active subscriptions, re-subscribe (FR-10.4.5) must complete before the readiness gate (FR-10.3.6) is released for notification-dependent work.
    - FR-10.4.3: Expose subscription state and its changes to the integrating app. Do not rely solely on the platform's `isNotifying` flag, which can lag the actual state.
    - FR-10.4.4: Notifications are unacknowledged at the GATT layer and may be lost or reordered above the link layer; application-layer framing/sequencing of multi-packet notification streams is out of scope for this section and handled per FR-7 (chunking and reassembly) and the command protocol (FR-4).
    - FR-10.4.5: The library tracks requested subscription intent per characteristic. After reconnection, state restoration (FR-10.6.3), or `didModifyServices` re-discovery (FR-10.5.1), previously requested subscriptions must be re-armed — or explicitly reported as inactive for the app to re-request. Re-discovery alone does not restore notify/indicate intent, and notify-only integrations (FR-4.2.1) break without this.

- FR-10.5: GATT Cache Invalidation and Re-discovery:
    - FR-10.5.1: On a peripheral GATT-table change (the `didModifyServices` callback), detection alone is insufficient. The library must immediately mark the peripheral *not ready* (re-gating work per FR-10.3.6), park or fail any in-flight discovery-dependent I/O, re-run discovery for the affected (or all declared) services, return to *ready* only after that completes, re-arm subscription intent (FR-10.4.5), and surface the event on the discovery/readiness stream.
    - FR-10.5.2: Treat reconnection following a peripheral firmware update or DFU as requiring full re-discovery; do not trust a previously cached view of services and characteristics.
    - FR-10.5.3: Document the iOS OS-level GATT caching limitation: there is no public API to clear the cache. Reliable cross-connection refresh requires the peripheral to implement the Service Changed characteristic (0x2A05) within the Generic Attribute Service (0x1801) and to bond; otherwise the only fallback is user-driven (toggle Bluetooth, or "Forget This Device"). This is a peripheral-firmware responsibility that the library cannot fully control, and the limitation must be communicated to integrating apps.

- FR-10.6: Reconnection, State Restoration, and Stale-Reference Handling:
    - FR-10.6.1: Re-discover services and characteristics on every new connection. Never reuse a service or characteristic reference obtained from a prior connection. Re-discovery is part of returning to the *ready* state (FR-10.3.6): a re-established link is not sufficient to resume characteristic I/O until discovery completes (see FR-1.2).
    - FR-10.6.2: Internally discard all live CoreBluetooth service/characteristic references on disconnect and reset the discovery state. The app-facing catalog must be keyed by the library's peripheral identity model (`Peripheral.id`, which resolves name → localName → `cbIdentifier`), not by held CoreBluetooth objects and not by `cbIdentifier` alone — so discovery keys stay consistent with the rest of the library. (Stable identity from manufacturer data, FR-8.5, is still open; this keying must adopt whatever FR-8.5 settles on.) This is consistent with the library's existing invalidation/refresh behavior on Bluetooth power cycling.
    - FR-10.6.3: On CoreBluetooth central state restoration (`willRestoreState`), re-associate the restored peripherals, discard any prior discovery catalog, re-run discovery for peripherals the app still intends to use, and re-apply subscription intent (FR-10.4.5). A restored link is not ready: the same readiness gate (FR-10.3.6) as a fresh connection applies.


### Non-Functional Requirements

1. Modern Swift 6 Architecture:

- ✅ NFR-1.1: Use Swift 6 language features like concurrency with async/await for handling BLE operations.
- ✅ NFR-1.2: Adhere to Swift best practices like protocol-oriented programming and value types where feasible.


2. High Test Coverage:

- ✅ NFR-2.1: Write unit tests for all public API methods, covering at least 80% of code paths.
- ✅ NFR-2.2: Use mocking or simulation for BLE peripherals to facilitate testing in CI environments.
- NFR-2.3: Implement integration tests to verify the system's behavior in real-world scenarios, including multi-device connections, security modes, and data chunking.

3. Performance:

- NFR-3.1: Ensure low latency in command execution and response handling to meet real-time application needs.
- NFR-3.2: Optimize for battery life on iOS devices by minimizing unnecessary BLE activity.


4. Scalability and Maintainability:

- NFR-4.1: Design with future extensibility in mind, allowing easy addition of new command types or security protocols.
- NFR-4.2: Ensure clear separation of concerns by modularizing code into components for BLE management and security.


5. Documentation:

- NFR-5.1: Provide comprehensive documentation for all public APIs, including usage examples, parameters, return values, error handling, and specifics on command types and data chunking.


6. Compatibility:

- NFR-6.1: Ensure compatibility with the latest iOS versions and CoreBluetooth API changes.
- NFR-6.2: Consider backward compatibility where it does not compromise security or performance.


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


