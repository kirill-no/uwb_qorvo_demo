import Foundation
import simd

// MARK: - Recording Data Structures

struct StaticTestSessionContext {
    let markerName: String
    let groundTruth: simd_double2
    let areaSizeMeters: simd_double2
    let captureDuration: TimeInterval
    let phoneHeightMeters: Double
    let instructions: String
}

struct AnchorMeasurementSnapshot {
    let anchorName: String
    let anchorUUID: String
    let configuredX: Double
    let configuredY: Double
    let rawDistance: Double?
    let smoothedDistance: Double?
    let planarDistance: Double?
    let confidence: Double
    let residual: Double?
}

struct RecordedDataPoint {
    let timestamp: TimeInterval
    let task: RecordingTask
    
    // Raw trilaterated position
    let rawX: Double?
    let rawY: Double?
    
    // Filtered position
    let filteredX: Double?
    let filteredY: Double?
    
    // Estimator quality
    let measurementStdDev: Double?
    let overallConfidence: Double?
    
    // Per-anchor snapshots for post-analysis
    let anchorSnapshots: [AnchorMeasurementSnapshot]
}

struct RecordedSession {
    let id: UUID
    let task: RecordingTask
    let startTime: Date
    let endTime: Date
    let staticContext: StaticTestSessionContext?
    var dataPoints: [RecordedDataPoint]
    
    var duration: TimeInterval {
        return endTime.timeIntervalSince(startTime)
    }
    
    var sessionTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        if let staticContext {
            return "\(task.rawValue) - \(staticContext.markerName) - \(formatter.string(from: startTime))"
        }
        return "\(task.rawValue) - \(formatter.string(from: startTime))"
    }

    func generateCSV() -> String {
        let maxAnchors = max(dataPoints.map(\.anchorSnapshots.count).max() ?? 0, 3)
        var headers = [
            "timestamp",
            "task",
            "markerName",
            "groundTruthX",
            "groundTruthY",
            "rawX",
            "rawY",
            "filteredX",
            "filteredY",
            "measurementStdDev",
            "overallConfidence"
        ]
        for index in 0..<maxAnchors {
            let prefix = "anchor\(index + 1)"
            headers.append(contentsOf: [
                "\(prefix)Name",
                "\(prefix)UUID",
                "\(prefix)ConfiguredX",
                "\(prefix)ConfiguredY",
                "\(prefix)RawDistance",
                "\(prefix)SmoothedDistance",
                "\(prefix)PlanarDistance",
                "\(prefix)Confidence",
                "\(prefix)Residual"
            ])
        }
        
        var csvString = headers.joined(separator: ",") + "\n"
        let markerName = staticContext?.markerName ?? "N/A"
        let gtX = staticContext.map { String(format: "%.4f", $0.groundTruth.x) } ?? "N/A"
        let gtY = staticContext.map { String(format: "%.4f", $0.groundTruth.y) } ?? "N/A"
        
        for point in dataPoints {
            var row = [
                String(format: "%.4f", point.timestamp),
                task.rawValue,
                markerName,
                gtX,
                gtY,
                point.rawX.map { String(format: "%.4f", $0) } ?? "N/A",
                point.rawY.map { String(format: "%.4f", $0) } ?? "N/A",
                point.filteredX.map { String(format: "%.4f", $0) } ?? "N/A",
                point.filteredY.map { String(format: "%.4f", $0) } ?? "N/A",
                point.measurementStdDev.map { String(format: "%.4f", $0) } ?? "N/A",
                point.overallConfidence.map { String(format: "%.4f", $0) } ?? "N/A"
            ]
            
            let snapshots = point.anchorSnapshots.sorted { $0.anchorName < $1.anchorName }
            for index in 0..<maxAnchors {
                if index < snapshots.count {
                    let snapshot = snapshots[index]
                    row.append(contentsOf: [
                        snapshot.anchorName,
                        snapshot.anchorUUID,
                        String(format: "%.4f", snapshot.configuredX),
                        String(format: "%.4f", snapshot.configuredY),
                        snapshot.rawDistance.map { String(format: "%.4f", $0) } ?? "N/A",
                        snapshot.smoothedDistance.map { String(format: "%.4f", $0) } ?? "N/A",
                        snapshot.planarDistance.map { String(format: "%.4f", $0) } ?? "N/A",
                        String(format: "%.4f", snapshot.confidence),
                        snapshot.residual.map { String(format: "%.4f", $0) } ?? "N/A"
                    ])
                } else {
                    row.append(contentsOf: Array(repeating: "N/A", count: 9))
                }
            }
            
            csvString.append(row.joined(separator: ",") + "\n")
        }
        return csvString
    }
}
