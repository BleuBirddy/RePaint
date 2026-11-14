#include "ClipperBridge.h"

#include <cstdlib>

#include "clipper2/clipper.h"

using namespace Clipper2Lib;

namespace {

Paths64 unpack(const int64_t *coords, const int32_t *counts, int32_t pathCount) {
    Paths64 paths;
    paths.reserve(static_cast<size_t>(pathCount));
    size_t at = 0;
    for (int32_t p = 0; p < pathCount; ++p) {
        Path64 path;
        path.reserve(static_cast<size_t>(counts[p]));
        for (int32_t i = 0; i < counts[p]; ++i, at += 2) {
            path.emplace_back(coords[at], coords[at + 1]);
        }
        paths.push_back(std::move(path));
    }
    return paths;
}

ClipPaths pack(const Paths64 &paths) {
    size_t points = 0;
    for (const auto &path : paths) points += path.size();

    ClipPaths out;
    out.pathCount = static_cast<int32_t>(paths.size());
    // malloc(0) may return NULL, which Swift would read as "no buffer", so
    // always ask for at least one element.
    out.counts = static_cast<int32_t *>(std::malloc(sizeof(int32_t) * (paths.size() + 1)));
    out.coords = static_cast<int64_t *>(std::malloc(sizeof(int64_t) * (points * 2 + 1)));
    size_t at = 0;
    for (size_t p = 0; p < paths.size(); ++p) {
        out.counts[p] = static_cast<int32_t>(paths[p].size());
        for (const auto &pt : paths[p]) {
            out.coords[at++] = pt.x;
            out.coords[at++] = pt.y;
        }
    }
    return out;
}

}  // namespace

void clip_free(ClipPaths paths) {
    std::free(paths.coords);
    std::free(paths.counts);
}

ClipPaths clip_offset(const int64_t *coords, const int32_t *counts, int32_t pathCount,
                  double delta, int32_t roundCorners) {
    // Coordinates are micrometres. An arc tolerance of 5 keeps rounded
    // corners within 0.005 mm of a true arc without flooding them with points.
    return pack(InflatePaths(unpack(coords, counts, pathCount), delta,
                             roundCorners ? JoinType::Round : JoinType::Miter,
                             EndType::Polygon, 2.0, 5.0));
}

ClipPaths clip_boolean(int32_t op, int32_t evenOdd,
                   const int64_t *aCoords, const int32_t *aCounts, int32_t aPathCount,
                   const int64_t *bCoords, const int32_t *bCounts, int32_t bPathCount) {
    const Paths64 a = unpack(aCoords, aCounts, aPathCount);
    const Paths64 b = unpack(bCoords, bCounts, bPathCount);
    const FillRule rule = evenOdd ? FillRule::EvenOdd : FillRule::NonZero;
    switch (op) {
        case 1: return pack(Difference(a, b, rule));
        case 2: return pack(Intersect(a, b, rule));
        default: return pack(Union(a, b, rule));
    }
}

ClipPaths clip_clip_lines(const int64_t *lineCoords, const int32_t *lineCounts, int32_t linePathCount,
                      const int64_t *areaCoords, const int32_t *areaCounts, int32_t areaPathCount) {
    Clipper64 clipper;
    clipper.AddOpenSubject(unpack(lineCoords, lineCounts, linePathCount));
    clipper.AddClip(unpack(areaCoords, areaCounts, areaPathCount));
    Paths64 closed, open;
    clipper.Execute(ClipType::Intersection, FillRule::NonZero, closed, open);
    return pack(open);
}
