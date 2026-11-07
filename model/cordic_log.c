#include "bm_config.h"
#include "bm_constants.h"
#include "fixed_math.h"
#include "cordic_log.h"
#include <assert.h>

unsigned bm_log_last_shift(void)
{
    unsigned shift = 1, repeat = 4, repeated = 0, last = 1;
    for (unsigned stage = 0; stage < BM_LOG_ITERATIONS; ++stage) {
        last = shift;
        if (shift == repeat && !repeated) repeated = 1;
        else { if (shift == repeat) repeat = 3*repeat+1; ++shift; repeated = 0; }
    }
    return last;
}

uint64_t bm_log(uint64_t u)
{
    unsigned top = 0, exponent, shift = 1, repeat = 4, repeated = 0;
    int64_t x, y, z = 0, one = INT64_C(1) << BM_LOG_X_FRAC_BITS;
    int64_t result;
    uint64_t mantissa;
    assert(u <= fm_mask(BM_U1_BITS));
    if (!u) u = 1;
    /* Fixed-length leading-one detector, directly unrollable in RTL. */
    for (unsigned bit = 0; bit < BM_U1_BITS; ++bit)
        if (u & (UINT64_C(1) << bit)) top = bit;
    exponent = BM_U1_BITS-top;
    mantissa = fm_uscale(u, top, BM_LOG_X_FRAC_BITS, BM_LOG_X_BITS-1, 0, 0);
    x = (int64_t)mantissa + one;
    y = (int64_t)mantissa - one;
    for (unsigned stage = 0; stage < BM_LOG_ITERATIONS; ++stage) {
        int64_t xs = fm_asr(x, shift), ys = fm_asr(y, shift);
        int64_t angle = (int64_t)fm_constant(bm_atanh_q60[shift], BM_LOG_CONST_FRAC_BITS, BM_LOG_Z_FRAC_BITS);
        int positive = y >= 0;
        /* All three right-hand sides use the previous stage. */
        x = fm_wrap(positive ? x-ys : x+ys, BM_LOG_X_BITS);
        y = fm_wrap(positive ? y-xs : y+xs, BM_LOG_Y_BITS);
        z = fm_wrap(positive ? z+angle : z-angle, BM_LOG_Z_BITS);
        if (shift == repeat && !repeated) repeated = 1;
        else { if (shift == repeat) repeat = 3*repeat+1; ++shift; repeated = 0; }
    }
    result = 2*(int64_t)exponent*(int64_t)fm_constant(BM_LN2_Q60, BM_LOG_CONST_FRAC_BITS, BM_LOG_Z_FRAC_BITS) - 4*z;
    /* Near U1=1, approximation can be a fraction of an LSB below zero. */
    return result <= 0 ? 0 : fm_uscale((uint64_t)result, BM_LOG_Z_FRAC_BITS,
        BM_LOG_OUTPUT_FRAC_BITS, BM_LOG_OUTPUT_BITS, BM_ROUNDING_MODE, BM_OVERFLOW_MODE);
}
