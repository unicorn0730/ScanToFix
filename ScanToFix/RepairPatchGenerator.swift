import Foundation
import simd

struct RepairPatchResult {
    let patchMesh: ScannedMesh
    let detectedBoundaryCount: Int
    let boundaryVertexCount: Int
    let boundaryPerimeter: Float
}

struct RepairBoundaryCandidate: Identifiable, Hashable {
    let id: String
    let indices: [Int]
    let perimeter: Float
    let area: Float
    let score: Float
    let confidence: Float
}

enum RepairPatchGenerationError: LocalizedError {
    case sourceMeshEmpty
    case noRepairBoundaryFound
    case boundaryTooSmall
    case triangulationFailed

    var errorDescription: String? {
        switch self {
        case .sourceMeshEmpty:
            return "No scan mesh data is available yet."
        case .noRepairBoundaryFound:
            return "Could not detect a clear fracture boundary. Scan closer around the damaged edge."
        case .boundaryTooSmall:
            return "Detected boundary is too small to build a printable patch."
        case .triangulationFailed:
            return "Could not build a watertight patch from the detected boundary."
        }
    }
}

enum RepairPatchGenerator {
    static func detectBoundaryCandidates(from sourceMesh: ScannedMesh) -> [RepairBoundaryCandidate] {
        guard !sourceMesh.isEmpty else {
            return []
        }

        let scoredLoops = scoredBoundaryLoops(
            from: sourceMesh,
            minimumBoundaryVertices: 4,
            maxVertexCount: 220
        )
        guard !scoredLoops.isEmpty else {
            return []
        }

        return materializeCandidates(from: scoredLoops, limit: 3)
    }

    static func generate(from sourceMesh: ScannedMesh, version: RepairVersion) throws -> RepairPatchResult {
        guard !sourceMesh.isEmpty else {
            throw RepairPatchGenerationError.sourceMeshEmpty
        }

        let profile = version.patchProfile
        let scoredLoops = scoredBoundaryLoops(
            from: sourceMesh,
            minimumBoundaryVertices: profile.minimumBoundaryVertices,
            maxVertexCount: 220
        )

        guard let selectedLoop = scoredLoops.first else {
            throw RepairPatchGenerationError.noRepairBoundaryFound
        }

        let selectedCandidate = makeBoundaryCandidate(
            loop: selectedLoop,
            maxScore: scoredLoops.first?.score ?? selectedLoop.score,
            secondScore: scoredLoops.dropFirst().first?.score ?? 0
        )

        return try generate(
            from: sourceMesh,
            version: version,
            candidate: selectedCandidate,
            detectedBoundaryCount: scoredLoops.count
        )
    }

    static func generate(
        from sourceMesh: ScannedMesh,
        version: RepairVersion,
        candidate: RepairBoundaryCandidate
    ) throws -> RepairPatchResult {
        try generate(from: sourceMesh, version: version, candidate: candidate, detectedBoundaryCount: nil)
    }
}

private extension RepairPatchGenerator {
    struct LoopCandidate {
        let indices: [Int]
        let perimeter: Float
        let area: Float
        let score: Float
    }

    struct EdgeKey: Hashable {
        let low: Int
        let high: Int

        init(_ a: Int, _ b: Int) {
            if a <= b {
                low = a
                high = b
            } else {
                low = b
                high = a
            }
        }
    }

    struct PlaneBasis {
        let origin: SIMD3<Float>
        let axisU: SIMD3<Float>
        let axisV: SIMD3<Float>

        init(origin: SIMD3<Float>, normal: SIMD3<Float>) {
            let fallbackAxis = abs(normal.x) < 0.8 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let u = simd_normalize(simd_cross(normal, fallbackAxis))
            let v = simd_normalize(simd_cross(normal, u))
            self.origin = origin
            self.axisU = u
            self.axisV = v
        }

        func project(_ point: SIMD3<Float>) -> SIMD2<Float> {
            let local = point - origin
            return SIMD2<Float>(simd_dot(local, axisU), simd_dot(local, axisV))
        }
    }

    static func generate(
        from sourceMesh: ScannedMesh,
        version: RepairVersion,
        candidate: RepairBoundaryCandidate,
        detectedBoundaryCount: Int?
    ) throws -> RepairPatchResult {
        guard !sourceMesh.isEmpty else {
            throw RepairPatchGenerationError.sourceMeshEmpty
        }

        let profile = version.patchProfile
        let simplifiedIndices = simplifyLoop(candidate.indices, maxVertexCount: 220)

        guard simplifiedIndices.count >= profile.minimumBoundaryVertices else {
            throw RepairPatchGenerationError.boundaryTooSmall
        }

        let patchMesh = try buildPatchMesh(
            sourceMesh: sourceMesh,
            boundaryLoopIndices: simplifiedIndices,
            profile: profile
        )

        let boundaryCount: Int
        if let detectedBoundaryCount {
            boundaryCount = detectedBoundaryCount
        } else {
            boundaryCount = scoredBoundaryLoops(
                from: sourceMesh,
                minimumBoundaryVertices: profile.minimumBoundaryVertices,
                maxVertexCount: 220
            ).count
        }

        return RepairPatchResult(
            patchMesh: patchMesh,
            detectedBoundaryCount: boundaryCount,
            boundaryVertexCount: simplifiedIndices.count,
            boundaryPerimeter: candidate.perimeter
        )
    }

    static func scoredBoundaryLoops(
        from mesh: ScannedMesh,
        minimumBoundaryVertices: Int,
        maxVertexCount: Int
    ) -> [LoopCandidate] {
        let rawBoundaryLoops = extractBoundaryLoops(from: mesh)
        let simplifiedLoops = rawBoundaryLoops
            .map { simplifyLoop($0, maxVertexCount: maxVertexCount) }
            .filter { $0.count >= minimumBoundaryVertices }

        let loopCandidates = simplifiedLoops.compactMap {
            scoreLoopCandidate(indices: $0, vertices: mesh.vertices)
        }

        return loopCandidates.sorted { lhs, rhs in
            lhs.score > rhs.score
        }
    }

    static func materializeCandidates(
        from scoredLoops: [LoopCandidate],
        limit: Int
    ) -> [RepairBoundaryCandidate] {
        guard !scoredLoops.isEmpty else {
            return []
        }

        let topLoops = Array(scoredLoops.prefix(max(1, limit)))
        let maxScore = topLoops.first?.score ?? 0
        let secondScore = topLoops.dropFirst().first?.score ?? 0

        return topLoops.map {
            makeBoundaryCandidate(loop: $0, maxScore: maxScore, secondScore: secondScore)
        }
    }

    static func makeBoundaryCandidate(
        loop: LoopCandidate,
        maxScore: Float,
        secondScore: Float
    ) -> RepairBoundaryCandidate {
        let normalizedScore = clamp01(Double(loop.score) / max(Double(maxScore), 0.000001))
        let separationScore = clamp01(Double(loop.score - secondScore) / max(Double(loop.score), 0.000001))
        let confidence = Float(clamp01((0.7 * normalizedScore) + (0.3 * separationScore)))

        return RepairBoundaryCandidate(
            id: stableLoopIdentifier(indices: loop.indices),
            indices: loop.indices,
            perimeter: loop.perimeter,
            area: loop.area,
            score: loop.score,
            confidence: confidence
        )
    }

    static func stableLoopIdentifier(indices: [Int]) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        let prime: UInt64 = 1_099_511_628_211

        for index in indices {
            hash ^= UInt64(index)
            hash &*= prime
        }

        return String(hash, radix: 16)
    }

    static func scoreLoopCandidate(indices loop: [Int], vertices: [SIMD3<Float>]) -> LoopCandidate? {
        let points = loop.map { vertices[$0] }
        let perimeter = polygonPerimeter(points)
        if perimeter < 0.01 {
            return nil
        }

        let rawNormal = newellNormal(points)
        let normalLength = simd_length(rawNormal)
        if normalLength < 0.0001 {
            return nil
        }
        let normal = rawNormal / normalLength

        let centroid = polygonCentroid(points)
        let basis = PlaneBasis(origin: centroid, normal: normal)
        let projected = points.map { basis.project($0) }
        let area = abs(signedArea(projected))
        if area < 0.000001 {
            return nil
        }

        let compactness = max(0, min(1, (4 * Float.pi * area) / max(perimeter * perimeter, 0.000001)))
        let score = area * (0.45 + compactness)

        return LoopCandidate(indices: loop, perimeter: perimeter, area: area, score: score)
    }

    static func extractBoundaryLoops(from mesh: ScannedMesh) -> [[Int]] {
        var edgeUseCount: [EdgeKey: Int] = [:]
        var orientedEdges: [(Int, Int)] = []

        for face in mesh.faces {
            let a = Int(face.x)
            let b = Int(face.y)
            let c = Int(face.z)
            let edges = [(a, b), (b, c), (c, a)]

            for edge in edges {
                edgeUseCount[EdgeKey(edge.0, edge.1), default: 0] += 1
                orientedEdges.append(edge)
            }
        }

        let boundaryEdges = orientedEdges.filter { edge in
            edgeUseCount[EdgeKey(edge.0, edge.1)] == 1
        }

        guard !boundaryEdges.isEmpty else {
            return []
        }

        var adjacency: [Int: Set<Int>] = [:]
        var remainingEdges = Set<EdgeKey>()

        for (a, b) in boundaryEdges {
            adjacency[a, default: []].insert(b)
            adjacency[b, default: []].insert(a)
            remainingEdges.insert(EdgeKey(a, b))
        }

        var loops: [[Int]] = []
        let maxStepCount = max(64, boundaryEdges.count * 2)

        for (start, firstNeighbor) in boundaryEdges {
            let initialEdge = EdgeKey(start, firstNeighbor)
            guard remainingEdges.contains(initialEdge) else {
                continue
            }

            var loop: [Int] = [start]
            var previous = start
            var current = firstNeighbor
            remainingEdges.remove(initialEdge)

            var steps = 0
            while steps < maxStepCount {
                steps += 1

                if current == start {
                    break
                }

                loop.append(current)
                let neighbors = adjacency[current] ?? []
                let preferredNext = neighbors.filter { $0 != previous }

                let next = preferredNext.first(where: { remainingEdges.contains(EdgeKey(current, $0)) })
                    ?? neighbors.first(where: { remainingEdges.contains(EdgeKey(current, $0)) })

                guard let next else {
                    break
                }

                remainingEdges.remove(EdgeKey(current, next))
                previous = current
                current = next
            }

            if current == start && loop.count >= 3 {
                loops.append(loop)
            }
        }

        return loops
    }

    static func simplifyLoop(_ loop: [Int], maxVertexCount: Int) -> [Int] {
        guard loop.count > maxVertexCount else {
            return loop
        }

        let stride = max(1, loop.count / maxVertexCount)
        var simplified: [Int] = []
        simplified.reserveCapacity(maxVertexCount)

        var index = 0
        while index < loop.count {
            simplified.append(loop[index])
            index += stride
        }

        if simplified.count < 3 {
            return Array(loop.prefix(maxVertexCount))
        }

        return simplified
    }

    static func buildPatchMesh(
        sourceMesh: ScannedMesh,
        boundaryLoopIndices: [Int],
        profile: RepairPatchProfile
    ) throws -> ScannedMesh {
        var loopPoints = boundaryLoopIndices.map { sourceMesh.vertices[$0] }
        loopPoints = removeNearDuplicatePoints(loopPoints, tolerance: 0.00015)

        guard loopPoints.count >= 3 else {
            throw RepairPatchGenerationError.boundaryTooSmall
        }

        let loopCentroid = polygonCentroid(loopPoints)
        var normal = newellNormal(loopPoints)
        guard simd_length(normal) > 0.0001 else {
            throw RepairPatchGenerationError.boundaryTooSmall
        }
        normal = simd_normalize(normal)

        let meshCentroid = sourceMesh.vertices.reduce(SIMD3<Float>.zero, +) / Float(sourceMesh.vertices.count)
        let inwardHint = meshCentroid - loopCentroid
        if simd_dot(normal, inwardHint) < 0 {
            normal *= -1
        }

        let base = PlaneBasis(origin: loopCentroid, normal: normal)
        var projectedBase = loopPoints.map { base.project($0) }
        if signedArea(projectedBase) < 0 {
            loopPoints.reverse()
            projectedBase = loopPoints.map { base.project($0) }
        }

        let fallbackDirection = base.axisU
        let radialDirections = loopPoints.map { point in
            var radial = point - loopCentroid
            radial -= normal * simd_dot(radial, normal)
            let length = simd_length(radial)
            if length < 0.00001 {
                return fallbackDirection
            }
            return radial / length
        }

        let topRing = zip(loopPoints, radialDirections).map { point, radial in
            point + radial * profile.overlapWidth
        }
        let bottomRing = zip(loopPoints, radialDirections).map { point, radial in
            point - radial * profile.insertionClearance + normal * profile.insertionDepth
        }

        let topProjected = topRing.map { base.project($0) }
        guard let topTriangles = triangulatePolygon(topProjected) else {
            throw RepairPatchGenerationError.triangulationFailed
        }

        let ringCount = topRing.count
        let allVertices = topRing + bottomRing
        var allFaces: [SIMD3<UInt32>] = []
        allFaces.reserveCapacity(topTriangles.count * 2 + ringCount * 2)

        for triangle in topTriangles {
            appendFace(
                to: &allFaces,
                a: triangle.z,
                b: triangle.y,
                c: triangle.x,
                vertices: allVertices
            )
            appendFace(
                to: &allFaces,
                a: triangle.x + ringCount,
                b: triangle.y + ringCount,
                c: triangle.z + ringCount,
                vertices: allVertices
            )
        }

        for i in 0..<ringCount {
            let j = (i + 1) % ringCount
            let topA = i
            let topB = j
            let bottomA = i + ringCount
            let bottomB = j + ringCount

            appendFace(
                to: &allFaces,
                a: topA,
                b: topB,
                c: bottomA,
                vertices: allVertices
            )
            appendFace(
                to: &allFaces,
                a: topB,
                b: bottomB,
                c: bottomA,
                vertices: allVertices
            )
        }

        guard !allFaces.isEmpty else {
            throw RepairPatchGenerationError.triangulationFailed
        }

        return ScannedMesh(vertices: allVertices, faces: allFaces)
    }

    static func appendFace(
        to faces: inout [SIMD3<UInt32>],
        a: Int,
        b: Int,
        c: Int,
        vertices: [SIMD3<Float>]
    ) {
        guard a != b, b != c, a != c else {
            return
        }

        let v0 = vertices[a]
        let v1 = vertices[b]
        let v2 = vertices[c]
        let areaMagnitude = simd_length(simd_cross(v1 - v0, v2 - v0))
        guard areaMagnitude > 0.0000001 else {
            return
        }

        faces.append(SIMD3<UInt32>(UInt32(a), UInt32(b), UInt32(c)))
    }

    static func triangulatePolygon(_ polygon: [SIMD2<Float>]) -> [SIMD3<Int>]? {
        guard polygon.count >= 3 else {
            return nil
        }

        var remaining = Array(polygon.indices)
        var triangles: [SIMD3<Int>] = []
        let maxIterations = polygon.count * polygon.count
        var iteration = 0

        while remaining.count > 3 && iteration < maxIterations {
            iteration += 1
            var earFound = false

            for index in remaining.indices {
                let previous = remaining[(index + remaining.count - 1) % remaining.count]
                let current = remaining[index]
                let next = remaining[(index + 1) % remaining.count]

                guard isConvex(previous: polygon[previous], current: polygon[current], next: polygon[next]) else {
                    continue
                }

                guard !containsPointInsideTriangle(
                    previous: previous,
                    current: current,
                    next: next,
                    polygon: polygon,
                    remaining: remaining
                ) else {
                    continue
                }

                triangles.append(SIMD3<Int>(previous, current, next))
                remaining.remove(at: index)
                earFound = true
                break
            }

            if !earFound {
                return nil
            }
        }

        if remaining.count == 3 {
            triangles.append(SIMD3<Int>(remaining[0], remaining[1], remaining[2]))
        }

        return triangles
    }

    static func isConvex(previous: SIMD2<Float>, current: SIMD2<Float>, next: SIMD2<Float>) -> Bool {
        cross2(next - current, previous - current) > 0.000001
    }

    static func containsPointInsideTriangle(
        previous: Int,
        current: Int,
        next: Int,
        polygon: [SIMD2<Float>],
        remaining: [Int]
    ) -> Bool {
        let a = polygon[previous]
        let b = polygon[current]
        let c = polygon[next]

        for index in remaining where index != previous && index != current && index != next {
            if pointInTriangle(polygon[index], a, b, c) {
                return true
            }
        }
        return false
    }

    static func pointInTriangle(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        let d1 = cross2(b - a, p - a)
        let d2 = cross2(c - b, p - b)
        let d3 = cross2(a - c, p - c)
        let hasNegative = (d1 < -0.000001) || (d2 < -0.000001) || (d3 < -0.000001)
        let hasPositive = (d1 > 0.000001) || (d2 > 0.000001) || (d3 > 0.000001)
        return !(hasNegative && hasPositive)
    }

    static func cross2(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Float {
        (lhs.x * rhs.y) - (lhs.y * rhs.x)
    }

    static func signedArea(_ points: [SIMD2<Float>]) -> Float {
        guard points.count >= 3 else {
            return 0
        }
        var sum: Float = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            let current = points[index]
            sum += (current.x * next.y) - (next.x * current.y)
        }
        return 0.5 * sum
    }

    static func polygonPerimeter(_ points: [SIMD3<Float>]) -> Float {
        guard points.count >= 2 else {
            return 0
        }
        var perimeter: Float = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            perimeter += simd_length(next - points[index])
        }
        return perimeter
    }

    static func polygonCentroid(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else {
            return .zero
        }
        return points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
    }

    static func newellNormal(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard points.count >= 3 else {
            return .zero
        }

        var normal = SIMD3<Float>.zero
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            normal.x += (current.y - next.y) * (current.z + next.z)
            normal.y += (current.z - next.z) * (current.x + next.x)
            normal.z += (current.x - next.x) * (current.y + next.y)
        }
        return normal
    }

    static func removeNearDuplicatePoints(_ points: [SIMD3<Float>], tolerance: Float) -> [SIMD3<Float>] {
        guard !points.isEmpty else {
            return []
        }

        var filtered: [SIMD3<Float>] = [points[0]]
        for point in points.dropFirst() {
            if simd_length(point - filtered[filtered.count - 1]) > tolerance {
                filtered.append(point)
            }
        }

        if filtered.count > 2, simd_length(filtered[0] - filtered[filtered.count - 1]) <= tolerance {
            filtered.removeLast()
        }

        return filtered
    }

    static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
