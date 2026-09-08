#ifndef OB_LOOPBACK_H
#define OB_LOOPBACK_H
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#define OB_LOOP_CAPACITY 32768u
#define OB_LOOP_DELAY 1024u
typedef struct {
  _Atomic uint64_t stamp, samples;
} OBFrame;
typedef struct {
  OBFrame frames[OB_LOOP_CAPACITY];
} OBLoopback;
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2,
               "Loopback requires atomic 64-bit access");

static inline void ob_loop_clear(OBLoopback *r) {
  for (unsigned i = 0; i < OB_LOOP_CAPACITY; ++i)
    atomic_store(&r->frames[i].stamp, 0);
}
static inline void ob_loop_write(OBLoopback *r, int64_t time, const float *in,
                                 uint32_t n) {
  for (uint32_t i = 0; i < n; ++i) {
    if (time + (int64_t)i < 0)
      continue;
    uint64_t t = time + i, packed;
    memcpy(&packed, in + 2 * i, sizeof(packed));
    OBFrame *f = &r->frames[t % OB_LOOP_CAPACITY];
    atomic_store(&f->stamp, 0);
    atomic_store(&f->samples, packed);
    atomic_store(&f->stamp, t + 1);
  }
}
static inline void ob_loop_read(OBLoopback *r, int64_t time, float *out,
                                uint32_t n) {
  for (uint32_t i = 0; i < n; ++i) {
    int64_t t = time + i - OB_LOOP_DELAY;
    uint64_t packed = 0;
    if (t >= 0) {
      OBFrame *f = &r->frames[(uint64_t)t % OB_LOOP_CAPACITY];
      uint64_t before = atomic_load(&f->stamp);
      packed = atomic_load(&f->samples);
      uint64_t after = atomic_load(&f->stamp);
      if (before != (uint64_t)t + 1 || after != before)
        packed = 0;
    }
    memcpy(out + 2 * i, &packed, sizeof(packed));
  }
}
#endif
