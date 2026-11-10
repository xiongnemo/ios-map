// style.c: see style.h. The layers and classes are OpenMapTiles' (openmaptiles.org/schema), as OpenFreeMap serves them.
// The colours are this map's own: a light style in the manner of a city map, and a dark one near black for the OLED.
#include "style.h"

#include <math.h>
#include <string.h>

static int
layer_is(const struct mvt_layer *layer, const char *name)
{
	size_t n = strlen(name);

	return layer->name.length == n && memcmp(layer->name.s, name, n) == 0;
}

static int
class_is(const struct mvt_value *v, const char *const *names)
{
	for (; *names != NULL; names++) {
		if (mvt_value_is(v, *names)) {
			return 1;
		}
	}
	return 0;
}

#define ANY(v, ...) class_is((v), (const char *const[]){ __VA_ARGS__, NULL })

static double
number_of(const struct mvt_value *v, double otherwise)
{
	return v != NULL && (v->kind == MVT_NUMBER || v->kind == MVT_BOOL) ? v->number : otherwise;
}

enum style_kind
style_kind_of(enum style_bucket bucket)
{
	return bucket >= B_RIVER ? STYLE_LINE : STYLE_FILL;
}

int
style_bucket_of(const struct mvt_layer *layer, const struct mvt_feature *feature, int zoom)
{
	const struct mvt_value *c = mvt_value_of(layer, feature, "class");
	int area = feature->type == MVT_POLYGON, line = feature->type == MVT_LINE;

	if (layer_is(layer, "landcover") && area) {
		if (ANY(c, "wood", "forest")) {
			return B_WOOD;
		}
		if (ANY(c, "grass", "meadow", "scrub")) {
			return B_GRASS;
		}
		if (ANY(c, "farmland")) {
			return zoom >= 9 ? B_FARMLAND : -1;
		}
		if (ANY(c, "sand", "beach")) {
			return B_SAND;
		}
		if (ANY(c, "ice", "glacier")) {
			return B_ICE;
		}
		if (ANY(c, "wetland")) {
			return B_WETLAND;
		}
		return -1;
	}
	if (layer_is(layer, "landuse") && area) {
		if (ANY(c, "residential", "suburb", "quarter", "neighbourhood")) {
			return zoom >= 10 ? B_RESIDENTIAL : -1;
		}
		if (ANY(c, "commercial", "retail")) {
			return B_COMMERCIAL;
		}
		if (ANY(c, "industrial", "garages", "railway", "dam", "quarry", "military")) {
			return B_INDUSTRIAL;
		}
		if (ANY(c, "school", "university", "college", "kindergarten", "hospital", "library", "bus_station")) {
			return B_INSTITUTIONAL;
		}
		if (ANY(c, "cemetery")) {
			return B_CEMETERY;
		}
		if (ANY(c, "pitch", "stadium", "track", "playground", "theme_park", "zoo")) {
			return B_PITCH;
		}
		return -1;
	}
	if (layer_is(layer, "park") && area) {
		return B_PARK;
	}
	if (layer_is(layer, "water") && area) {
		return mvt_value_is(mvt_value_of(layer, feature, "brunnel"), "tunnel") ? -1 : B_WATER;
	}
	if (layer_is(layer, "waterway") && line) {
		if (mvt_value_is(mvt_value_of(layer, feature, "brunnel"), "tunnel")) {
			return -1;
		}
		return ANY(c, "river", "canal") ? B_RIVER : zoom >= 12 ? B_STREAM : -1;
	}
	if (layer_is(layer, "aeroway")) {
		if (area && ANY(c, "aerodrome", "apron", "heliport")) {
			return B_AERODROME;
		}
		if (ANY(c, "runway")) {
			return line ? B_RUNWAY : area ? B_AERODROME : -1;
		}
		if (ANY(c, "taxiway")) {
			return line ? B_TAXIWAY : -1;
		}
		return -1;
	}
	if (layer_is(layer, "building") && area) {
		return zoom >= 13 ? B_BUILDING : -1;
	}
	if (layer_is(layer, "transportation")) {
		if (area) {
			return ANY(c, "pier", "bridge") ? B_PIER : -1;
		}
		if (!line) {
			return -1;
		}
		if (ANY(c, "motorway")) {
			return B_MOTORWAY;
		}
		if (ANY(c, "trunk")) {
			return B_TRUNK;
		}
		if (ANY(c, "primary")) {
			return B_PRIMARY;
		}
		if (ANY(c, "secondary")) {
			return B_SECONDARY;
		}
		if (ANY(c, "tertiary")) {
			return B_TERTIARY;
		}
		if (ANY(c, "minor", "busway", "raceway")) {
			return zoom >= 11 ? B_MINOR : -1;
		}
		if (ANY(c, "service")) {
			return zoom >= 13 ? B_SERVICE : -1;
		}
		if (ANY(c, "path", "track")) {
			return zoom >= 14 ? B_PATH : -1;
		}
		if (ANY(c, "rail", "transit")) {
			return zoom >= 10 && !mvt_value_is(mvt_value_of(layer, feature, "brunnel"), "tunnel") ? B_RAIL : -1;
		}
		return -1;
	}
	if (layer_is(layer, "boundary") && line) {
		double level = number_of(mvt_value_of(layer, feature, "admin_level"), 99);

		if (number_of(mvt_value_of(layer, feature, "maritime"), 0) != 0) {
			return -1;
		}
		return level <= 2 ? B_COUNTRY : level <= 4 && zoom >= 4 ? B_STATE : -1;
	}
	return -1;
}

/* -- the draw list: bottom to top */

#define RGB(r, g, b) (((uint32_t)(r) << 24) | ((uint32_t)(g) << 16) | ((uint32_t)(b) << 8) | 0xffu)

const struct style_draw style_draws[] = {
	{ B_WOOD, 0, { RGB(0xd6, 0xe6, 0xc6), RGB(0x12, 0x20, 0x17) }, 0 },
	{ B_GRASS, 0, { RGB(0xe1, 0xee, 0xd0), RGB(0x13, 0x21, 0x16) }, 0 },
	{ B_FARMLAND, 0, { RGB(0xee, 0xef, 0xdc), RGB(0x15, 0x19, 0x14) }, 0 },
	{ B_SAND, 0, { RGB(0xf4, 0xec, 0xd6), RGB(0x1d, 0x1b, 0x15) }, 0 },
	{ B_ICE, 0, { RGB(0xf4, 0xf8, 0xfb), RGB(0x19, 0x1e, 0x25) }, 0 },
	{ B_WETLAND, 0, { RGB(0xdb, 0xe9, 0xe0), RGB(0x12, 0x1e, 0x1c) }, 0 },
	{ B_RESIDENTIAL, 0, { RGB(0xee, 0xeb, 0xe6), RGB(0x13, 0x15, 0x1a) }, 0 },
	{ B_COMMERCIAL, 0, { RGB(0xf3, 0xe8, 0xe6), RGB(0x1a, 0x15, 0x1a) }, 0 },
	{ B_INDUSTRIAL, 0, { RGB(0xea, 0xe6, 0xee), RGB(0x16, 0x15, 0x1c) }, 0 },
	{ B_INSTITUTIONAL, 0, { RGB(0xf0, 0xe9, 0xdc), RGB(0x19, 0x17, 0x13) }, 0 },
	{ B_CEMETERY, 0, { RGB(0xdb, 0xe6, 0xd5), RGB(0x13, 0x1e, 0x16) }, 0 },
	{ B_PITCH, 0, { RGB(0xd3, 0xe9, 0xc8), RGB(0x13, 0x22, 0x18) }, 0 },
	{ B_PARK, 0, { RGB(0xd2, 0xe8, 0xc0), RGB(0x12, 0x23, 0x18) }, 0 },
	{ B_WATER, 0, { RGB(0xa7, 0xd1, 0xe8), RGB(0x0d, 0x26, 0x38) }, 0 },
	{ B_RIVER, 0, { RGB(0xa7, 0xd1, 0xe8), RGB(0x0d, 0x26, 0x38) }, 8 },
	{ B_STREAM, 0, { RGB(0xa7, 0xd1, 0xe8), RGB(0x0d, 0x26, 0x38) }, 12 },
	{ B_AERODROME, 0, { RGB(0xe9, 0xe7, 0xee), RGB(0x16, 0x16, 0x1d) }, 10 },
	{ B_RUNWAY, 0, { RGB(0xd6, 0xd3, 0xdd), RGB(0x2a, 0x2a, 0x33) }, 10 },
	{ B_TAXIWAY, 0, { RGB(0xdf, 0xdc, 0xe5), RGB(0x24, 0x24, 0x2c) }, 12 },
	{ B_PIER, 0, { RGB(0xf6, 0xf4, 0xef), RGB(0x16, 0x18, 0x1d) }, 13 },
	{ B_BUILDING, 0, { RGB(0xe0, 0xdc, 0xd5), RGB(0x1f, 0x23, 0x2a) }, 13 },
	/* the casings, the least of the roads first */
	{ B_SERVICE, 1, { RGB(0xd4, 0xcf, 0xc7), RGB(0x07, 0x08, 0x0a) }, 14 },
	{ B_MINOR, 1, { RGB(0xd4, 0xcf, 0xc7), RGB(0x07, 0x08, 0x0a) }, 13 },
	{ B_TERTIARY, 1, { RGB(0xcf, 0xc9, 0xbf), RGB(0x07, 0x08, 0x0a) }, 12 },
	{ B_SECONDARY, 1, { RGB(0xd6, 0xc5, 0x96), RGB(0x07, 0x08, 0x0a) }, 11 },
	{ B_PRIMARY, 1, { RGB(0xd9, 0xb8, 0x6c), RGB(0x07, 0x08, 0x0a) }, 10 },
	{ B_TRUNK, 1, { RGB(0xd8, 0x9f, 0x5c), RGB(0x07, 0x08, 0x0a) }, 9 },
	{ B_MOTORWAY, 1, { RGB(0xd4, 0x89, 0x4d), RGB(0x07, 0x08, 0x0a) }, 8 },
	/* the roads themselves */
	{ B_PATH, 0, { RGB(0xc9, 0xbf, 0xb0), RGB(0x3c, 0x3b, 0x37) }, 14 },
	{ B_RAIL, 0, { RGB(0xb6, 0xb1, 0xab), RGB(0x45, 0x48, 0x4f) }, 10 },
	{ B_SERVICE, 0, { RGB(0xff, 0xff, 0xff), RGB(0x31, 0x35, 0x3c) }, 13 },
	{ B_MINOR, 0, { RGB(0xff, 0xff, 0xff), RGB(0x38, 0x3d, 0x45) }, 11 },
	{ B_TERTIARY, 0, { RGB(0xff, 0xff, 0xff), RGB(0x46, 0x4b, 0x53) }, 10 },
	{ B_SECONDARY, 0, { RGB(0xff, 0xf4, 0xbd), RGB(0x57, 0x57, 0x50) }, 9 },
	{ B_PRIMARY, 0, { RGB(0xfd, 0xe2, 0x9c), RGB(0x6a, 0x61, 0x44) }, 7 },
	{ B_TRUNK, 0, { RGB(0xf9, 0xcc, 0x89), RGB(0x78, 0x61, 0x3e) }, 6 },
	{ B_MOTORWAY, 0, { RGB(0xf6, 0xb6, 0x79), RGB(0x86, 0x5d, 0x37) }, 5 },
	{ B_STATE, 0, { 0xb9a8c8b0u, 0x5a4f6cc0u }, 4 },
	{ B_COUNTRY, 0, { RGB(0xa9, 0x8f, 0xbd), RGB(0x6b, 0x58, 0x7d) }, 0 },
};

const unsigned style_draw_count = sizeof(style_draws) / sizeof(style_draws[0]);

uint32_t
style_background(int dark)
{
	return dark ? RGB(0x0c, 0x0e, 0x12) : RGB(0xf7, 0xf5, 0xf0);
}

/* -- line widths: points at zoom stops, exponential (base 1.5) between them, as map styles do */

struct stops {
	unsigned char count;
	float zoom[6], points[6];
};

static const struct stops widths[B_COUNT] = {
	[B_RIVER] = { 4, { 8, 12, 14, 18 }, { 0.5f, 1.2f, 2.2f, 7 } },
	[B_STREAM] = { 3, { 12, 14, 18 }, { 0.4f, 0.8f, 2.5f } },
	[B_RUNWAY] = { 3, { 10, 14, 18 }, { 1, 9, 45 } },
	[B_TAXIWAY] = { 3, { 12, 14, 18 }, { 0.5f, 2, 10 } },
	[B_PATH] = { 3, { 14, 16, 18 }, { 0.6f, 1.2f, 2.5f } },
	[B_RAIL] = { 3, { 10, 14, 18 }, { 0.5f, 1, 2.5f } },
	[B_SERVICE] = { 3, { 13, 16, 18 }, { 0.6f, 2.5f, 7 } },
	[B_MINOR] = { 4, { 11, 13, 16, 18 }, { 0.4f, 1.2f, 5.5f, 14 } },
	[B_TERTIARY] = { 5, { 10, 12, 14, 16, 18 }, { 0.4f, 1, 3, 7, 18 } },
	[B_SECONDARY] = { 5, { 9, 12, 14, 16, 18 }, { 0.4f, 1.6f, 4, 8, 20 } },
	[B_PRIMARY] = { 6, { 7, 10, 12, 14, 16, 18 }, { 0.4f, 1.2f, 2.5f, 5, 10, 24 } },
	[B_TRUNK] = { 6, { 6, 10, 12, 14, 16, 18 }, { 0.4f, 1.8f, 3, 5.5f, 11, 26 } },
	[B_MOTORWAY] = { 6, { 5, 8, 10, 12, 14, 18 }, { 0.5f, 1.2f, 2.2f, 3.5f, 6, 30 } },
	[B_COUNTRY] = { 3, { 2, 6, 10 }, { 0.6f, 1.2f, 2 } },
	[B_STATE] = { 2, { 4, 10 }, { 0.4f, 1 } },
};

static float
interpolate(const struct stops *s, double zoom)
{
	if (s->count == 0) {
		return 1;
	}
	if (zoom <= s->zoom[0]) {
		return s->points[0];
	}
	for (unsigned i = 1; i < s->count; i++) {
		if (zoom <= s->zoom[i]) {
			double span = s->zoom[i] - s->zoom[i - 1], t = (pow(1.5, zoom - s->zoom[i - 1]) - 1) / (pow(1.5, span) - 1);

			return (float)(s->points[i - 1] + (s->points[i] - s->points[i - 1]) * t);
		}
	}
	/* (past the last stop the width keeps growing as the map does: twice a zoom level) */
	return (float)(s->points[s->count - 1] * pow(2, zoom - s->zoom[s->count - 1]));
}

float
style_line_width(enum style_bucket bucket, double zoom, int casing)
{
	float w = interpolate(&widths[bucket], zoom);

	if (casing) {
		/* (a casing shows on each side as a hairline at first and grows to 1.5 points) */
		w += 2 * (float)fmin(1.5, fmax(0.5, (zoom - 10) * 0.25));
	}
	return w;
}

/* -- labels */

const struct style_label_look style_label_looks[L_KIND_COUNT] = {
	[L_COUNTRY] = { 15, { RGB(0x5b, 0x4a, 0x6b), RGB(0xc8, 0xbc, 0xd6) }, { 0xffffffd0u, 0x000000d0u }, 1, 2, 7 },
	[L_STATE] = { 12, { RGB(0x84, 0x74, 0x92), RGB(0x9e, 0x93, 0xab) }, { 0xffffffc0u, 0x000000c0u }, 0, 4, 8 },
	[L_CITY] = { 15, { RGB(0x2b, 0x2b, 0x2b), RGB(0xdc, 0xe0, 0xe6) }, { 0xffffffe0u, 0x000000e0u }, 1, 4, 14 },
	[L_TOWN] = { 13, { RGB(0x36, 0x36, 0x36), RGB(0xcc, 0xd1, 0xd8) }, { 0xffffffe0u, 0x000000e0u }, 1, 7, 15 },
	[L_VILLAGE] = { 12, { RGB(0x44, 0x44, 0x44), RGB(0xbc, 0xc1, 0xc9) }, { 0xffffffd0u, 0x000000d0u }, 0, 10, 17 },
	[L_SUBURB] = { 12, { RGB(0x5c, 0x58, 0x55), RGB(0xa9, 0xae, 0xb6) }, { 0xffffffd0u, 0x000000d0u }, 0, 11, 16 },
	[L_NEIGHBOURHOOD] = { 11, { RGB(0x6e, 0x69, 0x65), RGB(0x96, 0x9b, 0xa3) }, { 0xffffffd0u, 0x000000d0u }, 0, 13, 18 },
	[L_WATER] = { 12, { RGB(0x3f, 0x77, 0xa1), RGB(0x6b, 0x9e, 0xc4) }, { 0xffffffb0u, 0x000000b0u }, 0, 5, 20 },
	[L_PARK] = { 11, { RGB(0x3f, 0x7a, 0x3d), RGB(0x6f, 0xa8, 0x72) }, { 0xffffffc0u, 0x000000c0u }, 0, 12, 20 },
	[L_POI] = { 11, { RGB(0x5a, 0x54, 0x4f), RGB(0x9c, 0xa1, 0xa8) }, { 0xffffffd0u, 0x000000d0u }, 0, 14, 20 },
	[L_ROAD] = { 11, { RGB(0x3c, 0x3c, 0x3c), RGB(0xc0, 0xc5, 0xcc) }, { 0xffffffe0u, 0x000000e0u }, 0, 12, 20 },
	[L_ROAD_MINOR] = { 10, { RGB(0x55, 0x55, 0x55), RGB(0xa5, 0xaa, 0xb2) }, { 0xffffffe0u, 0x000000e0u }, 0, 15, 20 },
};

int
style_label_of(const struct mvt_layer *layer, const struct mvt_feature *feature, int zoom, int *priority)
{
	const struct mvt_value *c = mvt_value_of(layer, feature, "class");
	double rank = number_of(mvt_value_of(layer, feature, "rank"), 99);
	int kind = -1;

	if (layer_is(layer, "place") && feature->type == MVT_POINT) {
		if (ANY(c, "country")) {
			kind = L_COUNTRY;
		} else if (ANY(c, "state", "province")) {
			kind = L_STATE;
		} else if (ANY(c, "city")) {
			kind = L_CITY;
		} else if (ANY(c, "town")) {
			kind = L_TOWN;
		} else if (ANY(c, "village", "hamlet", "island")) {
			kind = L_VILLAGE;
		} else if (ANY(c, "suburb")) {
			kind = L_SUBURB;
		} else if (ANY(c, "quarter", "neighbourhood")) {
			kind = L_NEIGHBOURHOOD;
		}
	} else if (layer_is(layer, "water_name")) {
		kind = L_WATER;
		/* (a lake, or a pond, a pool: named only close up -- a sea, a bay, a strait from afar) */
		if (ANY(c, "lake")) {
			rank = 500;
		}
	} else if (layer_is(layer, "park") && feature->type == MVT_POINT) {
		kind = L_PARK;
	} else if (layer_is(layer, "poi") && feature->type == MVT_POINT) {
		/* (thousands of POIs in one tile of a city's centre: only the important ones, more of them the closer the map;
		   a bus stop only when it is very close) */
		if (ANY(c, "bus")) {
			rank += 30;
		}
		if (rank <= style_poi_rank(zoom)) {
			kind = L_POI;
		}
	} else if (layer_is(layer, "transportation_name") && feature->type == MVT_LINE) {
		kind = ANY(c, "motorway", "trunk", "primary", "secondary", "tertiary") ? L_ROAD :
		    ANY(c, "minor", "service") ? L_ROAD_MINOR : -1;
	}
	if (kind < 0) {
		return -1;
	}
	/* (a POI's rank can be past 99 -- a bus stop's is 30 more -- and style_label_shown reads it back) */
	*priority = kind * 1000 + (int)fmin(999, rank);
	return kind;
}

/* (as OpenFreeMap's own style, "liberty", has them: none before 15, the first six of a tile's ranks from 15, the
   first twenty from 16, all of them from 17) */
double
style_poi_rank(double zoom)
{
	return zoom >= 17 ? 1000 : zoom >= 16 ? 19 : zoom >= 15 ? 6 : 0;
}

int
style_label_shown(int kind, int priority, double zoom)
{
	const struct style_label_look *look = &style_label_looks[kind];

	if (zoom < look->min_zoom || zoom >= look->max_zoom + 1) {
		return 0;
	}
	if (kind == L_WATER && priority % 1000 >= 500) {
		return zoom >= 15;
	}
	return kind != L_POI || priority % 1000 <= style_poi_rank(zoom);
}
