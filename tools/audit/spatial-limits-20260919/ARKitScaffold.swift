// Hardware boundary only. The actual recorder, queues, quality policy, image
// writer, manifests and validators are compiled unchanged against these values.
import Foundation
import CoreVideo
import simd

public protocol ARSessionDelegate: AnyObject {}
public final class ARSession: NSObject {
    public func pause() {}
}
public final class ARCamera {
    public enum TrackingState {
        public enum Reason { case initializing, excessiveMotion, insufficientFeatures, relocalizing }
        case normal, notAvailable, limited(Reason)
    }
    public let trackingState: TrackingState
    public let imageResolution: CGSize
    public let transform: simd_float4x4
    public let intrinsics: simd_float3x3
    public let exposureDuration: Double = 0.01
    public let exposureOffset: Float = 0
    public init(transform: simd_float4x4, intrinsics: simd_float3x3,
                imageResolution: CGSize, trackingState: TrackingState = .normal) {
        self.transform = transform; self.intrinsics = intrinsics
        self.imageResolution = imageResolution; self.trackingState = trackingState
    }
}
public final class ARPointCloud {
    public let points: [SIMD3<Float>]
    public let identifiers: [UInt64]
    public init(points: [SIMD3<Float>], identifiers: [UInt64]) {
        self.points = points; self.identifiers = identifiers
    }
}
public final class ARFrame {
    public enum WorldMappingStatus { case notAvailable, limited, extending, mapped }
    public let timestamp: Double
    public let camera: ARCamera
    public let capturedImage: CVPixelBuffer
    public let rawFeaturePoints: ARPointCloud?
    public let worldMappingStatus: WorldMappingStatus = .mapped
    public init(timestamp: Double, camera: ARCamera, capturedImage: CVPixelBuffer, cloud: ARPointCloud?) {
        self.timestamp = timestamp; self.camera = camera
        self.capturedImage = capturedImage; self.rawFeaturePoints = cloud
    }
}
