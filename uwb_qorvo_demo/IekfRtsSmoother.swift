import Foundation
import simd

// MARK: - Matrix & Vector Lib
// A basic matrix and vector library to support the filter math.
struct Matrix {
    var rows: Int, cols: Int
    var grid: [Double]

    init(rows: Int, cols: Int, repeating value: Double = 0.0) {
        self.rows = rows
        self.cols = cols
        self.grid = Array(repeating: value, count: rows * cols)
    }

    subscript(row: Int, col: Int) -> Double {
        get { grid[(row * cols) + col] }
        set { grid[(row * cols) + col] = newValue }
    }

    static func identity(_ size: Int) -> Matrix {
        var mat = Matrix(rows: size, cols: size)
        for i in 0..<size { mat[i, i] = 1.0 }
        return mat
    }

    var transpose: Matrix {
        var mat = Matrix(rows: cols, cols: rows)
        for r in 0..<rows {
            for c in 0..<cols {
                mat[c, r] = self[r, c]
            }
        }
        return mat
    }

    // Basic LU-decomposition based inversion
    var inverse: Matrix? {
        guard rows == cols else { return nil }
        var mat = self
        var inv = Matrix.identity(rows)
        
        for i in 0..<rows {
            var pivot = i
            for j in i+1..<rows {
                if abs(mat[j, i]) > abs(mat[pivot, i]) { pivot = j }
            }
            if pivot != i {
                mat.grid.swapAt(i, pivot)
                inv.grid.swapAt(i, pivot)
            }
            
            let divisor = mat[i, i]
            guard abs(divisor) > 1e-12 else { return nil }
            
            for j in 0..<cols {
                mat[i, j] /= divisor
                inv[i, j] /= divisor
            }
            
            for j in 0..<rows {
                if i != j {
                    let multiple = mat[j, i]
                    for k in 0..<cols {
                        mat[j, k] -= multiple * mat[i, k]
                        inv[j, k] -= multiple * inv[i, k]
                    }
                }
            }
        }
        return inv
    }
}

// Matrix-Vector and Matrix-Matrix operations
func *(lhs: Matrix, rhs: Double) -> Matrix {
    var result = lhs
    for i in 0..<result.grid.count {
        result.grid[i] *= rhs
    }
    return result
}

func *(lhs: Matrix, rhs: [Double]) -> [Double] {
    var result = [Double](repeating: 0.0, count: lhs.rows)
    for r in 0..<lhs.rows {
        for c in 0..<lhs.cols {
            result[r] += lhs[r, c] * rhs[c]
        }
    }
    return result
}

func *(lhs: Matrix, rhs: Matrix) -> Matrix {
    var result = Matrix(rows: lhs.rows, cols: rhs.cols)
    for r in 0..<lhs.rows {
        for c in 0..<rhs.cols {
            for i in 0..<lhs.cols {
                result[r, c] += lhs[r, i] * rhs[i, c]
            }
        }
    }
    return result
}

func +(lhs: Matrix, rhs: Matrix) -> Matrix {
    var result = lhs
    for i in 0..<result.grid.count { result.grid[i] += rhs.grid[i] }
    return result
}

func -(lhs: Matrix, rhs: Matrix) -> Matrix {
    var result = lhs
    for i in 0..<result.grid.count { result.grid[i] -= rhs.grid[i] }
    return result
}

func +(lhs: [Double], rhs: [Double]) -> [Double] {
    zip(lhs, rhs).map(+)
}
func -(lhs: [Double], rhs: [Double]) -> [Double] {
    zip(lhs, rhs).map(-)
}


// MARK: - IEKF & RTS Smoother
class IekfRtsSmoother {
    
    struct SmoothedState {
        let timestamp: TimeInterval
        let state: [Double] // [x, y, vx, vy]
        let covariance: Matrix
    }

    private let anchorPositions: [simd_double2]
    private let maxIterations = 10
    private let tolerance = 1e-6

    init(anchorPositions: [simd_double2]) {
        self.anchorPositions = anchorPositions
    }
    
    func process(session: RecordedSession) -> [simd_double2]? {
        let measurements = session.dataPoints.compactMap { dataPoint -> (time: TimeInterval, ranges: [Double])? in
            // For now, we are assuming 3 anchors and direct use of rawX/rawY as a pseudo-measurement
            // This needs to be adapted to use actual ranges when available.
            // Here, we generate pseudo-ranges from raw positions for demonstration.
            guard let x = dataPoint.rawX, let y = dataPoint.rawY else { return nil }
            let pos = simd_double2(x, y)
            let ranges = anchorPositions.map { simd_distance($0, pos) }
            return (dataPoint.timestamp, ranges)
        }
        
        guard measurements.count > 2 else { return nil }
        
        // --- Forward Pass: IEKF ---
        var filteredStates: [SmoothedState] = []
        
        // Initial state: Use first measurement to get a position guess
        var x_hat = [measurements[0].ranges[0], measurements[0].ranges[1], 0.0, 0.0]
        var P_hat = Matrix.identity(4) * 0.1
        var K = Matrix(rows: 4, cols: 3)
        
        for i in 1..<measurements.count {
            let dt = measurements[i].time - measurements[i-1].time
            
            // Prediction
            var F = Matrix(rows: 4, cols: 4); F.grid = [1,0,dt,0, 0,1,0,dt, 0,0,1,0, 0,0,0,1]
            let Q = Matrix.identity(4) * 0.01 // Process noise
            
            var x_pred = F * x_hat
            var P_pred = F * P_hat * F.transpose + Q
            
            // Update
            let z = measurements[i].ranges
            var x_iter = x_pred
            
            for _ in 0..<maxIterations {
                let H = jacobianH(state: x_iter)
                let h_x = h(state: x_iter)
                let y = z - h_x // Innovation
                
                let R = Matrix.identity(3) * 0.1 // Measurement noise
                let S = H * P_pred * H.transpose + R
                guard let S_inv = S.inverse else { break }
                K = P_pred * H.transpose * S_inv
                
                let x_new = x_pred + K * y
                
                if simd_distance_squared(simd_double4(x_new), simd_double4(x_iter)) < tolerance {
                    break
                }
                x_iter = x_new
            }
            
            x_hat = x_iter
            let I = Matrix.identity(4)
            let H = jacobianH(state: x_hat)
            P_hat = (I - (K * H)) * P_pred
            
            filteredStates.append(SmoothedState(timestamp: measurements[i].time, state: x_hat, covariance: P_hat))
        }
        
        // --- Backward Pass: RTS Smoother ---
        var smoothedStates = filteredStates
        for i in (0..<smoothedStates.count - 1).reversed() {
            let dt = smoothedStates[i+1].timestamp - smoothedStates[i].timestamp
            var F = Matrix(rows: 4, cols: 4); F.grid = [1,0,dt,0, 0,1,0,dt, 0,0,1,0, 0,0,0,1]
            
            let P_k = smoothedStates[i].covariance
            let P_k1_pred = F * P_k * F.transpose + (Matrix.identity(4) * 0.01)
            guard let P_k1_pred_inv = P_k1_pred.inverse else { continue }
            
            let G = P_k * F.transpose * P_k1_pred_inv // Smoother gain
            
            let x_k_smooth = smoothedStates[i].state + G * (smoothedStates[i+1].state - (F * smoothedStates[i].state))
            let P_k_smooth = P_k + G * (smoothedStates[i+1].covariance - P_k1_pred) * G.transpose
            
            smoothedStates[i] = SmoothedState(timestamp: smoothedStates[i].timestamp, state: x_k_smooth, covariance: P_k_smooth)
        }
        
        return smoothedStates.map { simd_double2($0.state[0], $0.state[1]) }
    }
    
    // Measurement model: h(x) -> expected ranges
    private func h(state: [Double]) -> [Double] {
        let pos = simd_double2(state[0], state[1])
        return anchorPositions.map { simd_distance($0, pos) }
    }
    
    // Jacobian of the measurement model
    private func jacobianH(state: [Double]) -> Matrix {
        let x = state[0], y = state[1]
        var H = Matrix(rows: 3, cols: 4)
        for i in 0..<anchorPositions.count {
            let p_a = anchorPositions[i]
            let dist = simd_distance(p_a, simd_double2(x, y))
            if dist > 1e-6 {
                H[i, 0] = (x - p_a.x) / dist
                H[i, 1] = (y - p_a.y) / dist
            }
        }
        return H
    }
}

extension simd_double4 {
    init(_ arr: [Double]) {
        self.init(arr[0], arr[1], arr[2], arr[3])
    }
}