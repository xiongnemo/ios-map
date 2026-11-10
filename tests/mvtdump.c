// mvtdump: a vector tile's layers as mvt.c reads them -- features by type, keys, and a few names. For checking the
// reader on a computer: cc -O1 -o mvtdump tests/mvtdump.c mvt.c && ./mvtdump TILE.pbf
#include <stdio.h>
#include <stdlib.h>

#include "../mvt.h"

int
main(int argc, char **argv)
{
	for (int a = 1; a < argc; a++) {
		FILE *f = fopen(argv[a], "rb");
		struct mvt_tile tile;
		char error[200];
		uint8_t *data;
		long size;

		if (f == NULL) {
			perror(argv[a]);
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
		if (mvt_read(data, (size_t)size, &tile, error, sizeof(error)) != 0) {
			printf("%s: %s\n", argv[a], error);
			return 1;
		}
		printf("%s: %u layers\n", argv[a], tile.layer_count);
		for (uint32_t i = 0; i < tile.layer_count; i++) {
			const struct mvt_layer *l = &tile.layers[i];
			uint32_t by[4] = { 0 }, points = 0, broken = 0;
			const char *name = NULL;
			uint32_t name_len = 0;

			for (uint32_t k = 0; k < l->feature_count; k++) {
				const struct mvt_feature *ft = &l->features[k];
				int32_t *xy;
				uint32_t n, *parts, np;
				const struct mvt_value *v = mvt_value_of(l, ft, "name");

				by[ft->type]++;
				if (mvt_geometry(ft, &xy, &n, &parts, &np) == 0) {
					points += n;
					free(xy);
					free(parts);
				} else {
					broken++;
				}
				if (name == NULL && v != NULL && v->kind == MVT_STRING) {
					name = v->string;
					name_len = v->length;
				}
			}
			printf("  %-20.*s extent %u: %u features (%u points %u lines %u polygons), %u points, %u broken; "
			    "%u keys %u values%s%.*s\n", (int)l->name.length, l->name.s, l->extent, l->feature_count, by[1], by[2],
			    by[3], points, broken, l->key_count, l->value_count, name != NULL ? "; a name: " : "", (int)name_len,
			    name != NULL ? name : "");
		}
		mvt_free(&tile);
		free(data);
	}
	return 0;
}
