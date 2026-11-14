import Foundation

/// Everything the slicer needs to know besides the model. Lengths in mm,
/// speeds in mm/s, temperatures in °C.
///
/// The defaults are ordinary 0.4 mm nozzle PLA numbers, on the careful side.
nonisolated struct SliceSettings: Sendable, Equatable {
    var layerHeight = 0.2
    var firstLayerHeight = 0.2
    /// Width of one printed line; a little wider than the 0.4 mm nozzle, as
    /// usual, so neighbouring lines press into each other.
    var lineWidth = 0.42

    var wallCount = 2
    var topLayers = 5
    var bottomLayers = 3
    /// 0…1: how much of the inside is filled.
    var infillDensity = 0.15

    /// Scaffolding printed under parts of the model that hang in the air.
    var supportMode = SupportMode.off
    /// A surface leaning closer to flat than this many degrees (measured up
    /// from the bed) gets support. 90 would support every slope, 0 none.
    /// 30 is the usual default: most printers manage steeper overhangs alone.
    var supportThresholdAngle = 30.0
    /// Distance between support lines. Wide, so supports snap off easily.
    var supportSpacing = 2.5
    /// Empty layers left between the top of a support and the model, so the
    /// two don't weld together.
    var supportGapLayers = 1
    /// Sideways clearance between supports and the model's walls.
    var supportSideGap = 0.5

    /// The AMS slot (1 = first) the print starts with.
    var firstSlot = 1
    var firstFilamentName = ""
    /// Changes to another AMS slot at given layers. Any order; see
    /// `sortedSwaps`.
    var filamentSwaps: [FilamentSwap] = []

    var skirtLoops = 2
    var skirtDistance = 5.0

    var nozzleTemperature = 220
    var bedTemperature = 55
    var filamentDiameter = 1.75
    /// g/cm³; 1.24 is PLA.
    var filamentDensity = 1.24

    var firstLayerSpeed = 30.0
    var outerWallSpeed = 60.0
    var innerWallSpeed = 100.0
    var solidFillSpeed = 100.0
    var sparseFillSpeed = 150.0
    var supportSpeed = 80.0
    var travelSpeed = 250.0

    /// Pulling the filament back before a move stops it oozing a string.
    var retractLength = 0.8
    var retractSpeed = 30.0
}

nonisolated enum SupportMode: String, Sendable, CaseIterable {
    case off
    /// Only supports that stand on the bed. Nothing is built on top of the
    /// model, so no marks are left on its surfaces, but overhangs above
    /// other parts of the model stay unsupported.
    case bedOnly
    case everywhere

    var title: String {
        switch self {
        case .off: "Off"
        case .bedOnly: "From the bed only"
        case .everywhere: "Everywhere"
        }
    }
}

/// "From this layer on, print with the filament in that AMS slot."
nonisolated struct FilamentSwap: Identifiable, Hashable, Sendable {
    var id = UUID()
    /// 1 = the first layer. The swap happens just before this layer starts.
    var layer: Int
    /// 1 = the first AMS slot.
    var slot: Int
    var name = ""
}

nonisolated enum PathKind: Sendable, CaseIterable {
    case skirt, support, innerWall, outerWall, solidFill, sparseFill

    var gcodeName: String {
        switch self {
        case .skirt: "Skirt"
        case .support: "Support"
        case .innerWall: "Inner wall"
        case .outerWall: "Outer wall"
        case .solidFill: "Solid infill"
        case .sparseFill: "Sparse infill"
        }
    }

    var isFill: Bool { self == .solidFill || self == .sparseFill }
}

/// One stretch of plastic laid down without stopping.
nonisolated struct Extrusion: Sendable, Equatable {
    var kind: PathKind
    var points: Polyline
    /// A closed loop ends where it began; the last point isn't repeated.
    var closed: Bool
}

nonisolated struct SlicedLayer: Sendable, Equatable {
    /// Height of the nozzle while printing this layer (the layer's top).
    var z: Double
    var height: Double
    var paths: [Extrusion]
}

nonisolated struct SliceResult: Sendable, Equatable {
    var layers: [SlicedLayer]
    var settings: SliceSettings
    /// See `LayerSlicer.Output.layersWithGaps`.
    var layersWithGaps: Int
    var filamentMM: Double
    var filamentGrams: Double
    /// Distance ÷ speed only. Real printers also spend time speeding up and
    /// slowing down, so the true time is longer.
    var roughSeconds: Double
}

extension SliceSettings {
    /// Millimetres of filament pushed in per millimetre of line drawn.
    ///
    /// A printed line is a rectangle with rounded ends when seen from the
    /// front (the nozzle squashes it flat, the sides bulge round), so its
    /// area is a bit less than width × height.
    nonisolated func filamentPerMM(layerHeight h: Double) -> Double {
        let lineArea = (lineWidth - h) * h + .pi * (h / 2) * (h / 2)
        let filamentArea = .pi * (filamentDiameter / 2) * (filamentDiameter / 2)
        return lineArea / filamentArea
    }

    /// How far apart the centres of two touching lines are.
    ///
    /// Less than the line width: because lines have rounded sides, lines
    /// spaced a full width apart would leave little channels of air between
    /// them. At this spacing the plastic exactly fills the space.
    nonisolated func lineSpacing(layerHeight h: Double) -> Double {
        lineWidth - h * (1 - .pi / 4)
    }

    /// The swaps that will really happen, in print order: sorted by layer,
    /// with any at layer 1 or below dropped (the print starts with
    /// `firstSlot`), and only the last one kept when two name the same layer.
    nonisolated var sortedSwaps: [FilamentSwap] {
        var byLayer = [Int: FilamentSwap]()
        for swap in filamentSwaps where swap.layer > 1 { byLayer[swap.layer] = swap }
        return byLayer.values.sorted { $0.layer < $1.layer }
    }

    /// Which slot and filament name print the given layer (1 = first).
    nonisolated func filament(forLayer layer: Int) -> (slot: Int, name: String) {
        let current = sortedSwaps.last { $0.layer <= layer }
        return (current?.slot ?? firstSlot, current?.name ?? firstFilamentName)
    }

    nonisolated func speed(for kind: PathKind, firstLayer: Bool) -> Double {
        if firstLayer { return firstLayerSpeed }
        switch kind {
        case .skirt: return firstLayerSpeed
        case .support: return supportSpeed
        case .innerWall: return innerWallSpeed
        case .outerWall: return outerWallSpeed
        case .solidFill: return solidFillSpeed
        case .sparseFill: return sparseFillSpeed
        }
    }
}
