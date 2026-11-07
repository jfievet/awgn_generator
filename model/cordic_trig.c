#include "bm_config.h"
#include "bm_constants.h"
#include "fixed_math.h"
#include "cordic_trig.h"
#include <assert.h>

void bm_sincos(uint64_t phase, int64_t *cosine, int64_t *sine)
{
    unsigned quadrant = (unsigned)(phase >> (BM_U2_BITS-2));
    uint64_t residual = phase & fm_mask(BM_U2_BITS-2);
    int64_t x = (int64_t)fm_constant(bm_inverse_gain_q60[BM_TRIG_ITERATIONS], BM_TRIG_CONST_FRAC_BITS, BM_TRIG_X_FRAC_BITS);
    int64_t y = 0;
    int64_t z = (int64_t)fm_uscale(residual, BM_U2_BITS, BM_TRIG_Z_FRAC_BITS, BM_TRIG_Z_BITS-1, 0, 0);
    assert(phase <= fm_mask(BM_U2_BITS));
    for (unsigned stage = 0; stage < BM_TRIG_ITERATIONS; ++stage) {
        int64_t xs = fm_asr(x, stage), ys = fm_asr(y, stage);
        int64_t a = (int64_t)fm_constant(bm_atan_turn_q60[stage], BM_TRIG_CONST_FRAC_BITS, BM_TRIG_Z_FRAC_BITS);
        int positive = z >= 0;
        x = fm_wrap(positive ? x-ys : x+ys, BM_TRIG_X_BITS);
        y = fm_wrap(positive ? y+xs : y-xs, BM_TRIG_Y_BITS);
        z = fm_wrap(positive ? z-a : z+a, BM_TRIG_Z_BITS);
    }
    switch (quadrant) {
    case 0: *cosine = x; *sine = y; break;
    case 1: *cosine = -y; *sine = x; break;
    case 2: *cosine = -x; *sine = -y; break;
    default: *cosine = y; *sine = -x; break;
    }
}
