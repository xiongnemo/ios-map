// mvt.c: see mvt.h. Protocol buffers by hand -- varints, length-delimited fields, packed repeated uint32 -- over the
// messages of vector_tile.proto (Tile, Layer, Feature, Value); a field it does not know is skipped by its wire type.
#include "mvt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* -- an arena: every allocation of one tile, given back at once */

struct arena_block {
	struct arena_block *next;
	size_t used, size;
	unsigned char data[];
};

static void *
arena_alloc(void **arena, size_t size)
{
	struct arena_block *b = *arena;
	void *p;

	size = (size + 15) & ~(size_t)15;
	if (size == 0) {
		size = 16;
	}
	if (b == NULL || b->size - b->used < size) {
		size_t want = size > 65536 ? size : 65536;
		struct arena_block *n = malloc(sizeof(*n) + want);

		if (n == NULL) {
			return NULL;
		}
		n->next = b;
		n->used = 0;
		n->size = want;
		*arena = b = n;
	}
	p = b->data + b->used;
	b->used += size;
	memset(p, 0, size);
	return p;
}

static void
arena_free(void *arena)
{
	struct arena_block *b = arena, *next;

	for (; b != NULL; b = next) {
		next = b->next;
		free(b);
	}
}

/* -- protocol buffers */

struct pb {
	const uint8_t *at, *end;
	int bad;
};

static uint64_t
pb_varint(struct pb *p)
{
	uint64_t v = 0;

	for (unsigned shift = 0; shift < 64; shift += 7) {
		uint8_t b;

		if (p->at >= p->end) {
			p->bad = 1;
			return 0;
		}
		b = *p->at++;
		v |= (uint64_t)(b & 0x7f) << shift;
		if (!(b & 0x80)) {
			return v;
		}
	}
	p->bad = 1;
	return 0;
}

/* the next field's number, and its wire type in *wire; 0 at the end, or when the message is broken */
static int
pb_field(struct pb *p, unsigned *wire)
{
	uint64_t key;

	if (p->bad || p->at >= p->end) {
		return 0;
	}
	key = pb_varint(p);
	*wire = (unsigned)(key & 7);
	return p->bad || (key >> 3) == 0 ? 0 : (int)(key >> 3);
}

/* a length-delimited field's bytes */
static struct pb
pb_bytes(struct pb *p)
{
	struct pb sub = { NULL, NULL, 1 };
	uint64_t n = pb_varint(p);

	if (p->bad || n > (uint64_t)(p->end - p->at)) {
		p->bad = 1;
		return sub;
	}
	sub.at = p->at;
	sub.end = p->at + n;
	sub.bad = 0;
	p->at += n;
	return sub;
}

static void
pb_skip(struct pb *p, unsigned wire)
{
	switch (wire) {
	case 0:
		(void)pb_varint(p);
		break;
	case 1:
	case 5:
		if (p->end - p->at < (wire == 1 ? 8 : 4)) {
			p->bad = 1;
		} else {
			p->at += wire == 1 ? 8 : 4;
		}
		break;
	case 2:
		(void)pb_bytes(p);
		break;
	default:
		p->bad = 1;     /* groups (3, 4) are not in vector_tile.proto */
		break;
	}
}

/* a packed repeated uint32, into the arena; *count says how many */
static uint32_t *
pb_packed(void **arena, struct pb *p, uint32_t *count)
{
	struct pb sub = pb_bytes(p);
	uint32_t n = 0, *out;

	if (sub.bad) {
		return NULL;
	}
	for (const uint8_t *q = sub.at; q < sub.end; q++) {
		n += !(*q & 0x80);
	}
	out = arena_alloc(arena, (size_t)n * sizeof(uint32_t));
	if (out == NULL) {
		p->bad = 1;
		return NULL;
	}
	for (uint32_t i = 0; i < n; i++) {
		out[i] = (uint32_t)pb_varint(&sub);
	}
	if (sub.bad) {
		p->bad = 1;
		return NULL;
	}
	*count = n;
	return out;
}

static struct mvt_string
pb_string(struct pb *p)
{
	struct pb s = pb_bytes(p);
	struct mvt_string out = { NULL, 0 };

	if (!s.bad) {
		out.s = (const char *)s.at;
		out.length = (uint32_t)(s.end - s.at);
	}
	return out;
}

/* -- the messages */

static void
read_value(struct pb p, struct mvt_value *v)
{
	unsigned wire;
	int field;

	while ((field = pb_field(&p, &wire)) != 0) {
		if (field == 1 && wire == 2) {
			struct mvt_string s = pb_string(&p);

			v->kind = MVT_STRING;
			v->string = s.s;
			v->length = s.length;
		} else if (field == 2 && wire == 5 && p.end - p.at >= 4) {
			float f;

			memcpy(&f, p.at, 4);        /* (little-endian, as both the wire and arm64 are) */
			p.at += 4;
			v->kind = MVT_NUMBER;
			v->number = f;
		} else if (field == 3 && wire == 1 && p.end - p.at >= 8) {
			double d;

			memcpy(&d, p.at, 8);
			p.at += 8;
			v->kind = MVT_NUMBER;
			v->number = d;
		} else if ((field == 4 || field == 5 || field == 6 || field == 7) && wire == 0) {
			uint64_t n = pb_varint(&p);

			v->kind = field == 7 ? MVT_BOOL : MVT_NUMBER;
			v->number = field == 4 ? (double)(int64_t)n : field == 6 ? (double)((int64_t)(n >> 1) ^ -(int64_t)(n & 1)) :
			    field == 7 ? (n != 0) : (double)n;
		} else {
			pb_skip(&p, wire);
		}
	}
}

static int
read_feature(void **arena, struct pb p, struct mvt_feature *f)
{
	unsigned wire;
	int field;

	while ((field = pb_field(&p, &wire)) != 0) {
		if (field == 1 && wire == 0) {
			f->id = pb_varint(&p);
		} else if (field == 2 && wire == 2) {
			uint32_t n = 0;

			f->tags = pb_packed(arena, &p, &n);
			f->tag_pairs = n / 2;
		} else if (field == 3 && wire == 0) {
			uint64_t t = pb_varint(&p);

			f->type = t <= MVT_POLYGON ? (enum mvt_type)t : MVT_UNKNOWN;
		} else if (field == 4 && wire == 2) {
			f->geometry = pb_packed(arena, &p, &f->geometry_count);
		} else {
			pb_skip(&p, wire);
		}
	}
	return p.bad ? -1 : 0;
}

static int
read_layer(void **arena, struct pb p, struct mvt_layer *layer)
{
	struct pb scan = p;
	uint32_t features = 0, keys = 0, values = 0;
	unsigned wire;
	int field;

	/* counted first, so that each array is one allocation of its own size */
	while ((field = pb_field(&scan, &wire)) != 0) {
		if (wire == 2 && field >= 2 && field <= 4) {
			(void)pb_bytes(&scan);
			features += field == 2;
			keys += field == 3;
			values += field == 4;
		} else {
			pb_skip(&scan, wire);
		}
	}
	if (scan.bad) {
		return -1;
	}
	layer->extent = 4096;
	layer->features = arena_alloc(arena, (size_t)features * sizeof(*layer->features));
	layer->keys = arena_alloc(arena, (size_t)keys * sizeof(*layer->keys));
	layer->values = arena_alloc(arena, (size_t)values * sizeof(*layer->values));
	if (layer->features == NULL || layer->keys == NULL || layer->values == NULL) {
		return -1;
	}
	while ((field = pb_field(&p, &wire)) != 0) {
		if (field == 1 && wire == 2) {
			layer->name = pb_string(&p);
		} else if (field == 2 && wire == 2) {
			if (read_feature(arena, pb_bytes(&p), &layer->features[layer->feature_count++]) != 0) {
				return -1;
			}
		} else if (field == 3 && wire == 2) {
			layer->keys[layer->key_count++] = pb_string(&p);
		} else if (field == 4 && wire == 2) {
			read_value(pb_bytes(&p), &layer->values[layer->value_count++]);
		} else if (field == 5 && wire == 0) {
			layer->extent = (uint32_t)pb_varint(&p);
		} else {
			pb_skip(&p, wire);
		}
	}
	return p.bad || layer->extent == 0 ? -1 : 0;
}

int
mvt_read(const uint8_t *data, size_t size, struct mvt_tile *tile, char *error, size_t error_size)
{
	struct pb p = { data, data + size, 0 }, scan = p;
	uint32_t layers = 0;
	unsigned wire;
	int field;

	memset(tile, 0, sizeof(*tile));
	while ((field = pb_field(&scan, &wire)) != 0) {
		layers += field == 3 && wire == 2;
		pb_skip(&scan, wire);
	}
	if (scan.bad) {
		snprintf(error, error_size, "not a vector tile: broken at byte %ld of %zu", (long)(scan.at - data), size);
		return -1;
	}
	tile->layers = arena_alloc(&tile->arena, (size_t)layers * sizeof(*tile->layers));
	if (tile->layers == NULL) {
		snprintf(error, error_size, "no memory for %u layers", layers);
		mvt_free(tile);
		return -1;
	}
	while ((field = pb_field(&p, &wire)) != 0) {
		if (field == 3 && wire == 2) {
			struct mvt_layer *layer = &tile->layers[tile->layer_count];

			if (read_layer(&tile->arena, pb_bytes(&p), layer) != 0) {
				snprintf(error, error_size, "layer %u (%.*s) is broken", tile->layer_count, (int)layer->name.length,
				    layer->name.s != NULL ? layer->name.s : "");
				mvt_free(tile);
				return -1;
			}
			tile->layer_count++;
		} else {
			pb_skip(&p, wire);
		}
	}
	return 0;
}

void
mvt_free(struct mvt_tile *tile)
{
	arena_free(tile->arena);
	memset(tile, 0, sizeof(*tile));
}

static int
string_is(struct mvt_string s, const char *want)
{
	size_t n = strlen(want);

	return s.s != NULL && s.length == n && memcmp(s.s, want, n) == 0;
}

const struct mvt_layer *
mvt_layer_named(const struct mvt_tile *tile, const char *name)
{
	for (uint32_t i = 0; i < tile->layer_count; i++) {
		if (string_is(tile->layers[i].name, name)) {
			return &tile->layers[i];
		}
	}
	return NULL;
}

const struct mvt_value *
mvt_value_of(const struct mvt_layer *layer, const struct mvt_feature *feature, const char *key)
{
	for (uint32_t i = 0; i < feature->tag_pairs; i++) {
		uint32_t k = feature->tags[2 * i], v = feature->tags[2 * i + 1];

		if (k < layer->key_count && v < layer->value_count && string_is(layer->keys[k], key)) {
			return &layer->values[v];
		}
	}
	return NULL;
}

int
mvt_value_is(const struct mvt_value *value, const char *s)
{
	size_t n = strlen(s);

	return value != NULL && value->kind == MVT_STRING && value->length == n && memcmp(value->string, s, n) == 0;
}

static int32_t
unzigzag(uint32_t n)
{
	return (int32_t)(n >> 1) ^ -(int32_t)(n & 1);
}

int
mvt_geometry(const struct mvt_feature *feature, int32_t **points, uint32_t *point_count, uint32_t **parts,
    uint32_t *part_count)
{
	/* (each point takes two of the integers, so half of them is enough room) */
	uint32_t room = feature->geometry_count / 2 + 1, n = 0, np = 0, i = 0;
	int32_t x = 0, y = 0, *xy = malloc((size_t)room * 2 * sizeof(int32_t));
	uint32_t *starts = malloc((size_t)room * sizeof(uint32_t));

	*points = NULL;
	*parts = NULL;
	*point_count = *part_count = 0;
	if (xy == NULL || starts == NULL) {
		free(xy);
		free(starts);
		return -1;
	}
	while (i < feature->geometry_count) {
		uint32_t command = feature->geometry[i++], id = command & 7, count = command >> 3;

		if (id == 1 || id == 2) {               /* MoveTo, LineTo */
			if ((size_t)i + 2 * (size_t)count > feature->geometry_count || (id == 2 && np == 0)) {
				free(xy);
				free(starts);
				return -1;
			}
			for (uint32_t k = 0; k < count; k++) {
				x += unzigzag(feature->geometry[i++]);
				y += unzigzag(feature->geometry[i++]);
				if (id == 1) {
					starts[np++] = n;   /* (a point feature's MoveTo of several: each point a part) */
				}
				xy[2 * n] = x;
				xy[2 * n + 1] = y;
				n++;
			}
		} else if (id == 7) {                   /* ClosePath: the ring ends where it began; nothing to add */
			if (np == 0) {
				free(xy);
				free(starts);
				return -1;
			}
		} else {
			free(xy);
			free(starts);
			return -1;
		}
	}
	*points = xy;
	*parts = starts;
	*point_count = n;
	*part_count = np;
	return 0;
}
