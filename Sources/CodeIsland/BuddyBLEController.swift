import Foundation
import CoreBluetooth
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "BuddyBLE")

// Nordic UART Service UUIDs — match the buddy firmware. File-level so
// CoreBluetooth delegate callbacks (nonisolated) can read them without
// bouncing through MainActor.
private let NUS_SERVICE = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
private let NUS_RX      = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
private let NUS_TX      = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")

/// Mirrors the active agent state onto a claude-desktop-buddy BLE peripheral.
///
/// Protocol: the firmware listens for newline-terminated JSON on the Nordic
/// UART RX characteristic and parses fields `total` / `running` / `waiting` /
/// `entries` / `msg`. We synthesize heartbeat-shaped payloads so the firmware's
/// existing state machine reacts the same way it does to Claude Desktop's
/// heartbeats — no firmware change needed.
///
/// The firmware uses encrypted characteristics; CoreBluetooth reuses whatever
/// bond macOS already has from Claude Desktop's first pairing, so typically
/// no passkey prompt is shown again on this Mac.
@MainActor
@Observable
final class BuddyBLEController: NSObject {

    static let shared = BuddyBLEController()

    enum ConnectionState: Equatable {
        case disabled
        case poweringOn
        case scanning
        case connecting
        case connected
        case failed(String)
    }

    // Published state observed by SettingsView.
    private(set) var state: ConnectionState = .disabled
    private(set) var deviceName: String? = nil

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?

    private var enabled = false
    private var lastPayload: Data?
    private var rescanTask: Task<Void, Never>?

    /// Called on main actor when the buddy sends a button event over TX.
    /// The firmware emits lines like `{"cmd":"permission","id":"...","decision":"once"}`.
    var onButtonEvent: ((_ decision: String) -> Void)?

    // MARK: - Public API

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            if central == nil {
                // Lazy-init so Bluetooth permission prompt only fires when the
                // user actually turns this on, not on every app launch.
                central = CBCentralManager(delegate: self, queue: .main)
                state = .poweringOn
            } else {
                scanIfReady()
            }
        } else {
            teardown(setState: .disabled)
        }
    }

    /// Publish the current aggregate state to the buddy. Safe to call
    /// frequently — identical payloads are deduped before writing.
    func publish(status: AgentStatus, activeSessionCount: Int, toolName: String?) {
        guard enabled,
              let p = peripheral,
              let rx = rxChar,
              p.state == .connected else { return }

        var running = 0
        var waiting = 0
        var entries: [String] = []
        var msg = "idle"
        switch status {
        case .idle:
            msg = "idle"
        case .processing, .running:
            running = max(1, activeSessionCount)
            msg = "busy"
            entries = [toolName.map { "(using \($0))" } ?? "(busy)"]
        case .waitingApproval:
            waiting = 1
            msg = "waiting"
        case .waitingQuestion:
            waiting = 1
            msg = "question"
        }

        let payload: [String: Any] = [
            "total":   max(1, activeSessionCount),
            "running": running,
            "waiting": waiting,
            "entries": entries,
            "msg":     msg,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        let line = data + Data("\n".utf8)
        if line == lastPayload { return }
        lastPayload = line
        p.writeValue(line, for: rx, type: .withoutResponse)
    }

    // MARK: - Internals

    private func scanIfReady() {
        guard enabled, let c = central, c.state == .poweredOn, peripheral == nil else { return }
        log.info("scanning for Claude-*")
        state = .scanning
        deviceName = nil
        c.scanForPeripherals(withServices: [NUS_SERVICE], options: nil)
    }

    private func teardown(setState newState: ConnectionState) {
        rescanTask?.cancel()
        rescanTask = nil
        if let c = central {
            c.stopScan()
            if let p = peripheral { c.cancelPeripheralConnection(p) }
        }
        peripheral = nil
        rxChar = nil
        txChar = nil
        lastPayload = nil
        deviceName = nil
        state = newState
    }

    private func rescanAfterDelay(_ seconds: TimeInterval) {
        rescanTask?.cancel()
        rescanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.enabled, !Task.isCancelled else { return }
            self.scanIfReady()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BuddyBLEController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if self.enabled { self.scanIfReady() }
            case .poweredOff:
                self.state = .failed("Bluetooth off")
            case .unauthorized:
                self.state = .failed("Bluetooth permission denied")
            case .unsupported:
                self.state = .failed("Bluetooth unsupported")
            default:
                self.state = .poweringOn
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? ""
        guard name.hasPrefix("Claude-") else { return }
        Task { @MainActor in
            guard self.peripheral == nil else { return }
            central.stopScan()
            self.peripheral = peripheral
            self.deviceName = name
            self.state = .connecting
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.discoverServices([NUS_SERVICE])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            log.warning("connect failed: \(error?.localizedDescription ?? "nil")")
            self.peripheral = nil
            self.state = .failed(error?.localizedDescription ?? "connect failed")
            self.rescanAfterDelay(5)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            log.info("disconnected: \(error?.localizedDescription ?? "clean")")
            self.peripheral = nil
            self.rxChar = nil
            self.txChar = nil
            self.lastPayload = nil
            if self.enabled {
                self.state = .scanning
                self.rescanAfterDelay(1)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BuddyBLEController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let svc = peripheral.services?.first(where: { $0.uuid == NUS_SERVICE }) else {
                self.state = .failed("NUS service not found")
                return
            }
            peripheral.discoverCharacteristics([NUS_RX, NUS_TX], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                if c.uuid == NUS_RX { self.rxChar = c }
                if c.uuid == NUS_TX {
                    self.txChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            if self.rxChar != nil {
                log.info("connected to \(self.deviceName ?? "buddy", privacy: .public)")
                self.state = .connected
            } else {
                self.state = .failed("RX characteristic missing")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid == NUS_TX, let data = characteristic.value else { return }
        Task { @MainActor in
            // Firmware emits newline-delimited JSON; we may receive fragments
            // across notifies but a single button press fits in one notify.
            for chunk in data.split(separator: 0x0A) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any] else { continue }
                if let decision = obj["decision"] as? String {
                    log.info("buddy button: \(decision, privacy: .public)")
                    self.onButtonEvent?(decision)
                }
            }
        }
    }
}
