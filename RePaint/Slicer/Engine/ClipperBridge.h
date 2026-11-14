// The only doorway between Swift and the Clipper2 C++ library.
//
// Swift can't call Clipper2's C++ classes directly without extra build
// settings, but it can call plain C functions. So this header declares a few
// C functions, ClipperBridge.cpp implements them with Clipper2, and Clip.swift
// wraps them in Swift types. Nothing else in the app knows Clipper2 exists.

#ifndef CLIPPER_BRIDGE_H
#define CLIPPER_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A list of paths packed flat: `coords` is x0,y0,x1,y1,… for every path one
/// after another, and `counts[i]` is how many points path i has.
typedef struct {
    int64_t *coords;
    int32_t *counts;
    int32_t pathCount;
} ClipPaths;

/// Results are allocated by these functions; hand them back here when done.
void clip_free(ClipPaths paths);

/// Grows (delta > 0) or shrinks (delta < 0) closed outlines by `delta` units.
/// roundCorners: 1 for rounded outside corners, 0 for sharp (mitered) ones.
ClipPaths clip_offset(const int64_t *coords, const int32_t *counts, int32_t pathCount,
                  double delta, int32_t roundCorners);

/// op: 0 = union, 1 = difference (a minus b), 2 = intersection.
/// evenOdd: 1 treats `a` as raw overlapping loops where a loop inside a loop
/// is a hole; 0 expects the tidy output of an earlier call.
ClipPaths clip_boolean(int32_t op, int32_t evenOdd,
                   const int64_t *aCoords, const int32_t *aCounts, int32_t aPathCount,
                   const int64_t *bCoords, const int32_t *bCounts, int32_t bPathCount);

/// Keeps the parts of open lines that lie inside the closed outlines.
ClipPaths clip_clip_lines(const int64_t *lineCoords, const int32_t *lineCounts, int32_t linePathCount,
                      const int64_t *areaCoords, const int32_t *areaCounts, int32_t areaPathCount);

#ifdef __cplusplus
}
#endif

#endif
