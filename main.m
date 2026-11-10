// Map: OpenStreetMap as vector tiles drawn by the GPU (MapView.m) -- with OpenGL ES or with Metal, as the settings
// say -- a search through Nominatim, the location as a blue dot with its accuracy and, when asked for, the heading as a
// cone. Written for the iOS 16.5 port to the Redmi K40, where Apple's Maps cannot get its data (that needs Apple's
// servers to know the phone); on an iPhone it is an ordinary application. This file is the screen around the map: the
// search bar and its results, the locate, compass and settings buttons, the scale bar, the attribution, the settings
// and the location manager. build.sh builds it into Map.ipa (mkicon.py its icon).
//
// map://test?renderer=gl|metal|both&at=LATITUDE,LONGITUDE,ZOOM runs the self-test (MapView's testAt:) and says what it
// found on the console, a line each, after "mapcheck: ".
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import "MapView.h"

static NSString *const search_url = @"https://nominatim.openstreetmap.org/search";

/* where the map was, kept for the next launch */
static NSString *const saved_latitude = @"Latitude", *const saved_longitude = @"Longitude", *const saved_zoom = @"Zoom";
static NSString *const saved_bearing = @"Bearing";

/* the settings, iOS's Settings (Settings.bundle) and the gear's: the same keys */
static NSString *const setting_renderer = @"Renderer", *const setting_style = @"Style";
static NSString *const setting_language = @"LabelLanguage", *const setting_rate = @"ShowFrameRate";

/*
 * A line of what the app found, for whoever tests it: on the console after "mapcheck: ", and at the end of
 * Documents/mapcheck.log (a test harness that cannot read the console fetches that).
 */
static void
map_say(NSString *line)
{
	static NSFileHandle *log;
	static dispatch_once_t once;

	NSLog(@"mapcheck: %@", line);
	dispatch_once(&once, ^{
		NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
		    inDomains:NSUserDomainMask].firstObject;
		NSString *path = [documents URLByAppendingPathComponent:@"mapcheck.log"].path;

		if (path != nil && ([NSFileManager.defaultManager fileExistsAtPath:path] ||
		    [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil])) {
			log = [NSFileHandle fileHandleForWritingAtPath:path];
			[log seekToEndOfFile];
		}
	});
	[log writeData:[[NSString stringWithFormat:@"%@ %@\n", [NSDate date], line]
	    dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSString *
authorization_name(CLAuthorizationStatus status)
{
	switch (status) {
	case kCLAuthorizationStatusNotDetermined:
		return @"not determined";
	case kCLAuthorizationStatusRestricted:
		return @"restricted";
	case kCLAuthorizationStatusDenied:
		return @"denied";
	case kCLAuthorizationStatusAuthorizedAlways:
		return @"always";
	case kCLAuthorizationStatusAuthorizedWhenInUse:
		return @"when in use";
	}
	return [NSString stringWithFormat:@"%d", (int)status];
}

/* the place names the settings ask for, "system" being the phone's first language */
static enum style_language
language_for(NSString *setting)
{
	NSString *first = NSLocale.preferredLanguages.firstObject ?: @"en";
	/* (Chinese in the phone's script: zh-Hant, zh-TW, zh-HK, zh-MO are Traditional; the rest Simplified) */
	BOOL traditional = [first hasPrefix:@"zh-Hant"] || [first hasPrefix:@"zh-TW"] || [first hasPrefix:@"zh-HK"] ||
	    [first hasPrefix:@"zh-MO"];
	enum style_language chinese = traditional ? LANGUAGE_CHINESE_TRADITIONAL : LANGUAGE_CHINESE;

	if ([setting isEqualToString:@"local"]) {
		return LANGUAGE_LOCAL;
	}
	if ([setting isEqualToString:@"zh"]) {
		return chinese;
	}
	if ([setting isEqualToString:@"en"]) {
		return LANGUAGE_ENGLISH;
	}
	return [first hasPrefix:@"zh"] ? chinese : [first hasPrefix:@"en"] ? LANGUAGE_ENGLISH : LANGUAGE_LOCAL;
}

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
/* on a dark map: a dark plate, light lines */
@property (nonatomic) BOOL dark;
- (void)showMetresPerPoint:(double)metres zoom:(double)zoom;
@end

@implementation MapScaleBar {
	NSString *_length, *_level;
	CGFloat _width;
}

- (void)setDark:(BOOL)dark
{
	if (dark != _dark) {
		_dark = dark;
		[self setNeedsDisplay];
	}
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
	UIColor *ink = _dark ? [UIColor colorWithWhite:0.85 alpha:1] : UIColor.blackColor;
	NSDictionary *bold = @{ NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
	    NSForegroundColorAttributeName: ink };
	NSDictionary *light = @{ NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular],
	    NSForegroundColorAttributeName: [UIColor colorWithWhite:_dark ? 0.6 : 0.3 alpha:1] };
	UIBezierPath *bar = [UIBezierPath bezierPath];
	CGSize length, level;
	CGFloat plate;

	if (_length == nil) {
		return;
	}
	length = [_length sizeWithAttributes:bold];
	level = [_level sizeWithAttributes:light];
	plate = fmin(self.bounds.size.width, fmax(_width, length.width + 6 + level.width) + 10);
	/* (on a plate, pale or dark as the map is: the map under it may be anything) */
	[[UIColor colorWithWhite:_dark ? 0 : 1 alpha:_dark ? 0.55 : 0.75] setFill];
	[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, plate, self.bounds.size.height) cornerRadius:5] fill];
	[_length drawAtPoint:CGPointMake(5, 2) withAttributes:bold];
	[_level drawAtPoint:CGPointMake(5 + length.width + 6, 3) withAttributes:light];
	[bar moveToPoint:CGPointMake(5, 18)];
	[bar addLineToPoint:CGPointMake(5, 25)];
	[bar addLineToPoint:CGPointMake(5 + _width, 25)];
	[bar addLineToPoint:CGPointMake(5 + _width, 18)];
	bar.lineWidth = 2;
	[ink setStroke];
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

/* The gear's sheet: the settings iOS's Settings has for the app, written to the same keys (the map follows them). */
@interface MapSettingsController : UIViewController
@property (weak, nonatomic) MapView *map;
@end

@implementation MapSettingsController {
	UISegmentedControl *_renderer, *_style, *_language;
	UISwitch *_rate;
	UILabel *_note;
}

static NSArray<NSString *> *
style_values(void)
{
	return @[ @"system", @"light", @"dark" ];
}

static NSArray<NSString *> *
language_values(void)
{
	return @[ @"system", @"local", @"zh", @"en" ];
}

- (UIView *)row:(NSString *)title control:(UIView *)control
{
	UILabel *label = [UILabel new];
	UIStackView *row;

	label.text = title;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	label.textColor = UIColor.secondaryLabelColor;
	row = [[UIStackView alloc] initWithArrangedSubviews:@[ label, control ]];
	row.axis = [control isKindOfClass:UISwitch.class] ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
	row.spacing = 6;
	row.alignment = [control isKindOfClass:UISwitch.class] ? UIStackViewAlignmentCenter : UIStackViewAlignmentFill;
	return row;
}

- (void)viewDidLoad
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	NSString *metal = map_metal_problem();
	NSUInteger style = [style_values() indexOfObject:[defaults stringForKey:setting_style] ?: @"system"];
	NSUInteger language = [language_values() indexOfObject:[defaults stringForKey:setting_language] ?: @"system"];
	UIStackView *stack;

	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemBackgroundColor;
	self.title = NSLocalizedString(@"Map Settings", nil);
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
	    target:self action:@selector(done)];
	_renderer = [[UISegmentedControl alloc] initWithItems:@[ @"OpenGL ES", @"Metal" ]];
	[_renderer setEnabled:metal == nil forSegmentAtIndex:1];
	_renderer.selectedSegmentIndex = metal == nil && [[defaults stringForKey:setting_renderer] isEqualToString:@"metal"];
	_style = [[UISegmentedControl alloc] initWithItems:@[ NSLocalizedString(@"System", nil), NSLocalizedString(@"Light", nil),
	    NSLocalizedString(@"Dark", nil) ]];
	_style.selectedSegmentIndex = style == NSNotFound ? 0 : (NSInteger)style;
	_language = [[UISegmentedControl alloc] initWithItems:@[ NSLocalizedString(@"System", nil),
	    NSLocalizedString(@"Local", nil), NSLocalizedString(@"Chinese", nil), NSLocalizedString(@"English", nil) ]];
	_language.selectedSegmentIndex = language == NSNotFound ? 0 : (NSInteger)language;
	_rate = [UISwitch new];
	_rate.on = [defaults boolForKey:setting_rate];
	for (UIControl *control in @[ _renderer, _style, _language, _rate ]) {
		[control addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
	}
	_note = [UILabel new];
	_note.numberOfLines = 0;
	_note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	_note.textColor = UIColor.secondaryLabelColor;
	[self showNote];
	stack = [[UIStackView alloc] initWithArrangedSubviews:@[
		[self row:NSLocalizedString(@"Renderer", nil) control:_renderer],
		[self row:NSLocalizedString(@"Style", nil) control:_style],
		[self row:NSLocalizedString(@"Place Names", nil) control:_language],
		[self row:NSLocalizedString(@"Show Frame Rate", nil) control:_rate],
		_note,
	]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 20;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
		[stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
		[stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
	]];
}

- (void)showNote
{
	NSString *metal = map_metal_problem();
	NSString *text = [NSString stringWithFormat:NSLocalizedString(@"Drawing with %@.", nil), _map.rendererName ?: @"-"];

	if (metal != nil) {
		text = [text stringByAppendingFormat:@" %@", [NSString stringWithFormat:NSLocalizedString(@"Metal: %@.", nil),
		    NSLocalizedString(metal, nil)]];
	}
	_note.text = [text stringByAppendingString:@"\n\n© OpenFreeMap © OpenMapTiles © OpenStreetMap contributors"];
}

- (void)changed
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

	/* (the map hears of it through NSUserDefaultsDidChangeNotification, at once, on this thread) */
	[defaults setObject:_renderer.selectedSegmentIndex == 1 ? @"metal" : @"gl" forKey:setting_renderer];
	[defaults setObject:style_values()[(NSUInteger)MAX(0, _style.selectedSegmentIndex)] forKey:setting_style];
	[defaults setObject:language_values()[(NSUInteger)MAX(0, _language.selectedSegmentIndex)] forKey:setting_language];
	[defaults setBool:_rate.on forKey:setting_rate];
	[self showNote];
}

- (void)done
{
	[self dismissViewControllerAnimated:YES completion:nil];
}

@end

@interface MapController : UIViewController <CLLocationManagerDelegate, MapViewDelegate, UISearchBarDelegate,
    UITableViewDataSource, UITableViewDelegate>
- (void)runTest:(NSURL *)url;
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
	UIButton *_locate, *_gear, *_compass;
	MapScaleBar *_scale;
	MapCredit *_credit;
	UIView *_card;                  /* the search bar and its results */
	BOOL _testing;
}

- (void)viewDidLoad
{
	NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
	NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;

	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemBackgroundColor;
	/* (what Settings.bundle says too: iOS's Settings writes its values only once they are changed there) */
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		setting_renderer: @"gl", setting_style: @"system", setting_language: @"system", setting_rate: @NO,
	}];
	_map = [[MapView alloc] initWithFrame:self.view.bounds];
	_map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_map.delegate = self;
	[self applySettings];
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
	/* (the gear writes them, and iOS's Settings while the app was away: either way the map follows) */
	[center addObserver:self selector:@selector(applySettings) name:NSUserDefaultsDidChangeNotification object:nil];
}

/* the settings, as the map is to be drawn (a self-test chooses its renderer itself until it is done) */
- (void)applySettings
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	NSString *style = [defaults stringForKey:setting_style];

	if (_testing) {
		return;
	}
	_map.samples = 4;
	_map.rendererKind = [[defaults stringForKey:setting_renderer] isEqualToString:@"metal"] ? MapRendererKindMetal :
	    MapRendererKindGL;
	_map.style = [style isEqualToString:@"light"] ? MapStyleLight : [style isEqualToString:@"dark"] ? MapStyleDark :
	    MapStyleSystem;
	_map.labelLanguage = language_for([defaults stringForKey:setting_language]);
	_map.showsFrameRate = [defaults boolForKey:setting_rate];
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
	return _map.dark ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent;
}

- (void)makeSearch
{
	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	UIView *card = [UIView new];
	NSLayoutConstraint *wide;

	_card = card;
	card.backgroundColor = UIColor.systemBackgroundColor;
	card.layer.cornerRadius = 12;
	card.layer.borderWidth = 1 / UIScreen.mainScreen.scale;
	card.layer.borderColor = UIColor.separatorColor.CGColor;
	card.clipsToBounds = YES;
	_search = [UISearchBar new];
	_search.searchBarStyle = UISearchBarStyleMinimal;
	_search.placeholder = NSLocalizedString(@"Search places", nil);
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

/* a round-cornered button of the map's, with a system symbol (or a character, where the symbols are not) */
static UIButton *
map_button(NSString *symbol, NSString *mark, NSString *name)
{
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration
	    configurationWithPointSize:18 weight:UIImageSymbolWeightMedium]];

	button.backgroundColor = UIColor.systemBackgroundColor;
	button.layer.cornerRadius = 10;
	button.layer.borderWidth = 1 / UIScreen.mainScreen.scale;
	button.layer.borderColor = UIColor.separatorColor.CGColor;
	[button setImage:image forState:UIControlStateNormal];
	[button setTitle:image == nil ? mark : nil forState:UIControlStateNormal];
	button.accessibilityLabel = name;
	return button;
}

- (void)makeControls
{
	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	MapCredit *credit = [MapCredit new];

	/* the data's licences ask for this to be seen; tapped, it offers the pages that say what it means */
	_credit = credit;
	credit.text = @"© OpenFreeMap © OpenMapTiles © OpenStreetMap";
	credit.font = [UIFont systemFontOfSize:10];
	/* (the layer's own colour, which the rounded corners clip; a label's backgroundColor would be drawn square) */
	credit.layer.cornerRadius = 4;
	credit.userInteractionEnabled = YES;
	credit.accessibilityTraits = UIAccessibilityTraitLink;
	[credit addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openCredits)]];

	_locate = map_button(@"location", @"◎", @"Follow my location");
	[_locate addTarget:self action:@selector(locate) forControlEvents:UIControlEventTouchUpInside];
	[self showFollow];
	_gear = map_button(@"gearshape", @"⚙", NSLocalizedString(@"Settings", nil));
	[_gear addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
	/* (shown while the map is turned: it points north, and tapped turns the map back) */
	_compass = map_button(@"location.north.line", @"N", NSLocalizedString(@"North up", nil));
	[_compass addTarget:self action:@selector(northUp) forControlEvents:UIControlEventTouchUpInside];
	_compass.hidden = YES;

	_scale = [MapScaleBar new];

	for (UIView *view in @[ credit, _locate, _gear, _compass, _scale ]) {
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
		[_gear.trailingAnchor constraintEqualToAnchor:_locate.trailingAnchor],
		[_gear.bottomAnchor constraintEqualToAnchor:_locate.topAnchor constant:-10],
		[_gear.widthAnchor constraintEqualToConstant:44],
		[_gear.heightAnchor constraintEqualToConstant:44],
		[_compass.trailingAnchor constraintEqualToAnchor:_locate.trailingAnchor],
		[_compass.bottomAnchor constraintEqualToAnchor:_gear.topAnchor constant:-10],
		[_compass.widthAnchor constraintEqualToConstant:44],
		[_compass.heightAnchor constraintEqualToConstant:44],
		[_scale.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
		[_scale.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4],
		[_scale.widthAnchor constraintEqualToConstant:150],
		[_scale.heightAnchor constraintEqualToConstant:30],
	]];
	[self showLook];
}

/* the scale bar and the attribution as dark or light as the map */
- (void)showLook
{
	BOOL dark = _map.dark;

	_scale.dark = dark;
	_credit.textColor = dark ? [UIColor colorWithWhite:0.8 alpha:1] : [UIColor colorWithWhite:0.15 alpha:1];
	_credit.layer.backgroundColor = [UIColor colorWithWhite:dark ? 0 : 1 alpha:dark ? 0.55 : 0.75].CGColor;
	[self setNeedsStatusBarAppearanceUpdate];
}

- (void)openSettings
{
	MapSettingsController *settings = [MapSettingsController new];
	UINavigationController *sheet = [[UINavigationController alloc] initWithRootViewController:settings];

	settings.map = _map;
	if (@available(iOS 15.0, *)) {
		sheet.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.mediumDetent,
		    UISheetPresentationControllerDetent.largeDetent ];
		sheet.sheetPresentationController.prefersGrabberVisible = YES;
	}
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)northUp
{
	[_map setBearing:0 animated:YES];
}

/* Where the map was when the app last went away; else the last location known; else the world. */
- (void)restoreView
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	CLLocation *last = _location.location;

	if ([defaults objectForKey:saved_zoom] != nil) {
		[_map setCenterCoordinate:CLLocationCoordinate2DMake([defaults doubleForKey:saved_latitude],
		    [defaults doubleForKey:saved_longitude]) zoom:[defaults doubleForKey:saved_zoom] animated:NO];
		[_map setBearing:[defaults doubleForKey:saved_bearing] animated:NO];
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

	if (_testing) {
		return;                 /* (the self-test's place is not the user's) */
	}
	[defaults setDouble:center.latitude forKey:saved_latitude];
	[defaults setDouble:center.longitude forKey:saved_longitude];
	[defaults setDouble:_map.zoom forKey:saved_zoom];
	[defaults setDouble:_map.bearing forKey:saved_bearing];
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
	[self showCovered];
}

/* where the map is covered by what is over it: no label goes there */
- (void)showCovered
{
	NSMutableArray<NSValue *> *rects = [NSMutableArray array];

	/* (and the status bar's strip: the clock is over it) */
	[rects addObject:[NSValue valueWithCGRect:CGRectMake(0, 0, self.view.bounds.size.width,
	    self.view.safeAreaInsets.top)]];
	for (UIView *view in @[ _card ?: NSNull.null, _locate ?: NSNull.null, _gear ?: NSNull.null,
	    _compass ?: NSNull.null, _scale ?: NSNull.null, _credit ?: NSNull.null ]) {
		if ([view isKindOfClass:UIView.class] && !view.hidden && view.window != nil) {
			[rects addObject:[NSValue valueWithCGRect:[view convertRect:view.bounds toView:_map]]];
		}
	}
	_map.coveredRects = rects;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
	[coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
		[self showResults:self->_resultsShown];
	}];
}

#pragma mark the location

/* what Core Location says of the location for this app: its switch, the app's permission, how precise */
- (void)sayLocation:(NSString *)when
{
	map_say([NSString stringWithFormat:@"location (%@): Location Services %@, this app %@, %@ accuracy", when,
	    CLLocationManager.locationServicesEnabled ? @"on" : @"OFF", authorization_name(_location.authorizationStatus),
	    _location.accuracyAuthorization == CLAccuracyAuthorizationFullAccuracy ? @"full" : @"reduced"]);
}

- (void)startLocation
{
	switch (_location.authorizationStatus) {
	case kCLAuthorizationStatusNotDetermined:
		map_say(@"location: asking for the permission (requestWhenInUseAuthorization)");
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
	[self sayLocation:@"the permission changed"];
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
	if (_map.userLocation == nil) {
		map_say([NSString stringWithFormat:@"location: the first one, accurate to %.0f m", where.horizontalAccuracy]);
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
	map_say([NSString stringWithFormat:@"location: failed: %@ %ld (%@)", error.domain, (long)error.code,
	    error.localizedDescription]);
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

	[self sayLocation:@"the locate button"];
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
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
	    message:@"© OpenFreeMap © OpenMapTiles © OpenStreetMap contributors"
	    preferredStyle:UIAlertControllerStyleActionSheet];
	NSArray<NSArray<NSString *> *> *pages = @[
		@[ @"OpenStreetMap", @"https://www.openstreetmap.org/copyright" ],
		@[ @"OpenMapTiles", @"https://www.openmaptiles.org/" ],
		@[ @"OpenFreeMap", @"https://openfreemap.org/" ],
	];

	for (NSArray<NSString *> *page in pages) {
		[sheet addAction:[UIAlertAction actionWithTitle:page[0] style:UIAlertActionStyleDefault
		    handler:^(UIAlertAction *action) {
			[UIApplication.sharedApplication openURL:[NSURL URLWithString:page[1]] options:@{} completionHandler:nil];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = _credit;
	[self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark the map

- (void)mapViewDidChange:(MapView *)map
{
	double bearing = map.bearing;
	BOOL turned = bearing > 0.5 && bearing < 359.5;

	[_scale showMetresPerPoint:map.metresPerPoint zoom:map.zoom];
	if (_compass.hidden == turned) {
		_compass.hidden = !turned;
		[self showCovered];
	}
	/* (the compass's needle points to where north is on the screen) */
	_compass.imageView.transform = CGAffineTransformMakeRotation(-bearing * M_PI / 180);
}

- (void)mapViewDidChangeLook:(MapView *)map
{
	[self showLook];
}

#pragma mark the self-test

/* map://test?renderer=gl|metal|both&at=LATITUDE,LONGITUDE,ZOOM (the middle of Paris at 15 if not said) */
- (void)runTest:(NSURL *)url
{
	NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
	NSString *renderer = @"both";
	double latitude = 48.8566, longitude = 2.3522, zoom = 15;
	NSMutableArray<NSNumber *> *kinds = [NSMutableArray array];

	for (NSURLQueryItem *item in parts.queryItems) {
		if ([item.name isEqualToString:@"renderer"] && item.value.length > 0) {
			renderer = item.value;
		} else if ([item.name isEqualToString:@"style"]) {
			/* (the test's own; the settings' again when it is done) */
			_map.style = [item.value isEqualToString:@"dark"] ? MapStyleDark : [item.value isEqualToString:@"light"] ?
			    MapStyleLight : MapStyleSystem;
		} else if ([item.name isEqualToString:@"names"]) {
			/* (zh, local, en: the names' language for the test, as the settings would choose it) */
			_map.labelLanguage = language_for(item.value);
		} else if ([item.name isEqualToString:@"at"]) {
			NSArray<NSString *> *at = [item.value componentsSeparatedByString:@","];

			if (at.count >= 2) {
				latitude = at[0].doubleValue;
				longitude = at[1].doubleValue;
			}
			if (at.count >= 3) {
				zoom = at[2].doubleValue;
			}
		}
	}
	/* (each a renderer and its samples a pixel: "all" is both renderers with four and then with one) */
	if (![renderer isEqualToString:@"metal"]) {
		[kinds addObject:@(MapRendererKindGL * 10 + 4)];
	}
	if (![renderer isEqualToString:@"gl"]) {
		[kinds addObject:@(MapRendererKindMetal * 10 + 4)];
	}
	if ([renderer isEqualToString:@"all"]) {
		[kinds addObject:@(MapRendererKindGL * 10 + 1)];
		[kinds addObject:@(MapRendererKindMetal * 10 + 1)];
	}
	if (_testing) {
		NSLog(@"mapcheck: a self-test is running already");
		return;
	}
	_testing = YES;
	[self follow:FOLLOW_NONE];
	_placed = YES;
	[self dismissViewControllerAnimated:NO completion:nil];
	NSLog(@"mapcheck: self-test of %@ at %.5f, %.5f zoom %.1f; Metal %@", renderer, latitude, longitude, zoom,
	    map_metal_problem() ?: @"is there");
	[self test:kinds at:CLLocationCoordinate2DMake(latitude, longitude) zoom:zoom];
}

- (void)test:(NSMutableArray<NSNumber *> *)kinds at:(CLLocationCoordinate2D)where zoom:(double)zoom
{
	__weak MapController *weak = self;
	MapRendererKind kind;
	unsigned samples;

	if (kinds.count == 0) {
		NSLog(@"mapcheck: done");
		_testing = NO;
		/* (the map stays as the test left it, its style too, for a screenshot; the settings' renderer again) */
		{
			MapStyleChoice style = _map.style;
			enum style_language names = _map.labelLanguage;

			[self applySettings];
			_map.style = style;
			_map.labelLanguage = names;
		}
		return;
	}
	kind = (MapRendererKind)(kinds.firstObject.integerValue / 10);
	samples = (unsigned)(kinds.firstObject.integerValue % 10);
	[kinds removeObjectAtIndex:0];
	[_map testAt:where zoom:zoom renderer:kind samples:samples done:^(NSArray<NSString *> *lines) {
		for (NSString *line in lines) {
			map_say(line);
		}
		[weak test:kinds at:where zoom:zoom];
	}];
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
	_note = NSLocalizedString(@"Searching…", nil);
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
			me->_note = problem ?: (places.count == 0 ? NSLocalizedString(@"No places found", nil) : nil);
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

/* map://test...: the self-test (after a launch by the URL too: iOS calls this once the launch is done) */
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options
{
	if ([url.scheme isEqualToString:@"map"] && [url.host isEqualToString:@"test"]) {
		[(MapController *)self.window.rootViewController runTest:url];
		return YES;
	}
	/* map://settings: the app's own page in iOS's Settings (what Settings.bundle makes), as the system opens it */
	if ([url.scheme isEqualToString:@"map"] && [url.host isEqualToString:@"settings"]) {
		[application openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{}
		    completionHandler:^(BOOL opened) {
			NSLog(@"mapcheck: the Settings page %@", opened ? @"opened" : @"did NOT open");
		}];
		return YES;
	}
	return NO;
}

@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass(MapAppDelegate.class));
	}
}
