import Foundation

/// The printer-specific text wrapped around the sliced moves.
nonisolated struct PrinterProfile: Sendable, Equatable {
    var name: String
    var bed: Bed
    /// `{bed_temp}` and `{nozzle_temp}` are replaced with the settings,
    /// `{slot}` with the starting AMS slot counted from 0.
    var startGCode: String
    /// Run at each filament swap. `{slot}` is the new AMS slot counted from
    /// 0 (Bambu calls the first slot 0).
    var filamentChangeGCode: String
    var endGCode: String
    /// Sent at the start of the second layer; the first layer prints with
    /// the fan off so it sticks to the bed.
    var fanOnGCode: String

    /// NOT READY TO PRINT. Bambu publishes no G-code reference, and Bambu
    /// Studio's real start sequence (levelling, nozzle wipe, loading
    /// filament from the AMS with M620/M621) is long and model-specific.
    /// This is only the generic heat-home-go sequence most firmwares accept;
    /// whether a Bambu accepts it, and what it does about an AMS, is
    /// untested. Replace it with a checked sequence before a real print.
    ///
    /// The target is a P1P with an AMS 2 Pro. With an AMS the filament sits
    /// in the AMS between prints, not in the nozzle, so without the loading
    /// commands this sequence would most likely print nothing but air.
    static let bambuUntested = PrinterProfile(
        name: "Bambu P1P (untested start G-code)",
        bed: .bambu256,
        startGCode: """
            M140 S{bed_temp} ; start heating the bed
            M104 S{nozzle_temp} ; start heating the nozzle
            G28 ; home all axes
            M190 S{bed_temp} ; wait for the bed
            M109 S{nozzle_temp} ; wait for the nozzle
            M620 S{slot}A ; AMS: get ready to load this slot
            T{slot} ; load it
            M621 S{slot}A ; AMS: done
            """,
        // UNTESTED, like the start sequence. These three commands are the
        // core of the swap as Bambu owners describe it on Bambu's forum.
        // Bambu Studio's real sequence also moves to the waste chute and
        // pushes plastic through to flush the old colour out; without that
        // the first lines after a swap come out in mixed colours, and the
        // nozzle may ooze onto the print while it waits.
        filamentChangeGCode: """
            M620 S{slot}A ; AMS: get ready to swap to this slot
            T{slot} ; swap
            M621 S{slot}A ; AMS: done
            """,
        endGCode: """
            M104 S0 ; nozzle off
            M140 S0 ; bed off
            M106 P1 S0 ; fan off
            M84 ; motors off
            """,
        fanOnGCode: "M106 P1 S255")
}

nonisolated enum GCodeWriter {
    /// Moves shorter than this don't bother pulling the filament back.
    private static let retractOverMM = 1.5
    /// Hops between infill lines are allowed to be longer without a
    /// retraction: any string they leave is hidden inside the part.
    private static let retractOverMMInsideFill = 5.0

    static func write(_ result: SliceResult, printer: PrinterProfile, modelName: String) -> String {
        let s = result.settings
        var out = ""
        out.reserveCapacity(result.layers.reduce(0) { $0 + $1.paths.count } * 80)

        out += "; Sliced by RePaint\n"
        out += "; Model: \(modelName)\n"
        out += "; Printer: \(printer.name)\n"
        out += "; Layers: \(result.layers.count), layer height \(s.layerHeight) mm\n"
        out += "; Filament: \(fixed(result.filamentMM / 1000, 2)) m, \(fixed(result.filamentGrams, 1)) g\n\n"

        out += printer.startGCode
            .replacingOccurrences(of: "{bed_temp}", with: String(s.bedTemperature))
            .replacingOccurrences(of: "{nozzle_temp}", with: String(s.nozzleTemperature))
            .replacingOccurrences(of: "{slot}", with: String(s.firstSlot - 1))
        out += "\nG90 ; X, Y and Z are positions on the bed\n"
        out += "M83 ; E is how much filament to push for this one move\n"

        let travelF = Int(s.travelSpeed * 60)
        let retractF = Int(s.retractSpeed * 60)
        var position: IntPoint?
        var retracted = false

        let swaps = s.sortedSwaps
        for (index, layer) in result.layers.enumerated() {
            out += "\n; LAYER \(index + 1) of \(result.layers.count)\n"
            if let swap = swaps.first(where: { $0.layer == index + 1 }) {
                // Pull back first so the old filament doesn't drool on the
                // part while the printer is busy swapping.
                if !retracted {
                    out += "G1 E-\(fixed(s.retractLength, 2)) F\(retractF)\n"
                    retracted = true
                }
                out += "; FILAMENT CHANGE to slot \(swap.slot)\(swap.name.isEmpty ? "" : " (\(swap.name))")\n"
                out += printer.filamentChangeGCode
                    .replacingOccurrences(of: "{slot}", with: String(swap.slot - 1)) + "\n"
                // The swap moves the head somewhere we don't know about.
                position = nil
            }
            if index == 1 { out += printer.fanOnGCode + "\n" }
            out += "G1 Z\(fixed(layer.z, 3)) F600\n"

            let perUnit = s.filamentPerMM(layerHeight: layer.height) / Units.perMM
            var lastKind: PathKind?

            for path in layer.paths where path.points.count >= 2 {
                var points = path.points
                if path.closed {
                    // Start a loop at its corner nearest the nozzle, then go
                    // all the way round and back to it.
                    if let from = position,
                       let nearest = points.indices.min(by: { points[$0].distance(to: from) < points[$1].distance(to: from) }) {
                        points = Array(points[nearest...] + points[..<nearest])
                    }
                    points.append(points[0])
                }

                // Travel to the start without printing.
                if points[0] != position {
                    let hop = (position?.distance(to: points[0]) ?? 0) / Units.perMM
                    let limit = path.kind.isFill && lastKind == path.kind
                        ? retractOverMMInsideFill : retractOverMM
                    if hop > limit, !retracted {
                        out += "G1 E-\(fixed(s.retractLength, 2)) F\(retractF)\n"
                        retracted = true
                    }
                    out += "G1 X\(mm(points[0].x)) Y\(mm(points[0].y)) F\(travelF)\n"
                }
                if retracted {
                    out += "G1 E\(fixed(s.retractLength, 2)) F\(retractF)\n"
                    retracted = false
                }

                if path.kind != lastKind {
                    out += "; TYPE: \(path.kind.gcodeName)\n"
                    lastKind = path.kind
                }

                let feed = Int(s.speed(for: path.kind, firstLayer: index == 0) * 60)
                var needsFeed = true
                for i in 1..<points.count {
                    let e = points[i - 1].distance(to: points[i]) * perUnit
                    out += "G1 X\(mm(points[i].x)) Y\(mm(points[i].y)) E\(fixed(e, 5))"
                    // The speed only needs saying once; the printer keeps it.
                    if needsFeed {
                        out += " F\(feed)"
                        needsFeed = false
                    }
                    out += "\n"
                }
                position = points[points.count - 1]
            }
        }

        // Pull back and lift off so the hot nozzle doesn't sit on the part.
        out += "\nG1 E-\(fixed(s.retractLength, 2)) F\(retractF)\n"
        if let last = result.layers.last {
            out += "G1 Z\(fixed(min(last.z + 5, Double(printer.bed.height)), 3)) F600\n"
        }
        out += printer.endGCode + "\n"
        return out
    }

    /// Micrometres as millimetres with three decimals, e.g. 128042 → "128.042".
    private static func mm(_ units: Int64) -> String { fixed(Double(units) / Units.perMM, 3) }

    /// A number with exactly `decimals` digits after the point. Hand-rolled
    /// because a big print has millions of numbers and `String(format:)` is
    /// slow enough to notice.
    static func fixed(_ value: Double, _ decimals: Int) -> String {
        var scale: Int64 = 1
        for _ in 0..<decimals { scale *= 10 }
        let scaled = Int64((abs(value) * Double(scale)).rounded())
        var text = String(scaled / scale)
        if decimals > 0 {
            let fraction = String(scaled % scale)
            text += "." + String(repeating: "0", count: decimals - fraction.count) + fraction
        }
        return value < 0 && scaled != 0 ? "-" + text : text
    }
}
