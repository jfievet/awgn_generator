-- Functional block of the AWGN Box-Muller generator. VHDL-2008.
-- Registers advance together; synchronous active-low reset has priority.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.bm_rtl_pkg.all;
use work.bm_rtl_constants_pkg.all;

entity bm_log is
    generic (CONFIG : bm_config_t);
    port (
        aclk, aresetn, advance : in std_logic;
        input_token : in bm_token_t;
        normalized_token : out bm_token_t;
        output_token : out bm_token_t
    );
end entity bm_log;

architecture rtl of bm_log is
    constant L_END : natural := CONFIG.log_iterations;
    signal pipe : bm_pipeline_t(0 to L_END+2);
    signal mantissa : bm_u64;
begin
    -- input_token.x carries unsigned raw U1; phase and metadata pass through.
    -- normalized_token taps the input register for the parallel trig branch.
    mantissa <= fm_uscale(unsigned(input_token.x),top_bit(unsigned(input_token.x)),CONFIG.log_x_frac_bits,CONFIG.log_x_bits-1,0,0);
    normalized_token <= pipe(0);
    output_token <= pipe(L_END+2);

    -- First stage normalizes U1 and retains U2 for the trig branch.
    input_stage : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                pipe(0) <= BM_EMPTY_TOKEN;
            elsif advance = '1' then
                pipe(0) <= input_token;
                pipe(0).x <= signed(mantissa)+signed(shift_left(U_ONE,CONFIG.log_x_frac_bits));
                pipe(0).y <= signed(mantissa)-signed(shift_left(U_ONE,CONFIG.log_x_frac_bits));
                pipe(0).exponent_value <= to_unsigned(CONFIG.u1_bits-top_bit(unsigned(input_token.x)),7);
            end if;
        end if;
    end process;

    log_stages : for i in 0 to CONFIG.log_iterations-1 generate
        constant SHIFT : positive := log_shift(i);
        constant ANGLE : bm_s64 := signed(fm_constant(BM_ATANH_Q60(SHIFT),CONFIG.log_const_frac_bits,CONFIG.log_z_frac_bits));
    begin
        process(aclk)
        begin
            if rising_edge(aclk) then
                if aresetn = '0' then pipe(i+1) <= BM_EMPTY_TOKEN;
                elsif advance = '1' then
                    pipe(i+1) <= pipe(i);
                    if pipe(i).y >= 0 then
                        pipe(i+1).x <= fm_wrap(pipe(i).x-shift_right(pipe(i).y,SHIFT),CONFIG.log_x_bits);
                        pipe(i+1).y <= fm_wrap(pipe(i).y-shift_right(pipe(i).x,SHIFT),CONFIG.log_y_bits);
                        pipe(i+1).z <= fm_wrap(pipe(i).z+ANGLE,CONFIG.log_z_bits);
                    else
                        pipe(i+1).x <= fm_wrap(pipe(i).x+shift_right(pipe(i).y,SHIFT),CONFIG.log_x_bits);
                        pipe(i+1).y <= fm_wrap(pipe(i).y+shift_right(pipe(i).x,SHIFT),CONFIG.log_y_bits);
                        pipe(i+1).z <= fm_wrap(pipe(i).z-ANGLE,CONFIG.log_z_bits);
                    end if;
                end if;
            end if;
        end process;
    end generate;

    log_finish : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                pipe(L_END+1) <= BM_EMPTY_TOKEN;
                pipe(L_END+2) <= BM_EMPTY_TOKEN;
            elsif advance = '1' then
                pipe(L_END+1) <= pipe(L_END);
                pipe(L_END+1).z <= mul_s64(to_signed(2*to_integer(pipe(L_END).exponent_value),64),
                    signed(fm_constant(BM_LN2_Q60,CONFIG.log_const_frac_bits,CONFIG.log_z_frac_bits)))
                    -shift_left(pipe(L_END).z,2);
                pipe(L_END+2) <= pipe(L_END+1);
                if pipe(L_END+1).z <= 0 then
                    pipe(L_END+2).radicand <= U_ZERO;
                else
                    pipe(L_END+2).radicand <= fm_uscale(unsigned(pipe(L_END+1).z),
                        CONFIG.log_z_frac_bits,CONFIG.log_output_frac_bits,CONFIG.log_output_bits,CONFIG.rounding_mode,CONFIG.overflow_mode);
                end if;
            end if;
        end if;
    end process;

end architecture;
