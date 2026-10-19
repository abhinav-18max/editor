// Face finder for faces.sh: reads image files, prints one JSON line per image
// with every face Apple's Vision framework finds in it.
//
// Usage: faces IMAGE... | DIR   (faces.sh compiles and runs this; it isn't a tool on its own)
// A directory means every .jpg in it, in name order.
//
// Each line: {"file": NAME, "faces": [{"x", "y", "w", "h", "mouth", "conf"}],
//             "bodies": [{"x", "y", "w", "h", "conf"}], "heads": [{"x", "y", "w", "conf"}]}
// x, y are the centre and w, h the size, as fractions of the picture (origin
// top-left). mouth is how far the inner lips are apart, as a fraction of the
// face's height; it changes a lot while someone talks; yaw is how far the head
// is turned (radians, 0 = facing the camera). When no face is found (people
// seen side-on or from behind): bodies are people's upper bodies, and heads
// are where their heads are, from the body-pose joints (nose, eyes, ears),
// which still work in profile; w is a rough head width.

import Foundation
import Vision
import ImageIO

func mouthOpening(_ face: VNFaceObservation) -> Double? {
    guard let lips = face.landmarks?.innerLips, lips.pointCount >= 4 else { return nil }
    let ys = lips.normalizedPoints.map { Double($0.y) }
    guard let lo = ys.min(), let hi = ys.max() else { return nil }
    return hi - lo
}

func r(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

var files = Array(CommandLine.arguments.dropFirst())
if files.isEmpty {
    FileHandle.standardError.write("usage: faces IMAGE... | DIR\n".data(using: .utf8)!)
    exit(2)
}
var isDir: ObjCBool = false
if files.count == 1, FileManager.default.fileExists(atPath: files[0], isDirectory: &isDir), isDir.boolValue {
    let dir = files[0]
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    files = names.filter { $0.lowercased().hasSuffix(".jpg") }.sorted().map { dir + "/" + $0 }
}

for path in files {
    let url = URL(fileURLWithPath: path)
    var faces: [[String: Double]] = []
    var bodies: [[String: Double]] = []
    var heads: [[String: Double]] = []
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            for face in request.results ?? [] {
                let b = face.boundingBox
                var f: [String: Double] = [
                    "x": r(Double(b.midX)), "y": r(1 - Double(b.midY)),
                    "w": r(Double(b.width)), "h": r(Double(b.height)),
                    "conf": r(Double(face.confidence)),
                ]
                if let m = mouthOpening(face) { f["mouth"] = r(m) }
                // Which way the head is turned, in radians (0 = facing the camera).
                if let yaw = face.yaw { f["yaw"] = r(yaw.doubleValue) }
                faces.append(f)
            }
            if faces.isEmpty {
                let people = VNDetectHumanRectanglesRequest()
                people.upperBodyOnly = true
                try handler.perform([people])
                for body in people.results ?? [] {
                    let b = body.boundingBox
                    bodies.append(["x": r(Double(b.midX)), "y": r(1 - Double(b.midY)),
                                   "w": r(Double(b.width)), "h": r(Double(b.height)),
                                   "conf": r(Double(body.confidence))])
                }
                let pose = VNDetectHumanBodyPoseRequest()
                try handler.perform([pose])
                let headJoints: [VNHumanBodyPoseObservation.JointName] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
                for person in pose.results ?? [] {
                    guard let joints = try? person.recognizedPoints(.all) else { continue }
                    let seen = headJoints.compactMap { joints[$0] }.filter { $0.confidence > 0.3 }
                    guard !seen.isEmpty else { continue }
                    let xs = seen.map { Double($0.location.x) }, ys = seen.map { 1 - Double($0.location.y) }
                    // Head width: from the head joints' spread, or a share of the shoulders.
                    var w = (xs.max()! - xs.min()!) * 1.6
                    if let ls = joints[.leftShoulder], let rs = joints[.rightShoulder], ls.confidence > 0.3, rs.confidence > 0.3 {
                        w = max(w, abs(Double(ls.location.x - rs.location.x)) * 0.45)
                    }
                    heads.append(["x": r(xs.reduce(0, +) / Double(xs.count)), "y": r(ys.reduce(0, +) / Double(ys.count)),
                                  "w": r(max(w, 0.03)), "conf": r(seen.map { Double($0.confidence) }.reduce(0, +) / Double(seen.count))])
                }
            }
        } catch {
            FileHandle.standardError.write("faces: \(path): \(error)\n".data(using: .utf8)!)
        }
    }
    let line: [String: Any] = ["file": url.lastPathComponent, "faces": faces, "bodies": bodies, "heads": heads]
    if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}
