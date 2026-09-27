import CoreML
import Foundation

/// Loads Core ML resources copied by SwiftPM. Source `.mlpackage` resources
/// must be compiled before `MLModel(contentsOf:)` can open them in an installed app.
enum BundledMLModelLoader {
    static func load(
        resource name: String,
        bundle: Bundle,
        configuration: MLModelConfiguration
    ) -> MLModel? {
        let sourceURL = bundle.url(forResource: name, withExtension: "mlmodelc")
            ?? bundle.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Resources")
            ?? bundle.url(forResource: name, withExtension: "mlpackage")
            ?? bundle.url(forResource: name, withExtension: "mlpackage", subdirectory: "Resources")
        guard let sourceURL else {
            StartupLog.mark("mlmodel.missing name=\(name)")
            return nil
        }

        do {
            let loadURL: URL
            if sourceURL.pathExtension == "mlmodelc" {
                loadURL = sourceURL
            } else {
                loadURL = try MLModel.compileModel(at: sourceURL)
            }
            let model = try MLModel(contentsOf: loadURL, configuration: configuration)
            StartupLog.mark("mlmodel.ready name=\(name)")
            return model
        } catch {
            StartupLog.mark("mlmodel.load-failed name=\(name) error=\(error.localizedDescription)")
            return nil
        }
    }
}
