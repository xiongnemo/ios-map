// MapSource.m: see MapSource.h. OpenFreeMap (openfreemap.org) serves OpenStreetMap's data as OpenMapTiles' vector tiles,
// with no key and no account; its terms ask for what any tile server's do -- only the tiles being looked at, no bulk
// downloading, an application that says who it is -- and for the attribution main.m shows.
#import <UIKit/UIKit.h>
#include <zlib.h>

#import "MapSource.h"

static NSString *const tilejson_url = @"https://tiles.openfreemap.org/planet";
static NSString *const saved_template = @"TileTemplate", *const saved_template_at = @"TileTemplateAt";

#define DOWNLOADS       6               /* tiles downloading at once, as a browser would */
#define MADE_BYTES      (160 << 20)     /* tiles made kept in memory: their meshes, counted twice (the GPU has a copy) */
#define DISK_BYTES      (80 << 20)      /* the downloads on disk: not much, the data disk of the K40 port is RAM */
#define MEMORY_BYTES    (4 << 20)       /* the downloads in the URL cache's memory (the tiles made are what counts) */
#define RETRY_AFTER     15.0            /* seconds before a tile that failed is asked for again (doubling each time) */
#define TEMPLATE_DAYS   1.0             /* how long the TileJSON's answer is good for: its URLs name a version */

NSString *
user_agent(void)
{
	static NSString *agent;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"2.0";

		agent = [NSString stringWithFormat:@"Map/%@ (iOS; https://github.com/xiongnemo/ios-map)", version];
	});
	return agent;
}

@implementation MapTile {
	struct tess_tile _mesh;
}

- (instancetype)initWithKey:(uint64_t)key mesh:(struct tess_tile *)mesh
{
	self = [super init];
	if (self != nil) {
		_key = key;
		_mesh = *mesh;
		_bytes = _mesh.fills.vertex_count * sizeof(struct fill_vertex) +
		    _mesh.lines.vertex_count * sizeof(struct line_vertex) +
		    (_mesh.fills.index_count + _mesh.lines.index_count) * sizeof(uint32_t) +
		    _mesh.label_count * (sizeof(struct tess_label) + 24) + 1024;
		memset(mesh, 0, sizeof(*mesh));
	}
	return self;
}

- (const struct tess_tile *)mesh
{
	return &_mesh;
}

- (void)dealloc
{
	tess_free(&_mesh);
}

@end

/* gzip's bytes inflated (the server may send a tile as the gzip file it keeps, not as a gzip transfer); nil: not gzip */
static NSData *
gunzipped(NSData *data)
{
	const uint8_t *bytes = data.bytes;
	NSMutableData *out;
	z_stream z;
	int status = Z_OK;

	if (data.length < 18 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
		return nil;
	}
	out = [NSMutableData dataWithLength:data.length * 4];
	memset(&z, 0, sizeof(z));
	if (inflateInit2(&z, 16 + MAX_WBITS) != Z_OK) {
		return nil;
	}
	z.next_in = (Bytef *)bytes;
	z.avail_in = (uInt)data.length;
	while (status == Z_OK) {
		if (z.total_out >= out.length) {
			if (out.length > (64u << 20)) {
				break;          /* (no tile is that big) */
			}
			out.length *= 2;
		}
		z.next_out = (Bytef *)out.mutableBytes + z.total_out;
		z.avail_out = (uInt)(out.length - z.total_out);
		status = inflate(&z, Z_NO_FLUSH);
	}
	out.length = z.total_out;
	inflateEnd(&z);
	return status == Z_STREAM_END ? out : nil;
}

@implementation MapSource {
	NSURLSession *_session;
	NSString *_template;            /* the tiles' URL, {z} {x} {y} in it; nil until the TileJSON says */
	BOOL _custom, _askingTemplate;
	double _templateFailures;
	NSCache<NSNumber *, MapTile *> *_tiles;
	NSHashTable<MapTile *> *_every;
	NSOperationQueue *_makers;
	NSMutableDictionary<NSNumber *, NSURLSessionDataTask *> *_running;
	NSMutableArray<NSNumber *> *_queue;
	NSMutableDictionary<NSNumber *, NSNumber *> *_failedAt, *_failures;
	NSUInteger _serial;             /* counts forget's: a tile made before the last one is not kept */
	BOOL _retrying;
}

- (instancetype)init
{
	NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
	NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	NSString *custom = [defaults stringForKey:@"TileURL"];

	self = [super init];
	if (self == nil) {
		return nil;
	}
	config.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:MEMORY_BYTES diskCapacity:DISK_BYTES
	    directoryURL:[caches URLByAppendingPathComponent:@"VectorTiles" isDirectory:YES]];
	config.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
	config.HTTPMaximumConnectionsPerHost = DOWNLOADS;
	config.HTTPAdditionalHeaders = @{ @"User-Agent": user_agent() };
	config.timeoutIntervalForRequest = 20;
	_session = [NSURLSession sessionWithConfiguration:config];
	_tiles = [NSCache new];
	_tiles.totalCostLimit = MADE_BYTES;
	_every = [NSHashTable weakObjectsHashTable];
	_makers = [NSOperationQueue new];
	_makers.maxConcurrentOperationCount = 2;
	_makers.qualityOfService = NSQualityOfServiceUserInitiated;
	_running = [NSMutableDictionary new];
	_queue = [NSMutableArray new];
	_failedAt = [NSMutableDictionary new];
	_failures = [NSMutableDictionary new];
	if (custom.length > 0) {
		/* (a server of one's own, as the defaults say: `defaults write com.anzupop.com.ios.map TileURL ...`) */
		_template = custom;
		_custom = YES;
	} else {
		_template = [defaults stringForKey:saved_template];
		if (_template == nil || CFAbsoluteTimeGetCurrent() - [defaults doubleForKey:saved_template_at] >
		    TEMPLATE_DAYS * 86400) {
			[self askTemplate];
		}
	}
	return self;
}

#pragma mark the TileJSON

- (void)askTemplate
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:tilejson_url]];
	__weak MapSource *weak = self;

	if (_askingTemplate || _custom) {
		return;
	}
	_askingTemplate = YES;
	request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
	[[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		NSString *template = nil, *problem = nil;
		NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;

		if (error != nil) {
			problem = [NSString stringWithFormat:@"TileJSON: %@", error.localizedDescription];
		} else if (status != 200) {
			problem = [NSString stringWithFormat:@"TileJSON: the server answered %ld", (long)status];
		} else {
			id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
			id tiles = [json isKindOfClass:NSDictionary.class] ? json[@"tiles"] : nil;

			if ([tiles isKindOfClass:NSArray.class] && [tiles count] > 0 && [tiles[0] isKindOfClass:NSString.class] &&
			    [tiles[0] containsString:@"{z}"]) {
				template = tiles[0];
			} else {
				problem = @"TileJSON: no tile URL in it";
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[weak gotTemplate:template problem:problem];
		});
	}] resume];
}

- (void)gotTemplate:(NSString *)template problem:(NSString *)problem
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	__weak MapSource *weak = self;

	_askingTemplate = NO;
	if (template != nil) {
		_template = template;
		_templateFailures = 0;
		[defaults setObject:template forKey:saved_template];
		[defaults setDouble:CFAbsoluteTimeGetCurrent() forKey:saved_template_at];
		NSLog(@"mapcheck: tiles from %@", template);
		[self pump];
		return;
	}
	_problem = problem;
	NSLog(@"mapcheck: %@", problem);
	/* (an old answer is still used meanwhile; asked again after 5, 10, 20 ... seconds, at most 5 minutes) */
	_templateFailures++;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmin(300, 5 * exp2(_templateFailures - 1)) * NSEC_PER_SEC)),
	    dispatch_get_main_queue(), ^{
		[weak askTemplate];
	});
}

#pragma mark the tiles

- (MapTile *)tileFor:(uint64_t)key
{
	return [_tiles objectForKey:@(key)];
}

- (void)forEachTile:(void (^)(MapTile *tile))block
{
	/* (the cache cannot be gone through; this table holds the same tiles, weakly) */
	for (MapTile *tile in _every.allObjects) {
		block(tile);
	}
}

- (BOOL)failed:(uint64_t)key
{
	NSNumber *k = @(key), *when = _failedAt[k];
	double wait;

	if (when == nil) {
		return NO;
	}
	/* (each failure in a row doubles the wait, up to five minutes: a server that refuses is not asked every second) */
	wait = fmin(RETRY_AFTER * exp2(_failures[k].intValue - 1), 300);
	return CFAbsoluteTimeGetCurrent() - when.doubleValue < wait;
}

- (void)want:(NSArray<NSNumber *> *)keys
{
	NSSet<NSNumber *> *wanted = [NSSet setWithArray:keys];

	for (NSNumber *key in _running.allKeys) {
		if (![wanted containsObject:key]) {
			[_running[key] cancel];
			[_running removeObjectForKey:key];
		}
	}
	[_queue removeAllObjects];
	for (NSNumber *key in keys) {
		if (_running[key] == nil && [_tiles objectForKey:key] == nil && ![self failed:key.unsignedLongLongValue]) {
			[_queue addObject:key];
		}
	}
	[self pump];
}

- (void)pump
{
	if (_template == nil) {
		[self askTemplate];
		return;
	}
	while (_running.count < DOWNLOADS && _queue.count > 0) {
		NSNumber *key = _queue.firstObject;

		[_queue removeObjectAtIndex:0];
		if (_running[key] == nil && [_tiles objectForKey:key] == nil) {
			[self start:key.unsignedLongLongValue];
		}
	}
}

- (NSURL *)urlFor:(uint64_t)tile
{
	NSString *url = _template;

	url = [url stringByReplacingOccurrencesOfString:@"{z}" withString:[NSString stringWithFormat:@"%d", tile_z(tile)]];
	url = [url stringByReplacingOccurrencesOfString:@"{x}" withString:[NSString stringWithFormat:@"%ld", tile_x(tile)]];
	url = [url stringByReplacingOccurrencesOfString:@"{y}" withString:[NSString stringWithFormat:@"%ld", tile_y(tile)]];
	return [NSURL URLWithString:url];
}

- (void)start:(uint64_t)tile
{
	NSURL *url = [self urlFor:tile];
	NSUInteger serial = _serial;
	enum style_language language = _language;
	NSURLSessionDataTask *task;
	__block __weak NSURLSessionDataTask *weakTask = nil;
	__weak MapSource *weak = self;
	NSOperationQueue *makers = _makers;

	if (url == nil) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[weak finished:tile task:nil made:nil problem:@"not a URL" cancelled:NO serial:serial];
		});
		return;
	}
	_downloads++;
	task = [_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		NSURLSessionDataTask *done = weakTask;
		NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;

		if (error != nil || (status != 200 && status != 204)) {
			BOOL cancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
			NSString *problem = error != nil ? error.localizedDescription :
			    [NSString stringWithFormat:@"the server answered %ld", (long)status];

			dispatch_async(dispatch_get_main_queue(), ^{
				[weak finished:tile task:done made:nil problem:problem cancelled:cancelled serial:serial];
			});
			return;
		}
		[makers addOperationWithBlock:^{
			NSData *raw = gunzipped(data) ?: data;
			struct tess_tile mesh;
			char why[200] = "";
			MapTile *made = nil;
			NSString *problem = nil;

			/* (an empty answer is a tile with nothing on it: open sea) */
			if (raw.length == 0) {
				memset(&mesh, 0, sizeof(mesh));
				mesh.extent = 4096;
				made = [[MapTile alloc] initWithKey:tile mesh:&mesh];
			} else if (tess_make(raw.bytes, raw.length, tile_z(tile), language, &mesh, why, sizeof(why)) == 0) {
				made = [[MapTile alloc] initWithKey:tile mesh:&mesh];
			} else {
				problem = [NSString stringWithFormat:@"tile %d/%ld/%ld: %s", tile_z(tile), tile_x(tile), tile_y(tile),
				    why];
			}
			dispatch_async(dispatch_get_main_queue(), ^{
				[weak finished:tile task:done made:made problem:problem cancelled:NO serial:serial];
			});
		}];
	}];
	weakTask = task;
	_running[@(tile)] = task;
	[task resume];
}

- (void)finished:(uint64_t)tile task:(NSURLSessionDataTask *)task made:(MapTile *)made problem:(NSString *)problem
    cancelled:(BOOL)cancelled serial:(NSUInteger)serial
{
	NSNumber *key = @(tile);

	/* (only if it is still this download: a cancelled one may end after the same tile was asked for again) */
	if (task == nil || _running[key] == task) {
		[_running removeObjectForKey:key];
	}
	if (serial != _serial) {
		[self pump];
		return;
	}
	if (made != nil) {
		[_tiles setObject:made forKey:key cost:2 * made.bytes];
		[_every addObject:made];
		[_failedAt removeObjectForKey:key];
		[_failures removeObjectForKey:key];
		_made++;
		[_delegate sourceTileArrived:tile];
	} else if (!cancelled) {
		_problem = problem;
		NSLog(@"mapcheck: tile %d/%ld/%ld failed: %@", tile_z(tile), tile_x(tile), tile_y(tile), problem);
		_failedAt[key] = @(CFAbsoluteTimeGetCurrent());
		_failures[key] = @(_failures[key].intValue + 1);
		[_delegate sourceTileFailed:tile];
		[self retryLater];
	}
	[self pump];
}

- (void)retryLater
{
	__weak MapSource *weak = self;

	if (_retrying) {
		return;
	}
	_retrying = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((RETRY_AFTER + 0.5) * NSEC_PER_SEC)),
	    dispatch_get_main_queue(), ^{
		MapSource *me = weak;

		if (me != nil) {
			me->_retrying = NO;
			[me->_delegate sourceMayRetry];
		}
	});
}

- (void)setLanguage:(enum style_language)language
{
	if (language != _language) {
		_language = language;
		[self forget];
	}
}

- (void)forget
{
	_serial++;
	for (NSURLSessionDataTask *task in _running.objectEnumerator) {
		[task cancel];
	}
	[_running removeAllObjects];
	[_queue removeAllObjects];
	[_tiles removeAllObjects];
}

@end
