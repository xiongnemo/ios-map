// earcut.c: see earcut.h. A port to C of Mapbox's earcut 2.2.4 (https://github.com/mapbox/earcut), whose licence is:
//
//   ISC License. Copyright (c) 2016, Mapbox.
//   Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby
//   granted, provided that the above copyright notice and this permission notice appear in all copies.
//   THE SOFTWARE IS PROVIDED "AS IS" AND ISC DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
//   WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL ISC BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
//   CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF
//   CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS
//   SOFTWARE.
//
// The algorithm is the original's, step for step: the polygon as a circular doubly linked list, holes bridged into the
// outer ring (Eberly), ears cut with a z-order index for big polygons, and three passes of repair when no ear is left.
// What is C's own: nodes come from blocks that never move (the lists hold pointers into them), and the triangles grow
// in one array.
#include "earcut.h"

#include <float.h>
#include <math.h>
#include <stdlib.h>

struct node {
	uint32_t i;                     /* the point's index in the input */
	double x, y;
	struct node *prev, *next;       /* the ring */
	int32_t z;                      /* z-order of the point, 0 until indexed */
	struct node *prev_z, *next_z;   /* the z-order list */
	int steiner;
};

#define BLOCK_NODES 2048

struct block {
	struct block *next;
	uint32_t used;
	struct node nodes[BLOCK_NODES];
};

struct ec {
	struct block *blocks;
	uint32_t *out;
	size_t count, room;
	int no_memory;
};

static struct node *
make_node(struct ec *e, uint32_t i, double x, double y)
{
	struct node *p;

	if (e->blocks == NULL || e->blocks->used == BLOCK_NODES) {
		struct block *b = malloc(sizeof(*b));

		if (b == NULL) {
			e->no_memory = 1;
			return NULL;
		}
		b->next = e->blocks;
		b->used = 0;
		e->blocks = b;
	}
	p = &e->blocks->nodes[e->blocks->used++];
	p->i = i;
	p->x = x;
	p->y = y;
	p->prev = p->next = p->prev_z = p->next_z = NULL;
	p->z = 0;
	p->steiner = 0;
	return p;
}

static void
emit(struct ec *e, uint32_t a, uint32_t b, uint32_t c)
{
	if (e->count + 3 > e->room) {
		size_t room = e->room ? e->room * 2 : 192;
		uint32_t *grown = realloc(e->out, room * sizeof(uint32_t));

		if (grown == NULL) {
			e->no_memory = 1;
			return;
		}
		e->out = grown;
		e->room = room;
	}
	e->out[e->count++] = a;
	e->out[e->count++] = b;
	e->out[e->count++] = c;
}

/* -- geometry */

static double
area(const struct node *p, const struct node *q, const struct node *r)
{
	return (q->y - p->y) * (r->x - q->x) - (q->x - p->x) * (r->y - q->y);
}

static int
equals(const struct node *a, const struct node *b)
{
	return a->x == b->x && a->y == b->y;
}

static int
sign(double v)
{
	return v > 0 ? 1 : v < 0 ? -1 : 0;
}

/* for collinear points p, q, r: whether q lies on the segment pr */
static int
on_segment(const struct node *p, const struct node *q, const struct node *r)
{
	return q->x <= fmax(p->x, r->x) && q->x >= fmin(p->x, r->x) && q->y <= fmax(p->y, r->y) && q->y >= fmin(p->y, r->y);
}

static int
intersects(const struct node *p1, const struct node *q1, const struct node *p2, const struct node *q2)
{
	int o1 = sign(area(p1, q1, p2)), o2 = sign(area(p1, q1, q2)), o3 = sign(area(p2, q2, p1)),
	    o4 = sign(area(p2, q2, q1));

	if (o1 != o2 && o3 != o4) {
		return 1;
	}
	return (o1 == 0 && on_segment(p1, p2, q1)) || (o2 == 0 && on_segment(p1, q2, q1)) ||
	    (o3 == 0 && on_segment(p2, p1, q2)) || (o4 == 0 && on_segment(p2, q1, q2));
}

static int
point_in_triangle(double ax, double ay, double bx, double by, double cx, double cy, double px, double py)
{
	return (cx - px) * (ay - py) >= (ax - px) * (cy - py) && (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
	    (bx - px) * (cy - py) >= (cx - px) * (by - py);
}

static int
intersects_polygon(const struct node *a, const struct node *b)
{
	const struct node *p = a;

	do {
		if (p->i != a->i && p->next->i != a->i && p->i != b->i && p->next->i != b->i && intersects(p, p->next, a, b)) {
			return 1;
		}
		p = p->next;
	} while (p != a);
	return 0;
}

static int
locally_inside(const struct node *a, const struct node *b)
{
	return area(a->prev, a, a->next) < 0 ? area(a, b, a->next) >= 0 && area(a, a->prev, b) >= 0 :
	    area(a, b, a->prev) < 0 || area(a, a->next, b) < 0;
}

static int
middle_inside(const struct node *a, const struct node *b)
{
	const struct node *p = a;
	double px = (a->x + b->x) / 2, py = (a->y + b->y) / 2;
	int inside = 0;

	do {
		if (((p->y > py) != (p->next->y > py)) && p->next->y != p->y &&
		    (px < (p->next->x - p->x) * (py - p->y) / (p->next->y - p->y) + p->x)) {
			inside = !inside;
		}
		p = p->next;
	} while (p != a);
	return inside;
}

static int
is_valid_diagonal(const struct node *a, const struct node *b)
{
	return a->next->i != b->i && a->prev->i != b->i && !intersects_polygon(a, b) &&
	    ((locally_inside(a, b) && locally_inside(b, a) && middle_inside(a, b) &&
	      (area(a->prev, a, b->prev) != 0 || area(a, b->prev, b) != 0)) ||
	     (equals(a, b) && area(a->prev, a, a->next) > 0 && area(b->prev, b, b->next) > 0));
}

/* -- the linked list */

static struct node *
insert_node(struct ec *e, uint32_t i, double x, double y, struct node *last)
{
	struct node *p = make_node(e, i, x, y);

	if (p == NULL) {
		return NULL;
	}
	if (last == NULL) {
		p->prev = p->next = p;
	} else {
		p->next = last->next;
		p->prev = last;
		last->next->prev = p;
		last->next = p;
	}
	return p;
}

static void
remove_node(struct node *p)
{
	p->next->prev = p->prev;
	p->prev->next = p->next;
	if (p->prev_z != NULL) {
		p->prev_z->next_z = p->next_z;
	}
	if (p->next_z != NULL) {
		p->next_z->prev_z = p->prev_z;
	}
}

static double
signed_area(const double *xy, uint32_t start, uint32_t end)
{
	double sum = 0;

	for (uint32_t i = start, j = end - 1; i < end; j = i++) {
		sum += (xy[2 * j] - xy[2 * i]) * (xy[2 * i + 1] + xy[2 * j + 1]);
	}
	return sum;
}

/* a ring as a circular list, in the winding asked for */
static struct node *
linked_list(struct ec *e, const double *xy, uint32_t start, uint32_t end, int clockwise)
{
	struct node *last = NULL;

	if (end <= start) {
		return NULL;
	}
	if (clockwise == (signed_area(xy, start, end) > 0)) {
		for (uint32_t i = start; i < end; i++) {
			last = insert_node(e, i, xy[2 * i], xy[2 * i + 1], last);
			if (last == NULL) {
				return NULL;
			}
		}
	} else {
		for (uint32_t i = end; i-- > start;) {
			last = insert_node(e, i, xy[2 * i], xy[2 * i + 1], last);
			if (last == NULL) {
				return NULL;
			}
		}
	}
	if (last != NULL && equals(last, last->next)) {
		remove_node(last);
		last = last->next;
	}
	return last;
}

/* points that repeat, or lie on the line through their neighbours, out */
static struct node *
filter_points(struct node *start, struct node *end)
{
	struct node *p;
	int again;

	if (start == NULL) {
		return start;
	}
	if (end == NULL) {
		end = start;
	}
	p = start;
	do {
		again = 0;
		if (!p->steiner && (equals(p, p->next) || area(p->prev, p, p->next) == 0)) {
			remove_node(p);
			p = end = p->prev;
			if (p == p->next) {
				break;
			}
			again = 1;
		} else {
			p = p->next;
		}
	} while (again || p != end);
	return end;
}

/* two vertices joined by a bridge: a ring split in two, or a hole merged into the ring */
static struct node *
split_polygon(struct ec *e, struct node *a, struct node *b)
{
	struct node *a2 = make_node(e, a->i, a->x, a->y), *b2 = make_node(e, b->i, b->x, b->y), *an = a->next,
	    *bp = b->prev;

	if (a2 == NULL || b2 == NULL) {
		return NULL;
	}
	a->next = b;
	b->prev = a;
	a2->next = an;
	an->prev = a2;
	b2->next = a2;
	a2->prev = b2;
	bp->next = b2;
	b2->prev = bp;
	return b2;
}

/* -- the z-order index */

static int32_t
z_order(double x, double y, double min_x, double min_y, double inv_size)
{
	uint32_t ix = (uint32_t)(int32_t)((x - min_x) * inv_size), iy = (uint32_t)(int32_t)((y - min_y) * inv_size);

	ix = (ix | (ix << 8)) & 0x00FF00FF;
	ix = (ix | (ix << 4)) & 0x0F0F0F0F;
	ix = (ix | (ix << 2)) & 0x33333333;
	ix = (ix | (ix << 1)) & 0x55555555;
	iy = (iy | (iy << 8)) & 0x00FF00FF;
	iy = (iy | (iy << 4)) & 0x0F0F0F0F;
	iy = (iy | (iy << 2)) & 0x33333333;
	iy = (iy | (iy << 1)) & 0x55555555;
	return (int32_t)(ix | (iy << 1));
}

/* Simon Tatham's merge sort of a linked list, by z */
static struct node *
sort_linked(struct node *list)
{
	int merges;
	int in_size = 1;

	do {
		struct node *p = list, *e, *tail = NULL;

		list = NULL;
		merges = 0;
		while (p != NULL) {
			struct node *q = p;
			int p_size = 0, q_size;

			merges++;
			for (int i = 0; i < in_size; i++) {
				p_size++;
				q = q->next_z;
				if (q == NULL) {
					break;
				}
			}
			q_size = in_size;
			while (p_size > 0 || (q_size > 0 && q != NULL)) {
				if (p_size != 0 && (q_size == 0 || q == NULL || p->z <= q->z)) {
					e = p;
					p = p->next_z;
					p_size--;
				} else {
					e = q;
					q = q->next_z;
					q_size--;
				}
				if (tail != NULL) {
					tail->next_z = e;
				} else {
					list = e;
				}
				e->prev_z = tail;
				tail = e;
			}
			p = q;
		}
		tail->next_z = NULL;
		in_size *= 2;
	} while (merges > 1);
	return list;
}

static void
index_curve(struct node *start, double min_x, double min_y, double inv_size)
{
	struct node *p = start;

	do {
		if (p->z == 0) {
			p->z = z_order(p->x, p->y, min_x, min_y, inv_size);
		}
		p->prev_z = p->prev;
		p->next_z = p->next;
		p = p->next;
	} while (p != start);
	p->prev_z->next_z = NULL;
	p->prev_z = NULL;
	(void)sort_linked(p);
}

/* -- ears */

static int
is_ear(const struct node *ear)
{
	const struct node *a = ear->prev, *b = ear, *c = ear->next, *p;
	double ax = a->x, bx = b->x, cx = c->x, ay = a->y, by = b->y, cy = c->y, x0, y0, x1, y1;

	if (area(a, b, c) >= 0) {
		return 0;       /* reflex: no ear */
	}
	x0 = fmin(ax, fmin(bx, cx));
	y0 = fmin(ay, fmin(by, cy));
	x1 = fmax(ax, fmax(bx, cx));
	y1 = fmax(ay, fmax(by, cy));
	for (p = c->next; p != a; p = p->next) {
		if (p->x >= x0 && p->x <= x1 && p->y >= y0 && p->y <= y1 && point_in_triangle(ax, ay, bx, by, cx, cy, p->x, p->y) &&
		    area(p->prev, p, p->next) >= 0) {
			return 0;
		}
	}
	return 1;
}

static int
in_ear(const struct node *p, const struct node *a, const struct node *c, double ax, double ay, double bx, double by,
    double cx, double cy, double x0, double y0, double x1, double y1)
{
	return p->x >= x0 && p->x <= x1 && p->y >= y0 && p->y <= y1 && p != a && p != c &&
	    point_in_triangle(ax, ay, bx, by, cx, cy, p->x, p->y) && area(p->prev, p, p->next) >= 0;
}

static int
is_ear_hashed(const struct node *ear, double min_x, double min_y, double inv_size)
{
	const struct node *a = ear->prev, *b = ear, *c = ear->next, *p, *n;
	double ax = a->x, bx = b->x, cx = c->x, ay = a->y, by = b->y, cy = c->y, x0, y0, x1, y1;
	int32_t min_z, max_z;

	if (area(a, b, c) >= 0) {
		return 0;
	}
	x0 = fmin(ax, fmin(bx, cx));
	y0 = fmin(ay, fmin(by, cy));
	x1 = fmax(ax, fmax(bx, cx));
	y1 = fmax(ay, fmax(by, cy));
	min_z = z_order(x0, y0, min_x, min_y, inv_size);
	max_z = z_order(x1, y1, min_x, min_y, inv_size);
	p = ear->prev_z;
	n = ear->next_z;
	while (p != NULL && p->z >= min_z && n != NULL && n->z <= max_z) {
		if (in_ear(p, a, c, ax, ay, bx, by, cx, cy, x0, y0, x1, y1)) {
			return 0;
		}
		p = p->prev_z;
		if (in_ear(n, a, c, ax, ay, bx, by, cx, cy, x0, y0, x1, y1)) {
			return 0;
		}
		n = n->next_z;
	}
	for (; p != NULL && p->z >= min_z; p = p->prev_z) {
		if (in_ear(p, a, c, ax, ay, bx, by, cx, cy, x0, y0, x1, y1)) {
			return 0;
		}
	}
	for (; n != NULL && n->z <= max_z; n = n->next_z) {
		if (in_ear(n, a, c, ax, ay, bx, by, cx, cy, x0, y0, x1, y1)) {
			return 0;
		}
	}
	return 1;
}

static struct node *
cure_local_intersections(struct ec *e, struct node *start)
{
	struct node *p = start;

	do {
		struct node *a = p->prev, *b = p->next->next;

		if (!equals(a, b) && intersects(a, p, p->next, b) && locally_inside(a, b) && locally_inside(b, a)) {
			emit(e, a->i, p->i, b->i);
			remove_node(p);
			remove_node(p->next);
			p = start = b;
		}
		p = p->next;
	} while (p != start);
	return filter_points(p, NULL);
}

static void earcut_linked(struct ec *e, struct node *ear, double min_x, double min_y, double inv_size, int pass);

/* a diagonal that splits what is left in two, each half cut on its own */
static void
split_earcut(struct ec *e, struct node *start, double min_x, double min_y, double inv_size)
{
	struct node *a = start;

	do {
		struct node *b = a->next->next;

		while (b != a->prev) {
			if (a->i != b->i && is_valid_diagonal(a, b)) {
				struct node *c = split_polygon(e, a, b);

				if (c == NULL) {
					return;
				}
				a = filter_points(a, a->next);
				c = filter_points(c, c->next);
				earcut_linked(e, a, min_x, min_y, inv_size, 0);
				earcut_linked(e, c, min_x, min_y, inv_size, 0);
				return;
			}
			b = b->next;
		}
		a = a->next;
	} while (a != start);
}

static void
earcut_linked(struct ec *e, struct node *ear, double min_x, double min_y, double inv_size, int pass)
{
	struct node *stop;

	if (ear == NULL || e->no_memory) {
		return;
	}
	if (pass == 0 && inv_size != 0) {
		index_curve(ear, min_x, min_y, inv_size);
	}
	stop = ear;
	while (ear->prev != ear->next) {
		struct node *prev = ear->prev, *next = ear->next;

		if (inv_size != 0 ? is_ear_hashed(ear, min_x, min_y, inv_size) : is_ear(ear)) {
			emit(e, prev->i, ear->i, next->i);
			remove_node(ear);
			ear = next->next;       /* (skipping the next vertex makes fewer slivers) */
			stop = next->next;
			continue;
		}
		ear = next;
		if (ear == stop) {
			/* no ear left: filter the points and try again, then cure small self-intersections, then split */
			if (pass == 0) {
				earcut_linked(e, filter_points(ear, NULL), min_x, min_y, inv_size, 1);
			} else if (pass == 1) {
				ear = cure_local_intersections(e, filter_points(ear, NULL));
				earcut_linked(e, ear, min_x, min_y, inv_size, 2);
			} else if (pass == 2) {
				split_earcut(e, ear, min_x, min_y, inv_size);
			}
			break;
		}
	}
}

/* -- holes */

static struct node *
leftmost(struct node *start)
{
	struct node *p = start, *best = start;

	do {
		if (p->x < best->x || (p->x == best->x && p->y < best->y)) {
			best = p;
		}
		p = p->next;
	} while (p != start);
	return best;
}

static int
sector_contains_sector(const struct node *m, const struct node *p)
{
	return area(m->prev, m, p->prev) < 0 && area(p->next, m, m->next) < 0;
}

/* David Eberly's bridge from a hole's leftmost point to the outer ring */
static struct node *
find_hole_bridge(struct node *hole, struct node *outer)
{
	struct node *p = outer, *m = NULL, *stop;
	double hx = hole->x, hy = hole->y, qx = -DBL_MAX, mx, my, tan_min = DBL_MAX;

	do {
		if (hy <= p->y && hy >= p->next->y && p->next->y != p->y) {
			double x = p->x + (hy - p->y) * (p->next->x - p->x) / (p->next->y - p->y);

			if (x <= hx && x > qx) {
				qx = x;
				m = p->x < p->next->x ? p : p->next;
				if (x == hx) {
					return m;       /* the hole touches the outer segment */
				}
			}
		}
		p = p->next;
	} while (p != outer);
	if (m == NULL) {
		return NULL;
	}
	stop = m;
	mx = m->x;
	my = m->y;
	p = m;
	do {
		if (hx >= p->x && p->x >= mx && hx != p->x &&
		    point_in_triangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, p->x, p->y)) {
			double t = fabs(hy - p->y) / (hx - p->x);

			if (locally_inside(p, hole) &&
			    (t < tan_min || (t == tan_min && (p->x > m->x || (p->x == m->x && sector_contains_sector(m, p)))))) {
				m = p;
				tan_min = t;
			}
		}
		p = p->next;
	} while (p != stop);
	return m;
}

static struct node *
eliminate_hole(struct ec *e, struct node *hole, struct node *outer)
{
	struct node *bridge = find_hole_bridge(hole, outer), *reverse;

	if (bridge == NULL) {
		return outer;
	}
	reverse = split_polygon(e, bridge, hole);
	if (reverse == NULL) {
		return outer;
	}
	(void)filter_points(reverse, reverse->next);
	return filter_points(bridge, bridge->next);
}

static int
by_x(const void *a, const void *b)
{
	double ax = (*(struct node *const *)a)->x, bx = (*(struct node *const *)b)->x;

	return ax < bx ? -1 : ax > bx ? 1 : 0;
}

static struct node *
eliminate_holes(struct ec *e, const double *xy, uint32_t points, const uint32_t *holes, uint32_t hole_count,
    struct node *outer)
{
	struct node **queue = malloc((size_t)hole_count * sizeof(*queue));
	uint32_t queued = 0;

	if (queue == NULL) {
		e->no_memory = 1;
		return outer;
	}
	for (uint32_t i = 0; i < hole_count; i++) {
		uint32_t start = holes[i], end = i + 1 < hole_count ? holes[i + 1] : points;
		struct node *list = linked_list(e, xy, start, end, 0);

		if (list == NULL) {
			continue;
		}
		if (list == list->next) {
			list->steiner = 1;
		}
		queue[queued++] = leftmost(list);
	}
	qsort(queue, queued, sizeof(*queue), by_x);
	for (uint32_t i = 0; i < queued; i++) {
		outer = eliminate_hole(e, queue[i], outer);
	}
	free(queue);
	return outer;
}

/* -- the whole */

long
earcut(const double *xy, uint32_t points, const uint32_t *holes, uint32_t hole_count, uint32_t **out)
{
	struct ec e = { NULL, NULL, 0, 0, 0 };
	uint32_t outer_end = hole_count != 0 ? holes[0] : points;
	struct node *outer = linked_list(&e, xy, 0, outer_end, 1);
	double min_x = 0, min_y = 0, inv_size = 0;

	*out = NULL;
	if (outer != NULL && outer->next != outer->prev && !e.no_memory) {
		if (hole_count != 0) {
			outer = eliminate_holes(&e, xy, points, holes, hole_count, outer);
		}
		/* (a polygon of more than 80 points is indexed by z-order for the ear test) */
		if (points > 80) {
			double max_x = -DBL_MAX, max_y = -DBL_MAX;

			min_x = min_y = DBL_MAX;
			for (uint32_t i = 0; i < outer_end; i++) {
				min_x = fmin(min_x, xy[2 * i]);
				min_y = fmin(min_y, xy[2 * i + 1]);
				max_x = fmax(max_x, xy[2 * i]);
				max_y = fmax(max_y, xy[2 * i + 1]);
			}
			inv_size = fmax(max_x - min_x, max_y - min_y);
			inv_size = inv_size != 0 ? 32767 / inv_size : 0;
		}
		earcut_linked(&e, outer, min_x, min_y, inv_size, 0);
	}
	while (e.blocks != NULL) {
		struct block *next = e.blocks->next;

		free(e.blocks);
		e.blocks = next;
	}
	if (e.no_memory) {
		free(e.out);
		return -1;
	}
	*out = e.out;
	return (long)e.count;
}
