#include "CHalltone.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct es_ring {
    float *buf;
    uint32_t cap;   // power of two
    uint32_t mask;
    _Alignas(64) _Atomic uint64_t head; // producer writes, consumer reads
    _Alignas(64) _Atomic uint64_t tail; // consumer writes, producer reads
};

static uint32_t next_pow2(uint32_t v) {
    if (v < 2) return 2;
    v--;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
    return v + 1;
}

es_ring *es_ring_create(uint32_t capacity_floats) {
    es_ring *r = calloc(1, sizeof(es_ring));
    if (!r) return NULL;
    r->cap = next_pow2(capacity_floats);
    r->mask = r->cap - 1;
    r->buf = calloc(r->cap, sizeof(float));
    if (!r->buf) { free(r); return NULL; }
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
    return r;
}

void es_ring_destroy(es_ring *r) {
    if (!r) return;
    free(r->buf);
    free(r);
}

uint32_t es_ring_capacity(const es_ring *r) { return r->cap; }

uint32_t es_ring_available_read(const es_ring *r) {
    uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    return (uint32_t)(head - tail);
}

uint32_t es_ring_available_write(const es_ring *r) {
    return r->cap - es_ring_available_read(r);
}

uint32_t es_ring_write(es_ring *r, const float *src, uint32_t count) {
    uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    uint32_t space = r->cap - (uint32_t)(head - tail);
    if (count > space) count = space;
    if (count == 0) return 0;
    uint32_t idx = (uint32_t)head & r->mask;
    uint32_t first = r->cap - idx;
    if (first > count) first = count;
    memcpy(r->buf + idx, src, first * sizeof(float));
    if (count > first) memcpy(r->buf, src + first, (count - first) * sizeof(float));
    atomic_store_explicit(&r->head, head + count, memory_order_release);
    return count;
}

uint32_t es_ring_read(es_ring *r, float *dst, uint32_t count) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    uint32_t avail = (uint32_t)(head - tail);
    if (count > avail) count = avail;
    if (count == 0) return 0;
    uint32_t idx = (uint32_t)tail & r->mask;
    uint32_t first = r->cap - idx;
    if (first > count) first = count;
    memcpy(dst, r->buf + idx, first * sizeof(float));
    if (count > first) memcpy(dst + first, r->buf, (count - first) * sizeof(float));
    atomic_store_explicit(&r->tail, tail + count, memory_order_release);
    return count;
}

uint32_t es_ring_skip(es_ring *r, uint32_t count) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    uint32_t avail = (uint32_t)(head - tail);
    if (count > avail) count = avail;
    atomic_store_explicit(&r->tail, tail + count, memory_order_release);
    return count;
}

void es_ring_reset(es_ring *r) {
    atomic_store_explicit(&r->head, 0, memory_order_release);
    atomic_store_explicit(&r->tail, 0, memory_order_release);
}
