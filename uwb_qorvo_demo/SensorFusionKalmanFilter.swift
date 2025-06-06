import Foundation
import simd
import QuartzCore

class SensorFusionKalmanFilter {
    private var state: [Double]
    private var covariance: Matrix
    private let measurementMatrix: Matrix
    private let processAccelerationStdDev: Double = 0.9
    private let minimumMeasurementStdDev: Double = 0.12
    private var lastTimestamp: TimeInterval

    init(initialState: simd_double4, initialCovariance: [[Double]]) {
        self.state = [initialState.x, initialState.y, initialState.z, initialState.w]
        self.covariance = Matrix(rows: 4, cols: 4)
        for row in 0..<4 {
            for col in 0..<4 {
                covariance[row, col] = initialCovariance[row][col]
            }
        }

        var measurementMatrix = Matrix(rows: 2, cols: 4)
        measurementMatrix[0, 0] = 1.0
        measurementMatrix[1, 1] = 1.0
        self.measurementMatrix = measurementMatrix
        self.lastTimestamp = CACurrentMediaTime()
    }

    func predict(with acceleration: simd_double2, timestamp: TimeInterval) {
        let dt = max(0.001, timestamp - lastTimestamp)

        var transition = Matrix.identity(4)
        transition[0, 2] = dt
        transition[1, 3] = dt

        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt2 * dt2
        let q = processAccelerationStdDev * processAccelerationStdDev

        var processNoise = Matrix(rows: 4, cols: 4)
        processNoise[0, 0] = 0.25 * dt4 * q
        processNoise[0, 2] = 0.5 * dt3 * q
        processNoise[1, 1] = 0.25 * dt4 * q
        processNoise[1, 3] = 0.5 * dt3 * q
        processNoise[2, 0] = 0.5 * dt3 * q
        processNoise[2, 2] = dt2 * q
        processNoise[3, 1] = 0.5 * dt3 * q
        processNoise[3, 3] = dt2 * q

        // The ranging stack is more trustworthy than device-frame acceleration.
        // Keep a constant-velocity model and let uncertainty grow with time.
        state = transition * state
        covariance = transition * covariance * transition.transpose + processNoise
        lastTimestamp = timestamp
    }

    func update(with measurement: simd_double2, measurementStdDev: Double) -> simd_double4 {
        let stdDev = max(minimumMeasurementStdDev, measurementStdDev)
        let variance = stdDev * stdDev

        var measurementNoise = Matrix(rows: 2, cols: 2)
        measurementNoise[0, 0] = variance
        measurementNoise[1, 1] = variance

        let innovation = [measurement.x, measurement.y] - (measurementMatrix * state)
        let innovationCovariance = measurementMatrix * covariance * measurementMatrix.transpose + measurementNoise
        guard let innovationCovarianceInv = innovationCovariance.inverse else {
            return getCurrentState()
        }

        let kalmanGain = covariance * measurementMatrix.transpose * innovationCovarianceInv
        let candidateState = state + (kalmanGain * innovation)
        let candidatePosition = simd_double2(candidateState[0], candidateState[1])
        let measurementPosition = simd_double2(measurement.x, measurement.y)
        let innovationDistance = simd_distance(candidatePosition, measurementPosition)

        if innovationDistance > 4.0 * stdDev {
            return getCurrentState()
        }

        state = candidateState
        let identity = Matrix.identity(4)
        covariance = (identity - kalmanGain * measurementMatrix) * covariance
        return getCurrentState()
    }

    func getCurrentState() -> simd_double4 {
        simd_double4(state[0], state[1], state[2], state[3])
    }
}
