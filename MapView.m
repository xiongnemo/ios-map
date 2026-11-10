// MapView.m: the camera, which tiles a frame draws and where (MapSource has them, the renderer draws them), the labels
// (MapLabels), the gestures, the location's dot and cone, and the pin. See MapView.h.
#import <QuartzCore/QuartzCore.h>

#import "MapLabels.h"
#import "MapRenderer.h"
#import "MapView.h"

#define TILE_POINTS     256.0           /* a tile's size at its own zoom, as OpenStreetMap counts zooms */
#define EARTH_RADIUS    6378137.0       /* metres: Web Mercator's sphere, the size of WGS 84's equator */
#define MAX_LATITUDE    85.0511287798   /* where Web Mercator's square world ends, north and south */
#define FALLBACK_LEVELS 6               /* how many levels up a missing tile looks for one to stand in for it */
#define UPLOADS         4               /* tiles given to the GPU in one frame, at most (each a few hundred KB) */
#define MAX_SLOTS       160             /* tiles of the screen, at most (a frame has at most four pieces for each) */
#define EDGE            0.02f           /* tile units a piece's clip reaches past its edges: no hairline between them */

/*
 * Web Mercator as a square of side 1: x from 0 at 180° west to 1 at 180° east, y from 0 at the top (85.05° north) to 1
 * at the bottom. A level z cuts it into 2^z by 2^z tiles.
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

NSString *
coordinate_text(CLLocationCoordinate2D where)
{
	return [NSString stringWithFormat:@"%.5f, %.5f", where.latitude, where.longitude];
}

static long
floor_div(long a, long b)
{
	long q = a / b;

	return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}

static void
premultiplied(uint32_t rgba, float *out)
{
	float a = (rgba & 0xff) / 255.0f;

	out[0] = ((rgba >> 24) & 0xff) / 255.0f * a;
	out[1] = ((rgba >> 16) & 0xff) / 255.0f * a;
	out[2] = ((rgba >> 8) & 0xff) / 255.0f * a;
	out[3] = a;
}

/* A layer that never animates by itself: the dot is where the map put it now, not a quarter of a second later. */
@interface MapQuietLayer : CALayer
@end

@implementation MapQuietLayer

- (id<CAAction>)actionForKey:(NSString *)event
{
	return nil;
}

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

/* a tile of the screen: its level, x (as laid out: east or west of the world's first copy) and y */
struct slot {
	int z;
	long x, y;
	double distance;                /* of its middle from the screen's, in points */
};

static int
by_distance(const void *a, const void *b)
{
	const struct slot *p = a, *q = b;

	return p->distance < q->distance ? -1 : p->distance > q->distance ? 1 : 0;
}

@interface MapView () <UIGestureRecognizerDelegate, MapSourceDelegate>
@end

@implementation MapView {
	MapSource *_source;
	id<MapRenderer> _renderer;
	NSUInteger _generation;         /* counts the renderers made: a tile's GPU copy is of the one it says */
	MapLabels *_labels;
	CALayer *_userHost;
	MapQuietLayer *_accuracy, *_cone, *_dot;
	UILabel *_rate;
	CGFloat _pixel;                 /* the screen's pixels per point */

	double _cx, _cy;                /* the centre, in world units (x wraps round) */
	double _z;                      /* the zoom: fractional, MAP_MIN_ZOOM to MAP_MAX_ZOOM */
	double _turn;                   /* the bearing, radians */
	int _level;                     /* the level whose tiles are shown */
	BOOL _zooming;                  /* a pinch or a zoom animation: the level stays, and nothing is fetched */
	BOOL _wantAgain;                /* the tiles wanted are to be sent again, even if the screen wants the same ones */
	NSArray<NSNumber *> *_wanted;
	double _ux, _uy;                /* the user's location, in world units */
	BOOL _lastDark;

	struct slot _slots[MAX_SLOTS];
	unsigned _slotCount;
	struct map_piece _pieces[4 * MAX_SLOTS];
	unsigned _pieceCount;
	NSMutableArray *_drawn;         /* the tiles of the frame's pieces, held while it is drawn */
	unsigned _uploads;

	CADisplayLink *_link;
	BOOL _dirty;
	unsigned _idle;
	double _shownX, _shownY, _shownZ, _shownTurn;   /* what the overlays and the delegate were last told */
	unsigned _frames;
	CFTimeInterval _rateSince, _frameTime, _worstFrame, _lastFrame;
	CFTimeInterval _spentTiles, _spentLabels, _spentDraw;   /* the frames' time, part by part (the self-test's) */

	UIPanGestureRecognizer *_panner;
	UIPinchGestureRecognizer *_pincher;
	UIRotationGestureRecognizer *_rotator;
	BOOL _pinching, _dragTold, _pinchAtKnown, _turning;
	CGPoint _pinchAt;
	double _rotationHeld;           /* a turn of the fingers too small yet to turn the map (a pinch turns a little) */
	CFTimeInterval _pinchEnded;

	int _motion;
	CGPoint _velocity;
	CFTimeInterval _last, _start, _duration;
	double _fromX, _fromY, _fromZ, _fromTurn, _toX, _toY, _toZ, _toTurn;
	BOOL _anchored;
	double _anchorX, _anchorY;
	CGPoint _anchorAt;

	BOOL _hasPin;
	double _pinX, _pinY;
	CLLocationCoordinate2D _pinWhere;
	UIImageView *_pin;
	UIView *_callout;
	UIButton *_copy;

	void (^_test)(void);            /* the self-test's step, run after each frame */
}

- (instancetype)initWithFrame:(CGRect)frame
{
	UITapGestureRecognizer *doubleTap, *twoFingerTap;
	UILongPressGestureRecognizer *press;

	self = [super initWithFrame:frame];
	if (self == nil) {
		return nil;
	}
	_pixel = UIScreen.mainScreen.nativeScale;
	self.clipsToBounds = YES;
	self.multipleTouchEnabled = YES;
	self.backgroundColor = UIColor.clearColor;
	_source = [MapSource new];
	_source.delegate = self;
	_labels = [MapLabels new];
	_drawn = [NSMutableArray array];
	_userHost = [MapQuietLayer layer];
	[self.layer addSublayer:_userHost];
	[self makeUserLayers];
	_cx = 0.5;
	_cy = 0.5;
	_z = MAP_MIN_ZOOM;
	_level = -1;
	_heading = -1;
	_shownZ = -1;
	_samples = 4;

	_panner = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
	_pincher = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
	_rotator = [[UIRotationGestureRecognizer alloc] initWithTarget:self action:@selector(rotate:)];
	doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
	doubleTap.numberOfTapsRequired = 2;
	twoFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerTap:)];
	twoFingerTap.numberOfTouchesRequired = 2;
	press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(press:)];
	for (UIGestureRecognizer *recognizer in @[ _panner, _pincher, _rotator, doubleTap, twoFingerTap, press ]) {
		recognizer.delegate = self;
		[self addGestureRecognizer:recognizer];
	}
	return self;
}

- (void)dealloc
{
	[_link invalidate];
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
	if (self.window != nil) {
		_pixel = self.window.screen.nativeScale;
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_renderer.layer.frame = self.bounds;
	_renderer.layer.contentsScale = _pixel;
	_userHost.frame = self.bounds;
	[CATransaction commit];
	if (_rate != nil) {
		_rate.frame = CGRectMake(self.safeAreaInsets.left + 8, self.safeAreaInsets.top + 70, 210, 34);
	}
	[self setNeedsFrame];
}

- (void)didMoveToWindow
{
	[super didMoveToWindow];
	if (self.window != nil) {
		[self setNeedsFrame];
	} else {
		[_link invalidate];
		_link = nil;
	}
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous
{
	[super traitCollectionDidChange:previous];
	[self setNeedsFrame];
}

#pragma mark the renderer and the look

- (void)setRendererKind:(MapRendererKind)kind
{
	if (kind == _rendererKind && _renderer != nil) {
		return;
	}
	_rendererKind = kind;
	if (_renderer != nil) {
		[self makeRenderer];
	}
}

- (void)setSamples:(unsigned)samples
{
	samples = samples > 1 ? 4 : 1;
	if (samples != _samples) {
		_samples = samples;
		if (_renderer != nil) {
			[self makeRenderer];
		}
	}
}

- (NSString *)rendererName
{
	return _renderer.name;
}

/* the renderer the settings say; the tiles' GPU copies of the one before are let go of, the new one makes its own */
- (void)makeRenderer
{
	NSString *why = nil;
	id<MapRenderer> made = nil, old = _renderer;
	NSUInteger generation;

	[_renderer.layer removeFromSuperlayer];
	_renderer = nil;
	/* (the old one let go of a turn of the main queue later, not now: the K40 port's OpenGL ES before hk 49d3826 read
	   a context in a block its last present had queued on the main queue, and faulted if the context was gone) */
	if (old != nil) {
		dispatch_async(dispatch_get_main_queue(), ^{
			(void)old;
		});
	}
	generation = ++_generation;
	[_source forEachTile:^(MapTile *tile) {
		tile.gpu = nil;
		tile.gpuOf = 0;
	}];
	if (_rendererKind == MapRendererKindMetal) {
		made = map_renderer_metal(_samples, &why);
		if (made == nil) {
			NSLog(@"mapcheck: no Metal renderer: %@; OpenGL ES instead", why);
		}
	}
	if (made == nil) {
		made = map_renderer_gl(_samples, &why);
		if (made == nil) {
			NSLog(@"mapcheck: no OpenGL ES renderer: %@", why);
			return;
		}
	}
	_renderer = made;
	(void)generation;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	made.layer.frame = self.bounds;
	made.layer.contentsScale = _pixel;
	[self.layer insertSublayer:made.layer atIndex:0];
	[CATransaction commit];
	[_labels forgetAtlas];
	NSLog(@"mapcheck: renderer %@", made.name);
	[self setNeedsFrame];
}

- (BOOL)dark
{
	if (_style == MapStyleSystem) {
		return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
	}
	return _style == MapStyleDark;
}

- (void)setStyle:(MapStyleChoice)style
{
	_style = style;
	[self setNeedsFrame];
}

- (void)setLabelLanguage:(enum style_language)language
{
	if (language != _labels.language) {
		_labels.language = language;
		[_labels forgetAtlas];
	}
	_source.language = language;
	_wantAgain = YES;
	[self setNeedsFrame];
}

- (enum style_language)labelLanguage
{
	return _source.language;
}

- (void)setCoveredRects:(NSArray<NSValue *> *)rects
{
	if (![rects isEqualToArray:_coveredRects]) {
		_coveredRects = [rects copy];
		[self setNeedsFrame];
	}
}

- (void)setShowsFrameRate:(BOOL)shows
{
	_showsFrameRate = shows;
	if (shows && _rate == nil) {
		_rate = [UILabel new];
		_rate.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
		_rate.numberOfLines = 2;
		_rate.layer.cornerRadius = 5;
		_rate.layer.masksToBounds = YES;
		_rate.userInteractionEnabled = NO;
		[self addSubview:_rate];
		[self setNeedsLayout];
	}
	_rate.hidden = !shows;
	_rateSince = 0;
}

#pragma mark where things are

- (double)zoom
{
	return _z;
}

- (double)bearing
{
	double degrees = fmod(_turn * 180 / M_PI, 360);

	return degrees < 0 ? degrees + 360 : degrees;
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
	double ppw = [self ppw], dx = x - _cx, sx, sy, c = cos(_turn), s = sin(_turn);

	dx -= round(dx);
	sx = dx * ppw;
	sy = (y - _cy) * ppw;
	/* (the world turned by minus the bearing: what is east is up when the top of the screen points east) */
	return CGPointMake(size.width / 2 + c * sx + s * sy, size.height / 2 - s * sx + c * sy);
}

- (void)worldAt:(CGPoint)p x:(double *)x y:(double *)y
{
	CGSize size = self.bounds.size;
	double ppw = [self ppw], dx = p.x - size.width / 2, dy = p.y - size.height / 2, c = cos(_turn), s = sin(_turn);

	*x = _cx + (c * dx - s * dy) / ppw;
	*y = _cy + (s * dx + c * dy) / ppw;
}

- (void)clamp
{
	CGSize size = self.bounds.size;
	double half;

	_z = isfinite(_z) ? fmin(MAP_MAX_ZOOM, fmax(MAP_MIN_ZOOM, _z)) : MAP_MIN_ZOOM;
	_cx = isfinite(_cx) ? _cx - floor(_cx) : 0.5;
	_cy = isfinite(_cy) ? _cy : 0.5;
	_turn = isfinite(_turn) ? remainder(_turn, 2 * M_PI) : 0;
	/* (north and south the world ends: the centre stays where the screen is full of it, or in the middle when the
	   world is less tall than the screen -- turned, the screen's height is partly its width) */
	half = (fabs(cos(_turn)) * size.height + fabs(sin(_turn)) * size.width) / 2 / [self ppw];
	_cy = half >= 0.5 ? 0.5 : fmin(1 - half, fmax(half, _cy));
}

#pragma mark frames

- (void)setNeedsFrame
{
	_dirty = YES;
	[self startLink];
}

- (void)startLink
{
	float most = (float)UIScreen.mainScreen.maximumFramesPerSecond;

	if (_link != nil || self.window == nil) {
		return;
	}
	/* (as fast as the screen goes, 120 Hz where it can; it runs only while something changes, and stops when
	   nothing does: a map that stands still is not drawn again) */
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	if (@available(iOS 15.0, *)) {
		_link.preferredFrameRateRange = CAFrameRateRangeMake(fminf(60, most), most, most);
	}
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	_idle = 0;
}

- (void)tick:(CADisplayLink *)link
{
	BOOL moving = [self advance:CACurrentMediaTime()];

	if (_dirty || moving) {
		_dirty = NO;
		_idle = 0;
		[self drawFrame];
	} else if (++_idle > 3) {
		/* (the link holds the view: let go of it, made again when something changes) */
		[_link invalidate];
		_link = nil;
	}
	if (_test != nil) {
		void (^step)(void) = _test;

		step();
	}
}

/* the tile of the screen's slot, made and on the GPU; nil if it is not (yet) */
- (MapTile *)ready:(uint64_t)key
{
	MapTile *tile = [_source tileFor:key];

	if (tile == nil) {
		return nil;
	}
	if (tile.gpu == nil || tile.gpuOf != _generation) {
		if (_uploads == 0) {
			_dirty = YES;
			return nil;
		}
		_uploads--;
		tile.gpu = [_renderer makeTile:tile.mesh];
		tile.gpuOf = _generation;
		if (tile.gpu == nil) {
			return nil;
		}
	}
	return tile;
}

/* the piece of tile `tile` (of level z, at x, y as laid out) shown in `clip` of its units */
- (void)addPiece:(MapTile *)tile z:(int)z x:(long)x y:(long)y clip:(const float *)clip
{
	CGSize size = self.bounds.size;
	double ppw = [self ppw], n = exp2(z), k = ppw / (n * 4096), c = cos(_turn), s = sin(_turn);
	double ox = (x / n - _cx) * ppw, oy = (y / n - _cy) * ppw;
	struct map_piece *piece;
	CGAffineTransform t;

	if (_pieceCount == sizeof(_pieces) / sizeof(_pieces[0])) {
		return;
	}
	/* tile units to screen points: the tile's corner at its place, the world turned by minus the bearing */
	t.a = c * k;
	t.b = -s * k;
	t.c = s * k;
	t.d = c * k;
	t.tx = size.width / 2 + c * ox + s * oy;
	t.ty = size.height / 2 - s * ox + c * oy;
	piece = &_pieces[_pieceCount++];
	piece->tile = tile.gpu;
	piece->matrix[0] = (float)(t.a * 2 / size.width);
	piece->matrix[1] = (float)(-t.b * 2 / size.height);
	piece->matrix[2] = (float)(t.c * 2 / size.width);
	piece->matrix[3] = (float)(-t.d * 2 / size.height);
	piece->matrix[4] = (float)((t.tx - size.width / 2) * 2 / size.width);
	piece->matrix[5] = (float)(-(t.ty - size.height / 2) * 2 / size.height);
	memcpy(piece->clip, clip, sizeof(piece->clip));
	[_drawn addObject:tile];
	[_labels addTile:tile transform:t clip:clip];
}

/* the part of an ancestor's units (d levels up, at ax, ay) that is (x0, y0, x1, y1) of the slot's (at x, y) */
static void
clip_in_ancestor(long x, long y, long ax, long ay, int d, const float *slot, float *clip)
{
	double part = 1.0 / (1L << d), fx = (double)(x - (ax << d)), fy = (double)(y - (ay << d));

	clip[0] = (float)((fx * 4096 + slot[0]) * part) - EDGE;
	clip[1] = (float)((fy * 4096 + slot[1]) * part) - EDGE;
	clip[2] = (float)((fx * 4096 + slot[2]) * part) + EDGE;
	clip[3] = (float)((fy * 4096 + slot[3]) * part) + EDGE;
}

/* the level to show at a style zoom (MapLibre's: a tile is 512 points across at its own) */
- (int)levelFor:(double)styleZoom
{
	int level = (int)floor(styleZoom + 1e-9);

	level = MAX(0, MIN(MAP_DATA_ZOOM, level));
	/* (while zooming the level stays, its tiles scaled, unless the zoom goes far from it: half too small is four
	   times the tiles, four times too big is short of detail) */
	if (_zooming && _level >= 0 && styleZoom >= _level - 1 && styleZoom < _level + 2) {
		level = _level;
	}
	return level;
}

/* the screen's tiles at `level`: those whose square the turned screen overlaps, nearest its middle first */
- (void)findSlots:(int)level
{
	CGSize size = self.bounds.size;
	const CGPoint corners[4] = { { 0, 0 }, { size.width, 0 }, { 0, size.height }, { size.width, size.height } };
	double minx = INFINITY, maxx = -INFINITY, miny = INFINITY, maxy = -INFINITY, n = exp2(level);
	long x0, x1, y0, y1;

	for (int i = 0; i < 4; i++) {
		double x, y;

		[self worldAt:corners[i] x:&x y:&y];
		minx = fmin(minx, x);
		maxx = fmax(maxx, x);
		miny = fmin(miny, y);
		maxy = fmax(maxy, y);
	}
	x0 = (long)floor(minx * n);
	x1 = (long)floor(maxx * n);
	y0 = MAX(0, (long)floor(miny * n));
	y1 = MIN((long)n - 1, (long)floor(maxy * n));
	_slotCount = 0;
	for (long y = y0; y <= y1; y++) {
		for (long x = x0; x <= x1 && _slotCount < MAX_SLOTS; x++) {
			CGPoint p[4] = {
				[self pointAtX:x / n y:y / n], [self pointAtX:(x + 1) / n y:y / n],
				[self pointAtX:x / n y:(y + 1) / n], [self pointAtX:(x + 1) / n y:(y + 1) / n],
			};
			double left = INFINITY, right = -INFINITY, top = INFINITY, bottom = -INFINITY, sx = 0, sy = 0;

			/* (pointAtX takes each corner to the copy of the world nearest the middle, which for a tile on the
			   screen is the copy it is laid out in) */
			for (int i = 0; i < 4; i++) {
				left = fmin(left, p[i].x);
				right = fmax(right, p[i].x);
				top = fmin(top, p[i].y);
				bottom = fmax(bottom, p[i].y);
				sx += p[i].x / 4;
				sy += p[i].y / 4;
			}
			/* (the tile's square against the screen's sides; the screen against the tile's came with the range) */
			if (right < 0 || bottom < 0 || left > size.width || top > size.height) {
				continue;
			}
			_slots[_slotCount++] = (struct slot){ level, x, y,
			    hypot(sx - size.width / 2, sy - size.height / 2) };
		}
	}
	qsort(_slots, _slotCount, sizeof(struct slot), by_distance);
}

- (void)drawFrame
{
	CGSize size = self.bounds.size;
	CFTimeInterval began = CACurrentMediaTime();
	const float full[4] = { -EDGE, -EDGE, 4096 + EDGE, 4096 + EDGE };
	double styleZoom, c, s;
	BOOL dark;
	int level;
	long n;
	NSMutableArray<NSNumber *> *wanted;
	struct map_frame frame;
	unsigned labelVertices = 0;

	if (size.width < 1 || size.height < 1 || self.window == nil) {
		return;
	}
	if (_renderer == nil) {
		[self makeRenderer];
		if (_renderer == nil) {
			return;
		}
	}
	[self clamp];
	styleZoom = _z - 1;
	dark = self.dark;
	level = [self levelFor:styleZoom];
	if (level != _level) {
		_level = level;
	}
	n = 1L << level;
	[self findSlots:level];
	[_drawn removeAllObjects];
	[_labels beginFrame:size scale:_pixel zoom:styleZoom bearing:_turn dark:dark covered:_coveredRects];
	_pieceCount = 0;
	_uploads = UPLOADS;
	wanted = [NSMutableArray arrayWithCapacity:_slotCount];
	for (unsigned i = 0; i < _slotCount; i++) {
		const struct slot *slot = &_slots[i];
		long wx = (slot->x % n + n) % n;
		uint64_t key = tile_id(level, wx, slot->y);
		MapTile *own = [self ready:key], *child[4] = { nil, nil, nil, nil }, *up = nil;
		BOOL anyChild = NO;
		long ax = 0, ay = 0;
		int d = 0;

		if (own != nil) {
			[self addPiece:own z:level x:slot->x y:slot->y clip:full];
			continue;
		}
		if ([_source tileFor:key] == nil) {
			[wanted addObject:@(key)];
		}
		/* until it is here: the four of the level below that are (zooming out, they were a moment ago), and for
		   the rest of it the nearest tile above that is */
		if (level < MAP_DATA_ZOOM) {
			for (int q = 0; q < 4; q++) {
				child[q] = [self ready:tile_id(level + 1, 2 * wx + (q & 1), 2 * slot->y + (q >> 1))];
				anyChild |= child[q] != nil;
			}
		}
		for (d = 1; d <= FALLBACK_LEVELS && level - d >= 0; d++) {
			long an = n >> d;

			ax = floor_div(slot->x, 1L << d);
			ay = slot->y >> d;
			up = [self ready:tile_id(level - d, (ax % an + an) % an, ay)];
			if (up != nil) {
				break;
			}
		}
		if (!anyChild) {
			if (up != nil) {
				const float whole[4] = { 0, 0, 4096, 4096 };
				float clip[4];

				clip_in_ancestor(slot->x, slot->y, ax, ay, d, whole, clip);
				[self addPiece:up z:level - d x:ax y:ay clip:clip];
			}
			continue;
		}
		for (int q = 0; q < 4; q++) {
			if (child[q] != nil) {
				[self addPiece:child[q] z:level + 1 x:2 * slot->x + (q & 1) y:2 * slot->y + (q >> 1) clip:full];
			} else if (up != nil) {
				const float quarter[4] = { (q & 1) * 2048.0f, (q >> 1) * 2048.0f, (q & 1) * 2048.0f + 2048,
				    (q >> 1) * 2048.0f + 2048 };
				float clip[4];

				clip_in_ancestor(slot->x, slot->y, ax, ay, d, quarter, clip);
				[self addPiece:up z:level - d x:ax y:ay clip:clip];
			}
		}
	}
	if (!_zooming && (_wantAgain || ![wanted isEqualToArray:_wanted ?: @[]])) {
		_wantAgain = NO;
		_wanted = wanted;
		[_source want:wanted];
	}

	/* the passes: what of the style is drawn at this zoom, in which colour and how wide */
	memset(&frame, 0, sizeof(frame));
	premultiplied(style_background(dark), frame.background);
	for (unsigned p = 1; p < MAP_PASSES; p++) {
		frame.passes[p].lines = 1;
	}
	for (unsigned i = 0; i < style_draw_count; i++) {
		const struct style_draw *draw = &style_draws[i];
		BOOL line = style_kind_of(draw->bucket) == STYLE_LINE;
		/* (fills; then the lines under the roads -- water, runways -- ; the roads' casings; the roads and the rest) */
		struct map_pass *pass = &frame.passes[!line ? 0 : draw->casing ? 2 : draw->bucket < B_PATH ? 1 : 3];

		if (styleZoom >= draw->min_zoom) {
			premultiplied(draw->colour[dark], pass->colour[draw->bucket]);
		}
		pass->half[draw->bucket] = line ? style_line_width(draw->bucket, styleZoom, draw->casing) / 2 : 0;
	}
	c = cos(_turn);
	s = sin(_turn);
	frame.extrude[0] = (float)(2 * c / size.width);
	frame.extrude[1] = (float)(2 * s / size.height);
	frame.extrude[2] = (float)(2 * s / size.width);
	frame.extrude[3] = (float)(-2 * c / size.height);
	frame.pixel = (float)(1 / _pixel);
	frame.pieces = _pieces;
	frame.piece_count = _pieceCount;
	{
		CFTimeInterval t1 = CACurrentMediaTime(), t2;

		frame.labels = [_labels finishFor:_renderer count:&labelVertices];
		frame.label_vertices = labelVertices;
		if (_labels.pending) {
			_dirty = YES;
		}
		t2 = CACurrentMediaTime();
		[_renderer drawFrame:&frame];
		/* (the tiles' part has the labels' gathering in it: addPiece hands each tile's labels over) */
		_spentTiles += t1 - began;
		_spentLabels += t2 - t1;
		_spentDraw += CACurrentMediaTime() - t2;
	}
	[_drawn removeAllObjects];

	if (dark != _lastDark) {
		_lastDark = dark;
		if ([_delegate respondsToSelector:@selector(mapViewDidChangeLook:)]) {
			[_delegate mapViewDidChangeLook:self];
		}
	}
	if (_cx != _shownX || _cy != _shownY || _z != _shownZ || _turn != _shownTurn) {
		_shownX = _cx;
		_shownY = _cy;
		_shownZ = _z;
		_shownTurn = _turn;
		[self placeUser];
		[self placePin];
		[_delegate mapViewDidChange:self];
	}
	[self countFrame:CACurrentMediaTime() - began];
}

/* frames a second over the last second, and the time a frame takes the processor (the GPU's runs after) */
- (void)countFrame:(CFTimeInterval)took
{
	CFTimeInterval now = CACurrentMediaTime();

	_lastFrame = took;
	_frames++;
	_frameTime += took;
	_worstFrame = fmax(_worstFrame, took);
	if (_rateSince == 0) {
		_rateSince = now;
		_frames = 0;
		_frameTime = 0;
		_worstFrame = 0;
	} else if (now - _rateSince >= 1) {
		if (_showsFrameRate) {
			BOOL dark = self.dark;

			_rate.text = [NSString stringWithFormat:@" %.0f fps  %@\n %.1f ms a frame (most %.1f), %u tiles", _frames /
			    (now - _rateSince), _renderer.name ?: @"-", _frames ? 1000 * _frameTime / _frames : 0, 1000 * _worstFrame,
			    _pieceCount];
			_rate.textColor = dark ? UIColor.whiteColor : UIColor.blackColor;
			_rate.backgroundColor = [UIColor colorWithWhite:dark ? 0 : 1 alpha:0.6];
		}
		_rateSince = now;
		_frames = 0;
		_frameTime = 0;
		_worstFrame = 0;
	}
}

#pragma mark the tiles

- (void)sourceTileArrived:(uint64_t)key
{
	[self setNeedsFrame];
}

- (void)sourceTileFailed:(uint64_t)key
{
}

- (void)sourceMayRetry
{
	_wantAgain = YES;
	[self setNeedsFrame];
}

- (void)forgetTiles
{
	[_source forget];
	_wantAgain = YES;
	[self setNeedsFrame];
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
	/* (the heading is from north; the screen's up is the bearing) */
	_cone.affineTransform = CGAffineTransformMakeRotation(_heading * M_PI / 180 - _turn);
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
	[_copy setTitle:NSLocalizedString(@"Copy", nil) forState:UIControlStateNormal];
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
	[button setTitle:NSLocalizedString(@"Copied", nil) forState:UIControlStateNormal];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[button setTitle:NSLocalizedString(@"Copy", nil) forState:UIControlStateNormal];
	});
}

- (CGFloat)snap:(double)value
{
	return round(value * _pixel) / _pixel;
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
		[self animateToX:x y:y zoom:zoom turn:_turn anchored:NO];
		return;
	}
	_cx = x;
	_cy = y;
	_z = zoom;
	[self clamp];
	[self setNeedsFrame];
}

- (void)setBearing:(double)degrees animated:(BOOL)animated
{
	double turn = remainder(degrees * M_PI / 180, 2 * M_PI);

	[self stopMotion];
	if (animated && self.window != nil) {
		[self animateToX:_cx y:_cy zoom:_z turn:turn anchored:NO];
		return;
	}
	_turn = turn;
	[self setNeedsFrame];
}

- (void)moveBy:(CGPoint)move
{
	double ppw = [self ppw], c = cos(_turn), s = sin(_turn);

	/* (the fingers move on the screen; the world under them is turned) */
	_cx -= (c * move.x - s * move.y) / ppw;
	_cy -= (s * move.x + c * move.y) / ppw;
	[self clamp];
	[self setNeedsFrame];
}

/* the world point at `at` stays where it is while the centre turns or zooms about it */
- (void)keep:(double)ax y:(double)ay at:(CGPoint)at
{
	CGSize size = self.bounds.size;
	double ppw = [self ppw], c = cos(_turn), s = sin(_turn), dx = at.x - size.width / 2, dy = at.y - size.height / 2;

	_cx = ax - (c * dx - s * dy) / ppw;
	_cy = ay - (s * dx + c * dy) / ppw;
}

/* a new zoom about a point: the world point that was at `from` is now at `to` (where the fingers have gone) */
- (void)zoomTo:(double)zoom from:(CGPoint)from to:(CGPoint)to
{
	double ax, ay;

	if (_followsUser && _userLocation != nil) {
		from = to = [self pointAtX:_ux y:_uy];
	}
	[self worldAt:from x:&ax y:&ay];
	_z = fmin(MAP_MAX_ZOOM, fmax(MAP_MIN_ZOOM, zoom));
	[self keep:ax y:ay at:to];
	[self clamp];
	[self setNeedsFrame];
}

- (void)turnBy:(double)radians about:(CGPoint)at
{
	double ax, ay;

	if (_followsUser && _userLocation != nil) {
		at = [self pointAtX:_ux y:_uy];
	}
	[self worldAt:at x:&ax y:&ay];
	/* (the fingers turning clockwise turn the map clockwise: the top of the screen then points further west) */
	_turn -= radians;
	[self keep:ax y:ay at:at];
	[self clamp];
	[self setNeedsFrame];
}

/* the zooming is over: the level for the zoom is shown, and its tiles fetched */
- (void)endZooming
{
	_zooming = NO;
	_wantAgain = YES;
	[self setNeedsFrame];
}

- (void)animateToX:(double)x y:(double)y zoom:(double)zoom turn:(double)turn anchored:(BOOL)anchored
{
	_fromX = _cx;
	_fromY = _cy;
	_fromZ = _z;
	_fromTurn = _turn;
	_toX = _cx + (x - _cx - round(x - _cx));
	_toY = y;
	_toZ = zoom;
	_toTurn = _turn + remainder(turn - _turn, 2 * M_PI);
	_anchored = anchored;
	_zooming = fabs(zoom - _z) > 1e-9;
	_start = CACurrentMediaTime();
	_duration = fabs(_toTurn - _fromTurn) > 0.5 ? 0.45 : 0.3;
	_motion = MOTION_ANIMATION;
	[self setNeedsFrame];
}

- (void)fling:(CGPoint)velocity
{
	[self stopMotion];
	_velocity = velocity;
	_last = CACurrentMediaTime();
	_motion = MOTION_FLING;
	[self setNeedsFrame];
}

- (void)stopMotion
{
	BOOL animating = _motion == MOTION_ANIMATION;

	_motion = MOTION_NONE;
	if (animating && !_pinching) {
		[self endZooming];
	}
}

/* the motion of the moment, on to `now`; NO: nothing moves by itself */
- (BOOL)advance:(CFTimeInterval)now
{
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
		return YES;
	}
	if (_motion == MOTION_ANIMATION) {
		double t = fmin(1, (now - _start) / _duration), e = 1 - pow(1 - t, 3);

		_z = _fromZ + (_toZ - _fromZ) * e;
		_turn = _fromTurn + (_toTurn - _fromTurn) * e;
		if (_anchored) {
			[self keep:_anchorX y:_anchorY at:_anchorAt];
		} else {
			_cx = _fromX + (_toX - _fromX) * e;
			_cy = _fromY + (_toY - _fromY) * e;
		}
		[self clamp];
		if (t >= 1) {
			[self stopMotion];
		}
		return YES;
	}
	return NO;
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

- (void)rotate:(UIRotationGestureRecognizer *)rotation
{
	double turn = rotation.rotation;

	rotation.rotation = 0;
	switch (rotation.state) {
	case UIGestureRecognizerStateBegan:
		_turning = NO;
		_rotationHeld = 0;
		[_delegate mapViewWillMove:self dragged:NO];
		__attribute__((fallthrough));
	case UIGestureRecognizerStateChanged:
		if (rotation.numberOfTouches < 2) {
			return;
		}
		/* (a pinch's fingers turn a little: the map turns once they have turned 12 degrees, and from there on) */
		if (!_turning) {
			_rotationHeld += turn;
			if (fabs(_rotationHeld) < 12 * M_PI / 180) {
				return;
			}
			_turning = YES;
			turn = 0;
		}
		[self turnBy:turn about:[rotation locationInView:self]];
		break;
	default:
		_turning = NO;
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

/* a level in or out, animated, about the point tapped */
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
	[self animateToX:_cx y:_cy zoom:zoom turn:_turn anchored:YES];
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
	[self showPinAt:CLLocationCoordinate2DMake(latitude_at(y), longitude_at(x)) title:NSLocalizedString(@"Dropped pin", nil)];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch
{
	/* (the callout's buttons are the callout's, not the map's) */
	return _callout == nil || ![touch.view isDescendantOfView:_callout];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)one
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other
{
	NSArray *together = @[ _panner, _pincher, _rotator ];

	return [together containsObject:one] && [together containsObject:other];
}

#pragma mark the self-test

/* what a frame read back shows: how much of it is not the background, how many colours (in steps of 16) */
static NSArray<NSString *> *
look_at(const uint8_t *rgba, size_t width, size_t height, const float *background)
{
	uint8_t bg[3] = { (uint8_t)lround(background[0] * 255), (uint8_t)lround(background[1] * 255),
	    (uint8_t)lround(background[2] * 255) };
	static uint8_t seen[4096];
	size_t drawn = 0, total = 0, colours = 0;

	if (rgba == NULL) {
		return @[ @"readback: failed" ];
	}
	memset(seen, 0, sizeof(seen));
	for (size_t y = 0; y < height; y += 2) {
		for (size_t x = 0; x < width; x += 2) {
			const uint8_t *p = rgba + (y * width + x) * 4;
			unsigned bin = (p[0] >> 4) << 8 | (p[1] >> 4) << 4 | p[2] >> 4;

			total++;
			if (abs(p[0] - bg[0]) > 6 || abs(p[1] - bg[1]) > 6 || abs(p[2] - bg[2]) > 6) {
				drawn++;
			}
			if (!seen[bin]) {
				seen[bin] = 1;
				colours++;
			}
		}
	}
	return @[
		[NSString stringWithFormat:@"readback: %zux%zu", width, height],
		[NSString stringWithFormat:@"drawn: %.1f%% of the pixels are not the background", total ? 100.0 * drawn / total : 0],
		[NSString stringWithFormat:@"colours: %zu", colours],
	];
}

- (void)testAt:(CLLocationCoordinate2D)where zoom:(double)zoom renderer:(MapRendererKind)kind samples:(unsigned)samples
    done:(void (^)(NSArray<NSString *> *lines))done
{
	__weak MapView *weak = self;
	CFTimeInterval began = CACurrentMediaTime();
	__block int stage = 0;
	__block CFTimeInterval stageBegan = began, waited = 0;
	__block unsigned frames = 0;
	__block double worst = 0, spent = 0;
	NSMutableArray<NSString *> *lines = [NSMutableArray array];

	[self stopMotion];
	_samples = samples > 1 ? 4 : 1;
	_rendererKind = kind;
	[self makeRenderer];
	_turn = 0;
	[self setCenterCoordinate:where zoom:zoom animated:NO];
	[lines addObject:[NSString stringWithFormat:@"renderer: %@ (asked for %@, %u samples)", _renderer.name ?: @"none",
	    kind == MapRendererKindMetal ? @"Metal" : @"OpenGL ES", _samples]];
	[lines addObject:[NSString stringWithFormat:@"at: %@ zoom %.1f", coordinate_text(where), zoom]];
	_test = ^{
		MapView *me = weak;
		CFTimeInterval now = CACurrentMediaTime();

		if (me == nil) {
			return;
		}
		[me setNeedsFrame];
		switch (stage) {
		case 0: {
			/* the tiles: all of the screen's own, or 30 seconds */
			BOOL all = me->_slotCount > 0;

			for (unsigned i = 0; i < me->_slotCount && all; i++) {
				const struct slot *slot = &me->_slots[i];
				long n = 1L << slot->z;

				all = [me->_source tileFor:tile_id(slot->z, (slot->x % n + n) % n, slot->y)].gpu != nil;
			}
			if ((all && !me->_labels.pending) || now - stageBegan > 30) {
				waited = now - stageBegan;
				[lines addObject:[NSString stringWithFormat:@"tiles: %u on the screen, %@ after %.1f s; %lu downloaded, "
				    "%lu made%@", me->_slotCount, all ? @"all there" : @"NOT all there", waited,
				    (unsigned long)me->_source.downloads, (unsigned long)me->_source.made,
				    me->_source.problem ? [@"; last problem: " stringByAppendingString:me->_source.problem] : @""]];
				{
					unsigned triangles = 0;

					for (unsigned i = 0; i < me->_slotCount; i++) {
						const struct slot *slot = &me->_slots[i];
						long n = 1L << slot->z;
						MapTile *tile = [me->_source tileFor:tile_id(slot->z, (slot->x % n + n) % n, slot->y)];

						triangles += tile.mesh->triangles;
					}
					[lines addObject:[NSString stringWithFormat:@"triangles: %u; pieces %u; labels %u", triangles,
					    me->_pieceCount, me->_labels.placed]];
				}
				stage = 1;
				stageBegan = now;
			}
			break;
		}
		case 1: {
			/* a frame read back */
			stage = 2;
			[me->_renderer captureNextFrame:^(const uint8_t *rgba, size_t width, size_t height) {
				float bg[4];

				premultiplied(style_background(me.dark), bg);
				[lines addObjectsFromArray:look_at(rgba, width, height, bg)];
				stage = 3;
				stageBegan = CACurrentMediaTime();
				frames = 0;
				spent = 0;
				worst = 0;
				me->_spentTiles = me->_spentLabels = me->_spentDraw = 0;
			}];
			break;
		}
		case 2:
			if (now - stageBegan > 5) {
				[lines addObject:@"readback: no frame came back in 5 s"];
				stage = 3;
				stageBegan = now;
			}
			break;
		case 3: {
			/* four seconds still (for a screenshot of it), then three of motion: turning a quarter round and zooming
			   one level in and out again */
			double t = (now - stageBegan - 4) / 3;

			if (t < 0) {
				me->_spentTiles = me->_spentLabels = me->_spentDraw = 0;
				(void)[me->_renderer timing];
				break;
			}
			if (t < 1) {
				if (frames > 0) {
					/* (the frame drawn at this tick, of the camera set at the last one) */
					spent += me->_lastFrame;
					worst = fmax(worst, me->_lastFrame);
				}
				me->_turn = t * M_PI / 2;
				me->_z = zoom + sin(t * M_PI);
				frames++;
			} else {
				[lines addObject:[NSString stringWithFormat:@"motion: %.0f frames a second over 3 s (the screen goes up "
				    "to %ld); the processor %.1f ms a frame, at most %.1f", frames / 3.0,
				    (long)UIScreen.mainScreen.maximumFramesPerSecond, frames > 1 ? 1000 * spent / (frames - 1) : 0,
				    1000 * worst]];
				[lines addObject:[NSString stringWithFormat:@"parts: tiles and pieces %.1f ms a frame, labels %.1f, the "
				    "renderer %.1f (its present included)", frames ? 1000 * me->_spentTiles / frames : 0,
				    frames ? 1000 * me->_spentLabels / frames : 0, frames ? 1000 * me->_spentDraw / frames : 0]];
				[lines addObject:[@"in the renderer: " stringByAppendingString:[me->_renderer timing]]];
				me->_turn = 0;
				me->_z = zoom;
				me->_test = nil;
				[lines addObject:[NSString stringWithFormat:@"took: %.1f s", now - began]];
				done(lines);
			}
			break;
		}
		default:
			break;
		}
	};
	[self setNeedsFrame];
}

@end
