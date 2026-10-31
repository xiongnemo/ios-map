// MapView: OpenStreetMap's raster tiles, drawn without the GPU. Every tile on the screen is a CALayer whose contents is
// the tile's PNG, decoded on a background queue into a plain bitmap; the main thread only moves those layers about, and
// Core Animation composites them in the window server (on the K40 port the one place that has OpenGL ES). Nothing of
// MapKit (it draws with Metal, which the port lacks) and nothing of Metal or OpenGL ES in the process.
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

#define MAP_MIN_ZOOM 2
#define MAP_MAX_ZOOM 19

@class MapView;

@protocol MapViewDelegate <NSObject>
/* the centre or the zoom changed: on every frame of a gesture or an animation */
- (void)mapViewDidChange:(MapView *)map;
/* the user began to move the map; dragged: by dragging it, which should stop it following the location */
- (void)mapViewWillMove:(MapView *)map dragged:(BOOL)dragged;
@end

@interface MapView : UIView
@property (weak, nonatomic) id<MapViewDelegate> delegate;
@property (readonly, nonatomic) CLLocationCoordinate2D centerCoordinate;
@property (readonly, nonatomic) double zoom;
/* metres a point covers at the centre */
@property (readonly, nonatomic) double metresPerPoint;
/* the blue dot and its accuracy circle (nil: none) */
@property (strong, nonatomic) CLLocation *userLocation;
/* the heading cone: degrees clockwise from north of where the top of the screen points (< 0: none) */
@property (nonatomic) double heading;
/* pinches and taps zoom about the user's location rather than the fingers */
@property (nonatomic) BOOL followsUser;

- (void)setCenterCoordinate:(CLLocationCoordinate2D)center zoom:(double)zoom animated:(BOOL)animated;
/* one pin at a time, with a callout: its title, its coordinates, Copy and a close button */
- (void)showPinAt:(CLLocationCoordinate2D)where title:(NSString *)title;
- (void)removePin;
/* forgets the decoded tiles kept in memory (a memory warning); those on the screen stay there */
- (void)forgetTiles;
@end

/* "latitude, longitude" in decimal degrees, 5 places (about a metre) */
NSString *coordinate_text(CLLocationCoordinate2D where);
/* who is asking, for the tile and the search servers: both their usage policies want an application to say */
NSString *user_agent(void);
/* a latitude as Web Mercator's y: 0 at the north edge of the square world, 1 at the south edge */
double mercator_y(double latitude);
