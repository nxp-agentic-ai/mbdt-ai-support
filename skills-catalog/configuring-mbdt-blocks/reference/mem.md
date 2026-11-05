# Mem -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the Mem
(Memory Abstraction) peripheral on any NXP MBDT-targeted Simulink
model. Covers the `Mem` block (`MaskType = s32k3_mem`), the full
`api_func` surface, resource enums (`memoryType`, `instance`,
`hwSpecificService`), the job-queue / main-function polling pattern,
and external-config-tool dependencies. Verified on S32K3.

Mem is an **AUTOSAR-aligned memory abstraction driver**: it provides
a uniform API for read, write, erase, and blank-check operations over
physical memory instances without exposing hardware-specific
addressing to the application. On S32K3, the only supported memory
type in the block is `INFLS (Internal Flash)` (the `Mem_43_INFLS`
driver). All operations are **asynchronous and job-based**: the caller
submits a job; the driver executes it in the background via
`Mem_MainFunction`; the caller polls `Mem_GetJobResult`.

Mem and Fee serve different purposes:
- **Fee** provides logical EEPROM emulation (named blocks, wear
  levelling, cluster groups).
- **Mem** provides direct physical flash read/write/erase by address
  range (no wear levelling, no logical names).

> **Tip -- start from a shipped example.** The examples
> `s32k3xx_mem_infls_s32ct` and `s32k3xx_memory_rw` contain complete
> Mem setups. Open them via
> [`opening-mbdt-example`](../../opening-mbdt-example/SKILL.md)
> and inspect each block with `get_param(...,'DialogParameters')`.
> Never carry instance names or service names from memory.

---

## 1. Peripheral Overview

Adding "Mem to a model" means placing four artefacts:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Peripherals -> Mem_43_INFLS: flash instance config, address ranges, sector sizes) | External | External config tool |
| 2 | Board-init entry `Mem_Init(NULL)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Initialize Function: no mandatory priming call beyond board-init | Simulink model | This skill |
| 4 | Runtime blocks: `Mem_Write` / `Mem_Read` / `Mem_Erase` + `Mem_MainFunction` (periodic) + `Mem_GetJobResult` (poll) | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1): `instance` enum resolves to `"No instances configured"` sentinel;
  all operations reference undefined flash instances.
- Missing (2): `Mem_Init` never called; every `Mem_Write` / `Mem_Read` /
  `Mem_Erase` submits a job into an uninitialized driver and silently fails.
- Missing `Mem_MainFunction` call: jobs are never processed; `Mem_GetJobResult`
  always returns `MEM_JOB_PENDING`.
- Missing `Mem_GetJobResult` polling: application cannot verify job success or
  failure; data integrity unverifiable.

**Key departures from other peripherals:**

- **Mem operates on physical addresses.** Unlike Fee (logical blocks),
  Mem requires address and length parameters at the application level. The
  application is responsible for staying within declared instance boundaries.
- **All Mem operations are asynchronous / job-based.** There is no synchronous
  variant. `Mem_MainFunction` must be called periodically to advance the state
  machine.
- **`memoryType` selects the physical memory driver.** Currently `INFLS
  (Internal Flash)` is the only entry in the live enum on S32K3. This may
  change on other families or RTD versions -- always read live.
- **`instance` is the logical flash instance name** declared in Peripherals ->
  Mem_43_INFLS in S32CT. When unconfigured, the enum holds the sentinel
  `"No instances configured"`.
- **`hwSpecificService`** is used only by `Mem_HwSpecificService` and holds
  vendor-specific service identifiers (`"No services available"` when empty).
- **No ISR-handler block entry of its own.** Completion is polled via
  `Mem_GetJobResult`.

---

## 2. The `Mem` Block -- Complete Behavioral Model

**One `Mem` block = one `Mem_*` function call.** `MaskType = s32k3_mem`.
A model places several `Mem` blocks with different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param(<memBlk>,'DialogParameters')`. The values below were read
live from S32K3 RTD (R2026a).

| `api_func` | Role | Resource params needed |
|---|---|---|
| `Mem_Read` | Submit a read job: copy data from a flash address range into a buffer | `memoryType`, `instance` |
| `Mem_Write` | Submit a write job: copy data from a buffer into a flash address range | `memoryType`, `instance` |
| `Mem_Erase` | Submit an erase job: erase a flash sector range | `memoryType`, `instance` |
| `Mem_BlankCheck` | Submit a blank-check job: verify a range is erased | `memoryType`, `instance` |
| `Mem_MainFunction` | Advance the Mem state machine; must be called periodically | none |
| `Mem_GetJobResult` | Poll the result of the last submitted job | none |
| `Mem_HwSpecificService` | Invoke a hardware-specific vendor service | `memoryType`, `instance`, `hwSpecificService` |
| `Mem_PropagateError` | Propagate an error notification to upper layers | none |
| `Mem_GetVersionInfo` | Read module / vendor version info | none |

Selecting `api_func` reshapes the S-Function's ports. **Set `api_func` first.**

### 2.2 Parameter surface

| Name | Type | Live values (S32K3, R2026a) | Semantics |
|---|---|---|---|
| `api_func` | enum | See Sec.2.1 | Function selector |
| `memoryType` | enum | `INFLS (Internal Flash)` | Physical memory driver type |
| `instance` | enum | Sentinel `"No instances configured"` when empty; else declared instance names | Logical flash instance name |
| `hwSpecificService` | enum | Sentinel `"No services available"` when empty | Vendor service identifier |
| `text` | string | -- | System-managed cache -- **never set** |

### 2.3 The resource enums

`memoryType` currently holds `INFLS (Internal Flash)` on S32K3; other
families or RTD versions may add entries -- always read live.

`instance` holds names declared in Peripherals -> Mem_43_INFLS (e.g.
`MemInstance_Code`, `MemInstance_Data`, ...). Names are application-chosen.
Read live; never enumerate from memory.

`hwSpecificService` holds vendor service identifiers (e.g.
`MEM_43_INFLS_SECTOR_ERASE_ASYNCH`, ...) -- read live, never assume.

### 2.4 Sentinel rules

| Resource | Sentinel | Action |
|---|---|---|
| `instance` | `"No instances configured"` | Declare a flash instance in Peripherals -> Mem_43_INFLS in S32CT |
| `hwSpecificService` | `"No services available"` | Only for `Mem_HwSpecificService`; declare the service in S32CT |

`Mem_MainFunction`, `Mem_GetJobResult`, `Mem_PropagateError`,
`Mem_GetVersionInfo` require no resource (sentinel = acceptable).

### 2.5 Port signatures per `api_func`

Port data types verified live on S32K3.
**Always read live after setting `api_func`** -- ports change with function selection.

| `api_func` | Inputs | Outputs |
|---|---|---|
| `Mem_Read` | u1: address (uint32), u2: length (uint32) | y1: data buffer (uint8[N]), y2: job status (uint8) |
| `Mem_Write` | u1: address (uint32), u2: data buffer (uint8[N]) *(verify live: may include u3: length (uint32) — check `get_param(<blk>,'PortHandles')` after setting `api_func=Mem_Write`)* | y1: job status (uint8) |
| `Mem_Erase` | u1: address (uint32), u2: length (uint32) | y1: job status (uint8) |
| `Mem_BlankCheck` | u1: address (uint32), u2: length (uint32) | y1: job status (uint8) |
| `Mem_MainFunction` | none | none |
| `Mem_GetJobResult` | none | y1: job result (uint8) |
| `Mem_HwSpecificService` | u1: service-specific data | y1: status (uint8) |
| `Mem_PropagateError` | none | none |
| `Mem_GetVersionInfo` | none | y1: version info |

> **Note:** Port types above are indicative; always verify live from the block
> after setting `api_func`. Address and length are uint32 (physical flash address).

### 2.6 Selection ordering

1. `api_func` first.
2. `memoryType` next.
3. `instance` then `hwSpecificService` last.

One `set_param` per parameter.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Library | Role |
|---|---|---|---|
| `Mem` | `s32k3_mem` | `mbd_s32k3_memory_library` | Wraps one `Mem_*` function; multiple instances per model |

Discover exact path via `get_mbdt_toolbox('s32k3','blocks')`.
Mem has no dedicated callback block or ISR-handler entry.

---

## 4. Configuration Workflow

Config-tool steps first; model steps last.

### 4.1 Peripherals -> Mem_43_INFLS

Declare flash instances (logical names, physical start address,
total size, sector size, write page size, erase value). The names
assigned here appear verbatim in the `instance` enum. Confirm the
`type_id` via `nxp_s32ct_inspect(kind='instances')` -- it is
`Mem_43_INFLS`, not `Mem`.

### 4.2 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../editing-mbdt-board-init/SKILL.md):

```
Component : Mem_43_INFLS
Priority  : <NN>
Enabled   : true
Header    : #include "Mem_43_INFLS.h"
Code      : Mem_Init(NULL);
```

Verify Priority and header live via `get_mbdt_board_init(modelName)`.
The board-init component name is `Mem_43_INFLS` (the S32CT `type_id`),
not `Mem`. The C call itself is `Mem_Init(NULL)`.

#### Expected generated C files

The config tool emits (exact names vary by RTD version):
- `Mem_43_INFLS_Cfg.h` / `Mem_43_INFLS_PBcfg.c` -- flash instance
  configuration structures.

Confirm exact filenames in the generated `<model>_Config/` folder.
Missing files indicate a config-tool problem; run `nxp_s32ct_validate`.

#### RTD documentation

```
<family_root>\S32K3_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Mem_43_INFLS_TS_T40D*_M70I*_R0\doc\
    RTD_MEM_43_INFLS_IM.pdf   RTD_MEM_43_INFLS_UM.pdf
```

`<family_root>` = `mbd_find_s32k3_root()`. Always glob the version segments.

### 4.3 Model Runtime Blocks

A complete Mem model requires at minimum:
1. `Mem_MainFunction` block called from a periodic rate.
2. `Mem_Write` / `Mem_Read` / `Mem_Erase` block triggered when needed.
3. `Mem_GetJobResult` block polled after submitting a job.

---

## 5. Initialize Function Pattern

Mem uses only board-init (`Mem_Init(NULL)`) for initialization.
No additional priming call is needed in the Simulink Initialize
Function subsystem.

If the model must verify readiness before the first job, add a
`Mem_GetJobResult` block in the Initialize Function to confirm no
pending job exists from a previous reset (result should not be
`MEM_JOB_PENDING` on a clean startup).

---

## 6. Runtime Data Flow

**Write job (asynchronous):**

```
[Trigger: data to persist]
  Mem block: api_func=Mem_Write, memoryType=INFLS (Internal Flash), instance=<MemInstance_X>
    inputs: start address (uint32), buffer (uint8 vector), length (uint32)
    --> submits write job; returns immediately

[Periodic step -- every task period]
  Mem block: api_func=Mem_MainFunction
    --> advances Mem state machine

[Polling]
  Mem block: api_func=Mem_GetJobResult
    output: MEM_JOB_OK / MEM_JOB_FAILED / MEM_JOB_PENDING / MEM_JOB_CANCELLED
```

**Erase + Write sequence:**

```
[Trigger]
  Mem: api_func=Mem_Erase, instance=<MemInstance_X>
    inputs: start address, length
  -- poll Mem_GetJobResult until MEM_JOB_OK
  Mem: api_func=Mem_Write, instance=<MemInstance_X>
    inputs: start address, buffer, length
  -- poll Mem_GetJobResult until MEM_JOB_OK
```

---

## 7. Interrupt Dependencies

Mem has **no ISR-handler block entry** in the MBDT model. The
underlying `Mem_43_INFLS` driver may use flash-controller interrupts
internally; these are managed by the driver and do not require a
user-added `Hardware_Interrupt_Handler` block. Completion is polled
via `Mem_GetJobResult`.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Flash instance logical name | Peripherals -> Mem_43_INFLS | `instance` enum on `Mem` block |
| Flash instance physical address / size | Peripherals -> Mem_43_INFLS | Compiled-in; not exposed on block |
| Sector / page size | Peripherals -> Mem_43_INFLS | Compiled-in; not exposed |
| HW-specific service identifiers | Peripherals -> Mem_43_INFLS | `hwSpecificService` enum |
| Board-init call | `editing-mbdt-board-init` | Emitted into `mbdt_board_init.c` |

---

## 9. Common Usage Patterns

### Pattern 1: Erase + write a flash sector

```
[Initialize Function]
  (board-init Mem_Init(NULL) is sufficient)

[Step -- triggered when new data must be saved]
  Mem: api_func=Mem_Erase, memoryType=INFLS (Internal Flash), instance=<MemInstance_X>
    inputs: address, length

[Periodic background task]
  Mem: api_func=Mem_MainFunction

[Polling -- after erase completes (MEM_JOB_OK)]
  Mem: api_func=Mem_Write, instance=<MemInstance_X>
    inputs: address, buffer, length

[Polling -- after write completes (MEM_JOB_OK)]
  -- data is now in flash
```

### Pattern 2: Read from flash on startup

```
[Initialize Function]
  Mem: api_func=Mem_Read, instance=<MemInstance_X>
    inputs: address, length
    output: uint8 buffer
  -- call Mem_MainFunction in a loop until Mem_GetJobResult != MEM_JOB_PENDING
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `instance` enum = `"No instances configured"` | Peripherals -> Mem_43_INFLS has no instance | Declare an instance in Peripherals -> Mem_43_INFLS in S32CT |
| `Mem_GetJobResult` always returns `MEM_JOB_PENDING` | `Mem_MainFunction` not called | Place `Mem_MainFunction` in a periodic step |
| `Mem_GetJobResult` returns `MEM_JOB_FAILED` | Sector not erased before write, or address out of range | Erase the sector first; confirm address stays within the declared instance range |
| Build fails: `Mem_43_INFLS_Cfg.h: No such file` | Config tool did not generate Mem config unit | Run `nxp_s32ct_validate`; check Peripherals -> Mem_43_INFLS |
| Build links but writes do not persist | `Mem_Init(NULL)` board-init entry missing or wrong component name | Add via `editing-mbdt-board-init`; component name must be `Mem_43_INFLS` |
| Write fails on blank flash | Flash is already programmed (not erased) | Call `Mem_Erase` first, poll `MEM_JOB_OK`, then call `Mem_Write` |

---

## 11. Board-Specific Considerations

- **S32K3:** Internal flash driver is `Mem_43_INFLS`. S32CT `type_id` =
  `Mem_43_INFLS`. `MaskType = s32k3_mem`. `memoryType` enum = `INFLS
  (Internal Flash)`.

---

## 12. Guardrails (Mem-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only Mem-specific rules follow.

- **Use board-init component `Mem_43_INFLS` with Code `Mem_Init(NULL)`.**
  Missing it causes silent failure; `Mem` is the block name, not the S32CT
  `type_id`.
- **Erase before write.** Call `Mem_Erase` and confirm `MEM_JOB_OK` before
  `Mem_Write`; writing unerased flash silently fails or corrupts data.
- **Call `Mem_MainFunction` periodically.** Mem operations never complete
  without it.
- **Do not add a `Hardware_Interrupt_Handler` block for Mem.** Completion is
  polled via `Mem_GetJobResult`.
