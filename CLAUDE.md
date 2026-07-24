# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script (`s0ix-selftest-tool.sh`) that debugs CPU Package C-state and
S0ix (S2idle) low-power-state failures on Intel client platforms running Linux. It
drives the system through real S2idle suspend/resume cycles, reads power residency
counters, and walks a decision tree to point at the likely blocker. There is no
build step and no test suite — the "test" is running it on target hardware.

## Running

Must run as **root** (the script exits immediately otherwise). Requires physical
Intel client hardware; results are meaningless in a VM.

```bash
./s0ix-selftest-tool.sh -s        # Check S0ix residency during S2idle (main path)
./s0ix-selftest-tool.sh -r on     # Check runtime PC10 with screen on
./s0ix-selftest-tool.sh -r off    # Check runtime PC10 with screen off (needs X/startx)
./s0ix-selftest-tool.sh -h        # Help
```

Every run appends a timestamped `YYYYMMDD-HH-MM-s0ix-output.log` in the working
directory via the `log_output` helper (which `tee`s to that file). `-r off` turns
the display off with `xset` and must be run from an xterminal after `startx`.

External tool dependencies: `turbostat` (bundled binary in repo root, invoked as
`"$DIR"/turbostat`), `powertop`, `acpidump`/`iasl` (acpica-tools), `xxd`
(vim-common), `gawk` (script relies on `gensub`), `bc`, `lspci`. `shell.nix`
provides all of these for `nix-shell` — but note it pulls turbostat from nixpkgs
rather than using the bundled binary.

## Architecture

### Data source: turbostat + intel_pmc_core sysfs

The script reads residency data two ways and cross-references them:

1. **turbostat** is run with `--show "$TURBO_COLUMNS"` while triggering an S2idle
   cycle (`echo freeze > /sys/power/state`, armed by an RTC wakealarm). It reports
   Core C-state and Package C-state (PC2/3/6/8/10) plus `SYS%LPI` (the S0ix
   residency).
2. **`/sys/kernel/debug/pmc_core/`** (`$PMC_CORE_SYSFS_PATH`) exposes finer detail:
   `substate_residencies`, `substate_requirements`, `substate_status_registers`,
   `ltr_show`/`ltr_ignore`, `slp_s0_debug_status`, `pch_ip_power_gating_status`,
   `lpm_latch_mode`, `slp_s0_dbg_latch`.

### Column parsing (fragile, handle with care)

turbostat's output column order is **not** fixed and varies by platform/version.
Never hardcode column positions. The script resolves them dynamically:
- `TURBO_RESULT_COLUMNS` is built from turbostat's header row (`sed -n '2p'`, tabs → commas).
- `get_column_index "$columns" "$name"` returns the 1-based column index (or `-1`).
- Values are then pulled with `awk -v idx=$(get_column_index ...) '{print $idx}'`
  from the data row (`sed -n '3p'`).

This dynamic-column approach is recent (see git history: "Get column index from
turbostat's output column"). When touching any residency extraction, keep using
`get_column_index`; do not reintroduce fixed `$4`/`$5`-style field access.

### The S2idle decision tree (`-s` path)

The heart of the tool. `pkg_output()` runs one S2idle cycle, then classifies the
result into a `DEBUG` scenario number, and the bottom-of-file `case $DEBUG` block
dispatches to the matching debug routine. The scenarios form a depth ladder — the
deeper the state the system reached, the "better", and each scenario debugs the
next-deepest state that was *not* reached:

- **DEBUG=1** — no PC2 → `debug_no_pc2` (checks Core C6, cpuidle driver)
- **DEBUG=2** — PC2/PC3 but no PC8 → `debug_no_pc8` (powertop, PCIe link/D-state)
- **DEBUG=3** — PC8 but no PC10 → `debug_no_dc9` (graphics DC5/DC6/DC9),
  then `debug_ltr_value` (per-IP LTR ignore sweep), then PCH/ACPI-DSM/ModPHY checks
- **DEBUG=4** — PC10 but no S0ix → `debug_pch_ip_pg`, `debug_acpi_dsm`, PCIe, ModPHY/CSME
- **DEBUG=5** — S0ix substates supported but shallowest (s0i2.0) not reached →
  `substate_triage`

Success cases (S0ix residency achieved, or deepest substate reached) `exit 0`
directly from inside `pkg_output`.

### Substate triage

When a system reaches S0ix but only a *shallow* substate, `pkg_output` compares
`substate_residencies` before vs. after S2idle to find which substate actually
accumulated residency, then calls `substate_triage <achieved> <desired-deeper>`.
That function uses `lpm_latch_mode` + `substate_requirements` to list the IPs that
are "Required" but not showing "Yes" — the blockers. `substate_requirements`
parsing depends on gawk's `gensub`.

### Cross-cutting debug helpers

These are shared by multiple scenarios and communicate partly through globals set
during the run (`PCIEPORT_D0`, `PCIEPORT_D3HOT`, `PCIEPORT_L0`, `ASPM_ENABLE`):
- `pci_d3_status_check` — S2idle cycle with PCI PM dynamic-debug on; records which
  pcieports failed to reach D3cold into the globals above.
- `debug_pcie_bridge_lpm` — decodes the PCIESTS1 register (offset `0x32a` in each
  bridge's config space, read via `xxd`) to report link L-state; expects L1.1/L1.2.
- `judge_dstate_linkstate` — correlates the D-state and link-state globals to flag
  a root port whose ASPM setting is inconsistent with its power state.

## Conventions

- Colored output uses raw ANSI escapes in `log_output` strings: `\033[31m` red
  (problem/blocker), `\033[32m` green (success). Match this when adding messages.
- Nearly every failure path `exit 0` (not non-zero) after printing guidance — the
  script is a diagnostic aid, not a pass/fail gate. Preserve that unless asked.
- Numeric residency comparisons go through `bc` (`echo "scale=2; $x > 0.00" | bc`),
  since values are floating-point percentages.
- Commit messages: present tense (repo convention and user preference).
- Licensed GPL-2.0-only; keep the SPDX header. Copyright is Intel.
