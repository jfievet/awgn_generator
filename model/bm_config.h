#ifndef BM_CONFIG_H
#define BM_CONFIG_H
#include <stdint.h>

/* All defaults can be overridden with -D. Widths include the sign bit. */
#ifndef BM_U1_BITS
#define BM_U1_BITS 32
#endif
#ifndef BM_U2_BITS
#define BM_U2_BITS 24
#endif
#ifndef BM_PRNG_BITS
#define BM_PRNG_BITS 64
#endif
#ifndef BM_PRNG_SEED
#define BM_PRNG_SEED UINT64_C(0x123456789abcdef1)
#endif
#ifndef BM_LOG_XY_BITS
#define BM_LOG_XY_BITS 32
#endif
#ifndef BM_LOG_X_BITS
#define BM_LOG_X_BITS BM_LOG_XY_BITS
#endif
#ifndef BM_LOG_Y_BITS
#define BM_LOG_Y_BITS BM_LOG_XY_BITS
#endif
#ifndef BM_LOG_X_FRAC_BITS
#define BM_LOG_X_FRAC_BITS (BM_LOG_X_BITS - 4)
#endif
#ifndef BM_LOG_Y_FRAC_BITS
#define BM_LOG_Y_FRAC_BITS BM_LOG_X_FRAC_BITS
#endif
#ifndef BM_LOG_Z_BITS
#define BM_LOG_Z_BITS 32
#endif
#ifndef BM_LOG_Z_FRAC_BITS
#define BM_LOG_Z_FRAC_BITS (BM_LOG_Z_BITS - 4)
#endif
#ifndef BM_LOG_ITERATIONS
#define BM_LOG_ITERATIONS 32
#endif
#ifndef BM_LOG_CONST_BITS
#define BM_LOG_CONST_BITS 32
#endif
#ifndef BM_LOG_CONST_FRAC_BITS
#define BM_LOG_CONST_FRAC_BITS (BM_LOG_CONST_BITS - 2)
#endif
#ifndef BM_LOG_OUTPUT_BITS
#define BM_LOG_OUTPUT_BITS 32
#endif
#ifndef BM_LOG_OUTPUT_FRAC_BITS
#define BM_LOG_OUTPUT_FRAC_BITS 24
#endif
#ifndef BM_SQRT_INPUT_BITS
#define BM_SQRT_INPUT_BITS 32
#endif
#ifndef BM_SQRT_INPUT_FRAC_BITS
#define BM_SQRT_INPUT_FRAC_BITS 24
#endif
#ifndef BM_SQRT_OUTPUT_BITS
#define BM_SQRT_OUTPUT_BITS 24
#endif
#ifndef BM_SQRT_OUTPUT_FRAC_BITS
#define BM_SQRT_OUTPUT_FRAC_BITS 20
#endif
#define BM_SQRT_RAD_SHIFT (2 * BM_SQRT_OUTPUT_FRAC_BITS - BM_SQRT_INPUT_FRAC_BITS)
#define BM_SQRT_RAD_BITS (BM_SQRT_INPUT_BITS + BM_SQRT_RAD_SHIFT)
#define BM_SQRT_STEPS ((BM_SQRT_RAD_BITS + 1) / 2)
#ifndef BM_SQRT_REMAINDER_BITS
#define BM_SQRT_REMAINDER_BITS (BM_SQRT_STEPS + 2)
#endif
#ifndef BM_TRIG_XY_BITS
#define BM_TRIG_XY_BITS 24
#endif
#ifndef BM_TRIG_X_BITS
#define BM_TRIG_X_BITS BM_TRIG_XY_BITS
#endif
#ifndef BM_TRIG_Y_BITS
#define BM_TRIG_Y_BITS BM_TRIG_XY_BITS
#endif
#ifndef BM_TRIG_X_FRAC_BITS
#define BM_TRIG_X_FRAC_BITS (BM_TRIG_X_BITS - 3)
#endif
#ifndef BM_TRIG_Y_FRAC_BITS
#define BM_TRIG_Y_FRAC_BITS BM_TRIG_X_FRAC_BITS
#endif
#ifndef BM_TRIG_Z_BITS
#define BM_TRIG_Z_BITS 24
#endif
#ifndef BM_TRIG_Z_FRAC_BITS
#define BM_TRIG_Z_FRAC_BITS (BM_TRIG_Z_BITS - 2)
#endif
#ifndef BM_TRIG_ITERATIONS
#define BM_TRIG_ITERATIONS 24
#endif
#ifndef BM_TRIG_CONST_BITS
#define BM_TRIG_CONST_BITS 24
#endif
#ifndef BM_TRIG_CONST_FRAC_BITS
#define BM_TRIG_CONST_FRAC_BITS (BM_TRIG_CONST_BITS - 1)
#endif
#ifndef BM_OUTPUT_BITS
#define BM_OUTPUT_BITS 24
#endif
#ifndef BM_OUTPUT_FRAC_BITS
#define BM_OUTPUT_FRAC_BITS 18
#endif
/* 0: floor; 1: nearest, ties away from zero. */
#ifndef BM_ROUNDING_MODE
#define BM_ROUNDING_MODE 0
#endif
/* Interface overflow: 0: saturate; 1: two's-complement wrap. */
#ifndef BM_OVERFLOW_MODE
#define BM_OVERFLOW_MODE 0
#endif
#ifndef BM_TEST_SAMPLES
#define BM_TEST_SAMPLES UINT64_C(1000000000)
#endif

#define BM_CHECK(c, message) _Static_assert((c), message)
#define BM_SIGNED_FORMAT(w, f) \
    BM_CHECK((w) >= 4 && (w) <= 60 && (f) >= 4 && (f) <= 48 && (f) <= (w)-2, "unsupported signed format: " #w)
#define BM_UNSIGNED_FORMAT(w, f) \
    BM_CHECK((w) >= 4 && (w) <= 60 && (f) >= 0 && (f) < (w), "unsupported unsigned format: " #w)
BM_CHECK(BM_PRNG_BITS == 32 || BM_PRNG_BITS == 64, "PRNG width must be 32 or 64");
BM_CHECK(BM_PRNG_SEED != 0 && (BM_PRNG_BITS == 64 || BM_PRNG_SEED <= UINT32_MAX), "invalid PRNG seed");
BM_CHECK(BM_U1_BITS >= 2 && BM_U1_BITS <= 48 && BM_U1_BITS <= BM_PRNG_BITS, "unsupported U1 resolution");
BM_CHECK(BM_U2_BITS >= 3 && BM_U2_BITS <= 48 && BM_U2_BITS <= BM_PRNG_BITS, "unsupported U2 resolution");
BM_SIGNED_FORMAT(BM_LOG_X_BITS, BM_LOG_X_FRAC_BITS);
BM_SIGNED_FORMAT(BM_LOG_Y_BITS, BM_LOG_Y_FRAC_BITS);
BM_SIGNED_FORMAT(BM_LOG_Z_BITS, BM_LOG_Z_FRAC_BITS);
BM_CHECK(BM_LOG_X_FRAC_BITS == BM_LOG_Y_FRAC_BITS, "LOG X/Y binary points must match");
BM_CHECK(BM_LOG_X_FRAC_BITS <= BM_LOG_X_BITS-3 && BM_LOG_Y_FRAC_BITS <= BM_LOG_Y_BITS-3, "LOG needs X/Y headroom");
BM_CHECK(BM_LOG_ITERATIONS >= 4 && BM_LOG_ITERATIONS <= 60, "LOG iterations must be 4..60");
BM_UNSIGNED_FORMAT(BM_LOG_CONST_BITS, BM_LOG_CONST_FRAC_BITS);
BM_CHECK(BM_LOG_CONST_FRAC_BITS >= 4 && BM_LOG_CONST_FRAC_BITS <= 48, "LOG constants need 4..48 fractional bits");
BM_UNSIGNED_FORMAT(BM_LOG_OUTPUT_BITS, BM_LOG_OUTPUT_FRAC_BITS);
BM_CHECK(BM_LOG_OUTPUT_BITS - BM_LOG_OUTPUT_FRAC_BITS >= 7, "L requires at least 7 integer bits");
BM_UNSIGNED_FORMAT(BM_SQRT_INPUT_BITS, BM_SQRT_INPUT_FRAC_BITS);
BM_CHECK(BM_SQRT_INPUT_BITS - BM_SQRT_INPUT_FRAC_BITS >= 7, "sqrt input requires 7 integer bits");
BM_UNSIGNED_FORMAT(BM_SQRT_OUTPUT_BITS, BM_SQRT_OUTPUT_FRAC_BITS);
BM_CHECK(BM_SQRT_RAD_SHIFT >= 0 && BM_SQRT_RAD_SHIFT <= 60 && BM_SQRT_RAD_BITS <= 62, "sqrt radicand must fit 62 bits without a right shift");
BM_CHECK(BM_SQRT_OUTPUT_BITS >= BM_SQRT_STEPS && BM_SQRT_REMAINDER_BITS >= BM_SQRT_STEPS+2 && BM_SQRT_REMAINDER_BITS <= 63, "sqrt root/remainder too narrow");
BM_SIGNED_FORMAT(BM_TRIG_X_BITS, BM_TRIG_X_FRAC_BITS);
BM_SIGNED_FORMAT(BM_TRIG_Y_BITS, BM_TRIG_Y_FRAC_BITS);
BM_SIGNED_FORMAT(BM_TRIG_Z_BITS, BM_TRIG_Z_FRAC_BITS);
BM_CHECK(BM_TRIG_X_FRAC_BITS == BM_TRIG_Y_FRAC_BITS, "TRIG X/Y binary points must match");
BM_CHECK(BM_TRIG_X_FRAC_BITS <= BM_TRIG_X_BITS-3 && BM_TRIG_Y_FRAC_BITS <= BM_TRIG_Y_BITS-3, "TRIG needs X/Y headroom");
BM_CHECK(BM_TRIG_ITERATIONS >= 4 && BM_TRIG_ITERATIONS <= 60, "TRIG iterations must be 4..60");
BM_UNSIGNED_FORMAT(BM_TRIG_CONST_BITS, BM_TRIG_CONST_FRAC_BITS);
BM_CHECK(BM_TRIG_CONST_FRAC_BITS >= 4 && BM_TRIG_CONST_FRAC_BITS <= 48, "TRIG constants need 4..48 fractional bits");
BM_CHECK(BM_SQRT_OUTPUT_BITS + BM_TRIG_X_BITS <= 62 && BM_SQRT_OUTPUT_BITS + BM_TRIG_Y_BITS <= 62, "full products exceed safe signed width");
BM_SIGNED_FORMAT(BM_OUTPUT_BITS, BM_OUTPUT_FRAC_BITS);
BM_CHECK(BM_ROUNDING_MODE == 0 || BM_ROUNDING_MODE == 1, "invalid rounding mode");
BM_CHECK(BM_OVERFLOW_MODE == 0 || BM_OVERFLOW_MODE == 1, "invalid overflow mode");
BM_CHECK(BM_TEST_SAMPLES > 0 && BM_TEST_SAMPLES <= UINT64_C(9007199254740991), "sample count must be 1..2^53-1");
#endif
