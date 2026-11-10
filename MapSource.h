// MapSource.h: the vector tiles -- where they are (OpenFreeMap's TileJSON), downloading them (only those the screen
// wants now, six at a time), and making each one into meshes and labels on a background queue (tessellate.c). The
// tiles made are kept in memory while there is room; the downloads also in an HTTP cache on disk.
#import <Foundation/Foundation.h>
#import "tessellate.h"

#define MAP_DATA_ZOOM 14                /* the deepest level the tiles come in; deeper zooms enlarge those */

/* A tile, or the place on the screen one is shown in, as one number: its level, x (offset by 2^30, so that the copies
   of the world east and west have numbers too) and y. */
static inline uint64_t
tile_id(int z, long x, long y)
{
	return (uint64_t)z << 56 | (uint64_t)(x + (1L << 30)) << 24 | (uint64_t)y;
}

static inline int
tile_z(uint64_t tile)
{
	return (int)(tile >> 56);
}

static inline long
tile_x(uint64_t tile)
{
	return (long)(tile >> 24 & 0xffffffff) - (1L << 30);
}

static inline long
tile_y(uint64_t tile)
{
	return (long)(tile & 0xffffff);
}

/* one tile made: its meshes and labels, and what the renderer of the moment made of them */
@interface MapTile : NSObject
@property (readonly, nonatomic) uint64_t key;
@property (readonly, nonatomic) const struct tess_tile *mesh;
@property (readonly, nonatomic) NSUInteger bytes;
/* the GPU's copy, and which renderer made it (MapView's count of them) */
@property (strong, nonatomic) id gpu;
@property (nonatomic) NSUInteger gpuOf;
@end

@protocol MapSourceDelegate <NSObject>
- (void)sourceTileArrived:(uint64_t)key;
- (void)sourceTileFailed:(uint64_t)key;
/* tiles failed a while ago: whichever are still wanted may be asked for again */
- (void)sourceMayRetry;
@end

@interface MapSource : NSObject
@property (weak, nonatomic) id<MapSourceDelegate> delegate;
/* the names labels take; another one forgets the tiles made with the one before */
@property (nonatomic) enum style_language language;
/* what went wrong last, for the self-test (nil: nothing) */
@property (readonly, nonatomic) NSString *problem;
@property (readonly, nonatomic) NSUInteger downloads, made;

- (MapTile *)tileFor:(uint64_t)key;
/* every tile made that is still in memory */
- (void)forEachTile:(void (^)(MapTile *tile))block;
- (BOOL)failed:(uint64_t)key;
/* the tiles wanted now, the most wanted first: it replaces the list before, and what is not on it stops */
- (void)want:(NSArray<NSNumber *> *)keys;
- (void)forget;
@end

/* who is asking, for the tile and the search servers: both their usage policies want an application to say */
NSString *user_agent(void);
