#include "bm_config.h"
#include "fixed_math.h"
#include "sqrt_fixed.h"
#include <assert.h>

uint64_t bm_isqrt(uint64_t n, uint64_t *remainder)
{
    uint64_t root = 0, rem = 0;
    assert(n <= fm_mask(BM_SQRT_RAD_BITS));
    for (unsigned stage = 0; stage < BM_SQRT_STEPS; ++stage) {
        unsigned shift = 2*(BM_SQRT_STEPS-1-stage);
        uint64_t trial;
        rem = ((rem << 2) | ((n >> shift) & 3)) & fm_mask(BM_SQRT_REMAINDER_BITS);
        trial = (root << 2) | 1;
        root <<= 1;
        if (rem >= trial) { rem -= trial; root |= 1; }
    }
    if (remainder) *remainder = rem;
    return root;
}

uint64_t bm_sqrt(uint64_t input)
{
    uint64_t rem, root;
    assert(input <= fm_mask(BM_SQRT_INPUT_BITS));
    root = bm_isqrt(input << BM_SQRT_RAD_SHIFT, &rem);
    if (BM_ROUNDING_MODE && rem > root) ++root;
    return fm_unsigned(root, BM_SQRT_OUTPUT_BITS, BM_OVERFLOW_MODE);
}
