-- VHDL-2008 behavioral AXI-Stream wrapper; not compiled or simulated.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.bm_behavioral_pkg.all;

entity bm_axis_behavioral is
    generic (
        BM_U1_BITS : integer := 32;
        BM_U2_BITS : integer := 24;
        BM_PRNG_BITS : integer := 64;
        BM_PRNG_SEED : std_logic_vector(63 downto 0) := x"123456789ABCDEF1";
        BM_LOG_XY_BITS : integer := 32;
        BM_LOG_X_BITS : integer := BM_LOG_XY_BITS;
        BM_LOG_Y_BITS : integer := BM_LOG_XY_BITS;
        BM_LOG_X_FRAC_BITS : integer := (BM_LOG_X_BITS - 4);
        BM_LOG_Y_FRAC_BITS : integer := BM_LOG_X_FRAC_BITS;
        BM_LOG_Z_BITS : integer := 32;
        BM_LOG_Z_FRAC_BITS : integer := (BM_LOG_Z_BITS - 4);
        BM_LOG_ITERATIONS : integer := 32;
        BM_LOG_CONST_BITS : integer := 32;
        BM_LOG_CONST_FRAC_BITS : integer := (BM_LOG_CONST_BITS - 2);
        BM_LOG_OUTPUT_BITS : integer := 32;
        BM_LOG_OUTPUT_FRAC_BITS : integer := 24;
        BM_SQRT_INPUT_BITS : integer := 32;
        BM_SQRT_INPUT_FRAC_BITS : integer := 24;
        BM_SQRT_OUTPUT_BITS : integer := 24;
        BM_SQRT_OUTPUT_FRAC_BITS : integer := 20;
        BM_SQRT_REMAINDER_BITS : integer := ((BM_SQRT_INPUT_BITS + 2*BM_SQRT_OUTPUT_FRAC_BITS - BM_SQRT_INPUT_FRAC_BITS + 1)/2 + 2);
        BM_TRIG_XY_BITS : integer := 24;
        BM_TRIG_X_BITS : integer := BM_TRIG_XY_BITS;
        BM_TRIG_Y_BITS : integer := BM_TRIG_XY_BITS;
        BM_TRIG_X_FRAC_BITS : integer := (BM_TRIG_X_BITS - 3);
        BM_TRIG_Y_FRAC_BITS : integer := BM_TRIG_X_FRAC_BITS;
        BM_TRIG_Z_BITS : integer := 24;
        BM_TRIG_Z_FRAC_BITS : integer := (BM_TRIG_Z_BITS - 2);
        BM_TRIG_ITERATIONS : integer := 24;
        BM_TRIG_CONST_BITS : integer := 24;
        BM_TRIG_CONST_FRAC_BITS : integer := (BM_TRIG_CONST_BITS - 1);
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
end entity bm_axis_behavioral;

architecture behavioral of bm_axis_behavioral is
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
    -- Evaluated during elaboration; mirrors bm_config.h restrictions.
    constant CONFIG_VALID : boolean := bm_config_valid(CONFIG);
    constant DATA_BITS : positive := ((BM_OUTPUT_BITS+7)/8)*8;
    signal valid_reg : std_logic := '0';
    signal data_reg : std_logic_vector(DATA_BITS-1 downto 0) := (others => '0');
    signal remaining : unsigned(31 downto 0) := (others => '0');
begin
    assert CONFIG_VALID report "Invalid Box-Muller configuration" severity failure;
    s_axis_tready <= '1' when aresetn = '1' and valid_reg = '0' else '0';
    m_axis_tvalid <= valid_reg;
    m_axis_tdata <= data_reg;

    stream_control : process(aclk)
        -- Persistent variables: no hidden state in the arithmetic package.
        variable prng_state : bm_u64 := unsigned(BM_PRNG_SEED);
        variable cached_z1 : bm_s64 := (others => '0');
        variable have_z1 : boolean := false;
        variable pair_trace : bm_trace_t;
        variable sample_value : bm_s64;
        variable requested : unsigned(31 downto 0);

        procedure prepare_next_sample is
        begin
            if have_z1 then
                sample_value := cached_z1;
                have_z1 := false;
            else
                bm_generate(CONFIG, prng_state, pair_trace);
                sample_value := pair_trace.z0;
                cached_z1 := pair_trace.z1;
                have_z1 := true;
            end if;
        end procedure;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                valid_reg <= '0';
                data_reg <= (others => '0');
                remaining <= (others => '0');
                prng_state := unsigned(BM_PRNG_SEED);
                cached_z1 := (others => '0');
                have_z1 := false;
            elsif aresetn = '1' then
                if valid_reg = '1' then
                    -- Busy: input commands are never examined here.
                    if m_axis_tready = '1' then
                        assert remaining /= to_unsigned(0, 32)
                            report "Internal AXI remaining-count invariant" severity failure;
                        if remaining = to_unsigned(1, 32) then
                            -- Last response consumed: input becomes ready
                            -- AFTER this edge, not on this same edge.
                            remaining <= (others => '0');
                            valid_reg <= '0';
                        else
                            remaining <= remaining-to_unsigned(1, 32);
                            prepare_next_sample;
                            data_reg <= std_logic_vector(resize(sample_value, DATA_BITS));
                        end if;
                    end if;
                    -- On backpressure: no assignments, no PRNG advance.
                else
                    -- Idle and outside reset implies s_axis_tready=1.
                    if s_axis_tvalid = '1' then
                        assert not is_x(s_axis_tdata)
                            report "Sample-count command contains non-binary bits" severity failure;
                        requested := unsigned(s_axis_tdata);
                        if requested /= to_unsigned(0, 32) then
                            remaining <= requested;
                            prepare_next_sample;
                            data_reg <= std_logic_vector(resize(sample_value, DATA_BITS));
                            valid_reg <= '1';
                        end if;
                        -- N=0: no output, cached sample/state unchanged.
                    end if;
                end if;
            end if;
        end if;
    end process stream_control;
end architecture behavioral;
