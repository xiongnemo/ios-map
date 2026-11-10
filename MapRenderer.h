// MapRenderer.h: what draws the map. Two of them draw the same frames, one with OpenGL ES (MapRendererGL.m), one with
// Metal (MapRendererMetal.m); the settings choose. MapView says what a frame is -- which tiles' meshes go where on the
// screen and which part of each is shown, the colours and line widths of the moment, the labels' quads -- and a renderer
// only draws that: everything about the map is worked out once, in MapView.m, for both.
#import <QuartzCore/QuartzCore.h>
#import "tessellate.h"

/*
 * A pass over every piece of the frame: the fills, or the lines with each bucket's colour and half-width. A bucket whose
 * colour has an alpha of 0 is not in the pass (its triangles are made empty in the vertex shader). Within a pass the
 * buckets are drawn in the order of style.h's enum, which is the order of their indices in a tile's mesh.
 */
#define MAP_PASSES 4
struct map_pass {
	int lines;                      /* the tiles' line meshes, else their fill meshes */
	float colour[B_COUNT][4];       /* premultiplied */
	float half[B_COUNT];            /* lines: half the width, in points */
};

/* one tile's mesh in one place: a tile of the screen, drawn with its own mesh or a part of an ancestor's */
struct map_piece {
	__unsafe_unretained id tile;    /* what the renderer made of the tile (-makeTile:) */
	float matrix[6];                /* tile units to clip space: x' = m0 x + m2 y + m4, y' = m1 x + m3 y + m5 */
	float clip[4];                  /* what is shown of it, in its units: x0, y0, x1, y1 (the rest is the neighbours') */
};

/* a corner of a label's quad (six to a label: two triangles), placed by MapView in clip space */
struct map_label_vertex {
	float x, y;
	float u, v;                     /* in the atlas, 0 to 1 */
	uint8_t colour[4], halo[4];     /* premultiplied RGBA */
};

#define MAP_ATLAS 4096                  /* the labels' atlas: this many pixels square, two channels (text, halo) */

struct map_frame {
	float background[4];            /* premultiplied */
	struct map_pass passes[MAP_PASSES];
	const struct map_piece *pieces;
	unsigned piece_count;
	float extrude[4];               /* a line's way out from its middle, in points, to clip space: 2x2, column major */
	float pixel;                    /* points a pixel: the lines' soft edges are a pixel wide */
	const struct map_label_vertex *labels;
	unsigned label_vertices;
};

@protocol MapRenderer <NSObject>
/* what it draws into: a CAEAGLLayer or a CAMetalLayer, for MapView to put where the map goes */
@property (readonly, nonatomic) CALayer *layer;
/* "OpenGL ES 3.0", "Metal": what the settings and the self-test say */
@property (readonly, nonatomic) NSString *name;
/* the GPU's copy of a tile's meshes (nil: it could not be made); MapView keeps it with the tile */
- (id)makeTile:(const struct tess_tile *)tile;
/* replaces a rectangle of the atlas: two bytes a pixel (text, halo), rows of `stride` bytes */
- (void)atlasReplace:(CGRect)rect bytes:(const uint8_t *)bytes stride:(size_t)stride;
/* a frame of the layer's size (its bounds times its contentsScale), presented */
- (void)drawFrame:(const struct map_frame *)frame;
/* the next frame read back after it is drawn (for the self-test): RGBA, top row first; on the main thread */
- (void)captureNextFrame:(void (^)(const uint8_t *rgba, size_t width, size_t height))done;
/* where its frames' time went since it was asked last (for the self-test): a sentence, and the counts begun again */
- (NSString *)timing;
@end

/* a renderer drawing `samples` samples a pixel (4, or 1: none, the lines' soft edges only), or nil and why not (a
   sentence for the settings: the device has no Metal, ...) */
id<MapRenderer> map_renderer_gl(unsigned samples, NSString **why);
id<MapRenderer> map_renderer_metal(unsigned samples, NSString **why);
/* why Metal cannot draw the map here (nil: it can) */
NSString *map_metal_problem(void);
