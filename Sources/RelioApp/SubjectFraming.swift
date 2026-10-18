import Foundation
import AVFoundation
import Vision
import CoreGraphics

struct FramingSample {
    var time: Double
    var subject: CGRect?
    var cutTime: Double? = nil
    var preserveWholeFrame: Bool = false
}

/// Analyze subject identity first, then plan the camera with future frames available.
/// Offline planning avoids the delay inherent in chasing each observation with a filter.
enum SubjectFramer {
    static let version = 19

    private struct Candidate {
        var observation: VNDetectedObjectObservation
        var person: Bool
        var score: Double
        var isPanel: Bool = false
    }

    static func analyze(_ url: URL, start: Double, duration: Double, zoom: Double, useSemanticModel: Bool = true, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> [CropKeyframe] {
        let worker = Task.detached(priority: .utility) { () async -> [CropKeyframe] in
            guard start.isFinite, duration.isFinite, duration > 0 else { return [] }
            let semanticModelEnabled = useSemanticModel && LocalVision.isInstalled
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 540)
            // Default tolerances can return a distant keyframe. Tracking must see the
            // requested moment, not a repeated image from an earlier part of the video.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let step = 0.08
            let count = max(1, Int(ceil(duration / step)))
            var samples: [FramingSample] = []
            var previousGrid: [UInt8]?
            var previousTime = 0.0
            var usualDifference = 0.02
            var sequence = VNSequenceRequestHandler()
            var tracking: VNTrackObjectRequest?
            var subjectBox: CGRect?
            var subjectIsPerson = false
            var lastVision = -Double.infinity
            var lastDetection = -Double.infinity
            var lastReliable = -Double.infinity
            var preserveWholeFrame = false
            var imageSize = CGSize(width: 16, height: 9)

            func image(at time: Double) -> CGImage? {
                try? generator.copyCGImage(at: CMTime(seconds: start + time, preferredTimescale: 600), actualTime: nil)
            }
            for index in 0..<count {
                if Task.isCancelled { return [] }
                if index.isMultiple(of: 4) { progress(Double(index) / Double(count)) }
                let time = min(duration - 0.001, Double(index) * step)
                guard let frame = image(at: time) else { continue }
                imageSize = CGSize(width: frame.width, height: frame.height)
                let grid = luminanceGrid(frame)
                var cutTime: Double?
                if let previousGrid, let grid {
                    let difference = distance(previousGrid, grid)
                    // Dark diagrams can change entirely while their mean luminance changes
                    // very little. Compare the changed signal with the scene's energy.
                    let energy = zip(previousGrid, grid).reduce(0.0) { $0 + Double(max($1.0, $1.1)) } / Double(grid.count) / 255
                    let relativeChange = difference / max(0.06, energy)
                    let isCut = difference > 0.32 ||
                        (difference > 0.16 && difference > usualDifference * 2.6) ||
                        (difference > 0.045 && relativeChange > 0.55 && difference > usualDifference * 3)
                    if isCut {
                        // Locate the source cut inside the sample interval, so export
                        // changes framing on the cut instead of sliding after it.
                        var before = previousTime
                        var after = time
                        for _ in 0..<4 {
                            let middle = (before + after) / 2
                            guard let middleImage = image(at: middle), let middleGrid = luminanceGrid(middleImage) else { break }
                            if distance(middleGrid, previousGrid) < distance(middleGrid, grid) { before = middle }
                            else { after = middle }
                        }
                        cutTime = after
                        tracking = nil
                        subjectBox = nil
                        subjectIsPerson = false
                        lastDetection = -Double.infinity
                        lastReliable = -Double.infinity
                        sequence = VNSequenceRequestHandler()
                        preserveWholeFrame = false
                        usualDifference = 0.02
                    } else {
                        usualDifference = usualDifference * 0.85 + difference * 0.15
                    }
                }
                previousGrid = grid
                previousTime = time

                var tracked: VNDetectedObjectObservation?
                if let tracking {
                    if (try? sequence.perform([tracking], on: frame)) != nil,
                       let result = tracking.results?.first as? VNDetectedObjectObservation,
                       result.confidence >= 0.55 {
                        tracked = result
                        tracking.inputObservation = result
                    }
                }
                if tracked == nil || time - lastDetection >= 0.24 {
                    var semantic: Candidate?
                    if semanticModelEnabled && (cutTime != nil || time - lastVision >= 3 || tracked == nil) {
                        if let subject = await LocalVision.shared.subject(in: frame, newScene: cutTime != nil || index == 0) {
                            preserveWholeFrame = subject.preserveWholeFrame
                            semantic = Candidate(observation: VNDetectedObjectObservation(boundingBox: subject.box), person: false, score: 10)
                        }
                        lastVision = time
                    }
                    let candidates = detect(in: frame)
                    let anchor = tracked?.boundingBox ?? subjectBox
                    let chosen: Candidate?
                    if let semantic {
                        chosen = semantic
                    } else if !semanticModelEnabled, let panel = candidates.first(where: \.isPanel) {
                        chosen = panel
                    } else if let anchor, time - lastReliable < 0.75, cutTime == nil {
                        // Match the same subject by overlap and distance. An unrelated
                        // larger object must not steal the camera in the middle of a shot.
                        let compatible = candidates.filter {
                            $0.person == subjectIsPerson && (overlap(anchor, $0.observation.boundingBox) > 0.12 ||
                                hypot(anchor.midX - $0.observation.boundingBox.midX, anchor.midY - $0.observation.boundingBox.midY) < 0.16)
                        }
                        chosen = compatible.max { matchingScore($0, anchor) < matchingScore($1, anchor) }
                    } else {
                        // Agree across nearby frames before committing to a shot's subject.
                        // A transient bright patch should not become the permanent target.
                        let future = [0.16, 0.32].compactMap { delta -> [Candidate]? in
                            guard time + delta < duration, let next = image(at: time + delta) else { return nil }
                            if let grid, let nextGrid = luminanceGrid(next), distance(grid, nextGrid) > 0.16 { return nil }
                            return detect(in: next)
                        }
                        chosen = candidates.max { a, b in
                            func stableScore(_ candidate: Candidate) -> Double {
                                let support = future.reduce(0.0) { sum, observations in
                                    sum + (observations.filter { $0.person == candidate.person }.map {
                                        overlap(candidate.observation.boundingBox, $0.observation.boundingBox)
                                    }.max() ?? 0)
                                }
                                return candidate.score * (1 + support)
                            }
                            return stableScore(a) < stableScore(b)
                        }
                    }
                    if let chosen {
                        if chosen.person { preserveWholeFrame = false }
                        if chosen.isPanel { preserveWholeFrame = true }
                        tracked = chosen.observation
                        subjectIsPerson = chosen.person
                        let request = VNTrackObjectRequest(detectedObjectObservation: chosen.observation)
                        request.trackingLevel = .accurate
                        tracking = request
                        lastReliable = time
                    }
                    lastDetection = time
                }
                if let tracked {
                    subjectBox = tracked.boundingBox
                    lastReliable = time
                } else if time - lastReliable > 0.6 {
                    subjectBox = nil
                    tracking = nil
                }
                samples.append(.init(time: time, subject: subjectBox, cutTime: cutTime, preserveWholeFrame: preserveWholeFrame))
            }
            progress(1)
            return plan(samples, duration: duration, imageSize: imageSize, zoom: zoom)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func detect(in image: CGImage) -> [Candidate] {
        let handler = VNImageRequestHandler(cgImage: image)
        let people = VNDetectHumanRectanglesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? handler.perform([people, faces, objects, attention])) != nil else { return [] }
        func candidate(_ observation: VNDetectedObjectObservation, person: Bool, weight: Double) -> Candidate {
            let box = observation.boundingBox
            let area = min(0.6, Double(box.width * box.height))
            let centerPreference = 0.7 + 0.3 * (1 - min(1, abs(Double(box.midX) - 0.5) * 2))
            return .init(observation: observation, person: person,
                         score: weight * Double(observation.confidence) * sqrt(max(0.001, area)) * centerPreference)
        }
        let humans = (people.results ?? []).filter { $0.confidence >= 0.55 }.map { candidate($0, person: true, weight: 2.5) }
        let facial = (faces.results ?? []).filter { $0.confidence >= 0.65 }.map { candidate($0, person: true, weight: 3.2) }
        let salient = (objects.results?.first?.salientObjects ?? []).filter {
            let box = $0.boundingBox
            return $0.confidence >= 0.3 && box.width * box.height >= 0.015 && !(box.width > 0.95 && box.height > 0.95)
        }.map { candidate($0, person: false, weight: 1) }
        let attentionBoxes = (attention.results?.first?.salientObjects ?? []).filter {
            $0.confidence >= 0.4 && $0.boundingBox.width * $0.boundingBox.height > 0.02 && $0.boundingBox.width < 0.8
        }.map { candidate($0, person: false, weight: 0.65) }
        // A face anchors framing to the speaker instead of the center of a broad body box.
        let bodies = humans.filter { human in !facial.contains { face in
            human.observation.boundingBox.contains(CGPoint(x: face.observation.boundingBox.midX, y: face.observation.boundingBox.midY))
        } }
        let illustrated = screenPanel(image).map {
            Candidate(observation: VNDetectedObjectObservation(boundingBox: $0), person: false, score: 2.8 * sqrt(Double($0.width * $0.height)), isPanel: true)
        }
        return bodies + facial + salient + attentionBoxes + (illustrated.map { [$0] } ?? [])
    }

    /// Preserve the context of text-dense diagrams instead of chasing a small
    /// salient object or selecting one panel and discarding the remaining labels.
    private static func screenPanel(_ image: CGImage) -> CGRect? {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        // Fast OCR is sufficient for layout detection. Avoid the heavyweight
        // accurate OCR model compilation on every new command-line test process.
        text.usesCPUOnly = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([text])) != nil,
              let words = text.results, words.count >= 4 else { return nil }
        let bounds = words.reduce(CGRect.null) { $0.union($1.boundingBox) }
        guard bounds.width > 0.6, bounds.height > 0.4 else { return nil }
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return Double(area / max(0.0001, a.width * a.height + b.width * b.height - area))
    }

    private static func matchingScore(_ candidate: Candidate, _ anchor: CGRect) -> Double {
        let box = candidate.observation.boundingBox
        let proximity = max(0, 1 - Double(hypot(box.midX - anchor.midX, box.midY - anchor.midY)) / 0.3)
        return overlap(anchor, box) * 0.65 + proximity * 0.25 + candidate.score * 0.1
    }

    static func plan(_ samples: [FramingSample], duration: Double, imageSize: CGSize, zoom: Double) -> [CropKeyframe] {
        guard !samples.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return [] }
        let scale = max(1080 / imageSize.width, 1920 / imageSize.height) * min(2, max(1, zoom))
        let visible = min(1, Double(1080 / (imageSize.width * scale)))
        let available = max(0.001, 1 - visible)
        let half = visible / 2
        func cropPosition(_ center: Double) -> Double { min(1, max(0, (center - half) / available)) }
        var shots: [[FramingSample]] = []
        for sample in samples {
            if shots.isEmpty || sample.cutTime != nil { shots.append([]) }
            shots[shots.count - 1].append(sample)
        }
        var path: [CropKeyframe] = []
        for shot in shots {
            guard let first = shot.first else { continue }
            let shotStart = first.cutTime ?? first.time
            let preserveShot = shot.contains { $0.preserveWholeFrame }
            let initial = shot.first(where: { $0.subject != nil && $0.time - first.time < 0.6 })?.subject
            var camera = min(1 - half, max(half, Double(initial?.midX ?? 0.5)))
            var targets: [Double] = []
            for (index, sample) in shot.enumerated() {
                if let box = sample.subject {
                    // Symmetric smoothing uses surrounding frames, avoiding the old
                    // delayed camera that kept chasing a subject after it had moved.
                    var sum = 0.0, weightSum = 0.0
                    for neighbor in max(0, index - 2)...min(shot.count - 1, index + 2) {
                        guard let neighborBox = shot[neighbor].subject else { continue }
                        let weight = Double(3 - abs(neighbor - index))
                        sum += Double(neighborBox.midX) * weight
                        weightSum += weight
                    }
                    let center = weightSum > 0 ? sum / weightSum : Double(box.midX)
                    let spare = (visible - Double(box.width)) / 2 - visible * 0.08
                    let deadZone = max(visible * 0.08, min(visible * 0.22, spare))
                    if abs(center - camera) > deadZone {
                        // Move only enough to return to the safe framing region.
                        // This avoids repeated full recentering for small movements.
                        let edge = center > camera ? center - deadZone * 0.5 : center + deadZone * 0.5
                        camera = min(1 - half, max(half, edge))
                    }
                }
                targets.append(cropPosition(camera))
            }
            // Ease only within a continuous shot. A hard source cut is a hard framing
            // change, so there is never a pan joining two unrelated scenes.
            for index in shot.indices {
                var sum = 0.0, weightSum = 0.0
                for neighbor in max(0, index - 1)...min(shot.count - 1, index + 1) {
                    let weight = neighbor == index ? 2.0 : 1.0
                    sum += targets[neighbor] * weight
                    weightSum += weight
                }
                var position = sum / weightSum
                if let subject = shot[index].subject {
                    // Never sacrifice keeping the main subject visible for a speed cap.
                    let center = half + position * available
                    let safeHalf = visible * 0.44
                    let corrected = min(Double(subject.midX) + safeHalf, max(Double(subject.midX) - safeHalf, center))
                    position = cropPosition(corrected)
                }
                let time = index == 0 ? shotStart : shot[index].time
                let point = CropKeyframe(time: time, position: position, isSceneCut: index == 0 && first.cutTime != nil ? true : nil, preserveWholeFrame: preserveShot ? true : nil)
                if path.count >= 2, point.isSceneCut != true,
                   path[path.count - 1].isSceneCut != true,
                   abs(path[path.count - 1].position - point.position) < 0.0005,
                   abs(path[path.count - 2].position - point.position) < 0.0005 {
                    path.removeLast()
                }
                path.append(point)
            }
        }
        if let first = path.first, first.time > 0 { path.insert(.init(time: 0, position: first.position, preserveWholeFrame: first.preserveWholeFrame), at: 0) }
        if let last = path.last, last.time < duration { path.append(.init(time: duration, position: last.position, preserveWholeFrame: last.preserveWholeFrame)) }
        return path
    }

    private static func luminanceGrid(_ image: CGImage) -> [UInt8]? {
        let width = 32, height = 18
        guard let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    private static func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) / 255
    }
}
