------------------------------------------------------------------------------
--  ESP - xilinx - vc707
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

use work.grlib_config.all;
use work.amba.all;
use work.stdlib.all;
use work.devices.all;
use work.gencomp.all;
use work.leon3.all;
use work.uart.all;
use work.misc.all;
use work.net.all;
use work.svga_pkg.all;
library unisim;
-- pragma translate_off
use work.sim.all;
-- pragma translate_on
use unisim.VCOMPONENTS.all;
use work.monitor_pkg.all;
use work.sldacc.all;
use work.tile.all;
use work.nocpackage.all;
use work.cachepackage.all;
use work.coretypes.all;
use work.config.all;
use work.esp_global.all;
use work.socmap.all;
use work.tiles_pkg.all;
use work.axi2mig_pkg.all;

entity top is
  generic (
    SIMULATION          : boolean := false
  );
  port (
    reset           : in    std_ulogic;
    sys_clk_p       : in    std_ulogic;  -- 200 MHz clock
    sys_clk_n       : in    std_ulogic;  -- 200 MHz clock
    ddr3_dq         : inout std_logic_vector(63 downto 0);
    ddr3_dqs_p      : inout std_logic_vector(7 downto 0);
    ddr3_dqs_n      : inout std_logic_vector(7 downto 0);
    ddr3_addr       : out   std_logic_vector(13 downto 0);
    ddr3_ba         : out   std_logic_vector(2 downto 0);
    ddr3_ras_n      : out   std_logic;
    ddr3_cas_n      : out   std_logic;
    ddr3_we_n       : out   std_logic;
    ddr3_reset_n    : out   std_logic;
    ddr3_ck_p       : out   std_logic_vector(0 downto 0);
    ddr3_ck_n       : out   std_logic_vector(0 downto 0);
    ddr3_cke        : out   std_logic_vector(0 downto 0);
    ddr3_cs_n       : out   std_logic_vector(0 downto 0);
    ddr3_dm         : out   std_logic_vector(7 downto 0);
    ddr3_odt        : out   std_logic_vector(0 downto 0);
    gtrefclk_p      : in    std_logic;
    gtrefclk_n      : in    std_logic;
    txp             : out   std_logic;
    txn             : out   std_logic;
    rxp             : in    std_logic;
    rxn             : in    std_logic;
    -- SFP+ cage (P3), carrying the ESP I/O link over Aurora 64B/66B.
    -- Distinct from txp/txn/rxp/rxn above, which are SGMII to the RJ45 PHY.
    sfp_txp         : out   std_logic;
    sfp_txn         : out   std_logic;
    sfp_rxp         : in    std_logic;
    sfp_rxn         : in    std_logic;
    -- SFP+ module control. Per UG885 Table 1-15/1-16 these ARE FPGA pins:
    -- TX_DISABLE on AP33 (active high -- the module will not transmit unless
    -- it is driven low) and LOS on BB38 (active high -- no optical signal
    -- being received). Previously unconstrained, which left TX_DISABLE relying
    -- on Vivado's default pulldown for unused pins rather than on intent.
    sfp_tx_disable  : out   std_logic;
    sfp_los         : in    std_logic;
    emdio           : inout std_logic;
    emdc            : out   std_ulogic;
    eint            : in    std_ulogic;
    erst            : out   std_ulogic;
    uart_rxd        : in    std_ulogic;  -- UART1_RX (u1i.rxd)
    uart_txd        : out   std_ulogic;  -- UART1_TX (u1o.txd)
    uart_ctsn       : in    std_ulogic;  -- UART1_RTSN (u1i.ctsn)
    uart_rtsn       : out   std_ulogic;  -- UART1_RTSN (u1o.rtsn)
    button          : in    std_logic_vector(3 downto 0);
    switch          : inout std_logic_vector(4 downto 0);
    led             : out   std_logic_vector(6 downto 0));
end;


architecture rtl of top is

component sgmii_vc707
  generic(
    pindex          : integer := 0;
    paddr           : integer := 0;
    pmask           : integer := 16#fff#;
    abits           : integer := 8;
    autonegotiation : integer := 1;
    pirq            : integer := 0;
    debugmem        : integer := 0;
    tech            : integer := 0;
    simulation      : boolean := false
  );
  port(
    sgmiii    :  in  eth_sgmii_in_type;
    sgmiio    :  out eth_sgmii_out_type;
    gmiii     : out   eth_in_type;
    gmiio     : in    eth_out_type;
    reset     : in    std_logic;                     -- Asynchronous reset for entire core.
    apb_clk   : in    std_logic;
    apb_rstn  : in    std_logic;
    apbi      : in    apb_slv_in_type;
    apbo      : out   apb_slv_out_type;
    gtrefclk_out : out std_logic
  );
end component;

-- Aurora 64B/66B core generated from constraints/<board>/aurora.tcl.
-- SupportLevel 1, so the core owns the MMCM/BUFGs/QPLL and SOURCES user_clk
-- as user_clk_out. SINGLEEND_GTREFCLK/INITCLK make refclk1_in and init_clk
-- single-ended, which is what lets it share the SGMII reference buffer and
-- take ESP's internal 50 MHz.
component aurora
  port (
    rxp                     : in  std_logic_vector(0 downto 0);
    rxn                     : in  std_logic_vector(0 downto 0);
    refclk1_in              : in  std_logic;
    reset_pb                : in  std_logic;
    power_down              : in  std_logic;
    pma_init                : in  std_logic;
    loopback                : in  std_logic_vector(2 downto 0);
    txp                     : out std_logic_vector(0 downto 0);
    txn                     : out std_logic_vector(0 downto 0);
    hard_err                : out std_logic;
    soft_err                : out std_logic;
    channel_up              : out std_logic;
    lane_up                 : out std_logic_vector(0 downto 0);
    tx_out_clk              : out std_logic;
    drp_clk_in              : in  std_logic;
    gt_pll_lock             : out std_logic;
    s_axi_tx_tdata          : in  std_logic_vector(0 to 63);
    s_axi_tx_tvalid         : in  std_logic;
    s_axi_tx_tready         : out std_logic;
    m_axi_rx_tdata          : out std_logic_vector(0 to 63);
    m_axi_rx_tvalid         : out std_logic;
    mmcm_not_locked_out     : out std_logic;
    drpaddr_in              : in  std_logic_vector(8 downto 0);
    drpdi_in                : in  std_logic_vector(15 downto 0);
    drprdy_out              : out std_logic;
    drpen_in                : in  std_logic;
    drpwe_in                : in  std_logic;
    drpdo_out               : out std_logic_vector(15 downto 0);
    init_clk                : in  std_logic;
    link_reset_out          : out std_logic;
    user_clk_out            : out std_logic;
    sync_clk_out            : out std_logic;
    gt_qpllclk_quad1_out    : out std_logic;
    gt_qpllrefclk_quad1_out : out std_logic;
    gt_rxcdrovrden_in       : in  std_logic;
    sys_reset_out           : out std_logic;
    gt_reset_out            : out std_logic
  );
end component;

component iolink_phy_aurora
  generic (
    io_bitwidth   : integer range 1 to 16 := 16;
    tx_fifo_depth : integer range 4 to 256 := 32);
  port (
    user_clk      : in  std_ulogic;
    user_rstn     : in  std_ulogic;
    channel_up    : in  std_ulogic;
    lane_up       : in  std_ulogic;
    hard_err      : in  std_ulogic;
    soft_err      : in  std_ulogic;
    tx_tdata      : out std_logic_vector(63 downto 0);
    tx_tvalid     : out std_ulogic;
    tx_tready     : in  std_ulogic;
    rx_tdata      : in  std_logic_vector(63 downto 0);
    rx_tvalid     : in  std_ulogic;
    io_clk_out    : out std_ulogic;
    io_clk_in     : in  std_ulogic;
    io_valid_out  : out std_ulogic;
    io_credit_out : out std_ulogic;
    io_data_out   : out std_logic_vector(io_bitwidth - 1 downto 0);
    io_valid_in   : in  std_ulogic;
    io_credit_in  : in  std_ulogic;
    io_data_in    : in  std_logic_vector(io_bitwidth - 1 downto 0);
    link_ready    : out std_ulogic;
    tx_overflow   : out std_ulogic;
    rx_sync_err   : out std_ulogic);
end component;

function fix_endian (
le : std_logic_vector((MEM_AXIDW/8) - 1 downto 0))
return std_logic_vector is
variable be : std_logic_vector((MEM_AXIDW/8) - 1 downto 0);
begin
if GLOB_CPU_RISCV = 0 then
  be := le;
else
  for i in 0 to (MEM_AXIDW/8) - 1 loop
	be(i) := le(MEM_AXIDW/8 - (i + 1));
  end loop;  -- i
end if;
return be;
end fix_endian;

-- constants
signal vcc, gnd   : std_logic_vector(31 downto 0);

-- Switches
signal sel0, sel1, sel2, sel3, sel4 : std_ulogic;

-- clock and reset
signal clkm : std_ulogic := '0';
signal rstn, rstraw : std_ulogic;
signal cgi : clkgen_in_type;
signal cgo : clkgen_out_type;
signal lock, calib_done, rst : std_ulogic;
signal clkref  : std_logic;
signal migrstn : std_logic;

-- Memory controller DDR3
signal ddr_axi_si   : axi_mosi_vector(0 to MEM_ID_RANGE_MSB);
signal ddr_axi_so   : axi_somi_vector(0 to MEM_ID_RANGE_MSB);

-- UART
signal uart_rxd_int  : std_logic;       -- UART1_RX (u1i.rxd)
signal uart_txd_int  : std_logic;       -- UART1_TX (u1o.txd)
signal uart_ctsn_int : std_logic;       -- UART1_RTSN (u1i.ctsn)
signal uart_rtsn_int : std_logic;       -- UART1_RTSN (u1o.rtsn)

-- Memory controller DDR3

-- DVI (unused on this board)
signal dvi_apbi  : apb_slv_in_type;
signal dvi_apbo  : apb_slv_out_type;
signal dvi_ahbmi : ahb_mst_in_type;
signal dvi_ahbmo : ahb_mst_out_type;

-- Ethernet
signal gmiii : eth_in_type;
signal gmiio : eth_out_type;
signal sgmiii :  eth_sgmii_in_type;
signal sgmiio :  eth_sgmii_out_type;
signal sgmiirst : std_logic;

-- I/O link over Aurora
signal gtrefclk_buf       : std_logic;
signal iolink_data_in     : std_logic_vector(CFG_IOLINK_BITS - 1 downto 0);
signal iolink_data_out    : std_logic_vector(CFG_IOLINK_BITS - 1 downto 0);
signal iolink_valid_in    : std_ulogic;
signal iolink_valid_out   : std_ulogic;
signal iolink_clk_in      : std_ulogic;
signal iolink_clk_out     : std_ulogic;
signal iolink_credit_in   : std_ulogic;
signal iolink_credit_out  : std_ulogic;
signal aurora_user_clk    : std_ulogic;
signal aurora_user_rstn   : std_ulogic;
-- Aurora's resets are active high. Kept as a signal rather than written as
-- "not rstn" inline: an operator expression as a port map actual is not legal
-- VHDL-93, and this file is also compiled by the ModelSim/Xcelium flows.
signal aurora_reset       : std_ulogic;
-- Aurora's serial ports are 1-bit vectors. Driven through signals rather than
-- aggregates like "(0 => sfp_rxp)" inline, which is not a globally static
-- expression and so is not a legal port map actual.
signal aurora_rxp         : std_logic_vector(0 downto 0);
signal aurora_rxn         : std_logic_vector(0 downto 0);
signal aurora_txp         : std_logic_vector(0 downto 0);
signal aurora_txn         : std_logic_vector(0 downto 0);
signal aurora_sys_reset   : std_logic;
signal aurora_channel_up  : std_logic;
signal aurora_lane_up     : std_logic_vector(0 downto 0);
signal aurora_hard_err    : std_logic;
signal aurora_soft_err    : std_logic;
signal aurora_tx_tdata    : std_logic_vector(63 downto 0);
signal aurora_tx_tvalid   : std_ulogic;
signal aurora_tx_tready   : std_logic;
signal aurora_rx_tdata    : std_logic_vector(63 downto 0);
signal aurora_rx_tvalid   : std_logic;
signal iolink_link_ready  : std_ulogic;
-- What the I/O link status LEDs show. Driven from either generate below so the
-- LEDs read '0' when the link is not built.
signal iolink_led_link    : std_ulogic;
signal iolink_led_aux     : std_ulogic;
signal iolink_led_err     : std_ulogic;
signal aurora_loopback    : std_logic_vector(2 downto 0);
signal sfp_txdis_int      : std_ulogic;
signal sfp_los_int        : std_ulogic;
signal iolink_tx_overflow : std_ulogic;
signal iolink_rx_sync_err : std_ulogic;
signal ethernet_phy_int : std_logic;
signal rxd1 : std_logic;
signal txd1 : std_logic;
signal ethi : eth_in_type;
signal etho : eth_out_type;
signal egtx_clk :std_ulogic;
signal negtx_clk :std_ulogic;
constant CPU_FREQ : integer := 50000;  -- cpu frequency in KHz
signal eth0_apbi : apb_slv_in_type;
signal eth0_apbo : apb_slv_out_type;
signal sgmii0_apbi : apb_slv_in_type;
signal sgmii0_apbo : apb_slv_out_type;
signal eth0_ahbmi : ahb_mst_in_type;
signal eth0_ahbmo : ahb_mst_out_type;
signal edcl_ahbmo : ahb_mst_out_type;

-- CPU flags
signal cpuerr : std_ulogic;

-- NOC
signal chip_rst : std_ulogic;
signal sys_clk : std_logic_vector(0 to 0);
signal chip_refclk : std_ulogic := '0';

attribute keep : boolean;
attribute syn_keep : string;
attribute keep of clkm : signal is true;
attribute keep of chip_refclk : signal is true;
attribute syn_keep of clkm : signal is "true";
attribute syn_keep of chip_refclk : signal is "true";

begin

-------------------------------------------------------------------------------
-- Leds -----------------------------------------------------------------------
-------------------------------------------------------------------------------

  -- From CPU 0
  led0_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (led(0), cpuerr);
  --pragma translate_off
  process(clkm, rstn)
  begin  -- process
    if rstn = '1' then
      assert cpuerr = '0' report "Program Completed!" severity failure;
    end if;
  end process;
  --pragma translate_on

  -- From DDR controller (on FPGA)
  led2_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (led(2), calib_done);
  led3_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (led(3), lock);
  led4_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (led(4), ddr_axi_so(0).ar.ready);

  -- I/O link status, so SFP bring-up can be read off the board without JTAG.
  --
  -- led(1) is Aurora channel_up. led(5) and led(6) depend on DIP switch
  -- switch(1), selected in iolink_aurora_gen below:
  --   switch(1) off (bring-up)   led(5) = lane_up      led(6) = SFP LOS
  --   switch(1) on  (integrity)  led(5) = tx_overflow  led(6) = rx_sync_err
  -- tx_overflow and rx_sync_err are the PHY's STICKY error bits: once lit they
  -- stay lit until reset, and either one means a beat was dropped. On a good
  -- link led(1) is solid and, in the integrity view, both error LEDs are dark.
  --
  -- All three read '0' when the link is not built, as they did before: they
  -- were spare.
  led1_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (led(1), iolink_led_link);
  led5_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (led(5), iolink_led_aux);
  led6_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (led(6), iolink_led_err);

  -- SFP+ module control pins.
  sfp_txdis_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (sfp_tx_disable, sfp_txdis_int);
  sfp_los_pad : inpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (sfp_los, sfp_los_int);

-------------------------------------------------------------------------------
-- Switches -------------------------------------------------------------------
-------------------------------------------------------------------------------

  sw0_pad : iopad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (switch(0), '0', '1', sel0);
  sw1_pad : iopad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (switch(1), '0', '1', sel1);
  sw2_pad : iopad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (switch(2), '0', '1', sel2);
  sw3_pad : iopad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (switch(3), '0', '1', sel3);
  sw4_pad : iopad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
    port map (switch(4), '0', '1', sel4);

-------------------------------------------------------------------------------
-- Buttons --------------------------------------------------------------------
-------------------------------------------------------------------------------

  --pio_pad : inpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
  --  port map (button(i-4), gpioi.din(i));

----------------------------------------------------------------------
--- FPGA Reset and Clock generation  ---------------------------------
----------------------------------------------------------------------

  vcc <= (others => '1'); gnd <= (others => '0');
  cgi.pllctrl <= "00"; cgi.pllrst <= rstraw;

  reset_pad : inpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v) port map (reset, rst);
  rst0 : rstgen         -- reset generator
  generic map (acthigh => 1, syncin => 0)
  port map (rst, clkm, lock, rstn, rstraw);
  lock <= calib_done and cgo.clklock;

  rst1 : rstgen         -- reset generator
  generic map (acthigh => 1)
  port map (rst, clkm, lock, migrstn, open);


-----------------------------------------------------------------------------
-- UART pads
-----------------------------------------------------------------------------

  uart_rxd_pad   : inpad  generic map (level => cmos, voltage => x18v, tech => CFG_FABTECH) port map (uart_rxd, uart_rxd_int);
  uart_txd_pad   : outpad generic map (level => cmos, voltage => x18v, tech => CFG_FABTECH) port map (uart_txd, uart_txd_int);
  uart_ctsn_pad : inpad  generic map (level => cmos, voltage => x18v, tech => CFG_FABTECH) port map (uart_ctsn, uart_ctsn_int);
  uart_rtsn_pad : outpad generic map (level => cmos, voltage => x18v, tech => CFG_FABTECH) port map (uart_rtsn, uart_rtsn_int);

----------------------------------------------------------------------
---  DDR3 memory controller ------------------------------------------
----------------------------------------------------------------------

  clkgenmigref0 : clkgen
    generic map (CFG_FABTECH, 16, 32, 0, 0, 0, 0, 0, 100000)
    port map (clkm, clkm, chip_refclk, open, clkref, open, open, cgi, cgo, open, open, open);

    gen_mig : if (SIMULATION /= true) generate
        ddrc : axi2mig_7series
      generic map (
        AXIDW => MEM_AXIDW
	  )
      port map(
        ddr3_dq         => ddr3_dq,
        ddr3_dqs_p      => ddr3_dqs_p,
        ddr3_dqs_n      => ddr3_dqs_n,
        ddr3_addr       => ddr3_addr,
        ddr3_ba         => ddr3_ba,
        ddr3_ras_n      => ddr3_ras_n,
        ddr3_cas_n      => ddr3_cas_n,
        ddr3_we_n       => ddr3_we_n,
        ddr3_reset_n    => ddr3_reset_n,
        ddr3_ck_p       => ddr3_ck_p,
        ddr3_ck_n       => ddr3_ck_n,
        ddr3_cke        => ddr3_cke,
        ddr3_cs_n       => ddr3_cs_n,
        ddr3_dm         => ddr3_dm,
        ddr3_odt        => ddr3_odt,
		calib_done     	=> calib_done,
		rst_n_syn      	=> migrstn,
		rst_n_async     => rstraw,
        sys_clk_p       => sys_clk_p,
        sys_clk_n       => sys_clk_n,
        clk_ref_i       => clkref,
        ui_clk          => clkm,
        ui_clk_sync_rst => open,
        ddr_axi_si      => ddr_axi_si(0),
    	ddr_axi_so      => ddr_axi_so(0)
        );

  end generate gen_mig;

  gen_mig_model : if (SIMULATION = true) generate
    -- pragma translate_off
 
	mig_axiram : axi_ram_sim
      generic map (
        kbytes            => 2 * 1024,
        DATA_WIDTH        => MEM_AXIDW,
        ADDR_WIDTH        => GLOB_PHYS_ADDR_BITS,
        STRB_WIDTH        => AW,
        ID_WIDTH          => 8,
        PIPELINE_OUTPUT   => 0
        )
      port map(
        rst   => rstn,
        clk   => clkm,
		ddr_axi_si	=> ddr_axi_si(0),
        ddr_axi_so	=> ddr_axi_so(0)
        );

    ddr3_dq           <= (others => 'Z');
    ddr3_dqs_p        <= (others => 'Z');
    ddr3_dqs_n        <= (others => 'Z');
    ddr3_addr         <= (others => '0');
    ddr3_ba           <= (others => '0');
    ddr3_ras_n        <= '0';
    ddr3_cas_n        <= '0';
    ddr3_we_n         <= '0';
    ddr3_reset_n      <= '1';
    ddr3_ck_p         <= (others => '0');
    ddr3_ck_n         <= (others => '0');
    ddr3_cke          <= (others => '0');
    ddr3_cs_n         <= (others => '0');
    ddr3_dm           <= (others => '0');
    ddr3_odt          <= (others => '0');

    calib_done <= '1';
    clkm <= not clkm after 5.0 ns;

    -- pragma translate_on
  end generate gen_mig_model;

-----------------------------------------------------------------------
---  ETHERNET ---------------------------------------------------------
-----------------------------------------------------------------------

  eth0 : if SIMULATION = false and CFG_GRETH = 1 generate -- Gaisler ethernet MAC
    e1 : grethm
      generic map(
        hindex => CFG_AHB_JTAG,
        ehindex => CFG_AHB_JTAG + 1,
        pindex => 6,
        paddr => 16#800#,
        pmask => 16#f00#,
        pirq => 12,
        memtech => CFG_FABTECH,
        little_end  => GLOB_CPU_RISCV * CFG_L2_DISABLE,
        rmii => 0,
        enable_mdio => 1,
        fifosize => CFG_ETH_FIFO,
        nsync => 2,
        edcl => CFG_DSU_ETH,
        edclbufsz => CFG_ETH_BUF,
        phyrstadr => 7,
        macaddrh => CFG_ETH_ENM,
        macaddrl => CFG_ETH_ENL,
        enable_mdint => 1,
        ipaddrh => CFG_ETH_IPM,
        ipaddrl => CFG_ETH_IPL,
        giga => CFG_GRETH1G,
        ramdebug => 0,
        gmiimode => 1,
        edclsepahbg => 1)
      port map(
        rst => rstn,
        clk => chip_refclk,
        mdcscaler => CPU_FREQ/1000,
        ahbmi => eth0_ahbmi,
        ahbmo => eth0_ahbmo,
        eahbmo => edcl_ahbmo,
        apbi => eth0_apbi,
        apbo => eth0_apbo,
        ethi => gmiii,
        etho => gmiio);

    sgmiirst <= not rstraw;

    sgmii0 : sgmii_vc707
      generic map(
        pindex          => 7,
        paddr           => 16#010#,
        pmask           => 16#ff0#,
        abits           => 8,
        autonegotiation => 1,
        pirq            => 11,
        debugmem        => 1,
        tech            => CFG_FABTECH,
        simulation      => SIMULATION
        )
      port map(
        sgmiii   => sgmiii,
        sgmiio   => sgmiio,
        gmiii    => gmiii,
        gmiio    => gmiio,
        reset    => sgmiirst,
        apb_clk  => chip_refclk,
        apb_rstn => rstn,
        apbi     => sgmii0_apbi,
        apbo     => sgmii0_apbo,
        gtrefclk_out => gtrefclk_buf
        );

    emdio_pad : iopad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
      port map (emdio, sgmiio.mdio_o, sgmiio.mdio_oe, sgmiii.mdio_i);

    emdc_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
      port map (emdc, sgmiio.mdc);

    eint_pad : inpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
      port map (eint, sgmiii.mdint);

    erst_pad : outpad generic map (tech => CFG_FABTECH, level => cmos, voltage => x18v)
      port map (erst, sgmiio.reset);

    sgmiii.clkp <= gtrefclk_p;
    sgmiii.clkn <= gtrefclk_n;
    txp         <= sgmiio.txp;
    txn         <= sgmiio.txn;
    sgmiii.rxp  <= rxp;
    sgmiii.rxn  <= rxn;

  end generate;

  no_eth0 : if SIMULATION = true or CFG_GRETH = 0 generate
    eth0_apbo <= apb_none;
    sgmii0_apbo <= apb_none;
    eth0_ahbmo <= ahbm_none;
    edcl_ahbmo <= ahbm_none;
    txp <= '0';
    txn <= '1';
    emdc <= '0';
    erst <= '0';
    emdio <= '0';
  end generate;

  -----------------------------------------------------------------------------
  -- CHIP
  -----------------------------------------------------------------------------
  chip_rst <= rstn;
  sys_clk(0) <= clkm;

  -----------------------------------------------------------------------------
  -- ESP I/O link over the SFP+ cage, via Aurora 64B/66B
  --
  -- Requires CFG_GRETH = 1: the IBUFDS_GTE2 on gtrefclk_p/n (AH8/AH7) lives
  -- inside sgmii_vc707 and is shared from there, because only one such buffer
  -- may drive a reference clock pin pair. With Ethernet off there is no buffer
  -- to share and one would have to be instantiated here instead.
  -----------------------------------------------------------------------------
  iolink_aurora_gen : if CFG_IOLINK_EN = 1 generate

    -- sys_reset_out is active high and already in the user_clk domain; the PHY
    -- wants active low. Taking the core's own reset rather than synchronising
    -- rstn by hand is what keeps the PHY's synchronous reset legitimate.
    aurora_user_rstn <= not aurora_sys_reset;
    aurora_reset     <= not rstn;

    -- BRING-UP AIDS on the otherwise unused DIP switches.
    --
    -- SW0 selects Aurora near-end PMA loopback ("010"), which loops TX back to
    -- RX inside the transceiver -- before the SFP cage. channel_up asserting
    -- with SW0 on therefore proves the entire FPGA side (GT placement,
    -- reference clock, MMCM, reset sequencing, the PHY) with no optics, cable
    -- or far-end board in the path. Up in loopback but dark in normal mode
    -- means the problem is outside the FPGA.
    aurora_loopback <= "010" when sel0 = '1' else "000";

    -- channel_up and lane_up are shown SEPARATELY rather than ANDed, because
    -- the difference is the whole diagnosis: lane_up means this receiver is
    -- locking to valid 64B/66B blocks from the far end, while channel_up also
    -- needs channel init to complete in both directions. lane_up without
    -- channel_up is a very different fault from neither.
    iolink_led_link <= aurora_channel_up;
    -- SW1 swaps led(5) from the bring-up view to the data-integrity view;
    -- tx_overflow only means anything once traffic is actually flowing.
    iolink_led_aux  <= iolink_tx_overflow when sel1 = '1' else aurora_lane_up(0);
    -- Drive TX_DISABLE low so the module actually transmits. Note this is
    -- necessary but not sufficient: the board ALSO gates the transmitter with
    -- jumper J6 ("SFP Enable"), which is not under FPGA control.
    sfp_txdis_int   <= '0';

    -- In bring-up view led(6) shows LOS straight off the module, which is a
    -- more direct question than anything the protocol can tell us: LOS high
    -- means no optical power is arriving at all, so the fault is the cable,
    -- the far end's transmitter or J6 -- not the rate, the GT or Aurora.
    iolink_led_err  <= sfp_los_int when sel1 = '0' else iolink_rx_sync_err;
    aurora_rxp(0)    <= sfp_rxp;
    aurora_rxn(0)    <= sfp_rxn;
    sfp_txp          <= aurora_txp(0);
    sfp_txn          <= aurora_txn(0);

    aurora_i : aurora
      port map (
        rxp                     => aurora_rxp,
        rxn                     => aurora_rxn,
        refclk1_in              => gtrefclk_buf,
        -- Aurora resets are active HIGH.
        reset_pb                => aurora_reset,
        power_down              => '0',
        pma_init                => aurora_reset,
        loopback                => aurora_loopback,
        txp                     => aurora_txp,
        txn                     => aurora_txn,
        hard_err                => aurora_hard_err,
        soft_err                => aurora_soft_err,
        channel_up              => aurora_channel_up,
        lane_up                 => aurora_lane_up,
        tx_out_clk              => open,
        drp_clk_in              => chip_refclk,
        gt_pll_lock             => open,
        s_axi_tx_tdata          => aurora_tx_tdata,
        s_axi_tx_tvalid         => aurora_tx_tvalid,
        s_axi_tx_tready         => aurora_tx_tready,
        m_axi_rx_tdata          => aurora_rx_tdata,
        m_axi_rx_tvalid         => aurora_rx_tvalid,
        mmcm_not_locked_out     => open,
        -- No dynamic reconfiguration; tied off.
        drpaddr_in              => (others => '0'),
        drpdi_in                => (others => '0'),
        drprdy_out              => open,
        drpen_in                => '0',
        drpwe_in                => '0',
        drpdo_out               => open,
        init_clk                => chip_refclk,
        link_reset_out          => open,
        user_clk_out            => aurora_user_clk,
        sync_clk_out            => open,
        gt_qpllclk_quad1_out    => open,
        gt_qpllrefclk_quad1_out => open,
        gt_rxcdrovrden_in       => '0',
        sys_reset_out           => aurora_sys_reset,
        gt_reset_out            => open);

    -- The AXI-Stream data ports are (0 to 63) on the core and (63 downto 0) on
    -- the PHY. Associating them directly is correct: VHDL maps leftmost to
    -- leftmost, so the PHY's bit 63 -- the top of the SYNC tag -- lands on
    -- Aurora's bit 0, which is first on the wire.
    iolink_phy_i : iolink_phy_aurora
      generic map (
        io_bitwidth   => CFG_IOLINK_BITS,
        tx_fifo_depth => 32)
      port map (
        user_clk      => aurora_user_clk,
        user_rstn     => aurora_user_rstn,
        channel_up    => aurora_channel_up,
        lane_up       => aurora_lane_up(0),
        hard_err      => aurora_hard_err,
        soft_err      => aurora_soft_err,
        tx_tdata      => aurora_tx_tdata,
        tx_tvalid     => aurora_tx_tvalid,
        tx_tready     => aurora_tx_tready,
        rx_tdata      => aurora_rx_tdata,
        rx_tvalid     => aurora_rx_tvalid,
        -- The PHY presents the far end of the cable to the bridge, so its
        -- outputs feed the SoC's inputs and vice versa.
        io_clk_out    => iolink_clk_in,
        -- The bridge's TX clock. For the target role this is user_clk looped
        -- back through iolink2ahbm; for the initiator it is tile_clk, which is
        -- why the PHY's TX FIFO has to be asynchronous.
        io_clk_in     => iolink_clk_out,
        io_valid_out  => iolink_valid_in,
        io_credit_out => iolink_credit_in,
        io_data_out   => iolink_data_in,
        io_valid_in   => iolink_valid_out,
        io_credit_in  => iolink_credit_out,
        io_data_in    => iolink_data_out,
        link_ready    => iolink_link_ready,
        tx_overflow   => iolink_tx_overflow,
        rx_sync_err   => iolink_rx_sync_err);

  end generate iolink_aurora_gen;

  no_iolink_aurora_gen : if CFG_IOLINK_EN = 0 generate
    sfp_txp            <= '0';
    sfp_txn            <= '1';
    iolink_clk_in      <= '0';
    iolink_valid_in    <= '0';
    iolink_credit_in   <= '0';
    iolink_data_in     <= (others => '0');
    iolink_link_ready  <= '0';
    iolink_tx_overflow <= '0';
    iolink_rx_sync_err <= '0';
    iolink_led_link    <= '0';
    iolink_led_aux     <= '0';
    iolink_led_err     <= '0';
    sfp_txdis_int      <= '1';   -- link not built: keep the transmitter off
  end generate no_iolink_aurora_gen;

  esp_1: esp
    generic map (
      SIMULATION => SIMULATION)
    port map (
      rst           => chip_rst,
      sys_clk       => sys_clk(0 to MEM_ID_RANGE_MSB),
      refclk        => chip_refclk,
      uart_rxd       => uart_rxd_int,
      uart_txd       => uart_txd_int,
      uart_ctsn      => uart_ctsn_int,
      uart_rtsn      => uart_rtsn_int,
      cpuerr         => cpuerr,
      ddr_axi_si     => ddr_axi_si(0 to MEM_ID_RANGE_MSB),
      ddr_axi_so	 => ddr_axi_so(0 to MEM_ID_RANGE_MSB), 
      eth0_ahbmi     => eth0_ahbmi,
      eth0_ahbmo     => eth0_ahbmo,
      edcl_ahbmo     => edcl_ahbmo,
      eth0_apbi      => eth0_apbi,
      eth0_apbo      => eth0_apbo,
      sgmii0_apbi    => sgmii0_apbi,
      sgmii0_apbo    => sgmii0_apbo,
      dvi_apbi       => dvi_apbi,
      dvi_apbo       => dvi_apbo,
      dvi_ahbmi      => dvi_ahbmi,
      dvi_ahbmo      => dvi_ahbmo,
      -- I/O link
      iolink_data_oen   => open,
      iolink_data_in    => iolink_data_in,
      iolink_data_out   => iolink_data_out,
      iolink_valid_in   => iolink_valid_in,
      iolink_valid_out  => iolink_valid_out,
      iolink_clk_in     => iolink_clk_in,
      iolink_clk_out    => iolink_clk_out,
      iolink_credit_in  => iolink_credit_in,
      iolink_credit_out => iolink_credit_out);

 end;

