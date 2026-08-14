import Foundation
import SceneKit
import simd

struct BuiltModelScene {
    let rootNode: SCNNode
    let boneNodes: [SCNNode]  // 与 ModelScene.bones 平行
}

enum ModelSceneBuilder {

    /// MDX/M3/M2 均为 Z-up 坐标系;SceneKit 为 Y-up。
    /// 内容根节点统一施加 -90°X 旋转(+Z → +Y,+Y → -Z)。
    static let zUpToYUp = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

    /// 模型包围盒中心经 Z-up→Y-up 旋转后的视觉中心(相机取景用)。
    static func visualCenter(of scene: ModelScene) -> SIMD3<Float> {
        zUpToYUp.act((scene.boundsMax + scene.boundsMin) / 2)
    }

    static func build(_ scene: ModelScene, hiddenMaterialTypes: Set<Int> = []) -> BuiltModelScene {
        let root = SCNNode()
        // Z-up → Y-up:统一在内容根上旋转,骨骼树与网格都在其下,变换一致
        root.simdTransform = simd_float4x4(zUpToYUp)

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
        for (i, bone) in scene.bones.enumerated() where bone.parentIndex < 0 {
            root.addChildNode(boneNodes[i])
        }

        // ── 网格:全部作为 root 的直接子节点(与骨骼树平级)。
        // 蒙皮网格挂到骨骼节点下会引入额外/不确定的节点变换,标准做法是与骨架平级。
        // 按材质类型过滤(M3 渲染设置控制;默认空集 = 全部可见)
        for mesh in scene.meshes where !hiddenMaterialTypes.contains(mesh.materialType) {
            let geometry = buildGeometry(mesh)
            let node = SCNNode(geometry: geometry)
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
            root.addChildNode(node)
        }

        // 基础光照,避免全黑
        let light = SCNLight()
        light.type = .omni
        let lightNode = SCNNode()
        lightNode.light = light
        lightNode.position = SCNVector3(5, 10, 5)
        root.addChildNode(lightNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 400
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

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
        // 注意:部分格式(如 SC2 DDS)的纹理 alpha 是遮罩而非透明度,
        // 不透明/additive/modulate 材质必须忽略 alpha,否则被当透明度渲染成近黑。
        switch mat.blendMode {
        case .blend, .alphaTest:
            material.diffuse.contents = mat.diffuseTexture?.cgImage ?? NSColor.systemGray
        case .opaque, .additive, .modulate:
            material.diffuse.contents = mat.diffuseTexture?.cgImageOpaque ?? placeholderColor(for: mat)
        }
        material.isDoubleSided = mat.twoSided
        // M3 贴图可按层设置 UV 环绕;超出 [0,1] 的平铺 UV(HotS 常见)
        // 若 clamp 会采样边缘像素,整模型涂成边缘色带
        material.diffuse.wrapS = mat.wrapU ? .repeat : .clamp
        material.diffuse.wrapT = mat.wrapV ? .repeat : .clamp
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

    /// 无纹理时的占位色,取各混合模式的"不可见"恒等色:
    /// additive 用黑色(加 0)、modulate 用白色(乘 1),其余用灰色标示"无纹理"。
    /// 避免缺失纹理的发光/特效网格渲染成巨大白色块或黑色块。
    private static func placeholderColor(for mat: ModelScene.Material) -> NSColor {
        switch mat.blendMode {
        case .additive:
            return NSColor.black
        case .modulate:
            return NSColor.white
        case .opaque, .alphaTest, .blend:
            return NSColor.systemGray
        }
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
