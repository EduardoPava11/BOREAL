// V1HWeights — loader for the BOREAL V1HW weights package
// (nn/v1/export_model.py). The trained V1-H seed net ships as DATA:
// magic 'V1HW', version 1, JSON config, tensor table, fp16 payload.
//
// SCOPE (honest): this is the PACKAGE + LOADER slice. The on-device
// forward pass (conv kernels consuming these tensors) is the N4 ship
// slice and does not exist yet — the classic path remains the product
// path until it does (circuit A2: classic fallback forever). The
// loader compiles into the gate's surface so the package format is
// pinned by code, not prose.

import Foundation

extension BorealKernels {

    struct V1HTensor {
        let shape: [Int]
        let values: [Float]                  // fp16 payload widened
    }

    struct V1HPackage {
        let config: [String: Any]
        let tensors: [String: V1HTensor]

        var totalParams: Int {
            tensors.values.reduce(0) { $0 + $1.values.count }
        }
    }

    enum V1HWeightsError: Error {
        case badMagic
        case badVersion(UInt16)
        case truncated
        case badConfig
    }

    /// Parse a V1HW package. Layout (little-endian): u32 magic,
    /// u16 version, u16 tensorCount, u32 configLen + JSON, then per
    /// tensor: u16 nameLen + utf8, u8 dtype (0 = f16), u8 ndim,
    /// u32 dims[ndim], u32 byteLen + fp16 payload.
    static func loadV1HWeights(_ data: Data) throws -> V1HPackage {
        var off = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            guard off + MemoryLayout<T>.size <= data.count else {
                throw V1HWeightsError.truncated
            }
            var v: T = 0
            _ = withUnsafeMutableBytes(of: &v) {
                data.copyBytes(to: $0, from: off..<(off + MemoryLayout<T>.size))
            }
            off += MemoryLayout<T>.size
            return T(littleEndian: v)
        }
        func readBytes(_ n: Int) throws -> Data {
            guard off + n <= data.count else { throw V1HWeightsError.truncated }
            defer { off += n }
            return data.subdata(in: off..<(off + n))
        }

        guard try read(UInt32.self) == 0x56314857 else {
            throw V1HWeightsError.badMagic
        }
        let version = try read(UInt16.self)
        guard version == 1 else { throw V1HWeightsError.badVersion(version) }
        let count = Int(try read(UInt16.self))
        let cfgLen = Int(try read(UInt32.self))
        let cfgData = try readBytes(cfgLen)
        guard let cfgObj = try? JSONSerialization.jsonObject(with: cfgData),
              let config = cfgObj as? [String: Any] else {
            throw V1HWeightsError.badConfig
        }

        var tensors: [String: V1HTensor] = [:]
        for _ in 0..<count {
            let nameLen = Int(try read(UInt16.self))
            let name = String(decoding: try readBytes(nameLen), as: UTF8.self)
            _ = try read(UInt8.self)                     // dtype: 0 = f16
            let ndim = Int(try read(UInt8.self))
            var shape: [Int] = []
            for _ in 0..<ndim { shape.append(Int(try read(UInt32.self))) }
            let byteLen = Int(try read(UInt32.self))
            let payload = try readBytes(byteLen)
            var values = [Float](repeating: 0, count: byteLen / 2)
            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let src = raw.bindMemory(to: UInt16.self)
                for i in 0..<values.count {
                    values[i] = Float(Float16(bitPattern:
                        UInt16(littleEndian: src[i])))
                }
            }
            tensors[name] = V1HTensor(shape: shape, values: values)
        }
        return V1HPackage(config: config, tensors: tensors)
    }
}
