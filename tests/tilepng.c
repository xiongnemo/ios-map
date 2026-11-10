// tilepng: a vector tile tessellated as the map does it (tessellate.c) and drawn on the processor into a PNG, for looking
// at on a computer -- the triangles of each bucket in the style's draw order, lines at their width for the tile's zoom
// (two pixels a point), a dot where each label would go. No anti-aliasing: this checks the geometry, not the looks.
//   cc -O2 -o tilepng tests/tilepng.c tessellate.c style.c mvt.c earcut.c -lm -lz
//   ./tilepng TILE.pbf ZOOM OUT.png [dark]
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "../tessellate.h"

#define SIZE 1024                       /* pixels: a tile is 512 points across, at two pixels a point */

static uint8_t image[SIZE][SIZE][3];

static void
colour_of(uint32_t rgba, double *r, double *g, double *b, double *a)
{
	*r = (rgba >> 24) & 0xff;
	*g = (rgba >> 16) & 0xff;
	*b = (rgba >> 8) & 0xff;
	*a = (rgba & 0xff) / 255.0;
}

static void
plot(int x, int y, uint32_t rgba)
{
	double r, g, b, a;

	if (x < 0 || y < 0 || x >= SIZE || y >= SIZE) {
		return;
	}
	colour_of(rgba, &r, &g, &b, &a);
	image[y][x][0] = (uint8_t)(image[y][x][0] * (1 - a) + r * a);
	image[y][x][1] = (uint8_t)(image[y][x][1] * (1 - a) + g * a);
	image[y][x][2] = (uint8_t)(image[y][x][2] * (1 - a) + b * a);
}

/* a triangle, filled where pixel centres fall inside it (either winding) */
static void
triangle(double x0, double y0, double x1, double y1, double x2, double y2, uint32_t rgba)
{
	int minx = (int)fmax(0, floor(fmin(x0, fmin(x1, x2)))), maxx = (int)fmin(SIZE - 1, ceil(fmax(x0, fmax(x1, x2))));
	int miny = (int)fmax(0, floor(fmin(y0, fmin(y1, y2)))), maxy = (int)fmin(SIZE - 1, ceil(fmax(y0, fmax(y1, y2))));
	double area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);

	if (area == 0) {
		return;
	}
	for (int y = miny; y <= maxy; y++) {
		for (int x = minx; x <= maxx; x++) {
			double px = x + 0.5, py = y + 0.5;
			double w0 = (x1 - px) * (y2 - py) - (x2 - px) * (y1 - py);
			double w1 = (x2 - px) * (y0 - py) - (x0 - px) * (y2 - py);
			double w2 = (x0 - px) * (y1 - py) - (x1 - px) * (y0 - py);

			if ((w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)) {
				plot(x, y, rgba);
			}
		}
	}
}

static void
write_png(const char *path)
{
	size_t raw_size = (size_t)SIZE * (SIZE * 3 + 1);
	uint8_t *raw = malloc(raw_size), *packed;
	uLongf packed_size = compressBound(raw_size);
	FILE *f = fopen(path, "wb");
	uint8_t ihdr[13] = { 0 };

	packed = malloc(packed_size);
	for (int y = 0; y < SIZE; y++) {
		raw[(size_t)y * (SIZE * 3 + 1)] = 0;
		memcpy(raw + (size_t)y * (SIZE * 3 + 1) + 1, image[y], SIZE * 3);
	}
	compress2(packed, &packed_size, raw, raw_size, 6);
	ihdr[0] = 0; ihdr[1] = 0; ihdr[2] = SIZE >> 8; ihdr[3] = SIZE & 0xff;
	ihdr[4] = 0; ihdr[5] = 0; ihdr[6] = SIZE >> 8; ihdr[7] = SIZE & 0xff;
	ihdr[8] = 8; ihdr[9] = 2;
	fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
	{
		const struct { const char *type; const uint8_t *data; uint32_t size; } chunks[] = {
			{ "IHDR", ihdr, 13 }, { "IDAT", packed, (uint32_t)packed_size }, { "IEND", NULL, 0 },
		};

		for (unsigned i = 0; i < 3; i++) {
			uint8_t be[4] = { chunks[i].size >> 24, chunks[i].size >> 16, chunks[i].size >> 8, chunks[i].size };
			uLong crc = crc32(0, (const Bytef *)chunks[i].type, 4);

			fwrite(be, 1, 4, f);
			fwrite(chunks[i].type, 1, 4, f);
			if (chunks[i].size) {
				fwrite(chunks[i].data, 1, chunks[i].size, f);
				crc = crc32(crc, chunks[i].data, chunks[i].size);
			}
			be[0] = (uint8_t)(crc >> 24); be[1] = (uint8_t)(crc >> 16); be[2] = (uint8_t)(crc >> 8); be[3] = (uint8_t)crc;
			fwrite(be, 1, 4, f);
		}
	}
	fclose(f);
	free(raw);
	free(packed);
}

int
main(int argc, char **argv)
{
	struct tess_tile tile;
	char error[200];
	FILE *f;
	uint8_t *data;
	long size;
	int zoom, dark;
	double scale = (double)SIZE / 4096, r, g, b, a;

	if (argc < 4) {
		fprintf(stderr, "usage: tilepng TILE.pbf ZOOM OUT.png [dark]\n");
		return 2;
	}
	zoom = atoi(argv[2]);
	dark = argc > 4;
	f = fopen(argv[1], "rb");
	if (f == NULL) {
		perror(argv[1]);
		return 2;
	}
	fseek(f, 0, SEEK_END);
	size = ftell(f);
	fseek(f, 0, SEEK_SET);
	data = malloc((size_t)size);
	if (data == NULL || fread(data, 1, (size_t)size, f) != (size_t)size) {
		return 2;
	}
	fclose(f);
	if (tess_make(data, (size_t)size, zoom, LANGUAGE_CHINESE, &tile, error, sizeof(error)) != 0) {
		fprintf(stderr, "%s\n", error);
		return 1;
	}
	colour_of(style_background(dark), &r, &g, &b, &a);
	for (int y = 0; y < SIZE; y++) {
		for (int x = 0; x < SIZE; x++) {
			image[y][x][0] = (uint8_t)r;
			image[y][x][1] = (uint8_t)g;
			image[y][x][2] = (uint8_t)b;
		}
	}
	for (unsigned d = 0; d < style_draw_count; d++) {
		const struct style_draw *draw = &style_draws[d];
		int fill = style_kind_of(draw->bucket) == STYLE_FILL;
		const struct tess_mesh *mesh = fill ? &tile.fills : &tile.lines;
		uint32_t first = mesh->first[draw->bucket], end = first + mesh->count[draw->bucket];

		if (zoom < draw->min_zoom || first == end) {
			continue;
		}
		if (fill) {
			const struct fill_vertex *v = mesh->vertices;

			for (uint32_t i = first; i + 2 < end; i += 3) {
				const struct fill_vertex *p = &v[mesh->indices[i]], *q = &v[mesh->indices[i + 1]],
				    *s = &v[mesh->indices[i + 2]];

				if (p->bucket != draw->bucket || q->bucket != draw->bucket || s->bucket != draw->bucket) {
					fprintf(stderr, "a triangle of bucket %d has a vertex of bucket %d\n", draw->bucket,
					    p->bucket);
					return 1;
				}
				triangle(p->x * scale, p->y * scale, q->x * scale, q->y * scale, s->x * scale, s->y * scale,
				    draw->colour[dark]);
			}
		} else {
			const struct line_vertex *v = mesh->vertices;
			/* half the width, in pixels (two a point) */
			double half = style_line_width(draw->bucket, zoom + 0.5, draw->casing);

			for (uint32_t i = first; i + 2 < end; i += 3) {
				double xy[3][2];

				for (int k = 0; k < 3; k++) {
					const struct line_vertex *p = &v[mesh->indices[i + k]];

					if (p->bucket != draw->bucket) {
						fprintf(stderr, "a line triangle of bucket %d has a vertex of bucket %d\n",
						    draw->bucket, p->bucket);
						return 1;
					}
					xy[k][0] = p->x * scale + (double)p->ex / EXTRUDE_ONE * half;
					xy[k][1] = p->y * scale + (double)p->ey / EXTRUDE_ONE * half;
				}
				triangle(xy[0][0], xy[0][1], xy[1][0], xy[1][1], xy[2][0], xy[2][1], draw->colour[dark]);
			}
		}
	}
	for (uint32_t i = 0; i < tile.label_count; i++) {
		const struct tess_label *l = &tile.labels[i];
		uint32_t colour = style_label_looks[l->kind].colour[dark];

		for (int dy = -2; dy <= 2; dy++) {
			for (int dx = -2; dx <= 2; dx++) {
				plot((int)(l->x * scale) + dx, (int)(l->y * scale) + dy, colour);
			}
		}
	}
	write_png(argv[3]);
	{
		uint32_t vertices = tile.fills.vertex_count + tile.lines.vertex_count;

		printf("%s z%d: %u triangles, %u vertices (%u KB), %u labels", argv[1], zoom, tile.triangles, vertices,
		    (unsigned)((tile.fills.vertex_count * sizeof(struct fill_vertex) +
		    tile.lines.vertex_count * sizeof(struct line_vertex) +
		    (tile.fills.index_count + tile.lines.index_count) * sizeof(uint32_t)) / 1024), tile.label_count);
		for (uint32_t i = 0; i < tile.label_count && i < 6; i++) {
			printf("%s%s", i ? ", " : "; e.g. ", tile.labels[i].text);
		}
		printf("\n");
	}
	tess_free(&tile);
	free(data);
	return 0;
}
