# 12.02 — Supply Chain and Bitstream Integrity

> **Why this matters here:** the bitstream *is* the trading system. Not a
> description of it, not a build of it — it is the actual logic that will decide,
> in 20 cycles, whether to commit the firm's capital. Everything upstream of that
> file — your RTL, someone else's encrypted IP, Vivado, the container image, the
> CI runner, the USB stick — is inside your trust boundary whether you modelled it
> or not. This document is about shrinking that boundary and proving what is
> inside it.

---

## 1. What you are actually trusting

Write the list down once, honestly. It is longer than people expect.

| Layer | Who controls it | Can it change the risk gate? | Would you notice? |
| --- | --- | --- | --- |
| Our RTL in `rtl/` | Us | Yes | Yes — code review, `git`, regression |
| Our constraints in `constraints/` | Us | **Yes** — a timing exception can break a check path | ⚠️ Only if you diff XDC as carefully as RTL |
| Our build scripts in `scripts/` | Us | Yes — `-generic`, file globs, waivers | Sometimes |
| Vendor IP (`.xci`: MAC/PCS, PCIe) | Vendor, encrypted | Not directly; can alter timing and behaviour | No — you cannot read it |
| Third-party / open-source IP | Whoever wrote it | Yes if on the datapath | Only by reading it |
| Vivado / Quartus | Vendor | **Yes** — synthesis, opt, retiming, bitgen | No |
| Container base image + OS packages | Whoever built it | Yes, via the tool | Only by pinning + hashing |
| CI runner | Us / cloud provider | Yes — it holds the artifact and often the keys | Only with attestation |
| Git server / review process | Us / vendor | Yes — a merged commit is a merged commit | Yes, if reviews are real |
| Card firmware, flash, BMC | Vendor + us | Indirectly — it decides what gets loaded | ⚠️ Rarely monitored |
| The human with `write_bitstream` access | Us | Yes | Only via governance |

⚠️ **Constraints are the most under-reviewed high-impact input in this list.** A
single `set_false_path` or `set_multicycle_path` aimed at the wrong net can make a
risk-gate comparison latch garbage, and the design will close timing, pass
simulation (which ignores XDC), and be wrong only on hardware, only sometimes.
Review XDC diffs with the same seriousness as RTL diffs — see
[../00-foundations/05-timing-closure.md](../00-foundations/05-timing-closure.md).

---

## 2. Reproducible builds as a security property

[../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md)
§1 states reproducibility as an engineering requirement. It is also the single
most useful *security* control in this tier, for one reason:

> **Reproducibility converts "trust the build machine" into "trust the source",
> and lets a second party check the answer.**

Without it, the only evidence that a `.bit` corresponds to a commit is that
somebody says so. With it, anyone with the pinned toolchain can rebuild and
compare hashes. That is the difference between an assertion and a proof.

| Property | What it gives you | What it does **not** give you |
| --- | --- | --- |
| **Reproducible** — same source ⇒ same artifact | Independent verification; tamper detection between source and artifact | Any assurance the source is benign |
| **Attested** — artifact carries a signed statement of *what built it* | Provenance: which runner, which commit, which inputs | Reproducibility, if the inputs weren't pinned |
| **Signed** — the *device* verifies before loading | Only our bitstreams load on our card | Anything about correctness |
| **Reviewed** — humans read the diff | Catches intent | Catches nothing that is not in the diff (i.e. not tool-inserted logic) |

You want all four; they are independent and none substitutes for another.

⚠️ **Bit-exact reproducibility across multi-threaded P&R is not guaranteed by the
tools.** `set_param general.maxThreads N` pinned to the same value is a
prerequisite, not a promise.
> **Verify:** the determinism guarantees for your exact Vivado version — *Vivado
> Design Suite User Guide: Implementation* (**UG904**) and the *UltraFast Design
> Methodology Guide* (**UG949**). Where bit-exactness is not achievable, fall back
> to **functional equivalence + hashed inputs**: hash every input (sources, IP,
> XDC, tool version, directives, seed, thread count) into the manifest, and treat
> the input hash — not the output hash — as the identity.

---

## 3. Bitstream authentication and encryption

Modern devices support cryptographic protection of the configuration file itself.
Two distinct mechanisms, routinely confused:

| Mechanism | Protects | Against | Key storage |
| --- | --- | --- | --- |
| **Authentication** (signature/MAC check at load) | Integrity + origin | Loading a modified or foreign bitstream | Public-key hash or symmetric key in device |
| **Encryption** (bitstream ciphertext) | Confidentiality | Cloning, reverse engineering, IP theft | Symmetric key in device |

**For a trading card, authentication is the one that matters.** Encryption
protects your design from being copied; authentication protects your capital from
executing someone else's logic. If you can only enable one, enable
authentication.

> **Verify:** the exact key types, storage options (eFUSE vs battery-backed RAM),
> and the property names below against the configuration user guide for your
> specific family — for UltraScale/UltraScale+ that is the *UltraScale
> Architecture Configuration User Guide* (**UG570**); for Zynq UltraScale+ MPSoC,
> **UG1085**; for the Vivado-side flow, the programming and debugging guide
> (**UG908**). Property names, key formats, and available algorithms differ by
> family and by tool version. Do not copy the snippet below into a build without
> checking it.

```tcl
# scripts/build_secure.tcl — ILLUSTRATIVE SHAPE ONLY.
# Confirm every property name and value against UG570/UG908 for your device
# and Vivado version before use.

# Encryption (confidentiality of the design)
set_property BITSTREAM.ENCRYPTION.ENCRYPT         YES        [current_design]
set_property BITSTREAM.ENCRYPTION.ENCRYPTKEYSELECT eFUSE     [current_design]
set_property BITSTREAM.ENCRYPTION.KEYFILE         keys/aes.nky [current_design]

# Authentication (integrity + origin) — mechanism and property set is
# family-specific; on some families this is driven by the programming tool
# rather than by write_bitstream properties.

write_bitstream -force $outdir/top_trading.bit
```

### Key management is the hard part

| Question | Bad answer | Required answer |
| --- | --- | --- |
| Where does the signing/encryption key live? | On the CI runner | HSM or a dedicated offline signer; CI submits, never holds |
| Who can sign? | Anyone who can push | A named, small set; every signature logged |
| What happens if the key leaks? | Rotate it | ⚠️ **eFUSE storage is one-time-programmable.** Plan for "the card is retired", not "we rotate" |
| Can a developer build a loadable image? | Yes, for convenience | Only for lab cards with a *different*, clearly-marked dev key |

⚠️ **Never provision production and development cards with the same key.** The
purpose of the whole mechanism is that a lab bitstream cannot run on a production
card. If the keys are shared, the control does nothing except make you feel safe.

---

## 4. The build-ID arm check as an anti-tamper control

[../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md)
§4 introduces the build-ID block, and
[`rtl/ctrl/csr_regfile.sv`](../../rtl/ctrl/csr_regfile.sv) exposes it at fixed
offsets that never move:

```
0x000 BUILD_ID         RO  ⚠ THE ARM GATE — host refuses to arm on mismatch
0x004 GIT_SHA          RO  first 4 bytes of the commit SHA
0x008 BUILD_TIMESTAMP  RO  unix seconds at synthesis
0x00C MAP_VERSION      RO  {MAGIC 0x4654, MAJOR, MINOR}
```

**What it is good at**, and it is genuinely good at these:

| Failure it catches | How |
| --- | --- |
| Stale bitstream from the last release still in flash | `BUILD_ID` ≠ expected → arming refused |
| Partial or failed reconfiguration | `MAP_VERSION` magic wrong or bus reads the `0xDEAD_C0DE` unmapped sentinel |
| Wrong card programmed in a multi-card host | ID mismatch per card |
| Host software / bitstream version skew | Compatibility matrix keyed on `BUILD_ID` × host version |
| "Which logic made this decision?" after the fact | `GIT_SHA` in every audit record |

⚠️ **What it is *not*: an authentication mechanism.** `BUILD_ID` is a constant the
bitstream carries about itself. An adversary who can produce a bitstream can
produce one that reports any build ID they like. The check proves *identity as
claimed*, not *authenticity*. It defeats the accident and the mix-up — which is
most of the real risk — and it does nothing whatsoever against attack-tree branch
B3 in [01-threat-model.md](01-threat-model.md).

**The layering, stated explicitly:**

```
device signature check   → only bitstreams we signed will load        (authenticity)
build-ID arm gate        → only the build we expected may trade       (identity)
host-side SHA256 compare → the file on disk is the released artifact  (integrity in transit)
reproducible rebuild     → the released artifact matches the source   (provenance)
code + XDC review        → the source does what we think              (intent)
```

Each layer catches something the others cannot. Skipping one is a decision, and
it belongs in the release note.

---

## 5. Vendor IP provenance

We deliberately depend on hard/soft vendor IP: the GT wrappers, the Ethernet
PCS/MAC, PCIe. That dependency is not optional, so manage it rather than pretend
it away.

| Requirement | Why |
| --- | --- |
| `.xci` files **checked in**, never auto-upgraded | `upgrade_ip` silently changes MAC/PCS latency — a latency change is a trading change |
| IP version recorded in `manifest.json` (`ip_versions`) | Post-incident: "what was the MAC?" is answerable |
| A latency measurement per IP version, in `docs/` | The budget in `rtl/fpga_top.sv` assumes ~90 ns each way through GT + PCS; that number belongs to a version |
| No vendor IP on the risk path | ⚠️ **Hard rule.** The risk gate, kill switch, and rate limiter are 100 % our RTL, readable, reviewed, simulated |
| Third-party non-vendor IP: source available, or it does not go on the datapath | You cannot review what you cannot read |

⚠️ **Encrypted IP is unreviewable by construction, and the encryption scheme
itself has a published weakness history.**
> **Verify:** IEEE 1735 (IP encryption recommended practice) and the CERT/CC
> advisory covering weaknesses in IEEE 1735 implementations (**VU#739007**), plus
> your tool vendor's current guidance. Confirm the present status before relying
> on IP encryption as a security boundary in either direction.

Practical position for this project: vendor IP is acceptable at the **edges**
(transceivers, PCS/MAC, PCIe hard block) where the alternative is not building
the system, and unacceptable **anywhere a trading decision or a risk decision is
made**. That line is not a style preference; it is the line between "we can
explain what the machine did" and "we cannot".

---

## 6. The hardware SBOM

The software world has SBOMs. The equivalent here is the build manifest, extended
with hashes. Everything that can change the artifact gets hashed into it.

```json
{
  "build_id":        "0x20260731_07_9F1C3AE4",
  "git_sha":         "9f1c3ae4d2b6...",
  "git_dirty":       false,
  "source_tree_sha": "sha256:1c9d...",     // hash of all rtl/ + constraints/ + scripts/
  "constraint_sha":  "sha256:0af2...",
  "filelist_sha":    "sha256:77b1...",     // rtl/filelist.f — what was actually compiled
  "tool":            "Vivado 2023.2 (AR patch 000000)",
  "tool_image_sha":  "sha256:be41...",     // the container image digest
  "part":            "xcvu9p-flga2104-2-i",
  "seed":            7,
  "max_threads":     8,
  "directives":      {"place": "ExtraTimingOpt", "route": "Explore"},
  "ip_versions":     {"xxv_ethernet": "4.1", "pcie4_uscale_plus": "1.3"},
  "ip_xci_sha":      {"xxv_ethernet": "sha256:04c8...", "pcie4_uscale_plus": "sha256:9ade..."},
  "waivers_sha":     "sha256:d3f0...",     // verilator + methodology waivers
  "bitstream_sha256":"sha256:3f5e...",
  "signed_by":       "hsm-key-prod-01",
  "built_by":        "ci-runner-03",
  "built_at_utc":    "2026-07-31T02:14:09Z"
}
```

Two entries deserve comment:

- **`waivers_sha`.** A lint or methodology waiver is a decision to ignore a
  warning. Waivers are how a real defect gets normalised. Hash them, review them,
  and require an owner and an expiry comment on each.
- **`filelist_sha`.** `read_verilog -sv [glob rtl/**/*.sv]` compiles whatever is
  on disk. Hashing an explicit file list ([`rtl/filelist.f`](../../rtl/filelist.f))
  turns "the files that happened to be there" into "the files we meant".

⚠️ **`git_dirty: true` is a hard fail for anything leaving CI**, and it is a
*security* failure, not a hygiene one: a bitstream built from uncommitted edits
has no provenance at all, and there is no way to distinguish "I was iterating" from
"I inserted something".

---

## 7. Verification at deployment time

The last mile is where the chain usually breaks: an artifact is verified in CI,
then copied to the trading host by hand.

```python
#!/usr/bin/env python3
# scripts/verify_bitstream.py — run on the trading host BEFORE programming.
# Refuses to proceed unless the local file matches the signed release record.
import hashlib, json, sys, pathlib

def sha256(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()

bit      = pathlib.Path(sys.argv[1])
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())

actual = sha256(bit)
if actual != manifest["bitstream_sha256"]:
    sys.exit(f"REFUSING: {bit} is {actual}, release says {manifest['bitstream_sha256']}")
if manifest.get("git_dirty", True):
    sys.exit("REFUSING: artifact was built from a dirty tree")

# The manifest itself must be signed; verify that signature here with your
# organisation's tooling before trusting any field above.
print(f"OK  build_id={manifest['build_id']}  git_sha={manifest['git_sha'][:8]}")
```

Then, after programming and **before** arming, the host reads back `BUILD_ID`,
`GIT_SHA`, `BUILD_TIMESTAMP`, and `MAP_VERSION` and compares them to the same
manifest. Two independent checks of the same fact, one on the file and one on the
silicon, is the correct amount of paranoia for this asset.

⚠️ **The rollback bitstream gets the identical treatment.** A known-good image
staged on local disk with an unverified hash is a known-*nothing* image, and you
will reach for it at the worst possible moment. See
[../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md)
§9.

---

## 8. ⚠️ What an unverified bitstream on a trading card actually means

Not an abstraction. Concretely, an unverified bitstream means **all** of the
following are simultaneously unknown:

| Unknown | Consequence |
| --- | --- |
| Whether the risk gate limits are the ones you committed | Every order could be unbounded, and every register readback could be lying about it |
| Whether the kill switch is wired to anything | The stop you rehearsed does nothing |
| Whether `KILL_RESP_CYCLES` is honoured | "Bounded response time" is an unverified claim |
| Whether the OUCH encoder emits the fields you think | Wrong side, wrong size, wrong symbol — all legal-looking on the wire |
| Whether the audit ring records what happened | You cannot reconstruct the incident |
| Whether the build-ID register is telling the truth | Your identity check is self-reported by the thing being checked |

And the compounding problem: **the failure is silent and plausible.** A wrong
bitstream that decodes the feed, updates the book, and sends well-formed orders
looks exactly like a working system on every dashboard you have. The version that
crashes is the lucky one.

There is a specific, historically common instance of this: a stale image that
works perfectly and enforces **last quarter's risk limits**. Nothing alerts. The
limits are real, the orders are real, and the bound you believe you have is
fiction. The build-ID arm gate exists precisely and only to close that case, and
it only closes it if arming is *conditional* on it — a warning that arming
proceeds past is not a control.

**Therefore:**

> A card whose bitstream identity has not been positively verified since the last
> reconfiguration is a card that is **not permitted to arm**. Not "should not".
> The host refuses. `arm_state` stays `DISARMED`.

---

## 9. Threats this chapter does not solve

Be explicit, so nobody over-claims in a compliance conversation:

| Threat | Why signing/reproducibility doesn't help | What does |
| --- | --- | --- |
| Malicious RTL merged into our own repo | It is legitimately signed and reproducible | Code review, separation of duties ([03](03-access-control-and-governance.md)), regression + golden-model equivalence |
| Compromised CI runner with signing access | It produces valid signatures | Signer separated from builder; reproducible rebuild by a second party |
| A backdoor in the synthesis tool | Reproducible — reproducibly backdoored | Nothing practical. Accept, document, prefer widely-used tool versions |
| Insider who can also update the expected build ID in host config | Both sides of the check are theirs | Four-eyes on host config; config in version control with review |
| Card firmware / BMC compromise | Sits below the bitstream | Vendor firmware updates, physical control, monitoring |

⚠️ Note the shape: **once an adversary is inside the build pipeline, cryptography
stops helping and governance takes over.** That is why the next document exists.

---

## 10. RULES FOR THIS PROJECT

1. **No vendor or third-party IP on the risk path.** Risk gate, kill switch, rate
   limiter, position monitor: our RTL, readable, reviewed, simulated.
2. **`.xci` files are checked in and never auto-upgraded.** An IP version change
   is a release, with a re-measured latency number.
3. **XDC diffs get RTL-grade review.** A timing exception near the risk path is a
   security review item.
4. **Every artifact that can reach a card carries a signed manifest** with the
   hashes in §6, and is verified on the host before programming (§7).
5. **Arming is conditional on build-ID match.** No warning-and-continue path
   exists, no override flag is added, ever.
6. **Production and development signing keys are different.** A lab bitstream must
   not load on a production card.
7. **The person who signs a release is not the only person who reviewed it.**
8. **Waivers have an owner and a reason, are hashed into the manifest, and are
   re-examined every release.**
9. **The rollback image is hash-verified at stage time and re-verified at use
   time.**
10. **If reproducibility cannot be achieved bit-exactly, hash the inputs and say
    so in the release note.** Silence here reads as a claim you cannot support.

---

## Further reading

- [01-threat-model.md](01-threat-model.md) — attack-tree branch B3, which this document addresses
- [03-access-control-and-governance.md](03-access-control-and-governance.md) — who is allowed to build, sign, and deploy
- [05-incident-preparedness.md](05-incident-preparedness.md) — using `GIT_SHA` and the manifest during an investigation
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) — the build flow, manifest, and release sign-off this extends
- [../06-operations/02-deployment-and-colocation.md](../06-operations/02-deployment-and-colocation.md) — getting a verified artifact onto a machine in the cage
- [../07-reference/03-toolchain-reference.md](../07-reference/03-toolchain-reference.md) — tool commands and where the reports land
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) §7 — pre-deployment checklist
