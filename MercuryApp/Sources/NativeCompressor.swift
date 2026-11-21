import AVFoundation

/// Uses Apple's HEVC encoder only when a recording exceeds its size budget.
enum NativeCompressor {
    static func compress(_ input: URL, to output: URL, bitsPerPixel: Double,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Mercury", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let size = try await video.load(.naturalSize)
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        let fps = try await video.load(.nominalFrameRate)
        let rate = max(800_000, Int(size.width * size.height * bitsPerPixel))
        let rawSize = (try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber)?.intValue ?? 0
        guard duration > 0, Double(rawSize) * 8 / duration > Double(rate) * 1.2 else {
            try FileManager.default.moveItem(at: input, to: output)
            return output
        }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-optimizing.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: rate,
                AVVideoExpectedSourceFrameRateKey: max(1, Int(fps.rounded())),
                AVVideoMaxKeyFrameIntervalDurationKey: 10,
                AVVideoAllowFrameReorderingKey: true
            ]
        ])
        videoInput.transform = try await video.load(.preferredTransform)
        reader.add(videoOutput)
        writer.add(videoInput)
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let format = try await track.load(.formatDescriptions).first
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            reader.add(audioOutput)
            writer.add(audioInput)
            audioPairs.append((audioOutput, audioInput))
        }
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error! }
        do {
            var tracks = [(videoOutput, videoInput)] + audioPairs
            while !tracks.isEmpty {
                try Task.checkCancellation()
                var advanced = false
                for index in tracks.indices.reversed() {
                    let (source, destination) = tracks[index]
                    guard destination.isReadyForMoreMediaData else { continue }
                    advanced = true
                    if let sample = source.copyNextSampleBuffer() {
                        guard destination.append(sample) else {
                            throw writer.error ?? NSError(domain: "Mercury", code: 2)
                        }
                        if index == 0 {
                            progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                        }
                    } else {
                        destination.markAsFinished()
                        tracks.remove(at: index)
                    }
                }
                if writer.status == .failed { throw writer.error! }
                if !advanced { try await Task.sleep(for: .milliseconds(2)) }
            }
            guard reader.status == .completed else { throw reader.error ?? NSError(domain: "Mercury", code: 3) }
            writer.endSession(atSourceTime: assetDuration)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Mercury", code: 4) }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        let encodedSize = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? 0
        if encodedSize > 0 && encodedSize < rawSize {
            try FileManager.default.moveItem(at: temporary, to: output)
            try? FileManager.default.removeItem(at: input)
        } else {
            try FileManager.default.moveItem(at: input, to: output)
        }
        progress(1)
        return output
    }
}
