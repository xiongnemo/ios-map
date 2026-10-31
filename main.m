// Map: OpenStreetMap drawn on the CPU -- raster tiles laid out as Core Animation layers (MapView.m), a search through
// Nominatim, the location as a blue dot with its accuracy and, when asked for, the heading as a cone. Written for the
// iOS 16.5 port to the Redmi K40, where Apple's Maps and MapKit show nothing (they draw with Metal, which the port does
// not have); on an iPhone it is an ordinary application. This file is the screen around the map: the search bar and
// its results, the locate button, the scale bar, the attribution, and the location manager. build.sh builds it into
// Map.ipa (mkicon.py its icon).
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import "MapView.h"

static NSString *const search_url = @"https://nominatim.openstreetmap.org/search";
static NSString *const copyright_url = @"https://www.openstreetmap.org/copyright";

/* where the map was, kept for the next launch */
static NSString *const saved_latitude = @"Latitude", *const saved_longitude = @"Longitude", *const saved_zoom = @"Zoom";

enum { FOLLOW_NONE, FOLLOW_LOCATION, FOLLOW_HEADING };

/* A search result: its name, the rest of its address, where it is and, if Nominatim gave one, the box it fills. */
@interface MapPlace : NSObject
@property (copy, nonatomic) NSString *name, *detail;
@property (nonatomic) CLLocationCoordinate2D coordinate;
@property (nonatomic) BOOL boxed;
@property (nonatomic) double south, north, west, east;
@end

@implementation MapPlace
@end

/* a number Nominatim sent, as a string or a number; NAN if neither */
static double
number(id value)
{
	if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
		return [value doubleValue];
	}
	return NAN;
}

static MapPlace *
place_from(id item)
{
	NSDictionary *entry = item;
	NSString *name, *full;
	NSArray *box;
	MapPlace *place;
	double latitude, longitude;

	if (![item isKindOfClass:NSDictionary.class]) {
		return nil;
	}
	latitude = number(entry[@"lat"]);
	longitude = number(entry[@"lon"]);
	if (!isfinite(latitude) || !isfinite(longitude) || fabs(latitude) > 90 || fabs(longitude) > 180) {
		return nil;
	}
	full = [entry[@"display_name"] isKindOfClass:NSString.class] ? entry[@"display_name"] : @"";
	name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : @"";
	if (name.length == 0) {
		name = [[full componentsSeparatedByString:@","].firstObject
		    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
	}
	place = [MapPlace new];
	place.coordinate = CLLocationCoordinate2DMake(latitude, longitude);
	place.name = name.length > 0 ? name : coordinate_text(place.coordinate);
	/* (display_name starts with the name: what follows it is the address) */
	place.detail = [full hasPrefix:[name stringByAppendingString:@", "]] ? [full substringFromIndex:name.length + 2] : full;
	box = entry[@"boundingbox"];
	if ([box isKindOfClass:NSArray.class] && box.count == 4) {
		place.south = number(box[0]);
		place.north = number(box[1]);
		place.west = number(box[2]);
		place.east = number(box[3]);
		place.boxed = isfinite(place.south) && isfinite(place.north) && isfinite(place.west) && isfinite(place.east) &&
		    place.north > place.south && place.east >= place.west;
	}
	return place;
}

/* Nominatim's answer as places; nil and *problem if there is none to show */
static NSArray<MapPlace *> *
places_from(NSData *data, NSURLResponse *response, NSError *error, NSString **problem)
{
	NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
	NSMutableArray<MapPlace *> *places = [NSMutableArray array];
	id json;

	if (error != nil) {
		*problem = [NSString stringWithFormat:@"Search failed: %@", error.localizedDescription];
		return nil;
	}
	if (status != 200 || data == nil) {
		*problem = [NSString stringWithFormat:@"Search failed: the server answered %ld", (long)status];
		return nil;
	}
	json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
	if (![json isKindOfClass:NSArray.class]) {
		*problem = @"Search failed: the answer was not understood";
		return nil;
	}
	for (id item in json) {
		MapPlace *place = place_from(item);

		if (place != nil) {
			[places addObject:place];
		}
	}
	return places;
}

/* a query for a URL: everything but ASCII letters, digits and -._~ escaped (NSURLComponents would leave + and & be) */
static NSString *
escaped(NSString *text)
{
	static NSCharacterSet *plain;

	if (plain == nil) {
		plain = [NSCharacterSet characterSetWithCharactersInString:
		    @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	}
	return [text stringByAddingPercentEncodingWithAllowedCharacters:plain] ?: @"";
}

/* the user's languages, for the names Nominatim answers with (otherwise it would be whatever CFNetwork says: English) */
static NSString *
languages(void)
{
	NSArray<NSString *> *preferred = NSLocale.preferredLanguages;
	NSMutableArray<NSString *> *parts = [NSMutableArray array];

	for (NSUInteger i = 0; i < preferred.count && i < 4; i++) {
		[parts addObject:i == 0 ? preferred[i] : [NSString stringWithFormat:@"%@;q=%.1f", preferred[i], 1 - 0.2 * i]];
	}
	return parts.count > 0 ? [parts componentsJoinedByString:@", "] : @"en";
}

/* The scale bar, bottom left: a bar of a round length of at most 100 points, the length, and the zoom, small. */
@interface MapScaleBar : UIView
- (void)showMetresPerPoint:(double)metres zoom:(double)zoom;
@end

@implementation MapScaleBar {
	NSString *_length, *_level;
	CGFloat _width;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		self.opaque = NO;
		self.backgroundColor = UIColor.clearColor;
		self.userInteractionEnabled = NO;
		self.contentMode = UIViewContentModeRedraw;
	}
	return self;
}

- (void)showMetresPerPoint:(double)metres zoom:(double)zoom
{
	double most = metres * 100, base, length;
	NSString *text, *level;
	CGFloat width;

	if (!isfinite(metres) || metres <= 0) {
		return;
	}
	/* (1, 2 or 5 times a power of ten) */
	base = pow(10, floor(log10(most)));
	length = most >= 5 * base ? 5 * base : most >= 2 * base ? 2 * base : base;
	width = round(length / metres);
	text = length >= 1000 ? [NSString stringWithFormat:@"%g km", length / 1000] :
	    [NSString stringWithFormat:@"%g m", length];
	level = [NSString stringWithFormat:@"z %.1f", zoom];
	/* (redrawn only when it looks different: it is asked on every frame of a gesture) */
	if (width != _width || ![text isEqualToString:_length] || ![level isEqualToString:_level]) {
		_width = width;
		_length = text;
		_level = level;
		[self setNeedsDisplay];
	}
}

- (void)drawRect:(CGRect)rect
{
	NSDictionary *bold = @{ NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
	    NSForegroundColorAttributeName: UIColor.blackColor };
	NSDictionary *light = @{ NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular],
	    NSForegroundColorAttributeName: [UIColor colorWithWhite:0.3 alpha:1] };
	UIBezierPath *bar = [UIBezierPath bezierPath];
	CGSize length, level;
	CGFloat plate;

	if (_length == nil) {
		return;
	}
	length = [_length sizeWithAttributes:bold];
	level = [_level sizeWithAttributes:light];
	plate = fmin(self.bounds.size.width, fmax(_width, length.width + 6 + level.width) + 10);
	/* (on a pale plate: the map under it may be anything) */
	[[UIColor colorWithWhite:1 alpha:0.75] setFill];
	[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, plate, self.bounds.size.height) cornerRadius:5] fill];
	[_length drawAtPoint:CGPointMake(5, 2) withAttributes:bold];
	[_level drawAtPoint:CGPointMake(5 + length.width + 6, 3) withAttributes:light];
	[bar moveToPoint:CGPointMake(5, 18)];
	[bar addLineToPoint:CGPointMake(5, 25)];
	[bar addLineToPoint:CGPointMake(5 + _width, 25)];
	[bar addLineToPoint:CGPointMake(5 + _width, 18)];
	bar.lineWidth = 2;
	[UIColor.blackColor setStroke];
	[bar stroke];
}

@end

/* The attribution: a label with some room round its text. */
@interface MapCredit : UILabel
@end

@implementation MapCredit

- (void)drawTextInRect:(CGRect)rect
{
	[super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(2, 6, 2, 6))];
}

- (CGSize)intrinsicContentSize
{
	CGSize size = [super intrinsicContentSize];

	return CGSizeMake(size.width + 12, size.height + 4);
}

@end

@interface MapController : UIViewController <CLLocationManagerDelegate, MapViewDelegate, UISearchBarDelegate,
    UITableViewDataSource, UITableViewDelegate>
@end

@implementation MapController {
	MapView *_map;
	UISearchBar *_search;
	UITableView *_results;
	NSLayoutConstraint *_resultsHeight;
	NSArray<MapPlace *> *_places;
	NSString *_note;                /* instead of places: "Searching…", "No places found" or what went wrong */
	BOOL _resultsShown;
	NSURLSession *_session;
	NSURLSessionDataTask *_searchTask;
	CFAbsoluteTime _searchedAt;
	NSUInteger _searches;           /* counts the searches: an answer to any but the last is dropped */

	CLLocationManager *_location;
	int _follow;
	BOOL _updating;                 /* the location is being updated (allowed, and in the foreground) */
	BOOL _placed;                   /* the map shows a place on purpose: the first location does not move it */
	UIButton *_locate;
	MapScaleBar *_scale;
}

- (void)viewDidLoad
{
	NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
	NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;

	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemBackgroundColor;
	_map = [[MapView alloc] initWithFrame:self.view.bounds];
	_map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_map.delegate = self;
	[self.view addSubview:_map];

	config.HTTPAdditionalHeaders = @{ @"User-Agent": user_agent() };
	config.timeoutIntervalForRequest = 20;
	_session = [NSURLSession sessionWithConfiguration:config];

	_location = [CLLocationManager new];
	_location.desiredAccuracy = kCLLocationAccuracyBest;
	_location.headingFilter = 2;

	[self makeSearch];
	[self makeControls];
	[self restoreView];
	/* (set last: it calls locationManagerDidChangeAuthorization at once, which may ask for permission) */
	_location.delegate = self;

	[center addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
	[center addObserver:self selector:@selector(resignedActive) name:UIApplicationWillResignActiveNotification
	    object:nil];
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
	/* (the map is light, in dark mode too) */
	return UIStatusBarStyleDarkContent;
}

- (void)makeSearch
{
	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	UIView *card = [UIView new];
	NSLayoutConstraint *wide;

	card.backgroundColor = UIColor.systemBackgroundColor;
	card.layer.cornerRadius = 12;
	card.layer.borderWidth = 1 / UIScreen.mainScreen.scale;
	card.layer.borderColor = UIColor.separatorColor.CGColor;
	card.clipsToBounds = YES;
	_search = [UISearchBar new];
	_search.searchBarStyle = UISearchBarStyleMinimal;
	_search.placeholder = @"Search places";
	_search.returnKeyType = UIReturnKeySearch;
	_search.autocorrectionType = UITextAutocorrectionTypeNo;
	_search.delegate = self;
	_results = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	_results.dataSource = self;
	_results.delegate = self;
	_results.rowHeight = 56;
	_results.backgroundColor = UIColor.clearColor;
	_results.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
	for (UIView *view in @[ card, _search, _results ]) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
	}
	[self.view addSubview:card];
	[card addSubview:_search];
	[card addSubview:_results];
	_resultsHeight = [_results.heightAnchor constraintEqualToConstant:0];
	/* (the whole width in portrait; in landscape no wider than 440 points, at the left) */
	wide = [card.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8];
	wide.priority = UILayoutPriorityDefaultHigh;
	[NSLayoutConstraint activateConstraints:@[
		[card.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
		[card.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
		[card.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-8],
		[card.widthAnchor constraintLessThanOrEqualToConstant:440],
		wide,
		[_search.topAnchor constraintEqualToAnchor:card.topAnchor],
		[_search.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
		[_search.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
		[_results.topAnchor constraintEqualToAnchor:_search.bottomAnchor],
		[_results.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
		[_results.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
		[_results.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
		_resultsHeight,
	]];
}

- (void)makeControls
{
	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	MapCredit *credit = [MapCredit new];

	/* OSM's licence asks for this to be seen; tapped, it opens the page that says what it means */
	credit.text = @"© OpenStreetMap contributors";
	credit.font = [UIFont systemFontOfSize:11];
	credit.textColor = [UIColor colorWithWhite:0.15 alpha:1];
	/* (the layer's own colour, which the rounded corners clip; a label's backgroundColor would be drawn square) */
	credit.layer.backgroundColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
	credit.layer.cornerRadius = 4;
	credit.userInteractionEnabled = YES;
	credit.accessibilityTraits = UIAccessibilityTraitLink;
	[credit addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openCredits)]];

	_locate = [UIButton buttonWithType:UIButtonTypeSystem];
	_locate.backgroundColor = UIColor.systemBackgroundColor;
	_locate.layer.cornerRadius = 10;
	_locate.layer.borderWidth = 1 / UIScreen.mainScreen.scale;
	_locate.layer.borderColor = UIColor.separatorColor.CGColor;
	[_locate addTarget:self action:@selector(locate) forControlEvents:UIControlEventTouchUpInside];
	[self showFollow];

	_scale = [MapScaleBar new];

	for (UIView *view in @[ credit, _locate, _scale ]) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[self.view addSubview:view];
	}
	[NSLayoutConstraint activateConstraints:@[
		[credit.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-6],
		[credit.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
		[_locate.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
		[_locate.bottomAnchor constraintEqualToAnchor:credit.topAnchor constant:-10],
		[_locate.widthAnchor constraintEqualToConstant:44],
		[_locate.heightAnchor constraintEqualToConstant:44],
		[_scale.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
		[_scale.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
		[_scale.widthAnchor constraintEqualToConstant:150],
		[_scale.heightAnchor constraintEqualToConstant:30],
	]];
}

/* Where the map was when the app last went away; else the last location known; else the world. */
- (void)restoreView
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	CLLocation *last = _location.location;

	if ([defaults objectForKey:saved_zoom] != nil) {
		[_map setCenterCoordinate:CLLocationCoordinate2DMake([defaults doubleForKey:saved_latitude],
		    [defaults doubleForKey:saved_longitude]) zoom:[defaults doubleForKey:saved_zoom] animated:NO];
		_placed = YES;
	} else if (last != nil) {
		[_map setCenterCoordinate:last.coordinate zoom:15 animated:NO];
		_placed = YES;
	} else {
		[_map setCenterCoordinate:CLLocationCoordinate2DMake(30, 10) zoom:MAP_MIN_ZOOM animated:NO];
	}
}

- (void)saveView
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	CLLocationCoordinate2D center = _map.centerCoordinate;

	[defaults setDouble:center.latitude forKey:saved_latitude];
	[defaults setDouble:center.longitude forKey:saved_longitude];
	[defaults setDouble:_map.zoom forKey:saved_zoom];
}

- (void)becameActive
{
	[self startLocation];
}

- (void)resignedActive
{
	[self saveView];
	[self stopLocation];
}

- (void)didReceiveMemoryWarning
{
	[super didReceiveMemoryWarning];
	[_map forgetTiles];
}

- (void)viewDidLayoutSubviews
{
	CLDeviceOrientation top;

	[super viewDidLayoutSubviews];
	/*
	 * The heading is of the side of the device CLLocationManager is told is up; the map's north is up the screen, so
	 * that is the side at the top of the interface. A landscape-left interface is a device turned right (its home
	 * side on the left), which UIKit's and Core Location's device orientations call landscape right.
	 */
	switch (self.view.window.windowScene.interfaceOrientation) {
	case UIInterfaceOrientationLandscapeLeft:
		top = CLDeviceOrientationLandscapeRight;
		break;
	case UIInterfaceOrientationLandscapeRight:
		top = CLDeviceOrientationLandscapeLeft;
		break;
	case UIInterfaceOrientationPortraitUpsideDown:
		top = CLDeviceOrientationPortraitUpsideDown;
		break;
	default:
		top = CLDeviceOrientationPortrait;
		break;
	}
	if (_location.headingOrientation != top) {
		_location.headingOrientation = top;
	}
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
	[coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
		[self showResults:self->_resultsShown];
	}];
}

#pragma mark the location

- (void)startLocation
{
	switch (_location.authorizationStatus) {
	case kCLAuthorizationStatusNotDetermined:
		[_location requestWhenInUseAuthorization];
		break;
	case kCLAuthorizationStatusAuthorizedWhenInUse:
	case kCLAuthorizationStatusAuthorizedAlways:
		[_location startUpdatingLocation];
		if (_follow == FOLLOW_HEADING && CLLocationManager.headingAvailable) {
			[_location startUpdatingHeading];
		}
		_updating = YES;
		break;
	default:
		[self stopLocation];
		[self lostLocation];
		break;
	}
}

- (void)stopLocation
{
	[_location stopUpdatingLocation];
	[_location stopUpdatingHeading];
	_updating = NO;
}

/* refused: no dot, nothing followed */
- (void)lostLocation
{
	_map.userLocation = nil;
	_map.heading = -1;
	if (_follow != FOLLOW_NONE) {
		[self follow:FOLLOW_NONE];
	}
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager
{
	if (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
		[self startLocation];
	}
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations
{
	CLLocation *where = locations.lastObject;

	if (where == nil || where.horizontalAccuracy < 0) {
		return;
	}
	_map.userLocation = where;
	if (_follow != FOLLOW_NONE) {
		[_map setCenterCoordinate:where.coordinate zoom:_map.zoom animated:YES];
	} else if (!_placed) {
		/* (the first launch, on the world: the first location is where to start) */
		_placed = YES;
		[_map setCenterCoordinate:where.coordinate zoom:15 animated:NO];
	}
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)heading
{
	if (_follow != FOLLOW_HEADING) {
		return;
	}
	/* (a negative accuracy means there is no heading; the true one needs a location, the magnetic one does not) */
	if (heading.headingAccuracy < 0) {
		_map.heading = -1;
	} else {
		_map.heading = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading;
	}
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
	/* (kCLErrorLocationUnknown only means not yet: Core Location keeps trying) */
	if ([error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorDenied) {
		[self stopLocation];
		[self lostLocation];
	} else if ([error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorHeadingFailure) {
		_map.heading = -1;
	}
}

/* none -> follow -> follow with the heading -> none; the first time, the permission is asked for instead */
- (void)locate
{
	CLAuthorizationStatus status = _location.authorizationStatus;
	CLLocation *where;

	if (status == kCLAuthorizationStatusNotDetermined) {
		[_location requestWhenInUseAuthorization];
		return;
	}
	if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
		[self askForLocation];
		return;
	}
	[self follow:(_follow + 1) % 3];
	where = _map.userLocation ?: _location.location;
	if (_follow != FOLLOW_NONE && where != nil) {
		_placed = YES;
		[_map setCenterCoordinate:where.coordinate zoom:_map.zoom < 12 ? 16 : _map.zoom animated:YES];
	}
}

/* following, the map keeps the location in the middle; with the heading, it shows the cone (the map is not turned) */
- (void)follow:(int)follow
{
	_follow = follow;
	_map.followsUser = follow != FOLLOW_NONE;
	if (follow == FOLLOW_HEADING && _updating && CLLocationManager.headingAvailable) {
		[_location startUpdatingHeading];
	} else {
		[_location stopUpdatingHeading];
		_map.heading = -1;
	}
	[self showFollow];
}

- (void)showFollow
{
	static NSString *const symbols[] = { @"location", @"location.fill", @"location.north.line.fill" };
	static NSString *const marks[] = { @"◎", @"●", @"▲" };
	static NSString *const names[] = { @"Follow my location", @"Follow my location and heading", @"Stop following" };
	UIImageSymbolConfiguration *look = [UIImageSymbolConfiguration configurationWithPointSize:18
	    weight:UIImageSymbolWeightMedium];
	UIImage *image = [UIImage systemImageNamed:symbols[_follow] withConfiguration:look];

	/* (a character if the system's symbols are not there) */
	[_locate setImage:image forState:UIControlStateNormal];
	[_locate setTitle:image == nil ? marks[_follow] : nil forState:UIControlStateNormal];
	_locate.accessibilityLabel = names[_follow];
}

- (void)askForLocation
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Location is off for Map"
	    message:@"Map may not use your location. It can be allowed in Settings."
	    preferredStyle:UIAlertControllerStyleAlert];

	[alert addAction:[UIAlertAction actionWithTitle:@"Settings" style:UIAlertActionStyleDefault
	    handler:^(UIAlertAction *action) {
		NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];

		if (url != nil) {
			[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
		}
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)openCredits
{
	[UIApplication.sharedApplication openURL:[NSURL URLWithString:copyright_url] options:@{} completionHandler:nil];
}

#pragma mark the map

- (void)mapViewDidChange:(MapView *)map
{
	[_scale showMetresPerPoint:map.metresPerPoint zoom:map.zoom];
}

- (void)mapViewWillMove:(MapView *)map dragged:(BOOL)dragged
{
	_placed = YES;
	if (dragged && _follow != FOLLOW_NONE) {
		[self follow:FOLLOW_NONE];
	}
	[_search resignFirstResponder];
	[self showResults:NO];
}

#pragma mark the search

- (void)searchBarTextDidBeginEditing:(UISearchBar *)bar
{
	[bar setShowsCancelButton:YES animated:YES];
	[self showResults:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)bar
{
	[bar setShowsCancelButton:NO animated:YES];
}

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text
{
	/* (nothing is searched for while typing -- Nominatim's policy forbids it -- but cleared, the old results go) */
	if (text.length == 0) {
		_places = nil;
		_note = nil;
		[self showResults:NO];
	}
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)bar
{
	_searches++;
	[_searchTask cancel];
	_searchTask = nil;
	_places = nil;
	_note = nil;
	bar.text = @"";
	[bar resignFirstResponder];
	[self showResults:NO];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar
{
	NSString *query = [bar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

	[bar resignFirstResponder];
	if (query.length > 0) {
		[self search:query];
	}
}

- (void)search:(NSString *)query
{
	NSUInteger serial = ++_searches;
	double wait = 1.0 - (CFAbsoluteTimeGetCurrent() - _searchedAt);
	__weak MapController *weak = self;

	[_searchTask cancel];
	_searchTask = nil;
	_places = nil;
	_note = @"Searching…";
	[self showResults:YES];
	/* (Nominatim allows one request a second at most: a search sooner than that after the last one waits its turn) */
	if (wait > 0) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			MapController *me = weak;

			if (me != nil && me->_searches == serial) {
				[me send:query serial:serial];
			}
		});
	} else {
		[self send:query serial:serial];
	}
}

- (void)send:(NSString *)query serial:(NSUInteger)serial
{
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?format=jsonv2&q=%@&limit=8", search_url,
	    escaped(query)]];
	__weak MapController *weak = self;
	NSMutableURLRequest *request;

	if (url == nil) {
		_note = @"Search failed: that cannot be asked";
		[self showResults:YES];
		return;
	}
	request = [NSMutableURLRequest requestWithURL:url];
	[request setValue:user_agent() forHTTPHeaderField:@"User-Agent"];
	[request setValue:languages() forHTTPHeaderField:@"Accept-Language"];
	_searchedAt = CFAbsoluteTimeGetCurrent();
	_searchTask = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response,
	    NSError *error) {
		NSString *problem = nil;
		NSArray<MapPlace *> *places = places_from(data, response, error, &problem);

		dispatch_async(dispatch_get_main_queue(), ^{
			MapController *me = weak;

			if (me == nil || me->_searches != serial) {
				return;
			}
			me->_searchTask = nil;
			me->_places = places;
			me->_note = problem ?: (places.count == 0 ? @"No places found" : nil);
			[me showResults:YES];
		});
	}];
	[_searchTask resume];
}

/* the results under the search bar, at most 45% of the screen tall (they scroll); none: hidden */
- (void)showResults:(BOOL)show
{
	NSInteger rows = _note != nil ? 1 : (NSInteger)_places.count;
	CGFloat most = fmax(_results.rowHeight, self.view.bounds.size.height * 0.45);

	_resultsShown = show && rows > 0;
	[_results reloadData];
	_resultsHeight.constant = _resultsShown ? fmin(rows * _results.rowHeight, most) : 0;
}

/* the zoom at which a place's box fits the map, below the search bar and with a margin; 16 for a place without one */
- (double)zoomFor:(MapPlace *)place
{
	CGSize size = _map.bounds.size;
	double width, height, zoom;

	if (!place.boxed) {
		return 16;
	}
	width = (place.east - place.west) / 360;
	height = fabs(mercator_y(place.south) - mercator_y(place.north));
	zoom = log2(fmin((size.width - 40) / fmax(width, 1e-9), size.height * 0.6 / fmax(height, 1e-9)) / 256);
	return isfinite(zoom) ? fmin(17, fmax(3, zoom)) : 16;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section
{
	return _note != nil ? 1 : (NSInteger)_places.count;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path
{
	UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"place"] ?:
	    [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"place"];
	UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];

	content.textProperties.numberOfLines = 1;
	content.secondaryTextProperties.numberOfLines = 1;
	content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
	if (_note != nil || path.row >= (NSInteger)_places.count) {
		content.text = _note ?: @"";
		content.textProperties.color = UIColor.secondaryLabelColor;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	} else {
		content.text = _places[path.row].name;
		content.secondaryText = _places[path.row].detail;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	}
	cell.contentConfiguration = content;
	cell.backgroundColor = UIColor.clearColor;
	return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path
{
	MapPlace *place;

	[table deselectRowAtIndexPath:path animated:YES];
	if (_note != nil || path.row >= (NSInteger)_places.count) {
		return;
	}
	place = _places[path.row];
	[_search resignFirstResponder];
	[self showResults:NO];
	[self follow:FOLLOW_NONE];
	_placed = YES;
	[_map setCenterCoordinate:place.coordinate zoom:[self zoomFor:place] animated:YES];
	[_map showPinAt:place.coordinate title:place.name];
}

@end

@interface MapAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MapAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.rootViewController = [MapController new];
	[self.window makeKeyAndVisible];
	return YES;
}

@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass(MapAppDelegate.class));
	}
}
