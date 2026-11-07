#include "fixed_math.h"
#include <assert.h>
#include <limits.h>

uint64_t fm_mask(unsigned bits)
{
    assert(bits >= 1 && bits <= 63);
    return (UINT64_C(1) << bits) - 1;
}

static uint64_t magnitude(int64_t v)
{
    return v < 0 ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;
}

int64_t fm_asr(int64_t v, unsigned n)
{
    if (n == 0) return v;
    if (n >= 64) return v < 0 ? -1 : 0;
    return v < 0 ? -1 - (int64_t)((~(uint64_t)v) >> n) : (int64_t)((uint64_t)v >> n);
}

static int64_t decode(uint64_t u, unsigned bits)
{
    uint64_t mask = fm_mask(bits);
    u &= mask;
    return (u & (UINT64_C(1) << (bits-1))) ? -1 - (int64_t)(mask ^ u) : (int64_t)u;
}

int64_t fm_wrap(int64_t v, unsigned bits) { return decode((uint64_t)v, bits); }

int64_t fm_signed(int64_t v, unsigned bits, int overflow)
{
    int64_t hi = (int64_t)((UINT64_C(1) << (bits-1)) - 1);
    int64_t lo = -hi - 1;
    if (overflow) return fm_wrap(v, bits);
    return v > hi ? hi : (v < lo ? lo : v);
}

uint64_t fm_unsigned(uint64_t v, unsigned bits, int overflow)
{
    uint64_t mask = fm_mask(bits);
    return overflow ? v & mask : (v > mask ? mask : v);
}

static uint64_t right_round(uint64_t v, unsigned n, int nearest)
{
    uint64_t q;
    if (!n) return v;
    assert(n <= 63);
    q = v >> n;
    if (nearest && (v & fm_mask(n)) >= (UINT64_C(1) << (n-1))) ++q;
    return q;
}

int64_t fm_scale(int64_t v, unsigned from, unsigned to, unsigned bits, int rounding, int overflow)
{
    uint64_t mag = magnitude(v), limit, u;
    if (from > to) {
        unsigned n = from-to;
        if (!rounding) return fm_signed(fm_asr(v, n), bits, overflow);
        mag = right_round(mag, n, 1);
        /* n >= 1 means magnitude now fits INT64_MAX. */
        return fm_signed(v < 0 ? -(int64_t)mag : (int64_t)mag, bits, overflow);
    }
    limit = (UINT64_C(1) << (bits-1)) - (v < 0 ? 0 : 1);
    if (!overflow && mag > (limit >> (to-from)))
        return v < 0 ? -(int64_t)(UINT64_C(1) << (bits-1)) : (int64_t)limit;
    u = mag << (to-from); /* unsigned wrap is intentional */
    return decode(v < 0 ? UINT64_C(0)-u : u, bits);
}

uint64_t fm_uscale(uint64_t v, unsigned from, unsigned to, unsigned bits, int rounding, int overflow)
{
    if (from > to) return fm_unsigned(right_round(v, from-to, rounding), bits, overflow);
    if (!overflow && v > (fm_mask(bits) >> (to-from))) return fm_mask(bits);
    return fm_unsigned(v << (to-from), bits, overflow);
}

uint64_t fm_constant(uint64_t q60, unsigned cf, unsigned df)
{
    uint64_t c = right_round(q60, 60-cf, 1);
    return df >= cf ? c << (df-cf) : right_round(c, cf-df, 1);
}
