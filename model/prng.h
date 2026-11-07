#ifndef PRNG_H
#define PRNG_H
#include <stdint.h>
typedef struct { uint64_t state; } bm_prng;
int bm_prng_init(bm_prng *p, uint64_t seed);
uint64_t bm_prng_next(bm_prng *p);
void bm_uniform_pair(bm_prng *p, uint64_t *u1, uint64_t *u2);
#endif
