-- Copyright (c) 2011-2026 Columbia University, System Level Design Group
-- SPDX-License-Identifier: Apache-2.0
--
-- Behavioural model of ONE direction of an Aurora 64B/66B streaming channel.
-- Not synthesisable and not a model of the GT: it reproduces only the three
-- properties of the real core that the I/O link design actually depends on,
-- because those are the ones that can break it.
--
--   1. s_axi_tx_tready drops periodically while the core inserts clock
--      compensation sequences. This is the entire reason iolink_phy_aurora has
--      a TX elastic FIFO, so the model must exercise it. CC_PERIOD/CC_LEN are
--      deliberately far more aggressive than real CC insertion (every ~10k
--      cycles for a few cycles) -- the point is to stress the FIFO, not to be
--      faithful about the duty cycle.
--
--   2. There is NO m_axi_rx_tready. The receiver cannot push back, so this
--      model has no way to be told to wait, and anything the sink fails to
--      consume on the cycle it arrives is simply lost. That is what makes the
--      link's credit scheme load bearing rather than an optimisation.
--
--   3. Latency is real and large. Aurora is 54-55 user_clk cycles each way, so
--      the round trip is ~125 cycles including the bridges' CDC. A credit
--      budget smaller than the round trip throttles the link; this is the
--      whole reason CONFIG_IOLINK_CREDITS had to become configurable, and a
--      zero-latency model would hide it completely.
--
-- Word order is preserved and nothing is corrupted: streaming mode inserts no
-- framing of its own. A separate error-injection hook could be added later to
-- test rx_sync_err, but a clean channel must pass first.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aurora_channel_model is
  generic (
    -- One-way latency in user_clk cycles.
    LATENCY   : integer range 1 to 512 := 55;
    -- tready is deasserted for CC_LEN cycles out of every CC_PERIOD.
    CC_PERIOD : integer := 64;
    CC_LEN    : integer := 6);
  port (
    user_clk  : in  std_ulogic;
    user_rstn : in  std_ulogic;
    -- Transmit side (driven by the sending PHY)
    tx_tdata  : in  std_logic_vector(63 downto 0);
    tx_tvalid : in  std_ulogic;
    tx_tready : out std_ulogic;
    -- Receive side (drives the receiving PHY). No tready, by construction.
    rx_tdata  : out std_logic_vector(63 downto 0);
    rx_tvalid : out std_ulogic;
    -- Count of beats that entered the channel, for the scoreboard.
    beats_in  : out integer);
end entity aurora_channel_model;

architecture sim of aurora_channel_model is

  type data_pipe_t  is array (0 to LATENCY - 1) of std_logic_vector(63 downto 0);
  type valid_pipe_t is array (0 to LATENCY - 1) of std_ulogic;

  signal data_pipe  : data_pipe_t;
  signal valid_pipe : valid_pipe_t;

  signal cc_cnt    : integer range 0 to CC_PERIOD - 1 := 0;
  signal ready_int : std_ulogic;
  signal n_in      : integer := 0;

begin

  -- Low for the last CC_LEN cycles of each period.
  ready_int <= '0' when cc_cnt >= CC_PERIOD - CC_LEN else '1';
  tx_tready <= ready_int;

  beats_in  <= n_in;

  rx_tdata  <= data_pipe(LATENCY - 1);
  rx_tvalid <= valid_pipe(LATENCY - 1);

  process (user_clk) is
  begin
    if rising_edge(user_clk) then
      if user_rstn = '0' then
        valid_pipe <= (others => '0');
        data_pipe  <= (others => (others => '0'));
        cc_cnt     <= 0;
        n_in       <= 0;
      else
        if cc_cnt = CC_PERIOD - 1 then cc_cnt <= 0; else cc_cnt <= cc_cnt + 1; end if;

        -- Shift the delay line.
        for i in LATENCY - 1 downto 1 loop
          data_pipe(i)  <= data_pipe(i - 1);
          valid_pipe(i) <= valid_pipe(i - 1);
        end loop;

        -- A beat enters only on a completed handshake.
        if tx_tvalid = '1' and ready_int = '1' then
          data_pipe(0)  <= tx_tdata;
          valid_pipe(0) <= '1';
          n_in          <= n_in + 1;
        else
          valid_pipe(0) <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture sim;
