-- Fully registered integer Box-Muller pipeline. VHDL-2008.
-- No behavioral-model dependency; all state uses synchronous active-low reset.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.bm_rtl_pkg.all;
use work.bm_rtl_constants_pkg.all;

entity bm_axis_rtl is
    generic (
        BM_U1_BITS : integer := 32;
        BM_U2_BITS : integer := 24;
        BM_PRNG_BITS : integer := 64;
        BM_PRNG_SEED : std_logic_vector(63 downto 0) := x"123456789ABCDEF1";
        BM_LOG_XY_BITS : integer := 32;
        BM_LOG_X_BITS : integer := 32;
        BM_LOG_Y_BITS : integer := 32;
        BM_LOG_X_FRAC_BITS : integer := 28;
        BM_LOG_Y_FRAC_BITS : integer := 28;
        BM_LOG_Z_BITS : integer := 32;
        BM_LOG_Z_FRAC_BITS : integer := 28;
        BM_LOG_ITERATIONS : integer := 32;
        BM_LOG_CONST_BITS : integer := 32;
        BM_LOG_CONST_FRAC_BITS : integer := 30;
        BM_LOG_OUTPUT_BITS : integer := 32;
        BM_LOG_OUTPUT_FRAC_BITS : integer := 24;
        BM_SQRT_INPUT_BITS : integer := 32;
        BM_SQRT_INPUT_FRAC_BITS : integer := 24;
        BM_SQRT_OUTPUT_BITS : integer := 24;
        BM_SQRT_OUTPUT_FRAC_BITS : integer := 20;
        BM_SQRT_REMAINDER_BITS : integer := 26;
        BM_TRIG_XY_BITS : integer := 24;
        BM_TRIG_X_BITS : integer := 24;
        BM_TRIG_Y_BITS : integer := 24;
        BM_TRIG_X_FRAC_BITS : integer := 21;
        BM_TRIG_Y_FRAC_BITS : integer := 21;
        BM_TRIG_Z_BITS : integer := 24;
        BM_TRIG_Z_FRAC_BITS : integer := 22;
        BM_TRIG_ITERATIONS : integer := 24;
        BM_TRIG_CONST_BITS : integer := 24;
        BM_TRIG_CONST_FRAC_BITS : integer := 23;
        BM_OUTPUT_BITS : integer := 24;
        BM_OUTPUT_FRAC_BITS : integer := 18;
        BM_ROUNDING_MODE : integer := 0;
        BM_OVERFLOW_MODE : integer := 0
    );
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;
        s_axis_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        m_axis_tdata  : out std_logic_vector(((BM_OUTPUT_BITS+7)/8)*8-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity bm_axis_rtl;

architecture rtl of bm_axis_rtl is
    constant CONFIG : bm_config_t := (
        u1_bits => BM_U1_BITS,
        u2_bits => BM_U2_BITS,
        prng_bits => BM_PRNG_BITS,
        prng_seed => unsigned(BM_PRNG_SEED),
        log_xy_bits => BM_LOG_XY_BITS,
        log_x_bits => BM_LOG_X_BITS,
        log_y_bits => BM_LOG_Y_BITS,
        log_x_frac_bits => BM_LOG_X_FRAC_BITS,
        log_y_frac_bits => BM_LOG_Y_FRAC_BITS,
        log_z_bits => BM_LOG_Z_BITS,
        log_z_frac_bits => BM_LOG_Z_FRAC_BITS,
        log_iterations => BM_LOG_ITERATIONS,
        log_const_bits => BM_LOG_CONST_BITS,
        log_const_frac_bits => BM_LOG_CONST_FRAC_BITS,
        log_output_bits => BM_LOG_OUTPUT_BITS,
        log_output_frac_bits => BM_LOG_OUTPUT_FRAC_BITS,
        sqrt_input_bits => BM_SQRT_INPUT_BITS,
        sqrt_input_frac_bits => BM_SQRT_INPUT_FRAC_BITS,
        sqrt_output_bits => BM_SQRT_OUTPUT_BITS,
        sqrt_output_frac_bits => BM_SQRT_OUTPUT_FRAC_BITS,
        sqrt_remainder_bits => BM_SQRT_REMAINDER_BITS,
        trig_xy_bits => BM_TRIG_XY_BITS,
        trig_x_bits => BM_TRIG_X_BITS,
        trig_y_bits => BM_TRIG_Y_BITS,
        trig_x_frac_bits => BM_TRIG_X_FRAC_BITS,
        trig_y_frac_bits => BM_TRIG_Y_FRAC_BITS,
        trig_z_bits => BM_TRIG_Z_BITS,
        trig_z_frac_bits => BM_TRIG_Z_FRAC_BITS,
        trig_iterations => BM_TRIG_ITERATIONS,
        trig_const_bits => BM_TRIG_CONST_BITS,
        trig_const_frac_bits => BM_TRIG_CONST_FRAC_BITS,
        output_bits => BM_OUTPUT_BITS,
        output_frac_bits => BM_OUTPUT_FRAC_BITS,
        rounding_mode => BM_ROUNDING_MODE,
        overflow_mode => BM_OVERFLOW_MODE
    );

    constant CONFIG_VALID : boolean := bm_config_valid(CONFIG);
    constant DATA_BITS : positive := ((BM_OUTPUT_BITS+7)/8)*8;
    constant NS : positive := bm_sqrt_steps(CONFIG);
    constant L_END : natural := BM_LOG_ITERATIONS;
    constant SQ_IN : natural := L_END+3;
    constant SQ_END : natural := SQ_IN+NS;
    constant T_IN : natural := SQ_END+1;
    constant T_END : natural := max_nat(T_IN,BM_TRIG_ITERATIONS+1)+1;
    constant LAST : natural := T_END+3;
    type token_t is record
        valid, single, two : std_logic;
        sample : bm_s64;
        x, y, z : bm_s64;
        exponent_value : unsigned(6 downto 0);
        phase, radicand, root, remainder_value, radius : bm_u64;
        cosine, sine, product0, product1, z0, z1 : bm_s64;
        quadrant : unsigned(1 downto 0);
    end record;
    constant EMPTY_TOKEN : token_t := (
        valid => '0', single => '0', two => '0', sample => (others => '0'),
        x => (others => '0'), y => (others => '0'), z => (others => '0'),
        exponent_value => (others => '0'), phase => (others => '0'),
        radicand => (others => '0'), root => (others => '0'),
        remainder_value => (others => '0'), radius => (others => '0'),
        cosine => (others => '0'), sine => (others => '0'),
        product0 => (others => '0'), product1 => (others => '0'),
        z0 => (others => '0'), z1 => (others => '0'), quadrant => (others => '0'));
    type pipeline_t is array(natural range <>) of token_t;
    signal pipe : pipeline_t(0 to LAST);
    signal trig_pipe : pipeline_t(0 to T_END-1);
    signal advance, issue, input_ready, output_valid : std_logic;
    signal busy, cooldown, cached_valid, second_valid : std_logic;
    signal to_generate, to_transfer : unsigned(31 downto 0);
    signal prng_state, next_state, pair_state, raw_u1, raw_u2, mantissa : bm_u64;
    signal cached_sample, second_sample, output_sample : bm_s64;
begin
    assert CONFIG_VALID report "Invalid RTL Box-Muller configuration" severity failure;
    input_ready <= not busy and aresetn;
    s_axis_tready <= input_ready;
    m_axis_tvalid <= output_valid;
    m_axis_tdata <= std_logic_vector(resize(output_sample, DATA_BITS));
    advance <= '0' when output_valid = '1' and m_axis_tready = '0' else '1';
    issue <= '1' when busy = '1' and to_generate /= 0 and cooldown = '0' else '0';
    next_state <= prng_step(prng_state,BM_PRNG_BITS);
    pair_state <= prng_step(next_state,BM_PRNG_BITS);
    raw_u1 <= nonzero(shift_right(next_state,BM_PRNG_BITS-BM_U1_BITS));
    raw_u2 <= shift_right(pair_state,BM_PRNG_BITS-BM_U2_BITS);
    mantissa <= fm_uscale(raw_u1,top_bit(raw_u1),BM_LOG_X_FRAC_BITS,BM_LOG_X_BITS-1,0,0);

    -- First stage normalizes U1 and retains U2 for the trig branch.
    input_stage : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                pipe(0) <= EMPTY_TOKEN;
            elsif advance = '1' then
                pipe(0) <= EMPTY_TOKEN;
                pipe(0).valid <= issue;
                pipe(0).single <= cached_valid;
                pipe(0).sample <= cached_sample;
                if to_generate >= 2 then pipe(0).two <= '1'; end if;
                pipe(0).x <= signed(mantissa)+signed(shift_left(U_ONE,BM_LOG_X_FRAC_BITS));
                pipe(0).y <= signed(mantissa)-signed(shift_left(U_ONE,BM_LOG_X_FRAC_BITS));
                pipe(0).exponent_value <= to_unsigned(BM_U1_BITS-top_bit(raw_u1),7);
                pipe(0).phase <= raw_u2;
            end if;
        end if;
    end process;

    log_stages : for i in 0 to BM_LOG_ITERATIONS-1 generate
        constant SHIFT : positive := log_shift(i);
        constant ANGLE : bm_s64 := signed(fm_constant(BM_ATANH_Q60(SHIFT),BM_LOG_CONST_FRAC_BITS,BM_LOG_Z_FRAC_BITS));
    begin
        process(aclk)
        begin
            if rising_edge(aclk) then
                if aresetn = '0' then pipe(i+1) <= EMPTY_TOKEN;
                elsif advance = '1' then
                    pipe(i+1) <= pipe(i);
                    if pipe(i).y >= 0 then
                        pipe(i+1).x <= fm_wrap(pipe(i).x-shift_right(pipe(i).y,SHIFT),BM_LOG_X_BITS);
                        pipe(i+1).y <= fm_wrap(pipe(i).y-shift_right(pipe(i).x,SHIFT),BM_LOG_Y_BITS);
                        pipe(i+1).z <= fm_wrap(pipe(i).z+ANGLE,BM_LOG_Z_BITS);
                    else
                        pipe(i+1).x <= fm_wrap(pipe(i).x+shift_right(pipe(i).y,SHIFT),BM_LOG_X_BITS);
                        pipe(i+1).y <= fm_wrap(pipe(i).y+shift_right(pipe(i).x,SHIFT),BM_LOG_Y_BITS);
                        pipe(i+1).z <= fm_wrap(pipe(i).z-ANGLE,BM_LOG_Z_BITS);
                    end if;
                end if;
            end if;
        end process;
    end generate;

    log_finish : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                pipe(L_END+1) <= EMPTY_TOKEN;
                pipe(L_END+2) <= EMPTY_TOKEN;
                pipe(SQ_IN) <= EMPTY_TOKEN;
            elsif advance = '1' then
                pipe(L_END+1) <= pipe(L_END);
                pipe(L_END+1).z <= mul_s64(to_signed(2*to_integer(pipe(L_END).exponent_value),64),
                    signed(fm_constant(BM_LN2_Q60,BM_LOG_CONST_FRAC_BITS,BM_LOG_Z_FRAC_BITS)))
                    -shift_left(pipe(L_END).z,2);
                pipe(L_END+2) <= pipe(L_END+1);
                if pipe(L_END+1).z <= 0 then
                    pipe(L_END+2).radicand <= U_ZERO;
                else
                    pipe(L_END+2).radicand <= fm_uscale(unsigned(pipe(L_END+1).z),
                        BM_LOG_Z_FRAC_BITS,BM_LOG_OUTPUT_FRAC_BITS,BM_LOG_OUTPUT_BITS,BM_ROUNDING_MODE,BM_OVERFLOW_MODE);
                end if;
                pipe(SQ_IN) <= pipe(L_END+2);
                pipe(SQ_IN).radicand <= shift_left(fm_uscale(pipe(L_END+2).radicand,
                    BM_LOG_OUTPUT_FRAC_BITS,BM_SQRT_INPUT_FRAC_BITS,BM_SQRT_INPUT_BITS,
                    BM_ROUNDING_MODE,BM_OVERFLOW_MODE),bm_sqrt_rad_shift(CONFIG));
            end if;
        end if;
    end process;

    sqrt_stages : for i in 0 to NS-1 generate
        constant K : natural := SQ_IN+i;
        signal shifted_remainder, trial : bm_u64;
    begin
        shifted_remainder <= (shift_left(pipe(K).remainder_value,2) or
            (shift_right(pipe(K).radicand,2*(NS-1-i)) and to_unsigned(3,64))) and fm_mask(BM_SQRT_REMAINDER_BITS);
        trial <= shift_left(pipe(K).root,2) or U_ONE;
        process(aclk)
        begin
            if rising_edge(aclk) then
                if aresetn = '0' then pipe(K+1) <= EMPTY_TOKEN;
                elsif advance = '1' then
                    pipe(K+1) <= pipe(K);
                    if shifted_remainder >= trial then
                        pipe(K+1).remainder_value <= shifted_remainder-trial;
                        pipe(K+1).root <= shift_left(pipe(K).root,1) or U_ONE;
                    else
                        pipe(K+1).remainder_value <= shifted_remainder;
                        pipe(K+1).root <= shift_left(pipe(K).root,1);
                    end if;
                end if;
            end if;
        end process;
    end generate;

    trig_input : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then pipe(T_IN) <= EMPTY_TOKEN;
            elsif advance = '1' then
                pipe(T_IN) <= pipe(SQ_END);
                if BM_ROUNDING_MODE /= 0 and pipe(SQ_END).remainder_value > pipe(SQ_END).root then
                    pipe(T_IN).radius <= fm_unsigned(pipe(SQ_END).root+1,BM_SQRT_OUTPUT_BITS,BM_OVERFLOW_MODE);
                else
                    pipe(T_IN).radius <= fm_unsigned(pipe(SQ_END).root,BM_SQRT_OUTPUT_BITS,BM_OVERFLOW_MODE);
                end if;
            end if;
        end if;
    end process;

    -- Parallel phase branch; its outputs are delayed to meet the radius.
    trig_pipe(0) <= pipe(0);
    trig_initialize : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then trig_pipe(1) <= EMPTY_TOKEN;
            elsif advance = '1' then
                trig_pipe(1) <= trig_pipe(0);
                trig_pipe(1).x <= signed(fm_constant(BM_INVERSE_GAIN_Q60(BM_TRIG_ITERATIONS),BM_TRIG_CONST_FRAC_BITS,BM_TRIG_X_FRAC_BITS));
                trig_pipe(1).y <= (others => '0');
                trig_pipe(1).z <= signed(fm_uscale(trig_pipe(0).phase and fm_mask(BM_U2_BITS-2),
                    BM_U2_BITS,BM_TRIG_Z_FRAC_BITS,BM_TRIG_Z_BITS-1,0,0));
                trig_pipe(1).quadrant <= resize(shift_right(trig_pipe(0).phase,BM_U2_BITS-2),2);
            end if;
        end if;
    end process;

    trig_stages : for i in 0 to BM_TRIG_ITERATIONS-1 generate
        constant K : natural := 1+i;
        constant ANGLE : bm_s64 := signed(fm_constant(BM_ATAN_TURN_Q60(i),BM_TRIG_CONST_FRAC_BITS,BM_TRIG_Z_FRAC_BITS));
    begin
        process(aclk)
        begin
            if rising_edge(aclk) then
                if aresetn = '0' then trig_pipe(K+1) <= EMPTY_TOKEN;
                elsif advance = '1' then
                    trig_pipe(K+1) <= trig_pipe(K);
                    if trig_pipe(K).z >= 0 then
                        trig_pipe(K+1).x <= fm_wrap(trig_pipe(K).x-shift_right(trig_pipe(K).y,i),BM_TRIG_X_BITS);
                        trig_pipe(K+1).y <= fm_wrap(trig_pipe(K).y+shift_right(trig_pipe(K).x,i),BM_TRIG_Y_BITS);
                        trig_pipe(K+1).z <= fm_wrap(trig_pipe(K).z-ANGLE,BM_TRIG_Z_BITS);
                    else
                        trig_pipe(K+1).x <= fm_wrap(trig_pipe(K).x+shift_right(trig_pipe(K).y,i),BM_TRIG_X_BITS);
                        trig_pipe(K+1).y <= fm_wrap(trig_pipe(K).y-shift_right(trig_pipe(K).x,i),BM_TRIG_Y_BITS);
                        trig_pipe(K+1).z <= fm_wrap(trig_pipe(K).z+ANGLE,BM_TRIG_Z_BITS);
                    end if;
                end if;
            end if;
        end process;
    end generate;

    trig_alignment : for i in BM_TRIG_ITERATIONS+1 to T_END-2 generate
    begin
        process(aclk)
        begin
            if rising_edge(aclk) then
                if aresetn = '0' then trig_pipe(i+1) <= EMPTY_TOKEN;
                elsif advance = '1' then trig_pipe(i+1) <= trig_pipe(i);
                end if;
            end if;
        end process;
    end generate;

    radius_alignment : for i in T_IN to T_END-1 generate
    begin
        process(aclk)
        begin
            if rising_edge(aclk) then
                if aresetn = '0' then pipe(i+1) <= EMPTY_TOKEN;
                elsif advance = '1' then
                    pipe(i+1) <= pipe(i);
                    if i = T_END-1 then
                        pipe(i+1).x <= trig_pipe(i).x;
                        pipe(i+1).y <= trig_pipe(i).y;
                        pipe(i+1).z <= trig_pipe(i).z;
                        pipe(i+1).quadrant <= trig_pipe(i).quadrant;
                    end if;
                end if;
            end if;
        end process;
    end generate;

    products : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                pipe(T_END+1) <= EMPTY_TOKEN;
                pipe(T_END+2) <= EMPTY_TOKEN;
                pipe(LAST) <= EMPTY_TOKEN;
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
                pipe(LAST).z0 <= fm_scale(pipe(T_END+2).product0,BM_SQRT_OUTPUT_FRAC_BITS+BM_TRIG_X_FRAC_BITS,
                    BM_OUTPUT_FRAC_BITS,BM_OUTPUT_BITS,BM_ROUNDING_MODE,BM_OVERFLOW_MODE);
                pipe(LAST).z1 <= fm_scale(pipe(T_END+2).product1,BM_SQRT_OUTPUT_FRAC_BITS+BM_TRIG_Y_FRAC_BITS,
                    BM_OUTPUT_FRAC_BITS,BM_OUTPUT_BITS,BM_ROUNDING_MODE,BM_OVERFLOW_MODE);
            end if;
        end if;
    end process;

    stream_control : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                busy <= '0'; cooldown <= '0'; cached_valid <= '0'; second_valid <= '0';
                output_valid <= '0';
                to_generate <= (others => '0'); to_transfer <= (others => '0');
                prng_state <= unsigned(BM_PRNG_SEED);
                cached_sample <= (others => '0'); second_sample <= (others => '0'); output_sample <= (others => '0');
            elsif advance = '1' then
                cooldown <= '0';
                if input_ready = '1' and s_axis_tvalid = '1' and unsigned(s_axis_tdata) /= 0 then
                    busy <= '1'; to_generate <= unsigned(s_axis_tdata); to_transfer <= unsigned(s_axis_tdata);
                end if;
                if output_valid = '1' and m_axis_tready = '1' then
                    to_transfer <= to_transfer-1;
                    if to_transfer = 1 then busy <= '0'; end if;
                end if;
                if issue = '1' then
                    if cached_valid = '1' then
                        cached_valid <= '0'; to_generate <= to_generate-1;
                    else
                        prng_state <= pair_state; cooldown <= '1';
                        if to_generate >= 2 then to_generate <= to_generate-2;
                        else to_generate <= (others => '0'); end if;
                    end if;
                end if;
                output_valid <= '0';
                if second_valid = '1' then
                    output_sample <= second_sample; output_valid <= '1'; second_valid <= '0';
                elsif pipe(LAST).valid = '1' then
                    output_valid <= '1';
                    if pipe(LAST).single = '1' then output_sample <= pipe(LAST).sample;
                    else
                        output_sample <= pipe(LAST).z0;
                        if pipe(LAST).two = '1' then
                            second_sample <= pipe(LAST).z1; second_valid <= '1';
                        else
                            cached_sample <= pipe(LAST).z1; cached_valid <= '1';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
