-- Copyright (c) 2011-2026 Columbia University, System Level Design Group
-- SPDX-License-Identifier: Apache-2.0
------------------------------------------------------------------------------
--  ESP - xilinx - zcu102
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.grlib_config.all;
use work.amba.all;
use work.stdlib.all;
use work.devices.all;
use work.gencomp.all;
use work.misc.all;
use work.nocpackage.all;
use work.cachepackage.all;
use work.config.all;
use work.esp_global.all;
use work.socmap.all;
use work.tiles_pkg.all;

entity top is
  generic (
    SIMULATION : boolean := false
    );
  port (
    reset            : in    std_ulogic;
    chip_refclk      : in    std_ulogic;  -- ZYNQ MP PL clock (configured to 75MHz)
    uart_rxd         : in    std_ulogic;  -- UART1_RX (u1i.rxd)
    uart_txd         : out   std_ulogic;  -- UART1_TX (u1o.txd)
    uart_ctsn        : in    std_ulogic;  -- UART1_RTSN (u1i.ctsn)
    uart_rtsn        : out   std_ulogic;  -- UART1_RTSN (u1o.rtsn)
    led              : out   std_logic_vector(6 downto 0);
    -- DDR AXI master interface (ESP -> Zynq MP S_AXI_HPC0_FPD)
    ddr_awid         : out   std_logic_vector(5 downto 0);
    ddr_awaddr       : out   std_logic_vector(GLOB_PHYS_ADDR_BITS - 1 downto 0);
    ddr_awlen        : out   std_logic_vector(7 downto 0);
    ddr_awsize       : out   std_logic_vector(2 downto 0);
    ddr_awburst      : out   std_logic_vector(1 downto 0);
    ddr_awlock       : out   std_logic;
    ddr_awcache      : out   std_logic_vector(3 downto 0);
    ddr_awprot       : out   std_logic_vector(2 downto 0);
    ddr_awqos        : out   std_logic_vector(3 downto 0);
    ddr_awvalid      : out   std_logic;
    ddr_awready      : in    std_logic;
    ddr_wdata        : out   std_logic_vector(AXIDW - 1 downto 0);
    ddr_wstrb        : out   std_logic_vector(AW - 1 downto 0);
    ddr_wlast        : out   std_logic;
    ddr_wvalid       : out   std_logic;
    ddr_wready       : in    std_logic;
    ddr_bid          : in    std_logic_vector(5 downto 0);
    ddr_bresp        : in    std_logic_vector(1 downto 0);
    ddr_bvalid       : in    std_logic;
    ddr_bready       : out   std_logic;
    ddr_arid         : out   std_logic_vector(5 downto 0);
    ddr_araddr       : out   std_logic_vector(GLOB_PHYS_ADDR_BITS - 1 downto 0);
    ddr_arlen        : out   std_logic_vector(7 downto 0);
    ddr_arsize       : out   std_logic_vector(2 downto 0);
    ddr_arburst      : out   std_logic_vector(1 downto 0);
    ddr_arlock       : out   std_logic;
    ddr_arcache      : out   std_logic_vector(3 downto 0);
    ddr_arprot       : out   std_logic_vector(2 downto 0);
    ddr_arqos        : out   std_logic_vector(3 downto 0);
    ddr_arvalid      : out   std_logic;
    ddr_arready      : in    std_logic;
    ddr_rid          : in    std_logic_vector(5 downto 0);
    ddr_rdata        : in    std_logic_vector(AXIDW - 1 downto 0);
    ddr_rresp        : in    std_logic_vector(1 downto 0);
    ddr_rlast        : in    std_logic;
    ddr_rvalid       : in    std_logic;
    ddr_rready       : out   std_logic;
    -- AHB master inputs
    mi_hready        : out   std_ulogic;  -- transfer done
    mi_hresp         : out   std_logic_vector(1 downto 0);  -- response type
    mi_hrdata        : out   std_logic_vector(31 downto 0);  -- read data bus
    -- AHB master outputs
    mo_hlock         : in    std_ulogic;  -- lock request
    mo_htrans        : in    std_logic_vector(1 downto 0);  -- transfer type
    mo_haddr         : in    std_logic_vector(31 downto 0);  -- address bus (byte)
    mo_hwrite        : in    std_ulogic;  -- read/write
    mo_hsize         : in    std_logic_vector(2 downto 0);  -- transfer size
    mo_hburst        : in    std_logic_vector(2 downto 0);  -- burst type
    mo_hprot         : in    std_logic_vector(3 downto 0);  -- protection control
    mo_hwdata        : in    std_logic_vector(31 downto 0)  -- write data bus
    );
end top;


architecture rtl of top is

constant CPU_FREQ : integer := 75000;  -- cpu frequency in KHz

  -- clock and reset
  signal rstn      : std_ulogic;
  signal lock  : std_ulogic;

  -- Memory controller DDR4
  signal ddr_axi_si        : axi_mosi_vector(0 to MEM_ID_RANGE_MSB);
  signal ddr_axi_so        : axi_somi_vector(0 to MEM_ID_RANGE_MSB);

  -- UART
  signal uart_rxd_int  : std_logic;       -- UART1_RX (u1i.rxd)
  signal uart_txd_int  : std_logic;       -- UART1_TX (u1o.txd)
  signal uart_ctsn_int : std_logic;       -- UART1_RTSN (u1i.ctsn)
  signal uart_rtsn_int : std_logic;       -- UART1_RTSN (u1o.rtsn)

  -- DVI (unused on this board)
  signal dvi_apbi  : apb_slv_in_type;
  signal dvi_apbo  : apb_slv_out_type;
  signal dvi_ahbmi : ahb_mst_in_type;
  signal dvi_ahbmo : ahb_mst_out_type;

  -- Ethernet (unused on this board)
  signal eth0_apbi   : apb_slv_in_type;
  signal eth0_apbo   : apb_slv_out_type;
  signal sgmii0_apbi : apb_slv_in_type;
  signal sgmii0_apbo : apb_slv_out_type;
  signal eth0_ahbmi  : ahb_mst_in_type;
  signal eth0_ahbmo  : ahb_mst_out_type;
  signal edcl_ahbmo  : ahb_mst_out_type;

  -- CPU flags
  signal cpuerr : std_ulogic;

  -- NOC
  signal sys_clk        : std_logic_vector(0 to 0);

  attribute keep                    : boolean;
  attribute syn_keep                : string;
  attribute keep of chip_refclk     : signal is true;
  attribute syn_keep of chip_refclk : signal is "true";

  constant edcl_hconfig : ahb_config_type := (
    0      => ahb_device_reg (VENDOR_GAISLER, GAISLER_EDCLMST, 0, 0, 0),
    others => zero32);

begin

  ----------------------------------------------------------------------
  --- FPGA Reset and Clock generation  ---------------------------------
  ----------------------------------------------------------------------

  rst0      : rstgen                    -- reset generator
    generic map (acthigh => 1, syncin => 0)
    port map (reset, chip_refclk, lock, rstn, open);
  lock <= '1';

  -----------------------------------------------------------------------------
  -- LEDs
  -----------------------------------------------------------------------------

  -- From CPU 0
  led0_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x33v)
    port map (led(0), cpuerr);
  --pragma translate_off
  process(chip_refclk, rstn)
  begin  -- process
    if rstn = '1' then
      assert cpuerr = '0' report "Program Completed!" severity failure;
    end if;
  end process;
  --pragma translate_on

  -- From DDR controller (on FPGA)
  led2_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x33v)
    port map (led(2), '0');
  led3_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x33v)
    port map (led(3), '0');
  led4_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x33v)
    port map (led(4), ddr_axi_so(0).ar.ready);

  -- unused
  led1_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x33v)
    port map (led(1), '0');
  led5_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x33v)
    port map (led(5), '0');
  led6_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x33v)
    port map (led(6), '0');


  -----------------------------------------------------------------------------
  -- UART pads
  -----------------------------------------------------------------------------

  uart_rxd_pad   : inpad  generic map (level => cmos, voltage => x33v, tech => CFG_FABTECH) port map (uart_rxd, uart_rxd_int);
  uart_txd_pad   : outpad generic map (level => cmos, voltage => x33v, tech => CFG_FABTECH) port map (uart_txd, uart_txd_int);
  uart_ctsn_pad : inpad  generic map (level => cmos, voltage => x33v, tech => CFG_FABTECH) port map (uart_ctsn, uart_ctsn_int);
  uart_rtsn_pad : outpad generic map (level => cmos, voltage => x33v, tech => CFG_FABTECH) port map (uart_rtsn, uart_rtsn_int);

  ----------------------------------------------------------------------
  --- PS-side DDR4 interface wired directly to the ESP AXI memory port
  ----------------------------------------------------------------------
  gen_ddr_addr_msb : if GLOB_PHYS_ADDR_BITS > 32 generate
    ddr_awaddr(GLOB_PHYS_ADDR_BITS - 1 downto 32) <= (others => '0');
    ddr_araddr(GLOB_PHYS_ADDR_BITS - 1 downto 32) <= (others => '0');
  end generate gen_ddr_addr_msb;

  ddr_awid                  <= ddr_axi_si(0).aw.id(5 downto 0);
  -- Preserve ESP's 1 GiB DDR ABI while targeting the Zynq Linux no-map carveout
  -- at PS DDR_LOW 0x20000000-0x5fffffff.
  ddr_awaddr(31)            <= '0';
  ddr_awaddr(30)            <= ddr_axi_si(0).aw.addr(29);
  ddr_awaddr(29)            <= not ddr_axi_si(0).aw.addr(29);
  ddr_awaddr(28 downto 0)   <= ddr_axi_si(0).aw.addr(28 downto 0);
  ddr_awlen                 <= ddr_axi_si(0).aw.len;
  ddr_awsize                <= ddr_axi_si(0).aw.size;
  ddr_awburst               <= ddr_axi_si(0).aw.burst;
  ddr_awlock                <= ddr_axi_si(0).aw.lock;
  ddr_awcache               <= ddr_axi_si(0).aw.cache;
  ddr_awprot                <= "011";
  ddr_awqos                 <= ddr_axi_si(0).aw.qos;
  ddr_awvalid               <= ddr_axi_si(0).aw.valid;
  ddr_wdata                 <= ddr_axi_si(0).w.data;
  ddr_wstrb                 <= ddr_axi_si(0).w.strb;
  ddr_wlast                 <= ddr_axi_si(0).w.last;
  ddr_wvalid                <= ddr_axi_si(0).w.valid;
  ddr_bready                <= ddr_axi_si(0).b.ready;
  ddr_arid                  <= ddr_axi_si(0).ar.id(5 downto 0);
  ddr_araddr(31)            <= '0';
  ddr_araddr(30)            <= ddr_axi_si(0).ar.addr(29);
  ddr_araddr(29)            <= not ddr_axi_si(0).ar.addr(29);
  ddr_araddr(28 downto 0)   <= ddr_axi_si(0).ar.addr(28 downto 0);
  ddr_arlen                 <= ddr_axi_si(0).ar.len;
  ddr_arsize                <= ddr_axi_si(0).ar.size;
  ddr_arburst               <= ddr_axi_si(0).ar.burst;
  ddr_arlock                <= ddr_axi_si(0).ar.lock;
  ddr_arcache               <= ddr_axi_si(0).ar.cache;
  ddr_arprot                <= "011";
  ddr_arqos                 <= ddr_axi_si(0).ar.qos;
  ddr_arvalid               <= ddr_axi_si(0).ar.valid;
  ddr_rready                <= ddr_axi_si(0).r.ready;

  ddr_axi_so(0).aw.ready    <= ddr_awready;
  ddr_axi_so(0).w.ready     <= ddr_wready;
  ddr_axi_so(0).b.id(5 downto 0) <= ddr_bid;
  ddr_axi_so(0).b.id(XID_WIDTH - 1 downto 6) <= (others => '0');
  ddr_axi_so(0).b.resp      <= ddr_bresp;
  ddr_axi_so(0).b.user      <= (others => '0');
  ddr_axi_so(0).b.valid     <= ddr_bvalid;
  ddr_axi_so(0).ar.ready    <= ddr_arready;
  ddr_axi_so(0).r.id(5 downto 0) <= ddr_rid;
  ddr_axi_so(0).r.id(XID_WIDTH - 1 downto 6) <= (others => '0');
  ddr_axi_so(0).r.data      <= ddr_rdata;
  ddr_axi_so(0).r.resp      <= ddr_rresp;
  ddr_axi_so(0).r.last      <= ddr_rlast;
  ddr_axi_so(0).r.user      <= (others => '0');
  ddr_axi_so(0).r.valid     <= ddr_rvalid;

  -----------------------------------------------------------------------------
  -- Host interface through Xilinx AXI-to-AHB-L adapter
  -----------------------------------------------------------------------------
  edcl_ahbmo.hbusreq <= '0' when edcl_ahbmo.htrans = HTRANS_IDLE else '1';
  edcl_ahbmo.hlock   <= mo_hlock;
  edcl_ahbmo.htrans  <= mo_htrans;
  edcl_ahbmo.haddr   <= mo_haddr;
  edcl_ahbmo.hwrite  <= mo_hwrite;
  edcl_ahbmo.hsize   <= mo_hsize;
  edcl_ahbmo.hburst  <= mo_hburst;
  edcl_ahbmo.hprot   <= mo_hprot;
  edcl_ahbmo.hwdata  <= ahbdrivedata(mo_hwdata);
  edcl_ahbmo.hirq    <= (others => '0');
  edcl_ahbmo.hconfig <= edcl_hconfig;
  edcl_ahbmo.hindex  <= 1;

  mi_hready <= eth0_ahbmi.hready;
  mi_hresp  <= eth0_ahbmi.hresp;
  mi_hrdata <= eth0_ahbmi.hrdata(31 downto 0);

  -----------------------------------------------------------------------
  ---  ETHERNET ---------------------------------------------------------
  -----------------------------------------------------------------------

  eth0_apbo   <= apb_none;
  sgmii0_apbo <= apb_none;
  eth0_ahbmo  <= ahbm_none;

  ------------------------------------------------------------------------
  -- CHIP
  ------------------------------------------------------------------------
  sys_clk(0)     <= chip_refclk;

  esp_1 : esp
    generic map (
      SIMULATION => SIMULATION)
    port map (
      rst         => rstn,
      sys_clk     => sys_clk(0 to MEM_ID_RANGE_MSB),
      refclk      => chip_refclk,
      uart_rxd    => uart_rxd_int,
      uart_txd    => uart_txd_int,
      uart_ctsn   => uart_ctsn_int,
      uart_rtsn   => uart_rtsn_int,
      cpuerr      => cpuerr,
      ddr_axi_si  => ddr_axi_si,
      ddr_axi_so  => ddr_axi_so,
      eth0_ahbmi  => eth0_ahbmi,
      eth0_ahbmo  => eth0_ahbmo,
      edcl_ahbmo  => edcl_ahbmo,
      eth0_apbi   => eth0_apbi,
      eth0_apbo   => eth0_apbo,
      sgmii0_apbi => sgmii0_apbi,
      sgmii0_apbo => sgmii0_apbo,
      dvi_apbi    => dvi_apbi,
      dvi_apbo    => dvi_apbo,
      dvi_ahbmi   => dvi_ahbmi,
      dvi_ahbmo   => dvi_ahbmo);

end;
