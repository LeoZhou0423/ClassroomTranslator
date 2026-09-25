import XCTest
import AVFoundation
import Speech
@testable import ClassroomTranslator

final class SpeechStartupSmokeTests: XCTestCase {
    @MainActor
    func testStartChainAfterPermissionGrantsDoesNotCrash() async throws {
        StartupLog.mark("smoke.begin")
        print("[smoke] os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("[smoke] speech-auth=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic-auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        print("[smoke] input-device=\(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")")

        let installed = await DictationTranscriber.installedLocales
        print("[smoke] installed-locales=\(installed.map(\.identifier))")
        guard !installed.isEmpty else {
            StartupLog.mark("smoke.no-installed-locales")
            throw XCTSkip("runner has no installed dictation assets")
        }

        let manager = SpeechManager()
        manager.configureContext(courseName: "Machine Learning Systems and Algorithms")
        if let english = installed.first(where: { $0.identifier.hasPrefix("en") }) {
            manager.switchLanguage(to: english.identifier)
        } else {
            manager.switchLanguage(to: installed[0].identifier)
        }

        do {
            try await manager.startRecording()
            StartupLog.mark("smoke.recording-started")
            XCTAssertTrue(manager.isRecording)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            manager.stopRecording()
            XCTAssertFalse(manager.isRecording)
            StartupLog.mark("smoke.stop-ok")
        } catch let error as AudioEngineError {
            print("[smoke] audio-environment-limited: \(error.localizedDescription)")
            StartupLog.mark("smoke.audio-error: \(error.localizedDescription)")
            manager.stopRecording()
        } catch let error as SpeechError {
            manager.stopRecording()
            if case .noInputDevice = error {
                StartupLog.mark("smoke.no-input-device")
            } else {
                StartupLog.mark("smoke.unexpected-speech-error")
                XCTFail("Unexpected SpeechError: \(error.localizedDescription)")
            }
        } catch {
            manager.stopRecording()
            StartupLog.mark("smoke.unexpected-error: \(error)")
            XCTFail("Unexpected error: \(error)")
        }
        StartupLog.mark("smoke.end")
    }

    @MainActor
    func testAutoStartChainAfterPermissionGrantsDoesNotCrash() async throws {
        StartupLog.mark("smoke.auto-begin")
        let installed = await DictationTranscriber.installedLocales
        print("[smoke] auto installed-locales=\(installed.map(\.identifier))")
        guard installed.contains(where: { $0.identifier == "en-GB" }) else {
            StartupLog.mark("smoke.auto-skip")
            throw XCTSkip("runner lacks en-GB dictation asset")
        }

        let manager = SpeechManager()
        do {
            try await manager.startAutoDetectRecording()
            StartupLog.mark("smoke.auto-recording-started lang=\(manager.currentLanguageCode)")
            XCTAssertTrue(manager.isRecording)
            XCTAssertEqual(manager.currentLanguageCode, "en-GB")
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            manager.stopRecording()
            XCTAssertFalse(manager.isRecording)
            StartupLog.mark("smoke.auto-stop-ok")
        } catch let error as AudioEngineError {
            print("[smoke] auto audio-environment-limited: \(error.localizedDescription)")
            StartupLog.mark("smoke.auto-audio-error: \(error.localizedDescription)")
            manager.stopRecording()
        } catch let error as SpeechError {
            manager.stopRecording()
            if case .noInputDevice = error {
                StartupLog.mark("smoke.auto-no-input-device")
            } else {
                StartupLog.mark("smoke.auto-unexpected-speech-error")
                XCTFail("Unexpected SpeechError: \(error.localizedDescription)")
            }
        } catch {
            manager.stopRecording()
            StartupLog.mark("smoke.auto-unexpected-error: \(error)")
            XCTFail("Unexpected error: \(error)")
        }
        StartupLog.mark("smoke.auto-end")
    }
}
