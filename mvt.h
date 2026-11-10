// mvt.h: a Mapbox Vector Tile (2.1) read into plain C structures -- its layers, their features, the features' tags and
// geometry. A reader and nothing else: what is drawn of it, and how, is style.c's and tessellate.c's.
#ifndef MVT_H
#define MVT_H

#include <stddef.h>
#include <stdint.h>

enum mvt_type { MVT_UNKNOWN = 0, MVT_POINT = 1, MVT_LINE = 2, MVT_POLYGON = 3 };

enum mvt_value_kind { MVT_NONE, MVT_STRING, MVT_NUMBER, MVT_BOOL };

struct mvt_value {
	enum mvt_value_kind kind;
	const char *string;             /* MVT_STRING: not NUL-terminated, `length` bytes of UTF-8 */
	uint32_t length;
	double number;                  /* MVT_NUMBER (a float, double, int, uint or sint), MVT_BOOL (0 or 1) */
};

struct mvt_feature {
	uint64_t id;
	enum mvt_type type;
	const uint32_t *tags;           /* key index, value index, key index, ... */
	uint32_t tag_pairs;
	const uint32_t *geometry;       /* command integers and parameters, out of their varints */
	uint32_t geometry_count;
};

struct mvt_string {
	const char *s;
	uint32_t length;
};

struct mvt_layer {
	struct mvt_string name;
	uint32_t extent;                /* 4096 unless the layer says otherwise */
	struct mvt_feature *features;
	uint32_t feature_count;
	struct mvt_string *keys;
	uint32_t key_count;
	struct mvt_value *values;
	uint32_t value_count;
};

struct mvt_tile {
	struct mvt_layer *layers;
	uint32_t layer_count;
	void *arena;                    /* all of the above; the strings point into the tile's own bytes: keep those */
};

/* 0, or -1 with a sentence in `error` (the tile then holds nothing to free) */
int mvt_read(const uint8_t *data, size_t size, struct mvt_tile *tile, char *error, size_t error_size);
void mvt_free(struct mvt_tile *tile);

const struct mvt_layer *mvt_layer_named(const struct mvt_tile *tile, const char *name);
/* a feature's value for `key`, NULL when it has none */
const struct mvt_value *mvt_value_of(const struct mvt_layer *layer, const struct mvt_feature *feature, const char *key);
/* whether a value is the string `s` */
int mvt_value_is(const struct mvt_value *value, const char *s);

/*
 * A feature's geometry as points -- x, y pairs in the layer's extent; a tile's buffer reaches past 0 and the extent --
 * and the index of the point each part begins with: a line string, or a ring. Of a polygon's rings, the exterior ones
 * have a positive area by the surveyor's formula (clockwise, y pointing down), holes a negative one. 0, or -1 for
 * geometry that does not decode. The caller frees *points and *parts.
 */
int mvt_geometry(const struct mvt_feature *feature, int32_t **points, uint32_t *point_count, uint32_t **parts,
    uint32_t *part_count);

#endif
