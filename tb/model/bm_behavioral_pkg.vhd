-- VHDL-2008 behavioral port of the integer C datapath.
-- No real arithmetic; all sample values and host intermediates are vectors.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.bm_constants_pkg.all;

package bm_behavioral_pkg is
    subtype bm_u64 is unsigned(63 downto 0);
    subtype bm_s64 is signed(63 downto 0);

    -- Names correspond to bm_config.h without the BM_ prefix. XY fields are
    -- aliases retained for configuration traceability; X/Y are effective widths.
    type bm_config_t is record
        u1_bits, u2_bits, prng_bits : integer;
        prng_seed : bm_u64;
        log_xy_bits, log_x_bits, log_y_bits : integer;
        log_x_frac_bits, log_y_frac_bits : integer;
        log_z_bits, log_z_frac_bits, log_iterations : integer;
        log_const_bits, log_const_frac_bits : integer;
        log_output_bits, log_output_frac_bits : integer;
        sqrt_input_bits, sqrt_input_frac_bits : integer;
        sqrt_output_bits, sqrt_output_frac_bits, sqrt_remainder_bits : integer;
        trig_xy_bits, trig_x_bits, trig_y_bits : integer;
        trig_x_frac_bits, trig_y_frac_bits : integer;
        trig_z_bits, trig_z_frac_bits, trig_iterations : integer;
        trig_const_bits, trig_const_frac_bits : integer;
        output_bits, output_frac_bits, rounding_mode, overflow_mode : integer;
    end record;

    -- Same fields and sign interpretation as C bm_trace. Narrow results are
    -- zero/sign extended to 64 bits after their configured quantization.
    type bm_trace_t is record
        u1, u2, logarithm, sqrt_input, radius : bm_u64;
        cosine, sine, z0, z1 : bm_s64;
    end record;

    function bm_config_valid(c : bm_config_t) return boolean;
    function bm_sqrt_rad_shift(c : bm_config_t) return integer;
    function bm_sqrt_rad_bits(c : bm_config_t) return integer;
    function bm_sqrt_steps(c : bm_config_t) return integer;

    function fm_mask(bits : positive) return bm_u64;
    function fm_asr(v : bm_s64; n : natural) return bm_s64;
    function fm_wrap(v : bm_s64; bits : positive) return bm_s64;
    function fm_signed(v : bm_s64; bits : positive; overflow : natural) return bm_s64;
    function fm_unsigned(v : bm_u64; bits : positive; overflow : natural) return bm_u64;
    function fm_scale(v : bm_s64; from_frac, to_frac : natural;
                      bits : positive; rounding, overflow : natural) return bm_s64;
    function fm_uscale(v : bm_u64; from_frac, to_frac : natural;
                       bits : positive; rounding, overflow : natural) return bm_u64;
    function fm_constant(q60 : bm_u64; constant_frac, destination_frac : natural) return bm_u64;

    function bm_prng_next(c : bm_config_t; state : bm_u64) return bm_u64;
    function bm_log(c : bm_config_t; raw_u1 : bm_u64) return bm_u64;
    procedure bm_isqrt(constant c : in bm_config_t; constant n : in bm_u64;
                       variable root, remainder : out bm_u64);
    function bm_sqrt(c : bm_config_t; input_value : bm_u64) return bm_u64;
    procedure bm_sincos(constant c : in bm_config_t; constant phase : in bm_u64;
                        variable cosine, sine : out bm_s64);
    procedure bm_transform(constant c : in bm_config_t;
                           constant u1, u2 : in bm_u64;
                           variable trace : out bm_trace_t);
    procedure bm_generate(constant c : in bm_config_t;
                          variable state : inout bm_u64;
                          variable trace : out bm_trace_t);
end package bm_behavioral_pkg;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.bm_constants_pkg.all;

package body bm_behavioral_pkg is
    constant U_ZERO : bm_u64 := (others => '0');
    constant U_ONE  : bm_u64 := to_unsigned(1, 64);

    function bm_sqrt_rad_shift(c : bm_config_t) return integer is
    begin
        return 2*c.sqrt_output_frac_bits - c.sqrt_input_frac_bits;
    end function;

    function bm_sqrt_rad_bits(c : bm_config_t) return integer is
    begin
        return c.sqrt_input_bits + bm_sqrt_rad_shift(c);
    end function;

    function bm_sqrt_steps(c : bm_config_t) return integer is
    begin
        return (bm_sqrt_rad_bits(c)+1)/2;
    end function;

    function bm_config_valid(c : bm_config_t) return boolean is
        variable valid : boolean := true;
        procedure require(constant condition : in boolean; constant message_text : in string) is
        begin
            assert condition report "Box-Muller configuration: " & message_text severity failure;
            if not condition then valid := false; end if;
        end procedure;
        procedure signed_format(constant w, f : in integer; constant label_text : in string) is
        begin
            require(w >= 4 and w <= 60 and f >= 4 and f <= 48 and f <= w-2,
                    "unsupported signed format " & label_text);
        end procedure;
        procedure unsigned_format(constant w, f : in integer; constant label_text : in string) is
        begin
            require(w >= 4 and w <= 60 and f >= 0 and f < w,
                    "unsupported unsigned format " & label_text);
        end procedure;
    begin
        require(c.prng_bits = 32 or c.prng_bits = 64, "PRNG width must be 32 or 64");
        require(not is_x(std_logic_vector(c.prng_seed)), "PRNG seed must contain only 0/1");
        require(c.prng_seed /= U_ZERO and
                (c.prng_bits = 64 or c.prng_seed(63 downto 32) = to_unsigned(0, 32)),
                "invalid PRNG seed");
        require(c.u1_bits >= 2 and c.u1_bits <= 48 and c.u1_bits <= c.prng_bits,
                "unsupported U1 resolution");
        require(c.u2_bits >= 3 and c.u2_bits <= 48 and c.u2_bits <= c.prng_bits,
                "unsupported U2 resolution");
        signed_format(c.log_x_bits, c.log_x_frac_bits, "LOG X");
        signed_format(c.log_y_bits, c.log_y_frac_bits, "LOG Y");
        signed_format(c.log_z_bits, c.log_z_frac_bits, "LOG Z");
        require(c.log_x_frac_bits = c.log_y_frac_bits, "LOG X/Y binary points must match");
        require(c.log_x_frac_bits <= c.log_x_bits-3 and c.log_y_frac_bits <= c.log_y_bits-3,
                "LOG needs X/Y headroom");
        require(c.log_iterations >= 4 and c.log_iterations <= 60, "LOG iterations must be 4..60");
        unsigned_format(c.log_const_bits, c.log_const_frac_bits, "LOG constants");
        require(c.log_const_frac_bits >= 4 and c.log_const_frac_bits <= 48,
                "LOG constants need 4..48 fractional bits");
        unsigned_format(c.log_output_bits, c.log_output_frac_bits, "LOG output");
        require(c.log_output_bits-c.log_output_frac_bits >= 7, "L requires 7 integer bits");
        unsigned_format(c.sqrt_input_bits, c.sqrt_input_frac_bits, "SQRT input");
        require(c.sqrt_input_bits-c.sqrt_input_frac_bits >= 7, "SQRT input requires 7 integer bits");
        unsigned_format(c.sqrt_output_bits, c.sqrt_output_frac_bits, "SQRT output");
        require(bm_sqrt_rad_shift(c) >= 0 and bm_sqrt_rad_shift(c) <= 60 and bm_sqrt_rad_bits(c) <= 62,
                "SQRT radicand must fit 62 bits without a right shift");
        require(c.sqrt_output_bits >= bm_sqrt_steps(c) and
                c.sqrt_remainder_bits >= bm_sqrt_steps(c)+2 and c.sqrt_remainder_bits <= 63,
                "SQRT root/remainder too narrow");
        signed_format(c.trig_x_bits, c.trig_x_frac_bits, "TRIG X");
        signed_format(c.trig_y_bits, c.trig_y_frac_bits, "TRIG Y");
        signed_format(c.trig_z_bits, c.trig_z_frac_bits, "TRIG Z");
        require(c.trig_x_frac_bits = c.trig_y_frac_bits, "TRIG X/Y binary points must match");
        require(c.trig_x_frac_bits <= c.trig_x_bits-3 and c.trig_y_frac_bits <= c.trig_y_bits-3,
                "TRIG needs X/Y headroom");
        require(c.trig_iterations >= 4 and c.trig_iterations <= 60, "TRIG iterations must be 4..60");
        unsigned_format(c.trig_const_bits, c.trig_const_frac_bits, "TRIG constants");
        require(c.trig_const_frac_bits >= 4 and c.trig_const_frac_bits <= 48,
                "TRIG constants need 4..48 fractional bits");
        require(c.sqrt_output_bits+c.trig_x_bits <= 62 and c.sqrt_output_bits+c.trig_y_bits <= 62,
                "full products exceed safe signed width");
        signed_format(c.output_bits, c.output_frac_bits, "output");
        require(c.rounding_mode = 0 or c.rounding_mode = 1, "invalid rounding mode");
        require(c.overflow_mode = 0 or c.overflow_mode = 1, "invalid overflow mode");
        return valid;
    end function;

    function fm_mask(bits : positive) return bm_u64 is
        variable result : bm_u64 := U_ZERO;
    begin
        assert bits <= 63 report "fm_mask: width must be 1..63" severity failure;
        result(bits-1 downto 0) := (others => '1');
        return result;
    end function;

    function fm_asr(v : bm_s64; n : natural) return bm_s64 is
    begin
        -- numeric_std signed shift_right replicates the sign, even for n >= 64.
        return shift_right(v, n);
    end function;

    function fm_wrap(v : bm_s64; bits : positive) return bm_s64 is
    begin
        assert bits <= 63 report "fm_wrap: width must be 1..63" severity failure;
        -- Slice first: narrowing signed resize alone preserves the OLD sign bit
        -- and is NOT the C mask/decode operation. Widening this slice is exact.
        return resize(v(bits-1 downto 0), 64);
    end function;

    function fm_signed(v : bm_s64; bits : positive; overflow : natural) return bm_s64 is
        variable hi, lo : bm_s64;
    begin
        if overflow /= 0 then return fm_wrap(v, bits); end if;
        hi := signed(shift_left(U_ONE, bits-1)-U_ONE);
        lo := -hi-to_signed(1, 64);
        if v > hi then return hi; end if;
        if v < lo then return lo; end if;
        return v;
    end function;

    function fm_unsigned(v : bm_u64; bits : positive; overflow : natural) return bm_u64 is
        variable mask : bm_u64 := fm_mask(bits);
    begin
        if overflow /= 0 then return v and mask; end if;
        if v > mask then return mask; end if;
        return v;
    end function;

    function right_round(v : bm_u64; n, nearest : natural) return bm_u64 is
        variable q : bm_u64;
    begin
        if n = 0 then return v; end if;
        assert n <= 63 report "right_round: shift exceeds 63" severity failure;
        q := shift_right(v, n);
        if nearest /= 0 and (v and fm_mask(n)) >= shift_left(U_ONE, n-1) then
            q := q+U_ONE;
        end if;
        return q;
    end function;

    function fm_scale(v : bm_s64; from_frac, to_frac : natural;
                      bits : positive; rounding, overflow : natural) return bm_s64 is
        variable mag, limit, word_value : bm_u64;
        variable scaled : bm_s64;
    begin
        if v(63) = '1' then mag := (not unsigned(v))+U_ONE;
        else mag := unsigned(v); end if;
        if from_frac > to_frac then
            if rounding = 0 then
                return fm_signed(fm_asr(v, from_frac-to_frac), bits, overflow);
            end if;
            mag := right_round(mag, from_frac-to_frac, 1);
            if v(63) = '1' then scaled := signed((not mag)+U_ONE);
            else scaled := signed(mag); end if;
            return fm_signed(scaled, bits, overflow);
        end if;
        limit := shift_left(U_ONE, bits-1);
        if v(63) = '0' then limit := limit-U_ONE; end if;
        if overflow = 0 and mag > shift_right(limit, to_frac-from_frac) then
            if v(63) = '1' then return -signed(shift_left(U_ONE, bits-1)); end if;
            return signed(limit);
        end if;
        -- 64-bit unsigned wrap matches the C intermediate before mask/decode.
        word_value := shift_left(mag, to_frac-from_frac);
        if v(63) = '1' then word_value := (not word_value)+U_ONE; end if;
        return fm_wrap(signed(word_value), bits);
    end function;

    function fm_uscale(v : bm_u64; from_frac, to_frac : natural;
                       bits : positive; rounding, overflow : natural) return bm_u64 is
    begin
        if from_frac > to_frac then
            return fm_unsigned(right_round(v, from_frac-to_frac, rounding), bits, overflow);
        end if;
        if overflow = 0 and v > shift_right(fm_mask(bits), to_frac-from_frac) then
            return fm_mask(bits);
        end if;
        return fm_unsigned(shift_left(v, to_frac-from_frac), bits, overflow);
    end function;

    function fm_constant(q60 : bm_u64; constant_frac, destination_frac : natural) return bm_u64 is
        variable value : bm_u64;
    begin
        value := right_round(q60, 60-constant_frac, 1);
        if destination_frac >= constant_frac then
            return shift_left(value, destination_frac-constant_frac);
        end if;
        return right_round(value, constant_frac-destination_frac, 1);
    end function;

    function mul_s64(a, b : bm_s64) return bm_s64 is
        variable product_value : signed(127 downto 0);
    begin
        product_value := a*b;
        assert resize(product_value(63 downto 0), 128) = product_value
            report "signed product exceeds the C int64_t domain" severity failure;
        return product_value(63 downto 0);
    end function;

    function bm_prng_next(c : bm_config_t; state : bm_u64) return bm_u64 is
        variable x64 : bm_u64 := state;
        variable x32 : unsigned(31 downto 0) := state(31 downto 0);
    begin
        assert state /= U_ZERO report "PRNG state must not be zero" severity failure;
        if c.prng_bits = 64 then
            x64 := x64 xor shift_left(x64, 13);
            x64 := x64 xor shift_right(x64, 7);
            x64 := x64 xor shift_left(x64, 17);
            return x64;
        end if;
        assert state(63 downto 32) = to_unsigned(0, 32)
            report "PRNG32 state has nonzero upper bits" severity failure;
        -- These shifts act on 32 bits at EVERY operation, just like uint32_t.
        x32 := x32 xor shift_left(x32, 13);
        x32 := x32 xor shift_right(x32, 17);
        x32 := x32 xor shift_left(x32, 5);
        return resize(x32, 64);
    end function;

    function bm_log(c : bm_config_t; raw_u1 : bm_u64) return bm_u64 is
        variable u, mantissa : bm_u64 := raw_u1;
        variable top : natural := 0;
        variable exponent_value : natural;
        variable shift_index : positive := 1;
        variable repeat_index : positive := 4;
        variable repeated : boolean := false;
        variable x, y, z, one, xs, ys, angle, result_value : bm_s64;
        variable positive_y : boolean;
    begin
        assert u <= fm_mask(c.u1_bits) report "U1 exceeds its configured width" severity failure;
        if u = U_ZERO then u := U_ONE; end if;
        for bit_index in 0 to c.u1_bits-1 loop
            if u(bit_index) = '1' then top := bit_index; end if;
        end loop;
        exponent_value := c.u1_bits-top;
        one := signed(shift_left(U_ONE, c.log_x_frac_bits));
        mantissa := fm_uscale(u, top, c.log_x_frac_bits, c.log_x_bits-1, 0, 0);
        x := signed(mantissa)+one;
        y := signed(mantissa)-one;
        z := (others => '0');
        for stage in 0 to c.log_iterations-1 loop
            xs := fm_asr(x, shift_index);
            ys := fm_asr(y, shift_index);
            angle := signed(fm_constant(BM_ATANH_Q60(shift_index),
                                       c.log_const_frac_bits, c.log_z_frac_bits));
            positive_y := y >= to_signed(0, 64);
            -- Saved xs/ys ensure that both updates use the OLD x/y values.
            if positive_y then
                x := fm_wrap(x-ys, c.log_x_bits);
                y := fm_wrap(y-xs, c.log_y_bits);
                z := fm_wrap(z+angle, c.log_z_bits);
            else
                x := fm_wrap(x+ys, c.log_x_bits);
                y := fm_wrap(y+xs, c.log_y_bits);
                z := fm_wrap(z-angle, c.log_z_bits);
            end if;
            if shift_index = repeat_index and not repeated then
                repeated := true;
            else
                if shift_index = repeat_index then repeat_index := 3*repeat_index+1; end if;
                shift_index := shift_index+1;
                repeated := false;
            end if;
        end loop;
        result_value := mul_s64(to_signed(2*exponent_value, 64),
            signed(fm_constant(BM_LN2_Q60, c.log_const_frac_bits, c.log_z_frac_bits)))
            - shift_left(z, 2);
        if result_value <= to_signed(0, 64) then return U_ZERO; end if;
        return fm_uscale(unsigned(result_value), c.log_z_frac_bits,
            c.log_output_frac_bits, c.log_output_bits, c.rounding_mode, c.overflow_mode);
    end function;

    procedure bm_isqrt(constant c : in bm_config_t; constant n : in bm_u64;
                       variable root, remainder : out bm_u64) is
        variable r, rem_value, trial : bm_u64 := U_ZERO;
        variable bit_shift : natural;
    begin
        assert n <= fm_mask(bm_sqrt_rad_bits(c))
            report "SQRT radicand exceeds its configured width" severity failure;
        for stage in 0 to bm_sqrt_steps(c)-1 loop
            bit_shift := 2*(bm_sqrt_steps(c)-1-stage);
            rem_value := (shift_left(rem_value, 2) or
                (shift_right(n, bit_shift) and to_unsigned(3, 64))) and fm_mask(c.sqrt_remainder_bits);
            trial := shift_left(r, 2) or U_ONE;
            r := shift_left(r, 1);
            if rem_value >= trial then
                rem_value := rem_value-trial;
                r := r or U_ONE;
            end if;
        end loop;
        root := r;
        remainder := rem_value;
    end procedure;

    function bm_sqrt(c : bm_config_t; input_value : bm_u64) return bm_u64 is
        variable root, remainder : bm_u64;
    begin
        assert input_value <= fm_mask(c.sqrt_input_bits)
            report "SQRT input exceeds its configured width" severity failure;
        bm_isqrt(c, shift_left(input_value, bm_sqrt_rad_shift(c)), root, remainder);
        if c.rounding_mode /= 0 and remainder > root then root := root+U_ONE; end if;
        return fm_unsigned(root, c.sqrt_output_bits, c.overflow_mode);
    end function;

    procedure bm_sincos(constant c : in bm_config_t; constant phase : in bm_u64;
                        variable cosine, sine : out bm_s64) is
        variable quadrant : natural;
        variable residual : bm_u64;
        variable x, y, z, xs, ys, angle : bm_s64;
        variable positive_z : boolean;
    begin
        assert phase <= fm_mask(c.u2_bits) report "U2 exceeds its configured width" severity failure;
        -- Only this reduced two-bit quantity is converted to native integer.
        quadrant := to_integer(shift_right(phase, c.u2_bits-2));
        residual := phase and fm_mask(c.u2_bits-2);
        x := signed(fm_constant(BM_INVERSE_GAIN_Q60(c.trig_iterations),
                               c.trig_const_frac_bits, c.trig_x_frac_bits));
        y := (others => '0');
        z := signed(fm_uscale(residual, c.u2_bits, c.trig_z_frac_bits, c.trig_z_bits-1, 0, 0));
        for stage in 0 to c.trig_iterations-1 loop
            xs := fm_asr(x, stage);
            ys := fm_asr(y, stage);
            angle := signed(fm_constant(BM_ATAN_TURN_Q60(stage),
                                       c.trig_const_frac_bits, c.trig_z_frac_bits));
            positive_z := z >= to_signed(0, 64);
            if positive_z then
                x := fm_wrap(x-ys, c.trig_x_bits);
                y := fm_wrap(y+xs, c.trig_y_bits);
                z := fm_wrap(z-angle, c.trig_z_bits);
            else
                x := fm_wrap(x+ys, c.trig_x_bits);
                y := fm_wrap(y-xs, c.trig_y_bits);
                z := fm_wrap(z+angle, c.trig_z_bits);
            end if;
        end loop;
        case quadrant is
            when 0 => cosine := x;  sine := y;
            when 1 => cosine := -y; sine := x;
            when 2 => cosine := -x; sine := -y;
            when others => cosine := y; sine := -x;
        end case;
    end procedure;

    procedure bm_transform(constant c : in bm_config_t;
                           constant u1, u2 : in bm_u64;
                           variable trace : out bm_trace_t) is
        variable t : bm_trace_t;
    begin
        t.u1 := u1;
        if t.u1 = U_ZERO then t.u1 := U_ONE; end if;
        t.u2 := u2;
        t.logarithm := bm_log(c, t.u1);
        t.sqrt_input := fm_uscale(t.logarithm, c.log_output_frac_bits, c.sqrt_input_frac_bits,
                                 c.sqrt_input_bits, c.rounding_mode, c.overflow_mode);
        t.radius := bm_sqrt(c, t.sqrt_input);
        bm_sincos(c, u2, t.cosine, t.sine);
        t.z0 := fm_scale(mul_s64(signed(t.radius), t.cosine),
            c.sqrt_output_frac_bits+c.trig_x_frac_bits, c.output_frac_bits,
            c.output_bits, c.rounding_mode, c.overflow_mode);
        t.z1 := fm_scale(mul_s64(signed(t.radius), t.sine),
            c.sqrt_output_frac_bits+c.trig_y_frac_bits, c.output_frac_bits,
            c.output_bits, c.rounding_mode, c.overflow_mode);
        trace := t;
    end procedure;

    procedure bm_generate(constant c : in bm_config_t;
                          variable state : inout bm_u64;
                          variable trace : out bm_trace_t) is
        variable u1, u2 : bm_u64;
    begin
        state := bm_prng_next(c, state);
        u1 := shift_right(state, c.prng_bits-c.u1_bits);
        state := bm_prng_next(c, state);
        u2 := shift_right(state, c.prng_bits-c.u2_bits);
        if u1 = U_ZERO then u1 := U_ONE; end if;
        bm_transform(c, u1, u2, trace);
    end procedure;
end package body bm_behavioral_pkg;
