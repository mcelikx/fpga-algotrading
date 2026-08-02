// =============================================================================
// csr_regfile.sv — BAR0-mapped control / status register file
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/06-operations/01-build-and-release.md §4 (build-ID gate)
//           manuals/06-operations/03-monitoring-and-telemetry.md §4 (watchdog)
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
//           manuals/00-foundations/04-clocking-reset-and-cdc.md §4 (reset policy)
//
// PURPOSE
//   This is how a human arms trading, sets risk limits, and sees what the
//   machine is doing. It runs entirely in the pcie_clk domain; every crossing
//   to core_clk is done by the parent, rtl/ctrl/host_ctrl.sv. This block
//   contains NO CDC.
//
//   The register map below is the HOST-SOFTWARE CONTRACT. The full table with
//   bit-level detail, the startup sequence and the shutdown sequence are in
//   rtl/ctrl/README.md — that file and this header must agree.
//
// -----------------------------------------------------------------------------
// REGISTER MAP (BAR0, byte offsets, all registers 32-bit, naturally aligned)
//
//  offset  name              acc   reset       meaning
//  ------  ----------------  ----  ----------  ---------------------------------
//  0x000   BUILD_ID          RO    param       ⚠ THE ARM GATE. The host refuses
//                                              to arm unless this matches the
//                                              expected build exactly.
//  0x004   GIT_SHA           RO    param       first 4 bytes of the commit SHA
//  0x008   BUILD_TIMESTAMP   RO    param       unix seconds at synthesis
//  0x00C   MAP_VERSION       RO    const       {MAGIC 0x4654, MAJOR, MINOR}
//
//  0x010   CONTROL           RW    0x0000_0002 ⚠ RESET = KILL ASSERTED,
//                                              TRADING DISABLED
//            [0]  trading_enable   RW   0
//            [1]  kill             RW   1  ⚠ writing 1 disarms IMMEDIATELY
//            [2]  arm_step1        W1P  -  first half of the two-step arm
//            [3]  arm_step2        W1P  -  second half; MUST be a separate
//                                          bus write (both bits in one write
//                                          is rejected as an operator error)
//            [4]  reset_counters   W1P  -
//            [5]  credit_return    W1P  -
//            [6]  clr_sticky       W1P  -  clears sticky error flags
//            [31:7] reserved, write 0
//
//  0x014   STATUS            RO    -           see STATUS bit table below
//  0x018   HEARTBEAT         WO    -           ⚠ WATCHDOG KICK. See below.
//  0x01C   WATCHDOG_CFG      RO    param       {warn_ms[15:0], timeout_ms[15:0]}
//  0x020   KILL_SRC          RO    0           sticky provenance, see below
//  0x024   KILL_COUNT        RO    0           kill activations since reset
//  0x028   HEARTBEAT_AGE     RO    0xFFFF      ms since the last kick
//  0x02C   SCRATCH           RW    0           host-owned; proves the BAR path
//  0x030   PARAM_GEN         RO    0           {strat_gen[15:0], risk_gen[15:0]}
//  0x034   PARAM_STATUS      RO    0           per-window valid / protected bits
//  0x038   CFG_ERR           RO/W1C 0          rejected-write reasons + count
//  0x03C   ARM_STATE         RO    0           {window_ms_left, fault, state}
//
//  0x040   LOG_RING_BASE_LO  RW    0           host physical address, 64 B aligned
//  0x044   LOG_RING_BASE_HI  RW    0
//  0x048   LOG_RING_SIZE     RW    0           [4:0] log2(entries); 0 = disabled
//  0x04C   LOG_RING_HEAD     RO    0           fabric produce pointer (records)
//  0x050   LOG_RING_TAIL     RW    0           host consume pointer (records)
//  0x054   LOG_DROP_CNT      RO    0           ⚠ ALERTABLE. Records LOST.
//  0x058   LOG_REC_CNT       RO    0           records delivered
//  0x05C   LOG_CTRL          RW    0           [0] ring_en, [1] W1P clr_sticky
//  0x060   LOG_FULL_CNT      RO    0           host-too-slow episodes
//  0x064   TELEM_ERR_CNT     RO    0           telemetry read timeouts
//
//  ── config write windows. Each window is ADDR + DATA + CTRL + readback. ──
//  0x100   FILTER_ADDR       RW    0    entry index; auto-increments on DATA
//  0x104   FILTER_DATA       WO    -    pushes {target, ADDR, wdata} to fabric
//  0x108   FILTER_CTRL       RW    1    [0] auto_inc(=1), [1] W1P reset_chk,
//                                       [2] W1P commit (risk/strat only),
//                                       [3] W1P zero_addr, [4] mark_valid
//  0x10C   FILTER_GEN        RO    0    {pending[15:0], generation[15:0]}
//  0x110   FILTER_WR_CHK     RO    seed running write-side checksum
//  0x114   FILTER_CMT_CHK    RO    0    checksum latched at the last commit
//  0x118   FILTER_STATUS     RO    0    {protected, valid, word_count[15:0]}
//
//  0x200.. RISK_*            same layout.  ⚠ WRITE-PROTECTED WHILE ENABLED
//  0x300.. STRAT_*           same layout.  NOT protected — see note below
//  0x400.. TMPL_*            same layout.  ⚠ WRITE-PROTECTED WHILE ENABLED
//  0x500.. SESSION_*         same layout; ADDR is a running word index only
//                                         ⚠ WRITE-PROTECTED WHILE ENABLED
//
//  0x800-0xBFC  TELEMETRY    RO    -    256-word read window, proxied to
//                                       telem_raddr/telem_rdata in core_clk.
//                                       word index = (offset - 0x800) >> 2.
//                                       Map: rtl/telemetry/telemetry_pkg.sv.
//
//  anything else             RO    0xDEAD_C0DE  unmapped sentinel — never 0, so
//                                       a host pointed at the wrong offset
//                                       finds out instead of reading plausible
//                                       zeros.
//
// -----------------------------------------------------------------------------
// STATUS (0x014) bit table
//    [2:0]  link_up {oe, md_b, md_a}   mirrored from the core telemetry STATUS
//    [3]    kill_active                fabric's kill state (authoritative)
//    [6:4]  kill_src                   live source
//    [7]    pcie_link_up
//    [8]    core_alive                 core_clk domain is running (§ liveness)
//    [11:9] arm_state                  0=DISARMED 1=STEP1 2=ARMED 3=FAULT
//    [12]   trading_en_effective       CONTROL[0] AND armed
//    [13]   watchdog_expired           ⚠ heartbeat stale
//    [14]   params_valid               ALL windows committed and marked valid
//    [15]   cfg_wr_busy                config write path not drained
//    [16]   risk_valid      [17] strat_valid   [18] filter_valid
//    [19]   tmpl_valid      [20] session_valid
//    [21]   log_drop_sticky            ⚠ audit records were LOST
//    [22]   telem_timeout_sticky       core domain did not answer a read
//    [23]   cfg_err_sticky             at least one write was rejected
//    [24]   watchdog_warn              heartbeat older than WATCHDOG_WARN_MS
//
// KILL_SRC (0x020) bit table — sticky, cleared only by reset
//    [2:0]  last_kill_src   (kill_src_e) provenance of the MOST RECENT kill
//    [3]    kill_active     live
//    [10:8] first_kill_src  provenance of the FIRST kill since reset. In a
//                           cascade the first cause is the one you need; the
//                           last one is usually just the consequence.
//    [23:16] ever_mask      bit n set = kill_src_e value n has fired at least
//                           once. A source that has never fired is a control
//                           you have never actually tested.
//
// -----------------------------------------------------------------------------
// ⚠ THE HEARTBEAT AND THE WATCHDOG (0x018)
//
//   The host writes ANY value to HEARTBEAT on a fixed cadence. Each write
//   resets HEARTBEAT_AGE to 0 and emits one pulse to the core domain, where
//   risk_gate runs the authoritative watchdog.
//
//     required cadence   : >= 10 Hz.  RECOMMENDED 50 Hz (20 ms period).
//     WATCHDOG_WARN_MS   : 50 ms  -> STATUS bit 13 sets, alert
//     WATCHDOG_MS        : 100 ms -> ⚠ FORCED DISARM. arm_state -> DISARMED,
//                          kill asserted, LOG_WATCHDOG record emitted.
//
//   ⚠ RESET STATE IS KILLED. HEARTBEAT_AGE resets to 0xFFFF — already past the
//     timeout — so a freshly configured or freshly reset card is watchdog-
//     expired and CANNOT be armed until the host has established a live
//     heartbeat. There is no window in which a rebooting host leaves an armed
//     card behind. This is the same reasoning as the kill switch: a dead host
//     process means no position accounting, no reconciliation and no human able
//     to act, so the fabric must fail safe by itself
//     (manuals/06-operations/03-monitoring-and-telemetry.md §4).
//
//   ⚠ The watchdog BLOCKS, it does not merely warn. Blocking is done in
//     risk_gate, in the core domain, and is not conditional on this block being
//     alive — host_ctrl additionally stops forwarding heartbeat pulses, which
//     makes risk_gate's own watchdog fire independently.
//
// -----------------------------------------------------------------------------
// ⚠ WRITE PROTECTION — THE FOUR-EYES-SUPPORTING MECHANISM
//
//   Writes to the RISK parameter window (0x200) are REJECTED while trading is
//   enabled. A rejected write sets a CFG_ERR bit, increments a counter, and
//   changes nothing. There is no override bit and no force flag.
//
//   The operator is therefore FORCED through:
//
//        disable trading -> change limits -> commit -> read back and
//        verify the checksum -> re-enable trading
//
//   Why this is the right shape, and what it does and does not give you:
//
//   * It makes a limit change a DELIBERATE, VISIBLE, MULTI-STEP operation
//     instead of a single MMIO write that can happen by accident, by a stray
//     script, or in the middle of a trading burst. Disabling trading is loud —
//     it shows on the dashboard, it stops order flow, and it is logged.
//   * It creates an unambiguous audit boundary: every risk-limit change is
//     bracketed by a LOG_TRADING_DIS / LOG_PARAM_COMMIT / LOG_TRADING_EN triple
//     in the DMA audit ring, with the write-side checksum in the commit record.
//     A reviewer can reconstruct exactly what changed and when.
//   * It removes the worst failure mode — limits mutating underneath live order
//     flow, so that a rejected order and an accepted one were judged by
//     different rules with no record of the transition.
//   * ⚠ It does NOT by itself implement four-eyes approval. Two humans
//     approving a change is a HOST-SIDE control: the host tool must require a
//     second authenticated operator before it performs the disable/commit/
//     re-enable sequence. What the fabric provides is the enforcement point
//     that makes the host-side control meaningful — the sequence cannot be
//     bypassed by writing directly to the BAR, because the fabric refuses.
//
//   The STRATEGY window (0x300) is deliberately NOT protected. sym_strat_t
//   carries `fair_value`, which the host updates at millisecond cadence while
//   trading (see rtl/pkg/trading_pkg.sv). Protecting it would make the strategy
//   unusable. The asymmetry is intentional and is the reason risk parameters
//   and strategy parameters live in separate windows with separate commits:
//   ⚠ never move a risk limit into the strategy window.
//
// -----------------------------------------------------------------------------
// LATENCY  : slow path only. Local register read: reg_rvalid 1 cycle after
//            reg_re. Telemetry window read: reg_rvalid after the core-domain
//            round trip (~20 pcie cycles typical), or TELEM_TIMEOUT cycles with
//            a 0xDEAD_DEAD sentinel and a sticky error if the core is wedged.
// RESOURCE : est. LUT ~3.5 k, FF ~2.8 k, BRAM 0, DSP 0.
// =============================================================================
`default_nettype none

module csr_regfile
    import trading_pkg::*;
    import telemetry_pkg::*;
#(
    parameter logic [31:0] BUILD_ID        = 32'hDEAD_0000,
    parameter logic [31:0] GIT_SHA         = 32'h0000_0000,
    parameter logic [31:0] BUILD_TIMESTAMP = 32'h0000_0000,
    parameter int unsigned BAR_ADDR_W      = 16,
    parameter int unsigned PCIE_CLK_MHZ    = 250,
    parameter int unsigned WATCHDOG_MS     = 100,
    parameter int unsigned WATCHDOG_WARN_MS= 50,
    parameter int unsigned ARM_WINDOW_MS   = 5000,   // step1 -> step2 deadline
    parameter int unsigned TELEM_TIMEOUT   = 4096    // pcie cycles
) (
    input  var logic                   clk,          // pcie_clk
    input  var logic                   rst,          // pcie_rst, sync, act. high

    // ── register port from pcie_wrapper ─────────────────────────────────────
    input  var logic [BAR_ADDR_W-1:0]  reg_addr,
    input  var logic [31:0]            reg_wdata,
    input  var logic                   reg_we,
    input  var logic                   reg_re,
    output var logic [31:0]            reg_rdata,
    output var logic                   reg_rvalid,

    // ── control levels and pulses (pcie domain; host_ctrl crosses them) ─────
    output var logic                   trading_en,
    output var logic                   kill,
    output var logic                   hb_pulse,
    output var logic                   credit_ret_pulse,
    output var logic                   risk_commit_pulse,
    output var logic                   strat_commit_pulse,
    output var logic                   counters_rst_pulse,

    // ── config write stream into the pcie->core handshake ───────────────────
    output var logic                   cfg_wr_valid,
    input  var logic                   cfg_wr_ready,
    output var cfg_target_e            cfg_wr_target,
    output var logic [15:0]            cfg_wr_addr,
    output var logic [31:0]            cfg_wr_data,

    // ── telemetry read proxy (host_ctrl owns the crossing) ──────────────────
    output var logic                   telem_req,
    output var logic [15:0]            telem_addr,
    input  var logic                   telem_ack,
    input  var logic [31:0]            telem_data,

    // ── status inputs, already synchronized by host_ctrl ────────────────────
    input  var logic                   kill_active_s,
    input  var logic [2:0]             kill_src_s,
    input  var logic [31:0]            core_status_s,   // mirrored TELEM STATUS
    input  var logic                   core_alive,      // core clock is running
    input  var logic                   pcie_link_up,

    // ── DMA log ring control / status ───────────────────────────────────────
    output var logic                   ring_en,
    output var logic [63:0]            ring_base,
    output var logic [4:0]             ring_size_log2,
    output var logic [31:0]            ring_tail,
    output var logic                   ring_clr_sticky,
    input  var logic [31:0]            ring_head,
    input  var logic [31:0]            ring_drop_cnt,
    input  var logic                   ring_drop_sticky,
    input  var logic [31:0]            ring_full_cnt,
    input  var logic [31:0]            ring_rec_cnt,

    // ── control-plane audit events -> dma_log_ring (via host_ctrl) ──────────
    // Standard valid/ready: the payload is held until ready. ⚠ Control-plane
    // events are compliance records (who armed it, when, with which checksum).
    // They are backpressured, never dropped.
    output var logic                   evt_valid,
    input  var logic                   evt_ready,
    output var logic [7:0]             evt_type,
    output var logic [7:0]             evt_reason,
    output var logic [31:0]            evt_aux0,
    output var logic [31:0]            evt_aux1,

    // ── state visible to host_ctrl ──────────────────────────────────────────
    output var logic                   watchdog_expired,
    output var logic [2:0]             arm_state_o
);

    // =========================================================================
    // Local constants
    // =========================================================================
    localparam int unsigned NTGT       = 5;    // filter, risk, strat, tmpl, session
    localparam int unsigned T_FILTER   = 0;
    localparam int unsigned T_RISK     = 1;
    localparam int unsigned T_STRAT    = 2;
    localparam int unsigned T_TMPL     = 3;
    localparam int unsigned T_SESSION  = 4;

    localparam int unsigned NP         = 4;    // rate-limited pulse outputs
    localparam int unsigned P_HB       = 0;
    localparam int unsigned P_CREDIT   = 1;
    localparam int unsigned P_RCOMMIT  = 2;
    localparam int unsigned P_SCOMMIT  = 3;

    // Millisecond prescaler. PCIE_CLK_MHZ * 1000 cycles per millisecond.
    localparam int unsigned MS_DIV     = PCIE_CLK_MHZ * 1000;
    localparam int unsigned MS_CTR_W   = 20;   // 250_000 needs 18 b; 20 for headroom

    localparam logic [31:0] CSR_UNMAPPED = 32'hDEAD_C0DE;
    localparam logic [31:0] CSR_TELEM_TO = 32'hDEAD_DEAD;

    // Page decode
    localparam logic [7:0]  PG_CORE    = 8'h00;
    localparam logic [7:0]  PG_FILTER  = 8'h01;
    localparam logic [7:0]  PG_RISK    = 8'h02;
    localparam logic [7:0]  PG_STRAT   = 8'h03;
    localparam logic [7:0]  PG_TMPL    = 8'h04;
    localparam logic [7:0]  PG_SESSION = 8'h05;

    // Window register offsets within a page
    localparam logic [7:0]  W_ADDR     = 8'h00;
    localparam logic [7:0]  W_DATA     = 8'h04;
    localparam logic [7:0]  W_CTRL     = 8'h08;
    localparam logic [7:0]  W_GEN      = 8'h0C;
    localparam logic [7:0]  W_WR_CHK   = 8'h10;
    localparam logic [7:0]  W_CMT_CHK  = 8'h14;
    localparam logic [7:0]  W_STATUS   = 8'h18;

    typedef enum logic [2:0] {
        ARM_DISARMED = 3'd0,
        ARM_STEP1    = 3'd1,
        ARM_ARMED    = 3'd2,
        ARM_FAULT    = 3'd3
    } arm_state_e;

    // CFG_ERR bit positions
    localparam int unsigned E_PROTECTED = 0;   // write while trading enabled
    localparam int unsigned E_QUEUE     = 1;   // config write queue overflow
    localparam int unsigned E_ARM_SEQ   = 2;   // arm_step2 without step1, or both
    localparam int unsigned E_ARM_PRE   = 3;   // arm attempted, preconditions unmet
    localparam int unsigned E_UNMAPPED  = 4;   // write to an unmapped offset
    localparam int unsigned E_RING_CFG  = 5;   // illegal ring size / base
    localparam int unsigned E_TELEM_TO  = 6;   // telemetry read timed out

    // =========================================================================
    // Address decode
    // =========================================================================
    logic [7:0]  page;
    logic [7:0]  off;
    logic        is_core_pg;
    logic        is_win_pg;
    logic        is_telem;
    logic [2:0]  tgt_idx;
    logic [7:0]  telem_word;

    always_comb begin
        page       = reg_addr[15:8];
        off        = reg_addr[7:0];
        is_core_pg = (page == PG_CORE);
        is_win_pg  = (page >= PG_FILTER) && (page <= PG_SESSION);
        // 0x800 .. 0xBFF
        is_telem   = (reg_addr[15:10] == 6'b0000_10);
        // Clamped: every window array is NTGT deep, and an out-of-range index
        // must never reach one even on an unmapped access.
        tgt_idx    = is_win_pg ? (page[2:0] - 3'd1) : 3'd0;
        telem_word = reg_addr[9:2];
    end

    // =========================================================================
    // Millisecond time base and the host watchdog
    // ⚠ RESET STATE IS KILLED: hb_age_q starts at its maximum, i.e. already
    //   expired, so a freshly reset card cannot be armed until the host has
    //   established a live heartbeat.
    // =========================================================================
    logic [MS_CTR_W-1:0] ms_ctr_q;
    logic                ms_tick;
    logic [15:0]         hb_age_q;
    logic [31:0]         hb_seq_q;
    logic                hb_write;

    always_ff @(posedge clk) begin
        if (rst) begin
            ms_ctr_q <= '0;
            hb_age_q <= 16'hFFFF;         // ⚠ expired at reset. Deliberate.
            hb_seq_q <= 32'd0;
        end else begin
            if (ms_ctr_q >= MS_CTR_W'(MS_DIV - 1)) ms_ctr_q <= '0;
            else                                   ms_ctr_q <= ms_ctr_q + 1'b1;

            if (hb_write) begin
                hb_age_q <= 16'd0;
                hb_seq_q <= reg_wdata;
            end else if (ms_tick && (hb_age_q != 16'hFFFF)) begin
                hb_age_q <= hb_age_q + 16'd1;
            end
        end
    end

    assign ms_tick          = (ms_ctr_q == MS_CTR_W'(MS_DIV - 1));
    assign watchdog_expired = (hb_age_q >= 16'(WATCHDOG_MS));

    logic watchdog_warn;
    assign watchdog_warn = (hb_age_q >= 16'(WATCHDOG_WARN_MS));

    // =========================================================================
    // Write decode (combinational strobes)
    // =========================================================================
    logic        wr_control;
    logic        wr_scratch;
    logic        wr_win_addr;
    logic        wr_win_data;
    logic        wr_win_ctrl;
    logic        wr_ring_lo, wr_ring_hi, wr_ring_size, wr_ring_tail, wr_ring_ctrl;
    logic        wr_cfg_err;
    logic        wr_unmapped;

    always_comb begin
        wr_control   = 1'b0;
        wr_scratch   = 1'b0;
        hb_write     = 1'b0;
        wr_win_addr  = 1'b0;
        wr_win_data  = 1'b0;
        wr_win_ctrl  = 1'b0;
        wr_ring_lo   = 1'b0;
        wr_ring_hi   = 1'b0;
        wr_ring_size = 1'b0;
        wr_ring_tail = 1'b0;
        wr_ring_ctrl = 1'b0;
        wr_cfg_err   = 1'b0;
        wr_unmapped  = 1'b0;

        if (reg_we) begin
            if (is_core_pg) begin
                case (off)
                    8'h10:   wr_control   = 1'b1;
                    8'h18:   hb_write     = 1'b1;
                    8'h2C:   wr_scratch   = 1'b1;
                    8'h38:   wr_cfg_err   = 1'b1;
                    8'h40:   wr_ring_lo   = 1'b1;
                    8'h44:   wr_ring_hi   = 1'b1;
                    8'h48:   wr_ring_size = 1'b1;
                    8'h50:   wr_ring_tail = 1'b1;
                    8'h5C:   wr_ring_ctrl = 1'b1;
                    default: wr_unmapped  = 1'b1;
                endcase
            end else if (is_win_pg) begin
                case (off)
                    W_ADDR:  wr_win_addr = 1'b1;
                    W_DATA:  wr_win_data = 1'b1;
                    W_CTRL:  wr_win_ctrl = 1'b1;
                    default: wr_unmapped = 1'b1;
                endcase
            end else begin
                // The telemetry window is read-only; writing it is an error the
                // host wants to hear about, not a no-op.
                wr_unmapped = 1'b1;
            end
        end
    end

    // =========================================================================
    // Per-window state
    // =========================================================================
    logic [15:0] w_addr_q     [NTGT];
    logic        w_autoinc_q  [NTGT];
    logic [31:0] w_chk_q      [NTGT];
    logic [31:0] w_cmt_chk_q  [NTGT];
    logic [15:0] w_gen_q      [NTGT];
    logic [15:0] w_cnt_q      [NTGT];
    logic        w_valid_q    [NTGT];
    logic        w_protected  [NTGT];

    logic trading_en_q;
    logic trading_en_eff;
    arm_state_e arm_state_q;

    assign trading_en_eff = trading_en_q && (arm_state_q == ARM_ARMED);
    assign trading_en     = trading_en_eff;

    always_comb begin
        // ⚠ Risk, filter, template and session windows are structural: they
        //   must not move under live order flow. The strategy window is not
        //   protected because fair_value is a millisecond-cadence update — see
        //   the header note. Do not "simplify" this by protecting all five.
        w_protected[T_FILTER]  = trading_en_eff;
        w_protected[T_RISK]    = trading_en_eff;
        w_protected[T_STRAT]   = 1'b0;
        w_protected[T_TMPL]    = trading_en_eff;
        w_protected[T_SESSION] = trading_en_eff;
    end

    // =========================================================================
    // Config write queue -> cdc_handshake
    // -----------------------------------------------------------------------------
    // 16 deep. The handshake round trip is ~6 pcie cycles; posted MMIO writes
    // from a host CPU can burst faster than that, so a queue is required or
    // bulk table loads would reject constantly. Overflow is an ERROR, counted
    // and flagged — never a silent drop of a risk limit.
    // =========================================================================
    localparam int unsigned CFGQ_DEPTH = 16;
    localparam int unsigned CFGQ_AW    = 4;

    logic [50:0]        cfgq [CFGQ_DEPTH];      // {target[2:0], addr[15:0], data[31:0]}
    logic [CFGQ_AW:0]   cfgq_wp_q, cfgq_rp_q;
    logic               cfgq_empty, cfgq_full;
    logic               cfgq_push;
    logic               cfgq_pop;
    logic [50:0]        cfgq_din;

    logic               out_valid_q;
    logic [50:0]        out_data_q;

    assign cfgq_empty = (cfgq_wp_q == cfgq_rp_q);
    assign cfgq_full  = (cfgq_wp_q[CFGQ_AW-1:0] == cfgq_rp_q[CFGQ_AW-1:0]) &&
                        (cfgq_wp_q[CFGQ_AW]     != cfgq_rp_q[CFGQ_AW]);

    // A window DATA write is accepted only when the window is unprotected and
    // the queue has room. Anything else is rejected and counted.
    logic win_data_ok;
    assign win_data_ok = wr_win_data && is_win_pg && !w_protected[tgt_idx] && !cfgq_full;

    always_comb begin
        cfgq_din  = {tgt_idx, w_addr_q[tgt_idx], reg_wdata};
        cfgq_push = win_data_ok;
        cfgq_pop  = (!out_valid_q || cfg_wr_ready) && !cfgq_empty;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cfgq_wp_q   <= '0;
            cfgq_rp_q   <= '0;
            out_valid_q <= 1'b0;
            out_data_q  <= '0;
        end else begin
            if (cfgq_push) begin
                cfgq[cfgq_wp_q[CFGQ_AW-1:0]] <= cfgq_din;
                cfgq_wp_q                    <= cfgq_wp_q + 1'b1;
            end
            if (out_valid_q && cfg_wr_ready) begin
                out_valid_q <= 1'b0;
            end
            if (cfgq_pop) begin
                out_data_q  <= cfgq[cfgq_rp_q[CFGQ_AW-1:0]];
                out_valid_q <= 1'b1;
                cfgq_rp_q   <= cfgq_rp_q + 1'b1;
            end
        end
    end

    assign cfg_wr_valid  = out_valid_q;
    assign cfg_wr_target = cfg_target_e'(out_data_q[50:48] + 3'd1);  // 0->NONE
    assign cfg_wr_addr   = out_data_q[47:32];
    assign cfg_wr_data   = out_data_q[31:0];

    // The config path is drained when nothing is queued, nothing is presented,
    // and the handshake is idle. ⚠ A commit MUST NOT be issued before this is
    // true, or the fabric could latch a half-written parameter set.
    logic cfg_path_idle;
    assign cfg_path_idle = cfgq_empty && !out_valid_q && cfg_wr_ready;

    // =========================================================================
    // Rate-limited pulse outputs
    // -----------------------------------------------------------------------------
    // cdc_pulse requires source pulses spaced by >= 2 DESTINATION clock periods
    // (manuals/00-foundations/04-*.md §3.2); closer together they MERGE and an
    // event is silently lost. pcie_clk is 250 MHz and core_clk is 156.25 MHz, so
    // the minimum safe spacing is ~4 pcie cycles. Each pulse class gets its own
    // pending flag and an 8-cycle hold-off, so a burst of host writes is paced
    // rather than lost — for credit_return, a lost pulse is a permanently leaked
    // in-flight credit slot.
    // =========================================================================
    logic       p_pend_q [NP];
    logic [2:0] p_hold_q [NP];
    logic       p_set    [NP];
    logic       p_gate   [NP];

    // =========================================================================
    // Arm FSM, control bits, sticky state
    // =========================================================================
    logic        kill_bit_q;          // CONTROL[1] as last written
    logic [15:0] arm_timer_q;         // ms remaining in the step1 window
    logic [2:0]  arm_fault_q;         // why the last arm attempt failed
    logic [31:0] scratch_q;
    logic [31:0] cfg_err_q;
    logic [31:0] cfg_err_cnt_q;
    logic [2:0]  last_kill_src_q;
    logic [2:0]  first_kill_src_q;
    logic        first_kill_seen_q;
    logic [7:0]  kill_ever_q;
    logic [31:0] kill_cnt_q;
    logic        kill_active_d_q;
    logic [31:0] telem_to_cnt_q;
    logic        telem_to_sticky_q;
    logic        cfg_err_sticky_q;

    // Preconditions for arming. ⚠ Arming is a POSITIVE action gated on positive
    // identification — "the card came up, probably fine" is not a state
    // (manuals/06-operations/01-build-and-release.md §4).
    logic arm_precond_ok;
    always_comb begin
        arm_precond_ok = w_valid_q[T_RISK]    && (w_gen_q[T_RISK]  != 16'd0) &&
                         w_valid_q[T_STRAT]   && (w_gen_q[T_STRAT] != 16'd0) &&
                         w_valid_q[T_FILTER]  &&
                         w_valid_q[T_TMPL]    &&
                         w_valid_q[T_SESSION] &&
                         !watchdog_expired    &&
                         core_alive           &&
                         pcie_link_up         &&
                         cfg_path_idle;
    end

    // Control-bit decode
    logic ctl_trading, ctl_kill, ctl_step1, ctl_step2, ctl_rstcnt, ctl_credit, ctl_clrsticky;
    always_comb begin
        ctl_trading   = wr_control && reg_wdata[0];
        ctl_kill      = wr_control && reg_wdata[1];
        ctl_step1     = wr_control && reg_wdata[2];
        ctl_step2     = wr_control && reg_wdata[3];
        ctl_rstcnt    = wr_control && reg_wdata[4];
        ctl_credit    = wr_control && reg_wdata[5];
        ctl_clrsticky = wr_control && reg_wdata[6];
    end

    // Window CTRL-bit decode
    logic win_reset_chk, win_commit, win_zero_addr, win_mark_valid;
    always_comb begin
        win_reset_chk  = wr_win_ctrl && reg_wdata[1];
        win_commit     = wr_win_ctrl && reg_wdata[2];
        win_zero_addr  = wr_win_ctrl && reg_wdata[3];
        win_mark_valid = wr_win_ctrl && reg_wdata[4];
    end

    // Commit is legal only for RISK and STRAT, and RISK only while disabled.
    always_comb begin
        p_set[P_HB]      = hb_write;
        p_set[P_CREDIT]  = ctl_credit;
        p_set[P_RCOMMIT] = win_commit && is_win_pg && (tgt_idx == 3'(T_RISK))  &&
                           !w_protected[T_RISK];
        p_set[P_SCOMMIT] = win_commit && is_win_pg && (tgt_idx == 3'(T_STRAT));

        p_gate[P_HB]      = 1'b1;
        p_gate[P_CREDIT]  = 1'b1;
        // ⚠ A commit pulse must not overtake the parameter writes it commits.
        //   Holding it until the write path has drained makes the ordering
        //   structural rather than a host-timing assumption.
        p_gate[P_RCOMMIT] = cfg_path_idle;
        p_gate[P_SCOMMIT] = cfg_path_idle;
    end

    // =========================================================================
    // Main register process
    // =========================================================================
    // Audit-event pending flags, priority 0 = highest (safety first).
    localparam int unsigned NEVT = 9;
    localparam int unsigned EVT_W = 4;              // $clog2(9) rounded up
    localparam int unsigned EV_KILL_ASSERT = 0;
    localparam int unsigned EV_WATCHDOG    = 1;
    localparam int unsigned EV_DISARM      = 2;
    localparam int unsigned EV_TRADING_DIS = 3;
    localparam int unsigned EV_ARM         = 4;
    localparam int unsigned EV_TRADING_EN  = 5;
    localparam int unsigned EV_RCOMMIT     = 6;
    localparam int unsigned EV_SCOMMIT     = 7;
    localparam int unsigned EV_KILL_CLEAR  = 8;

    logic [NEVT-1:0]  evt_pend_q;
    logic [NEVT-1:0]  evt_set;
    logic [NEVT-1:0]  evt_clr;
    logic [EVT_W-1:0] evt_pick;
    logic             evt_any;

    // Edge-detection registers. Every audit event is a TRANSITION, never a
    // level: a level would re-emit the same record every cycle and bury the
    // ring in duplicates of the one event you most need to see clearly.
    logic trading_en_eff_d_q;
    logic arm_armed_d_q;
    logic wdog_exp_d_q;

    // Telemetry-read timeout, raised by the read FSM below.
    localparam int unsigned TO_W = $clog2(TELEM_TIMEOUT + 1);
    logic telem_to_pulse;

    always_ff @(posedge clk) begin
        if (rst) begin
            // ═══ RESET = THE SAFE STATE ══════════════════════════════════════
            // Trading disabled, kill asserted (arm FSM in DISARMED), every
            // window generation zero so params_valid is false and arming is
            // refused, ring disabled, every checksum at its seed.
            // manuals/00-foundations/04-clocking-reset-and-cdc.md §4:
            // a bitstream reload must never come up armed.
            trading_en_q      <= 1'b0;
            kill_bit_q        <= 1'b1;
            arm_state_q       <= ARM_DISARMED;
            arm_timer_q       <= 16'd0;
            arm_fault_q       <= 3'd0;
            scratch_q         <= 32'd0;
            cfg_err_q         <= 32'd0;
            cfg_err_cnt_q     <= 32'd0;
            cfg_err_sticky_q  <= 1'b0;
            last_kill_src_q   <= 3'd0;
            first_kill_src_q  <= 3'd0;
            first_kill_seen_q <= 1'b0;
            kill_ever_q       <= 8'd0;
            kill_cnt_q        <= 32'd0;
            kill_active_d_q   <= 1'b0;
            ring_en           <= 1'b0;
            ring_base         <= 64'd0;
            ring_size_log2    <= 5'd0;
            ring_tail         <= 32'd0;
            ring_clr_sticky   <= 1'b0;
            telem_to_cnt_q    <= 32'd0;
            telem_to_sticky_q <= 1'b0;
            evt_pend_q        <= '0;
            trading_en_eff_d_q<= 1'b0;
            arm_armed_d_q     <= 1'b0;
            wdog_exp_d_q      <= 1'b1;   // expired at reset; no spurious edge
            for (int t = 0; t < NTGT; t++) begin
                w_addr_q[t]    <= 16'd0;
                w_autoinc_q[t] <= 1'b1;
                w_chk_q[t]     <= LOG_CHK_SEED;
                w_cmt_chk_q[t] <= 32'd0;
                w_gen_q[t]     <= 16'd0;
                w_cnt_q[t]     <= 16'd0;
                w_valid_q[t]   <= 1'b0;
            end
        end else begin
            ring_clr_sticky <= 1'b0;

            // ── sticky kill provenance ───────────────────────────────────────
            kill_active_d_q <= kill_active_s;
            if (kill_active_s && !kill_active_d_q) begin
                last_kill_src_q <= kill_src_s;
                kill_ever_q[kill_src_s] <= 1'b1;
                if (!first_kill_seen_q) begin
                    first_kill_seen_q <= 1'b1;
                    first_kill_src_q  <= kill_src_s;
                end
                if (kill_cnt_q != 32'hFFFF_FFFF) kill_cnt_q <= kill_cnt_q + 32'd1;
            end

            // ── CONTROL ──────────────────────────────────────────────────────
            if (ctl_kill) begin
                // ⚠ Writing kill=1 disarms IMMEDIATELY from any state, with no
                //   preconditions and no confirmation. That is the whole point
                //   of a kill switch (CLAUDE.md §5.6).
                kill_bit_q   <= 1'b1;
                trading_en_q <= 1'b0;
                arm_state_q  <= ARM_DISARMED;
                arm_timer_q  <= 16'd0;
            end else if (wr_control) begin
                kill_bit_q   <= 1'b0;
                trading_en_q <= reg_wdata[0];
            end

            if (ctl_clrsticky) begin
                cfg_err_q         <= 32'd0;
                cfg_err_sticky_q  <= 1'b0;
                telem_to_sticky_q <= 1'b0;
            end

            // ── two-step arm FSM ─────────────────────────────────────────────
            if (ms_tick && (arm_state_q == ARM_STEP1) && (arm_timer_q != 16'd0)) begin
                arm_timer_q <= arm_timer_q - 16'd1;
            end

            if (!ctl_kill) begin
                unique case (arm_state_q)
                    ARM_DISARMED: begin
                        if (ctl_step1 && ctl_step2) begin
                            // ⚠ Both halves in ONE bus write defeats the point.
                            arm_state_q <= ARM_FAULT;
                            arm_fault_q <= 3'd1;
                        end else if (ctl_step2) begin
                            arm_state_q <= ARM_FAULT;   // step2 without step1
                            arm_fault_q <= 3'd2;
                        end else if (ctl_step1) begin
                            if (arm_precond_ok) begin
                                arm_state_q <= ARM_STEP1;
                                arm_timer_q <= 16'(ARM_WINDOW_MS);
                            end else begin
                                arm_state_q <= ARM_FAULT;
                                arm_fault_q <= 3'd3;    // preconditions unmet
                            end
                        end
                    end

                    ARM_STEP1: begin
                        if (ctl_step2 && !ctl_step1) begin
                            if (arm_precond_ok) begin
                                arm_state_q <= ARM_ARMED;
                            end else begin
                                arm_state_q <= ARM_FAULT;
                                arm_fault_q <= 3'd3;
                            end
                        end else if (ctl_step1) begin
                            arm_state_q <= ARM_FAULT;   // step1 twice
                            arm_fault_q <= 3'd1;
                        end else if (arm_timer_q == 16'd0) begin
                            arm_state_q <= ARM_DISARMED; // window expired
                        end
                    end

                    ARM_ARMED: begin
                        // ⚠ Anything that invalidates the preconditions disarms.
                        if (watchdog_expired || !core_alive || !pcie_link_up) begin
                            arm_state_q  <= ARM_DISARMED;
                            trading_en_q <= 1'b0;
                        end
                    end

                    ARM_FAULT: begin
                        // Cleared only by an explicit kill write, above. A fault
                        // that clears itself teaches the operator nothing.
                        arm_state_q <= ARM_FAULT;
                    end

                    default: arm_state_q <= ARM_DISARMED;
                endcase
            end

            // ── scratch ──────────────────────────────────────────────────────
            if (wr_scratch) scratch_q <= reg_wdata;

            // ── DMA log ring configuration ───────────────────────────────────
            if (wr_ring_lo)   ring_base[31:0]  <= {reg_wdata[31:6], 6'd0};  // 64 B aligned
            if (wr_ring_hi)   ring_base[63:32] <= reg_wdata;
            if (wr_ring_size) begin
                if ((reg_wdata[4:0] >= 5'(LOG_RING_LOG2_MIN)) &&
                    (reg_wdata[4:0] <= 5'(LOG_RING_LOG2_MAX))) begin
                    ring_size_log2 <= reg_wdata[4:0];
                end else if (reg_wdata[4:0] == 5'd0) begin
                    ring_size_log2 <= 5'd0;      // explicit disable
                end
            end
            if (wr_ring_tail) ring_tail <= reg_wdata;
            if (wr_ring_ctrl) begin
                ring_en         <= reg_wdata[0];
                ring_clr_sticky <= reg_wdata[1];
            end

            // ── config write windows ─────────────────────────────────────────
            if (wr_win_addr && is_win_pg) begin
                w_addr_q[tgt_idx] <= reg_wdata[15:0];
            end

            if (win_data_ok) begin
                // Write-side checksum. Rotate-XOR over {data, addr}, seeded
                // non-zero. The host reproduces this over the words it INTENDED
                // to send; a mismatch means the BAR path corrupted, dropped or
                // reordered a write. Algorithm documented in ctrl/README.md.
                w_chk_q[tgt_idx] <= {w_chk_q[tgt_idx][30:0], w_chk_q[tgt_idx][31]}
                                    ^ reg_wdata
                                    ^ {16'd0, w_addr_q[tgt_idx]};
                if (w_cnt_q[tgt_idx] != 16'hFFFF) begin
                    w_cnt_q[tgt_idx] <= w_cnt_q[tgt_idx] + 16'd1;
                end
                if (w_autoinc_q[tgt_idx]) begin
                    w_addr_q[tgt_idx] <= w_addr_q[tgt_idx] + 16'd1;
                end
            end

            if (wr_win_ctrl && is_win_pg) begin
                w_autoinc_q[tgt_idx] <= reg_wdata[0];
                if (win_zero_addr)  w_addr_q[tgt_idx] <= 16'd0;
                if (win_reset_chk) begin
                    w_chk_q[tgt_idx] <= LOG_CHK_SEED;
                    w_cnt_q[tgt_idx] <= 16'd0;
                end
                if (win_mark_valid && !w_protected[tgt_idx]) begin
                    w_valid_q[tgt_idx] <= 1'b1;
                end
            end

            // Commit latches the checksum and bumps the generation. Latched on
            // the PULSE, not the request, so what is recorded is what the
            // fabric was actually told to commit — the write path is provably
            // drained by then (p_gate above). The host reads back CMT_CHK and
            // GEN to prove the fabric took what it sent.
            if (risk_commit_pulse) begin
                w_cmt_chk_q[T_RISK] <= w_chk_q[T_RISK];
                w_gen_q[T_RISK]     <= w_gen_q[T_RISK] + 16'd1;
                w_valid_q[T_RISK]   <= 1'b1;
            end
            if (strat_commit_pulse) begin
                w_cmt_chk_q[T_STRAT] <= w_chk_q[T_STRAT];
                w_gen_q[T_STRAT]     <= w_gen_q[T_STRAT] + 16'd1;
                w_valid_q[T_STRAT]   <= 1'b1;
            end

            // ── error accounting. ⚠ Every rejected write is counted; silence
            //    would let a script "configure" a card that ignored it. ──────
            if (wr_win_data && is_win_pg && w_protected[tgt_idx]) begin
                cfg_err_q[E_PROTECTED] <= 1'b1;
                cfg_err_sticky_q       <= 1'b1;
                if (cfg_err_cnt_q != 32'hFFFF_FFFF) cfg_err_cnt_q <= cfg_err_cnt_q + 32'd1;
            end
            if (wr_win_data && is_win_pg && !w_protected[tgt_idx] && cfgq_full) begin
                cfg_err_q[E_QUEUE] <= 1'b1;
                cfg_err_sticky_q   <= 1'b1;
                if (cfg_err_cnt_q != 32'hFFFF_FFFF) cfg_err_cnt_q <= cfg_err_cnt_q + 32'd1;
            end
            if ((ctl_step1 && ctl_step2) || (ctl_step2 && (arm_state_q == ARM_DISARMED))) begin
                cfg_err_q[E_ARM_SEQ] <= 1'b1;
                cfg_err_sticky_q     <= 1'b1;
            end
            if ((ctl_step1 || ctl_step2) && !arm_precond_ok) begin
                cfg_err_q[E_ARM_PRE] <= 1'b1;
                cfg_err_sticky_q     <= 1'b1;
            end
            if (wr_unmapped) begin
                cfg_err_q[E_UNMAPPED] <= 1'b1;
                cfg_err_sticky_q      <= 1'b1;
            end
            if (wr_ring_size && (reg_wdata[4:0] != 5'd0) &&
                ((reg_wdata[4:0] < 5'(LOG_RING_LOG2_MIN)) ||
                 (reg_wdata[4:0] > 5'(LOG_RING_LOG2_MAX)))) begin
                cfg_err_q[E_RING_CFG] <= 1'b1;
                cfg_err_sticky_q      <= 1'b1;
            end
            if (wr_cfg_err) begin
                cfg_err_q <= cfg_err_q & ~reg_wdata;   // W1C
            end

            // ── CONTROL[4] reset_counters ────────────────────────────────────
            // ⚠ This clears the CSR's own DIAGNOSTIC counters ONLY. It does NOT
            //   clear the fabric counters in telemetry, and there is no port in
            //   the fpga_top contract by which it could. That is deliberate and
            //   correct: fabric counters are free-running and the host computes
            //   deltas between snapshots. Clear-on-read and host-triggered
            //   clears lose every event between the read and the clear, and two
            //   collectors each see part of the truth
            //   (manuals/06-operations/03-monitoring-and-telemetry.md §9).
            //   The latency histogram is the one exception, cleared at start of
            //   day via the telemetry window's HIST_CLEAR address.
            if (ctl_rstcnt) begin
                cfg_err_cnt_q  <= 32'd0;
                telem_to_cnt_q <= 32'd0;
                kill_cnt_q     <= 32'd0;
                for (int t = 0; t < NTGT; t++) w_cnt_q[t] <= 16'd0;
            end

            // ── audit-event pending flags ────────────────────────────────────
            trading_en_eff_d_q <= trading_en_eff;
            arm_armed_d_q      <= (arm_state_q == ARM_ARMED);
            wdog_exp_d_q       <= watchdog_expired;
            evt_pend_q <= (evt_pend_q | evt_set) & ~evt_clr;

            if (telem_to_pulse) begin
                telem_to_sticky_q <= 1'b1;
                cfg_err_q[E_TELEM_TO] <= 1'b1;
                if (telem_to_cnt_q != 32'hFFFF_FFFF) telem_to_cnt_q <= telem_to_cnt_q + 32'd1;
            end
        end
    end

    // =========================================================================
    // Audit-event generation
    // -----------------------------------------------------------------------------
    // One record per cycle, strict priority, with a pending bit per class so a
    // coincidence never loses an event. Safety events (kill, watchdog, disarm)
    // outrank informational ones.
    // =========================================================================
    always_comb begin
        evt_set = '0;
        evt_set[EV_KILL_ASSERT] = kill_active_s && !kill_active_d_q;
        evt_set[EV_KILL_CLEAR]  = !kill_active_s && kill_active_d_q;
        evt_set[EV_WATCHDOG]    = watchdog_expired && !wdog_exp_d_q;
        evt_set[EV_DISARM]      = arm_armed_d_q && (arm_state_q != ARM_ARMED);
        evt_set[EV_ARM]         = !arm_armed_d_q && (arm_state_q == ARM_ARMED);
        evt_set[EV_TRADING_EN]  = trading_en_eff && !trading_en_eff_d_q;
        evt_set[EV_TRADING_DIS] = !trading_en_eff && trading_en_eff_d_q;
        evt_set[EV_RCOMMIT]     = risk_commit_pulse;
        evt_set[EV_SCOMMIT]     = strat_commit_pulse;
    end

    // Priority pick. Iterating downward means index 0 assigns last and
    // therefore wins — safety events outrank informational ones.
    logic evt_load;

    always_comb begin
        evt_pick = '0;
        evt_any  = 1'b0;
        evt_clr  = '0;
        for (int e = NEVT - 1; e >= 0; e--) begin
            if (evt_pend_q[e]) begin
                evt_pick = EVT_W'(e);
                evt_any  = 1'b1;
            end
        end
        // Only clear the pending bit once the record is actually loaded into
        // the output register — otherwise a busy downstream would silently
        // discard a compliance record.
        evt_load = evt_any && (!evt_valid || evt_ready);
        if (evt_load) evt_clr[evt_pick] = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            evt_valid  <= 1'b0;
            evt_type   <= 8'd0;
            evt_reason <= 8'd0;
            evt_aux0   <= 32'd0;
            evt_aux1   <= 32'd0;
        end else if (evt_valid && !evt_ready) begin
            evt_valid <= 1'b1;          // hold payload stable until accepted
        end else begin
            evt_valid  <= evt_any;
            evt_reason <= 8'd0;
            evt_aux0   <= 32'd0;
            evt_aux1   <= {16'd0, hb_age_q};
            case (evt_pick)
                EVT_W'(EV_KILL_ASSERT): begin
                    evt_type   <= 8'(LOG_KILL_ASSERT);
                    evt_reason <= {5'd0, kill_src_s};
                end
                EVT_W'(EV_WATCHDOG):    evt_type <= 8'(LOG_WATCHDOG);
                EVT_W'(EV_DISARM):      evt_type <= 8'(LOG_DISARM);
                EVT_W'(EV_TRADING_DIS): evt_type <= 8'(LOG_TRADING_DIS);
                EVT_W'(EV_ARM):         evt_type <= 8'(LOG_ARM);
                EVT_W'(EV_TRADING_EN):  evt_type <= 8'(LOG_TRADING_EN);
                EVT_W'(EV_RCOMMIT): begin
                    evt_type <= 8'(LOG_PARAM_COMMIT);
                    evt_aux0 <= w_cmt_chk_q[T_RISK];
                    evt_aux1 <= {8'd1, 8'd0, w_gen_q[T_RISK]};    // 1 = risk
                end
                EVT_W'(EV_SCOMMIT): begin
                    evt_type <= 8'(LOG_PARAM_COMMIT);
                    evt_aux0 <= w_cmt_chk_q[T_STRAT];
                    evt_aux1 <= {8'd2, 8'd0, w_gen_q[T_STRAT]};   // 2 = strategy
                end
                EVT_W'(EV_KILL_CLEAR):  evt_type <= 8'(LOG_KILL_CLEAR);
                default:                evt_type <= 8'd0;
            endcase
        end
    end

    // =========================================================================
    // Pulse pacing
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            hb_pulse           <= 1'b0;
            credit_ret_pulse   <= 1'b0;
            risk_commit_pulse  <= 1'b0;
            strat_commit_pulse <= 1'b0;
            counters_rst_pulse <= 1'b0;
            for (int k = 0; k < NP; k++) begin
                p_pend_q[k] <= 1'b0;
                p_hold_q[k] <= 3'd0;
            end
        end else begin
            hb_pulse           <= 1'b0;
            credit_ret_pulse   <= 1'b0;
            risk_commit_pulse  <= 1'b0;
            strat_commit_pulse <= 1'b0;
            counters_rst_pulse <= ctl_rstcnt;

            for (int k = 0; k < NP; k++) begin
                if (p_hold_q[k] != 3'd0) begin
                    p_hold_q[k] <= p_hold_q[k] - 3'd1;
                end else if (p_pend_q[k] && p_gate[k]) begin
                    p_pend_q[k] <= 1'b0;
                    p_hold_q[k] <= 3'd7;
                    case (k)
                        P_HB:      hb_pulse           <= 1'b1;
                        P_CREDIT:  credit_ret_pulse   <= 1'b1;
                        P_RCOMMIT: risk_commit_pulse  <= 1'b1;
                        P_SCOMMIT: strat_commit_pulse <= 1'b1;
                        default:   ;
                    endcase
                end
                // Set wins over clear: an event arriving in the same cycle as a
                // fire is still pending afterwards, never lost.
                if (p_set[k]) p_pend_q[k] <= 1'b1;
            end
        end
    end

    assign kill        = (arm_state_q != ARM_ARMED);
    assign arm_state_o = arm_state_q;

    // =========================================================================
    // Read path
    // =========================================================================
    logic [31:0] status_w;
    logic [31:0] killsrc_w;
    logic [31:0] control_w;
    logic [31:0] param_status_w;
    logic [31:0] arm_w;
    logic [31:0] rd_local;
    logic        params_valid;

    always_comb begin
        params_valid = w_valid_q[T_FILTER] && w_valid_q[T_RISK] &&
                       w_valid_q[T_STRAT]  && w_valid_q[T_TMPL] &&
                       w_valid_q[T_SESSION];

        status_w        = 32'd0;
        status_w[2:0]   = core_status_s[2:0];      // link_up, mirrored from core
        status_w[3]     = kill_active_s;
        status_w[6:4]   = kill_src_s;
        status_w[7]     = pcie_link_up;
        status_w[8]     = core_alive;
        status_w[11:9]  = arm_state_q;
        status_w[12]    = trading_en_eff;
        status_w[13]    = watchdog_expired;
        status_w[24]    = watchdog_warn;
        status_w[14]    = params_valid;
        status_w[15]    = !cfg_path_idle;
        status_w[16]    = w_valid_q[T_RISK];
        status_w[17]    = w_valid_q[T_STRAT];
        status_w[18]    = w_valid_q[T_FILTER];
        status_w[19]    = w_valid_q[T_TMPL];
        status_w[20]    = w_valid_q[T_SESSION];
        status_w[21]    = ring_drop_sticky;
        status_w[22]    = telem_to_sticky_q;
        status_w[23]    = cfg_err_sticky_q;

        killsrc_w        = 32'd0;
        killsrc_w[2:0]   = last_kill_src_q;
        killsrc_w[3]     = kill_active_s;
        killsrc_w[10:8]  = first_kill_src_q;
        killsrc_w[23:16] = kill_ever_q;

        control_w      = 32'd0;
        control_w[0]   = trading_en_q;
        control_w[1]   = kill_bit_q;

        param_status_w        = 32'd0;
        param_status_w[4:0]   = {w_valid_q[T_SESSION], w_valid_q[T_TMPL],
                                 w_valid_q[T_STRAT], w_valid_q[T_RISK],
                                 w_valid_q[T_FILTER]};
        param_status_w[12:8]  = {w_protected[T_SESSION], w_protected[T_TMPL],
                                 w_protected[T_STRAT], w_protected[T_RISK],
                                 w_protected[T_FILTER]};
        param_status_w[16]    = !cfg_path_idle;
        param_status_w[17]    = cfgq_full;

        arm_w         = 32'd0;
        arm_w[2:0]    = arm_state_q;
        arm_w[6:4]    = arm_fault_q;
        arm_w[7]      = arm_precond_ok;
        arm_w[31:16]  = arm_timer_q;

        // ── the mux ──────────────────────────────────────────────────────────
        rd_local = CSR_UNMAPPED;

        if (is_core_pg) begin
            case (off)
                8'h00:   rd_local = BUILD_ID;
                8'h04:   rd_local = GIT_SHA;
                8'h08:   rd_local = BUILD_TIMESTAMP;
                8'h0C:   rd_local = {TELEM_MAP_MAGIC, TELEM_MAP_MAJOR, TELEM_MAP_MINOR};
                8'h10:   rd_local = control_w;
                8'h14:   rd_local = status_w;
                8'h18:   rd_local = hb_seq_q;
                8'h1C:   rd_local = {16'(WATCHDOG_WARN_MS), 16'(WATCHDOG_MS)};
                8'h20:   rd_local = killsrc_w;
                8'h24:   rd_local = kill_cnt_q;
                8'h28:   rd_local = {16'd0, hb_age_q};
                8'h2C:   rd_local = scratch_q;
                8'h30:   rd_local = {w_gen_q[T_STRAT], w_gen_q[T_RISK]};
                8'h34:   rd_local = param_status_w;
                8'h38:   rd_local = {cfg_err_cnt_q[15:0], cfg_err_q[15:0]};
                8'h3C:   rd_local = arm_w;
                8'h40:   rd_local = ring_base[31:0];
                8'h44:   rd_local = ring_base[63:32];
                8'h48:   rd_local = {27'd0, ring_size_log2};
                8'h4C:   rd_local = ring_head;
                8'h50:   rd_local = ring_tail;
                8'h54:   rd_local = ring_drop_cnt;
                8'h58:   rd_local = ring_rec_cnt;
                8'h5C:   rd_local = {30'd0, ring_drop_sticky, ring_en};
                8'h60:   rd_local = ring_full_cnt;
                8'h64:   rd_local = telem_to_cnt_q;
                default: rd_local = 32'd0;
            endcase
        end else if (is_win_pg) begin
            case (off)
                W_ADDR:    rd_local = {16'd0, w_addr_q[tgt_idx]};
                W_DATA:    rd_local = 32'd0;              // write-only
                W_CTRL:    rd_local = {31'd0, w_autoinc_q[tgt_idx]};
                W_GEN:     rd_local = {w_cnt_q[tgt_idx], w_gen_q[tgt_idx]};
                W_WR_CHK:  rd_local = w_chk_q[tgt_idx];
                W_CMT_CHK: rd_local = w_cmt_chk_q[tgt_idx];
                W_STATUS:  rd_local = {14'd0, w_protected[tgt_idx],
                                       w_valid_q[tgt_idx], w_cnt_q[tgt_idx]};
                default:   rd_local = 32'd0;
            endcase
        end
    end

    // ── read FSM: local reads reply next cycle, telemetry reads are split ────
    typedef enum logic [1:0] {
        RD_IDLE  = 2'd0,
        RD_TELEM = 2'd1
    } rd_state_e;

    rd_state_e       rd_state_q;
    logic [TO_W-1:0] telem_to_ctr_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_state_q     <= RD_IDLE;
            reg_rvalid     <= 1'b0;
            reg_rdata      <= 32'd0;
            telem_req      <= 1'b0;
            telem_addr     <= TELEM_A_IDLE;
            telem_to_ctr_q <= '0;
            telem_to_pulse <= 1'b0;
        end else begin
            reg_rvalid     <= 1'b0;
            telem_req      <= 1'b0;
            telem_to_pulse <= 1'b0;

            unique case (rd_state_q)
                RD_IDLE: begin
                    if (reg_re) begin
                        if (is_telem) begin
                            telem_addr     <= {8'd0, telem_word};
                            telem_req      <= 1'b1;
                            telem_to_ctr_q <= '0;
                            rd_state_q     <= RD_TELEM;
                        end else begin
                            reg_rdata  <= rd_local;
                            reg_rvalid <= 1'b1;
                        end
                    end
                end

                RD_TELEM: begin
                    telem_to_ctr_q <= telem_to_ctr_q + 1'b1;
                    if (telem_ack) begin
                        reg_rdata  <= telem_data;
                        reg_rvalid <= 1'b1;
                        rd_state_q <= RD_IDLE;
                    end else if (telem_to_ctr_q >= TO_W'(TELEM_TIMEOUT)) begin
                        // ⚠ The core domain did not answer. Return a distinctive
                        //   sentinel, count it, and set a sticky flag — never
                        //   hang the PCIe read, which would wedge the host.
                        reg_rdata      <= CSR_TELEM_TO;
                        reg_rvalid     <= 1'b1;
                        telem_to_pulse <= 1'b1;
                        rd_state_q     <= RD_IDLE;
                    end
                end

                default: rd_state_q <= RD_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSED */
    logic csr_unused;
    assign csr_unused = &{1'b1, core_status_s[31:3], reg_addr[1:0], off[1:0]};
    /* verilator lint_on UNUSED */

    // =========================================================================
    // Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS
    // ⚠ THE reset invariant (CLAUDE.md §5.4, manual 00.04 §4).
    assert property (@(posedge clk)
        rst |-> (kill && !trading_en)
    ) else $error("csr_regfile: FATAL - not fail-closed during reset");

    // Trading can never be effectively enabled unless armed.
    assert property (@(posedge clk) disable iff (rst)
        trading_en |-> (arm_state_q == ARM_ARMED)
    ) else $error("csr_regfile: trading enabled while not armed");

    // kill is the complement of ARMED, always. No third state.
    assert property (@(posedge clk) disable iff (rst)
        kill == (arm_state_q != ARM_ARMED)
    ) else $error("csr_regfile: kill and arm state disagree");

    // A kill write disarms within one cycle. Unconditionally.
    assert property (@(posedge clk) disable iff (rst)
        ctl_kill |=> ((arm_state_q == ARM_DISARMED) && kill && !trading_en)
    ) else $error("csr_regfile: kill write did not disarm immediately");

    // The watchdog BLOCKS. Expired heartbeat must not coexist with armed.
    assert property (@(posedge clk) disable iff (rst)
        watchdog_expired |=> (arm_state_q != ARM_ARMED)
    ) else $error("csr_regfile: armed with an expired host heartbeat");

    // ⚠ The four-eyes-supporting mechanism: a risk write while enabled changes
    //    nothing and is counted.
    assert property (@(posedge clk) disable iff (rst)
        (wr_win_data && (tgt_idx == 3'(T_RISK)) && trading_en)
            |=> (cfg_err_q[E_PROTECTED] && $stable(w_gen_q[T_RISK]))
    ) else $error("csr_regfile: a risk parameter write was accepted while trading was enabled");

    // A commit never overtakes the writes it commits.
    assert property (@(posedge clk) disable iff (rst)
        (risk_commit_pulse || strat_commit_pulse) |-> cfg_path_idle
    ) else $error("csr_regfile: commit pulse issued before the write path drained");

    // Pulse outputs must be single-cycle and spaced for cdc_pulse.
    assert property (@(posedge clk) disable iff (rst)
        hb_pulse |=> !hb_pulse
    ) else $error("csr_regfile: heartbeat pulse was not one cycle");

    // ⚠ cdc_pulse merges pulses closer than ~2 core-clock periods. The hold-off
    //    counter guarantees >= 8 pcie cycles between fires; check it, because a
    //    merged credit_return permanently leaks an in-flight order slot.
    assert property (@(posedge clk) disable iff (rst)
        credit_ret_pulse |=> !credit_ret_pulse
    ) else $error("csr_regfile: credit return pulse was not one cycle");

    assert property (@(posedge clk) disable iff (rst)
        credit_ret_pulse |-> (p_hold_q[P_CREDIT] == 3'd7)
    ) else $error("csr_regfile: credit return fired without arming the hold-off");

    // A local register read must always be answered on the next cycle. A hung
    // read wedges the host; the telemetry window has its own timeout path.
    assert property (@(posedge clk) disable iff (rst)
        (reg_re && !is_telem) |=> reg_rvalid
    ) else $error("csr_regfile: a local register read was not answered");

    // Two-step arm: ARMED is only ever reached from STEP1.
    assert property (@(posedge clk) disable iff (rst)
        (arm_state_q == ARM_ARMED) && ($past(arm_state_q) != ARM_ARMED)
            |-> ($past(arm_state_q) == ARM_STEP1)
    ) else $error("csr_regfile: armed without passing through step 1");
`endif

endmodule : csr_regfile

`default_nettype wire
