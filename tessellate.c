// tessellate.c: see tessellate.h.
#include "tessellate.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "earcut.h"

#define MITER_LIMIT 2.0                 /* a corner sharper than this (in half-widths) is bevelled */
#define NO_PAIR UINT32_MAX

/* -- arrays that grow */

struct grow {
	void *data;
	size_t count, room, size;
};

static void *
grow_add(struct grow *g, size_t n, int *bad)
{
	void *p;

	if (g->count + n > g->room) {
		size_t room = g->room != 0 ? g->room : 256;
		void *d;

		while (room < g->count + n) {
			room *= 2;
		}
		d = realloc(g->data, room * g->size);
		if (d == NULL) {
			*bad = 1;
			return NULL;
		}
		g->data = d;
		g->room = room;
	}
	p = (char *)g->data + g->count * g->size;
	g->count += n;
	return p;
}

struct builder {
	struct grow vertices[B_COUNT], indices[B_COUNT], labels;
	int bad;
};

static int16_t
clamp16(double v)
{
	return (int16_t)fmax(-32767, fmin(32767, lround(v)));
}

/* -- fills */

/* the surveyor's formula: positive for an exterior ring of a vector tile (clockwise, y down), negative for a hole */
static double
ring_area(const int32_t *xy, uint32_t start, uint32_t end)
{
	double sum = 0;

	for (uint32_t i = start; i < end; i++) {
		uint32_t j = i + 1 < end ? i + 1 : start;

		sum += (double)xy[2 * i] * xy[2 * j + 1] - (double)xy[2 * j] * xy[2 * i + 1];
	}
	return sum / 2;
}

static void
add_polygon(struct builder *b, enum style_bucket bucket, const int32_t *xy, uint32_t points, const uint32_t *parts,
    uint32_t part_count)
{
	for (uint32_t r = 0; r < part_count;) {
		uint32_t start = parts[r], last = r + 1, end, n, hole_count = 0, *holes, *triangles = NULL;
		double *flat;
		long count;

		if (ring_area(xy, start, r + 1 < part_count ? parts[r + 1] : points) <= 0) {
			r++;                    /* a hole with no ring around it, or a ring with no area */
			continue;
		}
		while (last < part_count && ring_area(xy, parts[last], last + 1 < part_count ? parts[last + 1] : points) < 0) {
			last++;
		}
		end = last < part_count ? parts[last] : points;
		n = end - start;
		flat = malloc((size_t)n * 2 * sizeof(double));
		holes = malloc((size_t)(last - r) * sizeof(uint32_t));
		if (flat == NULL || holes == NULL) {
			free(flat);
			free(holes);
			b->bad = 1;
			return;
		}
		for (uint32_t k = 0; k < n; k++) {
			flat[2 * k] = xy[2 * (start + k)];
			flat[2 * k + 1] = xy[2 * (start + k) + 1];
		}
		for (uint32_t h = r + 1; h < last; h++) {
			holes[hole_count++] = parts[h] - start;
		}
		count = earcut(flat, n, holes, hole_count, &triangles);
		if (count < 0) {
			b->bad = 1;
		} else if (count > 0) {
			uint32_t base = (uint32_t)b->vertices[bucket].count;
			struct fill_vertex *v = grow_add(&b->vertices[bucket], n, &b->bad);
			uint32_t *ix = grow_add(&b->indices[bucket], (size_t)count, &b->bad);

			if (v != NULL && ix != NULL) {
				for (uint32_t k = 0; k < n; k++) {
					v[k].x = clamp16(flat[2 * k]);
					v[k].y = clamp16(flat[2 * k + 1]);
					v[k].bucket = (uint8_t)bucket;
					v[k].pad[0] = v[k].pad[1] = v[k].pad[2] = 0;
				}
				for (long i = 0; i < count; i++) {
					ix[i] = base + triangles[i];
				}
			}
		}
		free(triangles);
		free(flat);
		free(holes);
		r = last;
	}
}

/* -- lines */

/* two vertices across the middle at (x, y): +e on one edge, -e on the other; the first one's index */
static uint32_t
add_pair(struct builder *b, enum style_bucket bucket, double x, double y, double ex, double ey)
{
	uint32_t at = (uint32_t)b->vertices[bucket].count;
	struct line_vertex *v = grow_add(&b->vertices[bucket], 2, &b->bad);

	if (v == NULL) {
		return NO_PAIR;
	}
	memset(v, 0, 2 * sizeof(*v));
	v[0].x = v[1].x = clamp16(x);
	v[0].y = v[1].y = clamp16(y);
	v[0].ex = clamp16(ex * EXTRUDE_ONE);
	v[0].ey = clamp16(ey * EXTRUDE_ONE);
	v[1].ex = clamp16(-ex * EXTRUDE_ONE);
	v[1].ey = clamp16(-ey * EXTRUDE_ONE);
	v[0].across = 127;
	v[1].across = -127;
	v[0].bucket = v[1].bucket = (uint8_t)bucket;
	return at;
}

static void
add_triangle(struct builder *b, enum style_bucket bucket, uint32_t i, uint32_t j, uint32_t k)
{
	uint32_t *ix = grow_add(&b->indices[bucket], 3, &b->bad);

	if (ix != NULL) {
		ix[0] = i;
		ix[1] = j;
		ix[2] = k;
	}
}

/* the quad between the pair a segment starts with and the one it ends with */
static void
connect(struct builder *b, enum style_bucket bucket, uint32_t from, uint32_t to)
{
	if (from != NO_PAIR && to != NO_PAIR) {
		add_triangle(b, bucket, from, from + 1, to);
		add_triangle(b, bucket, from + 1, to + 1, to);
	}
}

static void
add_line(struct builder *b, enum style_bucket bucket, const int32_t *xy, uint32_t start, uint32_t end)
{
	uint32_t n = 0, previous = NO_PAIR;
	double *px = malloc((size_t)(end - start) * 2 * sizeof(double)), *py;

	if (px == NULL) {
		b->bad = 1;
		return;
	}
	py = px + (end - start);
	/* (a point that repeats the one before has no direction to give) */
	for (uint32_t i = start; i < end; i++) {
		if (n == 0 || xy[2 * i] != px[n - 1] || xy[2 * i + 1] != py[n - 1]) {
			px[n] = xy[2 * i];
			py[n] = xy[2 * i + 1];
			n++;
		}
	}
	for (uint32_t i = 0; i < n && n >= 2; i++) {
		double d0x = 0, d0y = 0, d1x = 0, d1y = 0, n0x, n0y, n1x, n1y, mx, my, half;

		if (i > 0) {
			double l = hypot(px[i] - px[i - 1], py[i] - py[i - 1]);

			d0x = (px[i] - px[i - 1]) / l;
			d0y = (py[i] - py[i - 1]) / l;
		}
		if (i + 1 < n) {
			double l = hypot(px[i + 1] - px[i], py[i + 1] - py[i]);

			d1x = (px[i + 1] - px[i]) / l;
			d1y = (py[i + 1] - py[i]) / l;
		}
		if (i == 0) {
			d0x = d1x;
			d0y = d1y;
		}
		if (i + 1 == n) {
			d1x = d0x;
			d1y = d0y;
		}
		n0x = -d0y;
		n0y = d0x;
		n1x = -d1y;
		n1y = d1x;
		mx = n0x + n1x;
		my = n0y + n1y;
		/* the mitre: the bisector of the two normals, as long as it takes to reach both edges */
		half = hypot(mx, my) / 2;
		if (half > 1 / MITER_LIMIT) {
			uint32_t pair = add_pair(b, bucket, px[i], py[i], mx / (2 * half * half), my / (2 * half * half));

			connect(b, bucket, previous, pair);
			previous = pair;
		} else {
			/* a sharp corner: the incoming side ends square, the outgoing begins square, a bevel between */
			uint32_t in = add_pair(b, bucket, px[i], py[i], n0x, n0y), out, centre;
			struct line_vertex *c;

			connect(b, bucket, previous, in);
			out = add_pair(b, bucket, px[i], py[i], n1x, n1y);
			centre = (uint32_t)b->vertices[bucket].count;
			c = grow_add(&b->vertices[bucket], 1, &b->bad);
			if (c == NULL || in == NO_PAIR || out == NO_PAIR) {
				break;
			}
			memset(c, 0, sizeof(*c));
			c->x = clamp16(px[i]);
			c->y = clamp16(py[i]);
			c->bucket = (uint8_t)bucket;
			/* (turning towards +n, the outside of the corner is the -n edge) */
			if (d0x * d1y - d0y * d1x > 0) {
				add_triangle(b, bucket, in + 1, out + 1, centre);
			} else {
				add_triangle(b, bucket, in, out, centre);
			}
			previous = out;
		}
	}
	free(px);
}

/* -- labels */

static const struct mvt_value *
name_value(const struct mvt_layer *layer, const struct mvt_feature *feature, enum style_language language)
{
	/* (name:zh is often Traditional, or both forms with a slash between: the script's own field first) */
	const char *const order[][5] = {
		[LANGUAGE_LOCAL] = { "name", "name:latin", NULL },
		[LANGUAGE_CHINESE] = { "name:zh-Hans", "name:zh", "name", "name:latin", NULL },
		[LANGUAGE_CHINESE_TRADITIONAL] = { "name:zh-Hant", "name:zh", "name", "name:latin", NULL },
		[LANGUAGE_ENGLISH] = { "name:en", "name_en", "name", "name:latin", NULL },
	};

	for (unsigned i = 0; i < 5 && order[language][i] != NULL; i++) {
		const struct mvt_value *v = mvt_value_of(layer, feature, order[language][i]);

		if (v != NULL && v->kind == MVT_STRING && v->length != 0) {
			return v;
		}
	}
	return NULL;
}

/* whether the points i..j of a line are nearly straight: each within 1.5% of the chord's length of it (at least 3
   units), and each further along it than the one before */
static int
straight(const int32_t *xy, uint32_t i, uint32_t j)
{
	double cx = xy[2 * j] - xy[2 * i], cy = xy[2 * j + 1] - xy[2 * i + 1], length = hypot(cx, cy), last = 0;
	double tolerance = fmax(3, 0.015 * length);

	if (length == 0) {
		return 0;
	}
	for (uint32_t k = i + 1; k < j; k++) {
		double dx = xy[2 * k] - xy[2 * i], dy = xy[2 * k + 1] - xy[2 * i + 1];
		double off = fabs(dx * cy - dy * cx) / length, along = (dx * cx + dy * cy) / length;

		if (off > tolerance || along < last || along > length) {
			return 0;
		}
		last = along;
	}
	return 1;
}

static void
add_label(struct builder *b, const struct mvt_layer *layer, const struct mvt_feature *feature, int kind, int priority,
    enum style_language language, const int32_t *xy, uint32_t points, const uint32_t *parts, uint32_t part_count)
{
	const struct mvt_value *name = name_value(layer, feature, language);
	struct tess_label *label;

	if (name == NULL || points == 0) {
		return;
	}
	label = grow_add(&b->labels, 1, &b->bad);
	if (label == NULL) {
		return;
	}
	memset(label, 0, sizeof(*label));
	label->text = malloc(name->length + 1);
	if (label->text == NULL) {
		b->labels.count--;
		b->bad = 1;
		return;
	}
	memcpy(label->text, name->string, name->length);
	label->text[name->length] = 0;
	label->kind = kind;
	label->priority = priority;
	/* (FNV-1a, 64 bits) */
	label->hash = 0xcbf29ce484222325ull;
	for (uint32_t i = 0; i < name->length; i++) {
		label->hash = (label->hash ^ (uint8_t)name->string[i]) * 0x100000001b3ull;
	}
	label->hash = (label->hash ^ (uint64_t)(kind + 1)) * 0x100000001b3ull;
	label->x = (float)xy[0];
	label->y = (float)xy[1];
	if (feature->type == MVT_LINE) {
		double best = -1;

		/*
		 * Along its longest stretch that is nearly straight -- every point of it within a little of the straight line
		 * from its first point to its last, in order along it -- on the road at the middle of that stretch, turned
		 * as that line is. (One segment between two of the road's points is seldom as long as a name.)
		 */
		for (uint32_t p = 0; p < part_count; p++) {
			uint32_t end = p + 1 < part_count ? parts[p + 1] : points;

			for (uint32_t i = parts[p]; i + 1 < end;) {
				uint32_t j = i + 1;
				double cx, cy, chord;

				while (j + 1 < end && straight(xy, i, j + 1)) {
					j++;
				}
				cx = xy[2 * j] - xy[2 * i];
				cy = xy[2 * j + 1] - xy[2 * i + 1];
				chord = hypot(cx, cy);
				if (chord > best) {
					double angle = atan2(cy, cx), half = 0, x, y;

					best = chord;
					/* (kept readable: never upside down) */
					if (angle > M_PI / 2) {
						angle -= M_PI;
					} else if (angle < -M_PI / 2) {
						angle += M_PI;
					}
					/* (the middle along the road, not of the chord: on a gentle curve the chord leaves it) */
					for (uint32_t k = i; k < j; k++) {
						half += hypot(xy[2 * k + 2] - xy[2 * k], xy[2 * k + 3] - xy[2 * k + 1]) / 2;
					}
					x = xy[2 * i];
					y = xy[2 * i + 1];
					for (uint32_t k = i; k < j; k++) {
						double dx = xy[2 * k + 2] - xy[2 * k], dy = xy[2 * k + 3] - xy[2 * k + 1], l = hypot(dx, dy);

						if (l >= half) {
							x = xy[2 * k] + (l > 0 ? dx * half / l : 0);
							y = xy[2 * k + 1] + (l > 0 ? dy * half / l : 0);
							break;
						}
						half -= l;
					}
					label->x = (float)x;
					label->y = (float)y;
					label->angle = (float)angle;
					label->room = (float)chord;
				}
				i = j;
			}
		}
	}
}

/* -- the tile */

/* the buckets of one kind into one mesh, in their order, each one's indices moved past the vertices before it */
static void
merge(struct builder *b, enum style_kind kind, struct tess_mesh *mesh)
{
	size_t vertices = 0, indices = 0, size = kind == STYLE_FILL ? sizeof(struct fill_vertex) : sizeof(struct line_vertex);

	memset(mesh, 0, sizeof(*mesh));
	for (int i = 0; i < B_COUNT; i++) {
		if (style_kind_of((enum style_bucket)i) == kind) {
			vertices += b->vertices[i].count;
			indices += b->indices[i].count;
		}
	}
	if (indices == 0) {
		return;
	}
	mesh->vertices = malloc(vertices * size);
	mesh->indices = malloc(indices * sizeof(uint32_t));
	if (mesh->vertices == NULL || mesh->indices == NULL) {
		b->bad = 1;
		return;
	}
	for (int i = 0; i < B_COUNT; i++) {
		const uint32_t *from = b->indices[i].data;

		if (style_kind_of((enum style_bucket)i) != kind) {
			continue;
		}
		memcpy((char *)mesh->vertices + mesh->vertex_count * size, b->vertices[i].data, b->vertices[i].count * size);
		mesh->first[i] = mesh->index_count;
		mesh->count[i] = (uint32_t)b->indices[i].count;
		for (size_t k = 0; k < b->indices[i].count; k++) {
			mesh->indices[mesh->index_count + k] = from[k] + mesh->vertex_count;
		}
		mesh->index_count += (uint32_t)b->indices[i].count;
		mesh->vertex_count += (uint32_t)b->vertices[i].count;
	}
}

int
tess_make(const uint8_t *data, size_t size, int zoom, enum style_language language, struct tess_tile *tile,
    char *error, size_t error_size)
{
	struct mvt_tile mvt;
	struct builder b;
	/* (the deepest level served is shown up to the deepest zoom: its labels are for all of those) */
	int serves = zoom >= 14 ? 20 : zoom + 1;

	memset(tile, 0, sizeof(*tile));
	memset(&b, 0, sizeof(b));
	for (int i = 0; i < B_COUNT; i++) {
		b.vertices[i].size = style_kind_of((enum style_bucket)i) == STYLE_FILL ? sizeof(struct fill_vertex) :
		    sizeof(struct line_vertex);
		b.indices[i].size = sizeof(uint32_t);
	}
	b.labels.size = sizeof(struct tess_label);
	if (mvt_read(data, size, &mvt, error, error_size) != 0) {
		return -1;
	}
	tile->extent = 4096;
	for (uint32_t l = 0; l < mvt.layer_count && !b.bad; l++) {
		const struct mvt_layer *layer = &mvt.layers[l];
		double scale = 4096.0 / layer->extent;  /* (every layer in the tile's one scale, 4096) */

		for (uint32_t f = 0; f < layer->feature_count && !b.bad; f++) {
			const struct mvt_feature *feature = &layer->features[f];
			int bucket = style_bucket_of(layer, feature, zoom), priority = 0;
			int kind = style_label_of(layer, feature, serves, &priority);
			int32_t *xy;
			uint32_t points, *parts, part_count;

			if (bucket < 0 && kind < 0) {
				continue;
			}
			if (mvt_geometry(feature, &xy, &points, &parts, &part_count) != 0) {
				continue;               /* (a feature that does not decode is left out, the rest stays) */
			}
			if (scale != 1) {
				for (uint32_t i = 0; i < 2 * points; i++) {
					xy[i] = (int32_t)lround(xy[i] * scale);
				}
			}
			if (bucket >= 0 && style_kind_of((enum style_bucket)bucket) == STYLE_FILL &&
			    feature->type == MVT_POLYGON) {
				add_polygon(&b, (enum style_bucket)bucket, xy, points, parts, part_count);
			} else if (bucket >= 0 && style_kind_of((enum style_bucket)bucket) == STYLE_LINE &&
			    feature->type == MVT_LINE) {
				for (uint32_t p = 0; p < part_count; p++) {
					add_line(&b, (enum style_bucket)bucket, xy, parts[p], p + 1 < part_count ? parts[p + 1] : points);
				}
			}
			if (kind >= 0 && style_label_looks[kind].max_zoom >= zoom && style_label_looks[kind].min_zoom <= serves) {
				add_label(&b, layer, feature, kind, priority, language, xy, points, parts, part_count);
			}
			free(xy);
			free(parts);
		}
	}
	mvt_free(&mvt);
	if (!b.bad) {
		merge(&b, STYLE_FILL, &tile->fills);
		merge(&b, STYLE_LINE, &tile->lines);
	}
	for (int i = 0; i < B_COUNT; i++) {
		free(b.vertices[i].data);
		free(b.indices[i].data);
	}
	tile->labels = b.labels.data;
	tile->label_count = (uint32_t)b.labels.count;
	tile->triangles = (tile->fills.index_count + tile->lines.index_count) / 3;
	if (b.bad) {
		snprintf(error, error_size, "out of memory making the tile's triangles");
		tess_free(tile);
		return -1;
	}
	return 0;
}

void
tess_free(struct tess_tile *tile)
{
	free(tile->fills.vertices);
	free(tile->fills.indices);
	free(tile->lines.vertices);
	free(tile->lines.indices);
	for (uint32_t i = 0; i < tile->label_count; i++) {
		free(tile->labels[i].text);
	}
	free(tile->labels);
	memset(tile, 0, sizeof(*tile));
}
