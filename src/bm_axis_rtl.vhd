-- Fully registered integer Box-Muller pipeline. VHDL-2008.
-- No behavioral-model dependency; all state uses synchronous active-low reset.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.bm_rtl_pkg.all;

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
    signal input_token, normalized_token, log_token, result_token : bm_token_t;
    signal pipe : bm_pipeline_t(T_IN to T_END);
    signal trig_pipe : bm_pipeline_t(BM_TRIG_ITERATIONS+1 to T_END-1);
    signal advance, issue, input_ready, output_valid : std_logic;
    signal busy, cooldown, cached_valid, second_valid : std_logic;
    signal to_generate, to_transfer : unsigned(31 downto 0);
    signal prng_state, next_state, pair_state, raw_u1, raw_u2 : bm_u64;
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
    -- Combinational launch metadata; bm_log owns the original input register.
    launch_token : process(issue, cached_valid, cached_sample, to_generate, raw_u1, raw_u2)
    begin
        input_token <= BM_EMPTY_TOKEN;
        input_token.valid <= issue;
        input_token.single <= cached_valid;
        input_token.sample <= cached_sample;
        if to_generate >= 2 then input_token.two <= '1'; end if;
        input_token.x <= signed(raw_u1);
        input_token.phase <= raw_u2;
    end process;

    log_block : entity work.bm_log
        generic map (CONFIG => CONFIG)
        port map (aclk => aclk, aresetn => aresetn, advance => advance,
                  input_token => input_token, normalized_token => normalized_token,
                  output_token => log_token);

    sqrt_block : entity work.bm_sqrt
        generic map (CONFIG => CONFIG)
        port map (aclk => aclk, aresetn => aresetn, advance => advance,
                  input_token => log_token, output_token => pipe(T_IN));

    trig_block : entity work.bm_trig
        generic map (CONFIG => CONFIG)
        port map (aclk => aclk, aresetn => aresetn, advance => advance,
                  input_token => normalized_token,
                  output_token => trig_pipe(BM_TRIG_ITERATIONS+1));

    trig_alignment : for i in BM_TRIG_ITERATIONS+1 to T_END-2 generate
    begin
        process(aclk)
        begin
            if rising_edge(aclk) then
                if aresetn = '0' then trig_pipe(i+1) <= BM_EMPTY_TOKEN;
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
                if aresetn = '0' then pipe(i+1) <= BM_EMPTY_TOKEN;
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

    products_block : entity work.bm_products
        generic map (CONFIG => CONFIG)
        port map (aclk => aclk, aresetn => aresetn, advance => advance,
                  input_token => pipe(T_END), output_token => result_token);

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
                elsif result_token.valid = '1' then
                    output_valid <= '1';
                    if result_token.single = '1' then output_sample <= result_token.sample;
                    else
                        output_sample <= result_token.z0;
                        if result_token.two = '1' then
                            second_sample <= result_token.z1; second_valid <= '1';
                        else
                            cached_sample <= result_token.z1; cached_valid <= '1';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
