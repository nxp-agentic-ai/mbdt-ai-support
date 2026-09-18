# CAN -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the CAN peripheral
on any NXP MBDT-targeted Simulink model. This document describes the
behavior of the `Can` block (`MaskType = {family}_can`),
the ISR-handler wiring, the standard initialization pattern, and the
external-configuration-tool dependencies. The behavioral model is
expected to hold cross-family (S32K3);
exact enum labels, helper-class names, and board-init symbols may differ
per family. The CAN examples shipped with the family MBDT toolbox are a
good starting point for confirming block behavior, wiring, and
config-tool setup.

> **Tip -- start from a shipped example.** Before building from scratch,
> open a CAN example shipped with the family MBDT toolbox: its S32
> Configuration Tools project (pins, clocks, peripherals, interrupt
> controller) and its Simulink model (board init, initialize function,
> runtime blocks, ISR-handler wiring) already form a coherent end-to-end
> setup that mirrors every section below. Examples are listed and opened
> via the [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md)
> skill; never carry example names from memory -- discover them at runtime.

---

## 1. Peripheral Overview

The CAN peripheral in MBDT is a **composite** of five distinct model artefacts.
Adding "CAN to a model" means placing all five, not one block:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins, Clocks, Peripherals, Interrupt Controller) | External to the model | External config tool |
| 2 | Board-init entry `Can_43_FLEXCAN_Init(&Can_43_FLEXCAN_Config)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | `Initialize Function` subsystem with the **6-block init sextet** | Simulink model | This skill |
| 4 | Transceiver bring-up (Pattern 1 GPIO or Pattern 2 C-helper -- see Sec.7) | Simulink model, inside Initialize Function | This skill |
| 5 | Runtime `Can_Write` block(s) + one or more `Hardware_Interrupt_Handler` blocks | Simulink model | This skill |

Omitting any single one produces a silent failure mode:

- Missing (1) -> block enums resolve to `"No {thing} configured"` sentinels.
- Missing (2) -> build links but the driver's config structures are never installed; every `Can_*` call is a no-op.
- Missing (3) -> the controller stays in `CAN_CS_UNINIT`, no traffic.
- Missing (4) -> the FlexCAN controller runs fine on-chip but the CAN wire stays silent (the transceiver is asleep in Standby).
- Missing (5) -> nothing to transmit; nothing to react to on reception.

---

## 2. The `Can` Block -- Complete Behavioral Model

**One `Can` block = one Real-Time Driver function call.**
Every `Can` block has `MaskType = {family}_can` (e.g. `s32k3_can`), is an
`S-Function`, and represents exactly one `Can_*` API invocation. A CAN
peripheral in a Simulink model is therefore composed of *several* `Can`
blocks with different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

The `api_func` parameter is the master control. **Always read its live
`Enum` from the block in front of you** via
`get_param({canBlk}, 'DialogParameters')` -- the set of available
`Can_*` functions is owned by the installed toolbox version and must
never be carried from memory. The enum is identical for classic CAN and
CAN FD on a given installation.

**Behavioral facts an AI agent must know (independent of the exact
function list, which is discovered live):**

- **Reception is not a `Can` function.** There is no `Can_Read`-style
  entry; received frames are delivered through the ISR-handler block
  (see Sec.5), never through a `Can` block. If you expect a "read"
  function in the live enum and it is absent, this is why.
- **Polling API.** Functions of the shape `Can_MainFunction_Read` /
  `Can_MainFunction_Write` (if present in the live enum) are the polling
  API -- placed in the model's base-rate execution path so the driver
  polls the mailboxes. A polling-mode `Can_MainFunction_Read` still fires
  `CanIf_RxIndication`, so a polling receiver still needs an ISR-handler
  block for `CanIf_RxIndication` (see Sec.6.3).
- **Optional periodic hooks.** Any `Can_MainFunction_{BusOff,Mode,Wakeup}`
  entries present in the live enum are optional periodic hooks; wire them
  into the base rate only if the corresponding driver state machines are
  enabled in the config tool.
- Selecting `api_func` **reshapes the S-Function's input/output ports and
  shows/hides every other parameter via the block's mask callback**. Set
  `api_func` first, before any other parameter on the block.

Whenever this reference names a specific `Can_*` function below (e.g.
`Can_Write`, `Can_SetControllerMode`), treat it as an **illustrative**
label (for example, from an S32K3 example) -- validate it against the
block's live `api_func.Enum` before selecting it, and refuse near-misses.

### 2.2 Parameter surface (constant across all `api_func` values)

The parameter *names* are the same on every `Can` block; only visibility and
semantics change with `api_func`.

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `controller` | enum | Controller | `CanController_N` symbol from config tool | Set/Get mode, En/Disable interrupts, GetErrorState |
| `hw_obj` | enum | Hardware Object | `CanHardwareObject_Can{N}_Tx_{Interrupt\|Polling}` symbol | `Can_Write` only |
| `mode` | enum | Mode | `CAN_CS_UNINIT \| CAN_CS_STARTED \| CAN_CS_STOPPED \| CAN_CS_SLEEP` | `Can_SetControllerMode` only |
| `canfd_msg` | boolean | CAN FD Frame | Emit as CAN FD frame (BRS + up to 64-byte payload) | `Can_Write` only |
| `ext_id_msg` | boolean | Extended ID | Use 29-bit extended CAN ID | `Can_Write` only |
| `empty_msg` | boolean | Empty Message | Force DLC=0 regardless of Data input | `Can_Write` only |
| `text` | string | *(empty)* | System-managed cache -- **never set** | Read-only |

### 2.3 Sentinel rules (critical -- do not treat all sentinels as errors)

A sentinel on an enum reads `"No {thing} configured"` or
`"No {thing} available"`. Whether it indicates an error depends on which
parameter is expected to be used for the currently selected `api_func`:

| `api_func` | `controller` sentinel = error? | `hw_obj` sentinel = error? |
|---|---|---|
| `Can_Write` | **NO** -- expected; not used by `Can_Write` | YES -- must resolve to a real HOH |
| `Can_SetControllerMode` | YES | NO -- expected |
| `Can_GetControllerMode` | YES | NO -- expected |
| `Can_GetControllerErrorState` | YES | NO -- expected |
| `Can_EnableControllerInterrupts` | YES | NO -- expected |
| `Can_DisableControllerInterrupts` | YES | NO -- expected |
| `Can_GetVersionInfo` | NO -- takes no resource | NO |
| `Can_MainFunction_*` | NO -- driver-wide | NO |

If a sentinel appears in an "error" cell above, the corresponding
resource has not been declared in the S32CT/EB tresos project; open the
config tool via `opening-mbdt-config-tool` and add it -- do not attempt
to select the sentinel.

### 2.4 Selection ordering when configuring a `Can` block

When setting multiple parameters at once:

1. `api_func` -- first, always. Reshapes ports and toggles visibility on all others.
2. Resource enums -- `controller`, `hw_obj` next.
3. Booleans -- `canfd_msg`, `ext_id_msg`, `empty_msg` last.

One `set_param` per parameter, in that order.

---

## 3. Required Block Catalog

Blocks referenced by any CAN configuration (all live under the family's
MBDT library; discover exact paths via `detect_mbdt_blocks({family})`):

| Block name | `MaskType` | Role |
|---|---|---|
| `Can` | `{family}_can` | Wraps one `Can_*` function; multiple instances per model |
| `Dio` | `{family}_dio` | Drives EN / STB / ERRN transceiver GPIOs (and status LEDs) |
| `MATLAB Function` (Simulink built-in) | -- | Wraps the `TJA1153Transceiver.init` helper class (Pattern 2 transceiver init only) |

Never create a "custom CAN block" or a stub function to work around a
missing feature -- see Guardrails.

---

## 4. Configuration Workflow (7 steps)

Perform in order. Steps 1-4 in the external configuration tool; steps
5-7 in the Simulink model.

### 4.1 Pins (S32 Configuration Tools -> Pins, or EB tresos -> Port)

Route the pins for the CAN interface(s) you plan to use:

- `can{N}_rx` -- the CAN RX pin (e.g. `PTA6` for CAN0 on S32K344-Q257)
- `can{N}_tx` -- the CAN TX pin (e.g. `PTA7` for CAN0 on S32K344-Q257)
- SIUL2 GPIO pins for the transceiver -- **EN**, **STB**, and (for TJA1153/TJA1463) **ERRN**

Pin numbers are **board-specific** -- never invent them. Discover the
active pins in the model's `.mex` via `nxp_s32ct_inspect(kind='pins')`.

Example (S32K344-Q257, CAN0 + CAN4 both routed):

```
CAN0    can0_rx  = PTA6  (M15)
CAN0    can0_tx  = PTA7  (M16)
CAN4    can4_rx  = PTE14 (L3)
CAN4    can4_tx  = PTE3  (N1)
SIUL2   EN pin   = PTC20 / PTD15 ...  (per controller, board-dependent)
SIUL2   STB pin  = PTC21 / PTD13 ...
SIUL2   ERRN pin = PTC23 / PTE8  ...
```

### 4.2 Clocks (S32 Configuration Tools -> Clocks, or EB tresos -> Mcu)

Verify the clock domain feeding the selected FlexCAN instance is
configured (on S32K3: `AIPS_PLAT_CLK` / `AIPS_SLOW_CLK` are set up by
the Mcu driver). No CAN-specific parameter is exposed on the Simulink
`Can` block for clocks -- the value is compiled into the driver's
`Can_43_FLEXCAN_Config` structure.

### 4.3 Peripherals -- Can_43_FLEXCAN (S32 Configuration Tools -> Peripherals)

Configure the FlexCAN instance:

- `CanController_{N}` -- enable and select bit-timing via
  `CanControllerBaudrateConfig_{M}`.
- `CanHardwareObject_Can{N}_Tx_Interrupt` (or `_Tx_Polling`) -- the TX HOH.
- `CanHardwareObject_Can{N}_Rx_*` -- the RX HOH; typically wired to
  `CanIf_RxIndication`.
- `CanIf` -- declare the notification callbacks
  (`CanIf_RxIndication`, `CanIf_TxConfirmation`) that will appear in the
  ISR-handler block's `irqHandlers` enum.
- If FIFO reception is used: the corresponding `MBDT_FlexCAN{N}_Fifo*`
  notifications must also be declared.

The **exact string names** you assign here (`CanController_0`,
`CanHardwareObject_Can1_Tx_Interrupt`, ...) are what appear in the
Simulink block's `controller` and `hw_obj` enums. Case-sensitive, 1:1.

### 4.4 Peripherals -- Dio (S32 Configuration Tools -> Peripherals -> Dio)

Declare **named DIO channels** for the CAN transceiver control pins.
The names are mandatory and must follow the pattern
`CanController_{N}_{EN,STB,ERRN}` -- the model's DIO blocks (both
transceiver patterns) look them up by this exact name:

```
CanController_0_EN    -> the SIUL2 GPIO on the EN pin  (both patterns)
CanController_0_STB   -> the SIUL2 GPIO on the STB pin (both patterns)
CanController_0_ERRN  -> the SIUL2 GPIO on the ERRN pin (Pattern 2 / TJA1153/TJA1463 only)
```

Renaming these channels in the config tool breaks the transceiver init
silently -- the block's `channel` enum will no longer contain the
expected entry.

### 4.5 Platform -> Interrupt Controller (S32 Configuration Tools -> Platform)

For each CAN controller in use, enable the corresponding NVIC entry.
Naming pattern:

```
FlexCAN{instance}_{line}_IRQn      e.g. FlexCAN0_0_IRQn, FlexCAN4_0_IRQn
```

Resolve exact entry names against the live Interrupt Controller view;
the line number depends on which mailboxes / notifications are used.

### 4.6 Board Initialization (Simulink model)

Add the CAN driver init call to `mbdt_board_init.c` via the
[`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md)
skill. The canonical entry:

```
Component : Can_43_FLEXCAN
Priority  : 60           (after Mcu=10, Port=30, before user-model init)
Enabled   : true
Header    : #include "Can_43_FLEXCAN.h"
Code      : Can_43_FLEXCAN_Init(&Can_43_FLEXCAN_Config);
```

Priorities are chosen so that dependencies run first:
`Mcu_Init` sets up clocks and PLLs (10) -> `Port_Init` muxes CAN pins
and EN/STB/ERRN GPIOs (30) -> `Can_43_FLEXCAN_Init` installs the FlexCAN
config structure (60) -> user model's Initialize Function runs after
all board init entries.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves, so you pick and drive the right function;
the **IM** covers generated-file expectations, init order, and NVIC
prerequisites. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-
version segments (filenames are uppercased):


```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Can_43_FLEXCAN_TS_T40D*_M70I*_R0\doc\
    RTD_CAN_43_FLEXCAN_IM.pdf   RTD_CAN_43_FLEXCAN_UM.pdf
```

The transceiver EN / STB / ERRN control pins are driven through the
**Dio** driver (Sec.4.4, Sec.7); its named-channel behavior is
documented in the Dio PDFs:

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Dio_TS_T40D*_M70I*_R0\doc\
    RTD_DIO_IM.pdf   RTD_DIO_UM.pdf
```

### 4.7 Model Initialize Function + Transceiver + Runtime Blocks (Simulink model)


Assemble the runtime side. See Sec.5 (init sequence), Sec.6 (RX/TX topology),
and Sec.7 (transceiver bring-up) for the concrete block layout.

---

## 5. Canonical Initialize Function ("The Init Sextet")

A canonical CAN Initialize Function uses **6 mandatory steps + 1 optional step**
inside a Simulink `Initialize Function` subsystem, driven by an `Event Listener`
with `EventType = Initialize`. The sequence runs **once at model
startup**, immediately after `mbdt_board_init.c`.

```
+--- Event Listener (EventType = Initialize) --------------------------+
|                                                                       |
|   1. Can_GetControllerMode         controller = CanController_0       |
|              |                                                        |
|              v                                                        |
|      (store initial mode in a Data Store Memory -- diagnostic)         |
|                                                                       |
|   2. Can_SetControllerMode         controller = CanController_0       |
|                                    mode       = CAN_CS_STARTED        |
|              |                                                        |
|              v                                                        |
|   3. Can_GetControllerErrorState   controller = CanController_0       |
|              |                                                        |
|              v                                                        |
|   4. Can_DisableControllerInterrupts   controller = CanController_0   |
|              |                                                        |
|              v                                                        |
|   5. {TRANSCEIVER INITIALIZATION}       (see Sec.7 -- Pattern 1 or 2)     |
|              |                                                        |
|              v                                                        |
|   6. Can_EnableControllerInterrupts    controller = CanController_0   |
|              |                                                        |
|              v                                                        |
|   7. (optional) Can_GetVersionInfo    -> store version in Data Store   |
|                                                                       |
+-----------------------------------------------------------------------+
```

Rationale for each step:

1. **`Can_GetControllerMode`** -- capture the initial mode for later
   diagnostic readback (the driver comes up in `CAN_CS_STOPPED` after
   `Can_43_FLEXCAN_Init`).
2. **`Can_SetControllerMode(STARTED)`** -- bring the FlexCAN controller
   into the operational state. Without this the driver processes no
   frames.
3. **`Can_GetControllerErrorState`** -- verify the controller did not
   land in Error Passive / Bus Off; store the state for later readback.
4. **`Can_DisableControllerInterrupts`** -- **silence the FlexCAN
   controller during the transceiver bring-up**. This is not cosmetic
   -- the TJA1153 handshake in Pattern 2 sends a frame on the CAN wire
   and expects a specific response; a spurious controller interrupt at
   this moment can lock the transceiver in an error state.
5. **Transceiver bring-up** -- see Sec.7. Not optional on any physical board.
6. **`Can_EnableControllerInterrupts`** -- controller + transceiver
   both live; enable interrupts for the runtime path.
7. **`Can_GetVersionInfo`** -- writes module ID / vendor ID / version
   numbers to Data Store Memory for FreeMASTER / PIL introspection.
   Skip for size-constrained builds.

**Multi-controller variant:** add a `Can_SetControllerMode` (step 2)
for each `CanController_{N}` in use; the remaining steps can be
repeated per controller or omitted if the additional controllers do
not need runtime interrupt gating.

---

## 6. Runtime Data Flow

### 6.1 Transmission

Every TX path resolves to **exactly one `Can_Write` block per outgoing
message per controller**.

Parameter template for a `Can_Write` block:

```
api_func    = Can_Write
controller  = <"No controller configured">   <- expected sentinel; not used
hw_obj      = CanHardwareObject_Can{N}_Tx_{Interrupt|Polling}
mode        = {ignored for Can_Write}
canfd_msg   = 'off'  (classic CAN)  |  'on'  (CAN FD)
ext_id_msg  = 'off'  (11-bit ID)    |  'on'  (29-bit ID)
empty_msg   = 'off'  (payload from Data input)  |  'on'  (force DLC=0)
```

Input ports on `Can_Write` (visible after `api_func = Can_Write`):

- **Data** -- the payload as a `uint8` vector. Length must match the
  DLC configured on the selected HOH (up to 8 for classic CAN, up to
  64 for CAN FD).
- **CanId** -- the CAN identifier. 11-bit when `ext_id_msg='off'`,
  29-bit when `ext_id_msg='on'`.
- **Length** -- DLC (0..8 or 0..64).

Output: a status byte (0 = success, non-zero = error such as
`E_NOT_OK`). Typical usage routes the status into an `Error_Subsystem`
that lights a diagnostic LED via `Dio_WriteChannel`.

### 6.2 Reception -- the definitive architectural pattern

**There is no `Can_Read` block.** RX is delivered by the ISR-handler
block. The canonical topology:

```
+--------------------------------------+         +-------------------------------+
|  Hardware_Interrupt_Handler          |         |  Triggered Subsystem          |
|  -----------------------------       |         |  --------------------         |
|  irqGroup    = Can                   |         |  TriggerType = function-call  |
|  irqHandlers = CanIf_RxIndication    |         |  TriggerTime = on message ...   |
|                                      |         |                               |
|  Outputs (6 ports):                  |         |  Inputs:                      |
|    port 1  --- function-call --------+-------->|  Trigger                      |
|    port 2  --- (unused/terminated)   |         |                               |
|    port 3  --- Hw Obj ID ------------+-------->|  Hw Obj ID   (uint8)          |
|    port 4  --- (unused/terminated)   |         |                               |
|    port 5  --- Data -----------------+-------->|  Data        (uint8 vector)   |
|    port 6  --- (unused/terminated)   |         |                               |
+--------------------------------------+         +-------------------------------+
```

Inside the Triggered Subsystem: user logic consumes `Hw Obj ID` (to
demultiplex which mailbox delivered the frame) and `Data` (the
payload). Common patterns:

- **Echo:** wire `Data` -> a `Can_Write` block. Same `Data` bytes go
  back out on a `_Tx_Interrupt` or `_Tx_Polling` HOH.
- **LED indicator:** decode a bit or byte from `Data` and drive
  `Dio_WriteChannel`.
- **Stateflow decoder:** feed `Data` into a `Chart` for
  application-layer parsing.

### 6.3 Polling reception

Polling does not remove the ISR-handler block -- it moves the *trigger
source* into the model's periodic execution path.

```
Model base rate (periodic function-call generator)
        |
        v
+----------------------------+
| Can Polling subsystem      |
|                            |
|   Can_MainFunction_Read    | <- drains RX FIFOs; internally invokes
|           |                |   CanIf_RxIndication (which fires the
|           v                |   ISR-handler block's function-call)
|   Can_MainFunction_Write   | <- services TX confirmations
+----------------------------+

Independent of the above:
   Hardware_Interrupt_Handler(irqGroup=Can, irqHandlers=CanIf_RxIndication)
        |
        v
   Triggered Subsystem (as in Sec.6.2)
```

In polling mode, `Can_Write` uses the `_Tx_Polling` HOH variant. The
ISR-handler wiring is unchanged from Sec.6.2.

### 6.4 TX confirmation notification

To react to completed transmissions (LED toggle, next-frame trigger,
watchdog reset), add a **second** `Hardware_Interrupt_Handler` block:

```
Hardware_Interrupt_Handler2
    irqGroup    = Can
    irqHandlers = CanIf_TxConfirmation
        |
        +--- function-call --- (into a Triggered Subsystem that
                                 typically contains just a Dio_WriteChannel)
```

`CanIf_TxConfirmation` has no payload output ports -- only the trigger
is meaningful, since the ISR just reports "the last TX finished".

### 6.5 The `irqHandlers` enum under `irqGroup = Can`

The live enum entries visible on the ISR-handler block when
`irqGroup = Can` are populated from the config tool -- **read them live**
from `get_param({isrBlk}, 'DialogParameters')` after setting
`irqGroup = Can`; the exact set is owned by the installed toolbox version
and by what the `.mex` / EB tresos project declares (entries not declared
there will not appear). Do not carry the list from memory.

Illustrative entries (validate against the live enum before selecting):

```
CanIf_ControllerBusOff
CanIf_ControllerModeIndication
CanIf_RxIndication              <- RX payload delivery
CanIf_TxConfirmation            <- TX completion
MBDT_FlexCAN0_FifoOverflowNotif <- only if FIFO mode + overflow enabled on CAN0
MBDT_FlexCAN4_FifoOverflowNotif <- only if FIFO mode + overflow enabled on CAN4
MBDT_FlexCAN4_FifoWarnNotif     <- only if FIFO mode + warning enabled on CAN4
```

The `MBDT_FlexCAN{N}_Fifo*` set varies per model: instances not
declared as FIFO-mode in the config tool do not contribute entries.

---

## 7. Transceiver Initialization

The FlexCAN peripheral inside the MCU is only the controller half of
the physical CAN link. The wire-side transmit/receive is done by an
**external CAN transceiver chip** on the evaluation board (NXP TJA1043,
TJA1153, TJA1463, or equivalent). `Can_43_FLEXCAN_Init` sets up the
MCU controller but does **not** touch the transceiver. Every physical
board requires a **transceiver bring-up sequence inside the Initialize
Function**, placed as step 5 of the init sextet (Sec.5), between
`Can_DisableControllerInterrupts` and `Can_EnableControllerInterrupts`.

Observed examples fall into **five** patterns, chosen by the board's
transceiver chip and how it is wired (Pattern 1 & 2 documented below in
depth; Pattern 3 & 4 are simpler degenerate cases; 

### 7.1 Pattern 1 -- GPIO wake-up (TJA1043 family; MR-CANHUB style)

**Applicable transceivers:** TJA1043 (non-secure); boards where the
on-board transceiver is pre-configured by board hardware (for example
the MR-CANHUBK344, which carries pre-configured TJA1153s).

**Block composition:**

```
Constant (=1) --> Dio_WriteChannel   channel = CanController_{N}_EN
Constant (=1) --> Dio_WriteChannel   channel = CanController_{N}_STB
```

That's it. Two GPIO high-drives take the transceiver out of Standby
into Normal Operating Mode. No handshake, no external dependency.

**Multi-controller variant:** repeat one EN/STB pair per controller
(for example, a dual-controller board would use 4 `Dio_WriteChannel`
blocks, 2 per controller).

### 7.2 Pattern 2 -- Secure transceiver via C helper library (TJA1153, TJA1463)

**Applicable transceivers:** TJA1153, TJA1463 (secure CAN transceivers
with hardware-ID handshake).

The bring-up sequence is too complex to model in native Simulink blocks
(timed GPIO edges + a CAN-wire handshake with a specific hardware ID).
It is delegated to a **prebuilt C library shipped with the toolbox**,
wrapped in a `MATLAB Function` block via a `coder.ExternalDependency`
helper class.

**Block composition (example):**

```
+----------------------------------------------------------------+
|  TJA1153 subsystem                                             |
|                                                                |
|  Constant  = 0x0055  -+                                        |
|  Constant  = 0x0054  -+--> (transceiver identity constants;    |
|  Constant  = 0x0057  -+     hard-coded TJA1153 HW IDs)         |
|                                                                |
|  Variant Subsystem  --> Constant = canExtHwId  (board-specific)|
|    +-- S32K344_Q172              -> canExtHwId = 3              |
|    +-- S32K344_Q257 / S32K388    -> canExtHwId = 6              |
|                                                                |
|  Constant = canEnDioChannel   (looks up CanController_0_EN)    |
|  Constant = canStbDioChannel  (looks up CanController_0_STB)   |
|  Constant = canErrnDioChannel (looks up CanController_0_ERRN)  |
|                                                                |
|                    |                                           |
|                    v                                           |
|         +---------------------------+                          |
|         |  MATLAB Function block    |                          |
|         |  ---------------------    |                          |
|         |  function status = ...    |                          |
|         |    TJA1153_Init(...)      |                          |
|         |      status = ...         |                          |
|         |        TJA1153Transceiver |                          |
|         |          .init(...)       |                          |
|         +---------------------------+                          |
|                    |                                           |
|                    v status (int32)                            |
|         +---------------------------+                          |
|         |  If block                 |                          |
|         |  Error_Subsystem (u1 != 0) |--> Dio_WriteChannel      |
|         |                           |      channel = DioLed0   |
|         +---------------------------+                          |
+----------------------------------------------------------------+
```

**Helper class (S32K3 example location):**

```
File   : {mbdtbx_s32k3}/+mbd_s32k3/+common/+nxp/+can/TJA1153Transceiver.m
Class  : mbd_s32k3.common.nxp.can.TJA1153Transceiver
        (inherits coder.ExternalDependency)
Method : status = init(canExtHwId, canEnDioChannel, canStbDioChannel, canErrnDioChannel)
```

The class's `init` method returns `int32(0)` under `coder.target('MATLAB')`
(simulation) and emits `coder.ceval('TJA1153_Init', ...)` under
`coder.target('Rtw')` (code generation). Its `updateBuildInfo` hook
copies **`mbdt_tja.a`** (prebuilt static library) and
**`mbdt_tja1153.h`** into the model's `{config}_Config/src` folder and
registers them with the build.

**Non-obvious facts:**

- The three identity constants (`0x0055`, `0x0054`, `0x0057`) are
  **not user-configurable** -- they are the TJA1153 hardware IDs the
  helper expects. Do not modify.
- `canExtHwId` is **board-specific** and identifies the Can HOH used
  by the polling side of the driver to send the transceiver identity
  handshake message on the wire. The HOH must be configured as
  `_Tx_Polling` (not `_Tx_Interrupt`) in the S32CT/EB tresos Peripherals
  -> Can section. It varies per board because MBDT-generated HOH
  numbering differs per MCU package.
- The two-level variant structure -- outer variant selects transceiver
  chip (TJA1043 vs TJA1153); inner variant selects board sub-package
  (Q172 vs Q257 vs Q289) -- is chosen automatically from the model's
  Hardware Part on the inner level, and by an explicit push-button
  in the model top level on the outer level.
- **There is no `TJA1043Transceiver.m` helper.** TJA1043 does not
  need one because Pattern 1 is sufficient. If an agent asked to
  "add a TJA1043 helper class" is following a hallucinated pattern.

### 7.3 Pattern 3 -- Jumper-selected on-board transceiver (XS32K396 family)

**Applicable boards:** for example `XS32K396-BGA-DC` and `XS32K396-BGA-DC1`.

On these boards, the CAN transceiver's operating mode is selected by a **hardware jumper** (`J35` in position `2-3` = Normal mode) rather than by MCU GPIOs. The Simulink models for these boards therefore include **no transceiver-init subsystem at all** -- no `Dio_WriteChannel`, no `MATLAB Function` helper, nothing. The user is responsible for verifying the jumper position before running the demo; the model has no runtime control over it.

For an AI agent this means: **if the target is an XS32K396 board, do not add a transceiver-init block. If the CAN link does not work, the fix is a physical jumper, not a model edit.**

### 7.4 Pattern 4 -- External discrete transceiver (headerless boards)

**Applicable boards:** boards that ship without an on-board CAN transceiver -- for example `XS32K3X2CVB-Q172`.

The user must physically connect an **external CAN transceiver breakout** between the MCU's CAN RX/TX pins (routed to a header -- `J80[1] = CAN Rx`, `J80[2] = CAN Tx` on the observed board) and the CAN analyzer / bus. The transceiver is a separate breakout board with its own power supply; MBDT has no visibility of it and does not attempt to configure it.

The Simulink models for these boards accordingly have **no transceiver-init subsystem**. The Initialize Function contains only the init sextet minus the transceiver step (`Can_GetControllerMode` -> `Can_SetControllerMode` -> `Can_GetControllerErrorState` -> `Can_DisableControllerInterrupts` -> `Can_EnableControllerInterrupts` -> `Can_GetVersionInfo`).

For an AI agent: **do not synthesize any DIO / helper block for the transceiver on these boards.** If the CAN link does not work, the first diagnostic is "is an external transceiver actually wired to the RX/TX header?" -- not a model edit.


### 7.6 Which pattern for which board


| Board (example) | Transceiver arrangement | Pattern |
|---|---|---|
| XS32K3X2CVB-Q172 | External discrete transceiver on a header (`J80`) | **Pattern 4** (no init) |
| S32K3X4EVB-Q257 | On-board TJA1153, secure handshake required | Pattern 2 |
| Multi-board (selectable transceiver) | User-selectable at model level: TJA1043 (P1) or TJA1153 (P2) via top-level button | Both P1 and P2 |
| MR-CANHUBK344 | On-board TJA1153, board pre-configures secure state | Pattern 1, inline |
| XS32K396-BGA-DC | On-board transceiver, **mode selected by jumper `J35`** | **Pattern 3** (no init) |

### 7.7 Config-tool requirements for the transceiver

Beyond the FlexCAN requirements of Sec.4.3, the transceiver imposes
extra requirements on the config tool:

| Config-tool object | Pattern 1 | Pattern 2 | Consumed by |
|---|---|---|---|
| S32CT Pins -> SIUL2 GPIO for EN pin | required | required | `Dio_WriteChannel.channel` |
| S32CT Pins -> SIUL2 GPIO for STB pin | required | required | `Dio_WriteChannel.channel` |
| S32CT Pins -> SIUL2 GPIO for ERRN pin | not needed | required | `TJA1153_Init` helper |
| S32CT Peripherals -> Dio -> channel `CanController_{N}_EN` | required | required | Both patterns |
| S32CT Peripherals -> Dio -> channel `CanController_{N}_STB` | required | required | Both patterns |
| S32CT Peripherals -> Dio -> channel `CanController_{N}_ERRN` | not needed | required | Pattern 2 |
| S32CT Peripherals -> Can -> HOH reserved for TJA1153 handshake | not needed | required | Pattern 2 (feeds `canExtHwId`) |

Rename any of these DIO channels in the config tool and both
patterns break silently (the block's `channel` enum will no longer
contain the expected entry).

---

## 8. Configuration Correlation Matrix

Single-lookup table for AI agents: given a CAN behavior, which
artefact owns it?

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Controller instance name (`CanController_0`) | S32CT Peripherals -> Can | `controller.Enum` on `Can` block |
| HOH name (`CanHardwareObject_Can{N}_Tx_Interrupt`) | S32CT Peripherals -> Can | `hw_obj.Enum` on `Can` block |
| Baud rate | S32CT Peripherals -> Can -> `CanControllerBaudrateConfig_{M}` | Compiled-in; not exposed |
| CAN pin muxing (`can{N}_rx`, `can{N}_tx`) | S32CT Pins | Compiled-in; not exposed |
| Transceiver EN/STB/ERRN pin muxing | S32CT Pins -> SIUL2 GPIO | Consumed by `Dio_WriteChannel.channel` |
| Clock source & frequency | S32CT Clocks + Mcu init | Compiled-in; not exposed |
| Interrupt enable at NVIC | S32CT Platform -> Interrupt Controller | Manifests as populated `irqHandlers.Enum` |
| Notification callbacks (`CanIf_RxIndication`, `CanIf_TxConfirmation`) | S32CT Peripherals -> Can + CanIf | `irqHandlers.Enum` on ISR-handler block |
| FIFO overflow/warning notifications | S32CT Peripherals -> Can (FIFO settings) | `MBDT_FlexCAN{N}_Fifo*` in `irqHandlers.Enum` |
| DIO channel names (`CanController_{N}_EN` etc.) | S32CT Peripherals -> Dio | `channel.Enum` on `Dio` block |
| Extended-ID enable (per message) | Simulink model | `ext_id_msg` on `Can_Write` |
| CAN FD framing (per message) | Simulink model | `canfd_msg` on `Can_Write` |
| Force DLC=0 (per message) | Simulink model | `empty_msg` on `Can_Write` |
| Runtime mode transitions | Simulink model | `Can_SetControllerMode` + `mode` |
| Board-init entry `Can_43_FLEXCAN_Init(&Can_43_FLEXCAN_Config)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

---

## 8.1 Runtime Observability Conventions

A consistent set of `Data Store Memory` variables is commonly used for
CAN telemetry; an AI agent should preserve them when replicating an
existing model, and can propose them to a user who asks for CAN
telemetry:

| Variable | Written by | Meaning |
|---|---|---|
| `CAN_Rx_Msg_Count` | Triggered subsystem under `CanIf_RxIndication` ISR | Incremented on every received message; monotonic frame counter |
| `CAN_Tx_Msg_Count` | Triggered subsystem under `CanIf_TxConfirmation` ISR | Incremented on every completed transmission |
| `CAN_Error_Count` | Downstream of `Can_Write` status output | Incremented when `Can_Write` returns non-zero (typical cause: HTH busy -- previous transmission not yet acknowledged) |
| `versionInfo` (or similar) | Output of `Can_GetVersionInfo` in the Initialize Function | Module ID / vendor ID / vendor-specific version numbers |
| `ControllerMode` | Output of `Can_GetControllerMode` in the Initialize Function | Post-init controller mode readback (`CAN_CS_STARTED` on success) |
| `ErrorState` | Output of `Can_GetControllerErrorState` in the Initialize Function | Post-init error state readback |

**FreeMASTER integration:** a companion `.pmpx` FreeMASTER project
(same base name as the `.mdl`) can plot the counters above. Adding a
`FreeMASTER Config` block to a freshly-authored CAN model exposes these
variables to FreeMASTER without any additional wiring -- the block-name
based symbol resolution is what a companion `.pmpx` relies on. See
[`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md) for how
to open a shipped `.pmpx` alongside its `.mdl`.

## 8.2 Expected CAN Analyzer Settings

The CAN analyzer (Vector CANalyzer, PCAN-View, etc.) must be set to
match the bus configured in the config tool. A common configuration:

| Setting | Classic CAN examples | CAN FD examples |
|---|---|---|
| Baud rate | **500 kbps** | 500 kbps arbitration, 2 Mbps data (from FD HOH) |
| Frame format | **Extended (29-bit) enabled** | Extended enabled + **CAN FD enabled** |
| Bit-rate switching (BRS) | N/A | Enabled |

The 500 kbps figure is a common default in the Peripherals -> Can
configuration. If the user changes the baud rate in the config tool,
they must update the analyzer to match -- the block-side `Can_Write` has
no way to signal a mismatch. **A silent bus with no error frames on the
MCU side but the analyzer showing a bus-error state almost always means
baud-rate mismatch, not a wiring or transceiver-init issue.**

## 9. Common Usage Patterns (block-topology cookbook)

### 9.1 Time-driven transmit (periodic frame)

```
(periodic function-call generator)
        |
        v
Triggered Subsystem
   +-- Constant / Stateflow chart producing Data (uint8 vector)
   +-- Constant producing CanId (uint32)
   +-- Constant producing Length (uint8)
   +-- Can_Write   api_func=Can_Write, hw_obj={TX HOH}, canfd_msg=off/on

Initialize Function: init sextet (Sec.5) + transceiver init (Sec.7)
Runtime: no ISR handler required (unless you also want TX confirmation)
```

### 9.2 Event-driven receive-and-process

```
Hardware_Interrupt_Handler
   irqGroup=Can, irqHandlers=CanIf_RxIndication
        |
        | trigger + Hw Obj ID + Data
        v
Triggered Subsystem
   +-- (user application logic -- Stateflow chart, matrix indexing, ...)
   +-- Dio_WriteChannel / Data Store Write / etc.

Initialize Function: init sextet (Sec.5) + transceiver init (Sec.7)
```

### 9.3 Echo (receive then re-transmit)

```
Hardware_Interrupt_Handler (RX)
   irqGroup=Can, irqHandlers=CanIf_RxIndication
        |
        v
Triggered Subsystem "RX_Complete_Event"
   +-- (Hw Obj ID, Data flow through)
   +-- Can_Write   api_func=Can_Write, hw_obj={TX HOH}
   +-- Dio_WriteChannel (optional LED heartbeat)

Hardware_Interrupt_Handler (TX conf -- optional)
   irqGroup=Can, irqHandlers=CanIf_TxConfirmation
        |
        v
Triggered Subsystem
   +-- Dio_WriteChannel (optional TX LED)
```

### 9.4 Polling echo

```
Can Polling subsystem (runs at model base rate)
   +-- Can_MainFunction_Read
   +-- Can_MainFunction_Write

Hardware_Interrupt_Handler (RX indication still needed -- fired from Can_MainFunction_Read)
   irqGroup=Can, irqHandlers=CanIf_RxIndication
        |
        v
Triggered Subsystem
   +-- Can_Write   hw_obj = CanHardwareObject_Can{N}_Tx_Polling   <- Polling variant HOH
```

### 9.5 CAN FD

Same topology as classic CAN. The **only** block-level difference is
`canfd_msg = 'on'` on `Can_Write`. `hw_obj` uses the same
`CanHardwareObject_Can{N}_Tx_{Interrupt|Polling}` label -- there is no
separate FD hw_obj namespace. The FD framing (baud-rate switching,
extended payload) is compiled into the HOH definition in the config
tool.

### 9.6 Multi-controller (dual FlexCAN)

```
Initialize Function
   +-- Can_SetControllerMode  controller=CanController_0, mode=CAN_CS_STARTED
   +-- Can_SetControllerMode  controller=CanController_1, mode=CAN_CS_STARTED
   +-- (transceiver init -- one EN/STB (+/- ERRN) set per controller)
   +-- (Enable interrupts -- either per controller or once globally)

Runtime
   +-- Can_Write     hw_obj = CanHardwareObject_Can0_Tx_Interrupt
   +-- Can_Write     hw_obj = CanHardwareObject_Can1_Tx_Interrupt
```

---

## 10. Troubleshooting -- mapping symptoms to root causes

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `controller.Enum` on any `Can` block reads `"No controller configured"`, and you're on `Can_SetControllerMode` / mode/error-state functions | S32CT/EB tresos has no `CanController_{N}` declared | Open config tool via `opening-mbdt-config-tool`; add controller under Peripherals -> Can |
| `controller.Enum` reads sentinel on a `Can_Write` block | **This is expected** -- `Can_Write` routes via `hw_obj`, not `controller` | Ignore; verify `hw_obj` instead |
| `hw_obj.Enum` reads `"No TRANSMIT hardware object configured"` on `Can_Write` | No `CanHardwareObject_*_Tx_*` declared in config tool | Add TX HOH in Peripherals -> Can |
| `irqHandlers.Enum` under `irqGroup=Can` does not list `CanIf_RxIndication` | Notification not declared in CanIf section of config tool | Add the notification in the config tool |
| `irqHandlers.Enum` does not list `MBDT_FlexCAN{N}_Fifo*` | FIFO mode is not enabled for that controller | Enable FIFO reception in Peripherals -> Can -> CanController_{N} |
| Build links successfully but the CAN wire is silent (no frames observed) | Missing board-init entry OR missing transceiver init | Verify `Can_43_FLEXCAN_Init` in board init (Sec.4.6); verify transceiver bring-up runs (Sec.7) |
| Build fails: unresolved `Can_Init`, `Can_Write`, `CanIf_*` | Board-init entry missing -- driver config structures never installed | Add via `editing-mbdt-board-init` (see Sec.4.6). **Never** stub the function |
| Build fails: unresolved `TJA1153_Init` | Pattern 2 helper's build info hook did not run, or `mbdt_tja.a` / `mbdt_tja1153.h` missing | Verify the `TJA1153_Init` MATLAB Function subsystem is present and correctly wired; do not hand-edit the C |
| RX Triggered Subsystem sees payload data but wrong Hw Obj ID | Multiple RX HOHs share the same `CanIf_RxIndication` -- the subsystem must demultiplex by `Hw Obj ID` | Add a demux (switch/if) inside the subsystem, keyed on port `Hw Obj ID` |
| TJA1153 transceiver init returns non-zero status (DioLed0 lights up) | Wrong `canExtHwId` for the board OR wrong DIO channels wired OR CAN pins not muxed | Verify the Hardware Part matches the board; verify `CanController_{N}_{EN,STB,ERRN}` channels exist in Dio config; verify Pins section muxes both CAN pins and the three transceiver GPIOs |
| Model runs after reset but stops after ~256 error frames | Bus off -- transceiver got a corrupted first frame, likely because interrupts were re-enabled before transceiver came out of Standby | Ensure `Can_EnableControllerInterrupts` is **after** the transceiver-init subsystem, not before |
| CAN FD frame goes out as classic CAN | HOH is not configured as CAN FD in the config tool, or `canfd_msg = 'off'` on the block | Enable CAN FD on the HOH in Peripherals -> Can; set `canfd_msg = 'on'` on `Can_Write` |
| `Can_Write` returns non-zero (E_NOT_OK) intermittently | TX mailbox busy (previous transmission not yet confirmed) | Add a `CanIf_TxConfirmation` ISR handler and gate `Can_Write` on the confirmation, or slow the trigger rate |

---

## 11. Board-Specific Considerations

- **Pin assignments vary per board.** Never hard-code `PTA6`/`PTA7`
  or the transceiver EN/STB/ERRN pins from memory. Discover them from
  the model's `.mex` (via `nxp_s32ct_inspect(kind='pins')`) or the
  EB tresos Port module.
- **Transceiver chip varies per board.** Q172 packages tend to ship
  with TJA1043; Q257/Q289 packages ship with TJA1153; MR-CANHUBK344
  ships with pre-configured TJA1153s that behave like TJA1043 at the
  model level (Pattern 1). Check the board schematic before choosing
  a pattern.
- **`canExtHwId` varies per board** (Pattern 2 only). Observed on
  S32K344: `3` for Q172, `6` for Q257 / S32K388-Q289. Not
  interchangeable.
- **NVIC entry names vary per instance.** `FlexCAN0_0_IRQn` for
  FlexCAN 0 line 0, `FlexCAN4_0_IRQn` for FlexCAN 4 line 0, and so on.
- **Cross-family portability.** The behavioral model above (the `api_func`
  function set discovered live, ISR-handler routing, init sextet) is expected to hold on
  S32K3, but the exact board-init component
  name may differ (`Can_43_FLEXCAN` is FlexCAN-specific; families with
  a different CAN IP may use a different `{driver}_Init` symbol).
  Discover live via `get_mbdt_board_init({family})`.

---

## 12. Guardrails (CAN-specific -- supersedes nothing in parent SKILL.md)


- **Never add CAN stubs by hand.** Do not hand-write `Can_Init`,
  `Can_SetControllerMode`, `Can_Write`, `CanIf_*` callbacks, `TJA1153_Init`,
  or any other Real-Time Driver / transceiver function into the
  generated C, the model, or a hand-written .c file. Adding the CAN
  init entry to the board initialization (Sec.4.6) is what triggers MBDT
  to generate the driver code automatically. If the build reports a
  missing CAN symbol, the fix is **always** in the config tool or the
  board-init entry -- never in the C.

- **Never invent HOH / controller / channel names.** `CanController_0`,
  `CanHardwareObject_Can0_Tx_Interrupt`, `CanController_0_EN`, etc. are
  exact strings owned by the S32CT/EB tresos project. Read them from
  the block's live `Enum`; if the string is not present, open the
  config tool via `opening-mbdt-config-tool` and add it there.

- **Never fabricate the transceiver bring-up.** Either use two/three
  `Dio_WriteChannel` blocks with the correctly named channels
  (Pattern 1) or use the shipped `TJA1153Transceiver` helper via a
  `MATLAB Function` block (Pattern 2). Do not hand-write GPIO edge
  sequences, do not hand-author `coder.ceval` calls, do not modify
  the `TJA1153Transceiver.m` class.

- **Never wire an ISR through a parameter on the `Can` block.** No
  `isr_*`, `callback_*`, or `notification_*` parameter exists on
  `{family}_can`. All CAN callbacks go through the
  `Hardware_Interrupt_Handler` block.

- **Never set `text` on any `Can` block.** It is system-managed
  (cached dump of the config tree); the block regenerates it on the
  next mask refresh.

- **`Can_EnableControllerInterrupts` must come after the transceiver
  init**, not before. Reversing them is a subtle bug that lets the
  first spurious CAN frame reach the FlexCAN controller before the
  transceiver is out of Standby, which can lock the transceiver in
  an error state on TJA1153 / TJA1463.

- **When configuring `Can_Write`, expect the `controller` sentinel.**
  `Can_Write` selects its target via `hw_obj`, not `controller`. The
  `"No controller configured"` sentinel on `controller` is expected
  for `Can_Write` and is not an error to report to the user.
