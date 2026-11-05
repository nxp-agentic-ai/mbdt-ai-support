# Rdc_Checker -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the Rdc_Checker
(Resolver-to-Digital Converter checker) peripheral on NXP MBDT-targeted
Simulink models. This document describes the behavior of the `Rdc_Checker`
block (`MaskType = s32k3_rdc_checker`), the initialization pattern, and
the external-config-tool dependencies. Verified on S32K3 only -- this
block lives in `mbd_s32k3_cdd_library` and is S32K3-specific.

> **Tip -- start from a shipped example.** Open a shipped Rdc_Checker
> example via [`opening-mbdt-example`](../../opening-mbdt-example/SKILL.md);
> its `.mex` project plus its model forms a coherent end-to-end reference.
> Never carry example names from memory -- discover them at runtime via
> `get_mbdt_toolbox('s32k3','examples')`.

---

## 1. Peripheral Overview

The Rdc_Checker CDD wraps the NXP Resolver-to-Digital Converter (RDC)
fault-detection logic on S32K3 devices. It monitors resolver signals for
fault conditions (amplitude, phase, frequency deviations) and provides
fault status readback and threshold reconfiguration.

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT project: Peripherals -> Rdc_Checker instance and threshold declarations | External to the model | External config tool |
| 2 | Board-init entry `Rdc_Checker_Init(...)` | `mbdt_board_init.c` | `editing-mbdt-board-init` skill |
| 3 | Initialize Function blocks (optional fault-clear, threshold setup) | Simulink model | This skill |
| 4 | Runtime blocks for fault monitoring | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1) -> `instance`, `threshold`, `xResolver` enums hold sentinels.
- Missing (2) -> build links but RDC checker is never initialized.
- Missing (4) -> no fault status is read.

---

## 2. The `Rdc_Checker` Block -- Complete Behavioral Model

**One `Rdc_Checker` block = one `Rdc_Checker_*` function call.**
The block has `MaskType = s32k3_rdc_checker`.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param({blk}, 'DialogParameters')`. Illustrative entries (S32K3 MBDT 1.8.0):

- `Rdc_Checker_DetectFaults` -- trigger fault detection run
- `Rdc_Checker_ReadFaultStatus` -- read the current fault status
- `Rdc_Checker_ChangeThresholdsConfig` -- reconfigure detection thresholds at runtime
- `Rdc_Checker_ResolverCallback` -- resolver signal callback handler
- `Rdc_Checker_GetVersionInfo` -- version query (no instance needed)

Selecting `api_func` reshapes the S-Function ports. **Set `api_func` first.**

### 2.2 Parameter surface

| Name | Type | Semantics | Meaningful for |
|---|---|---|---|
| `api_func` | enum | Function selector (Sec.2.1) | All |
| `instance` | enum | Logical Rdc_Checker instance | All except `GetVersionInfo` |
| `threshold` | enum | Threshold configuration name | `ChangeThresholdsConfig` |
| `xResolver` | enum | Resolver channel selector | `ResolverCallback` and select functions |
| `text` | string | System-managed cache -- **never set** | Read-only |

### 2.3 Resource enums

All three resource enums (`instance`, `threshold`, `xResolver`) are
populated by the config tool. Sentinels:
- `"No Instances configured"` -- add in Peripherals -> Rdc_Checker
- `"No Thresholds configured"` -- add threshold config in Peripherals -> Rdc_Checker
- `"No Resolvers configured"` -- add resolver channel in Peripherals -> Rdc_Checker

### 2.4 Sentinel rules

| `api_func` | Sentinel = error? |
|---|---|
| `Rdc_Checker_GetVersionInfo` | NO |
| All others | YES -- route to `opening-mbdt-config-tool` |

### 2.5 Port signatures per `api_func`

Port types not verified live; read from block after setting `api_func`.

| `api_func` | Inputs | Outputs |
|---|---|---|
| `Rdc_Checker_DetectFaults` | none | y1: status |
| `Rdc_Checker_ReadFaultStatus` | none | y1: fault status bitmask |
| `Rdc_Checker_ChangeThresholdsConfig` | none | y1: status |
| `Rdc_Checker_ResolverCallback` | none | none (ISR-style handler) |
| `Rdc_Checker_GetVersionInfo` | none | y1: version info |

> **Note:** Always read port types live from the block after setting `api_func`.

### 2.6 Selection ordering

1. `api_func` first.
2. `instance`, then `threshold` or `xResolver` as exposed.
3. One `set_param` per parameter.

---

## 3. Required Block Catalog

| Block name | Library | Role |
|---|---|---|
| `Rdc_Checker` | `mbd_s32k3_cdd_library` | Wraps one `Rdc_Checker_*` function |
| `Hardware_Interrupt_Handler` | `mbd_s32k3_isr_library` | Routes `ResolverCallback` ISR (if async mode used) |

---

## 4. Configuration Workflow

### 4.1 Pins
Route resolver excitation, SIN/COS signal pins per instance.
Pin numbers are board-specific -- discover via `nxp_s32ct_inspect(kind='pins')`.

### 4.2 Peripherals -> Rdc_Checker
Declare each instance, threshold configuration, and resolver channel.
The exact names appear 1:1 in the block's resource enums.

### 4.3 Platform -> Interrupt Controller (ResolverCallback mode only)
Enable the relevant interrupt if `Rdc_Checker_ResolverCallback` is used.
Verify exact IRQ names via the `.mex`.

### 4.4 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../editing-mbdt-board-init/SKILL.md):

```
Component : Rdc_Checker
Priority  : (verify live)
Enabled   : true
Header    : #include "Rdc_Checker.h"
Code      : Rdc_Checker_Init(&Rdc_Checker_Config);
```

AUTOSAR standard driver. `Rdc_Checker_Config` is emitted by the code-gen
tool from Peripherals -> Rdc_Checker. Priority and exact config symbol
must be verified live via `get_mbdt_board_init(modelName)` -- do not
carry them from memory.

#### Expected generated C files

A correctly-configured Rdc_Checker peripheral must cause the config tool
to emit these generated units. If any are missing, the build fails at
compile/link time -- authoritative evidence of a config-tool-side problem,
NOT a model problem. Confirm the exact file names against the generated
`{model}_Config/` folder or the RTD Rdc_Checker component docs -- do not
cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `Rdc_Checker_Cfg.h` / `Rdc_Checker_PBcfg.*` | Peripherals -> Rdc_Checker (always) | Rdc_Checker driver |

**If `fatal error: Rdc_Checker_Cfg.h` No such file appears at build
time:** the Rdc_Checker flavor was not emitted. Do NOT touch the model.
Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`,
read the parsed problems, and re-generate.

#### RTD documentation

Read the **UM** and the **IM** before modifying the external configuration
tool project, or before implementing a user request the shipped examples do
not cover. The **UM** tells you how each `api_func` behaves; the **IM**
covers generated-file expectations, init order, and NVIC prerequisites.
`{s32k3_root}` = `mbd_find_s32k3_root()`:

```
{s32k3_root}\S32K3_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Rdc_Checker_TS_T40D*_M70I*_R0\doc\
    RTD_RDC_CHECKER_IM.pdf   RTD_RDC_CHECKER_UM.pdf
```

Read UM before selecting `api_func`.

---

## 5. Initialize Function Pattern

Typically no Initialize Function block is needed beyond the board-init
`Rdc_Checker_Init`. If runtime threshold reconfiguration is required,
place a `Rdc_Checker_ChangeThresholdsConfig` block in the Initialize
Function to prime the thresholds. Read the shipped example live.

---

## 6. Runtime Data Flow

```
Periodic task:
  Rdc_Checker_DetectFaults   --> trigger fault scan
  Rdc_Checker_ReadFaultStatus --> fault status output
  [downstream fault-handling logic]
```

For callback-driven operation:
```
Hardware_Interrupt_Handler (irqGroup=<read live> -- verify Rdc_Checker is in irqGroup enum)
  --> function-call subsystem
       --> Rdc_Checker_ResolverCallback
```

> **Note:** The `irqGroup` value for `Rdc_Checker` callbacks must be
> verified live via `get_param(<isrBlk>,'DialogParameters').irqGroup.Enum`.
> `Rdc_Checker` may appear as its own group or may be nested under
> `MotorControl` depending on the RTD version. Never hardcode `Rdc_Checker`
> as the `irqGroup` without confirming it exists in the live enum.

---

## 7. Interrupt Dependencies

If `Rdc_Checker_ResolverCallback` is used, wire a
`Hardware_Interrupt_Handler` block with the appropriate `irqGroup`.
Read the live `irqHandlers` enum for the available callback name.
NVIC must be enabled in the S32CT project (Platform -> Interrupt Controller).

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Instance name | Peripherals -> Rdc_Checker | `instance` enum |
| Threshold config name | Peripherals -> Rdc_Checker | `threshold` enum |
| Resolver channel name | Peripherals -> Rdc_Checker | `xResolver` enum |
| Pin routing | Pins | Compiled-in; not exposed |
| NVIC enable | Platform -> Interrupt Controller | Manifests as callback firing |
| Board-init entry | `editing-mbdt-board-init` | Emitted into `mbdt_board_init.c` |

---

## 9. Common Usage Patterns

**Pattern A -- Polling fault detection**
```
Init: (none beyond board-init)
Loop (periodic): Rdc_Checker_DetectFaults -> Rdc_Checker_ReadFaultStatus
                 --> fault flags to downstream logic
```

**Pattern B -- Runtime threshold change**
```
Init: Rdc_Checker_ChangeThresholdsConfig (new threshold config)
Loop: Rdc_Checker_DetectFaults -> Rdc_Checker_ReadFaultStatus
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `instance` = `"No Instances configured"` | Config tool missing instance | Add in Peripherals -> Rdc_Checker in S32CT |
| `threshold` = `"No Thresholds configured"` | Config tool missing threshold | Add threshold config in S32CT |
| `xResolver` = `"No Resolvers configured"` | Config tool missing resolver | Add resolver channel in S32CT |
| Build links but no fault detection | Missing board-init | Add `Rdc_Checker_Init` via `editing-mbdt-board-init` |
| Callback never fires | ISR handler missing or NVIC disabled | Add `Hardware_Interrupt_Handler`; enable NVIC in S32CT |
| Build fails: unresolved `Rdc_Checker_Init` | Missing board-init | Add via `editing-mbdt-board-init`. Never stub. |

---

## 11. Board-Specific Considerations

- S32K3-specific block -- not present on other MBDT families. Confirm
  availability via `get_mbdt_toolbox('s32k3','blocks')`.
- Resolver signal pin assignments are board-specific; never invent them.

---

## 12. Guardrails (Rdc_Checker-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only Rdc_Checker-specific rules follow.

- **S32K3 only.** The block is not available on other families.
