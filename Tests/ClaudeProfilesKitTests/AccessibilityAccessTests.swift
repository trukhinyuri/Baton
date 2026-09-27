import Foundation
import Testing
@testable import ClaudeProfilesKit

@Suite("Contextual Accessibility permission flow")
@MainActor
struct AccessibilityAccessTests {
    @Test func constructionAndStatusChecksNeverPromptOrOpenSettings() {
        let probe = PermissionProbe()
        let controller = AccessibilityAccess.Controller(client: probe.client)
        #expect(controller.state.status == .unknown && probe.checks == 0)
        #expect(controller.refresh().status == .notGranted)
        #expect(probe.checks == 1 && probe.requests == 0 && probe.settingsOpens == 0)
    }

    @Test func asynchronousPromptIsNotMistakenForDenialOrGrant() {
        let probe = PermissionProbe()
        let controller = AccessibilityAccess.Controller(client: probe.client)
        let waiting = controller.requestAccess()
        #expect(waiting.status == .waitingForApproval && waiting.requested && !waiting.canCapture)
        #expect(probe.requests == 1)
        #expect(controller.refresh().status == .waitingForApproval)
        probe.allowed = true
        #expect(controller.refresh().canCapture)
        #expect(probe.requests == 1 && probe.settingsOpens == 0)
    }

    @Test func alreadyGrantedAccessDoesNotRequestAgain() {
        let probe = PermissionProbe(); probe.allowed = true
        let controller = AccessibilityAccess.Controller(client: probe.client)
        #expect(controller.requestAccess().canCapture)
        #expect(probe.requests == 0 && !controller.state.requested)
        probe.allowed = false
        #expect(!controller.refresh().canCapture)
    }

    @Test func sayingSettingsWasEnabledNeverOverridesTheOSCheck() {
        let probe = PermissionProbe()
        let controller = AccessibilityAccess.Controller(client: probe.client)
        #expect(controller.checkAfterSettingsChange().status == .notApplied)
        #expect(controller.refresh().status == .notApplied)
        #expect(probe.requests == 0)
        probe.allowed = true
        #expect(controller.checkAfterSettingsChange().canCapture)
    }

    @Test func captureDenialBlocksRetryUntilAccessIsCheckedAgain() {
        let probe = PermissionProbe(); probe.allowed = true
        let controller = AccessibilityAccess.Controller(client: probe.client)
        #expect(controller.refresh().canCapture)
        #expect(controller.recordCaptureDenied().status == .notApplied)
        #expect(!controller.state.canCapture)
        probe.allowed = false
        #expect(!controller.checkAfterSettingsChange().canCapture)
        #expect(probe.requests == 0)
    }

    @Test func settingsLaunchAndFailureDoNotRequestOrAssumePermission() {
        let probe = PermissionProbe(); probe.settingsCanOpen = false
        let controller = AccessibilityAccess.Controller(client: probe.client)
        #expect(controller.openSystemSettings().settingsOpenFailed)
        #expect(!controller.state.canCapture && probe.requests == 0 && probe.settingsOpens == 1)
        probe.settingsCanOpen = true
        #expect(!controller.openSystemSettings().settingsOpenFailed)
        #expect(!controller.state.canCapture)
    }

    @Test func cancelOnlyCancelsWaitingAndLaterGrantCanBeObserved() {
        let probe = PermissionProbe()
        let controller = AccessibilityAccess.Controller(client: probe.client)
        _ = controller.requestAccess()
        #expect(controller.cancelWaiting().status == .notGranted)
        #expect(!controller.state.requested && probe.requests == 1)
        probe.allowed = true
        #expect(controller.refresh().canCapture)
        #expect(controller.cancelWaiting().canCapture)
    }

    @Test func recoveryRevealsExactlyThisApplicationWithoutChangingPermission() {
        let probe = PermissionProbe()
        let controller = AccessibilityAccess.Controller(client: probe.client)
        controller.revealThisApplication()
        #expect(probe.revealed == [probe.applicationURL])
        #expect(controller.application.isAdHocSigned == true)
        #expect(probe.requests == 0 && probe.settingsOpens == 0 && probe.checks == 0)
    }

    @Test func recoveryNeverRevealsAnArbitraryNonApplicationURL() {
        let probe = PermissionProbe()
        var client = probe.client
        client.application.url = URL(fileURLWithPath: "/tmp/arbitrary-file")
        AccessibilityAccess.Controller(client: client).revealThisApplication()
        #expect(probe.revealed.isEmpty)
    }

    @Test func permissionPaneUsesObservedModernNameAndOlderSystemName() {
        #expect(AccessibilityAccess.settingsPaneName(macOSMajorVersion: 26) == "Accessibility")
        #expect(AccessibilityAccess.settingsPaneName(macOSMajorVersion: 27) == "Device Control and Data Access")
    }
}

@MainActor
private final class PermissionProbe {
    var allowed = false
    var settingsCanOpen = true
    var checks = 0, requests = 0, settingsOpens = 0
    var revealed: [URL] = []
    let applicationURL = URL(fileURLWithPath: "/Applications/Claude Profiles.app")
    var client: AccessibilityAccess.Client {
        .init(check: { self.checks += 1; return self.allowed },
              request: { self.requests += 1; return self.allowed },
              openSettings: { self.settingsOpens += 1; return self.settingsCanOpen },
              revealApplication: { self.revealed.append($0) },
              application: .init(name: "Claude Profiles", url: applicationURL, isAdHocSigned: true))
    }
}
