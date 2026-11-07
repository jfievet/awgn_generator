-- Functional block of the AWGN Box-Muller generator. VHDL-2008.
-- Registers advance together; synchronous active-low reset has priority.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.bm_rtl_pkg.all;

entity bm_products is
    generic (CONFIG : bm_config_t);
    port (
        aclk, aresetn, advance : in std_logic;
        input_token : in bm_token_t;
        output_token : out bm_token_t
    );
end entity bm_products;

architecture rtl of bm_products is
    constant T_END : natural := 0;
    constant LAST : natural := 3;
    signal pipe : bm_pipeline_t(0 to LAST);
begin
    pipe(0) <= input_token;
    output_token <= pipe(LAST);

    products : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                pipe(T_END+1) <= BM_EMPTY_TOKEN;
                pipe(T_END+2) <= BM_EMPTY_TOKEN;
                pipe(LAST) <= BM_EMPTY_TOKEN;
            elsif advance = '1' then
                pipe(T_END+1) <= pipe(T_END);
                case to_integer(pipe(T_END).quadrant) is
                    when 0 => pipe(T_END+1).cosine <= pipe(T_END).x; pipe(T_END+1).sine <= pipe(T_END).y;
                    when 1 => pipe(T_END+1).cosine <= -pipe(T_END).y; pipe(T_END+1).sine <= pipe(T_END).x;
                    when 2 => pipe(T_END+1).cosine <= -pipe(T_END).x; pipe(T_END+1).sine <= -pipe(T_END).y;
                    when others => pipe(T_END+1).cosine <= pipe(T_END).y; pipe(T_END+1).sine <= -pipe(T_END).x;
                end case;
                pipe(T_END+2) <= pipe(T_END+1);
                pipe(T_END+2).product0 <= mul_s64(signed(pipe(T_END+1).radius),pipe(T_END+1).cosine);
                pipe(T_END+2).product1 <= mul_s64(signed(pipe(T_END+1).radius),pipe(T_END+1).sine);
                pipe(LAST) <= pipe(T_END+2);
                pipe(LAST).z0 <= fm_scale(pipe(T_END+2).product0,CONFIG.sqrt_output_frac_bits+CONFIG.trig_x_frac_bits,
                    CONFIG.output_frac_bits,CONFIG.output_bits,CONFIG.rounding_mode,CONFIG.overflow_mode);
                pipe(LAST).z1 <= fm_scale(pipe(T_END+2).product1,CONFIG.sqrt_output_frac_bits+CONFIG.trig_y_frac_bits,
                    CONFIG.output_frac_bits,CONFIG.output_bits,CONFIG.rounding_mode,CONFIG.overflow_mode);
            end if;
        end if;
    end process;

end architecture;
