import Foundation
import simd

enum RecordingTask: String, CaseIterable {
    case none = "Not Recording"
    case staticTest = "Static Test"
    case dynamicTest = "Dynamic Test"
}

struct EstimatorStatus {
    let connectedAnchors: Int
    let rangingAnchors: Int
    let latestPosition: simd_double2?
    let overallConfidence: Double?
}

// Protocol to communicate back to the presenting ViewController
protocol RecordingSetupDelegate: AnyObject {
    func didRequestStartRecording(task: RecordingTask)
    func didRequestStopRecording(task: RecordingTask)
    func getCurrentRecordingState() -> (isRecording: Bool, task: RecordingTask, startTime: Date?)
    func prepareStaticTestSession(context: StaticTestSessionContext)
    func getEstimatorStatus() -> EstimatorStatus
    func getMostRecentCompletedSession() -> RecordedSession?
}
