-- Copyright (c) 2011-2026 Columbia University, System Level Design Group
-- SPDX-License-Identifier: Apache-2.0
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.grlib_config.all;
use work.stdlib.all;
use work.amba.all;
use work.gencomp.all;
use work.config.all;
use work.esp_global.all;
use work.socmap.all;

entity zynqmp_top_wrapper is
  port (
    uart_rxd         : in    std_ulogic;
    uart_txd         : out   std_ulogic;
    uart_ctsn        : in    std_ulogic;
    uart_rtsn        : out   std_ulogic;
    switch           : in    std_logic_vector(7 downto 0);
    led              : out   std_logic_vector(6 downto 0)
    );

end zynqmp_top_wrapper;

architecture rtl of zynqmp_top_wrapper is

  constant ZYNQMP_DDR_AXI_ADDR_BITS : integer := 49;

  component top is
    generic (
      SIMULATION : boolean);
    port (
      reset       : in  std_ulogic;
      chip_refclk : in  std_ulogic;
      uart_rxd    : in  std_ulogic;
      uart_txd    : out std_ulogic;
      uart_ctsn   : in  std_ulogic;
      uart_rtsn   : out std_ulogic;
      led         : out std_logic_vector(6 downto 0);
      ddr_awid    : out std_logic_vector(5 downto 0);
      ddr_awaddr  : out std_logic_vector(GLOB_PHYS_ADDR_BITS - 1 downto 0);
      ddr_awlen   : out std_logic_vector(7 downto 0);
      ddr_awsize  : out std_logic_vector(2 downto 0);
      ddr_awburst : out std_logic_vector(1 downto 0);
      ddr_awlock  : out std_logic;
      ddr_awcache : out std_logic_vector(3 downto 0);
      ddr_awprot  : out std_logic_vector(2 downto 0);
      ddr_awqos   : out std_logic_vector(3 downto 0);
      ddr_awvalid : out std_logic;
      ddr_awready : in  std_logic;
      ddr_wdata   : out std_logic_vector(AXIDW - 1 downto 0);
      ddr_wstrb   : out std_logic_vector(AW - 1 downto 0);
      ddr_wlast   : out std_logic;
      ddr_wvalid  : out std_logic;
      ddr_wready  : in  std_logic;
      ddr_bid     : in  std_logic_vector(5 downto 0);
      ddr_bresp   : in  std_logic_vector(1 downto 0);
      ddr_bvalid  : in  std_logic;
      ddr_bready  : out std_logic;
      ddr_arid    : out std_logic_vector(5 downto 0);
      ddr_araddr  : out std_logic_vector(GLOB_PHYS_ADDR_BITS - 1 downto 0);
      ddr_arlen   : out std_logic_vector(7 downto 0);
      ddr_arsize  : out std_logic_vector(2 downto 0);
      ddr_arburst : out std_logic_vector(1 downto 0);
      ddr_arlock  : out std_logic;
      ddr_arcache : out std_logic_vector(3 downto 0);
      ddr_arprot  : out std_logic_vector(2 downto 0);
      ddr_arqos   : out std_logic_vector(3 downto 0);
      ddr_arvalid : out std_logic;
      ddr_arready : in  std_logic;
      ddr_rid     : in  std_logic_vector(5 downto 0);
      ddr_rdata   : in  std_logic_vector(AXIDW - 1 downto 0);
      ddr_rresp   : in  std_logic_vector(1 downto 0);
      ddr_rlast   : in  std_logic;
      ddr_rvalid  : in  std_logic;
      ddr_rready  : out std_logic;
      mi_hready   : out std_ulogic;
      mi_hresp    : out std_logic_vector(1 downto 0);
      mi_hrdata   : out std_logic_vector(31 downto 0);
      mo_hlock    : in  std_ulogic;
      mo_htrans   : in  std_logic_vector(1 downto 0);
      mo_haddr    : in  std_logic_vector(31 downto 0);
      mo_hwrite   : in  std_ulogic;
      mo_hsize    : in  std_logic_vector(2 downto 0);
      mo_hburst   : in  std_logic_vector(2 downto 0);
      mo_hprot    : in  std_logic_vector(3 downto 0);
      mo_hwdata   : in  std_logic_vector(31 downto 0));
  end component top;

  component zynqmpsoc is
    port (
      peripheral_reset_0       : out std_logic_vector (0 to 0);
      pl_clk0                  : out std_logic;
      dip_switches_8bits_tri_i : in  std_logic_vector(7 downto 0);
      ddr_axi_awaddr           : in  std_logic_vector(ZYNQMP_DDR_AXI_ADDR_BITS - 1 downto 0);
      ddr_axi_awburst          : in  std_logic_vector(1 downto 0);
      ddr_axi_awcache          : in  std_logic_vector(3 downto 0);
      ddr_axi_awid             : in  std_logic_vector(5 downto 0);
      ddr_axi_awlen            : in  std_logic_vector(7 downto 0);
      ddr_axi_awlock           : in  std_logic;
      ddr_axi_awprot           : in  std_logic_vector(2 downto 0);
      ddr_axi_awqos            : in  std_logic_vector(3 downto 0);
      ddr_axi_awready          : out std_logic;
      ddr_axi_awsize           : in  std_logic_vector(2 downto 0);
      ddr_axi_awvalid          : in  std_logic;
      ddr_axi_wdata            : in  std_logic_vector(AXIDW - 1 downto 0);
      ddr_axi_wlast            : in  std_logic;
      ddr_axi_wready           : out std_logic;
      ddr_axi_wstrb            : in  std_logic_vector(AW - 1 downto 0);
      ddr_axi_wvalid           : in  std_logic;
      ddr_axi_bid              : out std_logic_vector(5 downto 0);
      ddr_axi_bready           : in  std_logic;
      ddr_axi_bresp            : out std_logic_vector(1 downto 0);
      ddr_axi_bvalid           : out std_logic;
      ddr_axi_araddr           : in  std_logic_vector(ZYNQMP_DDR_AXI_ADDR_BITS - 1 downto 0);
      ddr_axi_arburst          : in  std_logic_vector(1 downto 0);
      ddr_axi_arcache          : in  std_logic_vector(3 downto 0);
      ddr_axi_arid             : in  std_logic_vector(5 downto 0);
      ddr_axi_arlen            : in  std_logic_vector(7 downto 0);
      ddr_axi_arlock           : in  std_logic;
      ddr_axi_arprot           : in  std_logic_vector(2 downto 0);
      ddr_axi_arqos            : in  std_logic_vector(3 downto 0);
      ddr_axi_arready          : out std_logic;
      ddr_axi_arsize           : in  std_logic_vector(2 downto 0);
      ddr_axi_arvalid          : in  std_logic;
      ddr_axi_rdata            : out std_logic_vector(AXIDW - 1 downto 0);
      ddr_axi_rid              : out std_logic_vector(5 downto 0);
      ddr_axi_rlast            : out std_logic;
      ddr_axi_rready           : in  std_logic;
      ddr_axi_rresp            : out std_logic_vector(1 downto 0);
      ddr_axi_rvalid           : out std_logic;
      m_ahb_0_haddr            : out std_logic_vector (31 downto 0);
      m_ahb_0_hburst           : out std_logic_vector (2 downto 0);
      m_ahb_0_hmastlock        : out std_logic;
      m_ahb_0_hprot            : out std_logic_vector (3 downto 0);
      m_ahb_0_hrdata           : in  std_logic_vector (31 downto 0);
      m_ahb_0_hready           : in  std_logic;
      m_ahb_0_hresp            : in  std_logic;
      m_ahb_0_hsize            : out std_logic_vector (2 downto 0);
      m_ahb_0_htrans           : out std_logic_vector (1 downto 0);
      m_ahb_0_hwdata           : out std_logic_vector (31 downto 0);
      m_ahb_0_hwrite           : out std_logic);
  end component zynqmpsoc;

  -- Clock and reset
  signal reset       : std_ulogic;
  signal chip_refclk : std_ulogic;

  -- DDR AXI master interface
  signal ddr_axi_awid       : std_logic_vector(5 downto 0);
  signal ddr_axi_awaddr_top : std_logic_vector(GLOB_PHYS_ADDR_BITS - 1 downto 0);
  signal ddr_axi_awaddr     : std_logic_vector(ZYNQMP_DDR_AXI_ADDR_BITS - 1 downto 0);
  signal ddr_axi_awlen   : std_logic_vector(7 downto 0);
  signal ddr_axi_awsize  : std_logic_vector(2 downto 0);
  signal ddr_axi_awburst : std_logic_vector(1 downto 0);
  signal ddr_axi_awlock  : std_logic;
  signal ddr_axi_awcache : std_logic_vector(3 downto 0);
  signal ddr_axi_awprot  : std_logic_vector(2 downto 0);
  signal ddr_axi_awqos   : std_logic_vector(3 downto 0);
  signal ddr_axi_awvalid : std_logic;
  signal ddr_axi_awready : std_logic;
  signal ddr_axi_wdata   : std_logic_vector(AXIDW - 1 downto 0);
  signal ddr_axi_wstrb   : std_logic_vector(AW - 1 downto 0);
  signal ddr_axi_wlast   : std_logic;
  signal ddr_axi_wvalid  : std_logic;
  signal ddr_axi_wready  : std_logic;
  signal ddr_axi_bid     : std_logic_vector(5 downto 0);
  signal ddr_axi_bresp   : std_logic_vector(1 downto 0);
  signal ddr_axi_bvalid  : std_logic;
  signal ddr_axi_bready  : std_logic;
  signal ddr_axi_arid       : std_logic_vector(5 downto 0);
  signal ddr_axi_araddr_top : std_logic_vector(GLOB_PHYS_ADDR_BITS - 1 downto 0);
  signal ddr_axi_araddr     : std_logic_vector(ZYNQMP_DDR_AXI_ADDR_BITS - 1 downto 0);
  signal ddr_axi_arlen   : std_logic_vector(7 downto 0);
  signal ddr_axi_arsize  : std_logic_vector(2 downto 0);
  signal ddr_axi_arburst : std_logic_vector(1 downto 0);
  signal ddr_axi_arlock  : std_logic;
  signal ddr_axi_arcache : std_logic_vector(3 downto 0);
  signal ddr_axi_arprot  : std_logic_vector(2 downto 0);
  signal ddr_axi_arqos   : std_logic_vector(3 downto 0);
  signal ddr_axi_arvalid : std_logic;
  signal ddr_axi_arready : std_logic;
  signal ddr_axi_rid     : std_logic_vector(5 downto 0);
  signal ddr_axi_rdata   : std_logic_vector(AXIDW - 1 downto 0);
  signal ddr_axi_rresp   : std_logic_vector(1 downto 0);
  signal ddr_axi_rlast   : std_logic;
  signal ddr_axi_rvalid  : std_logic;
  signal ddr_axi_rready  : std_logic;

  -- AHB master inputs
  signal mi_hready : std_ulogic;                          -- transfer done
  signal mi_hresp  : std_logic_vector(1 downto 0);        -- response type
  signal mi_hrdata : std_logic_vector(31 downto 0);       -- read data bus

  -- AHB master outputs
  signal mo_hlock  : std_ulogic;                          -- lock request
  signal mo_htrans : std_logic_vector(1 downto 0);        -- transfer type
  signal mo_haddr  : std_logic_vector(31 downto 0);       -- address bus (byte)
  signal mo_hwrite : std_ulogic;                          -- read/write
  signal mo_hsize  : std_logic_vector(2 downto 0);        -- transfer size
  signal mo_hburst : std_logic_vector(2 downto 0);        -- burst type
  signal mo_hprot  : std_logic_vector(3 downto 0);        -- protection control
  signal mo_hwdata : std_logic_vector(31 downto 0);       -- write data bus

begin

  gen_ddr_addr_from_wide_top : if GLOB_PHYS_ADDR_BITS >= ZYNQMP_DDR_AXI_ADDR_BITS generate
    ddr_axi_awaddr <= ddr_axi_awaddr_top(ZYNQMP_DDR_AXI_ADDR_BITS - 1 downto 0);
    ddr_axi_araddr <= ddr_axi_araddr_top(ZYNQMP_DDR_AXI_ADDR_BITS - 1 downto 0);
  end generate gen_ddr_addr_from_wide_top;

  gen_ddr_addr_from_narrow_top : if GLOB_PHYS_ADDR_BITS < ZYNQMP_DDR_AXI_ADDR_BITS generate
    ddr_axi_awaddr(ZYNQMP_DDR_AXI_ADDR_BITS - 1 downto GLOB_PHYS_ADDR_BITS) <= (others => '0');
    ddr_axi_awaddr(GLOB_PHYS_ADDR_BITS - 1 downto 0) <= ddr_axi_awaddr_top;
    ddr_axi_araddr(ZYNQMP_DDR_AXI_ADDR_BITS - 1 downto GLOB_PHYS_ADDR_BITS) <= (others => '0');
    ddr_axi_araddr(GLOB_PHYS_ADDR_BITS - 1 downto 0) <= ddr_axi_araddr_top;
  end generate gen_ddr_addr_from_narrow_top;

  esptop_i : top
    generic map (
      simulation => false)
    port map (
      reset       => reset,
      chip_refclk => chip_refclk,
      uart_rxd    => uart_rxd,
      uart_txd    => uart_txd,
      uart_ctsn   => uart_ctsn,
      uart_rtsn   => uart_rtsn,
      led         => led,
      ddr_awid    => ddr_axi_awid,
      ddr_awaddr  => ddr_axi_awaddr_top,
      ddr_awlen   => ddr_axi_awlen,
      ddr_awsize  => ddr_axi_awsize,
      ddr_awburst => ddr_axi_awburst,
      ddr_awlock  => ddr_axi_awlock,
      ddr_awcache => ddr_axi_awcache,
      ddr_awprot  => ddr_axi_awprot,
      ddr_awqos   => ddr_axi_awqos,
      ddr_awvalid => ddr_axi_awvalid,
      ddr_awready => ddr_axi_awready,
      ddr_wdata   => ddr_axi_wdata,
      ddr_wstrb   => ddr_axi_wstrb,
      ddr_wlast   => ddr_axi_wlast,
      ddr_wvalid  => ddr_axi_wvalid,
      ddr_wready  => ddr_axi_wready,
      ddr_bid     => ddr_axi_bid,
      ddr_bresp   => ddr_axi_bresp,
      ddr_bvalid  => ddr_axi_bvalid,
      ddr_bready  => ddr_axi_bready,
      ddr_arid    => ddr_axi_arid,
      ddr_araddr  => ddr_axi_araddr_top,
      ddr_arlen   => ddr_axi_arlen,
      ddr_arsize  => ddr_axi_arsize,
      ddr_arburst => ddr_axi_arburst,
      ddr_arlock  => ddr_axi_arlock,
      ddr_arcache => ddr_axi_arcache,
      ddr_arprot  => ddr_axi_arprot,
      ddr_arqos   => ddr_axi_arqos,
      ddr_arvalid => ddr_axi_arvalid,
      ddr_arready => ddr_axi_arready,
      ddr_rid     => ddr_axi_rid,
      ddr_rdata   => ddr_axi_rdata,
      ddr_rresp   => ddr_axi_rresp,
      ddr_rlast   => ddr_axi_rlast,
      ddr_rvalid  => ddr_axi_rvalid,
      ddr_rready  => ddr_axi_rready,
      mi_hready   => mi_hready,
      mi_hresp    => mi_hresp,
      mi_hrdata   => mi_hrdata,
      mo_hlock    => mo_hlock,
      mo_htrans   => mo_htrans,
      mo_haddr    => mo_haddr,
      mo_hwrite   => mo_hwrite,
      mo_hsize    => mo_hsize,
      mo_hburst   => mo_hburst,
      mo_hprot    => mo_hprot,
      mo_hwdata   => mo_hwdata);

  zynqmpsoc_i : zynqmpsoc
    port map (
      peripheral_reset_0(0)      => reset,
      pl_clk0                    => chip_refclk,
      dip_switches_8bits_tri_i   => switch,
      ddr_axi_awaddr             => ddr_axi_awaddr,
      ddr_axi_awburst            => ddr_axi_awburst,
      ddr_axi_awcache            => ddr_axi_awcache,
      ddr_axi_awid               => ddr_axi_awid,
      ddr_axi_awlen              => ddr_axi_awlen,
      ddr_axi_awlock             => ddr_axi_awlock,
      ddr_axi_awprot             => ddr_axi_awprot,
      ddr_axi_awqos              => ddr_axi_awqos,
      ddr_axi_awready            => ddr_axi_awready,
      ddr_axi_awsize             => ddr_axi_awsize,
      ddr_axi_awvalid            => ddr_axi_awvalid,
      ddr_axi_wdata              => ddr_axi_wdata,
      ddr_axi_wlast              => ddr_axi_wlast,
      ddr_axi_wready             => ddr_axi_wready,
      ddr_axi_wstrb              => ddr_axi_wstrb,
      ddr_axi_wvalid             => ddr_axi_wvalid,
      ddr_axi_bid                => ddr_axi_bid,
      ddr_axi_bready             => ddr_axi_bready,
      ddr_axi_bresp              => ddr_axi_bresp,
      ddr_axi_bvalid             => ddr_axi_bvalid,
      ddr_axi_araddr             => ddr_axi_araddr,
      ddr_axi_arburst            => ddr_axi_arburst,
      ddr_axi_arcache            => ddr_axi_arcache,
      ddr_axi_arid               => ddr_axi_arid,
      ddr_axi_arlen              => ddr_axi_arlen,
      ddr_axi_arlock             => ddr_axi_arlock,
      ddr_axi_arprot             => ddr_axi_arprot,
      ddr_axi_arqos              => ddr_axi_arqos,
      ddr_axi_arready            => ddr_axi_arready,
      ddr_axi_arsize             => ddr_axi_arsize,
      ddr_axi_arvalid            => ddr_axi_arvalid,
      ddr_axi_rdata              => ddr_axi_rdata,
      ddr_axi_rid                => ddr_axi_rid,
      ddr_axi_rlast              => ddr_axi_rlast,
      ddr_axi_rready             => ddr_axi_rready,
      ddr_axi_rresp              => ddr_axi_rresp,
      ddr_axi_rvalid             => ddr_axi_rvalid,
      m_ahb_0_haddr              => mo_haddr,
      m_ahb_0_hburst             => mo_hburst,
      m_ahb_0_hmastlock          => mo_hlock,
      m_ahb_0_hprot              => mo_hprot,
      m_ahb_0_hrdata             => mi_hrdata,
      m_ahb_0_hready             => mi_hready,
      m_ahb_0_hresp              => mi_hresp(0),
      m_ahb_0_hsize              => mo_hsize,
      m_ahb_0_htrans             => mo_htrans,
      m_ahb_0_hwdata             => mo_hwdata,
      m_ahb_0_hwrite             => mo_hwrite);

end;
