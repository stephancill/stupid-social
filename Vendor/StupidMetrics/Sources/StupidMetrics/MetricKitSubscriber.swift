#if canImport(MetricKit) && !os(tvOS) && !os(watchOS)
    import Foundation
    import MetricKit
    import os

    /// Receives MetricKit payloads (delivered at most daily, on device only) and
    /// hands their JSON to the engine to upload.
    final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
        private let engine: Engine

        /// MXMetricManager holds subscribers weakly.
        private static let retained = OSAllocatedUnfairLock<MetricKitSubscriber?>(initialState: nil)

        private init(engine: Engine) {
            self.engine = engine
        }

        static func start(engine: Engine) {
            let subscriber = MetricKitSubscriber(engine: engine)
            retained.withLock { $0 = subscriber }
            MXMetricManager.shared.add(subscriber)
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            upload(kind: "diagnostic", payloads.map { $0.jsonRepresentation() })
        }

        #if os(iOS) || os(visionOS)
            func didReceive(_ payloads: [MXMetricPayload]) {
                upload(kind: "metric", payloads.map { $0.jsonRepresentation() })
            }
        #endif

        private func upload(kind: String, _ payloads: [Data]) {
            guard StupidMetrics.isEnabled else { return }
            Task { [engine] in
                for json in payloads {
                    await engine.enqueueDiagnostic(kind: kind, json: json)
                }
                await engine.flush()
            }
        }
    }
#else
    enum MetricKitSubscriber {
        static func start(engine _: Engine) {}
    }
#endif
