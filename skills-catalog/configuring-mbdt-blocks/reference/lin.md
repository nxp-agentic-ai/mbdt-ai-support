# LIN -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the LIN
peripheral on any NXP MBDT-targeted Simulink model. The behavioral model
is expected to hold cross-family (S32K3);
exact enum labels and board-init symbols may differ per family. The LIN
examples shipped with the family MBDT toolbox are a good starting point
for confirming block behavior, wiring, and config-tool setup.

> **Tip -- start from a shipped example.** Open a shipped LIN example
> via [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md);
> its `.mex` project (Pins -> LPUART/FLEXIO, Peripherals -> Lin +
> Peripherals -> LinIf, Platform -> NVIC) plus its model (Initialize
> Function per-channel wakeup, top-level Lin_SendFrame, LinIf callback
> block wired to a Function-Call Subsystem) forms a coherent reference
> that mirrors the sections below.

> **LIN is architecturally different from CAN, UART, I2C.** Read Sec.3
> carefully -- LIN uses a **dedicated `LinIf` callback block**
> (`MaskType = {family}_linif`) instead of routing through
> `Hardware_Interrupt_Handler`. This is the only peripheral covered so
> far that departs from the family ISR-handler pattern. **Only one
> `LinIf_*` callback -- `LinIf_HeaderIndication` -- is truly
> bidirectional**; the other five callbacks are output-only or nearly so
> (see Sec.3.3).

---

## 1. Peripheral Overview

The LIN peripheral in MBDT is a composite of five artefacts:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins, Peripherals -> Lin, Peripherals -> LinIf, Platform -> NVIC) | External to the model | External config tool |
| 2 | Board-init entry `Lin_43_LPUART_FLEXIO_Init(&Lin_43_LPUART_FLEXIO_xConfig)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Per-channel wakeup sequence in `Initialize Function`: `Lin_WakeUpInternal` + `Lin_CheckWakeUp` | Simulink model | This skill |
| 4 | Runtime `Lin_SendFrame` + `Lin_GetStatus` polling loop | Simulink model | This skill |
| 5 | Slave-side callback: `LinIf_HeaderIndication` block + a **Function-Call Subsystem** that responds to it | Simulink model | This skill |

**Key departures from other peripherals:**

- **LIN has NO `Hardware_Interrupt_Handler` blocks.** All LIN callbacks (`LinIf_HeaderIndication`, `LinIf_RxIndication`, `LinIf_TxConfirmation`, `LinIf_LinErrorIndication`, `LinIf_WakeupConfirmation`, `LinIf_CheckWakeup` -- exactly 6 in the S32K3 live enum) go through the standalone `LinIf` block with `MaskType = {family}_linif`. LIN uses zero `Hardware_Interrupt_Handler` blocks.
- **Only `LinIf_HeaderIndication` is fully bidirectional** (5 in / 3 out) -- the block triggers the user subsystem *and* takes response values back into the driver. The other 5 `LinIf_*` callbacks are output-only (or 1-in for `LinIf_CheckWakeup`). See Sec.3.3 for verified port shapes per callback.
- **`Lin_SendFrame` has 5 input ports** carrying the frame parameters (PID, Cs, Drc, Dl, SduPtr). Frame configuration is per-call, not per-block.
- **Board-init pulls TWO headers**: `Lin_43_LPUART_FLEXIO.h` and `LinIf.h`. Only one `_Init` call, but both layers must be visible to the compiled code.
- **LIN requires external 12V VBAT** on the LIN header -- LIN uses a 12 V single-wire bus, not MCU logic-level pins.

---

## 2. The `Lin` Block -- Complete Behavioral Model

**One `Lin` block = one `Lin_*` function call.** Every block has
`MaskType = {family}_lin` (e.g. `s32k3_lin`) and is an `S-Function`.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** from the block in front of you
via `get_param({linBlk}, 'DialogParameters')` -- the set of available
`Lin_*` functions is owned by the installed toolbox version and must
never be carried from memory.

**Behavioral facts an AI agent must know (independent of the exact
function list, which is discovered live):**

- **The live S32K3 `Lin` enum has 8 entries** (illustrative, validate
  live): `Lin_CheckWakeUp`, `Lin_GetVersionInfo`, `Lin_SendFrame`,
  `Lin_GoToSleep`, `Lin_GoToSleepInternal`, `Lin_WakeUp`,
  `Lin_WakeUpInternal`, `Lin_GetStatus`. Both wake and sleep expose an
  `_Internal` counterpart (local state transition, no bus pulse) and a
  plain form (generates the wakeup/sleep pulse on the wire).
- **All LIN functions are synchronous / event-polled** -- there is no
  `Lin_Async*` and no `Lin_MainFunction_*`. LIN is inherently a polled
  protocol; the driver does the header/response scheduling internally,
  the application polls a `Lin_GetStatus`-style function for transitions.
- **A `Lin_SendFrame`-style function is the *only* runtime block for both
  master and slave TX/RX.** The `Drc` input port (Data Response Code)
  selects whether this frame is master-sends-data (`LIN_FRAMERESPONSE_TX`),
  master-receives-data-from-slave (`LIN_FRAMERESPONSE_RX`), or
  master-schedules-a-header-only (`LIN_FRAMERESPONSE_IGNORE`).
- **`Lin_WakeUpInternal` vs `Lin_WakeUp`** (and the symmetric
  `Lin_GoToSleepInternal` vs `Lin_GoToSleep`): the `_Internal` form
  transitions the local driver state without emitting a bus pulse (used
  for local startup / shutdown); the plain form emits the corresponding
  wakeup or sleep pulse on the wire. All shipped examples use
  `Lin_WakeUpInternal` at startup; sleep functions are available for
  power-management scenarios but are not exercised in the shipped
  examples.
- **A `Lin_GetStatus`-style function returns numeric states** consumed by
  If-action subsystems -- e.g. `1` = `LIN_TX_OK` (transmission completed),
  `5` = `LIN_RX_OK` (reception completed). Others exist (LIN_OPERATIONAL,
  LIN_BUSY, LIN_RX_ERROR, ...) -- read them from the model's constants,
  don't invent.
- **Master and Slave use the same block class.** There is no `Lin_Master_*`
  or `Lin_Slave_*`. The role of a `LinChannel_N` is decided by the config
  tool (Peripherals -> Lin -> channel -> LinNodeType = master/slave).
- Selecting `api_func` reshapes the S-Function's ports. **Set `api_func`
  first.**

Whenever this reference names a specific `Lin_*` function below, treat
it as an **illustrative** label (for example, from an S32K3 example) --
validate it against the block's live `api_func.Enum` before selecting
it, and refuse near-misses.

### 2.2 Parameter surface (constant across all `api_func` values)

The `Lin` block has an **unusually minimal** parameter surface -- only 3 dialog fields:

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `channel` | enum | Channel | `LinChannel_N` -- logical driver channel | All except `Lin_GetVersionInfo` |
| `text` | string | *(empty)* | System-managed cache -- never set | Read-only |

Everything runtime-specific (PID, checksum type, direction, data length, payload) comes through the block's **input ports** on `Lin_SendFrame` -- see Sec.2.3. Everything setup-specific (baud rate, node type, PID list, frame configuration table) is compiled in from the config tool.

### 2.3 `Lin_SendFrame` -- the 5 runtime input ports

The single most important LIN block. Verified port layout:

```
Lin_SendFrame inputs:
  port 1 = PID       (uint8; the Protected Identifier byte, e.g. 0x1A = 26)
  port 2 = Cs        (Lin_FrameCsModelType enum)
                       LIN_CLASSIC_CS   <- LIN 1.x / 2.0 checksum
                       LIN_ENHANCED_CS  <- LIN 2.1+ checksum with PID in sum
  port 3 = Drc       (Lin_FrameResponseType enum)
                       LIN_FRAMERESPONSE_TX      <- this node sends data
                       LIN_FRAMERESPONSE_RX      <- this node receives data
                       LIN_FRAMERESPONSE_IGNORE  <- master schedules header only
  port 4 = Dl        (uint8, data length in bytes, 1..8)
  port 5 = SduPtr    (uint8 vector, payload bytes)
                       Wire to Ground when Drc = LIN_FRAMERESPONSE_RX
                       (no data to send when receiving)

Lin_SendFrame output:
  Status   E_OK (0) if the frame was successfully queued
           E_NOT_OK (1) if the channel is busy or the PID is invalid
```

These map directly to the `Lin_SendFrame` C function signature in the RTD LIN driver. The enum constants (`LIN_CLASSIC_CS`, `LIN_FRAMERESPONSE_TX`, ...) are exposed as Simulink Enumerated Constant blocks in the shipped examples -- the enum type names (`Lin_FrameCsModelType`, `Lin_FrameResponseType`) come from the compiled Lin driver headers.

### 2.4 The `channel` enum

Observed live entries in shipped examples: `LinChannel_0 | LinChannel_1`. Semantics from the READMEs and the board-init header:

```
LinChannel_0  ->  FLEXIO peripheral (used as Master in the dual-channel examples)
LinChannel_1  ->  LPUART peripheral (used as Slave in the dual-channel examples)
```

The peripheral flavor behind each channel is decided by the config tool
(Peripherals -> Lin -> channel -> `LinHwUsing = LPUART_IP | FLEXIO_IP`). Both channels
run at 19200 bps in the shipped examples (the LIN standard baud rate).

### 2.5 Sentinel rules

| `api_func` | `channel` sentinel = error? |
|---|---|
| `Lin_GetVersionInfo` | NO -- no channel needed |
| Everything else | YES |

If `channel.Enum = {"No channels configured"}`, route to `opening-mbdt-config-tool` and declare a `LinChannel_N` in Peripherals -> Lin.

### 2.6 Selection ordering

1. `api_func` first.
2. `channel` next.
3. Runtime frame parameters (PID, Cs, Drc, Dl, SduPtr) are Simulink **input ports** -- set them by wiring signals, not by `set_param`.

---

## 3. The `LinIf` Block -- LIN's Unique Callback Mechanism

**LIN does not use `Hardware_Interrupt_Handler`.** Every LIN callback
that would be routed through `irqGroup = {driver}` on other peripherals
is instead implemented as a **standalone S-Function block** with
`MaskType = {family}_linif` (e.g. `s32k3_linif`). This is the only
peripheral so far that departs from the family ISR-handler pattern.

### 3.0 When is a `LinIf` block needed?

Use a `LinIf` block **only when the model must react to an asynchronous
event dispatched by the LIN driver into the LIN Interface upper layer**.
If the node just drives the bus and polls `Lin_GetStatus`, no `LinIf`
block is needed. The entire LinIf callback surface is gated by
`LINIF_WAKEUP_SUPPORT == STD_ON` -- if the config tool disables wakeup
support, none of the callbacks are compiled in.

**Per-callback semantics** (distilled from the LinIf upper-layer
contract, independent of any specific example):

| Callback | Role scope | Fires when... | What the user code must do |
|---|---|---|---|
| `LinIf_HeaderIndication` | **Slave only** | A LIN header arrives on a Slave channel | Read the incoming PID; write back frame length, checksum type (`Cs`), response direction (`Drc`) and -- if `Drc = LIN_FRAMERESPONSE_TX` -- the response payload. Return `E_OK` to accept, `E_NOT_OK` to reject. This is the **only bidirectional** callback: the driver consumes what your subsystem writes back to complete the transaction. |
| `LinIf_RxIndication` | **Slave only** | The Slave has finished receiving a response the Master transmitted to it | Consume the received SDU. Output-only from the model's point of view. |
| `LinIf_TxConfirmation` | **Slave only** | The Slave has finished transmitting its own response bytes on the wire | Post-TX bookkeeping (heartbeat LED, counter). Output-only. |
| `LinIf_LinErrorIndication` | **Slave only** | The Slave detected an error during header or response processing (parity / framing / checksum) | Log the error, drive a fault LED, transition to safe state. Output-only; carries an `ErrorStatus` code (`Lin_SlaveErrorType`). |
| `LinIf_CheckWakeup` | Either role | EcuM has been notified of a wakeup and is asking LinIf whether that wakeup source belongs to a LIN channel it manages | Return `E_OK` if this LinIf instance owns the wakeup source, `E_NOT_OK` otherwise. Note: parameter is an **EcuM wakeup source**, not a LinChannel. |
| `LinIf_WakeupConfirmation` | Either role | The LIN Driver (or LIN Transceiver Driver) confirms a successful wakeup detection (during `CheckWakeup` polling or power-on-by-bus) | Application-defined post-wakeup action. Output-only. |

**Decision table:**

| Node role / situation | Needs `LinIf`? | Which callback |
|---|---|---|
| Slave -- must answer incoming headers | **Yes (mandatory)** | `LinIf_HeaderIndication` |
| Slave -- react when RX of Master's response completes | Yes (optional) | `LinIf_RxIndication` |
| Slave -- react when TX of Slave's own response completes | Yes (optional) | `LinIf_TxConfirmation` |
| Slave -- react to bus errors (parity/framing/checksum) | Yes (optional) | `LinIf_LinErrorIndication` |
| Either role -- react after a wakeup completes | Yes (optional) | `LinIf_WakeupConfirmation` |
| Either role -- polling-style wakeup interrogation from EcuM | Yes (optional) | `LinIf_CheckWakeup` |
| Master -- pure TX, header-only, or request-response by polling `Lin_GetStatus` for `LIN_TX_OK` / `LIN_RX_OK` | **No** | -- |

**Important scoping rule:** `HeaderIndication`, `RxIndication`,
`TxConfirmation`, and `LinErrorIndication` are **Slave-only** -- they
are only meaningful on a node that has at least one LinChannel with
`LinNodeType = LIN_SLAVE_NODE`. `CheckWakeup` and `WakeupConfirmation`
are wakeup-source-oriented (not channel-oriented) and are usable on
either role.

Rule of thumb: **if the node is ever passive on the bus -- waiting to be
addressed, waiting for a wakeup, or watching for slave-side errors --
it needs `LinIf`. If it is purely driving the bus and polling status,
it does not.**

### 3.1 The `api_func` enum -- the callback selector

**Always read the live `api_func.Enum`** from the `LinIf` block via
`get_param({linIfBlk}, 'DialogParameters')` -- the set of available
`LinIf_*` callbacks is owned by the installed toolbox version and must
never be carried from memory.

The entries are the `LinIf_*` callback function names in the RTD driver.
Each `{family}_linif` block wraps exactly one callback. Callbacks
observed in the shipped examples (illustrative -- validate against the
live enum):

- `LinIf_HeaderIndication` -- Slave: called when a header arrives on the bus
- `LinIf_RxIndication` -- Slave: called when the response data has been received
- `LinIf_TxConfirmation` -- Slave: called when the response data has been transmitted
- `LinIf_LinErrorIndication` -- Any: called on bus error
- `LinIf_WakeupConfirmation` -- Any: called after a bus wakeup completes
- `LinIf_CheckWakeup` -- Any: polling-style wakeup interrogation hook

### 3.2 Parameter surface

| Name | Type | Prompt | Semantics |
|---|---|---|---|
| `api_func` | enum | Function | Callback selector (see Sec.3.1) |
| `text` | string | *(empty)* | System-managed |

**No `channel` selector.** The block is family-wide. Which LinChannel triggered the callback arrives at runtime via one of the block's outputs (see Sec.3.3).

### 3.3 `LinIf_HeaderIndication` -- bidirectional port shape (unique!)

The `LinIf_HeaderIndication` block is unlike any other block in MBDT
because it is **bidirectional**: it triggers the user subsystem *and*
takes response values back. Verified port layout:

```
LinIf_HeaderIndication:
  OUTPUTS (3, driving the user's function-call subsystem):
    port 1 = function-call trigger
              (fires when a header arrives on any LinChannel)
    port 2 = Channel  (uint8 -- which LinChannel the header came in on)
    port 3 = Pid      (uint8 -- the incoming Protected Identifier byte)

  INPUTS (5, from the user's function-call subsystem back to the driver):
    inport 1 = Cs      (Lin_FrameCsModelType -- the response's checksum model)
    inport 2 = Drc     (Lin_FrameResponseType -- the response's direction:
                        TX = this Slave sends data,
                        RX = this Slave receives data,
                        IGNORE = this Slave does not respond)
    inport 3 = Dl      (uint8, data length of the response)
    inport 4 = Data    (uint8 vector, payload if Drc = TX)
    inport 5 = Status  (E_OK if this Slave will handle this header,
                        E_NOT_OK if this Slave ignores this header)
```

Semantic flow:

1. A header arrives on the bus, targeting some PID.
2. The `LinIf_HeaderIndication` block fires its function-call trigger, exposing the incoming `Channel` and `Pid`.
3. The user's function-call subsystem examines `Pid` (typically against a Data Store or constant per Slave), and either:
   - **Handles it**: writes back `Cs`, `Drc`, `Dl`, `Data` (if TX response) and `Status = E_OK`. The driver uses these values to complete the LIN transaction.
   - **Ignores it**: writes back `Status = E_NOT_OK`. The driver drops the frame.

Observed in `s32k3xx_lin_master_request_slave_send_s32ct` and
`s32k3xx_lin_master_send_slave_receive_ebt`.

### 3.4 The other 5 `LinIf_*` callbacks

Unlike `LinIf_HeaderIndication`, the remaining 5 callbacks are
**output-only** (or nearly so) -- they notify the application of an
event and do not require the user subsystem to write values back into
the driver. Verified port shapes (live from S32K3 toolbox):

| Callback | Inports | Outports | Notes |
|---|---|---|---|
| `LinIf_RxIndication` | 0 | 3 | Trigger + Channel + received-length notification |
| `LinIf_TxConfirmation` | 0 | 2 | Trigger + Channel (fires when Slave finishes transmitting its response) |
| `LinIf_WakeupConfirmation` | 0 | 2 | Trigger + Channel (fires after a wakeup sequence completes) |
| `LinIf_CheckWakeup` | 1 | 2 | Trigger + Channel out; 1 inport for the polling-hook response |
| `LinIf_LinErrorIndication` | -- | -- | Slave-only. Requires `Lin_SlaveErrorType` to be in scope -- can only be instantiated inside a LIN example model; port shape not verified in isolation. Carries an `ErrorStatus` code alongside the Channel output. |

For any of these, add a standalone `LinIf` block at the model's top
level and select the corresponding `api_func`. Wire its trigger + data
outports to a function-call subsystem. For `LinIf_CheckWakeup`, also
drive the single inport with the `Std_ReturnType` return value the
driver expects (typically `E_OK` to acknowledge ownership of the wakeup
source, `E_NOT_OK` to decline).

---

## 4. Required Block Catalog

| Block name | `MaskType` | Role |
|---|---|---|
| `Lin` | `{family}_lin` | Wraps one `Lin_*` function (`Lin_SendFrame`, `Lin_WakeUpInternal`, `Lin_GetStatus`, ...) |
| `LinIf` | `{family}_linif` | Wraps one `LinIf_*` callback (`LinIf_HeaderIndication` etc.). **Replaces `Hardware_Interrupt_Handler` for LIN.** |
| `FreeMASTER Config` (optional) | `{family}_fm_config` | Ships in the `.pmpx` companion project for observability |

---

## 5. Configuration Workflow (6 steps)

Steps 1-4 in the external configuration tool; steps 5-6 in the Simulink model.

### 5.1 Pins (S32 Configuration Tools -> Pins, or EB tresos -> Port)

Route the LIN pin for each channel -- one wire per LIN bus. Master and Slave, if colocated on the same MCU, use *different* LPUART/FLEXIO instances with their own physical LIN pins (bridged externally through a LIN transceiver + 12 V VBAT).

Sample from the shipped READMEs (channel-to-header pin per board):

```
S32K3X4EVB-Q172, S32K3X4EVB-T172:  Master LIN1 = J23.8,  Slave LIN2 = J23.7
FRDM-A-S32K344                  :  Master LIN1 = J14.2,  Slave LIN2 = J14.3
S32K3X4EVB-Q257                 :  Master LIN1 = J675.8, Slave LIN2 = J675.7
S32K388EVB-Q289, S32K389EVB-Q437:  Master LIN1 = J28.8,  Slave LIN2 = J28.7
XS32K396-BGA-DC (single-node)   :  LIN1 = J52.8, GND = J52.1/J52.2, VBAT = J52.5/J52.6
```

Pin numbers are **board-specific** -- never invent them. Discover via `nxp_s32ct_inspect(kind='pins')`.

### 5.2 Peripherals -> Lin (S32 Configuration Tools -> Peripherals)

For each logical channel:

```
LinChannel_{N}
    LinHwUsing    = LPUART_IP  |  FLEXIO_IP
    LinNodeType   = LIN_MASTER_NODE  |  LIN_SLAVE_NODE
    LinBaudrate   = 19200                (LIN standard rate)
    LinClockRef   = /Mcu/.../LIN_CLK
    (LinFrame table: list of PIDs this node knows about, with response
     direction and data length hints)
```

The **exact channel names** you assign here are what appear in the block's `channel` enum.

### 5.3 Peripherals -> LinIf (S32 Configuration Tools -> Peripherals)

Declare which LinIf callbacks should be routed through the MBDT LinIf blocks. Typically:

```
LinIfCallback_HeaderIndication   = enabled
LinIfCallback_RxIndication       = enabled (Slave)
LinIfCallback_TxConfirmation     = enabled (Slave)
LinIfCallback_LinErrorIndication = enabled (optional)
```

If a callback is not declared in the LinIf module, the corresponding
`s32k3_linif` block still exists (the enum is family-wide) but the
runtime will never fire it -- the driver has no hook to route to it.

### 5.4 Platform -> Interrupt Controller

Enable the NVIC entry for each LPUART / FLEXIO instance backing a LinChannel:

```
LPUART{N}_IRQn                    (for LPUART-backed channels)
FLEXIO_IRQn                       (for FLEXIO-backed channels)
```

### 5.5 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md):

```
Component : Lin_43_LPUART_FLEXIO
Priority  : 130          (after Uart=120, before I2c=140)
Enabled   : true
Headers   : #include "Lin_43_LPUART_FLEXIO.h"
            #include "LinIf.h"                      <- BOTH headers required
Code      : Lin_43_LPUART_FLEXIO_Init(&Lin_43_LPUART_FLEXIO_xConfig);
```

Only one `_Init` call -- but both headers must be visible so `LinIf.h`
symbols (used by the `LinIf` block's generated code) resolve at compile
time.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves (both `Lin_*` and `LinIf_*`), so you pick and
drive the right function; the **IM** covers generated-file expectations,
init order, and NVIC prerequisites. A single RTD plugin covers both the
Lin driver and the LinIf module -- no separate `LinIf_TS_*` plugin
exists. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-version
segments (filenames are uppercased):

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Lin_43_LPUART_FLEXIO_TS_T40D*_M70I*_R0\doc\
    RTD_LIN_43_LPUART_FLEXIO_IM.pdf   RTD_LIN_43_LPUART_FLEXIO_UM.pdf
```

### 5.6 Model Runtime Blocks (Simulink model)

Assemble per Sec.6 (initialization) + Sec.7 (runtime).

---

## 6. Initialization Sequence -- Per-Channel Wakeup

Every observed LIN example uses the same per-channel startup pattern
inside the `Initialize Function` subsystem:

```
Event Listener (EventType = Initialize)
    |
    +-- Lin_GetVersionInfo        (diagnostic -- store versionInfo)
    |
    +-- Lin_WakeUpInternal   ch = LinChannel_0     (master)
    +-- Lin_CheckWakeUp      ch = LinChannel_0     (confirm operational)
    |
    +-- Lin_WakeUpInternal   ch = LinChannel_1     (slave, if applicable)
    +-- Lin_CheckWakeUp      ch = LinChannel_1
    |
    +-- Lin_SendFrame        ch = LinChannel_0     <- FIRST HEADER on master
              inputs = (PID = 0x1A,
                        Cs  = Lin_FrameCsModelType.LIN_CLASSIC_CS,
                        Drc = Lin_FrameResponseType.LIN_FRAMERESPONSE_RX,
                        Dl  = 2,
                        SduPtr = Ground)
```

**Notes:**

- The pair `Lin_WakeUpInternal` -> `Lin_CheckWakeUp` is repeated **per LinChannel** in use -- if you have two channels, you have two pairs.
- The first `Lin_SendFrame` in the Initialize Function primes the master's LIN state machine so subsequent frames can flow. Runtime logic (see Sec.7) then loops on `Lin_GetStatus` to send the next frame.
- On a Slave-only channel there is **no `Lin_SendFrame` in Initialize Function** -- the Slave is passive until a header arrives on the wire.

---

## 7. Runtime Data Flow

### 7.1 Master send-and-poll loop (canonical)

```
Model base rate
    |
    v
Lin_GetStatus  ch = LinChannel_0    ->  status integer
    |
    v
If (status == LIN_TX_OK)  --> If Action Subsystem
                                  |
                                  +-- increment `Master_Send[0]` (payload byte)
                                  +-- Lin_SendFrame  ch = LinChannel_0
                                  |       inputs = (PID, LIN_CLASSIC_CS,
                                  |                 LIN_FRAMERESPONSE_TX, 2,
                                  |                 Master_Send)
                                  +-- Dio_FlipChannel  DioLed2 (TX heartbeat)
```

Observed in `s32k3xx_lin_master_send_slave_receive_ebt` and
`s32k37x_s32k39x_lin_master_send_ebt`.

### 7.2 Master request-response loop

Same as Sec.7.1 but `Drc = LIN_FRAMERESPONSE_RX` -- the master schedules a
header requesting data from a Slave PID, then waits for `LIN_RX_OK`:

```
If (status == LIN_RX_OK)  --> If Action Subsystem
                                  |
                                  +-- (Master_Request now holds the Slave's response)
                                  +-- Lin_SendFrame  ch = LinChannel_0
                                          inputs = (PID, LIN_CLASSIC_CS,
                                                    LIN_FRAMERESPONSE_RX, 2,
                                                    Ground)
```

Observed in `s32k3xx_lin_master_request_slave_send_s32ct`.

### 7.3 Slave callback path (via `LinIf_HeaderIndication`)

```
Header arrives on LinChannel_1 -> driver dispatches to LinIf
    |
    v
LinIf_HeaderIndication block  (MaskType = s32k3_linif)
    |
    | outputs:
    |   port 1 = function-call trigger
    |   port 2 = Channel  (which LinChannel)
    |   port 3 = Pid      (incoming PID)
    v
Function-Call Subsystem (user-authored)
    |
    +-- Reads Data Store `Slave_PID_of_interest`  (e.g. 0x1A)
    +-- If (Pid == Slave_PID_of_interest && Channel == LinChannel_1)
    |       |
    |       v
    |   "Header is sent for this Slave" branch:
    |       +-- write inport 1 (Cs)     = LIN_CLASSIC_CS
    |       +-- write inport 2 (Drc)    = LIN_FRAMERESPONSE_TX  (or RX)
    |       +-- write inport 3 (Dl)     = 2
    |       +-- write inport 4 (Data)   = `Slave_Send` (payload if TX)
    |       +-- write inport 5 (Status) = E_OK
    |       +-- increment `Slave_Send[0]`
    |       +-- Dio_FlipChannel  DioLed1 (Slave accepts)
    |
    +-- "Slave ignores the received header" branch:
            +-- write inport 5 (Status) = E_NOT_OK
            +-- Dio_FlipChannel  DioLed0 (unexpected header)
```

The response signals feed back into the `LinIf_HeaderIndication` block's
5 inports; the driver picks them up when the function-call subsystem
finishes executing.

### 7.4 The three shipped topologies at a glance

| Example | Master role | Slave role | LinIf | Notes |
|---|---|---|---|---|
| `s32k37x_s32k39x_lin_master_send_ebt` | LinChannel_0 (master TX) | External device | none | Simplest; single node sends frames to whatever LIN device is attached |
| `s32k3xx_lin_master_send_slave_receive_ebt` | LinChannel_0 (master TX) | LinChannel_1 (slave RX) | HeaderIndication | Dual-channel loopback; both roles on same MCU, bridged externally |
| `s32k3xx_lin_master_request_slave_send_s32ct` | LinChannel_0 (master requests) | LinChannel_1 (slave responds) | HeaderIndication | Dual-channel bidirectional; Slave writes the response payload back through the LinIf block |

---

## 8. Interrupt Dependencies

1. **LIN does NOT use `Hardware_Interrupt_Handler`.** Every LIN example has **zero** ISR handler blocks in the model.
2. **All LIN callbacks go through the `LinIf` block** (`MaskType = {family}_linif`) with `api_func` set to one of the `LinIf_*` callbacks discovered live in the block's `api_func.Enum`.
3. **Multiple `LinIf` blocks are allowed** if the model needs to react to multiple callbacks (e.g. one block for `LinIf_HeaderIndication`, another for `LinIf_LinErrorIndication`). Each is its own top-level block.
4. NVIC enablement is still required at the config-tool level (`LPUART{N}_IRQn` or `FLEXIO_IRQn`) -- the LinIf block does not obviate the NVIC entry, it just changes how the callback dispatches on the Simulink side.

---

## 9. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Channel logical name (`LinChannel_0`) | S32CT/EB tresos Peripherals -> Lin | `channel.Enum` on `Lin` block |
| Physical peripheral (LPUART / FLEXIO) | S32CT/EB tresos Peripherals -> Lin -> `LinHwUsing` | Compiled-in; not exposed |
| Node type (master / slave) | S32CT/EB tresos Peripherals -> Lin -> `LinNodeType` | Implicit -- no block parameter |
| Baud rate (typically 19200 bps for LIN) | S32CT/EB tresos Peripherals -> Lin -> `LinBaudrate` | Compiled-in; not exposed |
| Frame configuration table (PIDs, checksum, direction, DL) | S32CT/EB tresos Peripherals -> Lin | Compiled-in; not exposed |
| LIN pin muxing | S32CT/EB tresos Pins | Compiled-in; not exposed |
| Clock source | S32CT/EB tresos Peripherals -> Lin -> clock ref -> Mcu -> `LIN_CLK` | Compiled-in; not exposed |
| LinIf callback declarations | S32CT/EB tresos Peripherals -> LinIf | Manifests as the LinIf callback actually firing at runtime |
| NVIC enable | S32CT/EB tresos Platform -> Interrupt Controller | Manifests as `LinIf_*` callback firing |
| Frame PID | Simulink model -- input port 1 on `Lin_SendFrame` | Wired signal (typically Constant) |
| Frame checksum type (Cs) | Simulink model -- input port 2 | Enumerated Constant of type `Lin_FrameCsModelType` |
| Frame direction (Drc) | Simulink model -- input port 3 | Enumerated Constant of type `Lin_FrameResponseType` |
| Frame data length (Dl) | Simulink model -- input port 4 | Wired signal |
| Frame payload (SduPtr) | Simulink model -- input port 5 | Data Store Read or uint8 signal |
| Board-init entry `Lin_43_LPUART_FLEXIO_Init(...)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

---

## 10. Common Usage Patterns

### 10.1 Single-node master transmit (external slave)

```
Initialize Function
   +-- Lin_GetVersionInfo
   +-- Lin_WakeUpInternal   ch = LinChannel_0
   +-- Lin_CheckWakeUp      ch = LinChannel_0
   +-- Lin_SendFrame        ch = LinChannel_0
              (PID, LIN_CLASSIC_CS, LIN_FRAMERESPONSE_TX, DL, data)

Base rate
   Lin_GetStatus  ch = LinChannel_0
     |
     v
   If (status == LIN_TX_OK)  -> increment payload, Lin_SendFrame, DIO toggle
```

Observed in `s32k37x_s32k39x_lin_master_send_ebt` (single-node XS32K396 board).

### 10.2 Dual-channel Master + Slave on same MCU (send)

```
Initialize Function
   +-- Lin_GetVersionInfo
   +-- Lin_WakeUpInternal   ch = LinChannel_0   (master)
   +-- Lin_CheckWakeUp      ch = LinChannel_0
   +-- Lin_WakeUpInternal   ch = LinChannel_1   (slave)
   +-- Lin_CheckWakeUp      ch = LinChannel_1
   +-- Lin_SendFrame        ch = LinChannel_0   (first master TX frame)

Base rate
   Lin_GetStatus  ch = LinChannel_0  ->  If (LIN_TX_OK) -> next Lin_SendFrame

Slave side (top level)
   LinIf_HeaderIndication block  ->  Function-Call Subsystem
        (checks incoming PID, writes back Cs/Drc/Dl/Data/Status)

Hardware wiring:
   MCU LinChannel_0 pin -- LIN transceiver -+
                                            +-- 12V VBAT LIN bus
   MCU LinChannel_1 pin -- LIN transceiver -+
```

Observed in `s32k3xx_lin_master_send_slave_receive_ebt`.

### 10.3 Dual-channel Master requests, Slave responds

Same startup as Sec.10.2. Master's Lin_SendFrame uses `Drc = LIN_FRAMERESPONSE_RX` to schedule a header requesting data. Slave's `LinIf_HeaderIndication` subsystem responds with `Drc = LIN_FRAMERESPONSE_TX` + payload. Master's base-rate loop watches for `LIN_RX_OK` instead of `LIN_TX_OK`.

Observed in `s32k3xx_lin_master_request_slave_send_s32ct`.

### 10.4 Slave-only listener

```
Initialize Function
   +-- Lin_GetVersionInfo
   +-- Lin_WakeUpInternal   ch = LinChannel_1   (slave)
   +-- Lin_CheckWakeUp      ch = LinChannel_1

Top level
   LinIf_HeaderIndication block  ->  Function-Call Subsystem
        (only responds to specific PIDs; ignores others via Status = E_NOT_OK)
```

Not seen in isolation in the shipped examples, but derivable from Sec.10.2 by removing the master side.

---

## 11. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `channel.Enum = "No channels configured"` on any Lin block (except GetVersionInfo) | S32CT/EB tresos has no `LinChannel_N` declared | Open config tool via `opening-mbdt-config-tool`; add channel in Peripherals -> Lin |
| Build fails: unresolved `Lin_43_LPUART_FLEXIO_Init` or `LinIf_*` symbols | Missing board-init entry, or `LinIf.h` header not in the entry | Add via `editing-mbdt-board-init` with **both** `Lin_43_LPUART_FLEXIO.h` and `LinIf.h` in the Header list (Sec.5.5) |
| Build links but no LIN traffic on the wire | Missing 12 V VBAT on the LIN header, OR missing LIN transceiver, OR wrong `LinHwUsing` in config tool | Verify hardware: VBAT + GND on the LIN header, external LIN transceiver connected; verify `LinHwUsing` matches physical routing |
| `Lin_GetStatus` never reports `LIN_TX_OK` | Master's first `Lin_SendFrame` in Initialize Function never fired (missing wakeup pair), or PID rejected by config-tool frame table | Verify `Lin_WakeUpInternal` + `Lin_CheckWakeUp` per channel run before first frame; verify PID is in the LinFrame table |
| Slave never receives header (LinIf callback never fires) | LinIf callback not declared in config tool, or `LinIf_HeaderIndication` block missing from top level | Add the callback in Peripherals -> LinIf; add the `s32k3_linif` block with `api_func = LinIf_HeaderIndication` |
| `LinIf_HeaderIndication` callback fires but wrong PID/Channel behavior | Function-Call Subsystem's If-block compares against wrong PID or wrong Channel constant | Read the constants from Data Store / model constants -- do not invent PIDs |
| Slave's response never appears on the wire | Function-Call Subsystem writes `Status = E_NOT_OK`, or forgets to write inports 1-4 (Cs/Drc/Dl/Data) | Ensure Status = E_OK **and** all four response inports are driven with valid signals |
| Bus error (E_NOT_OK on Lin_GetStatus repeatedly) | Baudrate mismatch, checksum-model mismatch (Classic vs Enhanced), or hardware wiring | Match Cs input on `Lin_SendFrame` to what the peer node expects; verify 19200 bps on both ends; check LIN transceiver |
| Frame direction wrong (master expects TX but got RX event) | `Drc` input on `Lin_SendFrame` set to the wrong `Lin_FrameResponseType` | For master-sends-data set `Drc = LIN_FRAMERESPONSE_TX`; for master-polls-slave set `Drc = LIN_FRAMERESPONSE_RX`; for header-only broadcast set `LIN_FRAMERESPONSE_IGNORE` |
| Multi-channel example works for LinChannel_0 but not LinChannel_1 | Missing `Lin_WakeUpInternal` / `Lin_CheckWakeUp` pair for LinChannel_1 in Initialize Function | Add per-channel wakeup pair -- one for every channel used |

---

## 12. Board-Specific Considerations

- **LIN requires a 12 V VBAT power supply** on the LIN header. Unlike CAN's differential signaling or I2C's logic-level bus, LIN uses a single-wire 12 V bus. Missing VBAT = no traffic -- the MCU-side driver runs fine, the wire stays quiet.
- **LIN requires an external LIN transceiver** on every physical bus. Some evaluation boards (e.g. XS32K396-BGA-DC) integrate a LIN transceiver on-board with a jumper for enable; others expose the raw LPUART/FLEXIO pins and require an external transceiver breakout. Confirm from the board schematic.
- **`LinChannel_0` = FLEXIO, `LinChannel_1` = LPUART** in every shipped multi-channel example. This is not a hard rule -- it is a convention driven by the shipped configuration. The channel-to-peripheral mapping lives in the config tool.
- **Both channels run at 19200 bps** -- the LIN standard baud rate for LIN 1.3 / 2.1 / 2.2A. Non-standard rates are technically supported by the driver but violate the LIN spec and cannot interoperate with LIN-compliant slaves.
- **Board-specific LIN header pins** (from the shipped READMEs):

  | Board | Master (LinChannel_0) LIN pin | Slave (LinChannel_1) LIN pin |
  |---|---|---|
  | S32K312EVB-Q172, FRDM-A-S32K312 | J23.8 | J23.7 |
  | S32K3X4EVB-Q172, S32K3X4EVB-T172 | J23.8 | J23.7 |
  | FRDM-A-S32K344 | J14.2 | J14.3 |
  | S32K3X4EVB-Q257 | J675.8 | J675.7 |
  | S32K388EVB-Q289, S32K389EVB-Q437 | J28.8 | J28.7 |
  | XS32K396-BGA-DC (single-node) | J52.8 (LIN1); GND on J52.1/J52.2; VBAT on J52.5/J52.6 | -- |

- **FreeMASTER `.pmpx` companion project** ships with the S32CT example and plots `Master_Send` / `Master_Request` / `Slave_Send` / DIO LED status.

- **DioLed convention across LIN examples:**
  - `DioLed0` -- unexpected/ignored header on the Slave
  - `DioLed1` -- Slave accepted a header (LinIf response OK)
  - `DioLed2` -- Master TX success (Lin_GetStatus == LIN_TX_OK)

- **Cross-family portability:** the split (`Lin` block + `LinIf` block, no `Hardware_Interrupt_Handler`) is expected to hold on other MBDT families. The board-init component name (`Lin_43_LPUART_FLEXIO`) may differ -- e.g. a family without FLEXIO might use `Lin_43_LPUART` alone. Discover live via `get_mbdt_board_init({family})`.

---

## 13. Guardrails (LIN-specific)

- **Never stub LIN functions.** Do not hand-write `Lin_43_LPUART_FLEXIO_Init`, `Lin_SendFrame`, `LinIf_HeaderIndication`, or any RTD/LinIf function into generated C. The board-init entry (Sec.5.5) is what triggers MBDT to generate the driver code. Both `Lin_43_LPUART_FLEXIO.h` and `LinIf.h` must be in the entry's header list.

- **Never invent channel names.** `LinChannel_0`, `LinChannel_1` are exact strings from the config tool. Read them from the block's live `Enum`.

- **Never route a LIN callback through `Hardware_Interrupt_Handler`.** LIN does not use it. Every LIN callback (`LinIf_HeaderIndication` and its 5 siblings) goes through a standalone `s32k3_linif` block. If a user says "add an ISR handler for LIN header indication", the correct action is to add a `LinIf` block, not a `Hardware_Interrupt_Handler`.

- **Never omit the `Lin_WakeUpInternal` + `Lin_CheckWakeUp` pair in Initialize Function.** Without them, the channel stays in Sleep and `Lin_SendFrame` returns E_NOT_OK forever. One pair per LinChannel used.

- **On `LinIf_HeaderIndication`, always drive ALL 5 response inports.** Leaving `Cs`, `Drc`, `Dl`, `Data`, or `Status` unconnected produces undefined behavior in the driver. `Status = E_NOT_OK` alone is sufficient to ignore a header (the other four are then don't-cares), but they still must be wired to *something* (Ground, Enumerated Constant, or Data Store Read).

- **On `Lin_SendFrame`, wire `SduPtr` (inport 5) to Ground when `Drc = LIN_FRAMERESPONSE_RX`.** There is no data to send; the driver ignores the pointer in RX mode but Simulink still requires a driver on every inport.

- **Never set `text` on any `Lin` or `LinIf` block** -- system-managed.

- **Verify Cs, Drc, and Dl match on both ends.** A LIN transaction with mismatched checksum type (Classic vs Enhanced), mismatched direction, or mismatched data length produces bus errors that cascade -- Lin_GetStatus reports `LIN_TX_ERROR` or `LIN_RX_ERROR`, and the LinIf error indication (if wired) fires. Both the master's `Lin_SendFrame` inputs AND the config-tool LinFrame table entry for that PID must agree.

- **`LinIf_HeaderIndication` (specifically) is bidirectional -- do not treat it as one-way.** Unlike `Hardware_Interrupt_Handler` (which only outputs), the `LinIf_HeaderIndication` block has 5 inputs that the user MUST drive from the function-call subsystem. Failing to wire the inputs back leaves the driver waiting for a response that never comes, and the LIN transaction times out on the wire. The other 5 `LinIf_*` callbacks (`RxIndication`, `TxConfirmation`, `WakeupConfirmation`, `LinErrorIndication`, `CheckWakeup`) are output-only or nearly so -- see Sec.3.4 for verified port shapes.

- **When adding a second LIN channel to a model, remember to add its `Lin_WakeUpInternal` + `Lin_CheckWakeUp` in Initialize Function.** The Slave channel is passive at wire level but still needs its driver-side state machine brought up. Verified across all dual-channel shipped examples.
