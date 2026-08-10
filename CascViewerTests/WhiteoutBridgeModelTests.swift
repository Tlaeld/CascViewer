import XCTest
import CascBridge
@testable import CascViewer

final class WhiteoutBridgeModelTests: XCTestCase {

    private func parseMDX(_ bytes: Data) -> WhiteoutBridge.WOModel {
        var error = WhiteoutBridge.WOError.None
        var loader = WhiteoutBridge.WOModelLoader()
        return bytes.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return loader.parseMDX(ptr, bytes.count, &error)
        }
    }

    func testMDXRoundTrip() {
        let bytes = WhiteoutBridge.WOEncodeTestMDX()
        XCTAssertGreaterThan(bytes.size(), 0)
        let model = parseMDX(Data(bytes))

        XCTAssertEqual(model.format, WhiteoutBridge.WOModelFormat.MDX)
        XCTAssertEqual(model.meshes.size(), 1)
        XCTAssertEqual(model.meshes[0].positions.size(), 3)      // 三角形
        XCTAssertEqual(model.meshes[0].indices.size(), 3)
        XCTAssertEqual(model.meshes[0].boneIndices.size(), 3 * 4) // 4 个/顶点,扁平
        XCTAssertEqual(model.materials.size(), 1)
        XCTAssertEqual(model.bones.size(), 2)
        XCTAssertEqual(model.bones[1].parentIndex, 0)
        XCTAssertEqual(model.animations.size(), 1)
        XCTAssertEqual(String(model.animations[0].name), "Stand")
        XCTAssertEqual(model.animations[0].durationMs, 1000)
        // bone1 的位移轨道:2 个关键帧
        let track = model.animations[0].translations[1]
        XCTAssertEqual(track.times.size(), 2)
        XCTAssertEqual(track.keys.size(), 2)
        XCTAssertEqual(track.times[0], 0)
        XCTAssertEqual(track.times[1], 1000)
        // bone0 无轨道
        XCTAssertEqual(model.animations[0].translations[0].times.size(), 0)
    }

    func testMDXGarbageFails() {
        let garbage: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        var error = WhiteoutBridge.WOError.None
        var loader = WhiteoutBridge.WOModelLoader()
        garbage.withUnsafeBufferPointer { buf in
            _ = loader.parseMDX(buf.baseAddress!, buf.count, &error)
        }
        XCTAssertEqual(error, WhiteoutBridge.WOError.ParseFailed)
    }
}
