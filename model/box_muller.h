#ifndef BOX_MULLER_H
#define BOX_MULLER_H
#include "prng.h"
typedef struct {
    uint64_t u1, u2, logarithm, sqrt_input, radius;
    int64_t cosine, sine, z0, z1;
} bm_trace;
void bm_transform(uint64_t u1, uint64_t u2, bm_trace *out);
void bm_generate(bm_prng *state, bm_trace *out);
/* Reporting only; never called by the integer datapath. */
double bm_to_double(int64_t raw);
#endif
