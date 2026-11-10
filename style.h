// style.h: what the map draws of a vector tile (OpenMapTiles' layers), in which order, and how: the buckets features are
// sorted into, the draw list over them (a road's casing and its fill are two draws of one bucket), the colours of the
// light and the dark style, line widths by zoom, and which names become labels.
#ifndef STYLE_H
#define STYLE_H

#include <stdint.h>

#include "mvt.h"

/* the features of a tile that are tessellated together: one vertex buffer each per tile */
enum style_bucket {
	B_WOOD, B_GRASS, B_FARMLAND, B_SAND, B_ICE, B_WETLAND,
	B_RESIDENTIAL, B_COMMERCIAL, B_INDUSTRIAL, B_INSTITUTIONAL, B_CEMETERY, B_PITCH,
	B_PARK, B_WATER, B_AERODROME, B_PIER, B_BUILDING,
	B_RIVER, B_STREAM,
	B_RUNWAY, B_TAXIWAY,
	B_PATH, B_RAIL, B_SERVICE, B_MINOR, B_TERTIARY, B_SECONDARY, B_PRIMARY, B_TRUNK, B_MOTORWAY,
	B_STATE, B_COUNTRY,
	B_COUNT                         /* (at most 32: the shaders' tables) */
};

enum style_kind { STYLE_FILL, STYLE_LINE };

/* one draw of a bucket, in the order of the draw list */
struct style_draw {
	enum style_bucket bucket;
	int casing;                     /* a line's casing: drawn wider, under all the fills */
	uint32_t colour[2];             /* 0xRRGGBBAA, light and dark */
	unsigned char min_zoom;         /* drawn from this zoom on */
};

extern const struct style_draw style_draws[];
extern const unsigned style_draw_count;

enum style_kind style_kind_of(enum style_bucket bucket);
/* the bucket of a feature of the named layer at tile zoom `zoom`, or -1: not drawn */
int style_bucket_of(const struct mvt_layer *layer, const struct mvt_feature *feature, int zoom);
/* a line's width in points at a (fractional) zoom, the casing's when asked: what each side of its middle is twice */
float style_line_width(enum style_bucket bucket, double zoom, int casing);
uint32_t style_background(int dark);

/* -- labels */

enum style_label_kind {
	L_COUNTRY, L_STATE, L_CITY, L_TOWN, L_VILLAGE, L_SUBURB, L_NEIGHBOURHOOD,
	L_WATER, L_PARK, L_POI, L_ROAD, L_ROAD_MINOR,
	L_KIND_COUNT
};

struct style_label_look {
	float size;                     /* points */
	uint32_t colour[2], halo[2];
	int bold;
	unsigned char min_zoom, max_zoom;
};

extern const struct style_label_look style_label_looks[L_KIND_COUNT];

/*
 * The label kind of a feature (-1: none) and how much it matters (lower first: kind * 1000 + the feature's rank), for a
 * tile shown up to zoom `zoom`. Whether it is shown at the zoom of the moment is style_label_shown()'s question.
 */
int style_label_of(const struct mvt_layer *layer, const struct mvt_feature *feature, int zoom, int *priority);
int style_label_shown(int kind, int priority, double zoom);
/* the least important POI rank shown at a zoom (OpenMapTiles' rank: 1 matters most) */
double style_poi_rank(double zoom);

/* which name a label takes: the one of the place, or a language's where the data has it (Chinese: Simplified) */
enum style_language { LANGUAGE_LOCAL, LANGUAGE_CHINESE, LANGUAGE_ENGLISH, LANGUAGE_CHINESE_TRADITIONAL };

#endif
