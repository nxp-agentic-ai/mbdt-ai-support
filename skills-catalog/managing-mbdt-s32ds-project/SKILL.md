---
name: managing-mbdt-s32ds-project
description: "Use when the user asks to open, launch, or focus S32 Design Studio (S32DS) IDE from an MBDT Simulink model (S32K3); click or reproduce the S32DS Open pushbutton (S32DesignStudioProject.S32DSProject_Open); configure, set, or fix the S32DS installation path (mbdt_s32{platform}_s32ds.m); resolve 'S32DS not found', invalid path, or workspace errors; or manage S32DS workspace and project settings from MBDT. Not for building or compiling (use building-mbdt-model), changing target MCU or board template (use setting-mbdt-target-mcu), opening S32CT or EB tresos (use opening-mbdt-config-tool), editing Configuration Parameters (use setting-mbdt-model-params), or PIL/FreeMASTER setup."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.0.0"
  product: nxp-mbdt
  tags: '[mbdt, s32ds, ide]'
---

# Managing the S32 Design Studio Project (Open)

Drives the **Open** pushbutton that lives on the **S32 Design Studio project** panel of an NXP MBDT-targeted Simulink model:

- **Open** -- launches S32 Design Studio (or focuses an already-running instance) on the model's generated project. Invoked through the generic `set_mbdt_model_param` MCP tool as a pushbutton on the `S32DesignStudioProject.S32DSProject_Open` parameter.

The active MBDT platform (`s32k3`) is detected at runtime from the model's `HardwareBoard`; do not hard-code it.

MBDT locates the S32DS installation through a tiny per-toolbox pointer file `mbdt_s32{platform}_s32ds.m` that sits in the toolbox root and whose only content is a MATLAB comment line containing the S32DS install path -- e.g. `%C:\NXP\S32DS.3.6.4`. This skill treats the presence of that file as a precondition for Open and offers to create it when it is missing.

The MBDT Open callback ingests this file's raw bytes and splices them into a Windows shell command line. Any trailing byte after the path -- newline, carriage return, BOM, stray space -- ends up **inside** the quoted argv and breaks the launcher with `'"{path}' is not recognized as an internal or external command`. Get the byte format exactly right on the first write; see [Byte-exact format of the configuration file](#byte-exact-format-of-the-configuration-file).

## When to Use

- The user asks to **open the S32DS project**, **launch S32 Design Studio on this model**, or **do what the S32DS *Open* button does**.
- The user asks to **configure the S32DS path**, **point MBDT at an installed S32DS**, or **fix an Open that failed because S32DS could not be found**.

## When NOT to Use

- The user wants to **export** the S32DS project (produce an importable project tree at a chosen destination).
- The user wants to **build** the model -- use `slbuild`. This skill *requires* a prior build.
- The user wants to **change the target MCU / board / template** -- use `setting-mbdt-target-mcu`.
- The user wants to **open S32CT or EB tresos** -- use `opening-mbdt-config-tool`.
- The user wants to **edit a different Hardware Implementation parameter** (clocking, PIL, monitoring, ...) -- use `setting-mbdt-model-params`.

## Prerequisite: the model MUST be built

Open consumes the artefacts produced by a prior `slbuild(model)` / Ctrl-B. Specifically, `{model}_ert_rtw/buildInfo.mat` must exist. Without it, Open still fires as a pushbutton callback but produces no useful S32DS project.

Verify before firing Open by checking that `buildInfo.mat` exists inside the folder `{model}_ert_rtw/` that can be found in the same folder as the model. If it does not, ask the user before running `slbuild` -- a build can take minutes.

## Workflow

1. **Identify the model.** If the user did not name one, use the active MBDT-targeted Simulink model. If multiple are open, ask which.

2. **Verify the MBDT target.** Read `HardwareBoard` from the active `ConfigSet`; reject `'None'` and any non-NXP board. Confirm the corresponding MBDT family toolbox is installed via `detect_matlab_toolboxes`.

3. **Verify the S32DS path configuration file exists.** See [Verifying the S32DS path configuration](#verifying-the-s32ds-path-configuration). If it is missing, run the configuration flow *before* attempting Open. If it exists, skip the configuration step.

4. **Verify the model has been built** by testing whether `{model}_ert_rtw/buildInfo.mat` exists. If the file is missing, ask the user before running `slbuild`.

5. **Fire Open.** See [Applying Open](#applying-open).

6. **Report** briefly: whether a configuration file was created (and with what path), and confirm that the Open pushbutton was fired on the named model.

## Defaults and Disambiguation

- If the user asks to *"open the S32DS project"* without naming a model, default to the active MBDT-targeted model in memory.
- *"the project"* / *"the S32DS project"* / *"the IDE project"* all refer to the same artefact.

## Verifying the S32DS path configuration

MBDT reads the S32DS install path from a per-toolbox pointer file:

- **Location** -- `{toolboxRoot}/mbdt_s32{platform}_s32ds.m` where `{toolboxRoot}` is the value of `mbd_find_{platform}_root()` and `{platform}` is the MBDT family (`s32k3`).
- **Contents** -- exactly `%{absolute path to S32DS install root}` and nothing else. The leading `%` is required -- the file is loaded as MATLAB source and must not contain executable statements. See [Byte-exact format of the configuration file](#byte-exact-format-of-the-configuration-file) for the mandatory byte layout.

**Step 0 -- resolve `{toolboxRoot}` at runtime (mandatory, non-negotiable).** Before checking anything else on disk, call `mbd_find_{platform}_root()` via `evaluate_matlab_code` and use its returned string **verbatim** as `{toolboxRoot}`. Do NOT infer `{toolboxRoot}` from:

- the `Toolbox Install Location:` line of `get_mbdt_toolbox({family}, 'overview')` -- that field points at the `mbdtbx_{platform}` **content** subfolder, which is a different concept from the toolbox root and is NOT where the pointer file lives;
- any folder name matching `mbdtbx_{platform}` seen on disk, on the MATLAB path, or in a `which()` result;
- the current working directory, `matlabroot`, `userpath`, or any other MATLAB path entry;
- memory of a previous session's value -- the root moves when the repo moves.

The pointer file sits at the value returned by `mbd_find_{platform}_root()`, which is typically the *parent* of `mbdtbx_{platform}`. Confusing the two silently succeeds `which('mbdt_s32{platform}_s32ds')` (because `mbdtbx_{platform}` is also on the MATLAB path) while placing the file where the MBDT Open callback will not look for it.

**If the file exists at `{toolboxRoot}/mbdt_s32{platform}_s32ds.m`**, the S32DS path is already configured. Skip the rest of this section and proceed to Open.

**If the file is missing**, run this flow:

1. Read the **minimum required S32DS version** from the `S32 Design Studio Version:` line returned by `get_mbdt_toolbox({family}, 'overview')`. Never guess; never carry the version from memory across releases.
2. Enumerate **installed S32DS versions** on the host that meet or exceed that minimum. Use the platform's conventional install locations (e.g. `C:\NXP\S32DS.{version}` on Windows) and confirm each candidate by the presence of the `eclipse\s32ds.exe` (or platform-equivalent) launcher.
3. Depending on the result, act as follows:

   | Matches found | Action |
   |---|---|
   | **None** | Stop. Report the required minimum version and ask the user either to install S32DS or to give you the absolute path of an existing installation. Do not fire Open. |
   | **Exactly one** | Ask the user for consent, then create `mbdt_s32{platform}_s32ds.m` in the toolbox root using the byte-exact format below. Report the path you wrote and the file location. |
   | **Multiple** | List the candidate installations and ask the user which one to configure. Once picked, write the file using the byte-exact format below. |

4. After writing the file, run the full [post-write verification](#post-write-verification) -- do NOT fire Open until every check passes.

**Never fabricate a path.** If you cannot confirm at least one qualifying S32DS install root on disk, stop and ask.

### Byte-exact format of the configuration file

The MBDT Open callback reads this file's raw bytes and pastes them into a shell command line. The file MUST contain exactly these bytes and nothing else:

```
%{absolute-path-to-S32DS-install-root}
```

Concretely: nothing before the `%`, nothing after the last character of the path -- **not even a trailing newline**. Most "write text file" primitives (the agent's default `write` tool, `echo > file` in `cmd`/`pwsh`, most editors' Save flows) silently append a newline to conform to the POSIX "text files end with `\n`" convention. The resulting file *looks* correct when read back as text but is actually one byte too long on disk and breaks the Open callback. Bypass the text-file layer and write with a byte-level primitive that emits exactly the string given (in MATLAB: `fwrite(fid, '%{path}', 'char')` on a handle opened with `fopen(..., 'wb')`).

### Post-write verification

After writing the file, and BEFORE firing Open, confirm all of the following:

1. `which('mbdt_s32{platform}_s32ds')` returns **exactly** `fullfile(mbd_find_{platform}_root(), 'mbdt_s32{platform}_s32ds.m')` -- a byte-for-byte string comparison. A `which()` that returns *any* other path (typically one inside `mbdtbx_{platform}/`) means the file was written to the wrong folder; delete it and rewrite at `{toolboxRoot}`. `which()` returning "some path" is not sufficient -- only the exact toolbox-root path counts.
2. The file's size in bytes equals `1 + length(path)` -- proves there is no trailing newline / BOM / whitespace.
3. The last byte of the file is the last character of the path (not `0x0A`, `0x0D`, `0x20`, `0x09`, or `0x00`) -- redundant but cheap belt-and-braces check.

If any check fails, rewrite the file with a byte-level primitive at the correct location; do not proceed to Open with a suspect file. A `which()` hit alone is **not** sufficient -- it succeeds both when the file is in the wrong folder (any MATLAB-path entry with a matching filename wins) and when the file has trailing EOL bytes that will later break the shell command.

### Recognizing and self-healing a malformed configuration file

If Open has already been fired and it reports an error whose signature is
`'"{some path}' is not recognized as an internal or external command`
(note the leading unmatched double quote), that is diagnostic of a malformed `mbdt_s32{platform}_s32ds.m` -- the path itself is fine, but the file has trailing bytes that broke the shell argv. The remedy is to rewrite the file per [Byte-exact format of the configuration file](#byte-exact-format-of-the-configuration-file) and retry Open. Do not change the path; do not blame the user; do not fall back to spawning `s32ds.exe` manually.

## Applying Open

The agent calls the generic `set_mbdt_model_param` MCP tool, targeting the pushbutton leaf discovered via `detect_mbdt_params(platform).S32DesignStudioProject.S32DSProject_Open`. Arguments:

- **modelName** -- Simulink model name (no extension).
- **platform** -- MBDT family (`s32k3`), auto-detected from `HardwareBoard`.
- **group** -- `S32DesignStudioProject`.
- **tag** -- `S32DSProject_Open`.
- **selection** -- omitted / empty (pushbutton leaves ignore the value).

The tool fires the same callback the live *Open* button runs. It does not save the model.

## Examples

| User says | What the agent does |
|---|---|
| "Click the Open button on the S32DS project panel." | Verifies MBDT target + configuration file + built; calls `set_mbdt_model_param` with `group='S32DesignStudioProject'`, `tag='S32DSProject_Open'`, empty selection. Reports the click. |
| "Open the S32DS project for `{model}`." | As above, on the named model. |
| "Launch S32 Design Studio on this build." | Same, on the active model. |
| "Open failed -- MBDT says it cannot find S32DS." | Runs the [configuration flow](#verifying-the-s32ds-path-configuration); on success, retries Open. |
| "Point MBDT at my S32DS install." | Runs the configuration flow (asks or auto-picks depending on how many qualifying installations are found). Does not fire Open unless the user also asks for it. |

## Guardrails

- **Never fabricate runtime values.** The button tag (`S32DSProject_Open`) and its parent group (`S32DesignStudioProject`) are declared *authoritative* by `detect_mbdt_params(platform)`. If you cannot confirm them at runtime for the active platform, stop and re-discover -- do not carry them from memory across releases.
- **Never infer the toolbox root; always resolve it at runtime.** Before touching the pointer file, call `mbd_find_{platform}_root()` via `evaluate_matlab_code` and use its returned string verbatim as `{toolboxRoot}`. Do NOT substitute the `Toolbox Install Location:` from `get_mbdt_toolbox` (that points at `mbdtbx_{platform}/`, a different folder), any `mbdtbx_{platform}` folder found on disk or on the MATLAB path, `matlabroot`, `userpath`, or a cached value from a previous session. Placing the file in `mbdtbx_{platform}/` silently passes `which()` but the MBDT Open callback will not find it.
- **Never fabricate the minimum S32DS version.** Read it fresh from `get_mbdt_toolbox({family}, 'overview')` on every configuration-flow run. The value changes per toolbox release.
- **Never fabricate an S32DS install path.** Only write `mbdt_s32{platform}_s32ds.m` when at least one qualifying installation was confirmed on disk. If you find zero, stop and ask the user for a path.
- **Never write the configuration file without user consent** when the choice is ambiguous. Exactly-one-match: ask for confirmation, then write. Multiple matches: ask the user to pick before writing. Zero matches: do not write.
- **Always preserve the byte-exact file format.** `mbdt_s32{platform}_s32ds.m` must be exactly `%{absolute path}` -- first byte `%`, last byte the last character of the path, size = `1 + length(path)`. No trailing newline (LF / CRLF / CR), no BOM, no trailing whitespace, no blank leading lines, no multiple lines, no executable statements. See [Byte-exact format of the configuration file](#byte-exact-format-of-the-configuration-file).
- **Never write the configuration file with a naive text-write flow.** The default `write` tool, `echo > file` in `cmd`/`pwsh`, and most editor "save as UTF-8" flows all append a trailing newline and produce a file that *looks* right but breaks the Open callback. Use a byte-level primitive (e.g. MATLAB `fwrite` on a file opened with `'wb'`) that writes exactly the specified bytes.
- **Always run the [post-write verification](#post-write-verification) before firing Open** whenever the configuration file was just created or modified. `which('mbdt_s32{platform}_s32ds')` returning *some* path is not sufficient -- it must return **exactly** `fullfile(mbd_find_{platform}_root(), 'mbdt_s32{platform}_s32ds.m')`. Also check the file size in bytes and the last byte.
- **On the `'"{path}' is not recognized ...` error signature, rewrite the config file, do not change the path.** That specific error means the path is correct but the file has trailing junk bytes; see [Recognizing and self-healing a malformed configuration file](#recognizing-and-self-healing-a-malformed-configuration-file). Do not fall back to spawning `s32ds.exe` / `eclipsec.exe` directly.
- **Never include implementation code in this SKILL.md.** The Applying and Verifying sections name tools, arguments, and canonical values; they must not embed multi-statement MATLAB, shell pipelines, or JSON algorithms.
- **Never operate on a microcontroller without first verifying the MBDT family toolbox is installed** via `detect_matlab_toolboxes`. `HardwareBoard` on the model is *not* proof of installation.
- **Always drive Open through `set_mbdt_model_param`.** Do not spawn `s32ds.exe` / `eclipsec.exe` directly, do not write a hand-built command line, and do not call `mbd_{platform}.common.nxp.ui.openS32DSProject` from `evaluate_matlab_code` -- the MBDT callback handles the *"S32DS already running"* case and the workspace-import handshake that a raw process spawn skips.
- **For non-MBDT targets, stop and report.** Do not attempt Open on a model whose `HardwareBoard` is not an NXP MBDT board.
- **Do not save the model as a side effect.** Open does not require saving.

## Validation loop

1. Verify that `set_mbdt_model_param` returned without error for the `S32DSProject_Open` pushbutton.
2. If S32DS was already running, the MBDT callback will show a focus-request message; that is expected and not an error.
3. If the configuration file was created or modified, re-run post-write verification before declaring success.
4. Report the S32DS launch outcome and, if applicable, the configuration file path that was written.

## References

- `opening-mbdt-config-tool` -- launch S32CT / EB tresos (the *other* external tool a Hardware Implementation pane can open).
- `setting-mbdt-target-mcu` -- change the target MCU / board / template before building.
- `setting-mbdt-model-params` -- edit any other Hardware Implementation parameter.
