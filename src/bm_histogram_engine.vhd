-- Vendor-neutral synchronous histogram accumulator, VHDL-1993.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bm_histogram_engine is
    generic (
        SAMPLE_BITS : positive := 24;
        SAMPLE_FRAC_BITS : natural := 18;
        HIST_ADDR_BITS : positive := 10;
        COUNTER_BITS : positive := 64
    );
    port (
        aclk, aresetn : in std_logic;
        clear_req : in std_logic;
        clearing, clear_done : out std_logic;
        sample_data : in signed(SAMPLE_BITS-1 downto 0);
        sample_valid : in std_logic;
        sample_ready : out std_logic;
        drained : out std_logic;
        -- Only request readback while drained and not clearing/acquiring.
        bin_read_req : in std_logic;
        bin_read_addr : in unsigned(HIST_ADDR_BITS-1 downto 0);
        bin_read_valid : out std_logic;
        bin_read_data : out unsigned(63 downto 0);
        -- 64-bit words: total, underflow, overflow, +3..+7, -3..-7.
        statistics : out std_logic_vector(13*64-1 downto 0);
        counter_overflow : out std_logic
    );
end entity;

architecture rtl of bm_histogram_engine is
    constant DEPTH : positive := 2**HIST_ADDR_BITS;
    subtype count_t is unsigned(COUNTER_BITS-1 downto 0);
    constant COUNT_MAX : count_t := (others => '1');
    type memory_t is array(0 to DEPTH-1) of count_t;
    type statistics_t is array(0 to 12) of count_t;
    signal memory : memory_t;
    signal counts : statistics_t;
    signal clear_active, overflow_flag : std_logic;
    signal clear_addr : unsigned(HIST_ADDR_BITS-1 downto 0);
    signal ready_int, accept_sample, in_range : std_logic;
    signal mapped_addr, read_addr : unsigned(HIST_ADDR_BITS-1 downto 0);
    signal sample_ext : signed(64 downto 0);
    constant LIMIT : signed(64 downto 0) := shift_left(to_signed(8,65),SAMPLE_FRAC_BITS);
    signal read_enable : std_logic;
    signal ram_q : count_t;
    signal update_valid, write_valid, committed_valid : std_logic;
    signal update_addr, write_addr, committed_addr : unsigned(HIST_ADDR_BITS-1 downto 0);
    signal write_data, committed_data : count_t;
    signal readback_pending : std_logic;
    function increment(v : count_t) return count_t is
    begin
        if v = COUNT_MAX then return v; end if;
        return v+1;
    end function;
begin
    assert HIST_ADDR_BITS >= 4 and HIST_ADDR_BITS <= 10
        report "HIST_ADDR_BITS must be 4..10" severity failure;
    assert COUNTER_BITS <= 64 and SAMPLE_BITS <= 64 and SAMPLE_FRAC_BITS <= 48
        report "Unsupported histogram numeric format" severity failure;
    clearing <= clear_active;
    counter_overflow <= overflow_flag;
    ready_int <= not clear_active and not clear_req and not bin_read_req and not readback_pending and aresetn;
    sample_ready <= ready_int;
    accept_sample <= sample_valid and ready_int;
    drained <= not update_valid and not write_valid and not readback_pending and
               not clear_active and not clear_req and not bin_read_req;
    sample_ext <= resize(sample_data,65);
    in_range <= '1' when sample_ext >= -LIMIT and sample_ext < LIMIT else '0';

    -- floor((Z+8) * DEPTH/16), with no integer conversion of raw samples.
    mapping : process(sample_ext)
        variable offset_value : unsigned(64 downto 0);
    begin
        offset_value := unsigned(sample_ext+LIMIT);
        if SAMPLE_FRAC_BITS+4 >= HIST_ADDR_BITS then
            mapped_addr <= resize(shift_right(offset_value,SAMPLE_FRAC_BITS+4-HIST_ADDR_BITS),HIST_ADDR_BITS);
        else
            mapped_addr <= resize(shift_left(offset_value,HIST_ADDR_BITS-SAMPLE_FRAC_BITS-4),HIST_ADDR_BITS);
        end if;
    end process;
    read_enable <= (accept_sample and in_range) or bin_read_req;
    read_addr <= mapped_addr when accept_sample = '1' and in_range = '1' else bin_read_addr;
    export_statistics : for i in 0 to 12 generate
        statistics(64*i+63 downto 64*i) <= std_logic_vector(resize(counts(i),64));
    end generate;

    -- No reset on memory or its output register: simple dual-port BRAM template.
    -- Correctness does not depend on the device's read-during-write mode.
    memory_ports : process(aclk)
    begin
        if rising_edge(aclk) then
            if clear_active = '1' then
                memory(to_integer(clear_addr)) <= (others => '0');
            elsif write_valid = '1' then
                memory(to_integer(write_addr)) <= write_data;
            end if;
            if read_enable = '1' and clear_active = '0' then
                ram_q <= memory(to_integer(read_addr));
            end if;
        end if;
    end process;

    accumulation : process(aclk)
        variable base : count_t;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                clear_active <= '1'; clear_addr <= (others => '0'); clear_done <= '0';
                counts <= (others => (others => '0')); overflow_flag <= '0';
                update_valid <= '0'; write_valid <= '0'; committed_valid <= '0';
                update_addr <= (others => '0'); write_addr <= (others => '0');
                committed_addr <= (others => '0'); write_data <= (others => '0');
                committed_data <= (others => '0'); readback_pending <= '0';
                bin_read_valid <= '0'; bin_read_data <= (others => '0');
            else
                clear_done <= '0'; bin_read_valid <= '0';
                if clear_req = '1' then
                    clear_active <= '1'; clear_addr <= (others => '0');
                    counts <= (others => (others => '0')); overflow_flag <= '0';
                    update_valid <= '0'; write_valid <= '0'; committed_valid <= '0';
                    readback_pending <= '0';
                elsif clear_active = '1' then
                    if clear_addr = to_unsigned(DEPTH-1,HIST_ADDR_BITS) then
                        clear_active <= '0'; clear_done <= '1';
                    else
                        clear_addr <= clear_addr+1;
                    end if;
                else
                    -- A read sampled one clock ago becomes an increment now.
                    update_valid <= accept_sample and in_range;
                    update_addr <= mapped_addr;
                    write_valid <= update_valid;
                    committed_valid <= write_valid;
                    if write_valid = '1' then
                        committed_addr <= write_addr; committed_data <= write_data;
                    end if;
                    if update_valid = '1' then
                        base := ram_q;
                        -- Newest pending value wins; the committed bypass also
                        -- covers a RAM read colliding with the preceding write.
                        if write_valid = '1' and write_addr = update_addr then
                            base := write_data;
                        elsif committed_valid = '1' and committed_addr = update_addr then
                            base := committed_data;
                        end if;
                        write_addr <= update_addr; write_data <= increment(base);
                        if base = COUNT_MAX then overflow_flag <= '1'; end if;
                    end if;
                    readback_pending <= bin_read_req;
                    if readback_pending = '1' then
                        bin_read_data <= resize(ram_q,64); bin_read_valid <= '1';
                    end if;
                    if accept_sample = '1' then
                        counts(0) <= increment(counts(0));
                        if counts(0) = COUNT_MAX then overflow_flag <= '1'; end if;
                        if sample_ext < -LIMIT then
                            counts(1) <= increment(counts(1));
                            if counts(1) = COUNT_MAX then overflow_flag <= '1'; end if;
                        elsif sample_ext >= LIMIT then
                            counts(2) <= increment(counts(2));
                            if counts(2) = COUNT_MAX then overflow_flag <= '1'; end if;
                        end if;
                        for i in 0 to 4 loop
                            if sample_ext > shift_left(to_signed(i+3,65),SAMPLE_FRAC_BITS) then
                                counts(3+i) <= increment(counts(3+i));
                                if counts(3+i) = COUNT_MAX then overflow_flag <= '1'; end if;
                            end if;
                            if sample_ext < -shift_left(to_signed(i+3,65),SAMPLE_FRAC_BITS) then
                                counts(8+i) <= increment(counts(8+i));
                                if counts(8+i) = COUNT_MAX then overflow_flag <= '1'; end if;
                            end if;
                        end loop;
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
