import Foundation
import CoreMotion
import simd

class CoreMotionManager {
    private let motionManager = CMMotionManager()
    
    // Closure to be called when new acceleration data is available
    var onAccelerationData: ((simd_double2) -> Void)?
    
    init() {
        // Configure the motion manager
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz
    }
    
    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            customPrint("CoreMotionManager: Device motion is not available.")
            return
        }
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] (motion, error) in
            guard let self = self, let motion = motion else {
                if let error = error {
                    customPrint("CoreMotionManager Error: \(error.localizedDescription)")
                }
                return
            }
            
            // Get user acceleration (gravity removed) and attitude (orientation)
            let userAcceleration = motion.userAcceleration
            let attitude = motion.attitude
            
            // Create a rotation matrix from the device's attitude
            let rotationMatrix = self.rotationMatrix(from: attitude)
            
            // Rotate the acceleration vector into the world frame to get a consistent reference
            let accelerationInWorldFrame = self.rotate(vector: userAcceleration, with: rotationMatrix)
            
            // We are interested in the x and y components for 2D positioning
            let acceleration2D = simd_double2(accelerationInWorldFrame.x, accelerationInWorldFrame.y)
            
            // Pass the data to the handler
            self.onAccelerationData?(acceleration2D)
        }
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
    
    // MARK: - Helper Functions
    
    private func rotationMatrix(from attitude: CMAttitude) -> simd_double3x3 {
        let roll = attitude.roll
        let pitch = attitude.pitch
        let yaw = attitude.yaw
        
        let cosRoll = cos(roll)
        let sinRoll = sin(roll)
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        
        // Rotation matrix for roll (around X-axis)
        let Rx = simd_double3x3(rows: [
            simd_double3(1, 0, 0),
            simd_double3(0, cosRoll, -sinRoll),
            simd_double3(0, sinRoll, cosRoll)
        ])
        
        // Rotation matrix for pitch (around Y-axis)
        let Ry = simd_double3x3(rows: [
            simd_double3(cosPitch, 0, sinPitch),
            simd_double3(0, 1, 0),
            simd_double3(-sinPitch, 0, cosPitch)
        ])
        
        // Rotation matrix for yaw (around Z-axis)
        let Rz = simd_double3x3(rows: [
            simd_double3(cosYaw, -sinYaw, 0),
            simd_double3(sinYaw, cosYaw, 0),
            simd_double3(0, 0, 1)
        ])
        
        // Combined rotation matrix (Z-Y-X order is common for device orientation)
        return Rz * Ry * Rx
    }
    
    private func rotate(vector: CMAcceleration, with matrix: simd_double3x3) -> simd_double3 {
        let vector3 = simd_double3(vector.x, vector.y, vector.z)
        return matrix * vector3
    }
}