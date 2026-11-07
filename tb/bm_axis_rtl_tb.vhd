library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
library vunit_lib;
context vunit_lib.vunit_context;

entity bm_axis_rtl_tb is
    generic (
        runner_cfg : string;
        samples_file : string;
        prng_bits : integer := 64;
        rounding_mode : integer := 0;
        overflow_mode : integer := 0
    );
end entity;

architecture test of bm_axis_rtl_tb is
    function initial_seed(bits : positive) return std_logic_vector is
    begin
        if bits = 32 then return x"0000000012345678"; end if;
        return x"123456789ABCDEF1";
    end function;
    constant PRNG_SEED : std_logic_vector(63 downto 0) := initial_seed(prng_bits);
    constant SAMPLE_COUNT : positive := 100;
    signal clk : std_logic := '0';
    signal resetn : std_logic := '0';
    signal command : std_logic_vector(31 downto 0) := (others => '0');
    signal ref_valid_in, rtl_valid_in : std_logic := '0';
    signal ref_ready_in, rtl_ready_in : std_logic;
    signal ref_data, rtl_data : std_logic_vector(23 downto 0);
    signal ref_valid, rtl_valid : std_logic;
    signal ref_ready, rtl_ready : std_logic := '0';
begin
    clk <= not clk after 5 ns;
    test_runner_watchdog(runner, 1 ms);

    reference : entity work.bm_axis_behavioral
        generic map (BM_PRNG_BITS => prng_bits, BM_PRNG_SEED => prng_seed,
                     BM_ROUNDING_MODE => rounding_mode, BM_OVERFLOW_MODE => overflow_mode)
        port map (aclk => clk, aresetn => resetn,
                  s_axis_tdata => command, s_axis_tvalid => ref_valid_in, s_axis_tready => ref_ready_in,
                  m_axis_tdata => ref_data, m_axis_tvalid => ref_valid, m_axis_tready => ref_ready);
    dut : entity work.bm_axis_rtl
        generic map (BM_PRNG_BITS => prng_bits, BM_PRNG_SEED => prng_seed,
                     BM_ROUNDING_MODE => rounding_mode, BM_OVERFLOW_MODE => overflow_mode)
        port map (aclk => clk, aresetn => resetn,
                  s_axis_tdata => command, s_axis_tvalid => rtl_valid_in, s_axis_tready => rtl_ready_in,
                  m_axis_tdata => rtl_data, m_axis_tvalid => rtl_valid, m_axis_tready => rtl_ready);

    main : process
        procedure reset_models is
        begin
            resetn <= '0'; ref_valid_in <= '0'; rtl_valid_in <= '0';
            ref_ready <= '0'; rtl_ready <= '0';
            for i in 1 to 5 loop wait until rising_edge(clk); end loop;
            wait until falling_edge(clk);
            resetn <= '1';
        end procedure;

        procedure send_command(constant count : natural) is
            variable ref_sent, rtl_sent : boolean := false;
        begin
            command <= std_logic_vector(to_unsigned(count,32));
            ref_valid_in <= '1'; rtl_valid_in <= '1';
            while not (ref_sent and rtl_sent) loop
                wait until rising_edge(clk);
                if not ref_sent and ref_ready_in = '1' then
                    ref_sent := true; ref_valid_in <= '0';
                end if;
                if not rtl_sent and rtl_ready_in = '1' then
                    rtl_sent := true; rtl_valid_in <= '0';
                end if;
            end loop;
        end procedure;

        procedure run_command(constant count : positive;
                              constant stalls : boolean := false;
                              constant use_file : boolean := false) is
            type sample_array is array (natural range <>) of integer;
            variable ref_samples, rtl_samples : sample_array(0 to count-1);
            variable nr, nd, compared, cycles : natural := 0;
            variable started, held : boolean := false;
            variable held_data : std_logic_vector(23 downto 0);
            file samples : text;
            variable status : file_open_status;
            variable row : line;
            variable expected : integer;
            variable good : boolean;
        begin
            if use_file then
                file_open(status,samples,samples_file,read_mode);
                assert status = open_ok report "Cannot open " & samples_file severity failure;
            end if;
            send_command(count);
            ref_ready <= '1'; rtl_ready <= '1';
            while nr < count or nd < count loop
                wait until rising_edge(clk);
                cycles := cycles+1;
                assert cycles < 10000 report "Timed out waiting for samples" severity failure;
                if held then
                    check_equal(rtl_valid,'1',"Valid must remain asserted under backpressure");
                    check_equal(rtl_data,held_data,"Data must remain stable under backpressure");
                end if;
                held := rtl_valid = '1' and rtl_ready = '0';
                held_data := rtl_data;
                if ref_valid = '1' and ref_ready = '1' then
                    assert nr < count report "Extra behavioral beat" severity failure;
                    ref_samples(nr) := to_integer(signed(ref_data)); nr := nr+1;
                end if;
                if started and not stalls and nd < count then
                    check_equal(rtl_valid,'1',"One RTL sample per clock after pipeline fill");
                end if;
                if rtl_valid = '1' and rtl_ready = '1' then
                    assert nd < count report "Extra RTL beat" severity failure;
                    rtl_samples(nd) := to_integer(signed(rtl_data)); nd := nd+1;
                    started := true;
                end if;
                while compared < nr and compared < nd loop
                    info("Sample " & integer'image(compared+1) &
                         " : modele=" & integer'image(ref_samples(compared)) &
                         ", RTL=" & integer'image(rtl_samples(compared)));
                    check_equal(rtl_samples(compared),ref_samples(compared),"RTL/model sample " & integer'image(compared+1));
                    if use_file then
                        assert not endfile(samples) report "Missing file sample" severity failure;
                        readline(samples,row); read(row,expected,good);
                        assert good report "Invalid file sample" severity failure;
                        info("Fichier=" & integer'image(expected));
                        check_equal(rtl_samples(compared),expected,"RTL/file sample " & integer'image(compared+1));
                    end if;
                    compared := compared+1;
                end loop;
                if stalls and cycles mod 11 >= 5 then rtl_ready <= '0';
                else rtl_ready <= '1'; end if;
            end loop;
            if use_file then file_close(samples); end if;
            for i in 1 to 4 loop
                wait until rising_edge(clk);
                check_equal(rtl_valid,'0',"No excess RTL samples");
                check_equal(ref_valid,'0',"No excess reference samples");
            end loop;
            ref_ready <= '0'; rtl_ready <= '0';
        end procedure;
    begin
        test_runner_setup(runner,runner_cfg);
        while test_suite loop
            reset_models;
            if run("compare_100_samples") then
                run_command(SAMPLE_COUNT);
            elsif run("compare_samples_file") then
                if prng_bits = 64 and prng_seed = x"123456789ABCDEF1" and rounding_mode = 0 and overflow_mode = 0 then
                    run_command(SAMPLE_COUNT,use_file => true);
                else
                    info("Reference file applies only to the default configuration");
                    run_command(SAMPLE_COUNT);
                end if;
            elsif run("zero_and_mixed_commands") then
                send_command(0);
                for i in 1 to 4 loop
                    wait until rising_edge(clk);
                    check_equal(rtl_valid,'0',"Zero command produces no data");
                    check_equal(ref_valid,'0',"Zero command produces no reference data");
                end loop;
                run_command(1); send_command(0); run_command(100);
                run_command(3); run_command(2); run_command(1); run_command(5);
            elsif run("backpressure") then
                run_command(SAMPLE_COUNT,stalls => true);
                run_command(3,stalls => true);
                run_command(SAMPLE_COUNT,stalls => true);
            elsif run("reset_in_flight") then
                send_command(SAMPLE_COUNT);
                for i in 1 to 10 loop wait until rising_edge(clk); end loop;
                reset_models;
                run_command(SAMPLE_COUNT);
            elsif run("reset_while_stalled") then
                send_command(SAMPLE_COUNT);
                wait until rising_edge(clk) and rtl_valid = '1';
                for i in 1 to 4 loop wait until rising_edge(clk); end loop;
                reset_models;
                run_command(SAMPLE_COUNT);
            end if;
        end loop;
        test_runner_cleanup(runner);
        wait;
    end process;
end architecture;
