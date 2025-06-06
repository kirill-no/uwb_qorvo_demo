//
//  ViewController.swift
//  uwb_qorvo_demo
//
//  Created by Kirill on 02/06/2025.
//  Rewritten 03/06/2025 to drop QorvoNIManager and do everything in here.
//
import UIKit
import CoreBluetooth
import NearbyInteraction
import simd
import QuartzCore

// MARK: – Beacon UUIDs (the BLE peripheral identifiers for your DWM3001CDK boards)
let beacon1UUID = UUID(uuidString: "6392BD53-9B46-3623-ECD3-02FE919BD038")!
let beacon2UUID = UUID(uuidString: "A3F121FB-850A-381E-DD90-3726A57E6EBF")!
let beacon3UUID = UUID(uuidString: "67F74E81-1C3D-ED23-41E5-C6212723CB82")!
let targetBeaconUUIDs = [beacon1UUID, beacon2UUID, beacon3UUID]

// MARK: – Qorvo NI Service & Characteristic UUIDs
// When the DWM3001CDK is flashed with Qorvo NI demo firmware v.3.x,
// it advertises this service and exposes these characteristics.
//
// Source: “If you’re using the latest firmware, the device advertises with QorvoNIService:
//   static let serviceUUID = CBUUID(string: "2E938FD0-6A61-11ED-A1EB-0242AC120002")
//   static let scCharacteristicUUID = CBUUID(string: "2E93941C-6A61-11ED-A1EB-0242AC120002")
//   static let rxCharacteristicUUID = CBUUID(string: "2E93998A-6A61-11ED-A1EB-0242AC120002")
//   static let txCharacteristicUUID = CBUUID(string: "2E939AF2-6A61-11ED-A1EB-0242AC120002”)
//  [oai_citation:0‡forum.qorvo.com](https://forum.qorvo.com/t/issues-with-apple-nearby-interaction-app-not-detecting-dwm3001cdk-accessory/20321?utm_source=chatgpt.com)
//
struct QorvoNIService {
    static let serviceUUID             = CBUUID(string: "2E938FD0-6A61-11ED-A1EB-0242AC120002")
    // “sc” = session-config / accessory-data characteristic:
    static let scCharacteristicUUID     = CBUUID(string: "2E93941C-6A61-11ED-A1EB-0242AC120002")
    // rx/tx are used internally by the demo firmware (not needed for basic accessoryData read)
    static let rxCharacteristicUUID     = CBUUID(string: "2E93998A-6A61-11ED-A1EB-0242AC120002")
    static let txCharacteristicUUID     = CBUUID(string: "2E939AF2-6A61-11ED-A1EB-0242AC120002")
}

// MARK: – Coordinate setup
// These are your “self-defined” anchor positions (in meters) in a local XY frame.
// Change these to the actual, measured positions of your three beacons.
struct BeaconPosition {
    let id: UUID
    let x: Double
    let y: Double
}

let knownBeaconPositions: [BeaconPosition] = [
    BeaconPosition(id: beacon1UUID, x: 0.0, y: 0.0),
    BeaconPosition(id: beacon2UUID, x: 5.0, y: 0.0),
    BeaconPosition(id: beacon3UUID, x: 0.0, y: 5.0)
]

// MARK: – ViewController
class ViewController: UIViewController, NISessionDelegate {
    
    // Once we read “accessoryData” from a beacon, we hold its NISession here:
    struct BeaconInfo {
        let peripheral: CBPeripheral
        var niSession: NISession
        var lastDistance: Float?
    }
    private var beaconInfos: [UUID: BeaconInfo] = [:]
    
    // Latest raw distances (in meters) from each beacon
    private var distanceMap: [UUID: Float] = [:]
    
    // Our 2D Kalman filter, initialized after we get the first trilateration
    private var kalmanFilter: KalmanFilter2D?
    
    // Display the smoothed (x, y) position on screen
    private let positionLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = .black
        label.textAlignment = .center
        label.text = "Position: --"
        return label
    }()
    
    // BLE helper manager
    private var bleManager: SimpleBLENIManager!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Add the position label
        view.addSubview(positionLabel)
        NSLayoutConstraint.activate([
            positionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            positionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            positionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            positionLabel.heightAnchor.constraint(equalToConstant: 30)
        ])
        
        // Initialize BLE manager and start scan
        bleManager = SimpleBLENIManager(targetUUIDs: targetBeaconUUIDs)
        bleManager.delegate = self
    }
    
    // MARK: – BLE is handled by SimpleBLENIManager
    
    // MARK: – Nearby Interaction
    
    private func startNISession(for peripheral: CBPeripheral, with accessoryData: Data) {
        do {
            let config = try NINearbyAccessoryConfiguration(
                accessoryData: accessoryData,
                bluetoothPeerIdentifier: peripheral.identifier
            )
            // Create a new NISession and run it
            let session = NISession()
            session.delegate = self
            
            // Keep track of it
            beaconInfos[peripheral.identifier] = BeaconInfo(
                peripheral: peripheral,
                niSession: session,
                lastDistance: nil
            )
            
            session.run(config)
            print("🏁 Started NISession for beacon \(peripheral.identifier)")
        } catch {
            print("❌ Failed to create NI config for \(peripheral.identifier): \(error)")
        }
    }
    
    // Called if a session invalidates (e.g. accessory out of range, or error)
    func session(_ session: NISession, didInvalidateWith error: Error) {
        print("⚠️ NISession invalidated: \(error.localizedDescription)")
    }

    // Called when iOS generates its shareable configuration for the accessory
    private func session(_ session: NISession,
                 didGenerateShareableConfigurationData shareableConfigurationData: Data,
                 for bluetoothPeerIdentifier: UUID) {
        print("▶︎ ViewController: Received shareable configuration (\(shareableConfigurationData.count) bytes) for \(bluetoothPeerIdentifier)")
        if let info = beaconInfos[bluetoothPeerIdentifier] {
            bleManager.sendShareableConfiguration(shareableConfigurationData, to: info.peripheral)
        }
    }
    
    // Called whenever ranging data (distance, direction) updates for one session
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        // Each NISession is tied to exactly one accessory, so we expect at most one nearbyObject
        guard let niObject = nearbyObjects.first else {
            print("ℹ️ session didUpdate called, but no nearbyObjects")
            return
        }
        guard let distanceMeters = niObject.distance else {
            print("ℹ️ session didUpdate called for \(session), but distance is nil")
            return
        }
        
        // Find which beacon this session belongs to
        for (id, var info) in beaconInfos where info.niSession === session {
            info.lastDistance = distanceMeters
            beaconInfos[id] = info
            distanceMap[id] = distanceMeters
            print("ℹ️ Updated distanceMap for \(id): \(distanceMap[id]!)")
            
            processRangingData()
            break
        }
    }
    
    // MARK: – Trilateration & Kalman Filter
    
    private func processRangingData() {
        print("ℹ️ processRangingData called. distanceMap keys: \(distanceMap.keys)")
        // Only run trilateration if we have distances from all three beacons
        guard distanceMap.keys.count == knownBeaconPositions.count else { return }
        
        if let (rawX, rawY) = trilaterate(distances: distanceMap) {
            print("ℹ️ Trilateration result: rawX=\(rawX), rawY=\(rawY)")
            let timestamp = CACurrentMediaTime()
            
            if kalmanFilter == nil {
                // First data point: initialize Kalman filter
                kalmanFilter = KalmanFilter2D(
                    initialPosition: simd_double2(rawX, rawY),
                    initialVelocity: simd_double2(0, 0),
                    initialPositionVariance: 1.0,
                    initialVelocityVariance: 1.0,
                    measurementNoise: 0.05,
                    processNoiseIntensity: 1e-3
                )
                updateLabel(x: rawX, y: rawY)
            } else if let kf = kalmanFilter {
                // Perform one Kalman update
                let filtered = kf.update(with: simd_double2(rawX, rawY), timestamp: timestamp)
                updateLabel(x: filtered.x, y: filtered.y)
            }
        }
    }
    
    private func updateLabel(x: Double, y: Double) {
        let displayX = String(format: "%.2f", x)
        let displayY = String(format: "%.2f", y)
        DispatchQueue.main.async {
            self.positionLabel.text = "Position: (\(displayX), \(displayY)) m"
        }
    }
    
    /// Trilaterate (x, y) from distances to three known beacons
    private func trilaterate(distances: [UUID: Float]) -> (x: Double, y: Double)? {
        guard knownBeaconPositions.count == 3 else { return nil }
        
        let p1 = knownBeaconPositions[0]
        let p2 = knownBeaconPositions[1]
        let p3 = knownBeaconPositions[2]
        
        guard let d1f = distances[p1.id],
              let d2f = distances[p2.id],
              let d3f = distances[p3.id] else {
            return nil
        }
        let x1 = p1.x, y1 = p1.y, r1 = Double(d1f)
        let x2 = p2.x, y2 = p2.y, r2 = Double(d2f)
        let x3 = p3.x, y3 = p3.y, r3 = Double(d3f)
        
        // Solve linearized equations
        let A1 = 2*(x1 - x2)
        let B1 = 2*(y1 - y2)
        let C1 = pow(r1,2) - pow(r2,2) + pow(x2,2) - pow(x1,2) + pow(y2,2) - pow(y1,2)
        
        let A2 = 2*(x1 - x3)
        let B2 = 2*(y1 - y3)
        let C2 = pow(r1,2) - pow(r3,2) + pow(x3,2) - pow(x1,2) + pow(y3,2) - pow(y1,2)
        
        let det = A1*B2 - A2*B1
        guard abs(det) > 1e-6 else { return nil }
        
        let x = (C1*B2 - C2*B1) / det
        let y = (A1*C2 - A2*C1) / det
        return (x, y)
    }
    
    /// Simple 2D constant-velocity Kalman filter
    class KalmanFilter2D {
        private var x: simd_double4
        private var P: simd_double4x4
        private let R: simd_double2x2
        private let q: Double
        private var lastTime: TimeInterval?
        
        init(initialPosition: simd_double2,
             initialVelocity: simd_double2,
             initialPositionVariance: Double,
             initialVelocityVariance: Double,
             measurementNoise: Double,
             processNoiseIntensity: Double) {
            
            x = simd_double4(
                initialPosition.x,
                initialPosition.y,
                initialVelocity.x,
                initialVelocity.y
            )
            P = simd_double4x4(diagonal:
                simd_double4(
                    initialPositionVariance,
                    initialPositionVariance,
                    initialVelocityVariance,
                    initialVelocityVariance
                )
            )
            let rVal = measurementNoise * measurementNoise
            R = simd_double2x2(diagonal: [rVal, rVal])
            q = processNoiseIntensity
        }
        
        func update(with measured: simd_double2, timestamp: TimeInterval) -> simd_double2 {
            guard let t0 = lastTime else {
                // First measurement: just set position
                x[0] = measured.x
                x[1] = measured.y
                lastTime = timestamp
                return measured
            }
            let dt = timestamp - t0
            lastTime = timestamp
            
            // State transition matrix
            let F = simd_double4x4(rows: [
                simd_double4(1, 0, dt, 0),
                simd_double4(0, 1, 0, dt),
                simd_double4(0, 0, 1,  0),
                simd_double4(0, 0, 0,  1)
            ])
            
            // Process noise covariance Q
            let dt2 = dt * dt
            let dt3 = dt2 * dt
            let dt4 = dt3 * dt
            let q11 = dt4/4 * q
            let q13 = dt3/2 * q
            let q22 = q11
            let q24 = q13
            let q31 = q13
            let q33 = dt2 * q
            let q42 = q24
            let q44 = q33
            
            let Q = simd_double4x4(rows: [
                simd_double4(q11,    0, q13,    0),
                simd_double4(   0, q22,    0, q24),
                simd_double4(q31,    0, q33,    0),
                simd_double4(   0, q42,    0, q44)
            ])
            
            // Predict
            x = F * x
            P = F * P * F.transpose + Q
            
            // Measurement update
            let H = simd_double4x2(columns: (
                simd_double2(1, 0),
                simd_double2(0, 1),
                simd_double2(0, 0),
                simd_double2(0, 0)
            ))
            let z = measured
            let Hx = simd_double2(x[0], x[1])
            let y_tilde = z - Hx
            
            let S = H * P * H.transpose + R
            let K = P * H.transpose * S.inverse
            
            let Ky = K * y_tilde
            x += Ky
            
            let I = simd_double4x4(diagonal: simd_double4(1,1,1,1))
            P = (I - K * H) * P
            
            return simd_double2(x[0], x[1])
        }
    }
}

// MARK: – SimpleBLENIManagerDelegate
extension ViewController: SimpleBLENIManagerDelegate {
    func didConnectToPeripheral(_ peripheral: CBPeripheral) {
        print("✅ Connected (helper) to \(peripheral.identifier). Waiting for ACD…")
    }

    func didDisconnectPeripheral(_ peripheral: CBPeripheral) {
        print("⚠️ Disconnected (helper) from \(peripheral.identifier)")
        if let info = beaconInfos[peripheral.identifier] {
            info.niSession.invalidate()
            beaconInfos.removeValue(forKey: peripheral.identifier)
        }
    }

    func didReceiveAccessoryData(_ data: Data, from peripheral: CBPeripheral) {
        print("📦 Received helper ACD (\(data.count) bytes) from \(peripheral.identifier)")
        startNISession(for: peripheral, with: data)
    }
}
