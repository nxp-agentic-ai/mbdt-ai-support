# eTPU -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the eTPU
(Enhanced Time Processing Unit) peripheral on NXP MBDT-targeted Simulink
models. This document describes the behavior of the `eTPU` block
(`MaskType = s32k3_etpu`), the initialization pattern, and the
external-config-tool dependencies. eTPU applies only to S32K3 only -- this block
lives in `mbd_s32k3_cdd_library` and is S32K39x-specific.

> **Tip -- start from a shipped example.** Open a shipped eTPU example
> via [`opening-mbdt-example`](../../opening-mbdt-example/SKILL.md).
> Never carry example names from memory -- discover at runtime via
> `get_mbdt_toolbox('s32k3','examples')`.

---

## 1. Peripheral Overview

The eTPU is a co-processor for time-critical automotive signal processing
(PWM generation, angle counting, input capture). The MBDT eTPU CDD wraps
engine management and control functions of the eTPU firmware engines.

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT project: eTPU firmware and channel configuration | External to the model | External config tool |
| 2 | Board-init `Etpu_Init(...)` / `Etpu_Start(...)` | `mbdt_board_init.c` | `editing-mbdt-board-init` skill |
| 3 | Initialize Function block (`Etpu_Start`) | Simulink model | This skill |
| 4 | Runtime blocks for engine management | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1) -> eTPU engines not loaded; all function calls are no-ops.
- Missing (2) -> eTPU never starts.
- Missing (3) -> engines never started.
- Missing (4) -> no runtime control.

---

## 2. The `eTPU` Block -- Complete Behavioral Model

**One `eTPU` block = one `Etpu_*` function call.** The block has
`MaskType = s32k3_etpu`.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param({blk}, 'DialogParameters')`. Illustrative entries (S32K3 MBDT 1.8.0):

- `Etpu_Start` -- start eTPU engine execution
- `Etpu_Stop` -- stop eTPU engine execution
- `Etpu_GetEngineUtilization` -- read utilization of an eTPU engine
- `Etpu_GetWatchdogStatus` -- read watchdog status
- `Etpu_EnableMemErrorInjection` / `Etpu_DisableMemErrorInjection` -- memory error injection (testing)
- `Etpu_InjectMemError` -- inject a memory error (testing)
- `Etpu_GetVersionInfo` -- version query (no engine needed)

Selecting `api_func` reshapes the S-Function ports. **Set `api_func` first.**

### 2.2 Parameter surface

| Name | Type | Semantics | Meaningful for |
|---|---|---|---|
| `api_func` | enum | Function selector (Sec.2.1) | All |
| `eStartSync` | enum (`ETPU_START_ASYNC`, `ETPU_START_SYNC`) | Start synchronization mode | `Etpu_Start` |
| `etpuEngine` | enum (`ETPU_ENGINE_A`, `ETPU_ENGINE_B`, `ETPU_ENG_COUNT`) | Engine selector | `Etpu_Start`, `Etpu_Stop`, `Etpu_GetEngineUtilization`, `Etpu_GetWatchdogStatus` |
| `eMemoryType` | enum (`ETPU_MEM_TYPE_SDM`, `ETPU_MEM_TYPE_SCM`, `ETPU_MEM_TYPE_ALL`) | Memory type for error injection | `Etpu_EnableMemErrorInjection`, `Etpu_InjectMemError` |
| `eHostScmAccessRequest` | enum (`ETPU_HOST_SCM_ACCESS_REQUESTED`, `ETPU_HOST_SCM_ACCESS_NOT_REQUESTED`) | Host SCM access mode | Select functions |
| `text` | string | System-managed cache -- **never set** | Read-only |

### 2.3 Resource enums

Unlike most peripherals, eTPU enums are **static** (not populated from
the config tool's logical-name list). `etpuEngine`, `eStartSync`,
`eMemoryType`, and `eHostScmAccessRequest` have fixed entries that do not
depend on the `.mex` project. No sentinel pattern applies to these enums.

### 2.4 Sentinel rules

eTPU block enums do not use the `"No ... configured"` sentinel pattern --
all enum values are fixed at library authoring time. The only sentinel
concern is that `api_func` must be set first to expose the correct enums.

### 2.5 Port signatures per `api_func`

Port types not verified live; read from block after setting `api_func`.

| `api_func` | Inputs | Outputs |
|---|---|---|
| `Etpu_Start` | none | y1: status |
| `Etpu_Stop` | none | y1: status |
| `Etpu_GetEngineUtilization` | none | y1: utilization (uint8 or uint32) |
| `Etpu_GetWatchdogStatus` | none | y1: status |
| `Etpu_EnableMemErrorInjection` / `Etpu_DisableMemErrorInjection` | none | y1: status |
| `Etpu_InjectMemError` | none | y1: status |
| `Etpu_GetVersionInfo` | none | y1: version info |

> **Note:** Always read port types live from the block after setting `api_func`.
> eTPU enums are static (not config-tool-populated), so port shapes are
> determined by `api_func` alone.

### 2.6 Selection ordering

1. `api_func` first.
2. `etpuEngine`, `eStartSync`, `eMemoryType`, `eHostScmAccessRequest`
   as exposed by the current `api_func`.
3. One `set_param` per parameter.

---

## 3. Required Block Catalog

| Block name | Library | Role |
|---|---|---|
| `eTPU` | `mbd_s32k3_cdd_library` | Wraps one `Etpu_*` function |

eTPU does not use the standard `Hardware_Interrupt_Handler` for callbacks
in typical MBDT models -- engine channel callbacks are handled within
the eTPU firmware. Confirm with the shipped example.

---

## 4. Configuration Workflow

### 4.1 eTPU Firmware Configuration (S32CT)
Configure eTPU firmware loading, channel assignments, and engine
parameters in the S32CT project (eTPU component). This step is required
before any `Etpu_*` function can operate.

### 4.2 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../editing-mbdt-board-init/SKILL.md):

```
Component : Etpu
Priority  : (verify live)
Enabled   : true
Header    : #include "Etpu.h"
Code      : Etpu_Init(&Etpu_Config);
```

AUTOSAR standard driver. `Etpu_Config` is emitted by the code-gen tool
from the S32CT eTPU component. Priority and exact config symbol must be
verified live via `get_mbdt_board_init(modelName)` -- do not carry them
from memory. Optionally add `Etpu_Start` as a separate board-init entry
or place it in the Initialize Function (see Sec.5).

#### Expected generated C files

A correctly-configured eTPU peripheral must cause the config tool to emit
these generated units. If any are missing, the build fails at
compile/link time -- authoritative evidence of a config-tool-side problem,
NOT a model problem. Confirm the exact file names against the generated
`{model}_Config/` folder -- do not cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `Etpu_Cfg.h` / `Etpu_PBcfg.*` | S32CT eTPU component (always) | eTPU driver |

**If `fatal error: Etpu_Cfg.h` No such file appears at build time:** the
eTPU flavor was not emitted. Do NOT touch the model. Run
`nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`, read
the parsed problems, and re-generate.

#### RTD documentation

Read the **UM** and the **IM** before modifying the external configuration
tool project, or before implementing a user request the shipped examples do
not cover. `{s32k3_root}` = `mbd_find_s32k3_root()`:

```
{s32k3_root}\S32K3_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Etpu_TS_T40D*_M70I*_R0\doc\
    RTD_ETPU_IM.pdf   RTD_ETPU_UM.pdf
```

Read UM before selecting `api_func`; read IM for init-order and
generated-file requirements.

### 4.3 Model Runtime Blocks
Typically: `Etpu_Start` in Initialize Function, then runtime blocks for
utilization monitoring, watchdog status, or error injection testing.

---

## 5. Initialize Function Pattern

```
Initialize Function:
  Etpu_Start (etpuEngine = ETPU_ENGINE_A, eStartSync = ETPU_START_SYNC)
  [Etpu_Start for ENGINE_B if dual engine used]
```

Read the shipped example's Initialize Function live to confirm ordering
and engine selection.

---

## 6. Runtime Data Flow

```
Periodic monitoring task:
  Etpu_GetEngineUtilization  --> utilization percentage
  Etpu_GetWatchdogStatus     --> watchdog status

Fault injection test task (test mode only):
  Etpu_EnableMemErrorInjection --> (error injection armed)
  Etpu_InjectMemError           --> (error injected)
  Etpu_DisableMemErrorInjection --> (error injection cleared)
```

---

## 7. Interrupt Dependencies

Typical MBDT eTPU usage does not require a `Hardware_Interrupt_Handler`
block -- the eTPU channels have their own microcode ISRs. If the
application requires host-side eTPU interrupt handling, verify the
appropriate IRQ in Platform -> Interrupt Controller in S32CT and wire
`Hardware_Interrupt_Handler` accordingly.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| eTPU firmware / channel config | S32CT eTPU component | Compiled-in; not exposed on block |
| Engine selector | Block param (`etpuEngine`) | `etpuEngine` enum (fixed entries) |
| Start sync mode | Block param (`eStartSync`) | `eStartSync` enum (fixed entries) |
| Board-init entry | `editing-mbdt-board-init` | Emitted into `mbdt_board_init.c` |

---

## 9. Common Usage Patterns

**Pattern A -- Start both engines synchronously**
```
Init: Etpu_Start (ENGINE_A, SYNC) -> Etpu_Start (ENGINE_B, SYNC)
Loop: Etpu_GetEngineUtilization (ENGINE_A) / (ENGINE_B)
```

**Pattern B -- Watchdog monitoring**
```
Loop: Etpu_GetWatchdogStatus (ENGINE_A) --> status signal to supervisor
```

**Pattern C -- Memory error injection (test only)**
```
Test trigger: Etpu_EnableMemErrorInjection -> Etpu_InjectMemError
              -> Etpu_DisableMemErrorInjection
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `Etpu_GetEngineUtilization` returns 0 | Engine not started | Add `Etpu_Start` in Initialize Function |
| Build fails: unresolved `Etpu_Init` | Missing board-init | Add via `editing-mbdt-board-init`. Never stub. |
| eTPU channels not responding | Firmware not loaded (S32CT config missing) | Configure eTPU firmware in S32CT |
| Wrong utilization engine | `etpuEngine` param wrong | Read live enum; set `api_func` first, then `etpuEngine` |

---

## 11. Board-Specific Considerations

- S32K3-specific block -- not present on other MBDT families. Confirm
  availability via `get_mbdt_toolbox('s32k3','blocks')`.
- eTPU firmware and channel assignments are board and application
  specific; never invent them. Read the shipped example `.mex`.

---

## 12. Guardrails (eTPU-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only eTPU-specific rules follow.

- **Pick `etpuEngine`, `eStartSync`, `eMemoryType`, `eHostScmAccessRequest`
  from their live enums.** They are fixed enums; no sentinel pattern applies.
- **S32K3 only.** The block is not available on other families.
- **Never use the error-injection functions in production control code.**
  `EnableMemErrorInjection` and `InjectMemError` are for testing only.
