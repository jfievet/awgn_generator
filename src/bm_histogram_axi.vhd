-- AXI4-Lite controlled Gaussian histogram analyzer. VHDL-1993.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bm_histogram_axi is
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
        BM_OVERFLOW_MODE : integer := 0;
        HIST_ADDR_BITS : positive := 10;
        COUNTER_BITS : positive := 64
    );
    port (
        aclk, aresetn : in std_logic;
        s_axi_awaddr : in std_logic_vector(11 downto 0);
        s_axi_awprot : in std_logic_vector(2 downto 0);
        s_axi_awvalid : in std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata : in std_logic_vector(31 downto 0);
        s_axi_wstrb : in std_logic_vector(3 downto 0);
        s_axi_wvalid : in std_logic;
        s_axi_wready : out std_logic;
        s_axi_bresp : out std_logic_vector(1 downto 0);
        s_axi_bvalid : out std_logic;
        s_axi_bready : in std_logic;
        s_axi_araddr : in std_logic_vector(11 downto 0);
        s_axi_arprot : in std_logic_vector(2 downto 0);
        s_axi_arvalid : in std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata : out std_logic_vector(31 downto 0);
        s_axi_rresp : out std_logic_vector(1 downto 0);
        s_axi_rvalid : out std_logic;
        s_axi_rready : in std_logic
    );
end entity;

architecture rtl of bm_histogram_axi is
    type state_t is (BOOT_CLEAR, IDLE, RESET_CORE, REQUEST_CLEAR, WAIT_CLEAR,
                     SEND_COMMAND, ACQUIRE, DRAIN_PIPELINE);
    signal state : state_t;
    signal run_after_clear, done_flag, error_flag : std_logic;
    signal n_samples, requested, remaining : unsigned(31 downto 0);
    signal bin_addr : unsigned(HIST_ADDR_BITS-1 downto 0);
    signal core_resetn, command_valid, command_ready : std_logic;
    signal gaussian_data : std_logic_vector(((BM_OUTPUT_BITS+7)/8)*8-1 downto 0);
    signal gaussian_valid, gaussian_ready, engine_valid, engine_ready : std_logic;
    signal clear_req, clearing, clear_done, drained, overflow_flag : std_logic;
    signal bin_read_req, bin_read_valid, read_pending : std_logic;
    signal bin_read_data, bin_snapshot : unsigned(63 downto 0);
    signal bin_snapshot_valid : std_logic;
    signal statistics : std_logic_vector(13*64-1 downto 0);
    type snapshots_t is array(0 to 12) of unsigned(63 downto 0);
    signal snapshots : snapshots_t;
    signal snapshot_valid : std_logic_vector(12 downto 0);
    signal aw_held, w_held, bvalid_int, rvalid_int : std_logic;
    signal awready_int, wready_int, arready_int : std_logic;
    signal awaddr_reg : std_logic_vector(11 downto 0);
    signal wdata_reg : std_logic_vector(31 downto 0);
    signal wstrb_reg : std_logic_vector(3 downto 0);
    signal bresp_reg, rresp_reg : std_logic_vector(1 downto 0);
    signal rdata_reg : std_logic_vector(31 downto 0);
    function apply_strobes(old_value, new_value : std_logic_vector(31 downto 0);
                           strobes : std_logic_vector(3 downto 0)) return std_logic_vector is
        variable result_value : std_logic_vector(31 downto 0);
    begin
        result_value := old_value;
        for i in 0 to 3 loop
            if strobes(i) = '1' then
                result_value(8*i+7 downto 8*i) := new_value(8*i+7 downto 8*i);
            end if;
        end loop;
        return result_value;
    end function;
begin
    assert HIST_ADDR_BITS >= 4 and HIST_ADDR_BITS <= 10 and COUNTER_BITS <= 64
        report "Unsupported histogram configuration" severity failure;
    -- PROT is accepted and ignored; all registers have identical access policy.
    s_axi_awready <= awready_int; s_axi_wready <= wready_int;
    s_axi_arready <= arready_int;
    s_axi_bvalid <= bvalid_int; s_axi_bresp <= bresp_reg;
    s_axi_rvalid <= rvalid_int; s_axi_rresp <= rresp_reg; s_axi_rdata <= rdata_reg;
    awready_int <= not aw_held and not bvalid_int and aresetn;
    wready_int <= not w_held and not bvalid_int and aresetn;
    -- A fully assembled write has priority over a new read. Outstanding BRAM
    -- reads finish before writes execute, so commands cannot invalidate them.
    arready_int <= not rvalid_int and not read_pending and aresetn and
                   not (aw_held and w_held and not bvalid_int);
    core_resetn <= '0' when state = RESET_CORE else aresetn;
    clear_req <= '1' when state = REQUEST_CLEAR else '0';
    command_valid <= '1' when state = SEND_COMMAND else '0';
    engine_valid <= gaussian_valid when state = ACQUIRE else '0';
    gaussian_ready <= engine_ready when state = ACQUIRE else '0';

    generator : entity work.bm_axis_rtl
        generic map (
            BM_U1_BITS => BM_U1_BITS,
            BM_U2_BITS => BM_U2_BITS,
            BM_PRNG_BITS => BM_PRNG_BITS,
            BM_PRNG_SEED => BM_PRNG_SEED,
            BM_LOG_XY_BITS => BM_LOG_XY_BITS,
            BM_LOG_X_BITS => BM_LOG_X_BITS,
            BM_LOG_Y_BITS => BM_LOG_Y_BITS,
            BM_LOG_X_FRAC_BITS => BM_LOG_X_FRAC_BITS,
            BM_LOG_Y_FRAC_BITS => BM_LOG_Y_FRAC_BITS,
            BM_LOG_Z_BITS => BM_LOG_Z_BITS,
            BM_LOG_Z_FRAC_BITS => BM_LOG_Z_FRAC_BITS,
            BM_LOG_ITERATIONS => BM_LOG_ITERATIONS,
            BM_LOG_CONST_BITS => BM_LOG_CONST_BITS,
            BM_LOG_CONST_FRAC_BITS => BM_LOG_CONST_FRAC_BITS,
            BM_LOG_OUTPUT_BITS => BM_LOG_OUTPUT_BITS,
            BM_LOG_OUTPUT_FRAC_BITS => BM_LOG_OUTPUT_FRAC_BITS,
            BM_SQRT_INPUT_BITS => BM_SQRT_INPUT_BITS,
            BM_SQRT_INPUT_FRAC_BITS => BM_SQRT_INPUT_FRAC_BITS,
            BM_SQRT_OUTPUT_BITS => BM_SQRT_OUTPUT_BITS,
            BM_SQRT_OUTPUT_FRAC_BITS => BM_SQRT_OUTPUT_FRAC_BITS,
            BM_SQRT_REMAINDER_BITS => BM_SQRT_REMAINDER_BITS,
            BM_TRIG_XY_BITS => BM_TRIG_XY_BITS,
            BM_TRIG_X_BITS => BM_TRIG_X_BITS,
            BM_TRIG_Y_BITS => BM_TRIG_Y_BITS,
            BM_TRIG_X_FRAC_BITS => BM_TRIG_X_FRAC_BITS,
            BM_TRIG_Y_FRAC_BITS => BM_TRIG_Y_FRAC_BITS,
            BM_TRIG_Z_BITS => BM_TRIG_Z_BITS,
            BM_TRIG_Z_FRAC_BITS => BM_TRIG_Z_FRAC_BITS,
            BM_TRIG_ITERATIONS => BM_TRIG_ITERATIONS,
            BM_TRIG_CONST_BITS => BM_TRIG_CONST_BITS,
            BM_TRIG_CONST_FRAC_BITS => BM_TRIG_CONST_FRAC_BITS,
            BM_OUTPUT_BITS => BM_OUTPUT_BITS,
            BM_OUTPUT_FRAC_BITS => BM_OUTPUT_FRAC_BITS,
            BM_ROUNDING_MODE => BM_ROUNDING_MODE,
            BM_OVERFLOW_MODE => BM_OVERFLOW_MODE
        )
        port map (aclk => aclk, aresetn => core_resetn,
                  s_axis_tdata => std_logic_vector(requested),
                  s_axis_tvalid => command_valid, s_axis_tready => command_ready,
                  m_axis_tdata => gaussian_data, m_axis_tvalid => gaussian_valid,
                  m_axis_tready => gaussian_ready);

    histogram : entity work.bm_histogram_engine
        generic map (SAMPLE_BITS => BM_OUTPUT_BITS, SAMPLE_FRAC_BITS => BM_OUTPUT_FRAC_BITS,
                     HIST_ADDR_BITS => HIST_ADDR_BITS, COUNTER_BITS => COUNTER_BITS)
        port map (aclk => aclk, aresetn => aresetn, clear_req => clear_req,
                  clearing => clearing, clear_done => clear_done,
                  sample_data => signed(gaussian_data(BM_OUTPUT_BITS-1 downto 0)),
                  sample_valid => engine_valid, sample_ready => engine_ready,
                  drained => drained, bin_read_req => bin_read_req,
                  bin_read_addr => bin_addr, bin_read_valid => bin_read_valid,
                  bin_read_data => bin_read_data, statistics => statistics,
                  counter_overflow => overflow_flag);

    registers_and_controller : process(aclk)
        variable address_value : natural range 0 to 4095;
        variable masked, merged : std_logic_vector(31 downto 0);
        variable index_value : natural range 0 to 12;
        variable is_counter, is_high, invalid, clears_results : boolean;
        variable counter_value : unsigned(63 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state <= BOOT_CLEAR; run_after_clear <= '0';
                done_flag <= '0'; error_flag <= '0';
                n_samples <= (others => '0'); requested <= (others => '0'); remaining <= (others => '0');
                bin_addr <= (others => '0'); bin_read_req <= '0'; read_pending <= '0';
                bin_snapshot <= (others => '0'); bin_snapshot_valid <= '0';
                snapshots <= (others => (others => '0')); snapshot_valid <= (others => '0');
                aw_held <= '0'; w_held <= '0'; bvalid_int <= '0'; rvalid_int <= '0';
                awaddr_reg <= (others => '0'); wdata_reg <= (others => '0'); wstrb_reg <= (others => '0');
                bresp_reg <= "00"; rresp_reg <= "00"; rdata_reg <= (others => '0');
            else
                clears_results := false;
                bin_read_req <= '0';
                if bvalid_int = '1' and s_axi_bready = '1' then bvalid_int <= '0'; end if;
                if rvalid_int = '1' and s_axi_rready = '1' then rvalid_int <= '0'; end if;
                if awready_int = '1' and s_axi_awvalid = '1' then
                    awaddr_reg <= s_axi_awaddr; aw_held <= '1';
                end if;
                if wready_int = '1' and s_axi_wvalid = '1' then
                    wdata_reg <= s_axi_wdata; wstrb_reg <= s_axi_wstrb; w_held <= '1';
                end if;

                case state is
                    when BOOT_CLEAR =>
                        if clear_done = '1' then state <= IDLE; end if;
                    when IDLE => null;
                    when RESET_CORE => state <= REQUEST_CLEAR;
                    when REQUEST_CLEAR => state <= WAIT_CLEAR;
                    when WAIT_CLEAR =>
                        if clear_done = '1' then
                            if run_after_clear = '1' then state <= SEND_COMMAND;
                            else state <= IDLE; end if;
                        end if;
                    when SEND_COMMAND =>
                        if command_ready = '1' then state <= ACQUIRE; end if;
                    when ACQUIRE =>
                        if gaussian_valid = '1' and engine_ready = '1' then
                            remaining <= remaining-1;
                            if remaining = 1 then state <= DRAIN_PIPELINE; end if;
                        end if;
                    when DRAIN_PIPELINE =>
                        if drained = '1' and command_ready = '1' and gaussian_valid = '0' then
                            state <= IDLE; done_flag <= '1';
                        end if;
                end case;

                if read_pending = '1' and bin_read_valid = '1' then
                    bin_snapshot <= bin_read_data; bin_snapshot_valid <= '1';
                    rdata_reg <= std_logic_vector(bin_read_data(31 downto 0));
                    rresp_reg <= "00"; rvalid_int <= '1'; read_pending <= '0';
                end if;

                if aw_held = '1' and w_held = '1' and bvalid_int = '0' and read_pending = '0' then
                    aw_held <= '0'; w_held <= '0'; bvalid_int <= '1'; bresp_reg <= "00";
                    address_value := to_integer(unsigned(awaddr_reg)); invalid := false;
                    masked := apply_strobes(x"00000000",wdata_reg,wstrb_reg);
                    case address_value is
                        when 16#000# =>
                            if masked(31 downto 3) /= (31 downto 3 => '0') then
                                invalid := true;
                            elsif masked(2 downto 0) = "000" then null;
                            elsif masked(2 downto 0) /= "001" and masked(2 downto 0) /= "010" and
                                  masked(2 downto 0) /= "100" then
                                invalid := true;
                            elsif state /= IDLE or drained = '0' then invalid := true;
                            elsif masked(1 downto 0) /= "00" and n_samples = 0 then invalid := true;
                            else
                                done_flag <= '0'; error_flag <= '0';
                                snapshot_valid <= (others => '0'); bin_snapshot_valid <= '0';
                                requested <= n_samples; remaining <= n_samples;
                                if masked(0) = '1' then
                                    run_after_clear <= '1'; state <= RESET_CORE; clears_results := true;
                                elsif masked(1) = '1' then
                                    state <= SEND_COMMAND;
                                else
                                    run_after_clear <= '0'; state <= REQUEST_CLEAR; clears_results := true;
                                end if;
                            end if;
                        when 16#008# =>
                            n_samples <= unsigned(apply_strobes(std_logic_vector(n_samples),wdata_reg,wstrb_reg));
                        when 16#014# =>
                            merged := apply_strobes(std_logic_vector(resize(bin_addr,32)),wdata_reg,wstrb_reg);
                            if unsigned(merged) >= to_unsigned(2**HIST_ADDR_BITS,32) then invalid := true;
                            else bin_addr <= resize(unsigned(merged),HIST_ADDR_BITS); bin_snapshot_valid <= '0'; end if;
                        when others => invalid := true;
                    end case;
                    if invalid then bresp_reg <= "10"; error_flag <= '1'; end if;
                end if;

                if arready_int = '1' and s_axi_arvalid = '1' then
                    address_value := to_integer(unsigned(s_axi_araddr));
                    rvalid_int <= '1'; rresp_reg <= "00"; rdata_reg <= (others => '0');
                    invalid := false; is_counter := false; is_high := false; index_value := 0;
                    case address_value is
                        when 16#004# =>
                            if state /= IDLE then rdata_reg(0) <= '1'; end if;
                            rdata_reg(1) <= done_flag; rdata_reg(2) <= error_flag;
                            rdata_reg(3) <= clearing; rdata_reg(4) <= overflow_flag;
                        when 16#008# => rdata_reg <= std_logic_vector(n_samples);
                        when 16#014# => rdata_reg <= std_logic_vector(resize(bin_addr,32));
                        when 16#018# =>
                            if state /= IDLE or drained = '0' then invalid := true;
                            else bin_read_req <= '1'; read_pending <= '1'; rvalid_int <= '0'; end if;
                        when 16#01C# =>
                            if state /= IDLE or bin_snapshot_valid = '0' then invalid := true;
                            else rdata_reg <= std_logic_vector(bin_snapshot(63 downto 32)); end if;
                        when 16#00C# | 16#010# =>
                            is_counter := true; index_value := 0; is_high := address_value = 16#010#;
                        when 16#020# | 16#024# =>
                            is_counter := true; index_value := 1; is_high := address_value = 16#024#;
                        when 16#028# | 16#02C# =>
                            is_counter := true; index_value := 2; is_high := address_value = 16#02C#;
                        when others =>
                            if address_value >= 16#030# and address_value <= 16#07C# and address_value mod 4 = 0 then
                                is_counter := true; index_value := 3+(address_value-16#030#)/8;
                                is_high := address_value mod 8 = 4;
                            else invalid := true; end if;
                    end case;
                    if is_counter then
                        if is_high then
                            if snapshot_valid(index_value) = '0' then invalid := true;
                            else rdata_reg <= std_logic_vector(snapshots(index_value)(63 downto 32)); end if;
                        else
                            counter_value := unsigned(statistics(64*index_value+63 downto 64*index_value));
                            snapshots(index_value) <= counter_value; snapshot_valid(index_value) <= '1';
                            rdata_reg <= std_logic_vector(counter_value(31 downto 0));
                        end if;
                    end if;
                    if invalid then rresp_reg <= "10"; error_flag <= '1'; end if;
                end if;
                -- Errors do not abort an acquisition or discard its samples.
                -- START/CLEAR intentionally erase the old saturation indication.
                if overflow_flag = '1' and not clears_results and state /= RESET_CORE and state /= REQUEST_CLEAR and state /= WAIT_CLEAR then
                    error_flag <= '1';
                end if;
                if gaussian_valid = '1' and state /= ACQUIRE and state /= RESET_CORE then
                    error_flag <= '1';
                end if;
            end if;
        end if;
    end process;
end architecture;
