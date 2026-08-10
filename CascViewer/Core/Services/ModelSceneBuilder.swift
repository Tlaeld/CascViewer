import Foundation
import SceneKit
import simd

struct BuiltModelScene {
    let rootNode: SCNNode
    let boneNodes: [SCNNode]  // 与 ModelScene.bones 平行
}

enum ModelSceneBuilder {

    static func build(_ scene: ModelScene) -> BuiltModelScene {
        let root = SCNNode()

        // ── 骨骼节点树(rest 变换;MDX/M2 的锚点公式在 AnimationPlayer 中处理,
        //    这里 rest 局部变换统一为 T(restTranslation) R(restRotation) S(restScale),
        //    MDX/M2 的 rest* 全为默认值,等价单位阵——绑定姿态即恒等)──
        let boneNodes = scene.bones.map { bone -> SCNNode in
            let node = SCNNode()
            node.name = bone.name
            node.simdTransform = translationMatrix(bone.restTranslation)
                * simd_float4x4(bone.restRotation)
                * scaleMatrix(bone.restScale)
            return node
        }
        for (i, bone) in scene.bones.enumerated() where bone.parentIndex >= 0
            && bone.parentIndex < boneNodes.count {
            boneNodes[bone.parentIndex].addChildNode(boneNodes[i])
        }
        var rootBoneNodes: [SCNNode] = []
        for (i, bone) in scene.bones.enumerated() where bone.parentIndex < 0 {
            root.addChildNode(boneNodes[i])
            rootBoneNodes.append(boneNodes[i])
        }

        // ── 网格 ──
        // 结构契约(ModelSceneBuilderTests):root 的直接子节点是骨骼树根,
        // 几何/蒙皮挂在它上面(单一网格 + 单一根骨骼时 root 恰有 1 个子节点)。
        // 因此网格按序绑到根骨骼节点;根骨骼不够用时(多网格模型)溢出网格
        // 作为 root 的普通子节点,保证不丢网格。
        for (m, mesh) in scene.meshes.enumerated() {
            let geometry = buildGeometry(mesh)
            let node: SCNNode
            if m < rootBoneNodes.count {
                node = rootBoneNodes[m]
            } else {
                node = SCNNode()
                root.addChildNode(node)
            }
            node.geometry = geometry
            node.geometry?.firstMaterial = buildMaterial(
                mesh.materialIndex >= 0 && mesh.materialIndex < scene.materials.count
                    ? scene.materials[mesh.materialIndex] : nil
            )
            if !scene.bones.isEmpty && !mesh.boneIndices.isEmpty {
                node.skinner = buildSkinner(mesh: mesh, bones: scene.bones,
                                            boneNodes: boneNodes,
                                            baseGeometry: geometry)
                node.skinner?.skeleton = root
            }
        }

        // 基础光照,避免全黑(挂在骨骼树根下以维持上述结构契约;无骨骼时挂 root)
        let lightParent = rootBoneNodes.first ?? root
        let light = SCNLight()
        light.type = .omni
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(5, 10, 5)
        lightParent.addChildNode(lightNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 400
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        lightParent.addChildNode(ambientNode)

        return BuiltModelScene(rootNode: root, boneNodes: boneNodes)
    }

    private static func buildGeometry(_ mesh: ModelScene.Mesh) -> SCNGeometry {
        // SIMD3<Float> 内存 stride 为 16(12 字节数据 + 4 字节 padding),
        // 必须按 stride 16 打包,否则顶点 ≥1 全部错位
        let vertexData = Data(bytes: mesh.positions, count: mesh.positions.count * 16)
        let positionSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex,
            vectorCount: mesh.positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 16
        )
        let normalData = Data(bytes: mesh.normals, count: mesh.normals.count * 16)
        let normalSource = SCNGeometrySource(
            data: normalData, semantic: .normal,
            vectorCount: mesh.normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 16
        )
        let uvData = Data(bytes: mesh.uvs, count: mesh.uvs.count * 8)
        let uvSource = SCNGeometrySource(
            data: uvData, semantic: .texcoord,
            vectorCount: mesh.uvs.count,
            usesFloatComponents: true, componentsPerVector: 2,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 8
        )
        let indexData = mesh.indices.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: mesh.indices.count / 3, bytesPerIndex: 4
        )
        return SCNGeometry(sources: [positionSource, normalSource, uvSource],
                           elements: [element])
    }

    private static func buildSkinner(mesh: ModelScene.Mesh, bones: [ModelScene.Bone],
                                     boneNodes: [SCNNode],
                                     baseGeometry: SCNGeometry) -> SCNSkinner {
        // SceneKit 骨骼权重格式:每顶点 4 个 UInt16 索引 + 4 个 Float 权重
        var weightIndices: [UInt16] = []
        var weightValues: [Float] = []
        weightIndices.reserveCapacity(mesh.boneIndices.count * 4)
        weightValues.reserveCapacity(mesh.boneWeights.count * 4)
        for v in 0..<mesh.boneIndices.count {
            for j in 0..<4 {
                weightIndices.append(UInt16(mesh.boneIndices[v][j]))
                weightValues.append(Float(mesh.boneWeights[v][j]) / 255.0)
            }
        }
        let weightIndicesData = weightIndices.withUnsafeBufferPointer { Data(buffer: $0) }
        let weightValuesData = weightValues.withUnsafeBufferPointer { Data(buffer: $0) }
        let boneIndicesSource = SCNGeometrySource(
            data: weightIndicesData, semantic: .boneIndices,
            vectorCount: mesh.boneIndices.count,
            usesFloatComponents: false, componentsPerVector: 4,
            bytesPerComponent: 2, dataOffset: 0, dataStride: 8
        )
        let boneWeightsSource = SCNGeometrySource(
            data: weightValuesData, semantic: .boneWeights,
            vectorCount: mesh.boneWeights.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 16
        )
        // SDK 要求 [NSValue](SCNMatrix4),不能直接传 [simd_float4x4]
        return SCNSkinner(
            baseGeometry: baseGeometry,
            bones: boneNodes,
            boneInverseBindTransforms: bones.map { NSValue(scnMatrix4: SCNMatrix4($0.inverseBind)) },
            boneWeights: boneWeightsSource,
            boneIndices: boneIndicesSource
        )
    }

    private static func buildMaterial(_ mat: ModelScene.Material?) -> SCNMaterial {
        let material = SCNMaterial()
        guard let mat = mat else {
            material.diffuse.contents = NSColor.systemGray  // 占位
            return material
        }
        if let tex = mat.diffuseTexture, let image = tex.cgImage {
            material.diffuse.contents = image
        } else {
            material.diffuse.contents = NSColor.systemGray
        }
        material.isDoubleSided = mat.twoSided
        material.lightingModel = mat.unlit ? .constant : .blinn
        switch mat.blendMode {
        case .opaque:
            material.blendMode = .replace
        case .alphaTest:
            material.blendMode = .replace
            material.transparencyMode = .aOne   // alpha 裁剪近似
        case .blend:
            material.blendMode = .alpha
        case .additive:
            material.blendMode = .add
        case .modulate:
            material.blendMode = .multiply
        }
        return material
    }

    private static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m[3, 0] = t.x; m[3, 1] = t.y; m[3, 2] = t.z
        return m
    }

    private static func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m[0, 0] = s.x; m[1, 1] = s.y; m[2, 2] = s.z
        return m
    }
}
