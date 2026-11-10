// MapLabels.m: see MapLabels.h.
#import <CoreText/CoreText.h>
#import "MapLabels.h"

#define MAX_LABELS      300             /* placed in one frame, at most */
#define DRAW_BUDGET     24              /* labels' texts drawn into the atlas in one frame, at most */
#define HALO            1.25            /* points of halo round the text */
#define WRAP            128.0           /* points: a place's name longer than this goes on more lines (three at most) */
#define MARGIN          3.0             /* points a label keeps from the screen's edges */
#define CELL            4.0             /* points: the side of a cell of the grid that says where labels are */
#define TABLE           32768           /* the atlas's table of labels: open addressing, a power of 2 */
#define MAX_ENTRIES     (TABLE / 2)
#define MAX_SHELVES     512

/* a label's text in the atlas: where (pixels, the border of one pixel round it not counted) and how big it is shown */
struct entry {
	uint64_t hash;
	uint16_t x, y, w, h;
	float points_w, points_h;
};

/* a row of the atlas the labels are put in, side by side */
struct shelf {
	uint16_t y, h, used;
};

struct candidate {
	const struct tess_label *label;
	float x, y;                     /* screen points */
	float angle;                    /* screen radians */
	float room;                     /* points */
	uint64_t order;                 /* what puts labels of the same priority in an order that does not change */
	int priority;
};

struct placed {
	uint64_t hash;
	float x, y;
};

static int
by_priority(const void *a, const void *b)
{
	const struct candidate *p = a, *q = b;

	if (p->priority != q->priority) {
		return p->priority < q->priority ? -1 : 1;
	}
	return p->order < q->order ? -1 : p->order > q->order ? 1 : 0;
}

static void
rgba_bytes(uint32_t rgba, uint8_t *out)
{
	unsigned a = rgba & 0xff;

	/* (premultiplied) */
	out[0] = (uint8_t)(((rgba >> 24) & 0xff) * a / 255);
	out[1] = (uint8_t)(((rgba >> 16) & 0xff) * a / 255);
	out[2] = (uint8_t)(((rgba >> 8) & 0xff) * a / 255);
	out[3] = (uint8_t)a;
}

@implementation MapLabels {
	struct entry *_entries;
	unsigned _entryCount;
	int32_t *_table;
	struct shelf _shelves[MAX_SHELVES];
	unsigned _shelfCount, _bottom;
	BOOL _full;

	CGSize _size;
	CGFloat _scale;
	double _zoom, _bearing;
	BOOL _dark;
	struct candidate *_candidates;
	unsigned _candidateCount, _candidateRoom;
	struct map_label_vertex *_vertices;
	unsigned _vertexCount;
	uint8_t *_grid;
	unsigned _gridW, _gridH, _gridRoom;
	struct placed *_placedList;
	NSMutableArray<MapTile *> *_tiles;
}

- (instancetype)init
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_entries = calloc(MAX_ENTRIES, sizeof(struct entry));
	_table = malloc(TABLE * sizeof(int32_t));
	_vertices = malloc(MAX_LABELS * 6 * sizeof(struct map_label_vertex));
	_placedList = malloc(MAX_LABELS * sizeof(struct placed));
	_tiles = [NSMutableArray array];
	if (_entries == NULL || _table == NULL || _vertices == NULL || _placedList == NULL) {
		return nil;
	}
	[self forgetAtlas];
	return self;
}

- (void)dealloc
{
	free(_entries);
	free(_table);
	free(_vertices);
	free(_placedList);
	free(_candidates);
	free(_grid);
}

- (void)forgetAtlas
{
	memset(_table, 0xff, TABLE * sizeof(int32_t));
	_entryCount = 0;
	_shelfCount = 0;
	_bottom = 0;
	_full = NO;
}

- (struct entry *)find:(uint64_t)hash
{
	for (uint32_t i = (uint32_t)hash & (TABLE - 1);; i = (i + 1) & (TABLE - 1)) {
		int32_t at = _table[i];

		if (at < 0) {
			return NULL;
		}
		if (_entries[at].hash == hash) {
			return &_entries[at];
		}
	}
}

/* a place of w x h pixels in the atlas, on a shelf about as tall; NO: the atlas is full */
- (BOOL)room:(unsigned)w height:(unsigned)h x:(unsigned *)x y:(unsigned *)y
{
	unsigned tall = (h + 3) & ~3u;

	for (unsigned i = 0; i < _shelfCount; i++) {
		struct shelf *s = &_shelves[i];

		if (s->h >= tall && s->h <= tall + tall / 4 + 4 && s->used + w <= MAP_ATLAS) {
			*x = s->used;
			*y = s->y;
			s->used += w;
			return YES;
		}
	}
	if (_shelfCount == MAX_SHELVES || _bottom + tall > MAP_ATLAS || w > MAP_ATLAS) {
		return NO;
	}
	_shelves[_shelfCount++] = (struct shelf){ (uint16_t)_bottom, (uint16_t)tall, (uint16_t)w };
	*x = 0;
	*y = _bottom;
	_bottom += tall;
	return YES;
}

/*
 * A name as it is shown: in the script of the Chinese asked for (name:zh, where the data has no name:zh-Hans or
 * -Hant, is often the other one, or both with a slash between, "臺北/台北"), through ICU's transforms.
 */
static NSString *
shown_name(NSString *text, enum style_language language)
{
	NSString *script = language == LANGUAGE_CHINESE ? @"Hant-Hans" : language == LANGUAGE_CHINESE_TRADITIONAL ?
	    @"Hans-Hant" : nil;
	NSArray<NSString *> *halves;

	if (script == nil || text.length == 0) {
		return text;
	}
	text = [text stringByApplyingTransform:script reverse:NO] ?: text;
	halves = [text componentsSeparatedByString:@"/"];
	if (halves.count == 2 && [halves[0] isEqualToString:halves[1]]) {
		text = halves[0];
	}
	return text;
}

/* the label's text and halo drawn (Core Text, through UIKit's string drawing) and put in the atlas */
- (struct entry *)draw:(const struct tess_label *)label renderer:(id<MapRenderer>)renderer
{
	const struct style_label_look *look = &style_label_looks[label->kind];
	NSString *text = shown_name([NSString stringWithUTF8String:label->text], _language);
	NSMutableParagraphStyle *centred = [NSMutableParagraphStyle new];
	UIFont *font;
	NSDictionary *fill, *halo;
	CGSize size;
	CGFloat pw, ph;
	BOOL wrapped = NO;
	unsigned w, h, x, y;
	uint8_t *grey, *out;
	CGColorSpaceRef space;
	struct entry *e;

	if (text == nil || _entryCount == MAX_ENTRIES) {
		_full = _entryCount == MAX_ENTRIES;
		return NULL;
	}
	font = [UIFont systemFontOfSize:look->size weight:look->bold ? UIFontWeightSemibold : UIFontWeightMedium];
	centred.alignment = NSTextAlignmentCenter;
	centred.lineBreakMode = NSLineBreakByWordWrapping;
	fill = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor,
	    NSParagraphStyleAttributeName: centred };
	/* (a stroke is centred on the glyphs' outlines: twice the halo wide, as a percentage of the font's size) */
	halo = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor,
	    NSStrokeColorAttributeName: UIColor.whiteColor, NSStrokeWidthAttributeName: @(-200.0 * HALO / look->size),
	    NSParagraphStyleAttributeName: centred };
	size = [text sizeWithAttributes:fill];
	/* (a long name of a place on lines of at most WRAP points; a road's name stays on its line, along the road) */
	if (size.width > WRAP && label->room == 0) {
		size = [text boundingRectWithSize:CGSizeMake(WRAP, 3.2 * font.lineHeight)
		    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:fill
		    context:nil].size;
		wrapped = YES;
	}
	pw = ceil(size.width + 2 * HALO);
	ph = ceil(size.height + 2 * HALO);
	if (pw > 500 || pw < 1) {
		return NULL;
	}
	/* (and a border of a pixel, empty: the sampler's filter never reaches a neighbour) */
	w = (unsigned)ceil(pw * _scale) + 2;
	h = (unsigned)ceil(ph * _scale) + 2;
	if (![self room:w height:h x:&x y:&y]) {
		_full = YES;
		return NULL;
	}
	grey = calloc((size_t)w * h, 2);
	out = calloc((size_t)w * h, 2);
	if (grey == NULL || out == NULL) {
		free(grey);
		free(out);
		return NULL;
	}
	space = CGColorSpaceCreateDeviceGray();
	for (int pass = 0; pass < 2; pass++) {
		CGContextRef context = CGBitmapContextCreate(grey + (size_t)pass * w * h, w, h, 8, w, space,
		    (CGBitmapInfo)kCGImageAlphaNone);

		if (context == NULL) {
			continue;
		}
		/* (UIKit's way up: y down from the top, in points, inside the border) */
		CGContextTranslateCTM(context, 1, h - 1);
		CGContextScaleCTM(context, _scale, -_scale);
		UIGraphicsPushContext(context);
		if (wrapped) {
			[text drawWithRect:CGRectMake(HALO, HALO, size.width, size.height)
			    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
			    attributes:pass == 0 ? fill : halo context:nil];
		} else {
			[text drawAtPoint:CGPointMake(HALO, HALO) withAttributes:pass == 0 ? fill : halo];
		}
		UIGraphicsPopContext();
		CGContextRelease(context);
	}
	CGColorSpaceRelease(space);
	for (size_t i = 0; i < (size_t)w * h; i++) {
		out[2 * i] = grey[i];
		out[2 * i + 1] = grey[(size_t)w * h + i];
	}
	[renderer atlasReplace:CGRectMake(x, y, w, h) bytes:out stride:(size_t)w * 2];
	free(grey);
	free(out);

	e = &_entries[_entryCount];
	e->hash = label->hash;
	e->x = (uint16_t)(x + 1);
	e->y = (uint16_t)(y + 1);
	e->w = (uint16_t)(w - 2);
	e->h = (uint16_t)(h - 2);
	e->points_w = (float)((w - 2) / _scale);
	e->points_h = (float)((h - 2) / _scale);
	for (uint32_t i = (uint32_t)label->hash & (TABLE - 1);; i = (i + 1) & (TABLE - 1)) {
		if (_table[i] < 0) {
			_table[i] = (int32_t)_entryCount;
			break;
		}
	}
	_entryCount++;
	return e;
}

- (void)beginFrame:(CGSize)size scale:(CGFloat)scale zoom:(double)zoom bearing:(double)bearing dark:(BOOL)dark
    covered:(NSArray<NSValue *> *)covered
{
	unsigned gw = (unsigned)ceil(size.width / CELL) + 1, gh = (unsigned)ceil(size.height / CELL) + 1;

	if (scale != _scale || _full) {
		/* (another scale draws every text anew; a full atlas is begun again, emptied) */
		[self forgetAtlas];
	}
	_size = size;
	_scale = scale;
	_zoom = zoom;
	_bearing = bearing;
	_dark = dark;
	_candidateCount = 0;
	_vertexCount = 0;
	_placed = 0;
	_pending = NO;
	[_tiles removeAllObjects];
	if (gw * gh > _gridRoom) {
		free(_grid);
		_grid = malloc(gw * gh);
		_gridRoom = _grid != NULL ? gw * gh : 0;
	}
	_gridW = _grid != NULL ? gw : 0;
	_gridH = _grid != NULL ? gh : 0;
	if (_grid != NULL) {
		memset(_grid, 0, gw * gh);
		/* (what covers the map is taken before any label is placed) */
		for (NSValue *rect in covered) {
			[self clear:CGRectInset(rect.CGRectValue, -2, -2) take:YES];
		}
	}
}

- (void)addTile:(MapTile *)tile transform:(CGAffineTransform)t clip:(const float *)clip
{
	const struct tess_tile *mesh = tile.mesh;
	double scale = hypot(t.a, t.b), turn = atan2(t.b, t.a);

	[_tiles addObject:tile];
	for (uint32_t i = 0; i < mesh->label_count; i++) {
		const struct tess_label *l = &mesh->labels[i];
		struct candidate *c;
		double x, y;

		if (l->x < clip[0] || l->y < clip[1] || l->x >= clip[2] || l->y >= clip[3] ||
		    !style_label_shown(l->kind, l->priority, _zoom)) {
			continue;
		}
		x = t.a * l->x + t.c * l->y + t.tx;
		y = t.b * l->x + t.d * l->y + t.ty;
		if (x < -300 || y < -100 || x > _size.width + 300 || y > _size.height + 100) {
			continue;
		}
		if (_candidateCount == _candidateRoom) {
			unsigned room = _candidateRoom ? 2 * _candidateRoom : 1024;
			struct candidate *grown = realloc(_candidates, room * sizeof(*grown));

			if (grown == NULL) {
				return;
			}
			_candidates = grown;
			_candidateRoom = room;
		}
		c = &_candidates[_candidateCount++];
		c->label = l;
		c->x = (float)x;
		c->y = (float)y;
		c->angle = 0;
		c->room = 0;
		if (l->room > 0) {
			double angle = l->angle + turn;

			/* (turned with the map, and kept readable again) */
			angle = remainder(angle, 2 * M_PI);
			if (angle > M_PI / 2) {
				angle -= M_PI;
			} else if (angle < -M_PI / 2) {
				angle += M_PI;
			}
			c->angle = (float)angle;
			c->room = (float)(l->room * scale);
		}
		c->priority = l->priority;
		c->order = tile.key * 0x9e3779b97f4a7c15ull + i;
	}
}

/* whether a box (points) is clear of the labels placed; marks it taken if `take` */
- (BOOL)clear:(CGRect)box take:(BOOL)take
{
	long x0 = (long)floor(CGRectGetMinX(box) / CELL), x1 = (long)floor(CGRectGetMaxX(box) / CELL);
	long y0 = (long)floor(CGRectGetMinY(box) / CELL), y1 = (long)floor(CGRectGetMaxY(box) / CELL);

	x0 = MAX(0, x0);
	y0 = MAX(0, y0);
	x1 = MIN((long)_gridW - 1, x1);
	y1 = MIN((long)_gridH - 1, y1);
	for (long y = y0; y <= y1; y++) {
		uint8_t *row = _grid + y * _gridW;

		for (long x = x0; x <= x1; x++) {
			if (take) {
				row[x] = 1;
			} else if (row[x]) {
				return NO;
			}
		}
	}
	return YES;
}

- (const struct map_label_vertex *)finishFor:(id<MapRenderer>)renderer count:(unsigned *)count
{
	unsigned budget = DRAW_BUDGET;

	qsort(_candidates, _candidateCount, sizeof(struct candidate), by_priority);
	for (unsigned i = 0; i < _candidateCount && _placed < MAX_LABELS && _grid != NULL; i++) {
		const struct candidate *c = &_candidates[i];
		const struct tess_label *l = c->label;
		const struct style_label_look *look = &style_label_looks[l->kind];
		struct entry *e = [self find:l->hash];
		double cs, sn, hw, hh, bw, bh, near;
		CGRect box;
		BOOL duplicate = NO;
		uint8_t colour[4], halo[4];
		struct map_label_vertex *v;

		if (e == NULL) {
			if (budget == 0 || _full) {
				_pending = YES;
				continue;
			}
			budget--;
			e = [self draw:l renderer:renderer];
			if (e == NULL) {
				continue;
			}
		}
		hw = e->points_w / 2;
		hh = e->points_h / 2;
		/* (a road's name that is longer than the stretch it lies on is not shown there) */
		if (l->room > 0 && 2 * hw > c->room + 8) {
			continue;
		}
		cs = cos(c->angle);
		sn = sin(c->angle);
		bw = fabs(hw * cs) + fabs(hh * sn);
		bh = fabs(hw * sn) + fabs(hh * cs);
		box = CGRectMake(c->x - bw - 1, c->y - bh - 1, 2 * bw + 2, 2 * bh + 2);
		/* (all of it on the screen, or none: a name cut by the edge is no use) */
		if (box.origin.x < MARGIN || box.origin.y < MARGIN || CGRectGetMaxX(box) > _size.width - MARGIN ||
		    CGRectGetMaxY(box) > _size.height - MARGIN) {
			continue;
		}
		/* (the same name again nearby: a road's, in the next tile along it) */
		near = l->room > 0 ? fmax(250, 3 * hw) : 120;
		for (unsigned k = 0; k < _placed; k++) {
			if (_placedList[k].hash == l->hash && hypot(_placedList[k].x - c->x, _placedList[k].y - c->y) < near) {
				duplicate = YES;
				break;
			}
		}
		if (duplicate || ![self clear:box take:NO]) {
			continue;
		}
		[self clear:box take:YES];
		_placedList[_placed] = (struct placed){ l->hash, c->x, c->y };
		_placed++;

		rgba_bytes(look->colour[_dark], colour);
		rgba_bytes(look->halo[_dark], halo);
		{
			const double corners[4][2] = { { -hw, -hh }, { hw, -hh }, { -hw, hh }, { hw, hh } };
			const float uv[4][2] = {
				{ (float)e->x / MAP_ATLAS, (float)e->y / MAP_ATLAS },
				{ (float)(e->x + e->w) / MAP_ATLAS, (float)e->y / MAP_ATLAS },
				{ (float)e->x / MAP_ATLAS, (float)(e->y + e->h) / MAP_ATLAS },
				{ (float)(e->x + e->w) / MAP_ATLAS, (float)(e->y + e->h) / MAP_ATLAS },
			};
			static const int order[6] = { 0, 1, 2, 1, 3, 2 };
			double ox = c->x, oy = c->y;

			/* (level text on whole pixels, sharp) */
			if (c->angle == 0) {
				ox = round((ox - hw) * _scale) / _scale + hw;
				oy = round((oy - hh) * _scale) / _scale + hh;
			}
			v = &_vertices[_vertexCount];
			for (int k = 0; k < 6; k++) {
				const double *p = corners[order[k]];
				double sx = ox + p[0] * cs - p[1] * sn, sy = oy + p[0] * sn + p[1] * cs;

				v[k].x = (float)(sx / _size.width * 2 - 1);
				v[k].y = (float)(1 - sy / _size.height * 2);
				v[k].u = uv[order[k]][0];
				v[k].v = uv[order[k]][1];
				memcpy(v[k].colour, colour, 4);
				memcpy(v[k].halo, halo, 4);
			}
			_vertexCount += 6;
		}
	}
	*count = _vertexCount;
	return _vertices;
}

@end
