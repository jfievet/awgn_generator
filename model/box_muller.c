#include "bm_config.h"
#include "box_muller.h"
#include "fixed_math.h"
#include "cordic_log.h"
#include "cordic_trig.h"
#include "sqrt_fixed.h"

void bm_transform(uint64_t u1, uint64_t u2, bm_trace *out)
{
    out->u1 = u1 ? u1 : 1;
    out->u2 = u2;
    out->logarithm = bm_log(out->u1);
    out->sqrt_input = fm_uscale(out->logarithm, BM_LOG_OUTPUT_FRAC_BITS, BM_SQRT_INPUT_FRAC_BITS,
        BM_SQRT_INPUT_BITS, BM_ROUNDING_MODE, BM_OVERFLOW_MODE);
    out->radius = bm_sqrt(out->sqrt_input);
    bm_sincos(u2, &out->cosine, &out->sine);
    out->z0 = fm_scale((int64_t)out->radius * out->cosine,
        BM_SQRT_OUTPUT_FRAC_BITS+BM_TRIG_X_FRAC_BITS, BM_OUTPUT_FRAC_BITS,
        BM_OUTPUT_BITS, BM_ROUNDING_MODE, BM_OVERFLOW_MODE);
    out->z1 = fm_scale((int64_t)out->radius * out->sine,
        BM_SQRT_OUTPUT_FRAC_BITS+BM_TRIG_Y_FRAC_BITS, BM_OUTPUT_FRAC_BITS,
        BM_OUTPUT_BITS, BM_ROUNDING_MODE, BM_OVERFLOW_MODE);
}

void bm_generate(bm_prng *state, bm_trace *out)
{
    uint64_t u1, u2;
    bm_uniform_pair(state, &u1, &u2);
    bm_transform(u1, u2, out);
}

double bm_to_double(int64_t raw)
{
    return (double)raw / (double)(UINT64_C(1) << BM_OUTPUT_FRAC_BITS);
}
