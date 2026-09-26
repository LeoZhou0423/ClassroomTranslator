import Foundation

/// PSY-02：把系统/底层抛出的错误翻译成"人话 + 可执行下一步"，
/// 避免 `error.localizedDescription` 直接砸给用户（例如
/// "The operation couldn't be completed. (Swift.CancellationError error 1.)"）。
///
/// 返回 nil 表示没有专门文案，调用方再退回 error.localizedDescription。
/// 纯逻辑、无副作用，便于单测（Tests/ClassroomTranslatorTests/RecordingErrorPhraserTests.swift）。
enum RecordingErrorPhraser {
    static func humanMessage(for error: Error) -> String? {
        if error is CancellationError { return supersededMessage }

        if let startupError = error as? RecordingStartupStep.StartupError {
            switch startupError {
            case .timedOut:
                return String(localized: "Recording took too long to start. Another app may be using the microphone. Stop it and try again.")
            }
        }

        if let speechError = error as? SpeechError {
            switch speechError {
            case .startSuperseded:
                return supersededMessage
            case .noInputDevice, .invalidFormat, .requestCreationFailed, .engineStartFailed:
                return String(localized: "Failed to start recording. Please check the microphone and try again.")
            case .recognizerUnavailable:
                return String(localized: "Speech recognition is unavailable on this device.")
            case .permissionDeniedSpeech:
                return String(localized: "Speech recognition permission was denied.")
            case .permissionDeniedMic:
                return String(localized: "Microphone permission was denied.")
            case .startInProgress:
                return String(localized: "The previous recording is still starting. Please wait.")
            }
        }

        if let engineError = error as? AudioEngineError {
            switch engineError {
            case .noInputDevice:
                return String(localized: "No microphone or audio input device was found.")
            case .recognizerUnavailable:
                return String(localized: "Speech recognition is unavailable on this device.")
            case .startFailed, .formatUnavailable:
                return String(localized: "Failed to start recording. Please check the microphone and try again.")
            }
        }

        // 兜底：某些路径会把 CancellationError 包装一层，描述里仍带类型名。
        if String(reflecting: type(of: error)).contains("CancellationError") {
            return supersededMessage
        }
        return nil
    }

    private static var supersededMessage: String {
        String(localized: "The recording was stopped before it finished starting.")
    }
}
