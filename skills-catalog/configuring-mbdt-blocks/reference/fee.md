# Fee -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the Fee
(Flash EEPROM Emulation) peripheral on any NXP MBDT-targeted Simulink
model. Covers the `Fee` block (`MaskType = s32k3_fee`), the full
`api_func` surface, resource enum structure (block name, cluster group),
the job-queue / main-function polling pattern, and external-config-tool
dependencies.

Fee is an **AUTOSAR-aligned flash-emulation driver**: it provides
non-volatile data storage over internal flash without exposing raw flash
addresses to the application. Data is organized into named **blocks**
(logical EEPROM records) mapped onto flash **cluster groups** (physical
page sets). All operations (read, write, erase, invalidate) are
**asynchronous and job-based**: the caller submits a job; the driver
executes it in the background via `Fee_MainFunction`; the caller polls
`Fee_GetJobResult` or waits for an Fls / NvM callback.

> **Tip -- start from a shipped example.** The example
> `s32k3xx_fee_s32ct` contains a complete Fee setup: S32CT project
> (Peripherals -> Fee -> blocks, cluster groups, Peripherals -> Fls),
> board-init entries for both Fls and Fee, and model blocks
> (`Fee_Init`, `Fee_Write`, `Fee_Read`, `Fee_MainFunction`,
> `Fee_GetJobResult`). Open it via
> [`opening-mbdt-example`](../../opening-mbdt-example/SKILL.md)
> and inspect each block with `get_param(...,'DialogParameters')`.
> Never carry block names or cluster group names from memory.

---

## 1. Peripheral Overview

Adding "Fee to a model" means placing five artefacts:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Peripherals -> Fls: flash controller config; Peripherals -> Fee: blocks, cluster groups) | External | External config tool |
| 2 | Board-init entries: `Fls_Init(NULL)` then `Fee_Init(NULL)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Initialize Function blocks: `Fee_Init` call (if not handled entirely in board-init) | Simulink model | This skill |
| 4 | Runtime blocks: `Fee_Write` / `Fee_Read` + `Fee_MainFunction` (called periodically) + `Fee_GetJobResult` (poll completion) | Simulink model | This skill |
| 5 | Optional: `Fee_Cancel`, `Fee_EraseImmediateBlock`, `Fee_ForceSwapOnNextWrite`, `Fee_InvalidateBlock`, `Fee_GetStatus`, `Fee_GetRunTimeInfo` | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1): `blockName` enum resolves to `"No Fee blocks configured"` sentinel;
  all operations reference undefined blocks.
- Missing (2): `Fls_Init` / `Fee_Init` never called; every `Fee_Write` /
  `Fee_Read` submits a job into an uninitialized driver and silently fails.
- Missing (3/4 `Fee_MainFunction`): jobs are never processed; `Fee_GetJobResult`
  always returns `FEE_JOB_PENDING`; writes/reads never complete.
- Missing `Fee_GetJobResult` polling: application never knows if a job succeeded
  or failed; data integrity cannot be verified.

**Key departures from other peripherals:**

- **Fee depends on Fls.** The Fls (Flash driver) must be initialized before
  Fee. Both board-init entries are required; Fls must have a lower Priority
  (earlier) than Fee.
- **All Fee operations are asynchronous / job-based.** There is no synchronous
  variant. The caller submits a job (`Fee_Write`, `Fee_Read`, ...) and must
  call `Fee_MainFunction` periodically to advance the state machine.
- **`Fee_MainFunction` is not a one-shot call.** It must be called from a
  periodic rate (typically the Step function or a dedicated periodic task)
  until the job completes.
- **No ISR handler block of its own.** Fee completion is polled via
  `Fee_GetJobResult`. Fls may use an interrupt internally but that is
  managed by the Fls driver; no `Hardware_Interrupt_Handler` block is
  added by the user for Fee.

---

## 2. The `Fee` Block -- Complete Behavioral Model

**One `Fee` block = one `Fee_*` function call.** `MaskType = s32k3_fee`.
A model places several `Fee` blocks with different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param(<feeBlk>,'DialogParameters')`. The values below were read
live from S32K3 RTD (R2026a).

| `api_func` | Role | Resource params needed |
|---|---|---|
| `Fee_Read` | Submit a read job: copy data from a named block into a buffer | `blockName` |
| `Fee_Write` | Submit a write job: copy data from a buffer into a named block | `blockName` |
| `Fee_EraseImmediateBlock` | Erase a named immediate block | `blockName` |
| `Fee_InvalidateBlock` | Mark a named block as invalid | `blockName` |
| `Fee_ForceSwapOnNextWrite` | Force a cluster swap before the next write | `clusterGroupName` (string) |
| `Fee_Cancel` | Cancel the currently pending job | none |
| `Fee_GetJobResult` | Poll the result of the last submitted job | none |
| `Fee_GetStatus` | Read the driver status (IDLE / BUSY / BUSY_INTERNAL / UNINIT) | none |
| `Fee_GetRunTimeInfo` | Read runtime statistics (writes per cluster, swap count, etc.) | `clusterGroupName` (string) |
| `Fee_MainFunction` | Advance the Fee state machine; must be called periodically | none |

Selecting `api_func` reshapes the S-Function's ports. **Set `api_func` first.**

### 2.2 Parameter surface

| Name | Type | Semantics |
|---|---|---|
| `api_func` | enum | Function selector (see Sec.2.1) |
| `blockName` | enum | Named Fee block (e.g. `FeeBlock_0`); sentinel = `"No Fee blocks configured"` |
| `clusterGroupName` | string | Cluster group name as a free-form string (must match the name declared in S32CT exactly); used by `Fee_ForceSwapOnNextWrite` and `Fee_GetRunTimeInfo` |
| `text` | string | System-managed cache -- **never set** |

`blockName` is an enum populated from the S32CT Fee block declarations.
`clusterGroupName` is a **string** (not an enum); the user must type the
name exactly as declared in Peripherals -> Fee -> Cluster Groups. Both
must be read/verified live -- never assumed.

### 2.3 The `blockName` enum

Entries follow the names assigned in Peripherals -> Fee (e.g.
`FeeBlock_Config`, `FeeBlock_Calib`, ...). The exact names are
application-chosen in the config tool and appear verbatim in the
block's `blockName` dropdown. Read live; never enumerate from memory.

### 2.4 Sentinel rules

| Resource | Sentinel | Action |
|---|---|---|
| `blockName` | `"No Fee blocks configured"` | Declare Fee blocks in Peripherals -> Fee -> Fee Blocks in S32CT |

`Fee_Cancel`, `Fee_GetJobResult`, `Fee_GetStatus`, `Fee_MainFunction` require
no resource; all operations that address a specific block require a valid
`blockName`.

### 2.5 Port signatures per `api_func`

Input and output port data types verified live on S32K3.
Read from block ports after setting `api_func`; never assume.

| `api_func` | Inputs | Outputs |
|---|---|---|
| `Fee_Read` | u1: offset (**uint16**), u2: length (**uint16**) | y1: data buffer (uint8[N]), y2: status (uint8) |
| `Fee_Write` | u1: data buffer (uint8[N]) | y1: status (uint8) |
| `Fee_GetJobResult` | none | y1: job result (uint8) |
| `Fee_GetStatus` | none | y1: driver status (uint8) |
| `Fee_MainFunction` | none | none |
| `Fee_Cancel` | none | none |
| `Fee_InvalidateBlock` | none | y1: status (uint8) |
| `Fee_EraseImmediateBlock` | none | y1: status (uint8) |
| `Fee_ForceSwapOnNextWrite` | none | y1: status (uint8) |
| `Fee_GetRunTimeInfo` | none | y1: runtime info struct |

> **Critical -- `Fee_Read` port types:** offset and length inputs are
> **uint16**, not uint32. Connecting uint32 Constant blocks causes a
> port data-type mismatch error at update diagram.
> Use `uint16(0)` / `uint16(N)` Constant blocks.

### 2.6 Selection ordering

1. `api_func` first.
2. `blockName` next (if applicable).
3. `clusterGroupName` string last (if applicable).

One `set_param` per parameter.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Library | Role |
|---|---|---|---|
| `Fee` | `s32k3_fee` | `mbd_s32k3_memory_library` | Wraps one `Fee_*` function; multiple instances per model |

Discover exact path via `get_mbdt_toolbox('s32k3','blocks')`.
Fee has no dedicated callback block or ISR-handler entry.

---

## 4. Configuration Workflow

Config-tool steps first; model steps last.

### 4.1 Peripherals -> Fls

Configure the underlying flash controller (clock, read/write timing,
interrupt mode). Fls must be declared before Fee can be added.
Confirm the `type_id` via `nxp_s32ct_inspect(kind='instances')`.

### 4.2 Peripherals -> Fee

Declare:
- **Fee Blocks** -- each named block (logical EEPROM record): block name,
  size in bytes, immediate/non-immediate type.
- **Cluster Groups** -- physical flash page sets that hold the emulated
  data; each cluster group has a name, two virtual sectors, and a size.

The block names assigned here are exactly what appear in the `blockName`
enum dropdown. Confirm via `nxp_s32ct_inspect(kind='instances')`.

### 4.3 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../editing-mbdt-board-init/SKILL.md).
Two entries required, in order:

```
Component : Fls
Priority  : <NN>     -- must be numerically lower (earlier) than Fee
Enabled   : true
Header    : #include "Fls.h"
Code      : Fls_Init(NULL);

Component : Fee
Priority  : <NN+1>   -- must be numerically higher (later) than Fls
Enabled   : true
Header    : #include "Fee.h"
Code      : Fee_Init(NULL);
```

Verify Priority and header live via `get_mbdt_board_init(modelName)`.
**Fls must be initialized before Fee** (INV-FEE-1); wrong ordering
causes `Fee_Init` to fail silently.

#### Expected generated C files

The config tool emits (exact names vary by RTD version):
- `Fls_Cfg.h` / `Fls_PBcfg.c` -- flash controller configuration.
- `Fee_Cfg.h` / `Fee_PBcfg.c` -- Fee block declarations and cluster group map.

Confirm exact filenames in the generated `<model>_Config/` folder.
Missing files indicate a config-tool problem; run `nxp_s32ct_validate`
and read its output.

#### RTD documentation

```
<family_root>\S32K3_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Fee_TS_T40D*_M70I*_R0\doc\
    RTD_FEE_IM.pdf   RTD_FEE_UM.pdf
```

`<family_root>` = `mbd_find_s32k3_root()`. Always glob the version segments.
Also consult the Fls UM/IM at the corresponding `Fls_TS_*` plugin path.

### 4.4 Model Runtime Blocks

A complete Fee model requires at minimum:
1. `Fee_MainFunction` block called from a periodic rate.
2. `Fee_Write` or `Fee_Read` block triggered when a new job is needed.
3. `Fee_GetJobResult` block polled after submitting a job.

---

## 5. Initialize Function Pattern

Fee typically uses only board-init (`Fls_Init(NULL)` + `Fee_Init(NULL)`)
for initialization. No additional priming call is needed in the Simulink
Initialize Function subsystem beyond the board-init entries.

If the model must verify that Fee is ready before the first job:
- Add a `Fee` block with `api_func = Fee_GetStatus` in the Initialize
  Function and confirm the output is `FEE_IDLE` before proceeding.

---

## 6. Runtime Data Flow

**Write job (asynchronous):**

```
[Trigger: new data available]
  Fee block: api_func=Fee_Write, blockName=<FeeBlock_X>
    input: data buffer (uint8 vector)
    --> submits write job; returns immediately

[Periodic step -- every task period]
  Fee block: api_func=Fee_MainFunction
    --> advances Fee state machine; processes the pending job

[Polling: after Fee_Write trigger + enough Fee_MainFunction cycles]
  Fee block: api_func=Fee_GetJobResult
    output: job result (FEE_JOB_OK / FEE_JOB_FAILED / FEE_JOB_PENDING / FEE_JOB_CANCELLED)
```

**Read job (asynchronous):**

```
[Trigger: data needed]
  Fee block: api_func=Fee_Read, blockName=<FeeBlock_X>
    output: data buffer (uint8 vector)
    --> submits read job; output buffer valid only after FEE_JOB_OK

[Periodic step]
  Fee block: api_func=Fee_MainFunction

[Polling]
  Fee block: api_func=Fee_GetJobResult
    output: FEE_JOB_OK -> data buffer now valid
```

---

## 7. Interrupt Dependencies

Fee has **no ISR-handler block entry** in the MBDT model. The Fls
driver may use flash-controller interrupts internally, but those are
managed by the Fls driver and do not require a user-added
`Hardware_Interrupt_Handler` block. Fee completion is polled via
`Fee_GetJobResult`; no interrupt fires to the model.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Fee block logical name | Peripherals -> Fee -> Fee Blocks | `blockName` enum on `Fee` block |
| Fee block size / type | Peripherals -> Fee -> Fee Blocks | Compiled-in; not exposed on block |
| Cluster group name | Peripherals -> Fee -> Cluster Groups | `clusterGroupName` string on block (free-form) |
| Flash controller config | Peripherals -> Fls | Compiled-in; not exposed |
| Board-init call order | `editing-mbdt-board-init` Priority | Enforced at board-init sequence level |

---

## 9. Common Usage Patterns

### Pattern 1: Periodic write (save calibration data)

```
[Initialize Function]
  Fee: api_func=Fee_GetStatus  -- confirm FEE_IDLE before first use

[Step function -- triggered when save needed]
  Fee: api_func=Fee_Write, blockName=FeeBlock_Calib
    input: uint8 buffer with calibration data

[Background periodic task -- every 1 ms]
  Fee: api_func=Fee_MainFunction

[Polling task]
  Fee: api_func=Fee_GetJobResult
    output -> check for FEE_JOB_OK
```

### Pattern 2: Read on startup

```
[Initialize Function]
  Fee: api_func=Fee_Read, blockName=FeeBlock_Calib
    output: uint8 read buffer
  -- then loop calling Fee_MainFunction until Fee_GetJobResult != FEE_JOB_PENDING
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `blockName` enum = `"No Fee blocks configured"` | Peripherals -> Fee has no block declared | Add blocks in Peripherals -> Fee -> Fee Blocks in S32CT |
| `Fee_GetJobResult` always returns `FEE_JOB_PENDING` | `Fee_MainFunction` not called, or called too infrequently | Call `Fee_MainFunction` from a periodic step every task period |
| `Fee_GetJobResult` returns `FEE_JOB_FAILED` | Fls not initialized, or flash sector not erased | Confirm `Fls_Init(NULL)` board-init entry; check cluster group configuration |
| Build fails: `Fee_Cfg.h: No such file` | Config tool did not generate Fee config unit | Run `nxp_s32ct_validate`; check Peripherals -> Fee for missing block / cluster declarations |
| Build links but data never persists | `Fee_Init(NULL)` board-init entry missing | Add via `editing-mbdt-board-init`; confirm Priority is after Fls |
| `Fee_Init` fails silently | `Fls_Init` not called before `Fee_Init` | Enforce Priority: Fls must have lower Priority value than Fee in board-init |

---

## 11. Board-Specific Considerations

- **S32K3:** Internal flash organized in sectors; Fee emulates EEPROM in
  a flash partition separate from code flash. Fls `type_id` is typically
  `Fls_43_INFLS`; Fee `type_id` is `Fee`. Verify via
  `nxp_s32ct_inspect(kind='instances')`. `MaskType = s32k3_fee`. 

---

## 12. Guardrails (Fee-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only Fee-specific rules follow.

- **Add both the `Fls` and the `Fee` board-init entries, Fls first
  (INV-FEE-1).** Missing either causes a silent runtime failure; enforce the
  order with Fls Priority < Fee Priority.
- **Match `clusterGroupName` to the S32CT name exactly.** It is a
  case-sensitive free-form string, not an enum.
- **Call `Fee_MainFunction` periodically.** Fee operations never complete
  without it; place it in a periodic step, not in a one-shot trigger.
- **Do not add a `Hardware_Interrupt_Handler` block for Fee.** Completion is
  polled via `Fee_GetJobResult`.
