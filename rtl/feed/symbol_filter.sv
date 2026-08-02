// =============================================================================
// symbol_filter.sv — ITCH stock locate -> compact active-set index, or reject
// -----------------------------------------------------------------------------
// Project : FPGA Algorithmic Trading System (Nasdaq Equities)
// Governs : manuals/04-system-architecture/02-feed-handler-design.md  §7
//           manuals/08-nasdaq/04-totalview-itch-5.0.md
//           manuals/00-foundations/03-hdl-and-rtl-coding.md
// Layer   : rtl/feed — see rtl/feed/README.md
//
// PURPOSE
//   Map the raw 16-bit ITCH Stock Locate to a compact trading_pkg::sym_idx_t
//   (0 .. N_ACTIVE-1), or reject the message.
//
// -----------------------------------------------------------------------------
// ⚠️  WHY THIS IS A DIRECT-INDEX BRAM READ AND NOT A HASH OR A CAM
//
//   NASDAQ STOCK LOCATE CODES ARE DENSE INTEGERS. The venue assigns them
//   sequentially over the securities in the session (they are published in the
//   Stock Directory 'R' messages at start of day). They are not sparse, not
//   random, and not adversarial.
//
//   That single fact is what makes the entire symbol lookup in this system
//   cheap. A dense integer key is a MEMORY ADDRESS:
//
//       act_idx = table[locate]        <- 1 cycle, 2 BRAM36, zero collisions
//
//   The alternatives all cost more and buy nothing:
//     • Hash table   — needs collision handling, which is either a variable
//                      number of probes (jitter on the fast path — forbidden)
//                      or a bounded-probe scheme that can spuriously reject.
//     • CAM / TCAM   — N comparators in parallel; large, slow, and its Fmax
//                      degrades with the number of entries.
//     • Assoc. cache — a miss path is a stall, and the RX path cannot stall.
//
//   The table is N_SYMBOLS entries deep, covering the whole locate space, so
//   there is no key that needs special handling. Read, done, fixed latency.
//
//   ⚠️ If a future venue or protocol version makes locate codes sparse, this
//      design does NOT degrade gracefully — the table must be resized or the
//      lookup replaced. Do not "fix" a sparse key space by hashing into this
//      table; that reintroduces collisions the rest of the design assumes away.
// -----------------------------------------------------------------------------
// ⚠️  WHY THE FILTER IS HERE AND NOT LATER
//   We trade ~N_ACTIVE symbols out of an ~N_SYMBOLS universe. The overwhelming
//   majority of every packet is work we should never do. Dropping here — before
//   the order-ID map, before the level RMW, before top-of-book, before the
//   strategy — saves ~7 of the 20 fabric cycles of pipeline OCCUPANCY per
//   filtered message, and it is what makes the direct-index book memory
//   affordable (the book is sized by N_ACTIVE, not by N_SYMBOLS).
//
//   Note carefully: filtering does NOT reduce latency for a symbol we do trade.
//   It reduces occupancy (which protects us from queueing jitter) and memory.
//   Those are the reasons and they are sufficient.
//
//   This works for EVERY message type — including Order Executed / Cancel /
//   Delete, which carry no symbol string — because Stock Locate is at bytes
//   1..2 of the invariant ITCH prefix. The filter therefore has no dependency
//   on the decode. Asserted below (p_locate_present is enforced upstream).
// -----------------------------------------------------------------------------
// LATENCY
//   1 cycle, fixed, on BOTH ports. 6.4 ns @ 156.25 MHz.
//   Initiation interval = 1.
//   ACHIEVED: 1 cycle (synchronous BRAM read; the BRAM output register IS the
//   output register for the `sym` field, so no extra stage is spent merging).
//   Budget row: fpga_top.sv "Symbol filter + active-index map 1 cyc".
//
// RESOURCE ESTIMATE (unmeasured, pre-synthesis)
//   LUT ~80   FF ~230   BRAM36 ~4   URAM 0   DSP 0
//   Two physically separate copies of an N_SYMBOLS x (1 + ACT_IDX_W) table,
//   written in lockstep, so port A (fast path) and port B (venue path) each get
//   a clean, hazard-free, single-cycle read. At N_SYMBOLS = 8192 and
//   ACT_IDX_W = 8 that is 2 x 73,728 bit = ~4 BRAM36. Duplication is cheaper
//   and far simpler than arbitrating one port between two readers.
//
// OUTPUT REGISTERING — DELIBERATE EXCEPTION (coding standard §5)
//   m_evt is fully registered: the body comes from the pipeline register
//   `evt_q` and the `sym` field comes straight off the BRAM output register.
//   The merge is pure rewiring, zero logic.
//   m_valid / q_hit are ONE 2-input LUT off two flip-flops (the pipeline valid
//   and the BRAM output register's valid bit). Registering them would add a
//   cycle to the tick-to-trade path for one LUT level. The exception is
//   intentional.
// =============================================================================
`default_nettype none

module symbol_filter
    import trading_pkg::*;
#(
    // Depth of the locate table. Must cover the venue's locate space.
    parameter int unsigned N_LOCATE = N_SYMBOLS
) (
    input  var logic        clk,
    input  var logic        rst,        // synchronous, active high

    // ── Port A: book-event stream (fast path) ────────────────────────────────
    input  var book_evt_t   s_evt,      // .locate populated, .sym ignored
    input  var logic        s_valid,
    output var book_evt_t   m_evt,      // .sym filled in
    output var logic        m_valid,    // asserted only on a HIT
    // Telemetry pulses, aligned with m_valid
    output var logic        m_miss,     // not subscribed  — NORMAL, not an error
    output var logic        m_bad_locate, // locate == 0 or >= N_LOCATE — ERROR

    // ── Port B: raw locate lookup (venue-state path, not latency critical) ───
    input  var locate_t     q_locate,
    input  var logic        q_valid,
    output var sym_idx_t    q_sym,
    output var logic        q_hit,      // 0 for locate 0 (global messages)
    output var logic        q_valid_o,

    // ── Host table load ──────────────────────────────────────────────────────
    // The host builds this table at session start from the ITCH Stock Directory
    // ('R') messages intersected with our traded-universe config file, then
    // writes one entry per subscribed locate.
    //   cfg_addr[LOC_AW-1:0] = stock locate code
    //   cfg_data[0]          = subscribed (1 = trade this symbol)
    //   cfg_data[8 +: ACT_IDX_W] = compact active-set index
    input  var logic        cfg_clk,
    input  var logic        cfg_wr,
    /* verilator lint_off UNUSED */
    input  var logic [15:0] cfg_addr,   // upper bits are the region select
    input  var logic [31:0] cfg_data    // reserved bits unused by design
    /* verilator lint_on UNUSED */
);

    // =========================================================================
    // 1. Table geometry
    // =========================================================================
    localparam int unsigned LOC_AW = $clog2(N_LOCATE);      // 13 @ 8192
    localparam int unsigned ENT_W  = 1 + ACT_IDX_W;         //  9 @ N_ACTIVE=256

    // Entry layout: {subscribed, active_index}
    localparam int unsigned ENT_VALID_BIT = ENT_W - 1;

    // ⚠️ Nasdaq assigns stock locate codes starting at 1. Locate 0 means
    //    "not applicable" and is used by the global messages ('S', 'V', 'W').
    //    It is NEVER a subscribed symbol, and we enforce that here rather than
    //    trusting the host to leave entry 0 clear. Without this, a stray host
    //    write to entry 0 would route every global message into a real symbol's
    //    book.
    localparam locate_t LOCATE_NONE = 16'd0;

    logic [ENT_W-1:0] tab_a_q [N_LOCATE];   // read by port A
    logic [ENT_W-1:0] tab_b_q [N_LOCATE];   // read by port B

    // ⚠️ FAIL-CLOSED POWER-ON STATE. BRAM contents are NOT cleared by `rst` —
    //    a synchronous reset cannot touch a memory array. The only way to
    //    guarantee the table starts empty is memory initialisation, which both
    //    Vivado and Quartus honour from an `initial` block (it becomes the
    //    BRAM INIT strings). Every entry invalid => every message filtered =>
    //    nothing reaches the book until the host has loaded the table.
    initial begin
        for (int unsigned i = 0; i < N_LOCATE; i++) begin
            tab_a_q[i] = '0;
            tab_b_q[i] = '0;
        end
    end

    // =========================================================================
    // 2. Host write port
    // -------------------------------------------------------------------------
    // ⚠️ cfg_clk MUST be the same clock as clk. fpga_top ties both to core_clk
    //    and host_ctrl performs ALL CDC on its own side (fpga_top.sv: "all CDC
    //    lives inside this module"). The separate clock port exists so the
    //    table load can later move into the PCIe domain without changing this
    //    module's interface — the memory is written on one clock and read on
    //    another, which is exactly what a dual-clock BRAM does natively.
    //    If they are ever made different, the host must not write while
    //    trading: read data is undefined for a simultaneous access to the same
    //    address from two clocks.
    // =========================================================================
    logic [LOC_AW-1:0] cfg_idx;
    logic              cfg_in_range;
    logic [ENT_W-1:0]  cfg_ent;

    assign cfg_idx      = cfg_addr[LOC_AW-1:0];
    assign cfg_in_range = (cfg_addr[15:LOC_AW] == '0);
    assign cfg_ent      = {cfg_data[0], cfg_data[8 +: ACT_IDX_W]};

    always_ff @(posedge cfg_clk) begin
        if (cfg_wr && cfg_in_range) begin
            // Lockstep write: the two copies are never allowed to diverge.
            tab_a_q[cfg_idx] <= cfg_ent;
            tab_b_q[cfg_idx] <= cfg_ent;
        end
    end

    // =========================================================================
    // 3. Port A — book-event stream
    // =========================================================================
    locate_t           a_loc;
    logic              a_bad;
    logic [LOC_AW-1:0] a_idx;

    assign a_loc = s_evt.locate;
    assign a_bad = (a_loc == LOCATE_NONE) || (a_loc >= locate_t'(N_LOCATE));
    assign a_idx = a_loc[LOC_AW-1:0];

    book_evt_t         evt_q;
    logic              valid_q;
    logic              bad_q;
    logic [ENT_W-1:0]  ent_a_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_q <= 1'b0;
            bad_q   <= 1'b0;
        end else begin
            valid_q <= s_valid;
            bad_q   <= s_valid && a_bad;
        end

        // Datapath: no reset. Clock-enabled so the BRAM and the 300-bit event
        // register stay quiet between messages.
        if (s_valid) begin
            evt_q   <= s_evt;
            ent_a_q <= tab_a_q[a_idx];     // 1-cycle synchronous read
        end
    end

    // m_evt: pure rewiring of two register banks. The `sym` field is the BRAM
    // output register itself — no combinational logic on the datapath.
    always_comb begin
        m_evt     = evt_q;
        m_evt.sym = ent_a_q[ACT_IDX_W-1:0];
    end

    assign m_valid      = valid_q && !bad_q &&  ent_a_q[ENT_VALID_BIT];
    assign m_miss       = valid_q && !bad_q && !ent_a_q[ENT_VALID_BIT];
    assign m_bad_locate = valid_q &&  bad_q;

    // =========================================================================
    // 4. Port B — raw locate lookup for the venue-state path
    // -------------------------------------------------------------------------
    // Global ITCH messages ('S' System Event, 'V'/'W' MWCB) carry locate 0.
    // That is normal, not an error: q_hit simply reads 0 and venue_state routes
    // them to the global session state instead of a per-symbol record.
    // =========================================================================
    logic              b_bad;
    logic [LOC_AW-1:0] b_idx;

    assign b_bad = (q_locate == LOCATE_NONE) || (q_locate >= locate_t'(N_LOCATE));
    assign b_idx = q_locate[LOC_AW-1:0];

    logic [ENT_W-1:0] ent_b_q;
    logic             qvalid_q;
    logic             qbad_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            qvalid_q <= 1'b0;
            qbad_q   <= 1'b0;
        end else begin
            qvalid_q <= q_valid;
            qbad_q   <= q_valid && b_bad;
        end

        if (q_valid) begin
            ent_b_q <= tab_b_q[b_idx];     // 1-cycle synchronous read
        end
    end

    assign q_sym     = ent_b_q[ACT_IDX_W-1:0];
    assign q_hit     = qvalid_q && !qbad_q && ent_b_q[ENT_VALID_BIT];
    assign q_valid_o = qvalid_q;

    // =========================================================================
    // 5. Assertions — simulation only
    // =========================================================================
`ifndef SYNTHESIS

    // Fixed 1-cycle latency, exactly one outcome per input.
    p_a_one_cycle: assert property (@(posedge clk) disable iff (rst)
        s_valid |=> (m_valid ^ m_miss ^ m_bad_locate)
    ) else $error("symbol_filter: port A input did not resolve to exactly one outcome in 1 cycle");

    p_b_one_cycle: assert property (@(posedge clk) disable iff (rst)
        q_valid |=> q_valid_o
    ) else $error("symbol_filter: port B lookup latency is not 1 cycle");

    // Outcomes are mutually exclusive.
    p_a_exclusive: assert property (@(posedge clk) disable iff (rst)
        $onehot0({m_valid, m_miss, m_bad_locate})
    ) else $error("symbol_filter: hit / miss / bad_locate are not mutually exclusive");

    // The event body must pass through untouched apart from `sym`. Sample a
    // couple of load-bearing fields.
    p_body_preserved: assert property (@(posedge clk) disable iff (rst)
        (valid_q && $past(s_valid)) |->
            ((m_evt.order_ref == $past(s_evt.order_ref)) &&
             (m_evt.rx_cycle  == $past(s_evt.rx_cycle))  &&
             (m_evt.locate    == $past(s_evt.locate))    &&
             (m_evt.op        == $past(s_evt.op)))
    ) else $error("symbol_filter: event body was modified in transit");

    // ⚠️ Locate 0 is never a tradeable symbol on either port.
    p_a_locate_zero: assert property (@(posedge clk) disable iff (rst)
        (s_valid && (s_evt.locate == LOCATE_NONE)) |=> !m_valid
    ) else $error("symbol_filter: locate 0 was accepted as a tradeable symbol");

    p_b_locate_zero: assert property (@(posedge clk) disable iff (rst)
        (q_valid && (q_locate == LOCATE_NONE)) |=> !q_hit
    ) else $error("symbol_filter: locate 0 was accepted as a tradeable symbol on port B");

    // A hit must never present an out-of-range active index. Structurally true
    // while ACT_IDX_W == $clog2(N_ACTIVE); this catches an edit that breaks it.
    p_sym_in_range: assert property (@(posedge clk) disable iff (rst)
        m_valid |-> ({{(32-ACT_IDX_W){1'b0}}, m_evt.sym} < 32'(N_ACTIVE))
    ) else $error("symbol_filter: active index out of range");

    // The two table copies must never diverge. Checked on every write.
    p_tables_match: assert property (@(posedge cfg_clk)
        (cfg_wr && cfg_in_range) |=> (tab_a_q[$past(cfg_idx)] == tab_b_q[$past(cfg_idx)])
    ) else $error("symbol_filter: table copies diverged");

`endif

endmodule : symbol_filter

`default_nettype wire
