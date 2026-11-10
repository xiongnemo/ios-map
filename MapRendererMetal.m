// MapRendererMetal.m: the map drawn with Metal into a CAMetalLayer: four samples a pixel in a texture that never leaves
// the GPU's tile memory (memoryless), resolved into the drawable. The shaders are those of MapRendererGL.m in the Metal
// shading language, compiled when the renderer is made. See MapRenderer.h.
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

#import "MapRenderer.h"

_Static_assert(B_COUNT <= 32, "the shaders' tables have 32 buckets");

static NSString *const shader_source = @
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"\n"
	"struct Pass { float4 colour[32]; float width[32]; };\n"
	"struct Frame { float2x2 extrude; float pixel; float pad; };\n"
	"struct Piece { float2 c0; float2 c1; float2 c2; float2 pad; float4 clip; };\n"
	"\n"
	"/* (the clip test is written out in each fragment function, not a function of its own: the K40 port's driver before\n"
	"   hk 11d331a took what such a function left behind for a store to [[depth]], and refused the pipeline) */\n"
	"#define OUTSIDE(t, c) ((t).x < (c).x || (t).y < (c).y || (t).x > (c).z || (t).y > (c).w)\n"
	"\n"
	"struct FillIn { float2 pos [[attribute(0)]]; float4 bucket [[attribute(1)]]; };\n"
	"struct FillOut { float4 position [[position]]; float2 tile; float4 colour; };\n"
	"\n"
	"vertex FillOut v_fill(FillIn in [[stage_in]], constant Pass &pass [[buffer(1)]],\n"
	"                      constant Piece &piece [[buffer(2)]]) {\n"
	"    FillOut o;\n"
	"    float2 p = in.pos * 32767.0;\n"
	"    float4 c = pass.colour[int(in.bucket.x * 255.0 + 0.5)];\n"
	"    o.tile = p;\n"
	"    o.colour = c;\n"
	"    /* (a bucket the pass leaves out: all its corners at one place off the screen, nothing to fill) */\n"
	"    o.position = c.a > 0.0 ? float4(piece.c0 * p.x + piece.c1 * p.y + piece.c2, 0.0, 1.0) : float4(2.0, 2.0, 2.0, 1.0);\n"
	"    return o;\n"
	"}\n"
	"\n"
	"fragment float4 f_fill(FillOut in [[stage_in]], constant Piece &piece [[buffer(0)]]) {\n"
	"    if (OUTSIDE(in.tile, piece.clip)) discard_fragment();\n"
	"    return in.colour;\n"
	"}\n"
	"\n"
	"struct LineIn { float4 pos [[attribute(0)]]; float2 rest [[attribute(1)]]; };\n"
	"struct LineOut { float4 position [[position]]; float2 tile; float4 colour; float across; float width; };\n"
	"\n"
	"/* (the line passes in one draw, an instance each: instances are drawn in their order, the passes' order) */\n"
	"vertex LineOut v_line(LineIn in [[stage_in]], uint instance [[instance_id]], constant Pass *passes [[buffer(1)]],\n"
	"                      constant Piece &piece [[buffer(2)]], constant Frame &frame [[buffer(3)]]) {\n"
	"    constant Pass &pass = passes[instance];\n"
	"    LineOut o;\n"
	"    float2 p = in.pos.xy * 32767.0, e = in.pos.zw * (32767.0 / 4096.0);\n"
	"    int b = int(in.rest.y * 127.0 + 0.5);\n"
	"    float4 c = pass.colour[b];\n"
	"    float w = pass.width[b], opacity = 1.0, drawn;\n"
	"    /* (thinner than a pixel: a pixel wide and as much fainter) */\n"
	"    if (w < 0.5 * frame.pixel) {\n"
	"        opacity = w / (0.5 * frame.pixel);\n"
	"        w = 0.5 * frame.pixel;\n"
	"    }\n"
	"    /* (half a pixel more on each side, for the soft edge to fade out over) */\n"
	"    drawn = w + 0.5 * frame.pixel;\n"
	"    o.tile = p;\n"
	"    o.colour = c * opacity;\n"
	"    o.across = in.rest.x;\n"
	"    o.width = drawn / frame.pixel;\n"
	"    o.position = c.a > 0.0 ? float4(piece.c0 * p.x + piece.c1 * p.y + piece.c2 + frame.extrude * (e * drawn), 0.0, 1.0) :\n"
	"        float4(2.0, 2.0, 2.0, 1.0);\n"
	"    return o;\n"
	"}\n"
	"\n"
	"fragment float4 f_line(LineOut in [[stage_in]], constant Piece &piece [[buffer(0)]]) {\n"
	"    if (OUTSIDE(in.tile, piece.clip)) discard_fragment();\n"
	"    return in.colour * clamp((1.0 - abs(in.across)) * in.width, 0.0, 1.0);\n"
	"}\n"
	"\n"
	"struct LabelIn { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; float4 colour [[attribute(2)]];\n"
	"                 float4 halo [[attribute(3)]]; };\n"
	"struct LabelOut { float4 position [[position]]; float2 uv; float4 colour; float4 halo; };\n"
	"\n"
	"vertex LabelOut v_label(LabelIn in [[stage_in]]) {\n"
	"    LabelOut o;\n"
	"    o.position = float4(in.pos, 0.0, 1.0);\n"
	"    o.uv = in.uv;\n"
	"    o.colour = in.colour;\n"
	"    o.halo = in.halo;\n"
	"    return o;\n"
	"}\n"
	"\n"
	"/* (the atlas is RG8: the text in R, the halo in G) */\n"
	"fragment float4 f_label(LabelOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]]) {\n"
	"    float2 t = atlas.sample(s, in.uv).rg;\n"
	"    float text = t.x * in.colour.a;\n"
	"    return in.colour * t.x + in.halo * (t.y * (1.0 - text));\n"
	"}\n";

/* the shaders' structures, as C lays them out (MSL: float2x2 is two float2 columns, float4 is aligned on 16) */
struct gpu_pass {
	float colour[32][4];
	float width[32];
};

struct gpu_frame {
	float extrude[4];
	float pixel, pad;
};

struct gpu_piece {
	float c0[2], c1[2], c2[2], pad[2];
	float clip[4];
};

_Static_assert(sizeof(struct gpu_pass) == 640 && sizeof(struct gpu_frame) == 24 && sizeof(struct gpu_piece) == 48,
    "the shaders' structures");

@interface MapMetalTile : NSObject {
@public
	id<MTLBuffer> fillVertices, fillIndices, lineVertices, lineIndices;
	NSUInteger fillCount, lineCount;
}
@end

@implementation MapMetalTile
@end

@interface MapRendererMetal : NSObject <MapRenderer>
@end

@implementation MapRendererMetal {
	id<MTLDevice> _device;
	id<MTLCommandQueue> _queue;
	CAMetalLayer *_layer;
	id<MTLRenderPipelineState> _fill, _line, _label;
	id<MTLTexture> _atlas, _msaa;
	id<MTLSamplerState> _sampler;
	NSUInteger _samples;
	NSString *_name;
	void (^_capture)(const uint8_t *, size_t, size_t);
	unsigned _frames;
	CFTimeInterval _waiting, _encoding, _committing;
}

- (NSString *)timing
{
	NSString *said = [NSString stringWithFormat:@"%.1f ms a frame in -nextDrawable, %.1f encoding, %.1f in -commit",
	    _frames ? 1000 * _waiting / _frames : 0, _frames ? 1000 * _encoding / _frames : 0,
	    _frames ? 1000 * _committing / _frames : 0];

	_frames = 0;
	_waiting = _encoding = _committing = 0;
	return said;
}

static MTLVertexDescriptor *
vertex_descriptor(const MTLVertexFormat *formats, const NSUInteger *offsets, unsigned count, NSUInteger stride)
{
	MTLVertexDescriptor *d = [MTLVertexDescriptor vertexDescriptor];

	for (unsigned i = 0; i < count; i++) {
		d.attributes[i].format = formats[i];
		d.attributes[i].offset = offsets[i];
		d.attributes[i].bufferIndex = 0;
	}
	d.layouts[0].stride = stride;
	d.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
	return d;
}

- (id<MTLRenderPipelineState>)pipeline:(id<MTLLibrary>)library vertex:(NSString *)vertex fragment:(NSString *)fragment
    layout:(MTLVertexDescriptor *)layout why:(NSString **)why
{
	MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
	MTLRenderPipelineColorAttachmentDescriptor *colour = p.colorAttachments[0];
	NSError *error = nil;
	id<MTLRenderPipelineState> state;

	p.vertexFunction = [library newFunctionWithName:vertex];
	p.fragmentFunction = [library newFunctionWithName:fragment];
	p.vertexDescriptor = layout;
	p.rasterSampleCount = _samples;
	colour.pixelFormat = MTLPixelFormatBGRA8Unorm;
	colour.blendingEnabled = YES;
	colour.sourceRGBBlendFactor = colour.sourceAlphaBlendFactor = MTLBlendFactorOne;
	colour.destinationRGBBlendFactor = colour.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	state = [_device newRenderPipelineStateWithDescriptor:p error:&error];
	if (state == nil) {
		*why = [NSString stringWithFormat:@"the %@ pipeline was refused: %@", vertex,
		    error.localizedDescription ?: @"no reason given"];
	}
	return state;
}

- (instancetype)initSamples:(unsigned)samples why:(NSString **)why
{
	static const MTLVertexFormat fill_formats[] = { MTLVertexFormatShort2Normalized, MTLVertexFormatUChar4Normalized };
	static const NSUInteger fill_offsets[] = { offsetof(struct fill_vertex, x), offsetof(struct fill_vertex, bucket) };
	static const MTLVertexFormat line_formats[] = { MTLVertexFormatShort4Normalized, MTLVertexFormatChar2Normalized };
	static const NSUInteger line_offsets[] = { offsetof(struct line_vertex, x), offsetof(struct line_vertex, across) };
	static const MTLVertexFormat label_formats[] = { MTLVertexFormatFloat2, MTLVertexFormatFloat2,
	    MTLVertexFormatUChar4Normalized, MTLVertexFormatUChar4Normalized };
	static const NSUInteger label_offsets[] = { offsetof(struct map_label_vertex, x), offsetof(struct map_label_vertex, u),
	    offsetof(struct map_label_vertex, colour), offsetof(struct map_label_vertex, halo) };
	NSError *error = nil;
	id<MTLLibrary> library;

	_Static_assert(offsetof(struct line_vertex, bucket) == offsetof(struct line_vertex, across) + 1 &&
	    offsetof(struct line_vertex, ex) == offsetof(struct line_vertex, x) + 4, "a line vertex as the shader reads it");
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_device = MTLCreateSystemDefaultDevice();
	if (_device == nil) {
		*why = @"Metal is not available to this app on this device";
		return nil;
	}
	_queue = [_device newCommandQueue];
	_samples = samples >= 4 && [_device supportsTextureSampleCount:4] ? 4 : 1;
	library = [_device newLibraryWithSource:shader_source options:nil error:&error];
	if (library == nil) {
		*why = [NSString stringWithFormat:@"the shaders did not compile: %@", error.localizedDescription ?: @"no reason"];
		return nil;
	}
	_fill = [self pipeline:library vertex:@"v_fill" fragment:@"f_fill"
	    layout:vertex_descriptor(fill_formats, fill_offsets, 2, sizeof(struct fill_vertex)) why:why];
	_line = _fill ? [self pipeline:library vertex:@"v_line" fragment:@"f_line"
	    layout:vertex_descriptor(line_formats, line_offsets, 2, sizeof(struct line_vertex)) why:why] : nil;
	_label = _line ? [self pipeline:library vertex:@"v_label" fragment:@"f_label"
	    layout:vertex_descriptor(label_formats, label_offsets, 4, sizeof(struct map_label_vertex)) why:why] : nil;
	if (_label == nil) {
		return nil;
	}
	{
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
		    width:MAP_ATLAS height:MAP_ATLAS mipmapped:NO];
		MTLSamplerDescriptor *s = [MTLSamplerDescriptor new];

		/* (left as it comes: a label writes its own place with an empty border round it, and nothing reads the rest) */
		d.usage = MTLTextureUsageShaderRead;
		_atlas = [_device newTextureWithDescriptor:d];
		if (_atlas == nil) {
			*why = @"no texture for the labels";
			return nil;
		}
		s.minFilter = s.magFilter = MTLSamplerMinMagFilterLinear;
		s.sAddressMode = s.tAddressMode = MTLSamplerAddressModeClampToEdge;
		_sampler = [_device newSamplerStateWithDescriptor:s];
	}
	_layer = [CAMetalLayer layer];
	_layer.device = _device;
	_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	_layer.framebufferOnly = YES;
	_layer.opaque = YES;
	_name = _samples > 1 ? @"Metal" : @"Metal, 1 sample";
	NSLog(@"mapcheck: metal: %@; %lu samples", _device.name, (unsigned long)_samples);
	return self;
}

- (CALayer *)layer
{
	return _layer;
}

- (NSString *)name
{
	return _name;
}

- (id)makeTile:(const struct tess_tile *)tile
{
	MapMetalTile *made = [MapMetalTile new];
	const MTLResourceOptions shared = MTLResourceStorageModeShared;

	if (tile->fills.index_count > 0) {
		made->fillVertices = [_device newBufferWithBytes:tile->fills.vertices
		    length:tile->fills.vertex_count * sizeof(struct fill_vertex) options:shared];
		made->fillIndices = [_device newBufferWithBytes:tile->fills.indices
		    length:tile->fills.index_count * sizeof(uint32_t) options:shared];
		if (made->fillVertices == nil || made->fillIndices == nil) {
			return nil;
		}
		made->fillCount = tile->fills.index_count;
	}
	if (tile->lines.index_count > 0) {
		made->lineVertices = [_device newBufferWithBytes:tile->lines.vertices
		    length:tile->lines.vertex_count * sizeof(struct line_vertex) options:shared];
		made->lineIndices = [_device newBufferWithBytes:tile->lines.indices
		    length:tile->lines.index_count * sizeof(uint32_t) options:shared];
		if (made->lineVertices == nil || made->lineIndices == nil) {
			return nil;
		}
		made->lineCount = tile->lines.index_count;
	}
	return made;
}

- (void)atlasReplace:(CGRect)rect bytes:(const uint8_t *)bytes stride:(size_t)stride
{
	NSUInteger x = (NSUInteger)rect.origin.x, y = (NSUInteger)rect.origin.y;
	NSUInteger w = (NSUInteger)rect.size.width, h = (NSUInteger)rect.size.height;

	if (w == 0 || h == 0) {
		return;
	}
	/* (written while an earlier frame may still sample the atlas: a label's pixels change only where no label of a
	   frame in flight is, as MapLabels hands out places) */
	[_atlas replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:0 withBytes:bytes bytesPerRow:stride];
}

- (void)captureNextFrame:(void (^)(const uint8_t *, size_t, size_t))done
{
	_capture = [done copy];
	/* (the drawables made from now on can be read: framebufferOnly ones cannot) */
	_layer.framebufferOnly = NO;
}

- (void)drawFrame:(const struct map_frame *)frame
{
	CGSize size = _layer.bounds.size, pixels;
	CGFloat scale = _layer.contentsScale;
	id<CAMetalDrawable> drawable;
	id<MTLCommandBuffer> buffer;
	id<MTLRenderCommandEncoder> encoder;
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	MTLRenderPassColorAttachmentDescriptor *colour = pass.colorAttachments[0];
	struct gpu_frame shared;
	id<MTLBuffer> readback = nil;
	CFTimeInterval encodeBegan = 0, committed;

	pixels = CGSizeMake(round(size.width * scale), round(size.height * scale));
	if (pixels.width < 1 || pixels.height < 1) {
		return;
	}
	if (!CGSizeEqualToSize(_layer.drawableSize, pixels)) {
		_layer.drawableSize = pixels;
	}
	if (_samples > 1 && (_msaa == nil || _msaa.width != (NSUInteger)pixels.width ||
	    _msaa.height != (NSUInteger)pixels.height)) {
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		    width:(NSUInteger)pixels.width height:(NSUInteger)pixels.height mipmapped:NO];

		d.textureType = MTLTextureType2DMultisample;
		d.sampleCount = _samples;
		d.usage = MTLTextureUsageRenderTarget;
		d.storageMode = MTLStorageModeMemoryless;
		_msaa = [_device newTextureWithDescriptor:d];
		if (_msaa == nil) {
			d.storageMode = MTLStorageModePrivate;
			_msaa = [_device newTextureWithDescriptor:d];
		}
		if (_msaa == nil) {
			NSLog(@"mapcheck: metal: no %lu-sample texture of %.0fx%.0f", (unsigned long)_samples, pixels.width,
			    pixels.height);
			return;
		}
	}
	{
		CFTimeInterval asked = CACurrentMediaTime();

		drawable = [_layer nextDrawable];
		_waiting += CACurrentMediaTime() - asked;
		encodeBegan = CACurrentMediaTime();
	}
	if (drawable == nil) {
		return;
	}
	buffer = [_queue commandBuffer];
	if (_samples > 1) {
		colour.texture = _msaa;
		colour.resolveTexture = drawable.texture;
		colour.storeAction = MTLStoreActionMultisampleResolve;
	} else {
		colour.texture = drawable.texture;
		colour.storeAction = MTLStoreActionStore;
	}
	colour.loadAction = MTLLoadActionClear;
	colour.clearColor = MTLClearColorMake(frame->background[0], frame->background[1], frame->background[2], 1);
	encoder = [buffer renderCommandEncoderWithDescriptor:pass];

	memcpy(shared.extrude, frame->extrude, sizeof(shared.extrude));
	shared.pixel = frame->pixel;
	shared.pad = 0;
	/*
	 * The fills' pass, then every line pass after it as the instances of one draw a tile: on the K40 port each draw
	 * waits for the GPU (about a millisecond), so a tile's three line passes in one draw are two fewer waits.
	 */
	for (unsigned p = 0; p < MAP_PASSES;) {
		const struct map_pass *mp = &frame->passes[p];
		struct gpu_pass tables[MAP_PASSES];
		unsigned passes = 1;

		if (mp->lines) {
			while (p + passes < MAP_PASSES && frame->passes[p + passes].lines) {
				passes++;
			}
		}
		memset(tables, 0, sizeof(tables));
		for (unsigned k = 0; k < passes; k++) {
			memcpy(tables[k].colour, frame->passes[p + k].colour, sizeof(mp->colour));
			memcpy(tables[k].width, frame->passes[p + k].half, sizeof(mp->half));
		}
		[encoder setRenderPipelineState:mp->lines ? _line : _fill];
		[encoder setVertexBytes:tables length:passes * sizeof(tables[0]) atIndex:1];
		if (mp->lines) {
			[encoder setVertexBytes:&shared length:sizeof(shared) atIndex:3];
		}
		for (unsigned i = 0; i < frame->piece_count; i++) {
			const struct map_piece *piece = &frame->pieces[i];
			MapMetalTile *tile = piece->tile;
			const float *m = piece->matrix;
			struct gpu_piece where = {
				{ m[0], m[1] }, { m[2], m[3] }, { m[4], m[5] }, { 0, 0 },
				{ piece->clip[0], piece->clip[1], piece->clip[2], piece->clip[3] },
			};
			NSUInteger count = mp->lines ? tile->lineCount : tile->fillCount;

			if (count == 0) {
				continue;
			}
			[encoder setVertexBuffer:mp->lines ? tile->lineVertices : tile->fillVertices offset:0 atIndex:0];
			[encoder setVertexBytes:&where length:sizeof(where) atIndex:2];
			[encoder setFragmentBytes:&where length:sizeof(where) atIndex:0];
			if (mp->lines) {
				[encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:count indexType:MTLIndexTypeUInt32
				    indexBuffer:tile->lineIndices indexBufferOffset:0 instanceCount:passes];
			} else {
				[encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:count indexType:MTLIndexTypeUInt32
				    indexBuffer:tile->fillIndices indexBufferOffset:0];
			}
		}
		p += passes;
	}
	if (frame->label_vertices > 0) {
		size_t length = frame->label_vertices * sizeof(struct map_label_vertex);

		[encoder setRenderPipelineState:_label];
		if (length <= 4096) {
			[encoder setVertexBytes:frame->labels length:length atIndex:0];
		} else {
			[encoder setVertexBuffer:[_device newBufferWithBytes:frame->labels length:length
			    options:MTLResourceStorageModeShared] offset:0 atIndex:0];
		}
		[encoder setFragmentTexture:_atlas atIndex:0];
		[encoder setFragmentSamplerState:_sampler atIndex:0];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:frame->label_vertices];
	}
	[encoder endEncoding];

	if (_capture != nil && !drawable.texture.framebufferOnly) {
		NSUInteger w = drawable.texture.width, h = drawable.texture.height;
		id<MTLBlitCommandEncoder> blit;

		readback = [_device newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
		if (readback != nil) {
			blit = [buffer blitCommandEncoder];
			[blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
			    sourceSize:MTLSizeMake(w, h, 1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:w * 4
			    destinationBytesPerImage:w * h * 4];
			[blit endEncoding];
		}
	}
	[buffer presentDrawable:drawable];
	if (readback != nil) {
		void (^done)(const uint8_t *, size_t, size_t) = _capture;
		NSUInteger w = drawable.texture.width, h = drawable.texture.height;
		__weak CAMetalLayer *layer = _layer;

		_capture = nil;
		[buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
			dispatch_async(dispatch_get_main_queue(), ^{
				uint8_t *rgba = readback.contents;

				/* (BGRA as the drawable has it, RGBA as the self-test reads it) */
				for (NSUInteger i = 0; i < w * h; i++) {
					uint8_t b = rgba[4 * i];

					rgba[4 * i] = rgba[4 * i + 2];
					rgba[4 * i + 2] = b;
				}
				done(finished.status == MTLCommandBufferStatusCompleted ? rgba : NULL, w, h);
				layer.framebufferOnly = YES;
			});
		}];
	}
	committed = CACurrentMediaTime();
	[buffer commit];
	_frames++;
	_encoding += committed - encodeBegan;
	_committing += CACurrentMediaTime() - committed;
}

@end

NSString *
map_metal_problem(void)
{
	static NSString *problem;
	static dispatch_once_t once;

	/* (on the K40 port an app has a Metal device only if it is on the list of those that may: metal_apps=) */
	dispatch_once(&once, ^{
		problem = MTLCreateSystemDefaultDevice() != nil ? nil : @"Metal is not available to this app on this device";
	});
	return problem;
}

id<MapRenderer>
map_renderer_metal(unsigned samples, NSString **why)
{
	NSString *reason = nil;
	MapRendererMetal *renderer = [[MapRendererMetal alloc] initSamples:samples why:&reason];

	if (why != NULL) {
		*why = reason;
	}
	return renderer;
}
