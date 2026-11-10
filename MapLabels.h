// MapLabels.h: the names on the map. Each frame, the labels of the tiles drawn are placed on the screen in the order
// of how much they matter, each one only where it overlaps none placed before it; each label's text is drawn once,
// with its halo, by Core Text into the renderer's atlas, and is a quad of it from then on. Road names lie along the
// longest stretch of their road, never upside down.
#import <UIKit/UIKit.h>
#import "MapRenderer.h"
#import "MapSource.h"

@interface MapLabels : NSObject
/* the place names' language: Chinese ones are written in its script (Simplified or Traditional) whatever the data's */
@property (nonatomic) enum style_language language;
/* labels waiting for their text to be drawn into the atlas (a few each frame): another frame is wanted */
@property (readonly, nonatomic) BOOL pending;
@property (readonly, nonatomic) unsigned placed;

/* a frame of `size` points at `scale` pixels a point, the map at style zoom `zoom` turned by `bearing` radians; no
   label goes where `covered` (CGRects of the view's) is -- the search bar, the buttons -- nor past the screen's edge */
- (void)beginFrame:(CGSize)size scale:(CGFloat)scale zoom:(double)zoom bearing:(double)bearing dark:(BOOL)dark
    covered:(NSArray<NSValue *> *)covered;
/* the labels of a tile drawn: `transform` takes its units to screen points, `clip` is the part of it shown */
- (void)addTile:(MapTile *)tile transform:(CGAffineTransform)transform clip:(const float *)clip;
/* the frame's labels as quads, drawn into `renderer`'s atlas as needed; valid until the next beginFrame */
- (const struct map_label_vertex *)finishFor:(id<MapRenderer>)renderer count:(unsigned *)count;
/* the renderer is a new one: its atlas has nothing in it */
- (void)forgetAtlas;
@end
