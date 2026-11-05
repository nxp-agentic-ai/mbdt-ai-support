---
name: inserting-mbdt-custom-code
description: "Use when the user wants to add custom C source files, header search paths, inline C snippets, or custom startup calls to an NXP MBDT Simulink model via the Simulink Custom Code pane or a Custom entry in the Board Initialization sequence. Do not activate for editing an existing catalog component (use editing-mbdt-board-init), changing the target MCU (use setting-mbdt-target-mcu), or configuring driver blocks (use configuring-mbdt-blocks)."
license: LA_OPT_Online Code Hosting NXP_Software_License
metadata:
  author: NXP
  version: "1.1.0"
  product: nxp-mbdt
  tags: '[mbdt, custom-code, board-init, integration]'
---

# Inserting Custom C Code into NXP MBDT Models

Use this skill to integrate user-supplied or RTD C code into a Simulink model that targets any NXP MBDT platform, either through the Simulink Custom Code configuration pane, the MBDT Board Initialization sequence, or both.

The governing principle is **live discovery, never memory**: toolbox availability comes from `detect_matlab_toolboxes`, current board-init components and their code come from `get_mbdt_board_init`, and current Custom Code pane values come from `get_param(modelName, fieldName)`. Writes use `set_param` (Custom Code pane) and `set_mbdt_board_init` (Board Init). All MATLAB calls run through the `evaluate_matlab_code` MCP tool.

**Important -- two Custom Code panes exist in Simulink:**

- **Code Generation pane** (Configuration Parameters -> Code Generation -> Custom Code): controls what is compiled into the generated embedded code. Parameter names are `CustomSource`, `CustomInclude`, `CustomSourceCode`, `CustomInitializer`, `CustomTerminator`, `CustomLibrary`, `CustomDefine`, `CustomHeaderCode`.
- **Simulation Target pane** (Configuration Parameters -> Simulation Target): controls what is available during normal-mode and accelerator-mode desktop simulation. Parameter names: `SimUserSources`, `SimUserIncludeDirs`, `SimUserLibraries`, `SimUserDefines`, `SimCustomSourceCode`, `SimCustomHeaderCode`, `SimCustomInitializer`, `SimCustomTerminator` (checked on MATLAB R2024b). If a `get_param` fails on another release, list the names with `fieldnames(get_param(modelName, 'ObjectParameters'))`.

For NXP MBDT embedded deployment the **Code Generation pane** parameters are the primary target. SIL/PIL compile the generated code and therefore use Code Generation pane fields -- Path A/C already covers SIL without any Simulation Target pane changes. The Simulation Target pane is needed only when the custom code must also be exercised in normal-mode or accelerator-mode desktop simulation (Path D, described in Step 2).

## When to Use

- **Add a custom `.c` source file** to the build (`"include my_driver.c in the build"`).
- **Add a custom header search path or `#include`** globally (`"add include path for my rtd header"`).
- **Add inline C snippet** that runs before or after the model step (`CustomSourceCode`, `CustomInitializer`).
- **Insert a startup RTD call** into `mbdt_board_init.c` (`"call MyDriver_Init at startup"`, `"add a Custom entry to board init"`).
- **Combine both** -- declare a symbol in the Custom Code pane, then call it from a Board Init `Custom` component (Path C).
- Ask which integration path is appropriate for a given RTD driver call.

## When NOT to Use

- **Configuring an existing MBDT driver block** (Can, Adc, Dio, Pwm, ...) -> use `configuring-mbdt-blocks`.
- **Editing the Code, Header, Priority, or Enabled flag of a named catalog component** (Mcu, Port, Adc, ...) already in the Board Init sequence -> use `editing-mbdt-board-init`.
- **Changing the target MCU or configuration template** -> use `setting-mbdt-target-mcu`.
- **Opening the external config tool** (S32CT or EB tresos) -> use `opening-mbdt-config-tool`.
- **Model structural edits** (adding blocks, wiring signals) -> use a model-building skill.
- **Stubbing a missing RTD C function** -- never synthesize RTD function bodies; see Guardrails.

## Workflow

### Step 1 -- Identify model and verify toolbox installation

1. **Identify the model.** If unspecified, use the currently focused MBDT-targeted Simulink model. If multiple models are open, ask which one.
2. **Confirm the model targets an MBDT platform.** Call `get_mbdt_board_init('{modelName}', 'none')`. If the call succeeds, note the `platform` field returned (e.g. `s32k3`) -- it is needed in the next step. If the call fails, handle by error type:
   - `UnsupportedPlatform` or any error indicating the model is not MBDT-targeted: stop and report that this skill applies only to NXP MBDT models.
   - `MATLAB:UndefinedFunction` on the MBDT functions (the NXP MBDT AI Support is not on the MATLAB path or its MCP tools are not registered): stop and ask the user to complete the toolkit setup from the toolkit README (add it to the MATLAB path, register the MCP tools, restart the MATLAB MCP server). Do not run `mbdt_ai_support_path()` yourself, it modifies the saved MATLAB path.
   - `NamespaceMissing` (message contains `mbd_{family}.common.nxp` or similar): the MBDT toolbox for this model's platform is not on the path. Stop and instruct the user to install the matching MBDT toolbox. Skip sub-step 3 (it is unreachable).
   - Any other error: report the error verbatim and stop.
3. **Verify the matching toolbox is installed.** Call `detect_matlab_toolboxes` and confirm that at least one entry contains `Model-Based Design Toolbox` (match loosely -- the exact display name may vary by release). If no such entry is found, stop and instruct the user to install the MBDT toolbox.

### Step 2 -- Identify the integration path

Ask the user (or infer from context) which path applies:

- **Path A -- Custom Code pane only**: the custom code is a standalone C file or snippet that does not need to run at board startup (e.g. a helper function called from a MATLAB Function block or S-Function).
- **Path B -- Board Initialization only**: an RTD function or custom startup routine must be called at boot, and its symbols are already available (provided by the RTD driver's own generated files or a pre-built library).
- **Path C -- Both panes**: custom symbols must be declared to the compiler (Path A) AND called at startup (Path B). This is the typical scenario when integrating a third-party RTD driver that ships its own `.c`/`.h` files.
- **Path D -- Simulation Target pane**: the custom code must also be exercised in normal-mode or accelerator-mode desktop simulation. (SIL/PIL compile the generated code using Code Generation pane fields -- Path A/C is sufficient for SIL; Path D is not needed for SIL.) Apply Path A first, then mirror the same changes to the `Sim*` parameters.

### Step 3 (Path A or C) -- Read ALL Code Generation Custom Code pane values

Before writing, read every field to avoid clobbering existing content:

```
get_param('{modelName}', 'CustomSource')
get_param('{modelName}', 'CustomInclude')
get_param('{modelName}', 'CustomSourceCode')
get_param('{modelName}', 'CustomInitializer')
get_param('{modelName}', 'CustomTerminator')
get_param('{modelName}', 'CustomLibrary')
get_param('{modelName}', 'CustomDefine')
get_param('{modelName}', 'CustomHeaderCode')
```

Append the new content to whatever is already there. Never replace non-empty fields with only the new value.

**Path D addition -- also read the Simulation Target pane fields:**

```
get_param('{modelName}', 'SimUserSources')
get_param('{modelName}', 'SimUserIncludeDirs')
get_param('{modelName}', 'SimCustomSourceCode')
get_param('{modelName}', 'SimCustomInitializer')
get_param('{modelName}', 'SimCustomHeaderCode')
get_param('{modelName}', 'SimCustomTerminator')
get_param('{modelName}', 'SimUserLibraries')
get_param('{modelName}', 'SimUserDefines')
```

If any `get_param` call fails with an unknown parameter error, verify the exact name for this release using `fieldnames(get_param('{modelName}', 'ObjectParameters'))` and filter for names containing `Sim`.

### Step 4 (Path A, C, or D) -- Apply Custom Code pane changes

Use `set_param` to write the updated value. The fields accept the following content types:

| Field | Content type | Notes |
|---|---|---|
| `CustomSource` | List of `.c` file paths to compile and link | Paths separated by spaces, commas, newlines, or semicolons. Relative paths are resolved from the model folder (use `./` prefix). Do NOT list `.h` files here. |
| `CustomInclude` | List of folder paths containing headers | Each entry is a plain **folder path** (e.g. `C:/myproject/include`). Do NOT prefix with `-I` -- the compiler flag is added automatically. Separators: spaces, commas, newlines, semicolons. |
| `CustomSourceCode` | Raw C text inserted at the top of the generated `.c` file | Use `extern` declarations (`extern int x;`, `extern void f(void);`) or `#include "myfile.h"` lines. Do NOT write full definitions (`int x;`, `void f(void) {...}`) -- they cause linker errors from duplicate symbols. |
| `CustomHeaderCode` | Raw C text inserted into the generated model header (`.h`) file | Allowed: `#include`, `#define`, `typedef`/`struct`/`enum`, `extern` declarations, `static inline` functions. Not allowed: non-`static` variable or function definitions (the header is included by several translation units, so they cause duplicate-symbol errors). Separator for appends: newline. |
| `CustomInitializer` | C statement(s) called once at model initialization | Runs in the generated code initialization function (covers both SIL execution and the embedded executable startup). For hardware board startup, use Board Init instead (Path B/C). Code lines must be full C statements ending with `;`. |
| `CustomTerminator` | C statement(s) called once at model termination | Symmetric to `CustomInitializer`. |
| `CustomLibrary` | List of static library file paths (`.lib` / `.a`) to link | Separators: spaces, commas, newlines, semicolons. |
| `CustomDefine` | Space-separated preprocessor macro definitions | Write plain `NAME` or `NAME=value` entries, e.g. `'MY_FLAG=1 DEBUG_LEVEL=2'`. The build adds `-D` itself; a `-D` prefix is also accepted and not doubled (verified on R2024b, ERT code generation). Unlike `CustomInclude` (which rejects `-I`), either form is valid here. |

For Path D, apply the same change to the matching Simulation Target parameter:

| Code Generation pane | Simulation Target pane |
|---|---|
| `CustomSource` | `SimUserSources` |
| `CustomInclude` | `SimUserIncludeDirs` |
| `CustomLibrary` | `SimUserLibraries` |
| `CustomDefine` | `SimUserDefines` |
| `CustomSourceCode` | `SimCustomSourceCode` |
| `CustomHeaderCode` | `SimCustomHeaderCode` |
| `CustomInitializer` | `SimCustomInitializer` |
| `CustomTerminator` | `SimCustomTerminator` |

The `Sim*` list fields (`SimUserSources`, `SimUserIncludeDirs`, `SimUserLibraries`, `SimUserDefines`) follow the same separators and duplicate check as their Code Generation counterparts; the `Sim*` code-text fields (`SimCustomSourceCode`, `SimCustomHeaderCode`, `SimCustomInitializer`, `SimCustomTerminator`) use the newline recipe.

Path syntax notes: use `./pathname` for paths relative to the model folder; use `$VarName$` to evaluate a MATLAB workspace variable as a path fragment; enclose paths containing spaces or hyphens in double quotes.

Use absolute paths when the model may be opened from different working directories.

### Step 5 (Path B or C) -- Read current Board Init sequence

Call `get_mbdt_board_init('{modelName}', 'none')` to retrieve the live component sequence, including the `Code` content of each component, and confirm no `Custom` entry with the intended code already exists.

`set_mbdt_board_init` with `field='Insert'` and `componentName='Custom'` **always appends** -- the tool performs no duplicate check for `Custom` entries. Re-running after a partial failure would create a second copy of the same init call. Before inserting, run the recipe below; if a match is found, skip the insert and report the existing component's Priority to the user:

```matlab
info = get_mbdt_board_init('{modelName}', 'none');
newLines = {'{line1}', '{line2}'};          % the Code lines you intend to insert
% Note: in a MATLAB string literal, a single quote must be doubled: 'It''s'.
customIdx = find(strcmp({info.components.Name}, 'Custom'));
alreadyPresent = false;
existingPriority = [];
for k = customIdx
    if ~info.components(k).Enabled, continue; end
    existingCode = info.components(k).Code;
    if all(ismember(strtrim(newLines), strtrim(existingCode)))
        alreadyPresent = true;
        existingPriority = info.components(k).Priority;
        break;
    end
end
if alreadyPresent
    fprintf('Custom entry already present at Priority=%g -- skipping insert.\n', existingPriority);
end
```

### Step 6 (Path B or C) -- Insert the Board Init component

Call `set_mbdt_board_init` with `field='Insert'` and `componentName='Custom'`. Supply at minimum:

- `Code`: a JSON array of C statement strings, one per line.
- `Header`: a JSON array of header filenames required by the code (optional but recommended).
- `Priority`: a number (lower = emitted earlier). Use the string `"Inf"` for a tail call after all catalog components (the most common case). For a call that must precede all active components, compute the priority from the live sequence -- see Defaults and Disambiguation. **Pass `"Inf"` as a JSON string, not as a JSON number** -- `jsonencode(Inf)` produces `null`; omitting `Priority` or passing `null` causes `set_mbdt_board_init` to default to `Inf`, but passing the explicit string `"Inf"` is unambiguous and recommended.

The tool appends the component, re-sorts by priority, saves the model, and returns `insertedIndex`. Read that value to confirm placement.

**Multiple Custom entries**: if the model already has two or more `Custom` entries with the same `Priority`, subsequent non-Insert edits targeting `componentName='Custom'` will emit an `AmbiguousName` warning and target the first one in storage order. Assign distinct priorities to Custom entries you intend to address individually after insertion.

### Step 7 -- Verify

After all writes, run the [Validation loop](#validation-loop) below. It is the single source of truth for post-write verification; do not repeat its checks here.

## Validation loop

Run after all writes (Step 7).

1. For each modified Custom Code pane field, call `get_param('{modelName}', '{field}')` and confirm the expected content is present and no prior content was lost.
2. If a `Custom` Board Init component was inserted, call `get_mbdt_board_init('{modelName}', 'full')` and confirm that the entry at the `insertedIndex` returned by `set_mbdt_board_init` has `Enabled=true`, the expected `Priority`, and the expected `Code` and `Header` lines. (`'summary'` prints only line counts, not the code.)
3. For Custom Code pane changes (Path A/C/D), call `save_system('{modelName}')` to persist them. Board Init changes are already saved by `set_mbdt_board_init`; a second `save_system` is harmless but not required.
4. Confirm `get_param('{modelName}', 'Dirty')` returns `'off'` after saving.
5. Instruct the user to build the model and check for compile/link errors before declaring success. Static verification here cannot catch path issues or missing generated config units.

**Error handling:** if any write or check fails, surface the error verbatim and stop. Do not retry, and do not substitute fabricated values, unless a step above documents a specific recovery. For `set_mbdt_board_init:*` errors (e.g. `VerifyFailed`), report the error and ask the user to inspect the model or the on-disk Board Init JSON.

## Defaults and Disambiguation

- When the user says `"add my_driver.c"` without specifying a field, default to `CustomSource`.
- When the user says `"add an include path"` without specifying a field, default to `CustomInclude`.
- When the user says `"call {function}_Init at startup"` and the function is an RTD init, default to Path B (Board Init `Custom` component at `Priority="Inf"`). Do **not** also add the same call to `CustomInitializer`: it runs in the generated code initialization function, which executes on hardware at model-init time too, so the init would run twice on target. Many RTD `*_Init` functions are not safe to call twice.
  - If the user needs the init in SIL, state explicitly that on hardware it will then run from both Board Init and model init, and proceed only if the user confirms the function is documented as safe to call more than once.
  - For normal/accelerator desktop simulation (not SIL), use Path D instead.
- When the user says `"add inline code"` without specifying a field, ask whether it should be in `CustomSourceCode` (compile-time declaration/include), `CustomInitializer` (model init), or a Board Init `Custom` component (hardware startup). These run at different times and are not interchangeable.
- **Priority for Board Init Custom components:** use `"Inf"` (as a string) for a tail call (after all catalog components -- this is the most common case). For a call that must precede all currently active components, read the live sequence and compute dynamically:

```matlab
info = get_mbdt_board_init('{modelName}', 'none');
enabled = info.components([info.components.Enabled]);
p = [enabled.Priority];
finite_p = p(isfinite(p));
if isempty(finite_p)
    newPrio = 0;   % no finite-priority components; place before the default Inf tail
else
    newPrio = min(finite_p) - 1;   % just before the earliest active component
end
```

Never hardcode `1`: it does not guarantee "before everything", because a catalog component may already use an equal or lower priority. Components with equal priority are emitted in alphabetical order by `Name`. Compute the value relative to what is actually in the sequence.

**Placement relative to a named component** (the usual case: the call depends on `Mcu`/clock/`Port` having run). Ask the user which component the call must follow if the order is not obvious; never guess a name.

```matlab
info    = get_mbdt_board_init('{modelName}', 'none');
iAnchor = find(strcmp({info.components.Name}, '{AnchorComponent}'), 1);
if isempty(iAnchor)
    error('Component not found in the live sequence -- stop and report; do not guess.');
end
anchorP = info.components(iAnchor).Priority;
allP    = [info.components.Priority];
nextP   = min(allP(allP > anchorP));      % [] if the anchor is last
if isinf(anchorP)
    % Anchor is a tail entry (Priority=Inf). Setting newPrio=Inf places
    % the new Custom component at Inf too, and components with equal
    % priority are sorted alphabetically by Name. 'Custom' < 'Mcu',
    % 'Port', 'Spi', etc., so the new entry would land BEFORE those
    % anchors, not after them. Check whether the anchor's own Name
    % sorts after 'Custom'; if so, warn and stop.
    anchorName = info.components(iAnchor).Name;
    sorted2    = sort({anchorName, 'Custom'});
    if ~strcmp(anchorName, 'Custom') && strcmp(sorted2{2}, anchorName)
        warning(['Anchor ''%s'' has Priority=Inf and its Name sorts AFTER ' ...
                 '''Custom'' alphabetically. Inserting at Inf would place ' ...
                 'the new Custom entry BEFORE it, not after. Confirm the ' ...
                 'resulting order with the user before proceeding, or use ' ...
                 'editing-mbdt-board-init to assign the anchor a finite ' ...
                 'priority (note: this reorders all existing Inf entries).'], ...
                '{AnchorComponent}');
        return;   % stop; do not proceed with the insert
    end
    newPrio = Inf;
elseif isempty(nextP) || isinf(nextP)
    newPrio = anchorP + 1;
else
    newPrio = (anchorP + nextP) / 2;      % strictly between anchor and the next component
end
```

## Applying the Change

All MATLAB calls in this skill run through the `evaluate_matlab_code` MCP tool. The patterns are:

**Read a Custom Code field:**
```matlab
get_param('{modelName}', '{fieldName}')
```

**Append to a Custom Code field (never replace blindly):**

Use the separator that matches the field's content type: a single space (` `) for list-of-paths fields (`CustomSource`, `CustomInclude`, `CustomLibrary`), a newline (`\n`) for code-text fields (`CustomSourceCode`, `CustomHeaderCode`, `CustomInitializer`, `CustomTerminator`), or a single space with token-level duplicate check for `CustomDefine`.

For list-of-paths fields, check membership element-wise -- a substring check would falsely match `'data.c'` when searching for `'a.c'`:

```matlab
% Append to a list-of-paths field (element-wise duplicate check)
field    = 'CustomSource';   % or CustomInclude / CustomLibrary (Sim*: SimUserSources / SimUserIncludeDirs / SimUserLibraries)
existing = get_param('{modelName}', field);
item     = '{new_file.c}';
tokens   = regexp(existing, '"[^"]*"|[^\s,;]+', 'match');
tokens   = strtrim(tokens);
tokens   = tokens(~cellfun(@isempty, tokens));
% Strip surrounding quotes so comparison works for quoted paths.
tokens   = regexprep(tokens, '^"|"$', '');
% Quote item for storage if it contains whitespace or hyphens.
if ~isempty(regexp(item, '[\s-]', 'once'))
    item_stored = ['"' item '"'];
else
    item_stored = item;
end
% NOTE: a relative path (e.g. './a.c') and its absolute equivalent are
% treated as different entries; this is a known limitation.
if ~any(strcmp(tokens, item))
    if isempty(existing) || all(isspace(existing))
        new_val = item_stored;
    else
        new_val = [strtrim(existing) ' ' item_stored];
    end
    set_param('{modelName}', field, new_val);
end
```

For code-text fields, a line-level duplicate check is sufficient:

```matlab
% Append to a code-text field (line-level duplicate check)
existing = get_param('{modelName}', 'CustomSourceCode');
item     = 'extern void {MyFunc}(void);';
lines    = strtrim(strsplit(existing, newline, 'CollapseDelimiters', false));
if ~any(strcmp(lines, item))
    if isempty(strtrim(existing))
        new_val = item;
    else
        new_val = [existing newline item];
    end
    set_param('{modelName}', 'CustomSourceCode', new_val);
end
```

For space-separated option fields (`CustomDefine`), join with a single space and skip the item if it is already one of the whitespace-separated tokens:

```matlab
% Append to a space-separated options field (token-level duplicate check)
% Both 'NAME=value' and '-DNAME=value' are accepted; normalise by stripping
% a leading -D before comparing so the same define in either form is not
% added twice.
field    = 'CustomDefine';
existing = strtrim(get_param('{modelName}', field));
item     = '{MACRO=1}';                  % plain form recommended; -D prefix also accepted
tokens   = regexprep(strsplit(existing), '^-D', '');   % normalise for comparison only
item_norm = regexprep(item, '^-D', '');
if ~any(strcmp(tokens, item_norm))
    if isempty(existing), new_val = item; else, new_val = [existing ' ' item]; end
    set_param('{modelName}', field, new_val);
end
```

**Insert a Custom Board Init component (via set_mbdt_board_init tool, not evaluate_matlab_code):**

Use `set_mbdt_board_init` directly with `field='Insert'`, `componentName='Custom'`, and a `valueJson` object containing `Code`, `Header`, and `Priority`. Example for a tail call:

```json
{
  "Code": ["MyDriver_Init(&{Config});"],
  "Header": ["MyDriver.h"],
  "Priority": "Inf"
}
```

Note: `Priority` must be the string `"Inf"`, not the JSON number `Infinity` -- pass it as a quoted string in the JSON object.

**Save the model (Custom Code pane changes only):**
```matlab
save_system('{modelName}');
```

## Examples

| User request | Path | Primary tool / field |
|---|---|---|
| "Add {my_init.c} to the build for my model" | A | `set_param(m, 'CustomSource', ...)` |
| "Add folder path for RTD headers" | A | `set_param(m, 'CustomInclude', ...)` (plain folder path, no `-I`) |
| "Include {my_driver.h} at the top of the generated C file" | A | `set_param(m, 'CustomSourceCode', '#include "{my_driver.h}"')` |
| "Call {MyDriver_Init} at model init (not hardware startup)" | A | `set_param(m, 'CustomInitializer', '{MyDriver_Init}(...);')` |
| "Call {function}_Init at board startup before the RTD drivers" | B | `set_mbdt_board_init`, Insert, Priority=computed `min(finite)-1` from live sequence. Placing a call at the very start precedes clock and port setup; use the anchor recipe when the call depends on them. |
| "Add a custom board init call after all RTD inits" | B | `set_mbdt_board_init`, Insert, `valueJson.Priority="Inf"` (string) |
| "Call {function}_Init after {Anchor}_Init" | B | `set_mbdt_board_init`, Insert, Priority computed with the anchor recipe |
| "Integrate my third-party RTD driver: add its .c/.h and call its Init at startup" | C | Path A (CustomSource + CustomInclude) then Path B (Board Init Insert) |
| "My custom code must also run in normal/accelerator desktop simulation" | D | Path A first, then mirror to the `Sim*` counterparts (`SimUserSources`, `SimUserIncludeDirs`, `SimCustomSourceCode`, ...; see the mapping table in Step 4). SIL uses the Code Generation pane -- Path A/C is sufficient. |

## Guardrails

- **Never fabricate component names, priorities, or RTD function signatures from memory.** Component names come from `get_mbdt_board_init` output; RTD function names come from the user or from the driver documentation. Do not guess.
- **Never include implementation code in this skill.** Do not synthesize, stub, or write RTD C function bodies or driver implementation code. If a required RTD function is missing from the build, the root cause is a config-tool-side problem (missing generated unit) or a missing source file -- not a model-side problem. Direct the user to open the external config tool (S32CT or EB tresos), run its validation, and read the actual errors. Use `opening-mbdt-config-tool` for that step.
- **Never replace a non-empty Custom Code field with only the new content.** Always read first (`get_param`), then append idempotently, then write (`set_param`). Overwriting discards the user's existing custom code.
- **Never write a `-I` prefix into `CustomInclude`.** The field expects plain **folder paths**. The compiler `-I` flag is added automatically by the build system. Writing `-I/path/to/headers` results in a double `-I` compiler argument and a failed build.
- **Never write a `.h` file path to `CustomSource`.** `CustomSource` is for `.c` files only. Header folder paths go into `CustomInclude`; inline `#include` directives go into `CustomSourceCode`.
- **Use element-wise duplicate detection when appending to list-of-paths fields.** A substring check (`contains`) would falsely match `'a.c'` inside `'data.c'`. Split on separators and use `strcmp` for element-wise comparison.
- **Never hardcode `Priority=1`.** A catalog component may already hold that priority. Read the live sequence with `get_mbdt_board_init` and compute the desired priority relative to what is actually there.
- **Verify toolbox installation before any write.** Step 1 must succeed first: `get_mbdt_board_init` returns without error and `detect_matlab_toolboxes` lists at least one `Model-Based Design Toolbox` entry. Stop and report on absence; never infer the platform from the model name.
- **Do not mix Path A and Path B semantics.** `CustomInitializer` is a Code Generation pane field; it runs in the generated code initialization function, covering both SIL execution and the embedded executable startup. The Board Init `Custom` component runs at hardware board startup inside `mbdt_board_init.c`. Both may be needed for a full embedded deployment (Path C), but they are not the same call site. For normal-mode or accelerator-mode desktop simulation only, use Path D (Simulation Target pane).
- **Do not bypass `set_mbdt_board_init` for Board Init writes.** Never call `nxp.settings.*` or `codertarget.data.setParameterValue` from `evaluate_matlab_code` for the write side. The tool handles platform detection, two-layer persistence, and on-disk verification.

## References

- `get_mbdt_board_init` -- MCP tool that returns the live Board Init sequence with auto-detected platform. Use `detail='none'` for the duplicate-check recipe in Step 5; use `detail='full'` in the Validation loop (Step 7) to verify the inserted component's Code and Header lines.
- `set_mbdt_board_init` -- MCP tool that inserts, edits, and saves Board Init components. Use with `field='Insert'` and `componentName='Custom'` for this skill's Path B/C. Pass `Priority` as the string `"Inf"` when a tail call is needed.
- `detect_matlab_toolboxes` -- MCP tool that returns installed MATLAB toolboxes. Read in Step 1 to verify the target MBDT toolbox is installed.
- `editing-mbdt-board-init` -- the companion skill for editing Code, Header, Priority, or Enabled on an existing named catalog component. Use that skill when modifying `Mcu`, `Port`, `Adc`, etc.; use this skill to insert a new `Custom` entry.
