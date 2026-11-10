// earcut.h: polygons into triangles, holes included -- a C port of Mapbox's earcut (v2.2.4, ISC licence; see earcut.c).
#ifndef EARCUT_H
#define EARCUT_H

#include <stdint.h>

/*
 * The triangles of one polygon, as indices into its points: three an triangle, written to *out (malloc'd: the caller
 * frees it). `xy`: x, y pairs -- the outer ring's points, then each hole's; `holes[i]`: the index of hole i's first
 * point. A ring is not closed by repeating its first point. Returns how many indices there are (a multiple of 3; 0 for
 * a polygon with no area), or -1 when out of memory.
 */
long earcut(const double *xy, uint32_t points, const uint32_t *holes, uint32_t hole_count, uint32_t **out);

#endif
