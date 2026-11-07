#include "bm_config.h"
#include "statistics.h"
#include "box_muller.h"
#include "cordic_log.h"
#include "bm_constants.h"
#include "fixed_math.h"
#include <inttypes.h>
#include <math.h>
#include <string.h>

typedef struct { uint64_t n; double mx, my, xx, yy, xy; } covariance;

static void cov_add(covariance *c, double x, double y)
{
    double dx = x-c->mx, dy = y-c->my;
    ++c->n;
    c->mx += dx/(double)c->n;
    c->my += dy/(double)c->n;
    c->xx += dx*(x-c->mx);
    c->yy += dy*(y-c->my);
    c->xy += dx*(y-c->my);
}

static double correlation(const covariance *c)
{
    return c->n > 1 && c->xx > 0 && c->yy > 0 ? c->xy/sqrt(c->xx*c->yy) : NAN;
}

int bm_qualify(uint64_t seed, uint64_t count, bm_statistics *out)
{
    bm_prng state;
    covariance pair = {0}, lag = {0};
    double m2 = 0, previous = 0;
    if (!count || count > UINT64_C(9007199254740991) || !bm_prng_init(&state, seed)) return 0;
    memset(out, 0, sizeof(*out));
    while (out->count < count) {
        bm_trace t;
        int64_t raw[2];
        bm_generate(&state, &t);
        raw[0] = t.z0; raw[1] = t.z1;
        if (count-out->count >= 2) cov_add(&pair, bm_to_double(t.z0), bm_to_double(t.z1));
        for (unsigned j = 0; j < 2 && out->count < count; ++j) {
            double x = bm_to_double(raw[j]), delta = x-out->mean;
            if (!out->count || raw[j] < out->minimum_raw) out->minimum_raw = raw[j];
            if (!out->count || raw[j] > out->maximum_raw) out->maximum_raw = raw[j];
            if (out->count) cov_add(&lag, previous, x);
            previous = x;
            ++out->count;
            out->mean += delta/(double)out->count;
            m2 += delta*(x-out->mean);
            for (unsigned k = 0; k < 7; ++k) {
                if (x > (double)(k+1)) ++out->positive[k];
                if (x < -(double)(k+1)) ++out->negative[k];
            }
        }
    }
    out->pairs = pair.n;
    out->variance = m2/(double)count;
    out->stddev = sqrt(out->variance);
    out->pair_correlation = correlation(&pair);
    out->lag1_correlation = correlation(&lag);
    if (!bm_prng_init(&state, seed)) return 0;
    for (uint64_t used = 0; used < count;) {
        bm_trace t;
        double values[2];
        bm_generate(&state, &t);
        values[0] = bm_to_double(t.z0); values[1] = bm_to_double(t.z1);
        for (unsigned j = 0; j < 2 && used < count; ++j, ++used)
            for (unsigned k = 0; k < 7; ++k)
                if (fabs(values[j]-out->mean) <= (k+1)*out->stddev) ++out->within[k];
    }
    return 1;
}

void bm_print_statistics(FILE *f, const bm_statistics *s)
{
    fprintf(f, "Statistical qualification\nSamples: %" PRIu64 " (complete pairs: %" PRIu64 ")\n", s->count, s->pairs);
    fprintf(f, "Mean              : %.12g\nPopulation variance: %.12g\nStandard deviation: %.12g\n", s->mean, s->variance, s->stddev);
    fprintf(f, "Relative variance error: %+.8g%%\n", 100*(s->variance-1));
    fprintf(f, "Minimum: %" PRId64 " raw, %.12g standard-normal units\nMaximum: %" PRId64 " raw, %.12g standard-normal units\n",
        s->minimum_raw, bm_to_double(s->minimum_raw), s->maximum_raw, bm_to_double(s->maximum_raw));
    fprintf(f, "Measured standardized extrema: %.12g, %.12g\n",
        s->stddev ? (bm_to_double(s->minimum_raw)-s->mean)/s->stddev : NAN,
        s->stddev ? (bm_to_double(s->maximum_raw)-s->mean)/s->stddev : NAN);
    fprintf(f, "Z0/Z1 correlation: %.9g\nLag-1 correlation: %.9g\n", s->pair_correlation, s->lag1_correlation);
    fprintf(f, "\nFixed thresholds (strict exceedance |Z| > k):\n");
    fprintf(f, "k  Positive  Negative  Total  Measured-P  Gaussian-P  Expected  Relative-error\n");
    for (unsigned k = 0; k < 7; ++k) {
        uint64_t total = s->positive[k]+s->negative[k];
        double p = erfc((k+1)/sqrt(2.0)), expected = (double)s->count*p;
        fprintf(f, "%u  %" PRIu64 "  %" PRIu64 "  %" PRIu64 "  %.9g  %.9g  %.9g  ",
            k+1, s->positive[k], s->negative[k], total, (double)total/(double)s->count, p, expected);
        if (expected >= 20) fprintf(f, "%+.6g%%\n", 100*((double)total/expected-1));
        else fprintf(f, "N/A: too few expected events (<20)\n");
    }
    fprintf(f, "A zero count does not establish absence of a tail. No rare-tail/BER guarantee.\n");
    fprintf(f, "\nSeparate intervals |Z - measured mean| <= k * measured stddev:\n");
    for (unsigned k = 0; k < 7; ++k)
        fprintf(f, "%u: %" PRIu64 " inside, %" PRIu64 " outside, inside probability %.9g\n",
            k+1, s->within[k], s->count-s->within[k], (double)s->within[k]/(double)s->count);
}

void bm_print_configuration(FILE *f)
{
    fprintf(f, "Configuration (S/U = signed/unsigned total width, F = fractional bits):\n");
    fprintf(f, "U1 U%u F%u; U2 U%u F%u\n", (unsigned)BM_U1_BITS, (unsigned)BM_U1_BITS, (unsigned)BM_U2_BITS, (unsigned)BM_U2_BITS);
    fprintf(f, "PRNG xorshift%u; seed 0x%016" PRIx64 "; shifts %s; two successive draws per pair\n",
        (unsigned)BM_PRNG_BITS, (uint64_t)BM_PRNG_SEED, BM_PRNG_BITS == 64 ? "13,7,17" : "13,17,5");
    fprintf(f, "U1 = max(raw,1)/2^U1_BITS (zero aliases one); U2 = raw/2^U2_BITS\n");
    fprintf(f, "LOG X S%u F%u, Y S%u F%u, Z S%u F%u; %u stages, last shift %u\n",
        (unsigned)BM_LOG_X_BITS, (unsigned)BM_LOG_X_FRAC_BITS, (unsigned)BM_LOG_Y_BITS, (unsigned)BM_LOG_Y_FRAC_BITS,
        (unsigned)BM_LOG_Z_BITS, (unsigned)BM_LOG_Z_FRAC_BITS, (unsigned)BM_LOG_ITERATIONS, bm_log_last_shift());
    fprintf(f, "LOG constants U%u F%u; L U%u F%u\n", (unsigned)BM_LOG_CONST_BITS, (unsigned)BM_LOG_CONST_FRAC_BITS,
        (unsigned)BM_LOG_OUTPUT_BITS, (unsigned)BM_LOG_OUTPUT_FRAC_BITS);
    fprintf(f, "SQRT input U%u F%u; output U%u F%u; radicand %u bits, remainder %u bits, %u stages\n",
        (unsigned)BM_SQRT_INPUT_BITS, (unsigned)BM_SQRT_INPUT_FRAC_BITS, (unsigned)BM_SQRT_OUTPUT_BITS, (unsigned)BM_SQRT_OUTPUT_FRAC_BITS,
        (unsigned)BM_SQRT_RAD_BITS, (unsigned)BM_SQRT_REMAINDER_BITS, (unsigned)BM_SQRT_STEPS);
    fprintf(f, "TRIG X S%u F%u, Y S%u F%u, Z S%u F%u turns; %u stages\n",
        (unsigned)BM_TRIG_X_BITS, (unsigned)BM_TRIG_X_FRAC_BITS, (unsigned)BM_TRIG_Y_BITS, (unsigned)BM_TRIG_Y_FRAC_BITS,
        (unsigned)BM_TRIG_Z_BITS, (unsigned)BM_TRIG_Z_FRAC_BITS, (unsigned)BM_TRIG_ITERATIONS);
    fprintf(f, "TRIG constants U%u F%u; inverse gain %.12g\n", (unsigned)BM_TRIG_CONST_BITS, (unsigned)BM_TRIG_CONST_FRAC_BITS,
        (double)fm_constant(bm_inverse_gain_q60[BM_TRIG_ITERATIONS], BM_TRIG_CONST_FRAC_BITS, BM_TRIG_X_FRAC_BITS)
        / (double)(UINT64_C(1) << BM_TRIG_X_FRAC_BITS));
    fprintf(f, "Full product widths: %u/%u bits; binary points F%u/F%u\n",
        (unsigned)(BM_SQRT_OUTPUT_BITS+BM_TRIG_X_BITS), (unsigned)(BM_SQRT_OUTPUT_BITS+BM_TRIG_Y_BITS),
        (unsigned)(BM_SQRT_OUTPUT_FRAC_BITS+BM_TRIG_X_FRAC_BITS), (unsigned)(BM_SQRT_OUTPUT_FRAC_BITS+BM_TRIG_Y_FRAC_BITS));
    fprintf(f, "Output S%u F%u; representable range [%.12g, %.12g]\n", (unsigned)BM_OUTPUT_BITS, (unsigned)BM_OUTPUT_FRAC_BITS,
        bm_to_double(-(INT64_C(1) << (BM_OUTPUT_BITS-1))), bm_to_double((INT64_C(1) << (BM_OUTPUT_BITS-1))-1));
    fprintf(f, "Rounding %d (%s), interface overflow %d (%s); CORDIC registers always wrap\n",
        (int)BM_ROUNDING_MODE, BM_ROUNDING_MODE ? "nearest, ties away" : "floor",
        (int)BM_OVERFLOW_MODE, BM_OVERFLOW_MODE ? "wrap" : "saturate");
    fprintf(f, "Test samples: %" PRIu64 "; ideal finite-U1 radial bound %.12g\n",
        (uint64_t)BM_TEST_SAMPLES, sqrt(2*BM_U1_BITS*log(2.0)));
}

void bm_print_samples(FILE *f, uint64_t seed)
{
    bm_prng p;
    if (!bm_prng_init(&p, seed)) return;
    for (unsigned i = 0; i < 20; ++i) {
        bm_trace t;
        bm_generate(&p, &t);
        fprintf(f, "%2u U1=%" PRIu64 " U2=%" PRIu64 " L=%" PRIu64 " SQRTin=%" PRIu64 " R=%" PRIu64
            " cos=%" PRId64 " sin=%" PRId64 " Z0=%" PRId64 " Z1=%" PRId64 " => %.9g %.9g\n",
            i+1, t.u1, t.u2, t.logarithm, t.sqrt_input, t.radius, t.cosine, t.sine, t.z0, t.z1,
            bm_to_double(t.z0), bm_to_double(t.z1));
        fprintf(f, "   scaled: U1=%.12g U2=%.12g L=%.12g R=%.12g cos=%.12g sin=%.12g\n",
            ldexp((double)t.u1, -BM_U1_BITS), ldexp((double)t.u2, -BM_U2_BITS),
            ldexp((double)t.logarithm, -BM_LOG_OUTPUT_FRAC_BITS),
            ldexp((double)t.radius, -BM_SQRT_OUTPUT_FRAC_BITS),
            ldexp((double)t.cosine, -BM_TRIG_X_FRAC_BITS), ldexp((double)t.sine, -BM_TRIG_Y_FRAC_BITS));
    }
}
