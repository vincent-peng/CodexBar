# Plugin percentage refresh runtime proof

This is runtime-trace evidence for [CodexBar #4787](https://github.com/steipete/CodexBar/pull/4787).
Both fresh macOS debug bundles use a real `NSStatusItem` created by the production
`StatusItemController`. The receipts read its actual `NSStatusBarButton.title`.

| Build | Weekly usage | Monthly before / after | Native title after snapshot update | Observer / other icon updates |
| --- | --- | --- | --- | --- |
| Baseline | 0% | 76.9% / 80% | `77%` | 0 / 0 |
| Fixed | 0% | 76.9% / 80% | `80%` | 1 / 0 |

The baseline's separately labelled forced-redraw control then changes its title to `80%`.
That confirms the updated snapshot can render; the baseline's observation signature suppressed
the update. Raw titles retain the app's leading padding space. Comparisons trim that whitespace.

## Evidence

- [Baseline ready state](runtime-baseline/ready.json), [snapshot-only result](runtime-baseline/measured.json),
  [forced-redraw control](runtime-baseline/forced-control.json), and [complete event trace](runtime-baseline/events.jsonl).
- [Fixed ready state](runtime-fixed/ready.json), [snapshot-only result](runtime-fixed/measured.json),
  and [complete event trace](runtime-fixed/events.jsonl).
- [Independent assertion script](verify_trace.py) and [verified result](verified-result.json).
- [Baseline build hashes](baseline-build-metadata.json) and [fixed build hashes](fixed-build-metadata.json).

Run `python3 verify_trace.py` in this directory to check the saved receipts. It verifies unchanged
selection, layout, defaults fingerprint, configuration revisions, plugin source hash, primary/weekly
usage, and snapshot timestamp. Both measured intervals have closed menus, inactive animation/blink/
countdown tasks, and no unexpected icon updates. The fixed trace contains an observer-origin
`updateIcons` call whose native title changes from `77%` to `80%` before returning.

## Provenance and method

The fixed production source is commit `f37cc8120f7e1cfca4f2093018f62e9e0b537528`.
The baseline uses the observation file from `7749f7b94ae8f1b84b9ffb2046643cec810f4078`.
Both runs otherwise use the same application source and identical temporary proof code.
The metadata records executable SHA-256 hashes and hashes of all temporarily instrumented files.

[The temporary harness](PluginPercentRefreshProof.swift) enters before ordinary app startup.
It supplies dictionary-backed settings, one synthetic plugin, empty credential stores, contained
files, and a manual/test-mode usage store. Merge icons, Current selection, Icon & percent, and
Monthly are set before controller creation. Startup settles for five seconds. The only measured
mutation replaces the plugin snapshot's monthly percentage, from 76.9 to 80.

[Five instrumentation lines](instrumentation.patch) record every production `updateIcons` entry
and exit. A nonnil precomputed signature identifies the existing store observer, which is its only
production caller. The hooks read state and append receipts; they do not request rendering.
The baseline's explicit forced redraw happens after its snapshot-only result is saved.

The packages use the repository's debug packaging script with the unused Widget extension
[omitted](packaging-omission.patch) after its local Xcode dependency cache failed to resolve pinned
revisions. The app, CLI helpers, resources, and Sparkle framework were freshly packaged and ad hoc
signed. A temporary [Swift wrapper](tools/swift) selects the native SwiftPM build backend.
The proof copies have distinct bundle identifiers and isolated home directories.

This proves native button state and the production observation/render path under synthetic input.
It does not assert WindowServer pixels, a live provider fetch, or personal account configuration.
The recorded proxy window geometry is informational. The zero network counter covers the injected
plugin transport. These are runtime traces, not screen recordings.

## Reproduction inputs

The harness, instrumentation patch, [bundle staging helper](stage_bundle.py), and
[launch helper](launch-proof.sh) are included. Work from a fresh checkout of the fixed production
commit above, with copies of these helpers in a fresh temporary directory.

1. Copy the harness into `Sources/CodexBar/Menu/`, then apply `instrumentation.patch`.
2. Make a temporary copy of `Scripts/package_app.sh` in `Scripts/` and omit the two Widget calls
   shown in `packaging-omission.patch`. Keep the rest of packaging unchanged.
3. Build the baseline with the pinned baseline observation file, then run `stage_bundle.py baseline`.
4. Restore the fixed observation file, build again, then run `stage_bundle.py fixed`.
5. Run `launch-proof.sh baseline` and `launch-proof.sh fixed`. Each launches the fresh bundle with
   Keychain access disabled, test file isolation, and contained `HOME`/`CFFIXED_USER_HOME`.
6. After both `measured.json` files appear, create `runtime-baseline/force` for the negative control.
   Run `verify_trace.py`, then create each run's `done` file to terminate its proof process.

Only the synthetic provider and snapshot input are substituted. Neither bundle starts ordinary
provider work or loads the installed app's account configuration. The temporary harness and hooks
are absent from the proposed production patch.
