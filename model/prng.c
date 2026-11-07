#include "bm_config.h"
#include "prng.h"
#include "fixed_math.h"
#include <assert.h>

int bm_prng_init(bm_prng *p, uint64_t seed)
{
    if (!seed || (BM_PRNG_BITS == 32 && seed > UINT32_MAX)) return 0;
    p->state = seed;
    return 1;
}

uint64_t bm_prng_next(bm_prng *p)
{
#if BM_PRNG_BITS == 64
    uint64_t x = p->state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
#else
    uint32_t x = (uint32_t)p->state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
#endif
    assert(p->state != 0);
    p->state = x;
    return x;
}

void bm_uniform_pair(bm_prng *p, uint64_t *u1, uint64_t *u2)
{
    *u1 = bm_prng_next(p) >> (BM_PRNG_BITS-BM_U1_BITS);
    *u2 = bm_prng_next(p) >> (BM_PRNG_BITS-BM_U2_BITS);
    if (!*u1) *u1 = 1;
}
