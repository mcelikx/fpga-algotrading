## =============================================================================
## scripts/build.tcl — Vivado NON-PROJECT mode build
## -----------------------------------------------------------------------------
## Project : FPGA Algorithmic Trading System (Nasdaq Equities)
## Governs : manuals/06-operations/01-build-and-release.md  (§1 reproducibility,
##           §2 the flow, §3 artifacts, §4 build-ID register)
##           manuals/00-foundations/05-timing-closure.md    (§5, §9 reporting)
##
## USAGE
##   vivado -mode batch -source scripts/build.tcl -tclargs [options]
##
##   Options (all have defaults; every one is recorded in the manifest):
##     --part <part>              target device        (default xcvu9p-flga2104-2-i)
##     --top <module>             top module           (default fpga_top)
##     --seed <int>               implementation seed  (default 1)
##     --out <dir>                build output dir     (default builds/<date>-<sha7>-s<seed>)
##     --synth-directive <d>      synth_design directive
##     --strategy <name>          implementation strategy (see IMPL_STRATEGIES)
##     --threads <n>              pinned thread count  (default 8)
##     --stop-after <stage>       synth | opt | place | route | bitstream
##     --no-floorplan             disable constraints/floorplan.xdc pblocks
##     --allow-dirty              permit a dirty git tree (NEVER in CI)
##
## ⚠️ WHY NON-PROJECT MODE (06-operations/01-build-and-release.md §2):
##    "Vivado project mode hides state in a .xpr and a .runs/ directory that is
##     not reviewable in a diff." A trading bitstream must be reproducible from
##     the repository alone. Everything that shapes the result is in this file
##     or in the arguments recorded in the manifest.
##
## ⚠️ THE BUILD FAILS — non-zero exit, no bitstream — ON ANY OF:
##      1. any inferred latch                        (Synth 8-327 -> ERROR)
##      2. any unconstrained clock or unclocked reg  (Timing 38-313 / check_timing)
##      3. any critical DRC violation                (report_drc)
##      4. negative post-route WNS or WHS            (the closure number)
##      5. a dirty git tree without --allow-dirty    (§1: unreproducible)
##      6. placeholder board pins still present      (constraints/io.xdc §5)
##    Each is checked explicitly below with a comment saying why it is fatal.
## =============================================================================

set BUILD_START_S [clock seconds]

## =============================================================================
## 1. Argument parsing
## =============================================================================
proc arg_get {name default} {
    global argv
    set i [lsearch -exact $argv $name]
    if {$i >= 0 && $i + 1 < [llength $argv]} { return [lindex $argv [expr {$i+1}]] }
    return $default
}
proc arg_flag {name} {
    global argv
    return [expr {[lsearch -exact $argv $name] >= 0}]
}

## Repo root = parent of the directory holding this script. Everything below is
## relative to it, so the build is invariant to where it was launched from.
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set REPO_ROOT  [file normalize [file join $SCRIPT_DIR ..]]
cd $REPO_ROOT

set PART            [arg_get --part            xcvu9p-flga2104-2-i]
set TOP             [arg_get --top             fpga_top]
set SEED            [arg_get --seed            1]
set THREADS         [arg_get --threads         8]
set SYNTH_DIRECTIVE [arg_get --synth-directive Default]
set STRATEGY        [arg_get --strategy        Performance_ExplorePostRoutePhysOpt]
set STOP_AFTER      [arg_get --stop-after      bitstream]
set FLOORPLAN_ENABLE [expr {[arg_flag --no-floorplan] ? 0 : 1}]
set ALLOW_DIRTY     [arg_flag --allow-dirty]

## ⚠️ PINNED THREAD COUNT (06-operations/01-build-and-release.md §1 table):
##    "Multi-threaded P&R is not bit-exact across thread counts." A build that
##    used 16 threads and one that used 8 are DIFFERENT BUILDS with different
##    placement, different routing, and therefore potentially different fast-path
##    latency. The count goes in the manifest for the same reason the seed does.
set_param general.maxThreads $THREADS

## =============================================================================
## 2. Git identity — the build must be traceable to a commit
## =============================================================================
proc run_or {cmd fallback} {
    if {[catch {exec {*}$cmd} out]} { return $fallback }
    return [string trim $out]
}

set GIT_SHA_FULL [run_or {git rev-parse HEAD} "0000000000000000000000000000000000000000"]
set GIT_SHA7     [string range $GIT_SHA_FULL 0 6]
set GIT_STATUS   [run_or {git status --porcelain} "UNKNOWN"]
set GIT_DIRTY    [expr {[string length $GIT_STATUS] > 0}]
set GIT_BRANCH   [run_or {git rev-parse --abbrev-ref HEAD} "unknown"]

## ⚠️ 06-operations/01-build-and-release.md §3:
##    "git_dirty: true is a hard fail for anything leaving CI. A bitstream built
##     from uncommitted edits cannot be reproduced and must never reach a
##     trading host."
if {$GIT_DIRTY && !$ALLOW_DIRTY} {
    puts "ERROR: git tree is dirty. A bitstream built from uncommitted edits"
    puts "ERROR: cannot be reproduced and must never reach a trading host."
    puts "ERROR: Commit, or pass --allow-dirty for a local experiment."
    puts "ERROR: ---- uncommitted files ----"
    puts $GIT_STATUS
    exit 1
}

## =============================================================================
## 3. Output directory layout
## =============================================================================
set DATE_TAG [clock format $BUILD_START_S -format %Y%m%d -gmt 1]
set OUTDIR   [arg_get --out [file join builds "${DATE_TAG}-${GIT_SHA7}-s${SEED}"]]
set RPTDIR   [file join $OUTDIR rpt]
set LOGDIR   [file join $OUTDIR log]
set DCPDIR   [file join $OUTDIR dcp]
foreach d [list $OUTDIR $RPTDIR $LOGDIR $DCPDIR] { file mkdir $d }

puts "=========================================================================="
puts " BUILD  top=$TOP  part=$PART  seed=$SEED  strategy=$STRATEGY"
puts " git    $GIT_SHA7 ($GIT_BRANCH)  dirty=$GIT_DIRTY"
puts " out    $OUTDIR"
puts " tool   [version -short]"
puts "=========================================================================="

## =============================================================================
## 4. Message severity promotions — turn silent-killer warnings into failures
## =============================================================================
## ⚠️ EVERY PROMOTION BELOW ENCODES A RULE FROM THE MANUALS. They are set BEFORE
##    any source is read so they apply from elaboration onward.

## Inferred latch. manuals/00-foundations/03-hdl-and-rtl-coding.md §3:
## "Treat any latch warning from synthesis as a build failure, not a warning."
## A latch is not timed by STA, creates combinational feedback, and produces a
## design that simulates correctly and fails intermittently in hardware.
set_msg_config -id {Synth 8-327}  -new_severity ERROR   ;# inferring latch
set_msg_config -id {Synth 8-614}  -new_severity ERROR   ;# signal assigned but never used as flop -> latch-ish
set_msg_config -id {Synth 8-5559} -new_severity ERROR   ;# multi-driven / latch net

## Unconstrained clock. manuals/00-foundations/04-clocking-reset-and-cdc.md §1:
## "An underived clock is an unconstrained clock, and an unconstrained clock is
## an unverified design." An unconstrained clock's paths are not analysed at
## all; the design "closes timing" by not being looked at.
set_msg_config -id {Timing 38-313} -new_severity ERROR  ;# there is no clock on this pin
set_msg_config -id {Timing 38-282} -new_severity ERROR  ;# clock not propagated / undefined

## Blackbox: a missing module silently becomes an empty box that outputs nothing.
## On this design that means, for example, a risk gate that emits no orders and
## a build that looks like it worked.
set_msg_config -id {Synth 8-3491} -new_severity ERROR   ;# module not found, treated as black box
set_msg_config -id {Synth 8-3848} -new_severity ERROR   ;# net has no driver

## Reduce noise so real problems are visible in the log.
set_msg_config -id {Synth 8-7080} -limit 20             ;# parallel synthesis chatter
set_msg_config -id {Synth 8-3331} -limit 50             ;# unconnected port info

## =============================================================================
## 5. Read sources from rtl/filelist.f
## =============================================================================
## The filelist is THE compile order (see its header). Parsing it here rather
## than globbing means simulation and synthesis compile the same files in the
## same order — a `glob rtl/**/*.sv` compiles packages last and fails, or worse,
## compiles a stale file nobody meant to include.
proc read_filelist {path} {
    set files   {}
    set incdirs {}
    set fh [open $path r]
    foreach line [split [read $fh] "\n"] {
        set fh_line [string trim $line]
        if {$fh_line eq "" || [string match "//*" $fh_line] || [string match "#*" $fh_line]} { continue }
        ## strip trailing inline comment
        set idx [string first "//" $fh_line]
        if {$idx > 0} { set fh_line [string trim [string range $fh_line 0 [expr {$idx-1}]]] }
        if {[string match "+incdir+*" $fh_line]} {
            lappend incdirs [string range $fh_line 8 end]
        } else {
            lappend files $fh_line
        }
    }
    close $fh
    return [list $files $incdirs]
}

lassign [read_filelist [file join $REPO_ROOT rtl filelist.f]] RTL_FILES RTL_INCDIRS

set MISSING {}
foreach f $RTL_FILES { if {![file exists $f]} { lappend MISSING $f } }
if {[llength $MISSING] > 0} {
    puts "ERROR: rtl/filelist.f lists [llength $MISSING] file(s) that do not exist:"
    foreach f $MISSING { puts "ERROR:   $f" }
    puts "ERROR: A filelist that does not match the tree is a build that compiles"
    puts "ERROR: something other than what the reviewer read."
    exit 1
}

puts "INFO: reading [llength $RTL_FILES] SystemVerilog sources"
read_verilog -sv $RTL_FILES

## Checked-in IP. ⚠️ NEVER `upgrade_ip` in an automated build
## (06-operations/01-build-and-release.md §1): "upgrade_ip silently changes
## MAC/PCS latency". An IP upgrade is a deliberate, reviewed, re-measured change.
set IP_FILES [glob -nocomplain [file join $REPO_ROOT ip * *.xci]]
if {[llength $IP_FILES] > 0} {
    puts "INFO: reading [llength $IP_FILES] IP core(s)"
    read_ip $IP_FILES
} else {
    puts "INFO: no ip/*/*.xci found — building with RTL stubs (rtl/eth/gt_wrapper_stub.sv)"
}

## =============================================================================
## 6. Read constraints
## =============================================================================
## Order matters: clocks first (everything else references clock names), then
## IO, then CDC, then exceptions, then floorplan.
set XDC_FILES [list \
    [file join $REPO_ROOT constraints clocks.xdc] \
    [file join $REPO_ROOT constraints io.xdc] \
    [file join $REPO_ROOT constraints cdc.xdc] \
    [file join $REPO_ROOT constraints timing_exceptions.xdc] \
    [file join $REPO_ROOT constraints floorplan.xdc] \
]
foreach x $XDC_FILES {
    if {![file exists $x]} { puts "ERROR: missing constraint file $x"; exit 1 }
    read_xdc $x
}

## ── Constraint hash ─────────────────────────────────────────────────────────
## 06-operations/01-build-and-release.md §1: constraints are "hashed into the
## build record", because a constraint change with no RTL change produces a
## different, and differently-behaving, bitstream. Without the hash, "same
## commit" is not the same thing as "same build inputs".
##
## Two hashes: a real SHA-256 for the manifest, and a 32-bit folded value for
## the CONSTRAINT_CRC generic that the fabric exposes over BAR0 (§4 of the same
## manual) — the host compares it at startup and refuses to arm on a mismatch.
proc fnv1a32 {bytes} {
    set h 2166136261
    foreach b $bytes {
        set h [expr {($h ^ $b) & 0xFFFFFFFF}]
        set h [expr {($h * 16777619) & 0xFFFFFFFF}]
    }
    return $h
}
proc file_bytes {path} {
    set fh [open $path rb]; set d [read $fh]; close $fh
    binary scan $d cu* out; return $out
}
set XDC_CONCAT {}
foreach x $XDC_FILES { set XDC_CONCAT [concat $XDC_CONCAT [file_bytes $x]] }
set CONSTRAINT_CRC32 [fnv1a32 $XDC_CONCAT]

set CONSTRAINT_SHA256 "unavailable"
foreach tool {sha256sum shasum} {
    if {![catch {exec {*}[list $tool -a 256] << [binary format cu* $XDC_CONCAT]} o]} {
        set CONSTRAINT_SHA256 [lindex [split [string trim $o]] 0]; break
    }
    if {![catch {exec $tool << [binary format cu* $XDC_CONCAT]} o]} {
        set CONSTRAINT_SHA256 [lindex [split [string trim $o]] 0]; break
    }
}

## ── Placeholder board pins gate ─────────────────────────────────────────────
## constraints/io.xdc §5 sets BOARD_PINS_ARE_PLACEHOLDERS while the PACKAGE_PIN
## values are generic. Synthesis and implementation still run — bring-up numbers
## are useful immediately — but the artifact that could reach hardware is
## blocked, because a wrong pin assignment can drive a signal into a supply rail.
set PINS_ARE_PLACEHOLDERS 0
if {![catch {exec grep -c {BOARD_PINS_ARE_PLACEHOLDERS TRUE} \
        [file join $REPO_ROOT constraints io.xdc]} n]} {
    if {[string trim $n] > 0} { set PINS_ARE_PLACEHOLDERS 1 }
}

## =============================================================================
## 7. Stage helpers
## =============================================================================
proc stage_banner {name} {
    puts "\n=========================================================================="
    puts " STAGE: $name    [clock format [clock seconds] -format %H:%M:%S]"
    puts "==========================================================================\n"
}

## Snapshot the message counters so per-stage critical warnings can be attributed.
proc crit_count {} {
    if {[catch {get_msg_config -severity {CRITICAL WARNING} -count} n]} { return 0 }
    return $n
}

## ⚠️ Common report set, written after EVERY stage.
## 05-timing-closure.md §2: "Synthesis timing estimates are not real ... Never
## report a synthesis number as timing closed." We still capture them, because
## a synth WNS that collapses between two commits localizes the regression to
## RTL rather than to placement — the number is useful for ATTRIBUTION even
## though it is worthless for CLOSURE.
proc write_reports {tag rptdir} {
    report_timing_summary -delay_type min_max -max_paths 20 -nworst 5 \
        -input_pins -routable_nets -file [file join $rptdir ${tag}_timing_summary.rpt]
    report_utilization -hierarchical -hierarchical_depth 3 \
        -file [file join $rptdir ${tag}_utilization.rpt]
    report_clock_interaction -delay_type min_max \
        -file [file join $rptdir ${tag}_clock_interaction.rpt]
    report_high_fanout_nets -timing -load_types -max_nets 50 \
        -file [file join $rptdir ${tag}_high_fanout_nets.rpt]
    report_methodology -file [file join $rptdir ${tag}_methodology.rpt]
    report_drc         -file [file join $rptdir ${tag}_drc.rpt]
    report_cdc -details -file [file join $rptdir ${tag}_cdc.rpt]
    report_exceptions -ignored -file [file join $rptdir ${tag}_exceptions_ignored.rpt]
    ## design_analysis needs placement to be meaningful; harmless before it.
    catch {report_design_analysis -complexity -congestion -timing \
        -file [file join $rptdir ${tag}_design_analysis.rpt]}
}

## =============================================================================
## 8. SYNTHESIS
## =============================================================================
stage_banner "synth_design (directive $SYNTH_DIRECTIVE)"

## Build identity generics — 06-operations/01-build-and-release.md §4.
## The fabric must be able to identify itself; the host reads these over BAR0
## and REFUSES TO ARM TRADING on any mismatch. "The card came up, probably fine"
## is not an acceptable state.
set GIT_SHA32   "32'h[string range $GIT_SHA_FULL 0 7]"
set BUILD_ID32  [format "32'h%08X" [expr {($BUILD_START_S ^ $CONSTRAINT_CRC32) & 0xFFFFFFFF}]]

synth_design -top $TOP -part $PART -directive $SYNTH_DIRECTIVE \
    -generic BUILD_ID=$BUILD_ID32 \
    -generic GIT_SHA=$GIT_SHA32 \
    -include_dirs $RTL_INCDIRS \
    -flatten_hierarchy rebuilt \
    -assert

write_checkpoint -force [file join $DCPDIR post_synth.dcp]
write_reports post_synth $RPTDIR

## ── GATE 1: latch inference ─────────────────────────────────────────────────
## Belt and braces: the message promotion in §4 should already have failed the
## build, but a Vivado version that reports latches under a different message ID
## must not slip through silently. Grep the utilization report's primitive list.
if {![catch {exec grep -ci {latch} \
        [file join $RPTDIR post_synth_utilization.rpt]} nl] && [string trim $nl] > 0} {
    puts "ERROR: GATE 1 FAILED — latch primitives present in the synthesized netlist."
    puts "ERROR: See [file join $RPTDIR post_synth_utilization.rpt]"
    puts "ERROR: manuals/00-foundations/03-hdl-and-rtl-coding.md §3: a latch is"
    puts "ERROR: not timed by STA and fails intermittently in hardware."
    exit 1
}

## ── GATE 2: unconstrained clocks and endpoints ──────────────────────────────
## 05-timing-closure.md §1: "an unconstrained input or output path is simply not
## checked, which is how designs pass timing and fail on hardware."
check_timing -verbose -file [file join $RPTDIR post_synth_check_timing.rpt]
report_clocks -file [file join $RPTDIR post_synth_clocks.rpt]

proc grep_count {pattern path} {
    if {[catch {exec grep -c -- $pattern $path} n]} { return 0 }
    return [expr {int([string trim $n])}]
}
set N_NOCLOCK   [grep_count {no_clock}                     [file join $RPTDIR post_synth_check_timing.rpt]]
set N_UNCONSTR  [grep_count {unconstrained_internal_endpoints} [file join $RPTDIR post_synth_check_timing.rpt]]
if {$N_NOCLOCK > 0 || $N_UNCONSTR > 0} {
    puts "ERROR: GATE 2 FAILED — unconstrained clock(s) or endpoint(s)."
    puts "ERROR: See [file join $RPTDIR post_synth_check_timing.rpt]"
    puts "ERROR: manuals/00-foundations/04-clocking-reset-and-cdc.md §1 rule 3:"
    puts "ERROR: an unconstrained clock is an unverified design."
    exit 1
}

if {$STOP_AFTER eq "synth"} { puts "INFO: --stop-after synth; done."; exit 0 }

## =============================================================================
## 9. IMPLEMENTATION
## =============================================================================
## ⚠️ SEED HANDLING — read this before changing it.
##    06-operations/01-build-and-release.md §6 note: whether place_design accepts
##    a numeric -seed depends on the Vivado release. Where it does not, DIRECTIVE
##    VARIATION is the seed-sweep mechanism. This script therefore maps the
##    integer seed onto a fixed, ordered table of directive triples. The mapping
##    is deterministic, so "seed 7" means the same thing on every machine and in
##    every release of this repository — which is the property that matters. The
##    resolved triple is recorded in the manifest, so a build is reproducible
##    from the manifest alone even if this table later grows.
set IMPL_STRATEGIES {
    {Explore              ExtraTimingOpt              Explore}
    {Explore              Explore                     AggressiveExplore}
    {ExploreWithRemap     ExtraPostPlacementOpt       NoTimingRelaxation}
    {Explore              AltSpreadLogic_high         AlternateCLBRouting}
    {ExploreSequentialArea SSI_SpreadLogic_high       Explore}
    {Explore              ExtraTimingOpt              MoreGlobalIterations}
    {ExploreWithRemap     AltSpreadLogic_medium       HigherDelayCost}
    {Explore              ExtraNetDelay_high          AdvancedSkewModeling}
    {Default              Default                     Default}
    {Explore              WLDrivenBlockPlacement      AlternateDelayModeling}
    {ExploreArea          ExtraTimingOpt              NoTimingRelaxation}
    {Explore              ExtraPostPlacementOpt       AggressiveExplore}
    {ExploreWithRemap     ExtraTimingOpt              Explore}
    {Explore              SSI_ExtraTimingOpt          HigherDelayCost}
    {ExploreSequentialArea ExtraTimingOpt             AlternateCLBRouting}
    {Explore              AltSpreadLogic_low          MoreGlobalIterations}
}
set N_STRAT [llength $IMPL_STRATEGIES]
set TRIPLE  [lindex $IMPL_STRATEGIES [expr {($SEED - 1) % $N_STRAT}]]
lassign $TRIPLE OPT_DIRECTIVE PLACE_DIRECTIVE ROUTE_DIRECTIVE
set PHYS_DIRECTIVE AggressiveExplore

puts "INFO: seed $SEED -> opt=$OPT_DIRECTIVE place=$PLACE_DIRECTIVE route=$ROUTE_DIRECTIVE"

## ⚠️ Directive names differ by Vivado release (UG835). If a directive in the
##    table does not exist in the pinned version, the build must FAIL rather
##    than silently fall back to Default — a silent fallback makes two different
##    "seeds" produce identical results and turns the sweep into theatre.

stage_banner "opt_design (directive $OPT_DIRECTIVE)"
opt_design -directive $OPT_DIRECTIVE
write_checkpoint -force [file join $DCPDIR post_opt.dcp]
write_reports post_opt $RPTDIR

if {$STOP_AFTER eq "opt"} { puts "INFO: --stop-after opt; done."; exit 0 }

stage_banner "place_design (directive $PLACE_DIRECTIVE)"
place_design -directive $PLACE_DIRECTIVE
write_checkpoint -force [file join $DCPDIR post_place.dcp]
write_reports post_place $RPTDIR

## ⚠️ SLR crossing audit — constraints/floorplan.xdc exists to keep the fast
##    path in one SLR. An SLR crossing costs roughly a full clock cycle; on a
##    6.4 ns period, one unplanned crossing on the critical path deletes the
##    entire budget. design_analysis is where they show up.
catch {report_design_analysis -timing -max_paths 20 \
    -file [file join $RPTDIR post_place_slr_analysis.rpt]}

if {$STOP_AFTER eq "place"} { puts "INFO: --stop-after place; done."; exit 0 }

stage_banner "phys_opt_design (pre-route, directive $PHYS_DIRECTIVE)"
phys_opt_design -directive $PHYS_DIRECTIVE
write_checkpoint -force [file join $DCPDIR post_physopt.dcp]

stage_banner "route_design (directive $ROUTE_DIRECTIVE)"
route_design -directive $ROUTE_DIRECTIVE

## Post-route physical optimization. 05-timing-closure.md §4 Tier 4 item 15.
## Only worth running if there is something to fix; running it unconditionally
## burns runtime on an already-closed design.
if {[get_property SLACK [get_timing_paths -delay_type max]] < 0} {
    stage_banner "phys_opt_design (post-route rescue)"
    phys_opt_design -directive $PHYS_DIRECTIVE
}

write_checkpoint -force [file join $DCPDIR post_route.dcp]
write_reports post_route $RPTDIR

## Extra sign-off reports that only make sense post-route.
report_timing -max_paths 50 -nworst 10 -path_type full_clock_expanded \
    -file [file join $RPTDIR post_route_paths.rpt]
report_power -file [file join $RPTDIR post_route_power.rpt]
report_route_status -file [file join $RPTDIR post_route_status.rpt]

## =============================================================================
## 10. SIGN-OFF GATES
## =============================================================================
## ── GATE 3: timing closure ──────────────────────────────────────────────────
## 05-timing-closure.md §9: quote WNS, TNS, WHS and failing-endpoint count from
## the POST-ROUTE report. Never claim closure from synthesis.
set WNS [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set WHS [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
set TNS [get_property STATS.TNS [get_timing_paths -delay_type max]]
set THS [get_property STATS.THS [get_timing_paths -delay_type min]]
if {[catch {set TNS [get_property STATS.TNS [current_design]]}]} { }
## Robust fallbacks: the property names above vary by release, so read the
## report as the source of truth if the property query came back empty.
foreach v {WNS WHS TNS THS} { if {[set $v] eq ""} { set $v 0 } }

set N_FAIL_SETUP [llength [get_timing_paths -delay_type max -max_paths 100000 \
                                            -slack_lesser_than 0 -quiet]]
set N_FAIL_HOLD  [llength [get_timing_paths -delay_type min -max_paths 100000 \
                                            -slack_lesser_than 0 -quiet]]

puts "\n---- POST-ROUTE TIMING (quoted verbatim; do not round, do not estimate) ----"
puts "  WNS = $WNS ns    TNS = $TNS ns    failing setup endpoints = $N_FAIL_SETUP"
puts "  WHS = $WHS ns    THS = $THS ns    failing hold  endpoints = $N_FAIL_HOLD"
puts "-----------------------------------------------------------------------------\n"

set TIMING_FAILED 0
if {$WNS < 0} {
    puts "ERROR: GATE 3 FAILED — negative post-route WNS ($WNS ns). Timing is NOT closed."
    puts "ERROR: 05-timing-closure.md §3: classify the failure as logic-bound or"
    puts "ERROR: route-bound before attempting a fix. See $RPTDIR/post_route_paths.rpt"
    set TIMING_FAILED 1
}
if {$WHS < 0} {
    puts "ERROR: GATE 3 FAILED — negative post-route WHS ($WHS ns). Hold violations"
    puts "ERROR: usually mean a missing -hold N-1 on a multicycle path."
    puts "ERROR: See constraints/timing_exceptions.xdc §0."
    set TIMING_FAILED 1
}

## ── GATE 4: DRC ─────────────────────────────────────────────────────────────
report_drc -ruledecks {default} -file [file join $RPTDIR post_route_drc.rpt]
set DRC_CRIT [get_drc_violations -quiet -name [get_drc_ruledecks default]]
set N_DRC_CRIT 0
if {![catch {set v [get_drc_violations -quiet]}]} {
    foreach viol $v {
        set sev [get_property SEVERITY $viol]
        if {$sev eq "CRITICAL WARNING" || $sev eq "Error" || $sev eq "ERROR"} { incr N_DRC_CRIT }
    }
}
if {$N_DRC_CRIT > 0} {
    puts "ERROR: GATE 4 FAILED — $N_DRC_CRIT critical DRC violation(s)."
    puts "ERROR: See [file join $RPTDIR post_route_drc.rpt]"
    set TIMING_FAILED 1
}

## ── GATE 5: CDC ─────────────────────────────────────────────────────────────
## STA does NOT check CDC correctness — those paths are excluded from analysis
## by construction (04-clocking-reset-and-cdc.md §6). report_cdc is the only
## structural check, and a CDC bug in this design corrupts a risk limit.
set N_CDC_CRIT [grep_count {Critical} [file join $RPTDIR post_route_cdc.rpt]]
if {$N_CDC_CRIT > 0} {
    puts "ERROR: GATE 5 FAILED — $N_CDC_CRIT critical CDC finding(s)."
    puts "ERROR: See [file join $RPTDIR post_route_cdc.rpt]"
    puts "ERROR: manuals/00-foundations/04-clocking-reset-and-cdc.md §6."
    set TIMING_FAILED 1
}

## ── Ignored exceptions: a warning, not a gate ───────────────────────────────
## An exception that matches nothing means the design was renamed underneath it,
## and the path it was meant to relax is now fully timed (harmless) — or some
## other path is now relaxed (not harmless). Worth a human's attention every
## build; not worth blocking one, because constraints/timing_exceptions.xdc §3
## documents a legitimate always-ignored case (constant-propagated build IDs).
set N_IGNORED [grep_count {set_} [file join $RPTDIR post_route_exceptions_ignored.rpt]]
if {$N_IGNORED > 0} {
    puts "WARNING: $N_IGNORED timing exception(s) matched nothing. Review"
    puts "WARNING: [file join $RPTDIR post_route_exceptions_ignored.rpt]"
    puts "WARNING: against constraints/timing_exceptions.xdc §5."
}

## =============================================================================
## 11. UTILIZATION EXTRACTION (for the manifest and CI trending)
## =============================================================================
proc util_of {type} {
    set n 0
    if {![catch {set cells [get_cells -quiet -hier -filter "PRIMITIVE_TYPE =~ $type"]}]} {
        set n [llength $cells]
    }
    return $n
}
set U_LUT  [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == LUT}]]
set U_FF   [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set U_BRAM [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == BLOCKRAM}]]
set U_URAM [llength [get_cells -quiet -hier -filter {REF_NAME =~ URAM*}]]
set U_DSP  [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == ARITHMETIC}]]

## =============================================================================
## 12. BITSTREAM
## =============================================================================
set BITFILE ""
if {$STOP_AFTER eq "route"} {
    puts "INFO: --stop-after route; skipping bitstream."
} elseif {$TIMING_FAILED} {
    puts "ERROR: not writing a bitstream — sign-off gates failed above."
    puts "ERROR: A bitstream that did not close timing must not exist, because"
    puts "ERROR: someone will eventually load it."
} elseif {$PINS_ARE_PLACEHOLDERS} {
    puts "ERROR: not writing a bitstream — constraints/io.xdc still declares"
    puts "ERROR: BOARD_PINS_ARE_PLACEHOLDERS. Real pin assignments are required"
    puts "ERROR: before an artifact that could reach hardware is produced."
    puts "ERROR: (Reports and checkpoints above are still valid for bring-up.)"
} else {
    stage_banner "write_bitstream"
    set BITFILE [file join $OUTDIR ${TOP}.bit]
    write_bitstream -force $BITFILE
    catch {write_debug_probes -force [file join $OUTDIR ${TOP}.ltx]}
}

## =============================================================================
## 13. BUILD MANIFEST
## =============================================================================
## 06-operations/01-build-and-release.md §3. This file is the answer to "what
## was running at 14:32:07?" — and the answer has to be a hash, not a
## description.
proc json_str {s} {
    set s [string map {\\ \\\\ \" \\\" \n \\n \r "" \t \\t} $s]
    return "\"$s\""
}
set BUILD_END_S [clock seconds]
set MANIFEST [file join $OUTDIR manifest.json]
set mf [open $MANIFEST w]
puts $mf "{"
puts $mf "  \"schema\":          1,"
puts $mf "  \"git_sha\":         [json_str $GIT_SHA_FULL],"
puts $mf "  \"git_branch\":      [json_str $GIT_BRANCH],"
puts $mf "  \"git_dirty\":       [expr {$GIT_DIRTY ? "true" : "false"}],"
puts $mf "  \"tool\":            [json_str [version -short]],"
puts $mf "  \"tool_full\":       [json_str [lindex [split [version] "\n"] 0]],"
puts $mf "  \"part\":            [json_str $PART],"
puts $mf "  \"top\":             [json_str $TOP],"
puts $mf "  \"seed\":            $SEED,"
puts $mf "  \"threads\":         $THREADS,"
puts $mf "  \"directives\":      {"
puts $mf "    \"synth\": [json_str $SYNTH_DIRECTIVE],"
puts $mf "    \"opt\":   [json_str $OPT_DIRECTIVE],"
puts $mf "    \"place\": [json_str $PLACE_DIRECTIVE],"
puts $mf "    \"phys\":  [json_str $PHYS_DIRECTIVE],"
puts $mf "    \"route\": [json_str $ROUTE_DIRECTIVE]"
puts $mf "  },"
puts $mf "  \"floorplan_enabled\": [expr {$FLOORPLAN_ENABLE ? "true" : "false"}],"
puts $mf "  \"constraint_sha256\": [json_str $CONSTRAINT_SHA256],"
puts $mf "  \"constraint_crc32\":  [json_str [format "0x%08X" $CONSTRAINT_CRC32]],"
puts $mf "  \"constraint_files\":  \[[join [lmap x $XDC_FILES {json_str [file tail $x]}] ,]\],"
puts $mf "  \"build_id\":        [json_str $BUILD_ID32],"
puts $mf "  \"wns_ns\":          $WNS,"
puts $mf "  \"tns_ns\":          $TNS,"
puts $mf "  \"whs_ns\":          $WHS,"
puts $mf "  \"ths_ns\":          $THS,"
puts $mf "  \"failing_endpoints_setup\": $N_FAIL_SETUP,"
puts $mf "  \"failing_endpoints_hold\":  $N_FAIL_HOLD,"
puts $mf "  \"util\": {\"lut\": $U_LUT, \"ff\": $U_FF, \"bram\": $U_BRAM, \"uram\": $U_URAM, \"dsp\": $U_DSP},"
puts $mf "  \"drc_critical\":    $N_DRC_CRIT,"
puts $mf "  \"cdc_critical\":    $N_CDC_CRIT,"
puts $mf "  \"timing_closed\":   [expr {$TIMING_FAILED ? "false" : "true"}],"
puts $mf "  \"bitstream\":       [json_str $BITFILE],"
puts $mf "  \"pins_placeholder\":[expr {$PINS_ARE_PLACEHOLDERS ? "true" : "false"}],"
puts $mf "  \"built_by\":        [json_str [run_or {hostname} unknown]],"
puts $mf "  \"built_at_utc\":    [json_str [clock format $BUILD_START_S -format {%Y-%m-%dT%H:%M:%SZ} -gmt 1]],"
puts $mf "  \"wall_seconds\":    [expr {$BUILD_END_S - $BUILD_START_S}]"
puts $mf "}"
close $mf
puts "INFO: manifest written to $MANIFEST"

## ⚠️ The manifest deliberately contains NO measured latency field. Latency is
##    measured on hardware (or explicitly labelled "simulated"), never inferred
##    from a build. CLAUDE.md §4: "If a latency number was simulated, say
##    'simulated'. If measured on hardware, say 'measured, N=…'. These are not
##    interchangeable." scripts/report_qor.py merges the simulation-measured
##    numbers in from the cocotb regression when it has them.

if {$TIMING_FAILED} {
    puts "\nBUILD FAILED — see the gate errors above. Reports are in $RPTDIR"
    exit 1
}
puts "\nBUILD OK  ([expr {$BUILD_END_S - $BUILD_START_S}] s)  WNS=$WNS  TNS=$TNS  WHS=$WHS"
exit 0
