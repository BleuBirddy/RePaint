import SceneKit
import simd

/// Builds the 3D picture of the model sitting on the bed.
enum MeshScene {
    static func make(mesh: Mesh, bed: Bed) -> SCNScene {
        let scene = SCNScene()

        // Printers call "up" Z; SceneKit calls it Y. Everything hangs off one
        // node that is tipped over, so the rest of the code can keep using
        // printer coordinates.
        let printer = SCNNode()
        printer.eulerAngles.x = -.pi / 2
        // Put the middle of the bed at the scene's origin so the camera
        // orbits around it.
        printer.position = SCNVector3(-bed.width / 2, 0, bed.depth / 2)
        scene.rootNode.addChildNode(printer)

        printer.addChildNode(bedNode(bed))
        printer.addChildNode(modelNode(mesh))

        let camera = SCNCamera()
        camera.zFar = 5000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let reach = max(bed.width, bed.depth)
        cameraNode.position = SCNVector3(0, reach * 0.9, reach * 1.3)
        cameraNode.look(at: SCNVector3(0, mesh.size.z / 2, 0))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    private static func bedNode(_ bed: Bed) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(bed.width), height: CGFloat(bed.depth))
        let material = SCNMaterial()
        material.diffuse.contents = CGColor(red: 0.22, green: 0.23, blue: 0.25, alpha: 1)
        // Visible from underneath too, so orbiting below doesn't hide the bed.
        material.isDoubleSided = true
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.position = SCNVector3(bed.width / 2, bed.depth / 2, 0)
        return node
    }

    private static func modelNode(_ mesh: Mesh) -> SCNNode {
        // One normal per triangle (repeated for its three corners) gives the
        // flat, faceted look that shows the real surface of an STL.
        var normals = [SCNVector3]()
        normals.reserveCapacity(mesh.vertices.count)
        for t in stride(from: 0, to: mesh.vertices.count, by: 3) {
            let a = mesh.vertices[t], b = mesh.vertices[t + 1], c = mesh.vertices[t + 2]
            let cross = simd_cross(b - a, c - a)
            // A triangle squashed to a line has no direction to face.
            let n = simd_length(cross) > 0 ? simd_normalize(cross) : SIMD3<Float>(0, 0, 1)
            normals.append(contentsOf: repeatElement(SCNVector3(n), count: 3))
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0) }),
                SCNGeometrySource(normals: normals),
            ],
            elements: [
                SCNGeometryElement(indices: Array(0..<UInt32(mesh.vertices.count)),
                                   primitiveType: .triangles)
            ])
        let material = SCNMaterial()
        material.diffuse.contents = CGColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        // STL files with inside-out triangles would otherwise show holes.
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}
