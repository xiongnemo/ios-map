// MapRendererGL.m: the map drawn with OpenGL ES -- 3.0 where there is, else 2.0 -- into a CAEAGLLayer, four samples a
// pixel and resolved before it is shown. The shaders are GLSL ES 1.00, which both versions take; MapRendererMetal.m has
// the same ones in the Metal shading language, line for line. See MapRenderer.h.
#define GLES_SILENCE_DEPRECATION 1
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <OpenGLES/ES3/gl.h>
#import <UIKit/UIKit.h>
#include <os/lock.h>

#import "MapRenderer.h"

static const char *const fill_vertex_source =
	"attribute vec2 a_pos;\n"
	"attribute float a_bucket;\n"
	"uniform vec3 u_matrix[2];\n"
	"uniform vec4 u_colour[32];\n"
	"varying highp vec2 v_tile;\n"
	"varying lowp vec4 v_colour;\n"
	"void main() {\n"
	"    vec4 c = u_colour[int(a_bucket + 0.5)];\n"
	"    vec3 p = vec3(a_pos, 1.0);\n"
	"    v_tile = a_pos;\n"
	"    v_colour = c;\n"
	"    /* (a bucket the pass leaves out: all its corners at one place off the screen, nothing to fill) */\n"
	"    gl_Position = c.a > 0.0 ? vec4(dot(u_matrix[0], p), dot(u_matrix[1], p), 0.0, 1.0) : vec4(2.0, 2.0, 2.0, 1.0);\n"
	"}\n";

static const char *const fill_fragment_source =
	"precision highp float;\n"
	"uniform vec4 u_clip;\n"
	"varying highp vec2 v_tile;\n"
	"varying lowp vec4 v_colour;\n"
	"void main() {\n"
	"    if (v_tile.x < u_clip.x || v_tile.y < u_clip.y || v_tile.x > u_clip.z || v_tile.y > u_clip.w) discard;\n"
	"    gl_FragColor = v_colour;\n"
	"}\n";

static const char *const line_vertex_source =
	"attribute vec2 a_pos;\n"
	"attribute vec2 a_extrude;\n"
	"attribute float a_across;\n"
	"attribute float a_bucket;\n"
	"uniform vec3 u_matrix[2];\n"
	"uniform vec4 u_colour[32];\n"
	"uniform float u_half[32];\n"
	"uniform mat2 u_extrude;\n"
	"uniform float u_pixel;\n"
	"varying highp vec2 v_tile;\n"
	"varying lowp vec4 v_colour;\n"
	"varying mediump float v_across;\n"
	"varying mediump float v_width;\n"
	"void main() {\n"
	"    int b = int(a_bucket + 0.5);\n"
	"    vec4 c = u_colour[b];\n"
	"    float w = u_half[b], opacity = 1.0, drawn;\n"
	"    vec3 p = vec3(a_pos, 1.0);\n"
	"    /* (thinner than a pixel: a pixel wide and as much fainter) */\n"
	"    if (w < 0.5 * u_pixel) {\n"
	"        opacity = w / (0.5 * u_pixel);\n"
	"        w = 0.5 * u_pixel;\n"
	"    }\n"
	"    /* (half a pixel more on each side, for the soft edge to fade out over) */\n"
	"    drawn = w + 0.5 * u_pixel;\n"
	"    v_tile = a_pos;\n"
	"    v_colour = c * opacity;\n"
	"    v_across = a_across / 127.0;\n"
	"    v_width = drawn / u_pixel;\n"
	"    gl_Position = c.a > 0.0 ? vec4(vec2(dot(u_matrix[0], p), dot(u_matrix[1], p)) +\n"
	"        u_extrude * (a_extrude * (drawn / 4096.0)), 0.0, 1.0) : vec4(2.0, 2.0, 2.0, 1.0);\n"
	"}\n";

static const char *const line_fragment_source =
	"precision highp float;\n"
	"uniform vec4 u_clip;\n"
	"varying highp vec2 v_tile;\n"
	"varying lowp vec4 v_colour;\n"
	"varying mediump float v_across;\n"
	"varying mediump float v_width;\n"
	"void main() {\n"
	"    if (v_tile.x < u_clip.x || v_tile.y < u_clip.y || v_tile.x > u_clip.z || v_tile.y > u_clip.w) discard;\n"
	"    gl_FragColor = v_colour * clamp((1.0 - abs(v_across)) * v_width, 0.0, 1.0);\n"
	"}\n";

static const char *const label_vertex_source =
	"attribute vec2 a_pos;\n"
	"attribute vec2 a_uv;\n"
	"attribute vec4 a_colour;\n"
	"attribute vec4 a_halo;\n"
	"varying mediump vec2 v_uv;\n"
	"varying lowp vec4 v_colour;\n"
	"varying lowp vec4 v_halo;\n"
	"void main() {\n"
	"    v_uv = a_uv;\n"
	"    v_colour = a_colour;\n"
	"    v_halo = a_halo;\n"
	"    gl_Position = vec4(a_pos, 0.0, 1.0);\n"
	"}\n";

/* (the atlas is LUMINANCE_ALPHA: the text in L, the halo in A) */
static const char *const label_fragment_source =
	"precision mediump float;\n"
	"uniform sampler2D u_atlas;\n"
	"varying mediump vec2 v_uv;\n"
	"varying lowp vec4 v_colour;\n"
	"varying lowp vec4 v_halo;\n"
	"void main() {\n"
	"    vec4 t = texture2D(u_atlas, v_uv);\n"
	"    float text = t.r * v_colour.a;\n"
	"    gl_FragColor = v_colour * t.r + v_halo * (t.a * (1.0 - text));\n"
	"}\n";

enum { A_POS, A_BUCKET, A_EXTRUDE, A_ACROSS, A_UV = 1, A_COLOUR = 2, A_HALO = 3 };

/*
 * What a tile's GPU objects become when the tile goes: its buffers' names, to be deleted on the main thread with the
 * context current (a tile may be let go of on another thread, by the cache). The renderer and its tiles share one; it
 * keeps the context, so that the names are those of a context still there.
 */
@interface MapGLShelf : NSObject {
@public
	EAGLContext *context;
	os_unfair_lock lock;
	GLuint *dead;
	size_t dead_count, dead_room;
}
@end

@implementation MapGLShelf

- (void)bury:(const GLuint *)names count:(size_t)count
{
	os_unfair_lock_lock(&lock);
	if (dead_count + count > dead_room) {
		size_t room = dead_room ? dead_room * 2 : 64;
		GLuint *grown;

		while (room < dead_count + count) {
			room *= 2;
		}
		grown = realloc(dead, room * sizeof(GLuint));
		if (grown == NULL) {
			os_unfair_lock_unlock(&lock);
			return;                 /* (they stay until the context goes, which frees them anyway) */
		}
		dead = grown;
		dead_room = room;
	}
	memcpy(dead + dead_count, names, count * sizeof(GLuint));
	dead_count += count;
	os_unfair_lock_unlock(&lock);
}

/* with the context current */
- (void)sweep
{
	os_unfair_lock_lock(&lock);
	if (dead_count > 0) {
		glDeleteBuffers((GLsizei)dead_count, dead);
		dead_count = 0;
	}
	os_unfair_lock_unlock(&lock);
}

- (void)dealloc
{
	free(dead);
}

@end

@interface MapGLTile : NSObject {
@public
	MapGLShelf *shelf;
	GLuint buffers[4];              /* fill vertices, fill indices, line vertices, line indices */
	GLsizei fill_indices, line_indices;
}
@end

@implementation MapGLTile

- (void)dealloc
{
	[shelf bury:buffers count:4];
}

@end

@interface MapRendererGL : NSObject <MapRenderer>
@end

@implementation MapRendererGL {
	CAEAGLLayer *_layer;
	EAGLContext *_context;
	MapGLShelf *_shelf;
	NSString *_name;
	BOOL _es3;
	GLuint _fill, _line, _label;    /* the programs */
	GLint _fillMatrix, _fillColour, _fillClip;
	GLint _lineMatrix, _lineColour, _lineHalf, _lineExtrude, _linePixel, _lineClip;
	GLuint _atlas, _labelBuffer;
	GLuint _msaaFramebuffer, _msaaColour, _framebuffer, _colour;
	GLint _width, _height, _samples;
	void (^_capture)(const uint8_t *, size_t, size_t);
	unsigned _frames;
	CFTimeInterval _drawing, _presenting;
}

- (NSString *)timing
{
	NSString *said = [NSString stringWithFormat:@"%.1f ms a frame drawing, %.1f in -presentRenderbuffer:",
	    _frames ? 1000 * _drawing / _frames : 0, _frames ? 1000 * _presenting / _frames : 0];

	_frames = 0;
	_drawing = _presenting = 0;
	return said;
}

static GLuint
compile(GLenum type, const char *source, NSString **why)
{
	GLuint shader = glCreateShader(type);
	GLint ok = 0;

	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024] = "";

		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		*why = [NSString stringWithFormat:@"a %s shader did not compile: %s", type == GL_VERTEX_SHADER ? "vertex" :
		    "fragment", log];
		glDeleteShader(shader);
		return 0;
	}
	return shader;
}

/* a program of the two, its attributes at the places given (NULL-terminated names, from 0) */
static GLuint
link_program(const char *vertex, const char *fragment, const char *const *attributes, NSString **why)
{
	GLuint vs = compile(GL_VERTEX_SHADER, vertex, why), fs, program;
	GLint ok = 0;

	if (vs == 0) {
		return 0;
	}
	fs = compile(GL_FRAGMENT_SHADER, fragment, why);
	if (fs == 0) {
		glDeleteShader(vs);
		return 0;
	}
	program = glCreateProgram();
	glAttachShader(program, vs);
	glAttachShader(program, fs);
	for (GLuint i = 0; attributes[i] != NULL; i++) {
		glBindAttribLocation(program, i, attributes[i]);
	}
	glLinkProgram(program);
	glDeleteShader(vs);
	glDeleteShader(fs);
	glGetProgramiv(program, GL_LINK_STATUS, &ok);
	if (!ok) {
		char log[1024] = "";

		glGetProgramInfoLog(program, sizeof(log), NULL, log);
		*why = [NSString stringWithFormat:@"a program did not link: %s", log];
		glDeleteProgram(program);
		return 0;
	}
	return program;
}

- (instancetype)initSamples:(unsigned)samples why:(NSString **)why
{
	static const char *const fill_attributes[] = { "a_pos", "a_bucket", NULL };
	static const char *const line_attributes[] = { "a_pos", "a_bucket", "a_extrude", "a_across", NULL };
	static const char *const label_attributes[] = { "a_pos", "a_uv", "a_colour", "a_halo", NULL };

	self = [super init];
	if (self == nil) {
		return nil;
	}
	_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
	_es3 = _context != nil;
	if (_context == nil) {
		_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
	}
	if (_context == nil || ![EAGLContext setCurrentContext:_context]) {
		*why = @"no OpenGL ES context";
		return nil;
	}
	_fill = link_program(fill_vertex_source, fill_fragment_source, fill_attributes, why);
	_line = _fill ? link_program(line_vertex_source, line_fragment_source, line_attributes, why) : 0;
	_label = _line ? link_program(label_vertex_source, label_fragment_source, label_attributes, why) : 0;
	if (_label == 0) {
		return nil;
	}
	_fillMatrix = glGetUniformLocation(_fill, "u_matrix");
	_fillColour = glGetUniformLocation(_fill, "u_colour");
	_fillClip = glGetUniformLocation(_fill, "u_clip");
	_lineMatrix = glGetUniformLocation(_line, "u_matrix");
	_lineColour = glGetUniformLocation(_line, "u_colour");
	_lineHalf = glGetUniformLocation(_line, "u_half");
	_lineExtrude = glGetUniformLocation(_line, "u_extrude");
	_linePixel = glGetUniformLocation(_line, "u_pixel");
	_lineClip = glGetUniformLocation(_line, "u_clip");
	glUseProgram(_label);
	glUniform1i(glGetUniformLocation(_label, "u_atlas"), 0);

	glGenTextures(1, &_atlas);
	glBindTexture(GL_TEXTURE_2D, _atlas);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	/* (left as it comes: a label writes its own place with an empty border round it, and nothing reads the rest) */
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE_ALPHA, MAP_ATLAS, MAP_ATLAS, 0, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, NULL);
	glGenBuffers(1, &_labelBuffer);
	glGetIntegerv(_es3 ? GL_MAX_SAMPLES : GL_MAX_SAMPLES_APPLE, &_samples);
	_samples = MAX(1, MIN(_samples, (GLint)samples));

	_shelf = [MapGLShelf new];
	_shelf->context = _context;
	_shelf->lock = OS_UNFAIR_LOCK_INIT;
	_layer = [CAEAGLLayer layer];
	_layer.opaque = YES;
	_layer.drawableProperties = @{
		kEAGLDrawablePropertyRetainedBacking: @NO,
		kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
	};
	{
		const char *version = (const char *)glGetString(GL_VERSION);

		_name = [NSString stringWithFormat:@"OpenGL ES %@%@", _es3 ? @"3.0" : @"2.0",
		    _samples > 1 ? @"" : @", 1 sample"];
		if (version != NULL) {
			NSLog(@"mapcheck: gl: %s, %s, %s; %d samples", version, (const char *)glGetString(GL_RENDERER),
			    (const char *)glGetString(GL_VENDOR), (int)_samples);
		}
	}
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

static GLuint
buffer_of(GLenum target, const void *data, size_t size)
{
	GLuint name = 0;

	glGenBuffers(1, &name);
	glBindBuffer(target, name);
	glBufferData(target, (GLsizeiptr)size, data, GL_STATIC_DRAW);
	return name;
}

- (id)makeTile:(const struct tess_tile *)tile
{
	MapGLTile *made = [MapGLTile new];

	[EAGLContext setCurrentContext:_context];
	[_shelf sweep];
	made->shelf = _shelf;
	made->buffers[0] = buffer_of(GL_ARRAY_BUFFER, tile->fills.vertices,
	    tile->fills.vertex_count * sizeof(struct fill_vertex));
	made->buffers[1] = buffer_of(GL_ELEMENT_ARRAY_BUFFER, tile->fills.indices, tile->fills.index_count * sizeof(uint32_t));
	made->buffers[2] = buffer_of(GL_ARRAY_BUFFER, tile->lines.vertices,
	    tile->lines.vertex_count * sizeof(struct line_vertex));
	made->buffers[3] = buffer_of(GL_ELEMENT_ARRAY_BUFFER, tile->lines.indices, tile->lines.index_count * sizeof(uint32_t));
	made->fill_indices = (GLsizei)tile->fills.index_count;
	made->line_indices = (GLsizei)tile->lines.index_count;
	if (glGetError() == GL_OUT_OF_MEMORY) {
		return nil;
	}
	return made;
}

- (void)atlasReplace:(CGRect)rect bytes:(const uint8_t *)bytes stride:(size_t)stride
{
	GLint x = (GLint)rect.origin.x, y = (GLint)rect.origin.y, w = (GLint)rect.size.width, h = (GLint)rect.size.height;

	if (w <= 0 || h <= 0) {
		return;
	}
	[EAGLContext setCurrentContext:_context];
	glBindTexture(GL_TEXTURE_2D, _atlas);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	if (stride == (size_t)w * 2) {
		glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, w, h, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, bytes);
	} else {
		/* (ES 2.0 has no UNPACK_ROW_LENGTH: a row at a time) */
		for (GLint row = 0; row < h; row++) {
			glTexSubImage2D(GL_TEXTURE_2D, 0, x, y + row, w, 1, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE,
			    bytes + (size_t)row * stride);
		}
	}
}

- (void)captureNextFrame:(void (^)(const uint8_t *, size_t, size_t))done
{
	_capture = [done copy];
}

/* the framebuffers for the layer's size: the resolved one is the layer's own storage, the multisampled one ours */
- (BOOL)makeFramebuffers
{
	CGSize size = _layer.bounds.size;
	CGFloat scale = _layer.contentsScale;
	GLint width = (GLint)lround(size.width * scale), height = (GLint)lround(size.height * scale);

	if (width <= 0 || height <= 0) {
		return NO;
	}
	if (width == _width && height == _height && _framebuffer != 0) {
		return YES;
	}
	if (_framebuffer != 0) {
		glDeleteFramebuffers(1, &_framebuffer);
		glDeleteRenderbuffers(1, &_colour);
		glDeleteFramebuffers(1, &_msaaFramebuffer);
		glDeleteRenderbuffers(1, &_msaaColour);
		_framebuffer = _colour = _msaaFramebuffer = _msaaColour = 0;
	}
	glGenFramebuffers(1, &_framebuffer);
	glGenRenderbuffers(1, &_colour);
	glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
	glBindRenderbuffer(GL_RENDERBUFFER, _colour);
	if (![_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:_layer]) {
		return NO;
	}
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colour);
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_width);
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_height);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		return NO;
	}
	if (_samples > 1) {
		glGenFramebuffers(1, &_msaaFramebuffer);
		glGenRenderbuffers(1, &_msaaColour);
		glBindFramebuffer(GL_FRAMEBUFFER, _msaaFramebuffer);
		glBindRenderbuffer(GL_RENDERBUFFER, _msaaColour);
		if (_es3) {
			glRenderbufferStorageMultisample(GL_RENDERBUFFER, _samples, GL_RGBA8, _width, _height);
		} else {
			glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, _samples, GL_RGBA8_OES, _width, _height);
		}
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _msaaColour);
		if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
			/* (no multisampling, then: drawn straight into the layer's storage) */
			NSLog(@"mapcheck: gl: no %d-sample framebuffer of %dx%d; drawing without", (int)_samples, _width, _height);
			glDeleteFramebuffers(1, &_msaaFramebuffer);
			glDeleteRenderbuffers(1, &_msaaColour);
			_msaaFramebuffer = _msaaColour = 0;
			_samples = 1;
		}
	}
	return YES;
}

static void
matrix_of(GLint location, const struct map_piece *piece)
{
	const float *m = piece->matrix;
	const GLfloat rows[6] = { m[0], m[2], m[4], m[1], m[3], m[5] };

	glUniform3fv(location, 2, rows);
}

- (void)drawFrame:(const struct map_frame *)frame
{
	CFTimeInterval began = CACurrentMediaTime(), presented;

	[EAGLContext setCurrentContext:_context];
	[_shelf sweep];
	if (![self makeFramebuffers]) {
		return;
	}
	glBindFramebuffer(GL_FRAMEBUFFER, _msaaFramebuffer != 0 ? _msaaFramebuffer : _framebuffer);
	glViewport(0, 0, _width, _height);
	glDisable(GL_DEPTH_TEST);
	glDisable(GL_CULL_FACE);
	glDisable(GL_DITHER);
	glClearColor(frame->background[0], frame->background[1], frame->background[2], 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glEnable(GL_BLEND);
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

	for (unsigned p = 0; p < MAP_PASSES; p++) {
		const struct map_pass *pass = &frame->passes[p];

		if (pass->lines) {
			glUseProgram(_line);
			glUniform4fv(_lineColour, B_COUNT, &pass->colour[0][0]);
			glUniform1fv(_lineHalf, B_COUNT, pass->half);
			glUniformMatrix2fv(_lineExtrude, 1, GL_FALSE, frame->extrude);
			glUniform1f(_linePixel, frame->pixel);
			glEnableVertexAttribArray(A_POS);
			glEnableVertexAttribArray(A_BUCKET);
			glEnableVertexAttribArray(A_EXTRUDE);
			glEnableVertexAttribArray(A_ACROSS);
		} else {
			glUseProgram(_fill);
			glUniform4fv(_fillColour, B_COUNT, &pass->colour[0][0]);
			glEnableVertexAttribArray(A_POS);
			glEnableVertexAttribArray(A_BUCKET);
			glDisableVertexAttribArray(A_EXTRUDE);
			glDisableVertexAttribArray(A_ACROSS);
		}
		for (unsigned i = 0; i < frame->piece_count; i++) {
			const struct map_piece *piece = &frame->pieces[i];
			MapGLTile *tile = piece->tile;

			if (pass->lines) {
				if (tile->line_indices == 0) {
					continue;
				}
				matrix_of(_lineMatrix, piece);
				glUniform4fv(_lineClip, 1, piece->clip);
				glBindBuffer(GL_ARRAY_BUFFER, tile->buffers[2]);
				glVertexAttribPointer(A_POS, 2, GL_SHORT, GL_FALSE, sizeof(struct line_vertex),
				    (const void *)offsetof(struct line_vertex, x));
				glVertexAttribPointer(A_EXTRUDE, 2, GL_SHORT, GL_FALSE, sizeof(struct line_vertex),
				    (const void *)offsetof(struct line_vertex, ex));
				glVertexAttribPointer(A_ACROSS, 1, GL_BYTE, GL_FALSE, sizeof(struct line_vertex),
				    (const void *)offsetof(struct line_vertex, across));
				glVertexAttribPointer(A_BUCKET, 1, GL_UNSIGNED_BYTE, GL_FALSE, sizeof(struct line_vertex),
				    (const void *)offsetof(struct line_vertex, bucket));
				glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, tile->buffers[3]);
				glDrawElements(GL_TRIANGLES, tile->line_indices, GL_UNSIGNED_INT, NULL);
			} else {
				if (tile->fill_indices == 0) {
					continue;
				}
				matrix_of(_fillMatrix, piece);
				glUniform4fv(_fillClip, 1, piece->clip);
				glBindBuffer(GL_ARRAY_BUFFER, tile->buffers[0]);
				glVertexAttribPointer(A_POS, 2, GL_SHORT, GL_FALSE, sizeof(struct fill_vertex),
				    (const void *)offsetof(struct fill_vertex, x));
				glVertexAttribPointer(A_BUCKET, 1, GL_UNSIGNED_BYTE, GL_FALSE, sizeof(struct fill_vertex),
				    (const void *)offsetof(struct fill_vertex, bucket));
				glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, tile->buffers[1]);
				glDrawElements(GL_TRIANGLES, tile->fill_indices, GL_UNSIGNED_INT, NULL);
			}
		}
	}
	glDisableVertexAttribArray(A_EXTRUDE);
	glDisableVertexAttribArray(A_ACROSS);

	if (frame->label_vertices > 0) {
		glUseProgram(_label);
		glActiveTexture(GL_TEXTURE0);
		glBindTexture(GL_TEXTURE_2D, _atlas);
		glBindBuffer(GL_ARRAY_BUFFER, _labelBuffer);
		glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(frame->label_vertices * sizeof(struct map_label_vertex)), frame->labels,
		    GL_STREAM_DRAW);
		glEnableVertexAttribArray(0);
		glEnableVertexAttribArray(1);
		glEnableVertexAttribArray(2);
		glEnableVertexAttribArray(3);
		glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(struct map_label_vertex),
		    (const void *)offsetof(struct map_label_vertex, x));
		glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(struct map_label_vertex),
		    (const void *)offsetof(struct map_label_vertex, u));
		glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(struct map_label_vertex),
		    (const void *)offsetof(struct map_label_vertex, colour));
		glVertexAttribPointer(3, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(struct map_label_vertex),
		    (const void *)offsetof(struct map_label_vertex, halo));
		glDrawArrays(GL_TRIANGLES, 0, (GLsizei)frame->label_vertices);
		glDisableVertexAttribArray(2);
		glDisableVertexAttribArray(3);
	}

	if (_msaaFramebuffer != 0) {
		const GLenum colour = GL_COLOR_ATTACHMENT0;

		if (_es3) {
			glBindFramebuffer(GL_READ_FRAMEBUFFER, _msaaFramebuffer);
			glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);
			glBlitFramebuffer(0, 0, _width, _height, 0, 0, _width, _height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
			glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 1, &colour);
		} else {
			glBindFramebuffer(GL_READ_FRAMEBUFFER_APPLE, _msaaFramebuffer);
			glBindFramebuffer(GL_DRAW_FRAMEBUFFER_APPLE, _framebuffer);
			glResolveMultisampleFramebufferAPPLE();
			glDiscardFramebufferEXT(GL_READ_FRAMEBUFFER_APPLE, 1, &colour);
		}
	}
	glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
	if (_capture != nil) {
		void (^done)(const uint8_t *, size_t, size_t) = _capture;
		size_t row = (size_t)_width * 4;
		uint8_t *pixels = malloc(row * (size_t)_height), *flipped = malloc(row * (size_t)_height);

		_capture = nil;
		if (pixels != NULL && flipped != NULL) {
			glReadPixels(0, 0, _width, _height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
			for (GLint y = 0; y < _height; y++) {
				memcpy(flipped + (size_t)y * row, pixels + (size_t)(_height - 1 - y) * row, row);
			}
			done(flipped, (size_t)_width, (size_t)_height);
		} else {
			done(NULL, 0, 0);
		}
		free(pixels);
		free(flipped);
	}
	glBindRenderbuffer(GL_RENDERBUFFER, _colour);
	presented = CACurrentMediaTime();
	[_context presentRenderbuffer:GL_RENDERBUFFER];
	_frames++;
	_drawing += presented - began;
	_presenting += CACurrentMediaTime() - presented;
}

- (void)dealloc
{
	if (_context != nil && [EAGLContext setCurrentContext:_context]) {
		[_shelf sweep];
		glDeleteProgram(_fill);
		glDeleteProgram(_line);
		glDeleteProgram(_label);
		glDeleteTextures(1, &_atlas);
		glDeleteBuffers(1, &_labelBuffer);
		glDeleteFramebuffers(1, &_framebuffer);
		glDeleteRenderbuffers(1, &_colour);
		glDeleteFramebuffers(1, &_msaaFramebuffer);
		glDeleteRenderbuffers(1, &_msaaColour);
		[EAGLContext setCurrentContext:nil];
	}
}

@end

id<MapRenderer>
map_renderer_gl(unsigned samples, NSString **why)
{
	NSString *reason = nil;
	MapRendererGL *renderer = [[MapRendererGL alloc] initSamples:samples why:&reason];

	if (why != NULL) {
		*why = reason;
	}
	return renderer;
}
