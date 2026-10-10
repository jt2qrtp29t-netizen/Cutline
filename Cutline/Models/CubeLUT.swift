import Foundation

/// A 3D color lookup table read from a .cube file (the Adobe/Resolve text format).
nonisolated struct CubeLUT: Sendable, Equatable {
    let title: String?
    /// Entries per side.
    let size: Int
    let domainMin: SIMD3<Double>
    let domainMax: SIMD3<Double>
    /// size³ entries, red changing fastest, then green, then blue.
    let table: [SIMD3<Float>]

    enum ParseError: LocalizedError, Equatable {
        case empty
        case missingSize
        case oneDimensional
        case unsupportedSize(Int)
        case badLine(number: Int, text: String)
        case wrongEntryCount(expected: Int, found: Int)
        case badDomain

        var errorDescription: String? {
            switch self {
            case .empty: "The file is empty."
            case .missingSize: "The file has no LUT_3D_SIZE line, so it isn’t a 3D .cube LUT."
            case .oneDimensional: "This is a 1D LUT. Only 3D .cube LUTs are supported."
            case .unsupportedSize(let size): "LUT_3D_SIZE \(size) isn’t supported (use 2 to 256)."
            case let .badLine(number, text): "Line \(number) couldn’t be read: “\(text.prefix(40))”."
            case let .wrongEntryCount(expected, found): "Expected \(expected) color entries but found \(found)."
            case .badDomain: "DOMAIN_MIN must be below DOMAIN_MAX."
            }
        }
    }

    static func load(from url: URL) throws -> CubeLUT {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.badLine(number: 1, text: "binary data")
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> CubeLUT {
        var title: String?
        var size: Int?
        var domainMin = SIMD3<Double>(0, 0, 0)
        var domainMax = SIMD3<Double>(1, 1, 1)
        var table: [SIMD3<Float>] = []
        var sawContent = false

        func numbers(_ parts: [Substring], line: Int, raw: String) throws -> SIMD3<Double> {
            guard parts.count == 3, let a = Double(parts[0]), let b = Double(parts[1]), let c = Double(parts[2]),
                  a.isFinite, b.isFinite, c.isFinite else {
                throw ParseError.badLine(number: line, text: raw)
            }
            return SIMD3(a, b, c)
        }

        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            sawContent = true
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let keyword = parts[0].uppercased()
            switch keyword {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_1D_SIZE":
                throw ParseError.oneDimensional
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]) else { throw ParseError.badLine(number: index + 1, text: line) }
                guard (2...256).contains(n) else { throw ParseError.unsupportedSize(n) }
                size = n
                table.reserveCapacity(n * n * n)
            case "DOMAIN_MIN":
                domainMin = try numbers(Array(parts.dropFirst()), line: index + 1, raw: line)
            case "DOMAIN_MAX":
                domainMax = try numbers(Array(parts.dropFirst()), line: index + 1, raw: line)
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                // Resolve's range lines: same meaning as DOMAIN_MIN/MAX for all channels.
                guard parts.count == 3, let lo = Double(parts[1]), let hi = Double(parts[2]) else {
                    throw ParseError.badLine(number: index + 1, text: line)
                }
                domainMin = SIMD3(repeating: lo)
                domainMax = SIMD3(repeating: hi)
            default:
                guard keyword.first.map({ $0.isNumber || $0 == "-" || $0 == "." || $0 == "+" }) == true else {
                    // Unknown keywords are allowed by the format; skip them.
                    continue
                }
                let v = try numbers(parts, line: index + 1, raw: line)
                table.append(SIMD3(Float(v.x), Float(v.y), Float(v.z)))
            }
        }
        guard sawContent else { throw ParseError.empty }
        guard let size else { throw ParseError.missingSize }
        guard table.count == size * size * size else {
            throw ParseError.wrongEntryCount(expected: size * size * size, found: table.count)
        }
        guard all(domainMin .< domainMax) else { throw ParseError.badDomain }
        return CubeLUT(title: title, size: size, domainMin: domainMin, domainMax: domainMax, table: table)
    }

    /// The LUT's output for a color, with trilinear interpolation.
    func sample(_ color: SIMD3<Double>) -> SIMD3<Double> {
        let n = size - 1
        var p = (color - domainMin) / (domainMax - domainMin) * Double(n)
        p = p.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: Double(n)))
        let i0 = SIMD3<Int>(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)), Int(p.z.rounded(.down)))
        let i1 = SIMD3<Int>(min(i0.x + 1, n), min(i0.y + 1, n), min(i0.z + 1, n))
        let f = p - SIMD3(Double(i0.x), Double(i0.y), Double(i0.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
            let v = table[r + size * (g + size * b)]
            return SIMD3(Double(v.x), Double(v.y), Double(v.z))
        }
        let c00 = at(i0.x, i0.y, i0.z) * (1 - f.x) + at(i1.x, i0.y, i0.z) * f.x
        let c10 = at(i0.x, i1.y, i0.z) * (1 - f.x) + at(i1.x, i1.y, i0.z) * f.x
        let c01 = at(i0.x, i0.y, i1.z) * (1 - f.x) + at(i1.x, i0.y, i1.z) * f.x
        let c11 = at(i0.x, i1.y, i1.z) * (1 - f.x) + at(i1.x, i1.y, i1.z) * f.x
        let c0 = c00 * (1 - f.y) + c10 * f.y
        let c1 = c01 * (1 - f.y) + c11 * f.y
        return c0 * (1 - f.z) + c1 * f.z
    }
}
