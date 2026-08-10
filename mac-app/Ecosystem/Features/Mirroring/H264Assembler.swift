import CoreMedia
import Foundation

/// Turns the phone's Annex-B H.264 frames into CMSampleBuffers ready for an
/// AVSampleBufferDisplayLayer: extracts SPS/PPS from config frames, converts
/// start-code NAL units to AVCC length-prefixed form, and stamps timing.
final class H264Assembler {
    enum AssemblerError: Error {
        case missingParameterSets
        case formatCreationFailed(OSStatus)
        case bufferCreationFailed(OSStatus)
    }

    private var sps: Data?
    private var pps: Data?
    private(set) var formatDescription: CMVideoFormatDescription?

    /// Frame type 0 (codec config): remember SPS/PPS, (re)build the format.
    func handleConfig(_ payload: Data) throws {
        for nal in Self.nalUnits(in: payload) {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            default: break
            }
        }
        guard let sps, let pps else { throw AssemblerError.missingParameterSets }

        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else {
            throw AssemblerError.formatCreationFailed(status)
        }
        formatDescription = format
    }

    /// Frame types 1/2 (key/delta): build a decodable sample buffer.
    func makeSampleBuffer(payload: Data, ptsMicros: Int64) throws -> CMSampleBuffer {
        guard let formatDescription else { throw AssemblerError.missingParameterSets }

        // Annex-B → AVCC: each NAL gets a 4-byte big-endian length prefix.
        var avcc = Data(capacity: payload.count + 16)
        for nal in Self.nalUnits(in: payload) {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            throw AssemblerError.bufferCreationFailed(status)
        }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { throw AssemblerError.bufferCreationFailed(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw AssemblerError.bufferCreationFailed(status)
        }
        // Live stream: display immediately, never wait to reorder.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
            let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sampleBuffer
    }

    /// Splits an Annex-B stream (00 00 01 / 00 00 00 01 start codes) into NALs.
    static func nalUnits(in data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var index = 0
        var nalStart = -1
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let headerLength = (index > 0 && bytes[index - 1] == 0) ? 4 : 3
                let start = index + 3
                if nalStart >= 0 {
                    let end = index - (headerLength - 3)
                    if end > nalStart { units.append(data.subdata(in: nalStart..<end)) }
                }
                nalStart = start
                index = start
            } else {
                index += 1
            }
        }
        if nalStart >= 0 && nalStart < bytes.count {
            units.append(data.subdata(in: nalStart..<bytes.count))
        }
        return units
    }
}
