// tessellate.h: one vector tile made into what the GPU draws -- triangles for each bucket of style.h, in the tile's own
// coordinates (0 .. extent; the tile's buffer goes past both) -- and the labels it has to offer. Both renderers draw
// these as they are.
#ifndef TESSELLATE_H
#define TESSELLATE_H

#include <stddef.h>
#include <stdint.h>

#include "style.h"

/* a fill's vertex: a point of the tile, and the bucket it is of (its colour comes from that, per frame) */
struct fill_vertex {
	int16_t x, y;
	uint8_t bucket, pad[3];
};

/*
 * A line's vertex: a point of its middle, and the way out from it to one edge of a line one unit wide (`ex`, `ey`, 1 is
 * EXTRUDE_ONE: longer at a mitred corner). The vertex shader multiplies that by half the line's width in pixels, so a
 * line is as wide on the screen at every zoom; `across` is -127 on one edge and 127 on the other (0 in the middle of a
 * corner's bevel), for the fragment shader's soft edge: a signed normalised byte, -1 to 1, to Metal.
 */
#define EXTRUDE_ONE 4096
struct line_vertex {
	int16_t x, y;
	int16_t ex, ey;
	int8_t across;
	uint8_t bucket, pad[2];
};

/*
 * All the fills of a tile in one array, all the lines in another, each in the buckets' order (style.h's enum: the
 * order they are drawn in), so that a tile is three draws: its fills, its lines' casings, its lines.
 */
struct tess_mesh {
	void *vertices;                 /* struct fill_vertex or struct line_vertex */
	uint32_t vertex_count;
	uint32_t *indices;              /* three a triangle */
	uint32_t index_count;
	uint32_t first[B_COUNT], count[B_COUNT];        /* each bucket's indices: where they begin, how many */
};

struct tess_label {
	char *text;                     /* UTF-8 */
	float x, y;                     /* where, in the tile's coordinates */
	float angle;                    /* along a road: radians, kept readable (between -pi/2 and pi/2); else 0 */
	float room;                     /* along a road: how long the stretch it lies on is, in tile units; else 0 */
	int kind;                       /* enum style_label_kind */
	int priority;                   /* lower is placed first */
	uint64_t hash;                  /* of the text and the kind: the same label in another tile has the same one */
};

struct tess_tile {
	uint32_t extent;
	struct tess_mesh fills, lines;
	struct tess_label *labels;
	uint32_t label_count;
	uint32_t triangles;             /* fills' and lines' */
};

/* 0, or -1 with a sentence in `error` */
int tess_make(const uint8_t *data, size_t size, int zoom, enum style_language language, struct tess_tile *tile,
    char *error, size_t error_size);
void tess_free(struct tess_tile *tile);

#endif
