import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import Network

/// App-lifetime effects. Tests exercise the policy without taking a real power
/// assertion, registering a login item, or bringing up a tailnet node.
@MainActor
final class PhoneReachabilityService: ObservableObject {
    static let shared = PhoneReachabilityService()
    @Published private(set) var power: PhoneReachabilityPolicy.Power = .unknown
    @Published private(set) var assertionActive = false
    @Published private(set) var assertionError: String?
    private var assertion: IOPMAssertionID = 0
    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var monitor: NWPathMonitor?
    private var subscription: AnyCancellable?
    private var timer: Task<Void, Never>?
    private weak var phone: TailscalePhoneAccessService?

    func start(phone: TailscalePhoneAccessService, startAtLogin: Bool) {
        guard subscription == nil else { return }
        self.phone = phone
        LoginItemService.shared.setPhoneAccessRequired(phone.enabled, generalPreference: startAtLogin)
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<PhoneReachabilityService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in service.refreshPower() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        subscription = phone.$enabled.sink { [weak self] enabled in
            // Published emits before the stored property changes; use its value.
            self?.refreshPower(enabled: enabled)
            LoginItemService.shared.setPhoneAccessRequired(enabled)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recover() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.recover() }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "ai.osaurus.phone-reachability"))
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.recover()
            }
        }
    }

    private func recover() {
        refreshPower()
        phone?.checkHealth()
    }

    private func refreshPower(enabled: Bool? = nil) {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            switch source as String {
            case kIOPSACPowerValue: power = .ac
            case kIOPSBatteryPowerValue: power = .battery
            default: power = .unknown
            }
        } else { power = .unknown }
        let needed = PhoneReachabilityPolicy.preventsIdleSleep(phoneEnabled: enabled ?? phone?.enabled ?? false, power: power)
        if needed && !assertionActive {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Keep Osaurus reachable from the phone while on AC power" as CFString, &assertion
            )
            assertionActive = result == kIOReturnSuccess
            assertionError = assertionActive ? nil : "Idle sleep assertion failed (IOKit \(result))."
        } else if !needed { releaseAssertion() }
    }

    private func releaseAssertion() {
        if assertionActive { IOPMAssertionRelease(assertion) }
        assertionActive = false; assertionError = nil; assertion = 0
    }

    func stop() {
        timer?.cancel(); timer = nil
        subscription?.cancel(); subscription = nil
        monitor?.cancel(); monitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        phone = nil
        releaseAssertion()
    }
}
