// MapView: OpenStreetMap as vector tiles, drawn by the GPU at the screen's own resolution -- sharp at every zoom, and
// turned when two fingers turn it. The tiles come from MapSource (OpenFreeMap), become triangles on a background queue
// (tessellate.c), and are drawn by a renderer of MapRenderer.h: OpenGL ES or Metal, as the settings say. The location's
// dot and cone and the pin are layers and views over that, as in Map 1.0.
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import "MapSource.h"

#define MAP_MIN_ZOOM 2
#define MAP_MAX_ZOOM 21                 /* (a zoom here is OpenStreetMap's: a tile of the level is 256 points across) */

typedef NS_ENUM(NSInteger, MapRendererKind) { MapRendererKindGL, MapRendererKindMetal };
typedef NS_ENUM(NSInteger, MapStyleChoice) { MapStyleSystem, MapStyleLight, MapStyleDark };

@class MapView;

@protocol MapViewDelegate <NSObject>
/* the centre, the zoom or the bearing changed: once a frame while it moves */
- (void)mapViewDidChange:(MapView *)map;
/* the user began to move the map; dragged: by dragging it, which should stop it following the location */
- (void)mapViewWillMove:(MapView *)map dragged:(BOOL)dragged;
@optional
/* the map turned dark or light */
- (void)mapViewDidChangeLook:(MapView *)map;
@end

@interface MapView : UIView
@property (weak, nonatomic) id<MapViewDelegate> delegate;
@property (readonly, nonatomic) CLLocationCoordinate2D centerCoordinate;
@property (readonly, nonatomic) double zoom;
/* degrees clockwise from north of where the top of the screen points */
@property (readonly, nonatomic) double bearing;
/* metres a point covers at the centre */
@property (readonly, nonatomic) double metresPerPoint;
/* the blue dot and its accuracy circle (nil: none) */
@property (strong, nonatomic) CLLocation *userLocation;
/* the heading cone: degrees clockwise from north of where the top of the device points (< 0: none) */
@property (nonatomic) double heading;
/* pinches and taps zoom about the user's location rather than the fingers */
@property (nonatomic) BOOL followsUser;

/* what draws it; Metal that is not there (nil: it is) draws with OpenGL ES instead */
@property (nonatomic) MapRendererKind rendererKind;
/* samples a pixel: 4 (the default), or 1 */
@property (nonatomic) unsigned samples;
@property (readonly, nonatomic) NSString *rendererName;
@property (nonatomic) MapStyleChoice style;
@property (readonly, nonatomic) BOOL dark;
@property (nonatomic) enum style_language labelLanguage;
/* frames a second and the time a frame takes, in a corner */
@property (nonatomic) BOOL showsFrameRate;
/* what covers the map (CGRects of the view's: the search bar, the buttons): no label is put under them */
@property (copy, nonatomic) NSArray<NSValue *> *coveredRects;

- (void)setCenterCoordinate:(CLLocationCoordinate2D)center zoom:(double)zoom animated:(BOOL)animated;
- (void)setBearing:(double)degrees animated:(BOOL)animated;
/* one pin at a time, with a callout: its title, its coordinates, Copy and a close button */
- (void)showPinAt:(CLLocationCoordinate2D)where title:(NSString *)title;
- (void)removePin;
/* forgets the tiles kept in memory (a memory warning); they come back from the disk cache */
- (void)forgetTiles;

/*
 * The self-test: the map at `where` and `zoom` with the renderer of `kind`; when its tiles are all there (or after
 * 30 seconds), a frame read back and looked at, then three seconds of turning and zooming timed. `done` gets what was
 * found, as text lines "name: value".
 */
- (void)testAt:(CLLocationCoordinate2D)where zoom:(double)zoom renderer:(MapRendererKind)kind samples:(unsigned)samples
    done:(void (^)(NSArray<NSString *> *lines))done;
@end

/* why Metal cannot draw the map here (nil: it can) */
NSString *map_metal_problem(void);
/* "latitude, longitude" in decimal degrees, 5 places (about a metre) */
NSString *coordinate_text(CLLocationCoordinate2D where);
/* a latitude as Web Mercator's y: 0 at the north edge of the square world, 1 at the south edge */
double mercator_y(double latitude);
