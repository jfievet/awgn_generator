library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library vunit_lib;
context vunit_lib.vunit_context;

entity bm_histogram_axi_tb is
    generic (runner_cfg : string; prng_bits : positive := 64; counter_bits : positive := 64);
end entity;

architecture test of bm_histogram_axi_tb is
    function seed return std_logic_vector is
    begin
        if prng_bits = 32 then return x"0000000012345678"; end if;
        return x"123456789ABCDEF1";
    end function;
    constant PRNG_SEED : std_logic_vector(63 downto 0) := seed;
    type bins_t is array(0 to 1023) of natural;
    type stats_t is array(0 to 12) of natural;
    signal expected_bins : bins_t := (others => 0);
    signal expected_stats : stats_t := (others => 0);
    signal clk : std_logic := '0';
    signal resetn : std_logic := '0';
    signal awaddr, araddr : std_logic_vector(11 downto 0) := (others => '0');
    signal awvalid, wvalid, bready, arvalid, rready : std_logic := '0';
    signal awready, wready, bvalid, arready, rvalid : std_logic;
    signal wdata : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb : std_logic_vector(3 downto 0) := "1111";
    signal rdata : std_logic_vector(31 downto 0);
    signal bresp, rresp : std_logic_vector(1 downto 0);
    signal ref_resetn, ref_command_valid, ref_clear_stats : std_logic := '0';
    signal ref_command : std_logic_vector(31 downto 0) := (others => '0');
    signal ref_command_ready, ref_valid : std_logic;
    signal ref_data : std_logic_vector(23 downto 0);
begin
    clk <= not clk after 5 ns;
    test_runner_watchdog(runner,30 ms);
    dut : entity work.bm_histogram_axi
        generic map (BM_PRNG_BITS => prng_bits, BM_PRNG_SEED => PRNG_SEED, COUNTER_BITS => counter_bits)
        port map (aclk => clk, aresetn => resetn,
                  s_axi_awaddr => awaddr, s_axi_awprot => "000", s_axi_awvalid => awvalid, s_axi_awready => awready,
                  s_axi_wdata => wdata, s_axi_wstrb => wstrb, s_axi_wvalid => wvalid, s_axi_wready => wready,
                  s_axi_bresp => bresp, s_axi_bvalid => bvalid, s_axi_bready => bready,
                  s_axi_araddr => araddr, s_axi_arprot => "000", s_axi_arvalid => arvalid, s_axi_arready => arready,
                  s_axi_rdata => rdata, s_axi_rresp => rresp, s_axi_rvalid => rvalid, s_axi_rready => rready);
    -- Independent numerical reference; the integrated DUT always uses real RTL.
    reference : entity work.bm_axis_behavioral
        generic map (BM_PRNG_BITS => prng_bits, BM_PRNG_SEED => PRNG_SEED)
        port map (aclk => clk, aresetn => ref_resetn,
                  s_axis_tdata => ref_command, s_axis_tvalid => ref_command_valid,
                  s_axis_tready => ref_command_ready, m_axis_tdata => ref_data,
                  m_axis_tvalid => ref_valid, m_axis_tready => '1');
    scoreboard : process(clk)
        variable raw, index_value : integer;
    begin
        if rising_edge(clk) then
            if ref_resetn = '0' or ref_clear_stats = '1' then
                expected_bins <= (others => 0); expected_stats <= (others => 0);
            elsif ref_valid = '1' then
                raw := to_integer(signed(ref_data));
                expected_stats(0) <= expected_stats(0)+1;
                if raw < -8*2**18 then expected_stats(1) <= expected_stats(1)+1;
                elsif raw >= 8*2**18 then expected_stats(2) <= expected_stats(2)+1;
                else
                    index_value := (raw+8*2**18)/4096;
                    expected_bins(index_value) <= expected_bins(index_value)+1;
                end if;
                for i in 0 to 4 loop
                    if raw > (i+3)*2**18 then expected_stats(3+i) <= expected_stats(3+i)+1; end if;
                    if raw < -(i+3)*2**18 then expected_stats(8+i) <= expected_stats(8+i)+1; end if;
                end loop;
            end if;
        end if;
    end process;

    main : process
        variable data, held_data : std_logic_vector(31 downto 0);
        variable count64 : unsigned(63 downto 0);
        variable first_histogram : bins_t;
        variable last_progress : natural;
        variable saw_busy : boolean;
        procedure tick is
        begin wait until rising_edge(clk); wait for 1 ns; end procedure;
        procedure write_reg(constant address_value : natural;
                            constant value : std_logic_vector(31 downto 0);
                            constant strobes : std_logic_vector(3 downto 0) := "1111";
                            constant gap : integer := 0;
                            constant stalls : natural := 0;
                            constant response : std_logic_vector(1 downto 0) := "00") is
            variable aw_done, w_done : boolean := false;
            variable cycles : natural := 0;
        begin
            awaddr <= std_logic_vector(to_unsigned(address_value,12)); wdata <= value; wstrb <= strobes;
            bready <= '0';
            while not (aw_done and w_done) loop
                if not aw_done and (gap >= 0 or cycles >= -gap) then awvalid <= '1'; else awvalid <= '0'; end if;
                if not w_done and (gap <= 0 or cycles >= gap) then wvalid <= '1'; else wvalid <= '0'; end if;
                wait until rising_edge(clk);
                if awvalid = '1' and awready = '1' then aw_done := true; end if;
                if wvalid = '1' and wready = '1' then w_done := true; end if;
                wait for 1 ns; cycles := cycles+1;
            end loop;
            awvalid <= '0'; wvalid <= '0';
            while bvalid /= '1' loop tick; end loop;
            check_equal(bresp,response,"write response at " & integer'image(address_value));
            for i in 1 to stalls loop tick; check_equal(bvalid,'1'); check_equal(bresp,response); end loop;
            bready <= '1'; tick; bready <= '0';
        end procedure;
        procedure read_reg(constant address_value : natural;
                           variable value : out std_logic_vector(31 downto 0);
                           constant stalls : natural := 0;
                           constant response : std_logic_vector(1 downto 0) := "00") is
            variable held : std_logic_vector(31 downto 0);
        begin
            araddr <= std_logic_vector(to_unsigned(address_value,12)); arvalid <= '1'; rready <= '0';
            loop wait until rising_edge(clk); exit when arready = '1'; end loop;
            wait for 1 ns; arvalid <= '0';
            while rvalid /= '1' loop tick; end loop;
            held := rdata; check_equal(rresp,response,"read response at " & integer'image(address_value));
            for i in 1 to stalls loop
                tick; check_equal(rvalid,'1'); check_equal(rdata,held); check_equal(rresp,response);
            end loop;
            value := rdata; rready <= '1'; tick; rready <= '0';
        end procedure;
        procedure read_count(constant low_address, high_address : natural;
                             variable value : out unsigned(63 downto 0)) is
            variable low_word, high_word : std_logic_vector(31 downto 0);
        begin
            read_reg(low_address,low_word); read_reg(high_address,high_word);
            value := unsigned(high_word & low_word);
        end procedure;
        procedure wait_idle(constant expect_done : boolean) is
        begin
            loop
                read_reg(4,data);
                exit when data(0) = '0';
                check_equal(data(1),'0',"DONE must wait for idle and final writes");
            end loop;
            check_equal(data(1) = '1',expect_done);
        end procedure;
        procedure reference_command(constant count : positive; constant restart : boolean) is
        begin
            if restart then ref_resetn <= '0'; tick; tick; end if;
            ref_resetn <= '1'; ref_command <= std_logic_vector(to_unsigned(count,32)); ref_command_valid <= '1';
            loop wait until rising_edge(clk); exit when ref_command_ready = '1'; end loop;
            wait for 1 ns; ref_command_valid <= '0';
        end procedure;
        procedure begin_measurement(constant count : positive; constant restart : boolean) is
        begin
            write_reg(8,std_logic_vector(to_unsigned(count,32)));
            if restart then write_reg(0,x"00000001");
            else write_reg(0,x"00000002"); end if;
            reference_command(count,restart);
        end procedure;
        procedure verify_results(constant expected_total : natural; constant compare_reference : boolean := true;
                                 constant verbose : boolean := false) is
            variable bin_value, measured_total, sum_value, stat_value : unsigned(63 downto 0);
            variable low_address : natural;
        begin
            read_count(12,16,measured_total); check_equal(measured_total,to_unsigned(expected_total,64));
            if verbose then
                info("[10000] TOTAL_COUNT=0x" & to_hstring(measured_total) &
                     "; requested=" & integer'image(expected_total));
                info("[10000] Reading all 1024 RAM bins through AXI4-Lite (low then high)");
            end if;
            if compare_reference then
                -- Reference may be a few cycles behind after a tiny measurement.
                while expected_stats(0) < expected_total loop tick; end loop;
            end if;
            sum_value := (others => '0');
            for i in 0 to 1023 loop
                write_reg(20,std_logic_vector(to_unsigned(i,32)));
                read_count(24,28,bin_value); sum_value := sum_value+bin_value;
                if compare_reference then check_equal(bin_value,to_unsigned(expected_bins(i),64),"reference bin " & integer'image(i)); end if;
                if verbose then
                    info("[10000] RAM bin=" & integer'image(i) &
                         " count=0x" & to_hstring(bin_value) &
                         " expected=" & integer'image(expected_bins(i)));
                end if;
            end loop;
            for i in 1 to 12 loop
                if i = 1 then low_address := 32;
                elsif i = 2 then low_address := 40;
                else low_address := 48+8*(i-3); end if;
                read_count(low_address,low_address+4,stat_value);
                if verbose then
                    info("[10000] STAT low_address=0x" & to_hstring(to_unsigned(low_address,12)) &
                         " count=0x" & to_hstring(stat_value) &
                         " expected=" & integer'image(expected_stats(i)));
                end if;
                if i <= 2 then sum_value := sum_value+stat_value; end if;
                if compare_reference then check_equal(stat_value,to_unsigned(expected_stats(i),64),"reference statistic " & integer'image(i));
                elsif expected_total = 0 then check_equal(stat_value,to_unsigned(0,64)); end if;
            end loop;
            check_equal(sum_value,measured_total,"all accepted samples are accounted for");
            if verbose then
                info("[10000] Conservation: sum(RAM bins)+UNDERFLOW+OVERFLOW=0x" &
                     to_hstring(sum_value) & "; TOTAL_COUNT=0x" & to_hstring(measured_total));
            end if;
        end procedure;
    begin
        test_runner_setup(runner,runner_cfg);
        while test_suite loop
            resetn <= '0'; ref_resetn <= '0'; ref_command_valid <= '0'; ref_clear_stats <= '0'; tick; tick;
            resetn <= '1'; wait_idle(false);
            if run("acquire_10000_samples_and_dump_ram") then
                info("[10000] Initialization complete; PRNG_BITS=" & integer'image(prng_bits));
                info("[10000] Writing N_SAMPLES=10000 and START=1 to the real AWGN generator");
                begin_measurement(10000,true);
                read_reg(8,data); check_equal(unsigned(data),to_unsigned(10000,32));
                info("[10000] Waiting for BUSY=0 and DONE=1; counting must finish before RAM readback");
                held_data := (others => '1'); last_progress := 0; saw_busy := false;
                loop
                    read_reg(4,data);
                    if data /= held_data then
                        info("[10000] STATUS=0x" & to_hstring(data) &
                             " BUSY=" & std_logic'image(data(0)) &
                             " DONE=" & std_logic'image(data(1)) &
                             " CLEARING=" & std_logic'image(data(3)));
                        held_data := data;
                    end if;
                    check_equal(data(2),'0',"measurement must not report ERROR");
                    check_equal(data(4),'0',"measurement must not overflow counters");
                    exit when data(0) = '0';
                    saw_busy := true;
                    check_equal(data(1),'0',"DONE must stay low until all writes have committed");
                    read_count(12,16,count64);
                    check(count64 <= to_unsigned(10000,64),"accepted count must not exceed N");
                    if count64 >= to_unsigned(last_progress+1000,64) then
                        info("[10000] Acquisition progress: " & integer'image(to_integer(count64)) & "/10000 samples");
                        last_progress := (to_integer(count64)/1000)*1000;
                    end if;
                end loop;
                check(saw_busy,"measurement must enter BUSY");
                check_equal(data(1),'1',"DONE must indicate completed counting and RAM writes");
                check_equal(data(3),'0',"memory clear must be finished");
                info("[10000] Counting complete: BUSY=0, DONE=1, ERROR=0, COUNTER_OVERFLOW=0");
                verify_results(10000,verbose => true);
                read_reg(4,data);
                check_equal(data(0),'0'); check_equal(data(1),'1');
                check_equal(data(2),'0'); check_equal(data(4),'0');
                info("[10000] RAM readback finished: 1024 bins and all statistical counters checked against reference");
            elsif run("axi_protocol_and_errors") then
                read_reg(16,data,response => "10"); -- high without low
                read_reg(28,data,response => "10");
                read_reg(0,data,response => "10");
                read_reg(5,data,response => "10");
                read_reg(128,data,response => "10");
                write_reg(4,x"00000000",response => "10");
                write_reg(9,x"00000000",response => "10");
                write_reg(128,x"00000000",response => "10");
                write_reg(20,x"00000400",response => "10");
                write_reg(0,x"00000001",response => "10"); -- N=0
                write_reg(0,x"00000003",response => "10");
                write_reg(0,x"00000008",response => "10");
                write_reg(8,x"FFFFFFFF"); read_reg(8,data);
                check_equal(data,std_logic_vector'(x"FFFFFFFF"));
                write_reg(8,x"12345678",gap => 5,stalls => 5);
                write_reg(8,x"AABBCCDD",strobes => "0101",gap => -5,stalls => 3);
                read_reg(8,data,stalls => 7); check_equal(data,std_logic_vector'(x"12BB56DD"));
                write_reg(8,x"00000000",strobes => "0000");
                read_reg(8,data); check_equal(data,std_logic_vector'(x"12BB56DD"));
                write_reg(0,x"000000FF",strobes => "0000"); -- no command
                write_reg(0,x"00000004"); wait_idle(false); verify_results(0,false);
                read_reg(4,data); check_equal(data(2),'0',"accepted CLEAR removes errors");
                write_reg(20,x"00000000"); read_reg(24,data,stalls => 4);
                write_reg(20,x"00000001"); read_reg(28,data,response => "10");
            elsif run("measurements_and_reference") then
                begin_measurement(10000,true);
                read_reg(16,data,response => "10"); -- START invalidated snapshots
                write_reg(0,x"00000001",response => "10");
                write_reg(0,x"00000002",response => "10");
                write_reg(0,x"00000004",response => "10");
                read_reg(24,data,response => "10");
                -- Capture low, then delay the high read while the count changes.
                read_reg(12,data); held_data := data;
                for i in 0 to 49 loop tick; end loop;
                read_reg(16,data,stalls => 3); check_equal(data,std_logic_vector'(x"00000000"));
                write_reg(8,x"00000007"); -- does not change active N
                wait_idle(true); verify_results(10000);
                for i in 0 to 1023 loop first_histogram(i) := expected_bins(i); end loop;
                -- START resets PRNG and cached sample, reproducing the sequence.
                begin_measurement(10000,true); wait_idle(true); verify_results(10000);
                for i in 0 to 1023 loop check_equal(expected_bins(i),first_histogram(i)); end loop;
                begin_measurement(7,false);
                read_reg(16,data,response => "10"); -- CONTINUE invalidates old total snapshot
                wait_idle(true); verify_results(10007);
                begin_measurement(1,false); wait_idle(true); verify_results(10008);
                begin_measurement(9,false); wait_idle(true); verify_results(10017);
                -- Odd START followed by another START discards the cached partner.
                begin_measurement(5,true); wait_idle(true); verify_results(5);
                begin_measurement(5,true); wait_idle(true); verify_results(5);
                write_reg(0,x"00000004"); wait_idle(false); verify_results(0,false);
                -- Clear only the reference scoreboard, retaining PRNG/cache.
                ref_clear_stats <= '1'; tick; ref_clear_stats <= '0'; tick;
                begin_measurement(3,false); wait_idle(true); verify_results(3);
                begin_measurement(10000,true);
                for i in 0 to 1299 loop tick; end loop;
                resetn <= '0'; ref_resetn <= '0'; tick; tick; resetn <= '1';
                wait_idle(false); verify_results(0,false);
                begin_measurement(13,true); wait_idle(true); verify_results(13);
            elsif run("counter_saturation") then
                begin_measurement(600,true); wait_idle(true);
                read_count(12,16,count64);
                read_reg(4,data);
                if counter_bits = 8 then
                    check_equal(count64,to_unsigned(255,64));
                    check_equal(data(4),'1'); check_equal(data(2),'1');
                else
                    check_equal(count64,to_unsigned(600,64)); check_equal(data(4),'0');
                end if;
                begin_measurement(1,false); wait_idle(true); read_reg(4,data);
                if counter_bits = 8 then check_equal(data(4),'1'); check_equal(data(2),'1'); end if;
                begin_measurement(1,true); wait_idle(true); verify_results(1);
                read_reg(4,data); check_equal(data(4),'0'); check_equal(data(2),'0');
                begin_measurement(600,true); wait_idle(true);
                write_reg(0,x"00000004"); wait_idle(false); verify_results(0,false);
                read_reg(4,data); check_equal(data(4),'0'); check_equal(data(2),'0');
            elsif run("readback_command_serialization") then
                begin_measurement(17,true); wait_idle(true);
                write_reg(20,x"00000200"); write_reg(8,x"00000011");
                -- Accept a BRAM read, then assemble START while RREADY is low.
                araddr <= x"018"; arvalid <= '1'; rready <= '0';
                loop wait until rising_edge(clk); exit when arready = '1'; end loop;
                wait for 1 ns; arvalid <= '0';
                write_reg(0,x"00000001",stalls => 5);
                while rvalid /= '1' loop tick; end loop;
                held_data := rdata;
                check_equal(unsigned(held_data),to_unsigned(expected_bins(512),32));
                for i in 0 to 7 loop tick; check_equal(rvalid,'1'); check_equal(rdata,held_data); end loop;
                rready <= '1'; tick; rready <= '0';
                reference_command(17,true); wait_idle(true); verify_results(17);
            end if;
        end loop;
        test_runner_cleanup(runner); wait;
    end process;
end architecture;
