#ifndef CHALLTONE_H
#define CHALLTONE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lock-free single-producer / single-consumer ring of floats.
/// Safe to call es_ring_write from one real-time thread and es_ring_read from
/// another; neither allocates, locks, or blocks.
typedef struct es_ring es_ring;

es_ring *es_ring_create(uint32_t capacity_floats);
void es_ring_destroy(es_ring *r);
uint32_t es_ring_capacity(const es_ring *r);
uint32_t es_ring_available_read(const es_ring *r);
uint32_t es_ring_available_write(const es_ring *r);
/// Returns the number of floats actually written (less than count when full).
uint32_t es_ring_write(es_ring *r, const float *src, uint32_t count);
/// Returns the number of floats actually read (less than count when empty).
uint32_t es_ring_read(es_ring *r, float *dst, uint32_t count);
/// Discards up to count floats from the read side. Returns how many were dropped.
uint32_t es_ring_skip(es_ring *r, uint32_t count);
/// Consumer-side reset. Only call when the producer is stopped.
void es_ring_reset(es_ring *r);

#ifdef __cplusplus
}
#endif
#endif

/* Minimal atomics for counters shared between a real-time callback and a worker thread. */
static inline void es_atomic_add_u32(uint32_t *p, uint32_t delta) { __atomic_fetch_add(p, delta, __ATOMIC_RELAXED); }
static inline uint32_t es_atomic_exchange_u32(uint32_t *p, uint32_t value) { return __atomic_exchange_n(p, value, __ATOMIC_ACQ_REL); }
static inline uint32_t es_atomic_load_u32(const uint32_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void es_atomic_add_u64(uint64_t *p, uint64_t delta) { __atomic_fetch_add(p, delta, __ATOMIC_RELAXED); }
static inline uint64_t es_atomic_load_u64(const uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void es_atomic_store_u64(uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
