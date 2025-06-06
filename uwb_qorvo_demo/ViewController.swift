import UIKit
import CoreBluetooth
import NearbyInteraction
import simd
import QuartzCore
import Foundation

// Shared environment mode for Indoor/Outdoor
enum EnvironmentMode: Int {
    case indoor = 0
    case outdoor = 1
}
// MARK: - Core Types & Globals
enum QorvoMessageId: UInt8 {
    case accessoryConfigurationData = 0x1
    case initialize = 0xA
    case configureAndStart = 0xB
}

typealias BluetoothLECentral = DataCommunicationChannel

let beaconUUID_6392 = UUID(uuidString: "6392BD53-9B46-3623-ECD3-02FE919BD038")! // Beacon 1
let beaconUUID_67F7 = UUID(uuidString: "67F74E81-1C3D-ED23-41E5-C6212723CB82")! // Beacon 3
let beaconUUID_A3F1 = UUID(uuidString: "A3F121FB-850A-381E-DD90-3726A57E6EBF")! // Beacon 2

var globalLogBuffer: [String] = []
let maxLogEntries = 300

func customPrint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let output = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
    DispatchQueue.main.async {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        globalLogBuffer.append("[\(timestamp)] \(output)")
        if globalLogBuffer.count > maxLogEntries {
            globalLogBuffer.removeFirst(globalLogBuffer.count - maxLogEntries)
        }
        NotificationCenter.default.post(name: .didUpdateLogBuffer, object: nil)
    }
}

extension Notification.Name {
    static let didUpdateLogBuffer = Notification.Name("didUpdateLogBuffer")
}

struct AnchorSetup {
    let name: String
    let targetUUID: UUID
    let designatedPosition: simd_double3
}

struct UWBAnchorMeasurement {
    let anchorID: UUID
    let anchorName: String
    let anchorUUID: String
    let point: simd_double2
    let rawDistance: Double
    let smoothedDistance: Double
    let planarDistance: Double
    let confidence: Double
}

struct UWBPositionSolution {
    let position: simd_double2
    let residuals: [UUID: Double]
    let rmsResidual: Double
    let usedAnchorIDs: [UUID]
}

struct ActiveAnchor {
    let peripheralID: UUID
    let bleID: Int
    let setup: AnchorSetup
    var niSession: NISession
    var discoveryToken: NIDiscoveryToken?
    var rawDistance: Float?
    var currentDistance: Float?
    var lastUpdatedAt: TimeInterval?
    var displayName: String { "\(setup.name) (\(String(peripheralID.uuidString.prefix(4))))" }
    
    private(set) var distanceHistory: [Float] = []
    private let smoothingFactor: Float = 0.25

    mutating func updateDistance(_ rawDistance: Float) {
        self.rawDistance = rawDistance
        self.lastUpdatedAt = CACurrentMediaTime()
        if let existingDistance = currentDistance {
            currentDistance = (smoothingFactor * rawDistance) + (1.0 - smoothingFactor) * existingDistance
        } else {
            currentDistance = rawDistance
        }
        
        if let smoothedDistance = currentDistance {
            distanceHistory.append(smoothedDistance)
            if distanceHistory.count > 8 {
                distanceHistory.removeFirst()
            }
        }
    }
    
    var confidence: Double {
        guard let lastUpdatedAt else { return 0.0 }
        guard distanceHistory.count > 2 else { return 0.4 }
        let mean = distanceHistory.reduce(0, +) / Float(distanceHistory.count)
        let variance = distanceHistory.map { pow($0 - mean, 2) }.reduce(0, +) / Float(distanceHistory.count)
        let stdDev = sqrt(max(variance, 0))
        let relativeSpread = Double(stdDev / max(mean, 0.001))
        let freshnessPenalty = min(1.0, max(0.0, (CACurrentMediaTime() - lastUpdatedAt) / 1.5))
        let stabilityScore = exp(-4.0 * relativeSpread)
        let freshnessScore = 1.0 - freshnessPenalty
        return max(0.05, min(1.0, 0.75 * stabilityScore + 0.25 * freshnessScore))
    }
}

// MARK: - Main ViewController
class ViewController: UIViewController, NISessionDelegate, RecordingSetupDelegate {
  
  private var central: BluetoothLECentral!
  private var sessions: [UUID: NISession] = [:]
  private var peripheralIdToBleIdMap: [UUID: Int] = [:]
  private var accessoryTokensToPeripheralIDs: [NIDiscoveryToken: UUID] = [:]
  private let beaconDefinitions = BeaconLayoutStore.defaultBeaconDefinitions
  private let beaconLayoutStore = BeaconLayoutStore()
  private var beaconLayoutConfiguration = BeaconLayoutStore.defaultConfiguration
  private var activeAnchors: [UUID: ActiveAnchor] = [:]
  private var sensorFusionFilter: SensorFusionKalmanFilter?
  private var coreMotionManager: CoreMotionManager!
  private let configuredAnchorHeightMeters: Double = 0.65
  private var assumedTagHeightMeters: Double = 1.2
  private var latestEstimatorConfidence: Double?
  
  // UI Elements
  private let mainStackView = UIStackView()
  private let coordinateLabel = UILabel()
  private var beaconTitleLabels: [UILabel] = []
  private var beaconUUIDLabels: [UILabel] = []
  private var beaconStatusLabels: [UILabel] = []
  
  // Recording State
  private var isRecordingSession: Bool = false
  private var currentRecordingTask: RecordingTask = .none
  private var currentSessionDataPoints: [RecordedDataPoint] = []
  private var sessionStartTime: Date?
  private var completedRecordingSessions: [RecordedSession] = []
  private var pendingStaticTestContext: StaticTestSessionContext?
  private var activeStaticTestContext: StaticTestSessionContext?
  
  // Environment Mode (needed for updateUI fix)
  private var environmentMode: EnvironmentMode = .indoor
  
  // Mode selector
  private let modeSegmentedControl: UISegmentedControl = {
      let sc = UISegmentedControl(items: ["Indoor", "Outdoor"])
      sc.selectedSegmentIndex = 0
      return sc
  }()

  private var currentAnchorSetups: [AnchorSetup] {
      beaconLayoutConfiguration.anchorSetups(using: beaconDefinitions)
  }

  private func anchorSetup(for uuid: UUID) -> AnchorSetup? {
      beaconLayoutConfiguration.anchorSetup(for: uuid, using: beaconDefinitions)
  }
  
  private func resetLayoutDependentState(reason: String) {
      sensorFusionFilter = nil
      latestEstimatorConfidence = nil
      let ids = Array(activeAnchors.keys)
      for id in ids { cleanupSessionForPeripheral(identifier: id, reason: reason) }
      updateUI()
  }
  
  override func viewDidLoad() {
      super.viewDidLoad()
      beaconLayoutConfiguration = beaconLayoutStore.load()
      setupUI()
      setupBluetooth()
      setupCoreMotion()
      updateUI()
  }

  private func setupBluetooth() {
      central = BluetoothLECentral()
      central.accessorySynchHandler = self.accessorySynch
      central.accessoryConnectedHandler = self.accessoryConnected
      central.accessoryDataHandler = self.accessoryDataReceived
      central.accessoryDisconnectedHandler = self.accessoryDisconnected
      central.start()
      customPrint("BluetoothLECentral started")
  }
    
  private func setupCoreMotion() {
      coreMotionManager = CoreMotionManager()
      coreMotionManager.onAccelerationData = { [weak self] acceleration in
          guard let self = self, let filter = self.sensorFusionFilter else { return }
          filter.predict(with: acceleration, timestamp: CACurrentMediaTime())
      }
      coreMotionManager.start()
      customPrint("CoreMotionManager started")
  }

  // MARK: - UI Setup & Actions
  private func setupUI() {
      view.backgroundColor = .systemBackground
      mainStackView.axis = .vertical
      mainStackView.spacing = 12
      mainStackView.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(mainStackView)

      let titleLabel = UILabel()
      titleLabel.text = "UWB Positioning"
      titleLabel.font = .systemFont(ofSize: 20, weight: .bold)

      let helpButton = UIButton(type: .system)
      helpButton.setTitle("?", for: .normal)
      helpButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
      helpButton.addTarget(self, action: #selector(showHelpSheet), for: .touchUpInside)
      helpButton.backgroundColor = .secondarySystemBackground
      helpButton.layer.cornerRadius = 20
      helpButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
      helpButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
      
      let topBarStack = UIStackView(arrangedSubviews: [titleLabel, helpButton])
      topBarStack.distribution = .equalSpacing
      mainStackView.addArrangedSubview(topBarStack)
      
      modeSegmentedControl.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
      mainStackView.addArrangedSubview(modeSegmentedControl)
      
      let manageRecordingButton = createButton(title: "Manage Recording Session", selector: #selector(showRecordingSetupSheet), isPrimary: true)
      mainStackView.addArrangedSubview(manageRecordingButton)
      
      coordinateLabel.font = .systemFont(ofSize: 18, weight: .semibold)
      coordinateLabel.textAlignment = .center
      coordinateLabel.numberOfLines = 0
      mainStackView.addArrangedSubview(coordinateLabel)

      mainStackView.addArrangedSubview(createButton(title: "Beacon Layout Debug", selector: #selector(showBeaconLayoutDebugSheet)))

      for setup in currentAnchorSetups {
          let container = UIStackView()
          container.axis = .vertical
          container.spacing = 4
          
          let titleLabel = createLabel(text: setup.name, weight: .medium)
          beaconTitleLabels.append(titleLabel)
          container.addArrangedSubview(titleLabel)

          let uuidLabel = createLabel(text: "UUID: \(setup.targetUUID.uuidString)", size: 10, color: .secondaryLabel)
          beaconUUIDLabels.append(uuidLabel)
          container.addArrangedSubview(uuidLabel)
          
          let statusLabel = createLabel(text: "🔴 Disconnected", size: 14)
          beaconStatusLabels.append(statusLabel)
          container.addArrangedSubview(statusLabel)
          
          mainStackView.addArrangedSubview(container)
      }
      
      mainStackView.addArrangedSubview(createButton(title: "Show Debug Log", selector: #selector(showDebugLogSheet)))
      mainStackView.addArrangedSubview(createButton(title: "Show Recordings", selector: #selector(showRecordingsListSheet)))
      mainStackView.addArrangedSubview(createButton(title: "Launch AR View", selector: #selector(launchARView)))

      NSLayoutConstraint.activate([
          mainStackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
          mainStackView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
          mainStackView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
      ])
  }

  @objc private func showHelpSheet() { presentSheet(vc: HelpViewController()) }

  @objc private func showBeaconLayoutDebugSheet() {
      let vc = BeaconLayoutDebugViewController(
          initialConfiguration: beaconLayoutConfiguration,
          availableBeacons: beaconDefinitions,
          positionProvider: { [weak self] in self?.currentEstimatedPosition() }
      )
      vc.onSave = { [weak self] configuration in
          self?.applyBeaconLayoutConfiguration(configuration)
      }
      presentSheet(vc: vc, detents: [.large()])
  }
    
  @objc private func showDebugLogSheet() {
      let vc = DebugLogViewController()
      vc.logText = globalLogBuffer.joined(separator: "\n")
      presentSheet(vc: vc)
  }

  @objc private func showRecordingSetupSheet() {
      let vc = RecordingSetupViewController()
      vc.delegate = self
      presentSheet(vc: vc, detents: [.medium(), .large()])
  }
    
  @objc private func showRecordingsListSheet() {
      customPrint("➡️ Showing recordings sheet. Session count: \(completedRecordingSessions.count)")
      let vc = RecordingsListViewController()
      vc.recordedSessions = self.completedRecordingSessions
      presentSheet(vc: vc)
  }

  @objc private func launchARView() {
      let arVC = ARViewController()
      arVC.uwbDataDelegate = self
      // Provide environment mode and area length to AR view
      arVC.environmentMode = (environmentMode == .indoor) ? .indoor : .outdoor
      arVC.uwbAreaWidth = Float(beaconLayoutConfiguration.widthMeters)
      arVC.uwbAreaHeight = Float(beaconLayoutConfiguration.heightMeters)
      arVC.originBeaconName = beaconDefinitions.first(where: { $0.uuid == beaconLayoutConfiguration.originBeaconUUID })?.shortName ?? "Origin"
      arVC.topLeftBeaconName = beaconDefinitions.first(where: { $0.uuid == beaconLayoutConfiguration.topLeftBeaconUUID })?.shortName ?? "Top Left"
      arVC.topRightBeaconName = beaconDefinitions.first(where: { $0.uuid == beaconLayoutConfiguration.topRightBeaconUUID })?.shortName ?? "Top Right"
      arVC.modalPresentationStyle = .fullScreen
      present(arVC, animated: true)
  }
    
  @objc private func modeChanged(_ sender: UISegmentedControl) {
      let newMode: EnvironmentMode = (sender.selectedSegmentIndex == 0) ? .indoor : .outdoor
      if newMode != environmentMode {
          environmentMode = newMode
          customPrint("Environment mode: \(newMode == .indoor ? "Indoor" : "Outdoor")")
          updateUI()
      }
  }

  private func applyBeaconLayoutConfiguration(_ configuration: BeaconLayoutConfiguration) {
      beaconLayoutConfiguration = configuration
      beaconLayoutStore.save(configuration)
      customPrint(
          String(
              format: "Beacon layout updated. Width %.2fm, height %.2fm",
              configuration.widthMeters,
              configuration.heightMeters
          )
      )
      resetLayoutDependentState(reason: "Beacon layout changed")
  }
    
  private func updateUI() {
      DispatchQueue.main.async {
          var coordText: String
          if let state = self.sensorFusionFilter?.getCurrentState() {
              coordText = String(format: "Coordinates: (%.2f, %.2f)", state.x, state.y)
          } else if self.activeAnchors.values.filter({ $0.currentDistance != nil }).count < 3 {
              coordText = "Coordinates: (Waiting for 3 anchors...)"
          } else {
              coordText = "Coordinates: (Trilateration Error)"
          }
          let modeText = self.environmentMode == .indoor ? "Mode: Indoor" : "Mode: Outdoor"
          let layoutText = String(
              format: "Layout: %.2fm × %.2fm",
              self.beaconLayoutConfiguration.widthMeters,
              self.beaconLayoutConfiguration.heightMeters
          )
          self.coordinateLabel.text = coordText + "\n" + modeText + "\n" + layoutText
          
          let currentSetups = self.currentAnchorSetups
          for (index, setup) in currentSetups.enumerated() {
              guard index < self.beaconStatusLabels.count else { continue }
              if index < self.beaconTitleLabels.count {
                  self.beaconTitleLabels[index].text = setup.name
              }
              if index < self.beaconUUIDLabels.count {
                  self.beaconUUIDLabels[index].text = "UUID: \(setup.targetUUID.uuidString)"
              }
              let label = self.beaconStatusLabels[index]
              if let anchor = self.activeAnchors.values.first(where: { $0.setup.targetUUID == setup.targetUUID }), anchor.discoveryToken != nil {
                  let distText = anchor.currentDistance.map { String(format: "\nDist: %.2f m", $0) } ?? "\nDist: N/A"
                  let confText = String(format: " (Conf: %.2f)", anchor.confidence)
                  label.text = "🟢 Connected" + distText + confText
                  label.textColor = .label
              } else if self.activeAnchors.values.contains(where: { $0.setup.targetUUID == setup.targetUUID }) {
                  label.text = "🟡 Connecting..."
                  label.textColor = .orange
              } else {
                  label.text = "🔴 Disconnected"
                  label.textColor = .systemRed
              }
          }
      }
  }

  // MARK: - Bluetooth & NI Handlers
  private func accessorySynch(_ bleDeviceID: Int, _ insert: Bool) {
      if insert {
          do { try self.central.connectPeripheral(bleDeviceID) } catch { customPrint("ERROR: Connect failed: \(error)") }
      } else if let pID = peripheralIdToBleIdMap.first(where: { $0.value == bleDeviceID })?.key {
          cleanupSessionForPeripheral(identifier: pID, reason: "BLE sync lost")
      }
  }
  
  private func accessoryConnected(_ bleDeviceID: Int) {
      guard let device = self.central.getDeviceFromUniqueID(bleDeviceID) else {
          customPrint("WARNING: Connected to unknown peripheral with identifier: \(self.central.getDeviceFromUniqueID(bleDeviceID)?.blePeripheral.identifier.uuidString ?? "N/A")")
          return
      }
      let pID = device.blePeripheral.identifier
      self.peripheralIdToBleIdMap[pID] = bleDeviceID
      
      let session = NISession()
      session.delegate = self
      self.sessions[pID] = session
      
      if let setup = anchorSetup(for: pID) {
          self.activeAnchors[pID] = ActiveAnchor(peripheralID: pID, bleID: bleDeviceID, setup: setup, niSession: session)
      } else {
          customPrint("WARNING: No AnchorSetup for peripheral \(pID.uuidString)")
      }
      
      let initMessage = Data([QorvoMessageId.initialize.rawValue])
      do { try self.central.sendData(initMessage, bleDeviceID) } catch { customPrint("ERROR: Send init failed: \(error)") }
      updateUI()
  }
  
  private func accessoryDataReceived(_ data: Data, accessoryName: String, bleDeviceID: Int) {
      guard !data.isEmpty, let msgID = QorvoMessageId(rawValue: data.first!),
            let pID = peripheralIdToBleIdMap.first(where: { $0.value == bleDeviceID })?.key,
            let session = self.sessions[pID]
      else { return }
      
      if msgID == .accessoryConfigurationData {
          do {
              let config = try NINearbyAccessoryConfiguration(data: data.advanced(by: 1))
              self.accessoryTokensToPeripheralIDs[config.accessoryDiscoveryToken] = pID
              self.activeAnchors[pID]?.discoveryToken = config.accessoryDiscoveryToken
              session.run(config)
          } catch { customPrint("ERROR: NI Configuration failed: \(error)") }
      }
      updateUI()
  }

  private func accessoryDisconnected(_ bleDeviceID: Int) {
      if let pID = peripheralIdToBleIdMap.first(where: { $0.value == bleDeviceID })?.key {
          cleanupSessionForPeripheral(identifier: pID, reason: "BLE Disconnected")
      }
  }

  private func cleanupSessionForPeripheral(identifier: UUID, reason: String) {
      customPrint("Cleaning up \(identifier.uuidString.prefix(4)) due to: \(reason)")
      self.sessions[identifier]?.invalidate()
      self.sessions.removeValue(forKey: identifier)
      if let token = self.activeAnchors[identifier]?.discoveryToken {
          self.accessoryTokensToPeripheralIDs.removeValue(forKey: token)
      }
      if let bleID = self.activeAnchors[identifier]?.bleID {
          self.peripheralIdToBleIdMap = self.peripheralIdToBleIdMap.filter { $0.value != bleID }
      }
      self.activeAnchors.removeValue(forKey: identifier)
      updateUI()
  }
  
  // MARK: - NISessionDelegate
  func session(_ session: NISession, didGenerateShareableConfigurationData data: Data, for object: NINearbyObject) {
      guard let pID = accessoryTokensToPeripheralIDs[object.discoveryToken], let bleID = peripheralIdToBleIdMap[pID] else { return }
      var msg = Data([QorvoMessageId.configureAndStart.rawValue]); msg.append(data)
      do { try self.central.sendData(msg, bleID) } catch { customPrint("ERROR: Send config failed: \(error)") }
  }
  
  func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
      guard let obj = nearbyObjects.first, let pID = accessoryTokensToPeripheralIDs[obj.discoveryToken], obj.distance != nil else { return }
      self.activeAnchors[pID]?.updateDistance(obj.distance!)
      processRangingData()
      updateUI()
  }
  
  func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
      guard let obj = nearbyObjects.first, let pID = accessoryTokensToPeripheralIDs[obj.discoveryToken] else { return }
      cleanupSessionForPeripheral(identifier: pID, reason: "NI Removal: \(reason)")
  }
  
  func sessionWasSuspended(_ session: NISession) { customPrint("Session suspended.") }
  func sessionSuspensionEnded(_ session: NISession) { customPrint("Session resumed.") }
  func session(_ session: NISession, didInvalidateWith error: Error) {
      customPrint("Session invalidated: \(error.localizedDescription)")
      if let pID = sessions.first(where: { $1 === session })?.key {
          cleanupSessionForPeripheral(identifier: pID, reason: "Session Invalidated")
      }
  }

    // MARK: - Data Processing & Recording
    private func processRangingData() {
        let rangingAnchors = activeAnchors.values.filter { $0.currentDistance != nil && $0.discoveryToken != nil }
        guard rangingAnchors.count >= 3, let filter = sensorFusionFilter else {
            if rangingAnchors.count >= 3 {
                let measurements = makeMeasurements(from: Array(rangingAnchors))
                let initialGuess = averageAnchorPoint(for: measurements)
                if let initialPos = solvePosition(measurements: measurements, initialGuess: initialGuess)?.position {
                    initializeSensorFusionFilter(at: initialPos)
                }
            }
            logCurrentDataPoint(anchorSnapshots: makeAnchorSnapshots(solution: nil))
            return
        }

        let measurements = makeMeasurements(from: Array(rangingAnchors))
        let overallConfidence = measurements.map(\.confidence).reduce(0, +) / Double(measurements.count)
        latestEstimatorConfidence = overallConfidence

        let predictedState = filter.getCurrentState()
        let predictedPos = simd_double2(predictedState.x, predictedState.y)

        guard let solution = solvePosition(measurements: measurements, initialGuess: predictedPos) else {
            customPrint("⚠️ Solver failed. Falling back to prediction only.")
            logCurrentDataPoint(anchorSnapshots: makeAnchorSnapshots(solution: nil))
            return
        }

        let measurementStdDev = measurementStdDev(for: solution, overallConfidence: overallConfidence)
        let filteredState = filter.update(with: solution.position, measurementStdDev: measurementStdDev)
        let snapshots = makeAnchorSnapshots(solution: solution)
        logCurrentDataPoint(
            rawX: solution.position.x,
            rawY: solution.position.y,
            filteredX: filteredState.x,
            filteredY: filteredState.y,
            measurementStdDev: measurementStdDev,
            overallConfidence: overallConfidence,
            anchorSnapshots: snapshots
        )

        if solution.rmsResidual > 0.75 {
            customPrint(String(format: "⚠️ High residual fit: %.3f m", solution.rmsResidual))
        } else {
            customPrint(String(format: "UWB fit residual: %.3f m", solution.rmsResidual))
        }
    }
    
  private func initializeSensorFusionFilter(at position: simd_double2) {
      sensorFusionFilter = SensorFusionKalmanFilter(
        initialState: simd_double4(position.x, position.y, 0, 0),
        initialCovariance: [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
      )
      customPrint("Sensor Fusion Kalman Filter Initialized at (\(position.x), \(position.y))")
  }

  // MARK: - Trilateration Logic
  private func makeMeasurements(from anchors: [ActiveAnchor]) -> [UWBAnchorMeasurement] {
      anchors.compactMap { anchor in
          guard let rawDistance = anchor.rawDistance, let smoothedDistance = anchor.currentDistance else { return nil }
          let slantDistance = Double(smoothedDistance)
          let verticalOffset = configuredAnchorHeightMeters - assumedTagHeightMeters
          let planarDistance = sqrt(max(0.01, slantDistance * slantDistance - verticalOffset * verticalOffset))
          return UWBAnchorMeasurement(
              anchorID: anchor.peripheralID,
              anchorName: anchor.setup.name,
              anchorUUID: anchor.peripheralID.uuidString,
              point: simd_double2(anchor.setup.designatedPosition.x, anchor.setup.designatedPosition.y),
              rawDistance: Double(rawDistance),
              smoothedDistance: Double(smoothedDistance),
              planarDistance: planarDistance,
              confidence: anchor.confidence
          )
      }
  }

  private func averageAnchorPoint(for measurements: [UWBAnchorMeasurement]) -> simd_double2 {
      guard !measurements.isEmpty else { return .zero }
      let weighted = measurements.reduce(simd_double2.zero) { partial, measurement in
          partial + measurement.point * measurement.confidence
      }
      let totalWeight = max(0.001, measurements.reduce(0.0) { $0 + $1.confidence })
      return weighted / totalWeight
  }

  private func solvePosition(measurements: [UWBAnchorMeasurement], initialGuess: simd_double2) -> UWBPositionSolution? {
      guard measurements.count >= 3 else { return nil }
      var activeMeasurements = measurements
      var guess = initialGuess
      let fallbackGuess = averageAnchorPoint(for: measurements)
      if guess == .zero {
          guess = fallbackGuess
      }

      func solve(_ measurements: [UWBAnchorMeasurement], guess: simd_double2) -> UWBPositionSolution? {
          var position = guess
          var lambda = 0.05

          for _ in 0..<25 {
              var normal = Matrix(rows: 2, cols: 2)
              var gradient = [Double](repeating: 0.0, count: 2)
              var residuals: [UUID: Double] = [:]
              var weightedSquaredResiduals = 0.0
              var totalWeight = 0.0

              for measurement in measurements {
                  let dx = position.x - measurement.point.x
                  let dy = position.y - measurement.point.y
                  let predicted = max(1e-6, sqrt(dx * dx + dy * dy))
                  let residual = predicted - measurement.planarDistance
                  let weight = max(0.05, measurement.confidence)
                  let huberScale = max(0.15, 0.35 + measurement.planarDistance * 0.02)
                  let robustWeight = abs(residual) <= huberScale ? 1.0 : huberScale / abs(residual)
                  let finalWeight = weight * robustWeight
                  let jx = dx / predicted
                  let jy = dy / predicted

                  normal[0, 0] += finalWeight * jx * jx
                  normal[0, 1] += finalWeight * jx * jy
                  normal[1, 0] += finalWeight * jy * jx
                  normal[1, 1] += finalWeight * jy * jy
                  gradient[0] += finalWeight * residual * jx
                  gradient[1] += finalWeight * residual * jy

                  residuals[measurement.anchorID] = residual
                  weightedSquaredResiduals += finalWeight * residual * residual
                  totalWeight += finalWeight
              }

              normal[0, 0] += lambda
              normal[1, 1] += lambda
              guard let inverse = normal.inverse else { return nil }

              let step = inverse * gradient
              let candidate = simd_double2(position.x - step[0], position.y - step[1])
              if simd_distance(candidate, position) < 1e-4 {
                  let rms = sqrt(max(0.0, weightedSquaredResiduals / max(totalWeight, 1e-6)))
                  return UWBPositionSolution(position: candidate, residuals: residuals, rmsResidual: rms, usedAnchorIDs: measurements.map(\.anchorID))
              }

              position = candidate
              lambda = max(0.001, lambda * 0.9)
          }

          var residuals: [UUID: Double] = [:]
          let rms = sqrt(measurements.map { measurement in
              let residual = simd_distance(position, measurement.point) - measurement.planarDistance
              residuals[measurement.anchorID] = residual
              return residual * residual
          }.reduce(0.0, +) / Double(measurements.count))
          return UWBPositionSolution(position: position, residuals: residuals, rmsResidual: rms, usedAnchorIDs: measurements.map(\.anchorID))
      }

      guard var solution = solve(activeMeasurements, guess: guess) else { return nil }
      if activeMeasurements.count > 3,
         let worst = solution.residuals.max(by: { abs($0.value) < abs($1.value) }),
         abs(worst.value) > 0.9 {
          activeMeasurements.removeAll { $0.anchorID == worst.key }
          if let refined = solve(activeMeasurements, guess: solution.position) {
              solution = refined
          }
      }
      return solution
  }

  private func measurementStdDev(for solution: UWBPositionSolution, overallConfidence: Double) -> Double {
      let residualTerm = max(0.08, solution.rmsResidual)
      let confidencePenalty = (1.0 - overallConfidence) * 0.8
      return min(2.5, max(0.12, residualTerm + confidencePenalty))
  }

  private func makeAnchorSnapshots(solution: UWBPositionSolution?) -> [AnchorMeasurementSnapshot] {
      activeAnchors.values.compactMap { anchor in
          let planarDistance: Double?
          if let smoothed = anchor.currentDistance {
              let verticalOffset = configuredAnchorHeightMeters - assumedTagHeightMeters
              let slant = Double(smoothed)
              planarDistance = sqrt(max(0.01, slant * slant - verticalOffset * verticalOffset))
          } else {
              planarDistance = nil
          }

          return AnchorMeasurementSnapshot(
              anchorName: anchor.setup.name,
              anchorUUID: anchor.peripheralID.uuidString,
              configuredX: anchor.setup.designatedPosition.x,
              configuredY: anchor.setup.designatedPosition.y,
              rawDistance: anchor.rawDistance.map(Double.init),
              smoothedDistance: anchor.currentDistance.map(Double.init),
              planarDistance: planarDistance,
              confidence: anchor.confidence,
              residual: solution?.residuals[anchor.peripheralID]
          )
      }
  }

  func didRequestStartRecording(task: RecordingTask) {
      customPrint("▶️ Recording STARTED for task: \(task.rawValue)")
      isRecordingSession = true
      currentRecordingTask = task
      sessionStartTime = Date()
      currentSessionDataPoints.removeAll()
      activeStaticTestContext = task == .staticTest ? pendingStaticTestContext : nil
      if let context = activeStaticTestContext {
          assumedTagHeightMeters = context.phoneHeightMeters
          customPrint("Static test context prepared for marker \(context.markerName) at (\(context.groundTruth.x), \(context.groundTruth.y))")
      }
      pendingStaticTestContext = nil
  }

  func didRequestStopRecording(task: RecordingTask) {
      if !isRecordingSession {
          customPrint(" CANCELED: didRequestStopRecording called but no session was active.")
          return
      }
      
      isRecordingSession = false
      
      if !currentSessionDataPoints.isEmpty {
          let newSession = RecordedSession(
            id: UUID(),
            task: currentRecordingTask,
            startTime: sessionStartTime!,
            endTime: Date(),
            staticContext: activeStaticTestContext,
            dataPoints: currentSessionDataPoints
          )
          completedRecordingSessions.append(newSession)
          customPrint("✅ Session SAVED! Total sessions: \(completedRecordingSessions.count). Points: \(currentSessionDataPoints.count)")
          currentSessionDataPoints.removeAll()
      } else {
          customPrint("⚠️ Recording STOPPED, but no data points were collected.")
      }
      
      currentRecordingTask = .none
      sessionStartTime = nil
      activeStaticTestContext = nil
  }

  func getCurrentRecordingState() -> (isRecording: Bool, task: RecordingTask, startTime: Date?) {
      (isRecordingSession, currentRecordingTask, sessionStartTime)
  }

  func prepareStaticTestSession(context: StaticTestSessionContext) {
      pendingStaticTestContext = context
  }

  func getEstimatorStatus() -> EstimatorStatus {
      let rangingAnchors = activeAnchors.values.filter { $0.currentDistance != nil && $0.discoveryToken != nil }
      let latestPosition = sensorFusionFilter.map {
          let state = $0.getCurrentState()
          return simd_double2(state.x, state.y)
      }
      return EstimatorStatus(
          connectedAnchors: activeAnchors.count,
          rangingAnchors: rangingAnchors.count,
          latestPosition: latestPosition,
          overallConfidence: latestEstimatorConfidence
      )
  }

  func getMostRecentCompletedSession() -> RecordedSession? {
      completedRecordingSessions.last
  }

  private func logCurrentDataPoint(
      rawX: Double? = nil,
      rawY: Double? = nil,
      filteredX: Double? = nil,
      filteredY: Double? = nil,
      measurementStdDev: Double? = nil,
      overallConfidence: Double? = nil,
      anchorSnapshots: [AnchorMeasurementSnapshot] = []
  ) {
      guard isRecordingSession else { return }
      
      let dataPoint = RecordedDataPoint(
        timestamp: CACurrentMediaTime(),
        task: currentRecordingTask,
        rawX: rawX,
        rawY: rawY,
        filteredX: filteredX,
        filteredY: filteredY,
        measurementStdDev: measurementStdDev,
        overallConfidence: overallConfidence,
        anchorSnapshots: anchorSnapshots
      )
      currentSessionDataPoints.append(dataPoint)
      
      if currentSessionDataPoints.count % 20 == 1 {
          customPrint("✍️ Logging data point #\(currentSessionDataPoints.count)...")
      }
  }
    
    // MARK: - UI Helpers
    private func createButton(title: String, selector: Selector, isPrimary: Bool = false) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: isPrimary ? .medium : .regular)
        if isPrimary {
            button.backgroundColor = .systemBlue
            button.setTitleColor(.white, for: .normal)
            button.layer.cornerRadius = 8
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        }
        return button
    }
    
    private func createLabel(text: String, size: CGFloat = 16, weight: UIFont.Weight = .regular, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }
    
    private func presentSheet(vc: UIViewController, detents: [UISheetPresentationController.Detent] = [.medium(), .large()]) {
        if let sheet = vc.sheetPresentationController {
            sheet.detents = detents
            sheet.prefersGrabberVisible = true
        }
        present(vc, animated: true)
    }
}

// MARK: - UWBDataDelegate
extension ViewController: UWBDataDelegate {
    func getCurrentUWBPosition() -> simd_float2? {
        guard let state = sensorFusionFilter?.getCurrentState() else { return nil }
        return simd_float2(Float(state.x), Float(state.y))
    }
}

private extension ViewController {
    func currentEstimatedPosition() -> simd_double2? {
        guard let state = sensorFusionFilter?.getCurrentState() else { return nil }
        return simd_double2(state.x, state.y)
    }
}

// MARK: - Analysis Functionality
struct AnalysisResult {
    let groundTruth: simd_double2
    let rawMeanError: Double
    let rawRmse: Double
    let rawStdDev: Double
    let rawP95: Double
    let filteredMeanError: Double
    let filteredRmse: Double
    let filteredStdDev: Double
    let filteredP95: Double
}

func analyzeSession(session: RecordedSession) -> Result<AnalysisResult, Error> {
    guard session.task == .staticTest else { return .failure(NSError(domain: "Analysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Analysis only available for 'Static' sessions."])) }
    guard let staticContext = session.staticContext else { return .failure(NSError(domain: "Analysis", code: 2, userInfo: [NSLocalizedDescriptionKey: "Static session is missing ground-truth marker data."])) }
    
    let rawPoints = session.dataPoints.compactMap { $0.rawX != nil ? simd_double2($0.rawX!, $0.rawY!) : nil }
    let filteredPoints = session.dataPoints.compactMap { $0.filteredX != nil ? simd_double2($0.filteredX!, $0.filteredY!) : nil }
    
    guard rawPoints.count > 1, filteredPoints.count > 1 else { return .failure(NSError(domain: "Analysis", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not enough data points to analyze."])) }
    
    func calculateMetrics(points: [simd_double2], truth: simd_double2) -> (mean: Double, rmse: Double, stdDev: Double, p95: Double) {
        let errors = points.map { distance($0, truth) }.sorted()
        let mean = errors.reduce(0, +) / Double(errors.count)
        let rmse = sqrt(errors.map { pow($0, 2) }.reduce(0, +) / Double(errors.count))
        let stdDev = sqrt(errors.map { pow($0 - mean, 2) }.reduce(0, +) / Double(errors.count))
        let p95Index = min(errors.count - 1, Int(Double(errors.count - 1) * 0.95))
        return (mean, rmse, stdDev, errors[p95Index])
    }
    
    let rawMetrics = calculateMetrics(points: rawPoints, truth: staticContext.groundTruth)
    let filteredMetrics = calculateMetrics(points: filteredPoints, truth: staticContext.groundTruth)
    
    return .success(AnalysisResult(
        groundTruth: staticContext.groundTruth,
        rawMeanError: rawMetrics.mean,
        rawRmse: rawMetrics.rmse,
        rawStdDev: rawMetrics.stdDev,
        rawP95: rawMetrics.p95,
        filteredMeanError: filteredMetrics.mean,
        filteredRmse: filteredMetrics.rmse,
        filteredStdDev: filteredMetrics.stdDev,
        filteredP95: filteredMetrics.p95
    ))
}

// MARK: - Child View Controllers
class HelpViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let tv = UITextView()
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.backgroundColor = .secondarySystemBackground
        tv.layer.cornerRadius = 8
        tv.textAlignment = .center
        tv.text = "Optimal Beacon Placement\n\n+-----------------------+\n| B1(0,1)         B2(1,1) |\n|           📱          |\n|                       |\n| B3(0,0)               |\n+-----------------------+\n\nB1: Top-Left, B2: Top-Right, B3: Bottom-Left"
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            tv.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            tv.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            tv.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }
}

class RecordingsListViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    var recordedSessions: [RecordedSession] = []
    private let tableView = UITableView()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }
    
    private func setupUI() {
        view.backgroundColor = .systemBackground
        
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.addTarget(self, action: #selector(closeSheet), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            
            tableView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }
    
    @objc private func closeSheet() { dismiss(animated: true) }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return recordedSessions.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let session = recordedSessions[indexPath.row]
        
        var content = cell.defaultContentConfiguration()
        content.text = session.sessionTitle
        content.secondaryText = String(format: "Duration: %.1f sec, Points: %d", session.duration, session.dataPoints.count)
        cell.contentConfiguration = content
        
        let analyzeButton = UIButton(type: .system)
        analyzeButton.setTitle("Analyze", for: .normal)
        analyzeButton.addAction(UIAction(handler: { _ in self.analyzeTapped(session: session) }), for: .touchUpInside)

        let exportButton = UIButton(type: .system)
        exportButton.setTitle("Export", for: .normal)
        exportButton.addAction(UIAction(handler: { _ in self.exportTapped(session: session, sourceView: exportButton) }), for: .touchUpInside)
        
        let accessoryStack = UIStackView(arrangedSubviews: [analyzeButton, exportButton])
        accessoryStack.axis = .horizontal
        accessoryStack.spacing = 8
        accessoryStack.frame = CGRect(x: 0, y: 0, width: 150, height: 30) // Explicit frame
        
        cell.accessoryView = accessoryStack
        
        return cell
    }
    
    private func analyzeTapped(session: RecordedSession) {
        let result = analyzeSession(session: session)
        DispatchQueue.main.async {
            switch result {
            case .success(let res):
                let msg = String(format: "Ground Truth: (%.3f, %.3f)\n\n--- RAW DATA ---\nMean Error: %.4f m\nRMSE: %.4f m\nStd Dev: %.4f m\nP95: %.4f m\n\n--- FILTERED DATA ---\nMean Error: %.4f m\nRMSE: %.4f m\nStd Dev: %.4f m\nP95: %.4f m", res.groundTruth.x, res.groundTruth.y, res.rawMeanError, res.rawRmse, res.rawStdDev, res.rawP95, res.filteredMeanError, res.filteredRmse, res.filteredStdDev, res.filteredP95)
                self.showAlert(title: "Analysis Result", message: msg)
            case .failure(let err):
                self.showAlert(title: "Analysis Failed", message: err.localizedDescription)
            }
        }
    }
    
    private func exportTapped(session: RecordedSession, sourceView: UIView) {
        let csv = session.generateCSV()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(session.id.uuidString.prefix(4)).csv")
        do {
            try csv.write(to: file, atomically: true, encoding: .utf8)
            let vc = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let popover = vc.popoverPresentationController {
                popover.sourceView = sourceView
            }
            self.present(vc, animated: true)
        } catch { showAlert(title: "Export Error", message: "Failed to generate CSV file.") }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
