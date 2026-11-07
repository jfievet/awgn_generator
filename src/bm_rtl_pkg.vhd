library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package bm_rtl_pkg is
    subtype bm_u64 is unsigned(63 downto 0);
    subtype bm_s64 is signed(63 downto 0);
    constant U_ZERO : bm_u64 := (others => '0');
    constant U_ONE : bm_u64 := to_unsigned(1, 64);
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


    function max_nat(a,b : natural) return natural;
    function bm_sqrt_rad_shift(c : bm_config_t) return integer;
    function bm_sqrt_rad_bits(c : bm_config_t) return integer;
    function bm_sqrt_steps(c : bm_config_t) return integer;
    function bm_config_valid(c : bm_config_t) return boolean;
    function fm_mask(bits : positive) return bm_u64;
    function fm_wrap(v : bm_s64; bits : positive) return bm_s64;
    function fm_signed(v : bm_s64; bits : positive; overflow : natural) return bm_s64;
    function fm_unsigned(v : bm_u64; bits : positive; overflow : natural) return bm_u64;
    function right_round(v : bm_u64; n, nearest : natural) return bm_u64;
    function magnitude(v : bm_s64) return bm_u64;
    function restore_sign(v : bm_u64; negative : boolean) return bm_s64;
    function fm_scale(v : bm_s64; from_frac, to_frac : natural;
                      bits : positive; rounding, overflow : natural) return bm_s64;
    function fm_uscale(v : bm_u64; from_frac, to_frac : natural;
                       bits : positive; rounding, overflow : natural) return bm_u64;
    function fm_constant(q60 : bm_u64; constant_frac, destination_frac : natural) return bm_u64;
    function mul_s64(a, b : bm_s64) return bm_s64;
    function prng_step(state : bm_u64; bits : positive) return bm_u64;
    function nonzero(v : bm_u64) return bm_u64;
    function top_bit(v : bm_u64) return natural;
    function log_shift(stage : natural; index_value : positive := 1;
                       repeat_value : positive := 4; repeated : boolean := false) return positive;
end package;

package body bm_rtl_pkg is
    function max_nat(a,b : natural) return natural is
    begin if a > b then return a; end if; return b; end;
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
        procedure require(constant condition : in boolean; constant message_text : in string) is
        begin
            assert condition report "Box-Muller configuration: " & message_text severity failure;
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
        return true;
    end function;


    function fm_mask(bits : positive) return bm_u64 is
    begin return shift_right(not U_ZERO, 64-bits); end;
    function fm_wrap(v : bm_s64; bits : positive) return bm_s64 is
    begin return resize(v(bits-1 downto 0), 64); end;
    function fm_signed(v : bm_s64; bits : positive; overflow : natural) return bm_s64 is
        constant hi : bm_s64 := signed(shift_left(U_ONE, bits-1)-U_ONE);
        constant lo : bm_s64 := -hi-1;
    begin
        if overflow /= 0 then return fm_wrap(v,bits); end if;
        if v > hi then return hi; end if;
        if v < lo then return lo; end if;
        return v;
    end;
    function fm_unsigned(v : bm_u64; bits : positive; overflow : natural) return bm_u64 is
    begin
        if overflow /= 0 then return v and fm_mask(bits); end if;
        if v > fm_mask(bits) then return fm_mask(bits); end if;
        return v;
    end;
    function right_round(v : bm_u64; n, nearest : natural) return bm_u64 is
    begin
        if n = 0 then return v; end if;
        if nearest /= 0 and (v and fm_mask(n)) >= shift_left(U_ONE,n-1) then
            return shift_right(v,n)+1;
        end if;
        return shift_right(v,n);
    end;
    function magnitude(v : bm_s64) return bm_u64 is
    begin
        if v(63) = '1' then return (not unsigned(v))+1; end if;
        return unsigned(v);
    end;
    function restore_sign(v : bm_u64; negative : boolean) return bm_s64 is
    begin
        if negative then return signed((not v)+1); end if;
        return signed(v);
    end;
    function fm_scale(v : bm_s64; from_frac, to_frac : natural;
                      bits : positive; rounding, overflow : natural) return bm_s64 is
    begin
        if from_frac > to_frac then
            if rounding = 0 then return fm_signed(shift_right(v,from_frac-to_frac),bits,overflow); end if;
            return fm_signed(restore_sign(right_round(magnitude(v),from_frac-to_frac,1),v(63)='1'),bits,overflow);
        end if;
        if overflow = 0 then
            if v(63) = '1' then
                if magnitude(v) > shift_right(shift_left(U_ONE,bits-1),to_frac-from_frac) then
                    return -signed(shift_left(U_ONE,bits-1));
                end if;
            elsif magnitude(v) > shift_right(shift_left(U_ONE,bits-1)-1,to_frac-from_frac) then
                return signed(shift_left(U_ONE,bits-1)-1);
            end if;
        end if;
        return fm_wrap(restore_sign(shift_left(magnitude(v),to_frac-from_frac),v(63)='1'),bits);
    end;
    function fm_uscale(v : bm_u64; from_frac, to_frac : natural;
                       bits : positive; rounding, overflow : natural) return bm_u64 is
    begin
        if from_frac > to_frac then
            return fm_unsigned(right_round(v,from_frac-to_frac,rounding),bits,overflow);
        end if;
        if overflow = 0 and v > shift_right(fm_mask(bits),to_frac-from_frac) then return fm_mask(bits); end if;
        return fm_unsigned(shift_left(v,to_frac-from_frac),bits,overflow);
    end;
    function fm_constant(q60 : bm_u64; constant_frac, destination_frac : natural) return bm_u64 is
    begin
        if destination_frac >= constant_frac then
            return shift_left(right_round(q60,60-constant_frac,1),destination_frac-constant_frac);
        end if;
        return right_round(right_round(q60,60-constant_frac,1),constant_frac-destination_frac,1);
    end;
    function mul_s64(a, b : bm_s64) return bm_s64 is
    begin return signed(resize(unsigned(a*b),64)); end;
    function xor_left(v : bm_u64; n, bits : positive) return bm_u64 is
    begin
        if bits = 32 then return resize(v(31 downto 0) xor shift_left(v(31 downto 0),n),64); end if;
        return v xor shift_left(v,n);
    end;
    function xor_right(v : bm_u64; n : positive) return bm_u64 is
    begin return v xor shift_right(v,n); end;
    function prng_step(state : bm_u64; bits : positive) return bm_u64 is
    begin
        if bits = 32 then return xor_left(xor_right(xor_left(state,13,32),17),5,32); end if;
        return xor_left(xor_right(xor_left(state,13,64),7),17,64);
    end;
    function nonzero(v : bm_u64) return bm_u64 is
    begin if v = 0 then return U_ONE; end if; return v; end;
    function top_bit(v : bm_u64) return natural is
    begin
        for i in 63 downto 0 loop
            if v(i) = '1' then return i; end if;
        end loop;
        return 0;
    end;
    function log_shift(stage : natural; index_value : positive := 1;
                       repeat_value : positive := 4; repeated : boolean := false) return positive is
    begin
        if stage = 0 then return index_value; end if;
        if index_value = repeat_value then
            if not repeated then return log_shift(stage-1,index_value,repeat_value,true); end if;
            return log_shift(stage-1,index_value+1,3*repeat_value+1,false);
        end if;
        return log_shift(stage-1,index_value+1,repeat_value,false);
    end;
end package body;
