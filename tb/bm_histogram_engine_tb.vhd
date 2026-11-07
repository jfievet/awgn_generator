library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library vunit_lib;
context vunit_lib.vunit_context;

entity bm_histogram_engine_tb is
    generic (runner_cfg : string; counter_bits : positive := 64; frac_bits : natural := 18; hist_addr_bits : positive := 10);
end entity;

architecture test of bm_histogram_engine_tb is
    constant DEPTH : positive := 2**hist_addr_bits;
    constant SCALE : positive := 2**frac_bits;
    function maximum_count return natural is
    begin
        if counter_bits < 31 then return 2**counter_bits-1; end if;
        return integer'high;
    end function;
    constant MAX_COUNT : natural := maximum_count;
    signal clk : std_logic := '0';
    signal resetn, clear_req, sample_valid, bin_req : std_logic := '0';
    signal clearing, clear_done, sample_ready, drained, bin_valid, overflow_flag : std_logic;
    signal sample : signed(23 downto 0) := (others => '0');
    signal bin_addr : unsigned(hist_addr_bits-1 downto 0) := (others => '0');
    signal bin_data : unsigned(63 downto 0);
    signal statistics : std_logic_vector(831 downto 0);
begin
    clk <= not clk after 5 ns;
    test_runner_watchdog(runner,20 ms);
    dut : entity work.bm_histogram_engine
        generic map (SAMPLE_BITS => 24, SAMPLE_FRAC_BITS => frac_bits, COUNTER_BITS => counter_bits,
                     HIST_ADDR_BITS => hist_addr_bits)
        port map (aclk => clk, aresetn => resetn, clear_req => clear_req,
                  clearing => clearing, clear_done => clear_done, sample_data => sample,
                  sample_valid => sample_valid, sample_ready => sample_ready, drained => drained,
                  bin_read_req => bin_req, bin_read_addr => bin_addr,
                  bin_read_valid => bin_valid, bin_read_data => bin_data,
                  statistics => statistics, counter_overflow => overflow_flag);

    main : process
        type bins_t is array(0 to DEPTH-1) of natural;
        type stats_t is array(0 to 12) of natural;
        variable bins : bins_t := (others => 0);
        variable stats : stats_t := (others => 0);
        variable saturated : boolean := false;
        variable random_state : unsigned(31 downto 0) := x"12345678";
        variable value : integer;
        procedure tick is
        begin wait until rising_edge(clk); wait for 1 ns; end procedure;
        procedure increment(variable count : inout natural) is
        begin
            if count = MAX_COUNT then saturated := true;
            else count := count+1; end if;
        end procedure;
        procedure account(constant raw : integer) is
            variable index_value : natural;
        begin
            increment(stats(0));
            if raw < -8*SCALE then increment(stats(1));
            elsif raw >= 8*SCALE then increment(stats(2));
            else
                index_value := ((raw+8*SCALE)*(DEPTH/16))/SCALE;
                increment(bins(index_value));
            end if;
            for i in 0 to 4 loop
                if raw > (i+3)*SCALE then increment(stats(3+i)); end if;
                if raw < -(i+3)*SCALE then increment(stats(8+i)); end if;
            end loop;
        end procedure;
        procedure send(constant raw : integer) is
        begin
            sample <= to_signed(raw,24); sample_valid <= '1';
            loop
                wait until rising_edge(clk);
                exit when sample_ready = '1';
            end loop;
            account(raw); wait for 1 ns;
        end procedure;
        procedure stop_and_drain is
        begin
            sample_valid <= '0'; tick;
            while drained /= '1' loop tick; end loop;
        end procedure;
        procedure verify is
        begin
            stop_and_drain;
            for i in 0 to 12 loop
                check_equal(unsigned(statistics(64*i+63 downto 64*i)),to_unsigned(stats(i),64),"statistic " & integer'image(i));
            end loop;
            check_equal(overflow_flag = '1',saturated,"overflow flag");
            for i in 0 to DEPTH-1 loop
                bin_addr <= to_unsigned(i,hist_addr_bits); bin_req <= '1'; tick; bin_req <= '0';
                while bin_valid /= '1' loop tick; end loop;
                check_equal(bin_data,to_unsigned(bins(i),64),"bin " & integer'image(i));
                tick;
            end loop;
        end procedure;
        procedure erase is
        begin
            stop_and_drain; clear_req <= '1'; tick; clear_req <= '0';
            check_equal(clearing,'1');
            while clear_done /= '1' loop
                check_equal(sample_ready,'0',"blocked while clearing"); tick;
            end loop;
            bins := (others => 0); stats := (others => 0); saturated := false;
        end procedure;
    begin
        test_runner_setup(runner,runner_cfg);
        while test_suite loop
            resetn <= '0'; sample_valid <= '0'; clear_req <= '0'; bin_req <= '0'; tick; tick;
            resetn <= '1';
            while clear_done /= '1' loop tick; end loop;
            bins := (others => 0); stats := (others => 0); saturated := false;
            if run("mapping_hazards_and_clear") then
                -- Endpoints and strict threshold comparisons, one LSB either side.
                send(-8*SCALE-1); send(-8*SCALE); send(-1); send(0); send(1);
                send(8*SCALE-1); send(8*SCALE); send(8*SCALE+1);
                for k in 3 to 7 loop
                    for delta in -1 to 1 loop
                        send(k*SCALE+delta); send(-k*SCALE+delta);
                    end loop;
                end loop;
                -- Exact lower boundaries and preceding LSB for all bins.
                for i in 0 to DEPTH-1 loop
                    value := -8*SCALE+(i*SCALE)/(DEPTH/16);
                    send(value); send(value-1);
                end loop;
                -- A,A,A and A,B,A exercise pending and committed bypasses.
                for i in 0 to 599 loop send(0); end loop;
                for i in 0 to 599 loop
                    if i mod 2 = 0 then send(0); else send(SCALE); end if;
                end loop;
                for i in 0 to 3999 loop
                    random_state := random_state xor shift_left(random_state,13);
                    random_state := random_state xor shift_right(random_state,17);
                    random_state := random_state xor shift_left(random_state,5);
                    value := (to_integer(random_state(23 downto 0)) mod (18*SCALE))-9*SCALE;
                    send(value);
                end loop;
                -- Exercise saturation of every statistical counter in the
                -- narrow-counter configuration, including both range counters.
                for i in 0 to 299 loop send(9*SCALE); send(-9*SCALE); end loop;
                verify; erase; verify;
                -- Hold a sample throughout clear: no transfer until ready returns.
                clear_req <= '1'; tick; clear_req <= '0';
                sample <= to_signed(7*SCALE+1,24); sample_valid <= '1';
                while sample_ready /= '1' loop tick; end loop;
                wait until rising_edge(clk); account(7*SCALE+1); wait for 1 ns;
                verify;
            end if;
        end loop;
        test_runner_cleanup(runner); wait;
    end process;
end architecture;
