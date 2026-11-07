library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;

entity bm_axis_behavioral_tb is
  generic (
    runner_cfg : string;
    samples_file : string := "model/samples_raw.txt"
  );
end entity;

architecture a of bm_axis_behavioral_tb is
    constant SAMPLE_COUNT : positive := 10_000;
    signal clk : std_logic := '0';
    signal aresetn : std_logic := '0';
    signal s_axis_tdata : std_logic_vector(31 downto 0) := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;
    signal m_axis_tdata : std_logic_vector(23 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '0';

begin

-- Clock
clk <= not clk after 5 ns;

    dut : entity work.bm_axis_behavioral
        port map (
            aclk => clk,
            aresetn => aresetn,
            s_axis_tdata => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            m_axis_tdata => m_axis_tdata,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready
        );

-----------------------------------------
-- Main process with testcases
-----------------------------------------
test_runner : process
    variable received_beat : std_logic_vector(23 downto 0);
    file reference_file : text;
    variable open_status : file_open_status;
    variable sample_line : line;
    variable reference_value : integer;
    variable model_value : integer;
    variable read_ok : boolean;

    procedure reset_model is
    begin
        aresetn <= '0';
        s_axis_tvalid <= '0';
        m_axis_tready <= '0';
        for cycle in 1 to 5 loop
            wait until rising_edge(clk);
        end loop;
        wait until falling_edge(clk);
        aresetn <= '1';
    end procedure;

    procedure axis_write(constant data : in std_logic_vector(31 downto 0)) is
    begin
        s_axis_tdata <= data;
        s_axis_tvalid <= '1';
        wait until rising_edge(clk) and s_axis_tready = '1';
        s_axis_tvalid <= '0';
    end procedure;

    procedure axis_read(variable data : out std_logic_vector(23 downto 0)) is
    begin
        m_axis_tready <= '1';
        wait until rising_edge(clk) and m_axis_tvalid = '1';
        data := m_axis_tdata;
        m_axis_tready <= '0';
    end procedure;
begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
    if run("test_001_read_one_sample") then
        reset_model;

        axis_write(x"00000001");
        axis_read(received_beat);
        info("Beat recu : " & integer'image(to_integer(signed(received_beat))));
    
    elsif run("test_002_compare_samples_raw") then
        reset_model;
        file_open(open_status, reference_file, samples_file, read_mode);
        assert open_status = open_ok
            report "Cannot open samples file: " & samples_file severity failure;

        -- One AXI command requests the complete stream of SAMPLE_COUNT beats.
        axis_write(std_logic_vector(to_unsigned(SAMPLE_COUNT, 32)));
        for sample_index in 1 to SAMPLE_COUNT loop
            assert not endfile(reference_file)
                report "Missing reference sample " & integer'image(sample_index)
                severity failure;
            readline(reference_file, sample_line);
            read(sample_line, reference_value, read_ok);
            assert read_ok
                report "Invalid integer at sample " & integer'image(sample_index)
                severity failure;

            axis_read(received_beat);
            model_value := to_integer(signed(received_beat));
            info("Sample " & integer'image(sample_index) &
                 " : fichier=" & integer'image(reference_value) &
                 ", modele=" & integer'image(model_value));
            check_equal(model_value, reference_value,
                        "Sample " & integer'image(sample_index));
        end loop;
        file_close(reference_file);
    end if;
    end loop;


    test_runner_cleanup(runner);
end process;


end architecture;
