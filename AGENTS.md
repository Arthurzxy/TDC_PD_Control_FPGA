# Project Rules

## Vivado Tcl

- Do not attach temporary/debug/test Tcl scripts to `synth_1`, `impl_1`, or IP run hooks.
- Do not set `STEPS.*.TCL.PRE`, `STEPS.*.TCL.POST`, `PreStepTclHook`, or `PostStepTclHook` unless the user explicitly asks for a persistent production hook.
- Run temporary Tcl manually with `source <script>.tcl`.
- Do not place custom source Tcl under `.runs`, `.hw`, `.cache`, `.gen`, or `.ip_user_files`.
- Use `$env:VIVADO_BIN` to run Vivado. Do not guess other Vivado paths unless this configured path fails.

## Build Consistency

- If RTL, XDC, ILA probes, debug cores, or state names change, rerun from `synth_1` through `write_bitstream`.
- Use `.bit` and `.ltx` from the same `impl_1` run.
- If Hardware Manager shows stale ILA names or states, close Vivado and delete `.hw`.

## Cleanup

- Generated Vivado output may be deleted: `.Xil`, `*.cache`, `*.gen`, `*.hw`, `*.ip_user_files`, `*.runs`, `*.sim`.
- Do not delete HDL, XDC, IP `.xci`, datasheets, or `.xpr` unless explicitly requested.
