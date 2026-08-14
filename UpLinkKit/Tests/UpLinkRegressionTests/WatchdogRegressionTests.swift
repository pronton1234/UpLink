import Testing
import Foundation
@testable import UpLinkKit

@Suite("Regression: Wi-Fi watchdog")
struct WatchdogRegressionTests {

    // SYMPTOM: the user connects the Mac to the iPhone's Personal Hotspot and
    // starts the bridge. macOS now sees a perfectly satisfied Wi-Fi path — the
    // hotspot itself — so two minutes later the app helpfully suggests
    // disconnecting the phone to save battery, about the very link it is
    // bridging over. The notification is not just useless, it is wrong.
    @Test("The link being bridged over never counts as an alternative network")
    func bridgingHotspotIsNotAnAlternative() {
        var watchdog = WifiWatchdog(bridgeInterfaceName: "en0")
        _ = watchdog.setBridgeActive(true)

        let hotspot = WatchdogPath(hasSatisfiedWifi: true, wifiInterfaceName: "en0")

        let action = watchdog.handle(hotspot)
        #expect(action == .none)
        #expect(watchdog.isTimerRunning == false)
    }

    // The flip side: a genuinely different network must still fire, or the
    // exclusion above has silently disabled the whole feature.
    @Test("A different Wi-Fi interface does start the countdown")
    func genuineAlternativeStartsTimer() {
        var watchdog = WifiWatchdog(bridgeInterfaceName: "en0")
        _ = watchdog.setBridgeActive(true)

        let officeWifi = WatchdogPath(hasSatisfiedWifi: true, wifiInterfaceName: "en1")

        let action = watchdog.handle(officeWifi)
        #expect(action == .startTimer)
        #expect(watchdog.isTimerRunning)
    }

    // SYMPTOM: the user walks out of Wi-Fi range while the countdown is
    // running. The timer is never invalidated, so two minutes later they get a
    // notification recommending they switch to a network that is no longer
    // there.
    @Test("Losing the Wi-Fi path cancels the countdown immediately")
    func pathLossCancelsTimer() {
        var watchdog = WifiWatchdog(bridgeInterfaceName: "en0")
        _ = watchdog.setBridgeActive(true)
        _ = watchdog.handle(WatchdogPath(hasSatisfiedWifi: true, wifiInterfaceName: "en1"))

        let action = watchdog.handle(WatchdogPath(hasSatisfiedWifi: false))
        #expect(action == .cancelTimer)
        #expect(watchdog.isTimerRunning == false)
        let fired = watchdog.timerFired()
        #expect(fired == false)
    }

    // SYMPTOM: the user disconnects the bridge while the countdown runs, and is
    // then told to disconnect a bridge that is already down.
    @Test("Disconnecting the bridge cancels the countdown")
    func disconnectingCancelsTimer() {
        var watchdog = WifiWatchdog(bridgeInterfaceName: "en0")
        _ = watchdog.setBridgeActive(true)
        _ = watchdog.handle(WatchdogPath(hasSatisfiedWifi: true, wifiInterfaceName: "en1"))

        let action = watchdog.setBridgeActive(false)
        #expect(action == .cancelTimer)
        let fired = watchdog.timerFired()
        #expect(fired == false)
    }

    // The spec is explicit that the watchdog performs zero background
    // evaluation while the bridge is off.
    @Test("No countdown starts while the bridge is off")
    func idleWhileBridgeOff() {
        var watchdog = WifiWatchdog(bridgeInterfaceName: "en0")
        let anyWifi = WatchdogPath(hasSatisfiedWifi: true, wifiInterfaceName: "en1")

        let action = watchdog.handle(anyWifi)
        #expect(action == .none)
        #expect(watchdog.isTimerRunning == false)
    }

    // SYMPTOM: a hotel captive portal presents a satisfied Wi-Fi path with no
    // actual internet, and the app recommends switching to it.
    @Test("A constrained or captive network is not offered as an alternative")
    func constrainedNetworkIsNotAnAlternative() {
        var watchdog = WifiWatchdog(bridgeInterfaceName: "en0")
        _ = watchdog.setBridgeActive(true)

        let captive = WatchdogPath(hasSatisfiedWifi: true, wifiInterfaceName: "en1", isConstrained: true)

        let action = watchdog.handle(captive)
        #expect(action == .none)
    }

    // SYMPTOM: every path update restarts the countdown, so on a network that
    // reports frequently the two minutes never elapse and the notification
    // never arrives.
    @Test("Repeated identical path updates do not restart the countdown")
    func repeatedUpdatesDoNotRestartTimer() {
        var watchdog = WifiWatchdog(bridgeInterfaceName: "en0")
        _ = watchdog.setBridgeActive(true)

        let wifi = WatchdogPath(hasSatisfiedWifi: true, wifiInterfaceName: "en1")
        let first = watchdog.handle(wifi)
        #expect(first == .startTimer)

        for _ in 0 ..< 20 {
            let repeated = watchdog.handle(wifi)
            #expect(repeated == .none)
        }
        let fired = watchdog.timerFired()
        #expect(fired)
    }

    @Test("The notification fires only once per qualifying stretch")
    func notificationIsNotRepeated() {
        var watchdog = WifiWatchdog(bridgeInterfaceName: "en0")
        _ = watchdog.setBridgeActive(true)
        _ = watchdog.handle(WatchdogPath(hasSatisfiedWifi: true, wifiInterfaceName: "en1"))

        let first = watchdog.timerFired()
        #expect(first)
        let second = watchdog.timerFired()
        #expect(second == false)
    }
}
