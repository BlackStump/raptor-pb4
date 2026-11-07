/*
 * ydiff -- how much of the picture changed between two YUV420SP frames.
 *
 *   ydiff PREV CUR WIDTH HEIGHT CELL THRESH
 *
 * Splits the luma plane into CELLxCELL cells, compares each cell's mean
 * brightness between the two frames and counts the cells whose mean moved
 * by more than THRESH (0-255). Prints
 *
 *   changed=<cells> cells=<total> dmean=<mean |difference| over all cells>
 *
 * which is what wlight parses (it reads fields 2 and 6 after replacing '='
 * with ' '). Only the Y plane is read, so NV12 and NV21 are the same here.
 */
#include <stdio.h>
#include <stdlib.h>

static unsigned char *load(const char *path, size_t n)
{
	unsigned char *b = malloc(n);
	FILE *f = fopen(path, "rb");

	if (!b || !f || fread(b, 1, n, f) != n) {
		if (f)
			fclose(f);
		free(b);
		return NULL;
	}
	fclose(f);
	return b;
}

int main(int argc, char **argv)
{
	unsigned char *a, *b;
	long w, h, cell, thresh, cx, cy, x, y, changed = 0, cells = 0, dsum = 0;

	if (argc != 7) {
		fprintf(stderr, "usage: ydiff PREV CUR WIDTH HEIGHT CELL THRESH\n");
		return 2;
	}
	w = atol(argv[3]);
	h = atol(argv[4]);
	cell = atol(argv[5]);
	thresh = atol(argv[6]);
	if (w <= 0 || h <= 0 || cell <= 0)
		return 2;

	a = load(argv[1], (size_t)(w * h));
	b = load(argv[2], (size_t)(w * h));
	if (!a || !b) {
		fprintf(stderr, "ydiff: cannot read frames\n");
		return 1;
	}

	for (cy = 0; cy + cell <= h; cy += cell) {
		for (cx = 0; cx + cell <= w; cx += cell) {
			long sa = 0, sb = 0, d;

			for (y = cy; y < cy + cell; y++)
				for (x = cx; x < cx + cell; x++) {
					sa += a[y * w + x];
					sb += b[y * w + x];
				}
			d = labs(sa - sb) / (cell * cell);
			dsum += d;
			if (d > thresh)
				changed++;
			cells++;
		}
	}
	printf("changed=%ld cells=%ld dmean=%ld\n", changed, cells, cells ? dsum / cells : 0);
	free(a);
	free(b);
	return 0;
}
