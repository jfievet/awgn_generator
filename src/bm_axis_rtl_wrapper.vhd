library ieee;
use ieee.std_logic_1164.all;

-- Fixed-width top level using the default Box-Muller configuration.
entity bm_axis_rtl_wrapper is
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;
        s_axis_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        m_axis_tdata  : out std_logic_vector(23 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic
    );
end entity bm_axis_rtl_wrapper;

architecture rtl of bm_axis_rtl_wrapper is
begin
    -- Omitting the generic map selects all entity default values.
    core : entity work.bm_axis_rtl
        port map (
            aclk          => aclk,
            aresetn       => aresetn,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            m_axis_tdata  => m_axis_tdata,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready
        );
end architecture rtl;
