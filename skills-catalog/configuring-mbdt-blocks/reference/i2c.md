# I2C -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the I2C
peripheral on any NXP MBDT-targeted Simulink model. Verified against
the MBDT S32K3 shipped examples: `s32k3xx_i2c_async_s32ct` and
`s32k3xx_i2c_sync_ebt`. The behavioral model is expected to hold
cross-family (S32K3); enum labels and board-init
symbols are verified only on S32K3.

> **Tip -- start from a shipped example.** Open a shipped I2C example
> via [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md);
> its `.mex` project (Pins -> FLEXIO/LPI2C, Peripherals -> I2c, Platform
> -> NVIC for the async case) plus its model (Initialize Function,
> Master/Slave block placement, callback subsystem) forms a coherent
> reference that mirrors the sections below.

---

## 1. Peripheral Overview

The I2C peripheral in MBDT is a composite of four artefacts:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins, Peripherals -> I2c, Platform -> NVIC for async) | External to the model | External config tool |
| 2 | Board-init entry `I2c_Init(&I2c_Config)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Setup blocks at the top level: `I2c_StartListening` (slave), plus initial `I2c_AsyncTransmit` or `I2c_PrepareSlaveBuffer` | Simulink model | This skill |
| 4 | Runtime blocks: `I2c_SyncTransmit` / `I2c_AsyncTransmit` / `I2c_GetStatus` + (async only) `Hardware_Interrupt_Handler` + callback subsystem | Simulink model | This skill |

**Key departures from other peripherals:**

- **The `Initialize Function` subsystem is minimal.** In both shipped examples it contains only `I2c_GetVersionInfo` (diagnostic). All setup happens at the top level of the model, not inside Initialize Function.
- **No transceiver init.** I2C uses SDA/SCL directly from the MCU pins.
- **External pull-up resistors are hardware-required on some boards.** MBDT cannot fix this from the model side.

---

## 2. The `I2c` Block -- Complete Behavioral Model

**One `I2c` block = one `I2c_*` function call.** Every block has
`MaskType = {family}_i2c` (e.g. `s32k3_i2c`) and is an `S-Function`.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** from the block in front of you
via `get_param({i2cBlk}, 'DialogParameters')` -- the set of available
`I2c_*` functions is owned by the installed toolbox version and must
never be carried from memory.

**Behavioral facts an AI agent must know (independent of the exact
function list, which is discovered live):**

- **A `Sync`- and an `Async`-transmit function are bidirectional.** The
  direction is controlled by the `data_direction` parameter (`Send` vs
  `Receive`). "SyncTransmit + Receive" means the master issues an address
  then reads bytes back -- a standard I2C master read.
- **A `StartListening`-style function is the slave-side startup call.**
  Call it once on the slave channel to make it responsive to incoming
  addresses. It is not needed on the master.
- **A `PrepareSlaveBuffer`-style function arms the slave's TX or RX
  buffer** for the next transfer. Used both for pre-arming (sync example)
  and inside the async callback to arm the next response.
- **A `GetStatus`-style function returns `I2C_CH_FINISHED`** (or similar)
  on successful completion of a sync transfer. Used in the sync example's
  If-action subsystem to detect completion.
- Selecting `api_func` reshapes the S-Function's ports. **Set `api_func`
  first.**

Whenever this reference names a specific `I2c_*` function below, treat
it as an **illustrative** label observed in shipped S32K3 examples --
validate it against the block's live `api_func.Enum` before selecting
it, and refuse near-misses.

### 2.2 Parameter surface (constant across all `api_func` values)

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `channel` | enum | Channel | `I2cChannel_N` -- the driver channel | All except `I2c_GetVersionInfo` |
| `data_direction` | enum | Data Direction | `Send` \| `Receive` | `I2c_SyncTransmit`, `I2c_AsyncTransmit` |
| `bits_slave_address_size` | boolean | 10 Bits Slave Address Size | Enables 10-bit addressing (default 7-bit) | Transmit functions |
| `text` | string | *(empty)* | System-managed cache -- never set | Read-only |

### 2.3 The `channel` enum

Observed live entries in shipped examples: `I2cChannel_0 | I2cChannel_1`. Semantics from the READMEs:

```
I2cChannel_0  ->  FLEXIO peripheral (used as Master in the shipped examples)
I2cChannel_1  ->  LPI2C0 or LPI2C1 (used as Slave; board-specific)
```

**Master vs Slave role is not a block parameter.** Which channel plays which role is decided by:
- The `I2cHwUsing` / peripheral-flavor setting in the config tool (FLEXIO-vs-LPI2C selector).
- Which I2c API functions call it (a channel that receives an `I2c_StartListening` is a slave; one that receives `I2c_AsyncTransmit` originates a master transaction).

### 2.4 Sentinel rules

| `api_func` | `channel` sentinel = error? |
|---|---|
| `I2c_GetVersionInfo` | NO -- no channel needed |
| Everything else | YES |

If `channel.Enum = {"No channels configured"}` (or empty), route to `opening-mbdt-config-tool` and declare a channel in Peripherals -> I2c.

### 2.5 Selection ordering

1. `api_func` first.
2. `channel`.
3. `data_direction`.
4. `bits_slave_address_size` last.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Role |
|---|---|---|
| `I2c` | `{family}_i2c` | Wraps one `I2c_*` function; multiple instances per model |
| `Hardware_Interrupt_Handler` | `{family}_isr_handler` | Routes the single `MBDT_I2c_Callback` into a function-call subsystem (async mode only) |
| `FreeMASTER Config` (optional) | `{family}_fm_config` | Ships in the async example's `.pmpx` companion project |

---

## 4. Configuration Workflow (5 steps)

Steps 1-3 in the external configuration tool; steps 4-5 in the Simulink model.

### 4.1 Pins (S32 Configuration Tools -> Pins, or EB tresos -> Port)

Route SDA and SCL for both channels -- one FLEXIO pair for the Master, one LPI2C pair for the Slave. Pin numbers are **board-specific** -- never invent them. Sample from the shipped README (S32K3X4EVB-Q257):

```
Master  I2cChannel_0 (FLEXIO)   SDA = PTF21   SCL = PTF20
Slave   I2cChannel_1 (LPI2C1)   SDA = PTC6    SCL = PTC7
```

Discover the live pin mapping via `nxp_s32ct_inspect(kind='pins')` on the `.mex`.

### 4.2 Peripherals -> I2c (S32 Configuration Tools -> Peripherals)

For each logical channel:

```
I2cChannel_{N}
    (peripheral flavor: FLEXIO or LPI2C_IP, per HW routing)
    (baud rate, addressing mode, buffer sizes)
```

The **exact channel names** you assign here are what appear in the block's `channel` enum. Case-sensitive.

### 4.3 Platform -> Interrupt Controller (async mode only)

Enable the NVIC entry for each I2C instance used asynchronously:

```
LPI2C{N}_MASTER_IRQn
LPI2C{N}_SLAVE_IRQn
FLEXIO_IRQn                (if using FLEXIO channel)
```

Sync mode does not require NVIC enablement.

### 4.4 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md):

```
Component : I2c
Priority  : 140          (after Lin_43_LPUART_FLEXIO=130, before Mem_43_INFLS=150)
Enabled   : true
Header    : #include "CDD_I2c.h"
Code      : I2c_Init(&I2c_Config);
```

CDD driver (Complex Device Driver), not AUTOSAR standard. `I2c_Config` is emitted by the code-gen tool from Peripherals -> I2c.

#### Expected generated C files (I2C)

A correctly-configured I2C peripheral must cause the config tool to
**emit these generated units**. If any are missing, the build fails at
compile/link time -- and that is authoritative evidence of a
config-tool-side problem, NOT a model problem (see the generic
"Expected generated files and the missing-file diagnostic" section in
`SKILL.md`).

| Generated file | Emitted from | Flavor |
|---|---|---|
| `CDD_I2c_Cfg.h` / `CDD_I2c_Cfg.c` (+ `CDD_I2c_PBcfg.*`) | Peripherals -> I2c (always) | CDD wrapper |
| `Lpi2c_Ip_Cfg.h` / `Lpi2c_Ip_Cfg.c` | Peripherals -> I2c, when an LPI2C channel is declared | LPI2C IP |
| `Lpi2c_Ip_CfgDefines.h` | Peripherals -> I2c, LPI2C channel | LPI2C IP |
| `Flexio_I2c_Ip_Cfg.h` / `Flexio_I2c_Ip_Cfg.c` | Peripherals -> I2c, when a FLEXIO channel is declared | FLEXIO IP |

**If `fatal error: Lpi2c_Ip_CfgDefines.h No such file` (or any
`*_Cfg.h`) appears at build time:** the LPI2C flavor was not emitted.
Do NOT touch the model. Run `nxp_s32ct_validate(project_path={.mex},
tool_name="Peripherals")`, read the parsed problems, and suspect a
leftover FLEXIO channel plus `I2cFlexIOUsed=true` left from the shipped
example (see Sec.10 troubleshooting row and Sec.6 note). Remove the
unused flavor in the config tool, re-validate, and re-generate.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves, so you pick and drive the right function;
the **IM** covers generated-file expectations, init order, and NVIC
prerequisites. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-
version segments (filenames are uppercased):

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\I2c_TS_T40D*_M70I*_R0\doc\
    RTD_I2C_IM.pdf   RTD_I2C_UM.pdf
```

I2C is a single-module CDD driver -- no cross-driver dependency block is
required (the LPI2C / FLEXIO IP flavors are emitted as part of the I2c
component, not a separately-configured driver).

### 4.5 Model Runtime Blocks (Simulink model)


Assemble per Sec.6.

---

## 5. Initialize Function Pattern (minimal)

**Both shipped examples put only `I2c_GetVersionInfo` in the Initialize
Function subsystem.** Everything else runs at the model's base rate:

```
Event Listener (EventType = Initialize)
    +-- I2c_GetVersionInfo        (diagnostic -- write versionInfo to Data Store)
```

This is a genuine departure from CAN, UART, and LIN. The pattern is
consistent across both sync and async examples.

---

## 6. Runtime Data Flow

### 6.1 Async (`s32k3xx_i2c_async_s32ct`) -- Master polls, Slave responds via ISR

```
Top-level (runs once at first execution)
   +-- I2c_StartListening    ch = I2cChannel_1 (slave)  -- arm slave for incoming addresses
   +-- I2c_AsyncTransmit     ch = I2cChannel_0 (master, data_direction = Receive)
                             -- master addresses the slave, requests bytes; the driver
                               returns immediately, ISR delivers completion

ISR path (fires when slave receives an address matching its config)
   Hardware_Interrupt_Handler  irqGroup = I2c, irqHandlers = MBDT_I2c_Callback
        |
        | 3 outports:
        |   port 1 = function-call trigger
        |   port 2 = event code (I2c_EventType, e.g. I2C_EVENT_TX_REQ_SLAVE)
        |   port 3 = (unused; terminated)
        v
   MBDT_I2c_Callback subsystem (function-call triggered)
        +-- If (event == I2C_EVENT_TX_REQ_SLAVE)
              +-- I2c_PrepareSlaveBuffer  ch = I2cChannel_1, direction = Send
              |       (arms slave TX with the response bytes from `slave_send`)
              +-- If (status successful) -> increment `slave_send`
```

### 6.2 Sync (`s32k3xx_i2c_sync_ebt`) -- blocking master transfer, pre-armed slave

```
Top-level (runs once at model start via first-execution logic)
   +-- I2c_StartListening       ch = I2cChannel_1 (slave)
   +-- I2c_PrepareSlaveBuffer   ch = I2cChannel_1  (arm slave RX buffer)
   +-- I2c_SyncTransmit         ch = I2cChannel_0, data_direction = Send
   |        (BLOCKS until the transfer completes or errors out)
   |        input: `master_send` uint8 vector
   +-- I2c_GetStatus            ch = I2cChannel_0
          If (status == I2C_CH_FINISHED) -> increment `master_send`
```

No ISR handler in the model at all.

### 6.3 The two-role setup -- one MCU, two roles

Both shipped examples wire **Master and Slave on the same MCU**. The user physically bridges SDA/SCL between the FLEXIO pins (Master) and the LPI2C pins (Slave) with jumper wires plus pull-up resistors. This is the shipped-example convention -- it demonstrates both roles in a single model. For a real system with an external I2C device, only one channel is instantiated in the model (typically Master on the FLEXIO or LPI2C IP; Slave role only if the MCU is being polled by an external master).

### 6.4 Multi-byte read output width -- Signal Specification is required

**The `I2c` block's RX / receive data output propagates as an inherited,
effectively width-1 (scalar) signal at edit time**, regardless of how
many bytes the transfer actually reads. The S-Function does not assert a
fixed output width, so Simulink cannot infer the vector size during
dimension propagation.

Consequence: **any downstream consumer that expects a vector** -- a
`Demux` that splits the read into N bytes, or per-byte processing (bit
masking, shifting, endianness handling) -- will fail at
diagram-update / build time with a dimension-mismatch error, because it
sees a width-1 signal where it needs width N.

**Fix (generic, any MBDT family, any multi-byte read):** insert a
`Signal Specification` block (`simulink/Signal Attributes/Signal
Specification`) with `Dimensions = N` between the `I2c` block's data
output and the vector consumer, where N is the number of bytes requested
by the transfer. This forces / asserts the signal width without
modifying the sealed I2c S-Function.

```
I2c (Receive / burst read, N bytes)
    | y = RX data  (inherited, width-1 at edit time)
    v
Signal Specification  (Dimensions = N)
    | y = width-N vector (asserted)
    v
Demux (N outputs)  /  per-byte processing
```

For a single-byte read no shaping is needed. Only multi-byte reads that
feed a `Demux` or other vector consumer require the Signal Specification
block.

### 6.5 The single-event ISR pattern


`irqHandlers.Enum` under `irqGroup = I2c` has **exactly one entry**: `MBDT_I2c_Callback`. Same single-callback pattern as UART. All I2C events (TX_REQ_SLAVE, RX_REQ_SLAVE, transfer complete, error) are demuxed inside the callback subsystem by the event-code output on port 2.

Documented event constant (from the README):

| Constant | Meaning | Emitted when |
|---|---|---|
| `I2C_EVENT_TX_REQ_SLAVE` | Master addressed this slave and is requesting data | Async example -- the callback responds by calling `I2c_PrepareSlaveBuffer` with `data_direction = Send` |

Other event constants presumed by the RTD I2c driver (`I2C_EVENT_RX_REQ_SLAVE`, transfer-complete, error) but not exercised by the shipped example. **Do not invent constants** -- read them from the model's If-block comparators and treat them as ground truth.

---

## 7. Interrupt Dependencies

1. **Async mode:** exactly one `Hardware_Interrupt_Handler` with `irqGroup = I2c, irqHandlers = MBDT_I2c_Callback`.
2. **Sync mode:** no ISR handler in the model.
3. **The `irqHandlers.Enum` under `irqGroup = I2c` has exactly one entry** (`MBDT_I2c_Callback`) -- same pattern as UART.
4. NVIC enablement: `LPI2C{N}_MASTER_IRQn` / `LPI2C{N}_SLAVE_IRQn` / `FLEXIO_IRQn` per instance in async use.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Channel logical name (`I2cChannel_0`) | S32CT/EB tresos Peripherals -> I2c | `channel.Enum` on `I2c` block |
| Physical peripheral (FLEXIO / LPI2C{N}) | S32CT/EB tresos Peripherals -> I2c | Compiled-in; not exposed on block |
| Baud rate (typically 100 or 400 kbps) | S32CT/EB tresos Peripherals -> I2c | Compiled-in; not exposed |
| Master/Slave role | S32CT/EB tresos + which API function calls the channel | Implicit -- no block parameter |
| Slave address | S32CT/EB tresos Peripherals -> I2c -> slave configuration | Compiled-in; not exposed |
| SDA/SCL pin muxing | S32CT/EB tresos Pins | Compiled-in; not exposed |
| Clock source | S32CT/EB tresos Peripherals -> I2c -> clock reference -> Mcu | Compiled-in; not exposed |
| NVIC enable | S32CT/EB tresos Platform -> Interrupt Controller | Manifests as `MBDT_I2c_Callback` firing |
| Transfer direction (per call) | Simulink model | `data_direction` on `I2c_SyncTransmit` / `I2c_AsyncTransmit` |
| 7-bit vs 10-bit addressing | Simulink model | `bits_slave_address_size` boolean |
| Board-init entry `I2c_Init(&I2c_Config)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

---

## 9. Common Usage Patterns

### 9.1 Master read from external slave (blocking)

```
Initialize Function
   +-- I2c_GetVersionInfo  (diagnostic only)

Top-level
   +-- (Ground / Constant driving the read-request buffer)
   +-- I2c_SyncTransmit    ch = I2cChannel_0, data_direction = Receive
   |       output: byte(s) read from external device
   +-- I2c_GetStatus       ch = I2cChannel_0
```

### 9.2 Master write to external slave (blocking)

```
Top-level
   +-- (Constant with the payload bytes)
   +-- I2c_SyncTransmit    ch = I2cChannel_0, data_direction = Send
   +-- I2c_GetStatus       ch = I2cChannel_0
          If status == I2C_CH_FINISHED -> next byte
```

### 9.3 Master write asynchronously with completion notification

```
Top-level
   +-- I2c_AsyncTransmit   ch = I2cChannel_0, data_direction = Send

Hardware_Interrupt_Handler  irqGroup = I2c, irqHandlers = MBDT_I2c_Callback
    | trigger + event code
    v
MBDT_I2c_Callback subsystem
    +-- If (event == transfer-complete)
          -> increment counter / arm next transfer
```

### 9.4 Same-MCU Master + Slave loopback (shipped-example pattern)

```
Initialize Function
   +-- I2c_GetVersionInfo

Top-level
   +-- I2c_StartListening    ch = I2cChannel_1 (slave)
   +-- I2c_AsyncTransmit     ch = I2cChannel_0 (master, direction = Receive)
   +-- (callback subsystem for I2C_EVENT_TX_REQ_SLAVE, calls
        I2c_PrepareSlaveBuffer ch = I2cChannel_1, direction = Send)

Hardware wiring (user provides with jumpers):
   FLEXIO SDA/SCL  --- SDA / SCL ---- LPI2C SDA/SCL
   VDD  --- 2 kohm -- SDA  (external pull-up, board-dependent)
   VDD  --- 2 kohm -- SCL  (external pull-up, board-dependent)
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `channel.Enum = "No channels configured"` on any I2c block (except GetVersionInfo) | S32CT/EB tresos has no `I2cChannel_N` declared | Open config tool via `opening-mbdt-config-tool`; add channel in Peripherals -> I2c |
| Build links but no I2C traffic on the wire | Missing board-init entry OR missing external pull-up resistors on SDA/SCL | Verify `I2c_Init` in board init (Sec.4.4); check board hardware -- some boards require 2 kohm pull-ups |
| Sync transfer blocks forever | Slave never responds (wrong address, wrong wiring, missing pull-ups) | Verify slave address in config tool matches what master addresses; check jumper wires; verify pull-ups |
| Async callback never fires | `Hardware_Interrupt_Handler` missing or `LPI2C{N}_*_IRQn` disabled in config tool | Add ISR handler with `irqGroup = I2c, irqHandlers = MBDT_I2c_Callback`; enable NVIC in Platform section |
| `I2c_GetStatus` returns non-`I2C_CH_FINISHED` after a sync transfer | Bus error, NACK from slave, arbitration lost | Check status code against RTD `I2c_StatusType` enum; verify slave is listening and pull-ups are present |
| ISR fires but nothing happens in callback | Callback If-block dispatches on event codes that don't match what the driver emits | Read the event-code constants from the model's If-block comparators -- do not invent them |
| Slave-role channel never sees the master's address | Missing initial `I2c_StartListening` on the slave channel | Add `I2c_StartListening` at the top level of the model, before any master transfer |
| 10-bit slave address not recognized | `bits_slave_address_size = 'off'` on the master's transmit block | Set `bits_slave_address_size = 'on'` on the transmit block |
| Same address used by two virtual slaves -- collision | I2C protocol allows only one slave per address; do not duplicate | Assign distinct 7-bit or 10-bit addresses in the config tool per slave channel |
| Build fails: unresolved `I2c_Init` / `I2c_SyncTransmit` | Missing board-init entry | Add via `editing-mbdt-board-init`. Never stub the function. |
| Diagram-update/build fails with a dimension mismatch where a `Demux` or per-byte processing consumes a multi-byte read output | The `I2c` read/receive data output is an inherited, width-1 signal at edit time; the vector consumer sees width-1 where it needs width N | Insert a `Signal Specification` block (`Dimensions = N`, N = bytes read) between the `I2c` data output and the consumer. See Sec.6.4. |

| Build fails: `fatal error: Lpi2c_Ip_CfgDefines.h` / `*_Cfg.h` No such file | Config tool did not emit the LPI2C (or FLEXIO) config unit -- often a leftover example channel + `I2cFlexIOUsed=true` suppressing the intended flavor | Do NOT edit the model. Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`; remove the unused/leftover channel flavor; re-validate and re-generate. See Sec.4.4 "Expected generated C files (I2C)". |


---

## 11. Board-Specific Considerations

- **External pull-up resistors are required on some boards.** The following boards need 2 kohm pull-ups on both SDA and SCL to VDD, at specific header pins:
  - **S32K311EVB-Q100** -- VDD at `J40.9`
  - **S32K312EVB-Q172** -- VDD at `J39.13`
  - **S32K388EVB-Q289** -- VDD at `J696.14`

  Boards with on-board pull-ups (S32K3X4EVB-Q257, FRDM-A-S32K344, XS32K396-BGA-DC) work without extra resistors.

- **Board-specific SDA/SCL header pins** (from the shipped READMEs):

  | Board | Master (FLEXIO) SDA / SCL | Slave (LPI2C) SDA / SCL |
  |---|---|---|
  | S32K311EVB-Q100 | PTC6 (J12.17) / PTC7 (J12.19) | PTD13 (J14.14) / PTD14 (J39.2) |
  | S32K312EVB-Q172, FRDM-A-S32K312 | PTC6 (J4.25) / PTC7 (J4.28) | PTD13 (J3.30) / PTD14 (J38.11) |
  | S32K344EVB-WB | PTE17 (J44.2) / PTE18 (J44.1) | PTD13 (J86.3) / PTD14 (J86.4) |
  | S32K3X4EVB-Q172, S32K3X4EVB-T172 | PTC6 (J4.17) / PTC7 (J4.19) | PTD13 (J3.30) / PTD14 (J38.8) |
  | FRDM-A-S32K344 | PTC6 (J2.17) / PTC7 (J2.19) | PTC9 (JB1.5) / PTC8 (JB1.7) |
  | S32K3X4EVB-Q257 | PTF21 (J354.12) / PTF20 (J354.9) | PTC6 (J353.25) / PTC7 (J353.28) |
  | S32K388EVB-Q289, S32K389EVB-Q437 | PTA22 (J696.29) / PTA21 (J702.7) | PTC9 / PTC8 (Pin Matrix) |
  | XS32K396-BGA-DC | PTD3 (J62.6) / PTB25 (J62.7) | PTF8 (J39.3) / PTF7 (J39.2) |

  Never invent these -- verify against the `.mex` via `nxp_s32ct_inspect(kind='pins')`.

- **`I2cChannel_0` is always FLEXIO in the shipped examples**, but this is a config-tool decision, not a hard rule. The channel could be reconfigured to use LPI2C in a custom project.

- **FreeMASTER `.pmpx` companion project** ships with each example and plots `master_send` / `slave_recv` / `master_recv` / `slave_send` / `versionInfo`.

- **Cross-family portability:** the behavioral model (the `api_func` function set discovered live, single ISR callback, master-role-implicit) is expected to hold on other MBDT families. Board-init component name may differ (S32K3 uses `I2c`; other families may use `I2c_43_LPI2C` or similar). Discover live via `get_mbdt_board_init({family})`.


---

## 12. Guardrails (I2C-specific)


- **Never stub I2C functions.** Do not hand-write `I2c_Init`, `I2c_SyncTransmit`, `I2c_AsyncTransmit`, `MBDT_I2c_Callback`, or any RTD function into generated C. The board-init entry (Sec.4.4) is what triggers MBDT to generate the driver code.

- **Never invent channel names.** `I2cChannel_0`, `I2cChannel_1` are exact strings from the config tool. Read them from the block's live `Enum`.

- **`data_direction` is only meaningful on `I2c_SyncTransmit` and `I2c_AsyncTransmit`.** On `I2c_StartListening`, `I2c_GetStatus`, `I2c_GetVersionInfo` it is silently ignored.

- **`bits_slave_address_size` must match the config-tool addressing mode.** If the slave is configured for 7-bit addressing but the master's block has `bits_slave_address_size = 'on'`, the transaction will fail with an addressing error. Verify against Peripherals -> I2c.

- **`I2c_StartListening` must precede any slave-side transfer.** If it is missing, the slave channel silently ignores incoming addresses. Not a build error -- a runtime silence.

- **Never route an I2C interrupt through a parameter on the `I2c` block.** No `isr_*`, `callback_*` parameter exists on `{family}_i2c`. All I2C callbacks go through the `Hardware_Interrupt_Handler` block.

- **Never set `text` on any `I2c` block** -- system-managed.

- **When the model runs on S32K311EVB-Q100, S32K312EVB-Q172, or S32K388EVB-Q289, verify pull-up resistors before diagnosing model-side issues.** Missing pull-ups look exactly like a driver failure but the driver is fine -- the bus can't idle high. This is a hardware failure that the model cannot detect or work around.
