// MapView.m: the tiles (MapTiles downloads, decodes and keeps them), the layers they are shown in, the gestures, the
// location's dot and cone, and the pin. See MapView.h.
#import <QuartzCore/QuartzCore.h>
#import "MapView.h"

#define TILE_POINTS     256.0           /* a tile's size at its own zoom: its 256 pixels as 256 points, as OSM's maps do */
#define EARTH_RADIUS    6378137.0       /* metres: Web Mercator's sphere, the size of WGS 84's equator */
#define MAX_LATITUDE    85.0511287798   /* where Web Mercator's square world ends, north and south */
#define DOWNLOADS       6               /* tiles downloading at once, as a browser would */
#define DECODED_BYTES   (150 << 20)     /* decoded tiles kept in memory, counted by their bitmaps */
#define DISK_BYTES      (50 << 20)      /* the PNGs on disk: little, as the data disk of the K40 port is RAM */
#define MEMORY_BYTES    (4 << 20)       /* the PNGs in the URL cache's memory (the decoded ones are what counts) */
#define FALLBACK_LEVELS 5               /* how many levels up a missing tile looks for one to enlarge */
#define RETRY_AFTER     15.0            /* seconds before a tile that failed is asked for again (doubling each time) */

static NSString *const default_tile_url = @"https://tile.openstreetmap.org/{z}/{x}/{y}.png";

NSString *
user_agent(void)
{
	static NSString *agent;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";

		agent = [NSString stringWithFormat:@"Map/%@ (iOS; https://github.com/xiongnemo/ios-map)", version];
	});
	return agent;
}

NSString *
coordinate_text(CLLocationCoordinate2D where)
{
	return [NSString stringWithFormat:@"%.5f, %.5f", where.latitude, where.longitude];
}

/*
 * Web Mercator as a square of side 1: x from 0 at 180° west to 1 at 180° east, y from 0 at the top (85.05° north) to 1
 * at the bottom. A zoom level z cuts it into 2^z by 2^z tiles.
 */
static double
world_x(double longitude)
{
	return (longitude + 180) / 360;
}

double
mercator_y(double latitude)
{
	double phi = fmax(-MAX_LATITUDE, fmin(MAX_LATITUDE, latitude)) * M_PI / 180;

	return (1 - asinh(tan(phi)) / M_PI) / 2;
}

static double
longitude_at(double x)
{
	return (x - floor(x)) * 360 - 180;
}

static double
latitude_at(double y)
{
	return atan(sinh(M_PI * (1 - 2 * y))) * 180 / M_PI;
}

/*
 * A tile, or the place on the screen one is shown in, as one number: its level, x and y. x is offset by 2^30 so that
 * the places west of x = 0 and east of the last tile (the world repeats east and west) have numbers too.
 */
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

/*
 * A PNG as a bitmap ready to be shown: UIImage only reads the file and decodes it when it is first drawn, which would be
 * on the main thread, in the middle of a frame. Drawing it here, on a background queue, into a bitmap of the layout Core
 * Animation uses itself (32-bit BGRA, premultiplied) does the decoding now, and leaves Core Animation nothing to convert.
 */
static id
decoded(NSData *data)
{
	UIImage *png = [UIImage imageWithData:data];
	CGImageRef source = png.CGImage, image;
	CGColorSpaceRef space;
	CGContextRef context;
	size_t width, height;

	if (source == NULL) {
		return nil;
	}
	width = CGImageGetWidth(source);
	height = CGImageGetHeight(source);
	if (width == 0 || height == 0 || width > 1024 || height > 1024) {
		return nil;
	}
	space = CGColorSpaceCreateDeviceRGB();
	context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
	    (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(space);
	if (context == NULL) {
		return nil;
	}
	CGContextSetBlendMode(context, kCGBlendModeCopy);
	CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);
	image = CGBitmapContextCreateImage(context);
	CGContextRelease(context);
	return image == NULL ? nil : (__bridge_transfer id)image;
}

@protocol MapTilesDelegate <NSObject>
- (void)tileArrived:(uint64_t)tile;
- (void)tileFailed:(uint64_t)tile;
/* some tiles failed a while ago: whichever are still wanted may be asked for again */
- (void)tilesMayBeRetried;
@end

/*
 * The tiles: the decoded ones in an NSCache (it lets go of them itself when memory runs short), the PNGs in a small
 * NSURLCache that honours the server's HTTP caching (OSM's usage policy asks for that), and at most DOWNLOADS
 * downloads at a time, of only the tiles the screen wants now, nearest its middle first. A tile that leaves the screen
 * is cancelled. Everything here is on the main thread except the download and the decoding.
 */
@interface MapTiles : NSObject
@property (weak, nonatomic) id<MapTilesDelegate> delegate;
- (id)imageFor:(uint64_t)tile;
- (BOOL)failed:(uint64_t)tile;
- (void)want:(NSArray<NSNumber *> *)tiles;
- (void)forget;
@end

@implementation MapTiles {
	NSURLSession *_session;
	NSString *_template;
	NSCache *_images;
	NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *_running;
	NSMutableArray<NSNumber *> *_queue;
	NSMutableDictionary<NSNumber *, NSNumber *> *_failedAt, *_failures;
	BOOL _retrying;
}

- (instancetype)init
{
	NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
	NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
	NSString *custom = [NSUserDefaults.standardUserDefaults stringForKey:@"TileURL"];

	self = [super init];
	if (self == nil) {
		return nil;
	}
	_template = custom.length > 0 ? custom : default_tile_url;
	config.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:MEMORY_BYTES diskCapacity:DISK_BYTES
	    directoryURL:[caches URLByAppendingPathComponent:@"Tiles" isDirectory:YES]];
	config.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
	/* (iOS allows 4 connections to a host by default; over HTTP/2 there is one, and DOWNLOADS is kept here anyway) */
	config.HTTPMaximumConnectionsPerHost = DOWNLOADS;
	config.HTTPAdditionalHeaders = @{ @"User-Agent": user_agent() };
	config.timeoutIntervalForRequest = 20;
	_session = [NSURLSession sessionWithConfiguration:config];
	_images = [NSCache new];
	_images.totalCostLimit = DECODED_BYTES;
	_running = [NSMutableDictionary new];
	_queue = [NSMutableArray new];
	_failedAt = [NSMutableDictionary new];
	_failures = [NSMutableDictionary new];
	return self;
}

- (id)imageFor:(uint64_t)tile
{
	return [_images objectForKey:@(tile)];
}

- (BOOL)failed:(uint64_t)tile
{
	NSNumber *key = @(tile), *when = _failedAt[key];
	double wait;

	if (when == nil) {
		return NO;
	}
	/* (each failure in a row doubles the wait, up to five minutes: a server that refuses is not asked every second) */
	wait = fmin(RETRY_AFTER * exp2(_failures[key].intValue - 1), 300);
	return CFAbsoluteTimeGetCurrent() - when.doubleValue < wait;
}

- (NSURL *)urlFor:(uint64_t)tile
{
	NSString *url = _template;

	url = [url stringByReplacingOccurrencesOfString:@"{z}" withString:[NSString stringWithFormat:@"%d", tile_z(tile)]];
	url = [url stringByReplacingOccurrencesOfString:@"{x}" withString:[NSString stringWithFormat:@"%ld", tile_x(tile)]];
	url = [url stringByReplacingOccurrencesOfString:@"{y}" withString:[NSString stringWithFormat:@"%ld", tile_y(tile)]];
	return [NSURL URLWithString:url];
}

/* The wish list, nearest the screen's middle first; it replaces the one before, and what is no longer on it stops. */
- (void)want:(NSArray<NSNumber *> *)tiles
{
	NSSet<NSNumber *> *wanted = [NSSet setWithArray:tiles];

	for (NSNumber *key in _running.allKeys) {
		if (![wanted containsObject:key]) {
			[_running[key] cancel];
			[_running removeObjectForKey:key];
		}
	}
	[_queue removeAllObjects];
	for (NSNumber *key in tiles) {
		if (_running[key] == nil && [_images objectForKey:key] == nil && ![self failed:key.unsignedLongLongValue]) {
			[_queue addObject:key];
		}
	}
	[self pump];
}

- (void)pump
{
	while (_running.count < DOWNLOADS && _queue.count > 0) {
		NSNumber *key = _queue.firstObject;

		[_queue removeObjectAtIndex:0];
		if (_running[key] == nil && [_images objectForKey:key] == nil) {
			[self start:key.unsignedLongLongValue];
		}
	}
}

- (void)start:(uint64_t)tile
{
	NSURL *url = [self urlFor:tile];
	NSMutableURLRequest *request;
	NSURLSessionDataTask *task;
	__block __weak NSURLSessionDataTask *weakTask = nil;
	__weak MapTiles *weak = self;

	if (url == nil) {
		/* (a TileURL that is not a URL: every tile fails, grey, and nothing crashes) */
		dispatch_async(dispatch_get_main_queue(), ^{
			[weak finished:tile task:nil image:nil cancelled:NO];
		});
		return;
	}
	request = [NSMutableURLRequest requestWithURL:url];
	[request setValue:user_agent() forHTTPHeaderField:@"User-Agent"];
	task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response,
	    NSError *error) {
		NSURLSessionDataTask *done = weakTask;
		BOOL http = [response isKindOfClass:NSHTTPURLResponse.class];
		NSInteger status = http ? ((NSHTTPURLResponse *)response).statusCode : 0;

		if (error != nil || data.length == 0 || (http && status != 200)) {
			BOOL cancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;

			dispatch_async(dispatch_get_main_queue(), ^{
				[weak finished:tile task:done image:nil cancelled:cancelled];
			});
			return;
		}
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			id image = decoded(data);

			dispatch_async(dispatch_get_main_queue(), ^{
				[weak finished:tile task:done image:image cancelled:NO];
			});
		});
	}];
	weakTask = task;
	_running[@(tile)] = task;
	[task resume];
}

- (void)finished:(uint64_t)tile task:(NSURLSessionDataTask *)task image:(id)image cancelled:(BOOL)cancelled
{
	NSNumber *key = @(tile);

	/* (only if it is still this download: a cancelled one may end after the same tile was asked for again) */
	if (task == nil || _running[key] == task) {
		[_running removeObjectForKey:key];
	}
	if (image != nil) {
		CGImageRef bitmap = (__bridge CGImageRef)image;

		[_images setObject:image forKey:key cost:CGImageGetBytesPerRow(bitmap) * CGImageGetHeight(bitmap)];
		[_failedAt removeObjectForKey:key];
		[_failures removeObjectForKey:key];
		[_delegate tileArrived:tile];
	} else if (!cancelled) {
		_failedAt[key] = @(CFAbsoluteTimeGetCurrent());
		_failures[key] = @(_failures[key].intValue + 1);
		[_delegate tileFailed:tile];
		[self retryLater];
	}
	[self pump];
}

- (void)retryLater
{
	__weak MapTiles *weak = self;

	if (_retrying) {
		return;
	}
	_retrying = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((RETRY_AFTER + 0.5) * NSEC_PER_SEC)),
	    dispatch_get_main_queue(), ^{
		MapTiles *me = weak;

		if (me != nil) {
			me->_retrying = NO;
			[me->_delegate tilesMayBeRetried];
		}
	});
}

- (void)forget
{
	[_images removeAllObjects];
}

@end

/* A layer that never animates by itself: a tile is where the finger put it now, not a quarter of a second later. */
@interface MapQuietLayer : CALayer
@end

@implementation MapQuietLayer

- (id<CAAction>)actionForKey:(NSString *)event
{
	return nil;
}

@end

/*
 * A place on the screen for one tile of the level shown. Until that tile is here it shows the nearest tile above it
 * that is (enlarged: contentsRect picks the part of it that covers this one), and over that whichever of the four tiles
 * below it are (zooming out, they were on the screen a moment ago); with none of them, grey.
 */
@interface MapTileSlot : NSObject {
@public
	MapQuietLayer *layer;
	MapQuietLayer *children[4];
	int z;
	long x, y;              /* x as laid out, east or west of the world's first copy */
	uint64_t tile;          /* the tile it shows: x brought into the world */
	BOOL own;               /* that tile is on it */
	CGRect frame;
}
@end

@implementation MapTileSlot
@end

enum { MOTION_NONE, MOTION_FLING, MOTION_ANIMATION };

/* the location's dot: white ring, blue middle, a faint edge to stand out on white roads */
static UIImage *
dot_image(void)
{
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(26, 26)];

	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[[UIColor colorWithWhite:0 alpha:0.18] setFill];
		[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 26, 26)] fill];
		[UIColor.whiteColor setFill];
		[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1.5, 1.5, 23, 23)] fill];
		[[UIColor colorWithRed:0 green:0.48 blue:1 alpha:1] setFill];
		[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(5.5, 5.5, 15, 15)] fill];
	}];
}

/* the heading: a wedge pointing up from the middle, fading out; the layer is turned to the heading */
static UIImage *
cone_image(void)
{
	CGFloat r = 64;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(2 * r, 2 * r)];

	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		CGFloat spread = 30 * M_PI / 180, colors[] = { 0, 0.48, 1, 0.55, 0, 0.48, 1, 0 };
		CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
		CGGradientRef fade = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
		UIBezierPath *wedge = [UIBezierPath bezierPath];

		[wedge moveToPoint:CGPointMake(r, r)];
		[wedge addArcWithCenter:CGPointMake(r, r) radius:r startAngle:-M_PI_2 - spread endAngle:-M_PI_2 + spread
		    clockwise:YES];
		[wedge closePath];
		[wedge addClip];
		CGContextDrawRadialGradient(context.CGContext, fade, CGPointMake(r, r), 0, CGPointMake(r, r), r, 0);
		CGGradientRelease(fade);
		CGColorSpaceRelease(space);
	}];
}

/* the pin: a red drop with a white hole, its tip at the bottom middle */
static UIImage *
pin_image(void)
{
	static UIImage *image;

	if (image == nil) {
		UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(30, 44)];

		image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
			CGPoint head = CGPointMake(15, 14), tip = CGPointMake(15, 43);
			CGFloat r = 12, side = acos(r / (tip.y - head.y));
			UIBezierPath *drop = [UIBezierPath bezierPath];

			/* (from the tip up one side to where it touches the head, round the head, and down the other side) */
			[drop moveToPoint:tip];
			[drop addArcWithCenter:head radius:r startAngle:M_PI_2 + side endAngle:5 * M_PI_2 - side clockwise:YES];
			[drop closePath];
			drop.lineWidth = 1;
			drop.lineJoinStyle = kCGLineJoinRound;
			[[UIColor colorWithRed:0.90 green:0.22 blue:0.21 alpha:1] setFill];
			[[UIColor colorWithRed:0.55 green:0.08 blue:0.08 alpha:1] setStroke];
			[drop fill];
			[drop stroke];
			[UIColor.whiteColor setFill];
			[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(head.x - 4.5, head.y - 4.5, 9, 9)] fill];
		}];
	}
	return image;
}

@interface MapView () <UIGestureRecognizerDelegate, MapTilesDelegate>
@end

@implementation MapView {
	MapTiles *_tiles;
	CALayer *_tileHost, *_userHost;
	MapQuietLayer *_accuracy, *_cone, *_dot;
	NSMutableDictionary<NSNumber *, MapTileSlot *> *_slots;
	NSMutableArray<MapQuietLayer *> *_spare;
	UIColor *_loadingColor, *_failedColor;
	CGFloat _pixel;             /* the screen's pixels per point */

	double _cx, _cy;            /* the centre, in world units (x wraps round) */
	double _z;                  /* the zoom: fractional, MAP_MIN_ZOOM to MAP_MAX_ZOOM */
	int _level;                 /* the zoom level whose tiles are shown */
	BOOL _zooming;              /* a pinch or a zoom animation: the level's tiles are scaled, and none is fetched */
	BOOL _wantAgain;            /* the tiles wanted are to be sent again, even if the screen shows the same ones */
	double _ux, _uy;            /* the user's location, in world units */

	UIPanGestureRecognizer *_panner;
	UIPinchGestureRecognizer *_pincher;
	BOOL _pinching, _dragTold, _pinchAtKnown;
	CGPoint _pinchAt;
	CFTimeInterval _pinchEnded;

	CADisplayLink *_link;
	int _motion;
	CGPoint _velocity;
	CFTimeInterval _last, _start, _duration;
	double _fromX, _fromY, _fromZ, _toX, _toY, _toZ;
	BOOL _anchored;
	double _anchorX, _anchorY;
	CGPoint _anchorAt;

	BOOL _hasPin;
	double _pinX, _pinY;
	CLLocationCoordinate2D _pinWhere;
	UIImageView *_pin;
	UIView *_callout;
	UIButton *_copy;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	UITapGestureRecognizer *doubleTap, *twoFingerTap;
	UILongPressGestureRecognizer *press;

	self = [super initWithFrame:frame];
	if (self == nil) {
		return nil;
	}
	_loadingColor = [UIColor colorWithRed:0.93 green:0.92 blue:0.90 alpha:1];
	_failedColor = [UIColor colorWithWhite:0.78 alpha:1];
	_pixel = UIScreen.mainScreen.scale;
	self.backgroundColor = _loadingColor;
	self.clipsToBounds = YES;
	self.multipleTouchEnabled = YES;
	_tiles = [MapTiles new];
	_tiles.delegate = self;
	_slots = [NSMutableDictionary new];
	_spare = [NSMutableArray new];
	_tileHost = [MapQuietLayer layer];
	_userHost = [MapQuietLayer layer];
	[self.layer addSublayer:_tileHost];
	[self.layer addSublayer:_userHost];
	[self makeUserLayers];
	_cx = 0.5;
	_cy = 0.5;
	_z = MAP_MIN_ZOOM;
	_level = -1;
	_heading = -1;

	_panner = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
	_pincher = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
	doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
	doubleTap.numberOfTapsRequired = 2;
	twoFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerTap:)];
	twoFingerTap.numberOfTouchesRequired = 2;
	press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(press:)];
	for (UIGestureRecognizer *recognizer in @[ _panner, _pincher, doubleTap, twoFingerTap, press ]) {
		recognizer.delegate = self;
		[self addGestureRecognizer:recognizer];
	}
	return self;
}

- (void)makeUserLayers
{
	UIImage *dot = dot_image(), *cone = cone_image();
	UIColor *blue = [UIColor colorWithRed:0 green:0.48 blue:1 alpha:1];

	_accuracy = [MapQuietLayer layer];
	_accuracy.backgroundColor = [blue colorWithAlphaComponent:0.14].CGColor;
	_accuracy.borderColor = [blue colorWithAlphaComponent:0.35].CGColor;
	_accuracy.borderWidth = 1;
	_cone = [MapQuietLayer layer];
	_cone.contents = (__bridge id)cone.CGImage;
	_cone.contentsScale = cone.scale;
	_cone.bounds = (CGRect){ CGPointZero, cone.size };
	_cone.hidden = YES;
	_dot = [MapQuietLayer layer];
	_dot.contents = (__bridge id)dot.CGImage;
	_dot.contentsScale = dot.scale;
	_dot.bounds = (CGRect){ CGPointZero, dot.size };
	[_userHost addSublayer:_accuracy];
	[_userHost addSublayer:_cone];
	[_userHost addSublayer:_dot];
	_userHost.hidden = YES;
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	_tileHost.frame = self.bounds;
	_userHost.frame = self.bounds;
	if (self.window != nil) {
		_pixel = self.window.screen.scale;
	}
	[self update];
}

#pragma mark where things are

- (double)zoom
{
	return _z;
}

- (CLLocationCoordinate2D)centerCoordinate
{
	return CLLocationCoordinate2DMake(latitude_at(_cy), longitude_at(_cx));
}

/* points per world unit */
- (double)ppw
{
	return TILE_POINTS * exp2(_z);
}

- (double)metresPerPoint
{
	return 2 * M_PI * EARTH_RADIUS * cos(latitude_at(_cy) * M_PI / 180) / [self ppw];
}

/* where a world point is on the screen; of its copies east and west, the one nearest the middle */
- (CGPoint)pointAtX:(double)x y:(double)y
{
	CGSize size = self.bounds.size;
	double ppw = [self ppw], dx = x - _cx;

	dx -= round(dx);
	return CGPointMake(size.width / 2 + dx * ppw, size.height / 2 + (y - _cy) * ppw);
}

- (void)worldAt:(CGPoint)p x:(double *)x y:(double *)y
{
	CGSize size = self.bounds.size;
	double ppw = [self ppw];

	*x = _cx + (p.x - size.width / 2) / ppw;
	*y = _cy + (p.y - size.height / 2) / ppw;
}

- (CGFloat)snap:(double)value
{
	return round(value * _pixel) / _pixel;
}

- (void)clamp
{
	double half;

	_z = isfinite(_z) ? fmin(MAP_MAX_ZOOM, fmax(MAP_MIN_ZOOM, _z)) : MAP_MIN_ZOOM;
	_cx = isfinite(_cx) ? _cx - floor(_cx) : 0.5;
	_cy = isfinite(_cy) ? _cy : 0.5;
	/* (north and south the world ends: the centre stays where the screen is full of it, or in the middle when the
	   world is less tall than the screen) */
	half = self.bounds.size.height / 2 / [self ppw];
	_cy = half >= 0.5 ? 0.5 : fmin(1 - half, fmax(half, _cy));
}

#pragma mark the tiles

/*
 * Everything on the screen, for the centre and zoom as they are now: the slots of the visible tiles at their places,
 * the wish list to MapTiles when the set of them changed, the dot and the pin. Called on every frame of a gesture.
 */
- (void)update
{
	CGSize size = self.bounds.size;
	NSMutableDictionary<NSNumber *, MapTileSlot *> *slots;
	BOOL changed;
	int level;
	long n, x0, x1, y0, y1;
	double ts, tx0, ty0;

	if (size.width < 1 || size.height < 1) {
		return;
	}
	[self clamp];
	/*
	 * The level nearest the zoom. While zooming the level stays (its tiles are scaled, and nothing new is fetched until
	 * the fingers let go) unless the zoom moves more than one level away from it: twice too big is blurry enough, and
	 * half too small already means four times as many tiles.
	 */
	level = (int)lround(_z);
	if (_zooming && _level >= MAP_MIN_ZOOM && fabs(_z - _level) <= 1) {
		level = _level;
	}
	level = MAX(MAP_MIN_ZOOM, MIN(MAP_MAX_ZOOM, level));
	changed = level != _level;
	_level = level;
	n = 1L << level;
	ts = TILE_POINTS * exp2(_z - level);
	tx0 = _cx * n - size.width / 2 / ts;
	ty0 = _cy * n - size.height / 2 / ts;
	x0 = (long)floor(tx0);
	x1 = (long)floor(tx0 + size.width / ts);
	y0 = MAX(0, (long)floor(ty0));
	y1 = MIN(n - 1, (long)floor(ty0 + size.height / ts));

	slots = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)MAX(0, (x1 - x0 + 1) * (y1 - y0 + 1))];
	for (long y = y0; y <= y1; y++) {
		for (long x = x0; x <= x1; x++) {
			NSNumber *key = @(tile_id(level, x, y));
			MapTileSlot *slot = _slots[key];
			BOOL fresh = slot == nil;
			/* (edges rounded to whole pixels, each from its own tile number, so that neighbours share them exactly
			   and no hairline of the background shows between them) */
			CGFloat left = [self snap:(x - tx0) * ts], right = [self snap:(x + 1 - tx0) * ts];
			CGFloat top = [self snap:(y - ty0) * ts], bottom = [self snap:(y + 1 - ty0) * ts];
			CGRect frame = CGRectMake(left, top, right - left, bottom - top);

			if (fresh) {
				slot = [self slotAt:level x:x y:y];
				changed = YES;
			} else {
				[_slots removeObjectForKey:key];
			}
			slots[key] = slot;
			if (!CGRectEqualToRect(frame, slot->frame)) {
				slot->frame = frame;
				slot->layer.frame = frame;
				if (!fresh) {
					[self placeChildren:slot];
				}
			}
			if (fresh) {
				[self fill:slot];
			}
		}
	}
	for (MapTileSlot *gone in _slots.objectEnumerator) {
		[self retire:gone];
		changed = YES;
	}
	_slots = slots;
	if (!_zooming && (changed || _wantAgain)) {
		_wantAgain = NO;
		[self request];
	}
	[self placeUser];
	[self placePin];
	[_delegate mapViewDidChange:self];
}

- (MapTileSlot *)slotAt:(int)z x:(long)x y:(long)y
{
	MapTileSlot *slot = [MapTileSlot new];
	long n = 1L << z;

	slot->z = z;
	slot->x = x;
	slot->y = y;
	slot->tile = tile_id(z, (x % n + n) % n, y);
	if (_spare.count > 0) {
		slot->layer = _spare.lastObject;
		[_spare removeLastObject];
	} else {
		slot->layer = [MapQuietLayer layer];
		slot->layer.edgeAntialiasingMask = 0;
	}
	[_tileHost addSublayer:slot->layer];
	return slot;
}

- (void)retire:(MapTileSlot *)slot
{
	for (int i = 0; i < 4; i++) {
		[slot->children[i] removeFromSuperlayer];
		slot->children[i] = nil;
	}
	[slot->layer removeFromSuperlayer];
	slot->layer.contents = nil;
	if (_spare.count < 100) {
		[_spare addObject:slot->layer];
	}
}

/* what a slot shows: its tile if it is here, else what stands in for it (see MapTileSlot) */
- (void)fill:(MapTileSlot *)slot
{
	CALayer *layer = slot->layer;
	int z = slot->z;
	long x = tile_x(slot->tile), y = slot->y;
	id image = [_tiles imageFor:slot->tile];
	BOOL any = NO;

	for (int i = 0; i < 4; i++) {
		[slot->children[i] removeFromSuperlayer];
		slot->children[i] = nil;
	}
	layer.contentsRect = CGRectMake(0, 0, 1, 1);
	layer.backgroundColor = _loadingColor.CGColor;
	layer.contents = image;
	slot->own = image != nil;
	if (slot->own) {
		return;
	}
	for (int d = 1; d <= FALLBACK_LEVELS && z - d >= 0; d++) {
		id above = [_tiles imageFor:tile_id(z - d, x >> d, y >> d)];

		if (above != nil) {
			double part = 1.0 / (1L << d);

			layer.contents = above;
			layer.contentsRect = CGRectMake((x & ((1L << d) - 1)) * part, (y & ((1L << d) - 1)) * part, part, part);
			any = YES;
			break;
		}
	}
	if (z < MAP_MAX_ZOOM) {
		for (int i = 0; i < 4; i++) {
			id below = [_tiles imageFor:tile_id(z + 1, 2 * x + (i & 1), 2 * y + (i >> 1))];

			if (below != nil) {
				MapQuietLayer *quarter = [MapQuietLayer layer];

				quarter.contents = below;
				quarter.edgeAntialiasingMask = 0;
				[layer addSublayer:quarter];
				slot->children[i] = quarter;
				any = YES;
			}
		}
		[self placeChildren:slot];
	}
	if (!any && [_tiles failed:slot->tile]) {
		layer.backgroundColor = _failedColor.CGColor;
	}
}

- (void)placeChildren:(MapTileSlot *)slot
{
	CGSize size = slot->frame.size;
	CGFloat mx = [self snap:size.width / 2], my = [self snap:size.height / 2];

	for (int i = 0; i < 4; i++) {
		BOOL right = i & 1, lower = i >> 1;

		slot->children[i].frame = CGRectMake(right ? mx : 0, lower ? my : 0, right ? size.width - mx : mx,
		    lower ? size.height - my : my);
	}
}

/* the tiles of the slots that do not have theirs, nearest the middle of the screen first */
- (void)request
{
	CGSize size = self.bounds.size;
	CGPoint middle = CGPointMake(size.width / 2, size.height / 2);
	NSMutableArray<MapTileSlot *> *missing = [NSMutableArray array];
	NSMutableOrderedSet<NSNumber *> *wanted = [NSMutableOrderedSet orderedSet];

	for (MapTileSlot *slot in _slots.objectEnumerator) {
		if (!slot->own) {
			[missing addObject:slot];
		}
	}
	[missing sortUsingComparator:^NSComparisonResult(MapTileSlot *a, MapTileSlot *b) {
		double da = hypot(CGRectGetMidX(a->frame) - middle.x, CGRectGetMidY(a->frame) - middle.y);
		double db = hypot(CGRectGetMidX(b->frame) - middle.x, CGRectGetMidY(b->frame) - middle.y);

		return da < db ? NSOrderedAscending : da > db ? NSOrderedDescending : NSOrderedSame;
	}];
	for (MapTileSlot *slot in missing) {
		[wanted addObject:@(slot->tile)];
	}
	[_tiles want:wanted.array];
}

- (void)tileArrived:(uint64_t)tile
{
	int z = tile_z(tile);

	/* (its own slots; and, if it is of another level, any slot still waiting, which it may stand in for) */
	for (MapTileSlot *slot in _slots.objectEnumerator) {
		if (slot->tile == tile || (!slot->own && slot->z != z)) {
			[self fill:slot];
		}
	}
}

- (void)tileFailed:(uint64_t)tile
{
	for (MapTileSlot *slot in _slots.objectEnumerator) {
		if (slot->tile == tile && !slot->own) {
			[self fill:slot];
		}
	}
}

- (void)tilesMayBeRetried
{
	_wantAgain = YES;
	if (!_zooming) {
		_wantAgain = NO;
		[self request];
	}
}

- (void)forgetTiles
{
	[_tiles forget];
}

#pragma mark the location and the pin

- (void)setUserLocation:(CLLocation *)location
{
	_userLocation = location;
	if (location != nil) {
		_ux = world_x(location.coordinate.longitude);
		_uy = mercator_y(location.coordinate.latitude);
	}
	[self placeUser];
}

- (void)setHeading:(double)heading
{
	_heading = heading;
	[self placeUser];
}

- (void)placeUser
{
	CLLocation *where = _userLocation;
	double radius;
	CGPoint p;

	_userHost.hidden = where == nil;
	if (where == nil) {
		return;
	}
	p = [self pointAtX:_ux y:_uy];
	/* (the accuracy is in metres; a point of the map covers cos(latitude) times fewer of them than at the equator) */
	radius = where.horizontalAccuracy * [self ppw] / (2 * M_PI * EARTH_RADIUS * cos(where.coordinate.latitude * M_PI / 180));
	radius = isfinite(radius) && radius > 0 ? fmin(radius, 30000) : 0;
	_accuracy.hidden = radius < 13;
	_accuracy.bounds = CGRectMake(0, 0, 2 * radius, 2 * radius);
	_accuracy.cornerRadius = radius;
	_accuracy.position = p;
	_dot.position = p;
	_cone.position = p;
	_cone.hidden = _heading < 0;
	_cone.affineTransform = CGAffineTransformMakeRotation(_heading * M_PI / 180);
}

- (void)showPinAt:(CLLocationCoordinate2D)where title:(NSString *)title
{
	[self removePin];
	_pinWhere = where;
	_pinX = world_x(where.longitude);
	_pinY = mercator_y(where.latitude);
	_pin = [[UIImageView alloc] initWithImage:pin_image()];
	_callout = [self calloutFor:title];
	[self addSubview:_pin];
	[self addSubview:_callout];
	_hasPin = YES;
	[self placePin];
}

- (void)removePin
{
	[_pin removeFromSuperview];
	[_callout removeFromSuperview];
	_pin = nil;
	_callout = nil;
	_copy = nil;
	_hasPin = NO;
}

- (UIView *)calloutFor:(NSString *)title
{
	UIView *box = [UIView new];
	UILabel *name = [UILabel new], *where = [UILabel new];
	UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
	UIStackView *labels, *row;
	CGSize size;

	name.text = title;
	name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
	name.numberOfLines = 2;
	name.preferredMaxLayoutWidth = 200;
	[name.widthAnchor constraintLessThanOrEqualToConstant:200].active = YES;
	where.text = coordinate_text(_pinWhere);
	where.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
	where.textColor = UIColor.secondaryLabelColor;
	_copy = [UIButton buttonWithType:UIButtonTypeSystem];
	_copy.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
	[_copy setTitle:@"Copy" forState:UIControlStateNormal];
	[_copy addTarget:self action:@selector(copyPin) forControlEvents:UIControlEventTouchUpInside];
	/* (wide enough for "Copied" too, so that nothing moves when it says so) */
	[_copy.widthAnchor constraintEqualToConstant:58].active = YES;
	close.tintColor = UIColor.secondaryLabelColor;
	close.titleLabel.font = [UIFont systemFontOfSize:15];
	close.accessibilityLabel = @"Remove pin";
	[close setTitle:@"✕" forState:UIControlStateNormal];
	[close addTarget:self action:@selector(removePin) forControlEvents:UIControlEventTouchUpInside];
	[close.widthAnchor constraintEqualToConstant:28].active = YES;
	labels = [[UIStackView alloc] initWithArrangedSubviews:@[ name, where ]];
	labels.axis = UILayoutConstraintAxisVertical;
	labels.spacing = 2;
	row = [[UIStackView alloc] initWithArrangedSubviews:@[ labels, _copy, close ]];
	row.axis = UILayoutConstraintAxisHorizontal;
	row.alignment = UIStackViewAlignmentCenter;
	row.spacing = 8;
	row.layoutMargins = UIEdgeInsetsMake(8, 12, 8, 6);
	row.layoutMarginsRelativeArrangement = YES;
	size = [row systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
	row.frame = CGRectMake(0, 0, ceil(size.width), ceil(size.height));
	box.bounds = row.frame;
	box.backgroundColor = UIColor.systemBackgroundColor;
	box.layer.cornerRadius = 10;
	box.layer.borderWidth = 1 / _pixel;
	box.layer.borderColor = UIColor.separatorColor.CGColor;
	[box addSubview:row];
	return box;
}

- (void)copyPin
{
	UIButton *button = _copy;

	UIPasteboard.generalPasteboard.string = coordinate_text(_pinWhere);
	[button setTitle:@"Copied" forState:UIControlStateNormal];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[button setTitle:@"Copy" forState:UIControlStateNormal];
	});
}

- (void)placePin
{
	CGSize pin, box;
	CGPoint p;

	if (!_hasPin) {
		return;
	}
	p = [self pointAtX:_pinX y:_pinY];
	pin = _pin.bounds.size;
	box = _callout.bounds.size;
	_pin.frame = CGRectMake([self snap:p.x - pin.width / 2], [self snap:p.y - pin.height], pin.width, pin.height);
	_callout.frame = CGRectMake([self snap:p.x - box.width / 2], [self snap:p.y - pin.height - box.height - 4], box.width,
	    box.height);
}

#pragma mark moving

- (void)setCenterCoordinate:(CLLocationCoordinate2D)center zoom:(double)zoom animated:(BOOL)animated
{
	CGSize size = self.bounds.size;
	double x, y, dx, dy, ppw = [self ppw];

	/* (fingers on the map win over whatever wants it elsewhere; so does a tap's zoom, a third of a second long, which
	   a location coming in while following would otherwise stop half way) */
	if (_pinching || (_motion == MOTION_ANIMATION && _anchored) || !CLLocationCoordinate2DIsValid(center) ||
	    !isfinite(zoom)) {
		return;
	}
	x = world_x(center.longitude);
	y = mercator_y(center.latitude);
	zoom = fmin(MAP_MAX_ZOOM, fmax(MAP_MIN_ZOOM, zoom));
	dx = (x - _cx - round(x - _cx)) * ppw;
	dy = (y - _cy) * ppw;
	[self stopMotion];
	/* (animated only when it is near: a long flight would show screenfuls of tiles that are not there) */
	if (animated && self.window != nil && fabs(zoom - _z) <= 2 && hypot(dx, dy) <= 2 * fmax(size.width, size.height)) {
		[self animateToX:x y:y zoom:zoom anchored:NO];
		return;
	}
	_cx = x;
	_cy = y;
	_z = zoom;
	[self update];
}

- (void)moveBy:(CGPoint)move
{
	double ppw = [self ppw];

	_cx -= move.x / ppw;
	_cy -= move.y / ppw;
	[self update];
}

/* a new zoom about a point: the world point that was at `from` is now at `to` (where the fingers have gone) */
- (void)zoomTo:(double)zoom from:(CGPoint)from to:(CGPoint)to
{
	CGSize size = self.bounds.size;
	double ax, ay, ppw;

	if (_followsUser && _userLocation != nil) {
		from = to = [self pointAtX:_ux y:_uy];
	}
	[self worldAt:from x:&ax y:&ay];
	_z = fmin(MAP_MAX_ZOOM, fmax(MAP_MIN_ZOOM, zoom));
	ppw = [self ppw];
	_cx = ax - (to.x - size.width / 2) / ppw;
	_cy = ay - (to.y - size.height / 2) / ppw;
	[self update];
}

/* the zooming is over: the nearest level is shown, and its tiles fetched */
- (void)endZooming
{
	_zooming = NO;
	_wantAgain = YES;
	[self update];
}

- (void)animateToX:(double)x y:(double)y zoom:(double)zoom anchored:(BOOL)anchored
{
	_fromX = _cx;
	_fromY = _cy;
	_fromZ = _z;
	_toX = _cx + (x - _cx - round(x - _cx));
	_toY = y;
	_toZ = zoom;
	_anchored = anchored;
	_zooming = fabs(zoom - _z) > 1e-9;
	_start = CACurrentMediaTime();
	_duration = 0.3;
	_motion = MOTION_ANIMATION;
	[self startLink];
}

- (void)fling:(CGPoint)velocity
{
	[self stopMotion];
	_velocity = velocity;
	_last = CACurrentMediaTime();
	_motion = MOTION_FLING;
	[self startLink];
}

- (void)startLink
{
	float most = (float)UIScreen.mainScreen.maximumFramesPerSecond;

	if (_link != nil) {
		return;
	}
	/* (as fast as the screen goes: 120 Hz where it can; it only runs while something moves by itself) */
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	_link.preferredFrameRateRange = CAFrameRateRangeMake(fminf(60, most), most, most);
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stopMotion
{
	BOOL animating = _motion == MOTION_ANIMATION;

	_motion = MOTION_NONE;
	[_link invalidate];
	_link = nil;
	if (animating && !_pinching) {
		[self endZooming];
	}
}

- (void)tick:(CADisplayLink *)link
{
	CFTimeInterval now = CACurrentMediaTime();

	if (_motion == MOTION_FLING) {
		/* UIScrollView's own deceleration: the speed is 0.998 of what it was a millisecond before */
		double dt = fmin(now - _last, 1.0 / 30), keep = pow(0.998, dt * 1000);

		_last = now;
		[self moveBy:CGPointMake(_velocity.x * dt, _velocity.y * dt)];
		_velocity.x *= keep;
		_velocity.y *= keep;
		if (hypot(_velocity.x, _velocity.y) < 15) {
			[self stopMotion];
		}
	} else if (_motion == MOTION_ANIMATION) {
		double t = fmin(1, (now - _start) / _duration), e = 1 - pow(1 - t, 3);

		_z = _fromZ + (_toZ - _fromZ) * e;
		if (_anchored) {
			CGSize size = self.bounds.size;
			double ppw = [self ppw];

			_cx = _anchorX - (_anchorAt.x - size.width / 2) / ppw;
			_cy = _anchorY - (_anchorAt.y - size.height / 2) / ppw;
		} else {
			_cx = _fromX + (_toX - _fromX) * e;
			_cy = _fromY + (_toY - _fromY) * e;
		}
		if (t >= 1) {
			[self stopMotion];
		} else {
			[self update];
		}
	} else {
		[self stopMotion];
	}
}

#pragma mark the gestures

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	/* (a finger on a map that is still gliding stops it there) */
	if (_motion == MOTION_FLING) {
		[self stopMotion];
	}
	[super touchesBegan:touches withEvent:event];
}

- (void)pan:(UIPanGestureRecognizer *)pan
{
	CGPoint move = [pan translationInView:self], velocity;

	[pan setTranslation:CGPointZero inView:self];
	switch (pan.state) {
	case UIGestureRecognizerStateBegan:
		[self stopMotion];
		_dragTold = NO;
		__attribute__((fallthrough));
	case UIGestureRecognizerStateChanged:
		/* (two fingers pinching: the pinch moves the map, with where they are) */
		if (_pinching && _pincher.numberOfTouches >= 2) {
			return;
		}
		if (!_dragTold) {
			_dragTold = YES;
			[_delegate mapViewWillMove:self dragged:YES];
		}
		[self moveBy:move];
		break;
	case UIGestureRecognizerStateEnded:
		velocity = [pan velocityInView:self];
		/* (not just after a pinch: lifting its two fingers is no throw) */
		if (!_pinching && CACurrentMediaTime() - _pinchEnded > 0.2 && hypot(velocity.x, velocity.y) > 200) {
			[self fling:velocity];
		}
		break;
	default:
		break;
	}
}

- (void)pinch:(UIPinchGestureRecognizer *)pinch
{
	BOOL first = pinch.state == UIGestureRecognizerStateBegan;
	double zoom;
	CGPoint at;

	switch (pinch.state) {
	case UIGestureRecognizerStateBegan:
		[self stopMotion];
		_pinching = YES;
		_zooming = YES;
		_pinchAtKnown = NO;
		[_delegate mapViewWillMove:self dragged:NO];
		__attribute__((fallthrough));
	case UIGestureRecognizerStateChanged:
		zoom = _z + log2(fmax(pinch.scale, 1e-3));
		pinch.scale = 1;
		/* (one finger lifted: nothing to zoom about, and the middle jumped to the other one; when a second finger
		   comes back, its first report only says where the middle is now) */
		if (pinch.numberOfTouches < 2) {
			_pinchAtKnown = NO;
			return;
		}
		at = [pinch locationInView:self];
		if (!_pinchAtKnown) {
			_pinchAt = at;
			_pinchAtKnown = YES;
			if (!first) {
				return;
			}
		}
		[self zoomTo:zoom from:_pinchAt to:at];
		_pinchAt = at;
		break;
	case UIGestureRecognizerStateEnded:
	case UIGestureRecognizerStateCancelled:
	case UIGestureRecognizerStateFailed:
		_pinching = NO;
		_pinchEnded = CACurrentMediaTime();
		[self endZooming];
		break;
	default:
		break;
	}
}

- (void)doubleTap:(UITapGestureRecognizer *)tap
{
	[self zoomBy:1 at:[tap locationInView:self]];
}

- (void)twoFingerTap:(UITapGestureRecognizer *)tap
{
	[self zoomBy:-1 at:[tap locationInView:self]];
}

/* a level in or out, animated, about the point tapped (to a whole level: its tiles are then shown at their size) */
- (void)zoomBy:(double)step at:(CGPoint)at
{
	double zoom = fmin(MAP_MAX_ZOOM, fmax(MAP_MIN_ZOOM, round(_z + step)));

	[_delegate mapViewWillMove:self dragged:NO];
	[self stopMotion];
	if (_followsUser && _userLocation != nil) {
		at = [self pointAtX:_ux y:_uy];
	}
	[self worldAt:at x:&_anchorX y:&_anchorY];
	_anchorAt = at;
	[self animateToX:_cx y:_cy zoom:zoom anchored:YES];
}

- (void)press:(UILongPressGestureRecognizer *)press
{
	double x, y;

	if (press.state != UIGestureRecognizerStateBegan) {
		return;
	}
	[self worldAt:[press locationInView:self] x:&x y:&y];
	if (y < 0 || y > 1) {
		return;
	}
	[self showPinAt:CLLocationCoordinate2DMake(latitude_at(y), longitude_at(x)) title:@"Dropped pin"];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch
{
	/* (the callout's buttons are the callout's, not the map's) */
	return _callout == nil || ![touch.view isDescendantOfView:_callout];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)one
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other
{
	return (one == _panner && other == _pincher) || (one == _pincher && other == _panner);
}

@end
