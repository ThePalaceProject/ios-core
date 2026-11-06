//
//  ActivityPolicyTests.swift
//  PalaceTests
//
//  ActivityPolicy (PP-5508): inputs, tick re-arming, off-main notification
//  delivery, and ownership. Uses a private NotificationCenter and a fake
//  scheduler; no singletons.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class ActivityPolicyTests: XCTestCase {

    // MARK: - Fakes

    /// Records each arm and lets the test fire a specific arm by index.
    private final class FakeTickScheduler: ActivityTickScheduling, @unchecked Sendable {
        private(set) var armedIntervals: [TimeInterval] = []
        private var subjects: [PassthroughSubject<Date, Never>] = []

        func ticks(every interval: TimeInterval) -> AnyPublisher<Date, Never> {
            armedIntervals.append(interval)
            let subject = PassthroughSubject<Date, Never>()
            subjects.append(subject)
            return subject.eraseToAnyPublisher()
        }

        func fire(arm index: Int) {
            subjects[index].send(Date(timeIntervalSince1970: TimeInterval(index)))
        }
    }

    /// Thread-safe box for the thermal / Low Power values the policy reads.
    private final class DeviceConditions: @unchecked Sendable {
        private let lock = NSLock()
        private var _thermal: ProcessInfo.ThermalState = .nominal
        private var _lowPower = false
        var thermal: ProcessInfo.ThermalState {
            get { lock.withLock { _thermal } }
            set { lock.withLock { _thermal = newValue } }
        }
        var lowPower: Bool {
            get { lock.withLock { _lowPower } }
            set { lock.withLock { _lowPower = newValue } }
        }
    }

    private var center: NotificationCenter!
    private var scheduler: FakeTickScheduler!
    private var conditions: DeviceConditions!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        scheduler = FakeTickScheduler()
        conditions = DeviceConditions()
    }

    override func tearDown() {
        cancellables.removeAll()
        center = nil
        scheduler = nil
        conditions = nil
        super.tearDown()
    }

    private func makeSUT() -> ActivityPolicy {
        let conditions = self.conditions!
        return ActivityPolicy(
            notificationCenter: center,
            thermalState: { conditions.thermal },
            isLowPowerModeEnabled: { conditions.lowPower },
            scheduler: scheduler
        )
    }

    /// Waits until the policy publishes a state matching `predicate`.
    private func waitForState(
        of policy: ActivityPolicy,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        where predicate: @escaping (ActivityState) -> Bool
    ) {
        let reached = expectation(description: description)
        reached.assertForOverFulfill = false
        let subscription = policy.statePublisher.sink { state in
            if predicate(state) { reached.fulfill() }
        }
        wait(for: [reached], timeout: 5)
        subscription.cancel()
    }

    // MARK: - Initial state

    func testInit_readsThermalAndLowPowerOnce_andStartsInBackgroundWithNoPlayer() {
        conditions.thermal = .critical
        conditions.lowPower = true

        let policy = makeSUT()

        XCTAssertEqual(policy.state, ActivityState(
            scene: .background, carPlayConnected: false, protectedDataAvailable: true,
            thermal: .critical, lowPowerMode: true, player: .none
        ))
        XCTAssertEqual(policy.ambientSync(), .deferUntilVisible)
    }

    // MARK: - Setters

    func testSetters_updateTheMatchingField_andDecisionsFollow() {
        let policy = makeSUT()

        policy.setScene(.inactive)
        XCTAssertEqual(policy.state.scene, .inactive)
        XCTAssertEqual(policy.ambientSync(), .runNow)

        policy.setScene(.background)
        XCTAssertEqual(policy.ambientSync(), .deferUntilVisible)

        policy.setCarPlayConnected(true)
        XCTAssertTrue(policy.state.carPlayConnected)
        XCTAssertEqual(policy.ambientSync(), .runNow)

        policy.setCarPlayConnected(false)
        XCTAssertEqual(policy.ambientSync(), .deferUntilVisible)

        policy.setScene(.active)
        policy.setPlayer(.expanded)
        XCTAssertEqual(policy.state.player, .expanded)
        XCTAssertEqual(policy.interval(for: .uiTick), 0.2)

        policy.setPlayer(.hidden)
        XCTAssertNil(policy.interval(for: .uiTick))
    }

    func testProtectedDataNotifications_toggleProtectedDataAvailable() {
        let policy = makeSUT()

        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        waitForState(of: policy, "locked") { !$0.protectedDataAvailable }

        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        waitForState(of: policy, "unlocked") { $0.protectedDataAvailable }
    }

    // MARK: - ticks(for:)

    func testTicks_reArmOnIntervalChange_andStopOnNil() {
        conditions.lowPower = true
        let policy = makeSUT()
        var received: [Date] = []
        policy.ticks(for: .housekeeping).sink { received.append($0) }.store(in: &cancellables)

        // Background: housekeeping is off, so nothing is armed.
        XCTAssertEqual(scheduler.armedIntervals, [])

        policy.setScene(.active)
        XCTAssertEqual(scheduler.armedIntervals, [120])
        scheduler.fire(arm: 0)
        XCTAssertEqual(received.count, 1)

        // An input that does not change the interval does not re-arm.
        policy.setCarPlayConnected(true)
        XCTAssertEqual(scheduler.armedIntervals, [120])

        conditions.lowPower = false
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        waitForState(of: policy, "low power off") { !$0.lowPowerMode }
        XCTAssertEqual(scheduler.armedIntervals, [120, 60])

        scheduler.fire(arm: 0)
        XCTAssertEqual(received.count, 1, "the replaced arm must not deliver")
        scheduler.fire(arm: 1)
        XCTAssertEqual(received.count, 2)

        policy.setCarPlayConnected(false)
        policy.setScene(.background)
        scheduler.fire(arm: 1)
        XCTAssertEqual(received.count, 2, "nothing is delivered while the interval is nil")
        XCTAssertEqual(scheduler.armedIntervals, [120, 60])

        policy.setScene(.active)
        XCTAssertEqual(scheduler.armedIntervals, [120, 60, 60], "leaving nil re-arms")
    }

    // MARK: - Off-main notifications

    func testThermalNotificationPostedOffMain_updatesStateOnMain() {
        let policy = makeSUT()
        var deliveredOnMain: [Bool] = []
        policy.statePublisher.dropFirst().sink { _ in deliveredOnMain.append(Thread.isMainThread) }
            .store(in: &cancellables)
        conditions.thermal = .serious
        let center = self.center!

        DispatchQueue.global(qos: .utility).async {
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }

        waitForState(of: policy, "thermal serious") { $0.thermal == .serious }
        XCTAssertEqual(deliveredOnMain, [true])
    }

    func testLowPowerNotificationPostedOffMain_updatesStateOnMain() {
        let policy = makeSUT()
        conditions.lowPower = true
        let center = self.center!

        DispatchQueue.global(qos: .utility).async {
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }

        waitForState(of: policy, "low power on") { $0.lowPowerMode }
        XCTAssertEqual(policy.interval(for: .housekeeping), nil, "still background")
        policy.setScene(.active)
        XCTAssertEqual(policy.interval(for: .housekeeping), 120)
    }

    // MARK: - Ownership

    /// Stand-in for the presenter: it holds the policy, pushes into it and
    /// consumes its ticks. Releasing it must free it (no cycle through the policy).
    private final class PolicyClient {
        let policy: ActivityPolicy
        var cancellable: AnyCancellable?
        var ticks = 0
        @MainActor init(policy: ActivityPolicy) {
            self.policy = policy
            cancellable = policy.ticks(for: .housekeeping).sink { [weak self] _ in self?.ticks += 1 }
            policy.setPlayer(.mini)
        }
    }

    func testPolicy_holdsNoStrongReferenceToItsClients_andIsFreedWhenReleased() {
        weak var weakClient: PolicyClient?
        weak var weakPolicy: ActivityPolicy?
        do {
            let policy = makeSUT()
            let client = PolicyClient(policy: policy)
            policy.setScene(.active)
            weakClient = client
            weakPolicy = policy
            XCTAssertEqual(scheduler.armedIntervals, [60])
        }
        XCTAssertNil(weakClient, "the policy must not keep a client alive")
        XCTAssertNil(weakPolicy, "notification and tick pipelines must not retain the policy")
    }

    // MARK: - SceneDelegate wiring

    func testSceneDelegateCallbacks_pushTheSceneVisibilityIntoThePolicy() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first)
        let policy = makeSUT()
        let sceneDelegate = SceneDelegate()
        sceneDelegate.foregroundShelfSync = nil
        sceneDelegate.activityPolicy = policy

        let steps: [(String, (UIScene) -> Void, SceneVisibility)] = [
            ("willEnterForeground", sceneDelegate.sceneWillEnterForeground, .inactive),
            ("didBecomeActive", sceneDelegate.sceneDidBecomeActive, .active),
            ("willResignActive", sceneDelegate.sceneWillResignActive, .inactive),
            ("didEnterBackground", sceneDelegate.sceneDidEnterBackground, .background),
        ]
        for (name, callback, expected) in steps {
            callback(scene)
            XCTAssertEqual(policy.state.scene, expected, name)
        }
    }

    // MARK: - AppContainer

    /// The main scene and CarPlay resolve the policy through separate container
    /// reads; both must reach the same instance.
    func testAppContainer_handsOutOnePolicyPerProcess() {
        let first = makeTestAppContainer()
        let second = makeTestAppContainer()

        XCTAssertTrue(first.activityPolicy === second.activityPolicy)
    }
}
