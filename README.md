# NXP MBDT AI Support

[![matlab-mcp-server-badge](https://img.shields.io/badge/MATLAB_MCP_Server-v0.12.0+-orange?logo=mathworks)](https://github.com/matlab/matlab-mcp-core-server) [![matlab-badge](https://img.shields.io/badge/MATLAB-R2024b+-blue?logo=mathworks)](https://www.mathworks.com/products/matlab.html) ![mbdt-badge](https://img.shields.io/badge/-MBDT-green?logo=NXP&logoColor=white&labelColor=grey)

Bring AI-assisted development to NXP Model-Based Design Toolbox.

NXP MBDT AI Support gives AI coding agents the NXP-specific capabilities and device expertise needed to develop Simulink applications for NXP MCUs and MPUs using the NXP Model-Based Design Toolbox (MBDT). Your agent can select and configure the target MCU, configure MBDT peripheral blocks and hardware parameters, initialize and customize the board, and work with existing MBDT applications and examples.
 
Beyond model configuration, the agent can build, compile, and deploy Simulink applications to NXP hardware, help diagnose build and configuration issues, and work across the broader NXP development flow. This includes working with S32 Design Studio and S32 Configuration Tools, as well as development and validation workflows such as Processor-in-the-Loop, External Mode, and FreeMASTER.
 
NXP MBDT AI Support extends the MathWorks Simulink Agentic Toolkit with NXP-specific tools, skills, and device expertise, enabling AI agents to work directly with NXP devices and MBDT workflows. These capabilities are exposed to the AI agent through the [MATLAB® MCP Server](https://github.com/matlab/matlab-mcp-server), providing the connection between the agent, Simulink, and the NXP Model-Based Design Toolbox.
 
**NXP MBDT AI Support** delivers two complementary components:

- **MCP Tools** - MATLAB-side functions exposed to AI agents through the MCP server. NXP AI Support Tools provide live access to and configuration of the installed NXP MBDT environment.
- **Agent Skills** - higher-level, workflow-oriented knowledge under `skills-catalog/`. Skills provide the NXP-specific workflow knowledge needed to guide the agent through configuration, build, deployment, troubleshooting, and verification.

---
## Table of Contents

- [Prerequisites](#prerequisites)
- [How to Install](#how-to-install)
  - [Step 1 - Install the MATLAB MCP Server and the MathWorks Agentic Toolkits](#step-1---install-the-matlab-mcp-server-and-the-mathworks-agentic-toolkits)
  - [Step 2 - Download, Install & Add the NXP MBDT AI Support to the MATLAB Path](#step-2---download-install--add-the-nxp-mbdt-ai-support-to-the-matlab-path)
  - [Step 3 - Register the MBDT AI Support MCP Tools with the AI Coding Agent](#step-3---register-the-mbdt-ai-support-mcp-tools-with-the-ai-coding-agent)
  - [Step 4 - Register the MBDT AI Support Skills with the AI Coding Agent](#step-4---register-the-mbdt-ai-support-skills-with-the-ai-coding-agent)
- [MCP Tools](#mcp-tools)
- [Skills Catalog](#skills-catalog)
- [Related Agentic Toolkits](#related-agentic-toolkits)
- [Supported MBDT Platforms](#supported-mbdt-platforms)
- [License](#license)
- [Community](#community)

---
## Prerequisites

| Prerequisite | Version | Link |
| ------------ | ------- | ---- |
| MATLAB & Simulink (with Embedded Coder) | R2024b+ | [Download](https://www.mathworks.com/products/matlab.html) |
| MATLAB MCP Server, MATLAB Agentic Toolkit & Simulink Agentic Toolkit | v0.12.0+ | See [Step 1 - Install the MATLAB MCP Server and the MathWorks Agentic Toolkits](#step-1---install-the-matlab-mcp-server-and-the-mathworks-agentic-toolkits) |
| NXP Model-Based Design Toolbox (S32K3) | latest | [Download](https://www.nxp.com/design/design-center/software/automotive-software-and-tools/model-based-design-toolbox-mbdt:MBDT) |
| AI Agent (MCP compatible) | latest |  Any MCP-compatible agent that can launch a standalone MCP server - such as [Claude Desktop](https://claude.ai/download), [VS Code](https://code.visualstudio.com/), [Cursor](https://www.cursor.com/), or [Goose](https://block.github.io/goose/), among others |
| NXP S32DS AI Support | latest | [Download](https://github.com/nxp-agentic-ai/s32-tools-agentic-ai-support)|

> **Note:** The MATLAB MCP Server, the MATLAB Agentic Toolkit, and the Simulink Agentic Toolkit are all delivered by the Agentic Toolkit Installer shipped by MathWorks. If they are not yet installed on the machine, follow [Step 1 - Install the MATLAB MCP Server and the MathWorks Agentic Toolkits](#step-1---install-the-matlab-mcp-server-and-the-mathworks-agentic-toolkits) before attempting to register the NXP MBDT AI Support.

> **Note:** NXP Model-Based Design Toolbox is required, and it must match the target MCU family you plan to build for (e.g. install the S32K3 MBDT to target an S32K3 device).

> **Note:** NXP S32DS AI Support is required for AI-assisted S32 Configuration Tools project configuration and S32 Design Studio.

---
## How to Install

This guide provides the installation and register steps for the **NXP MBDT AI Support** with the AI Agent. Additionally guides through the end-to-end installation of the [**MATLAB MCP Server**](https://github.com/matlab/matlab-mcp-server) and the [**MATLAB Agentic Toolkits**](https://github.com/matlab/matlab-agentic-toolkit) & [**Simulink Agentic Toolkits**](https://github.com/matlab/simulink-agentic-toolkit) when those prerequisites are not yet installed on the machine.

The guide also walks through the installation of the **Agent Skills catalog** shipped under `skills-catalog/` - higher-level workflow knowledge that encode the discovery order, the callbacks, and the verification steps on top of the MCP Tools.

> **New here? Follow Steps 1 -> 4 in order.** Step 1 sets up the MathWorks stack (the prerequisite), Step 2 installs the NXP MBDT AI Support on top, and Steps 3 - 4 register the MBDT tools and skills with your AI agent.
>
> **Already have the MathWorks stack** (MATLAB MCP Server + MATLAB & Simulink Agentic Toolkits)? Skip Step 1 and start at Step 2.
>
> **Want only the MathWorks stack** (without the NXP MBDT AI Support)? Do Step 1, then register your agent manually. The `nxp.setup.registerAgent` / `nxp.setup.registerSkills` helpers are shipped with the NXP MBDT AI Support, so they are not available unless you install it (Step 2). Use the manual registration paths instead - Step 3.3 to install the MATLAB MCP Server in your agent, and Step 4.3 to install the Agent Skills by hand.

### Step 1 - Install the MATLAB MCP Server and the MathWorks Agentic Toolkits

The MATLAB MCP Server and the MATLAB & Simulink Agentic Toolkits are the foundation the NXP MBDT AI Support builds on. **(Skip this step entirely if they are already installed.)**

Follow the official **Automated Setup** for the Simulink Agentic Toolkit and complete the installation as described there: [Install Simulink Agentic Toolkit (Automated Setup)](https://github.com/matlab/simulink-agentic-toolkit#get-started-with-the-simulink-agentic-toolkit). When prompted to select which toolkits to install, choose **both** the MATLAB Agentic Toolkit and the Simulink Agentic Toolkit.

### Step 2 - Download, Install & Add the NXP MBDT AI Support to the MATLAB Path

Clone this repository or download the latest **MBDT AI Support** *.mltbx release from the [MBDT AI Support releases](https://github.com/nxp-agentic-ai/mbdt-ai-support/releases/latest), then add it to the MATLAB path by running:

```matlab
mbdt_ai_support_path
```

**Expected output:**

```text
Successful: MBDT AI Support path prepended.

Next step:

Provide the following argument to matlab-mcp-server.exe: [...] --extension-file=<YOUR_PATH>\mbdt-agentic-toolkit\tools.json
```

### Step 3 - Register the MBDT AI Support MCP Tools with the AI Coding Agent

With the MATLAB MCP Server and the Simulink Agentic Toolkit in place, the next step is to register the MBDT AI Support MCP Tools with the AI coding agent. The `nxp.setup.registerAgent` helper generates the required MCP configuration for you: it locates the `matlab-mcp-server.exe` shipped by MathWorks, wires up the `MBDT AI Support` `tools.json` alongside the `Simulink Agentic Toolkit` `tools.json`, and produces the MCP configuration settings for the agent host. You can hand the output of this command to the AI agent and ask it to install the configuration automatically.

In the MATLAB Command Window, run the command that matches your target AI coding agent:

```matlab
nxp.setup.registerAgent("agent","claude")
```

#### 3.1 - Provide custom arguments to the MATLAB MCP Server

The `nxp.setup.registerAgent` helper accepts an optional `mcp_arguments` parameter, which appends extra command-line arguments to `matlab-mcp-server.exe` on top of the mandatory `--extension-file=...` entries.

> For the full list of supported MATLAB MCP Server arguments, see the [MATLAB MCP Server arguments documentation](https://github.com/matlab/matlab-mcp-core-server/tree/main#arguments).


```matlab
nxp.setup.registerAgent("agent","claude", ...
    "mcp_arguments", [ ...
        "--matlab-session-mode=existing"]);
```

> **Important:** When you use `--matlab-session-mode=existing`, the MATLAB MCP Server attaches to an already-running MATLAB session instead of starting a new one. That session must be shared first — run the following once in the MATLAB Command Window before starting the agent:

```matlab
shareMATLABSession
```


#### 3.2 - Register the MCP tools only (MathWorks stack, without NXP MBDT)

If you have already configured the [MATLAB MCP Server](https://github.com/matlab/matlab-mcp-server) and the [Simulink Agentic Toolkit](https://github.com/matlab/simulink-agentic-toolkit), registering the MBDT extension takes just one step: append its `--extension-file` argument to the existing MCP server entry in your AI agent's configuration:


```bash
matlab-mcp-server.exe --extension-file=<YOUR_PATH>\mbdt-agentic-toolkit\tools.json
```

#### 3.3 - Manually install the MCP server in the AI Agent

For users who prefer to install `matlab-mcp-server.exe` by hand, append the `--extension-file` argument resulted at Step 2 to the existing launch command. Multiple `--extension-file` arguments can be combined on a single command line:

```json
"mathworks_mbdt_toolkit": {
"command": "C:/Users/<username>/.matlab/agentic-toolkits/bin/matlab-mcp-server.exe",
"args": [
	"--disable-telemetry=true",
	"--extension-file=C:/Users/<username>/.matlab/agentic-toolkits/simulink/tools/tools.json",
	"--extension-file=<YOUR_PATH>/mbdt-agentic-toolkit/tools.json"
	],
"disabled": false,
"autoApprove": []
}
```


### Step 4 - Register the MBDT AI Support Skills with the AI Coding Agent

The NXP MBDT AI Support also delivers an Agent Skills catalog under `skills-catalog/`. The `nxp.setup.registerSkills` helper installs those skills - together with the skills delivered by the MATLAB Agentic Toolkit and the Simulink Agentic Toolkit - into the AI coding agent's per-user skills directory.

In the MATLAB Command Window, execute the following command, replacing `<agent>` with the target AI coding agent value from the table below:

| `<agent>` value | AI Agent         | Skills install location    |
| --------------- | ---------------- | -------------------------- |
| `"claude"`      | Claude Code      | `~/.claude/skills`         |
| `"codex"`       | Codex            | `~/.agents/skills`         |
| `"copilot"`     | GitHub Copilot   | `~/.agents/skills`         |
| `"opencode"`    | OpenCode         | `~/.agents/skills`         |
| `"goose"`       | Goose            | `~/.agents/skills`         |

> **Tip:** Have the toolkit sources and want live updates? Use `links=true` - see [4.1 - Install as links instead of copies](#41---install-as-links-instead-of-copies).

```matlab
nxp.setup.registerSkills("agent","<agent>")
```

### 4.1 - Install as links instead of copies

By default, `nxp.setup.registerSkills` copies the skill folders into the destination. When you have the toolkit sources and want live updates, pass `links=true` to install **links** instead, so future updates to the source `skills-catalog` are picked up automatically without re-running the registration:

```matlab
nxp.setup.registerSkills("agent","<agent>","links",true)
```

When `links=true` is used on Windows, the helper first attempts a directory symlink (`mklink /D`, which requires Developer Mode or running MATLAB as Administrator) and, on failure, falls back to a junction (`mklink /J`, which needs no special privilege but requires the source and destination to be on the same drive).

### 4.2 - Custom destination folder

To install the skills into an arbitrary folder (for example, a shared team location or a different agent host not listed above), use the `location` parameter instead of `agent`:

```matlab
nxp.setup.registerSkills("location","C:\custom\skills")
```

> The `agent` and `location` parameters are mutually exclusive - pass one or the other, not both.

### 4.3 - Manually install the AI Agent Skills 

For users who prefer to install the Agent Skills by hand, or when the `nxp.setup.registerSkills` script does not address their use case, copy the contents of the toolkit's `skills-catalog/` folder into the AI coding agent's per-user skills directory. For example, on Windows:

```powershell
xcopy /E /I <MBDT AI Support Location>\skills-catalog\* %USERPROFILE%\.agents\skills\
```

---
## MCP Tools

The MCP Tools expose live discovery and configuration of NXP MBDT models - they read the installed toolbox at runtime instead of relying on hard-coded catalogs, so they stay correct as MBDT and MATLAB are upgraded.

| Tool | What your agent can do |
|------|------------------------|
| `get_mbdt_toolbox` | Inspects an installed NXP MBDT toolbox for a given family and returns the requested `section`: `overview` (install paths and versions), `blocks` (MBDT library blocks with their internal Simulink library paths), `devices` (supported MCU targets and custom-board templates), `examples` (shipped example model names), or `all`. |
| `detect_mbdt_params` | Returns the full Configuration Parameters catalog (groups, tags, tooltips, widget types) for a given MBDT platform. |
| `get_mbdt_board_init` | Returns the ordered Board Initialization component sequence emitted into `mbdt_board_init.c` at build time. |
| `set_mbdt_device` | Changes the target MCU / processor / configuration template on a Simulink model targeting NXP MCUs/MPUs. |
| `set_mbdt_model_param` | Applies a value on any Hardware Implementation parameter of a Simulink model targeting NXP MCUs/MPUs. |
| `open_mbdt_example` | Copies an MBDT shipped example into a chosen folder and opens its main model in Simulink. |
| `set_mbdt_board_init` | Edits one field (`Code`, `Header`, `Enabled`, or `Priority`) of a component in the Board Initialization sequence, or inserts a new component (`Insert`). |

---

## Skills Catalog

This repository also ships an Agent Skills catalog under `skills-catalog/` for agents that support the Agent Skills format. These skills provide higher-level workflows on top of the MCP tools - they encode the right discovery order, the right callbacks to fire, the failure modes to recover from, and the verification steps after each change.

| Skill | What your agent can do |
|-------|------------------------|
| `building-mbdt-model` | Generate code, build, compile, rebuild, flash, download, program, deploy, or run on target for an MBDT Simulink model, and diagnose build / compiler / linker errors. |
| `configuring-mbdt-blocks` | Add, read, configure, set parameters on, select a driver function for, or wire interrupts on MBDT driver blocks (Can, Adc, Dio, Pwm, Spi, Uart, I2c, Lin, Gpt, Icu, Mcl, Mem, Fee, MotorControl, FreeMASTER, Profiler, ISR handler). |
| `editing-mbdt-board-init` | View, add, remove, enable, disable, reorder, comment, or edit component entries (Code, Header, Priority, Enabled) of the Board Initialization sequence emitted into `mbdt_board_init.c`. |
| `managing-mbdt-s32ds-project` | Open / launch / focus S32 Design Studio from an MBDT Simulink model (drives the S32DS *Open* pushbutton), and configure or fix the S32DS installation path (`mbdt_s32<platform>_s32ds.m`). |
| `opening-mbdt-config-tool` | Open the external configuration tool paired with the model - S32 Configuration Tools (S32CT) or EB tresos - and navigate to a specific peripheral module. |
| `opening-mbdt-example` | Discover, list, and copy an MBDT shipped example into a chosen folder, open its main model, and verify it loaded. |
| `refreshing-mbdt-com-ports` | Re-scan the host serial port list before reading or writing any MBDT COM port dropdown (PIL, External Mode, FreeMASTER) to avoid a blocking modal popup. |
| `setting-mbdt-model-params` | Set, enable, disable, or pick a value for any Configuration Parameters -> Hardware Implementation field of a Simulink model targeting NXP MCUs/MPUs. |
| `setting-mbdt-target-mcu` | Change / switch / list the target MCU, processor, or hardware configuration template of a Simulink model targeting NXP MCUs/MPUs and verify the change in-memory and on disk. |

---
## Related Agentic Toolkits

| Agentic Toolkits | Role |
|---|---|
| [matlab/matlab-mcp-server](https://github.com/matlab/matlab-mcp-server) | Official MATLAB® MCP Server from MathWorks®. Lets AI applications start and quit MATLAB, write and run MATLAB code, and assess that code for style and correctness. |
| [matlab/matlab-agentic-toolkit](https://github.com/matlab/matlab-agentic-toolkit) | MathWorks MATLAB Agentic Toolkit. Provides the MCP Tools and Agent Skills that expose general MATLAB functionality to AI coding agents. |
| [matlab/simulink-agentic-toolkit](https://github.com/matlab/simulink-agentic-toolkit) | MathWorks Simulink Agentic Toolkit. Provides the MCP Tools and Agent Skills that expose Simulink modeling and simulation to AI coding agents. The NXP MBDT AI Support extends this surface with NXP-specific blocks and configurations. |
| [mathworks/polyspace-agentic-toolkit](https://github.com/mathworks/polyspace-agentic-toolkit) | MathWorks Polyspace Agentic Toolkit. Provides the MCP Tools and Agent Skills that expose Polyspace static analysis and code verification to AI coding agents. |
| [NXP S32DS AI Support](https://github.com/nxp-agentic-ai/s32-tools-agentic-ai-support) | NXP companion product that orchestrates this toolkit and related NXP agentic skills across the broader NXP Tools, including configuring pins, clocks, and peripherals. |

---
## Supported MBDT Platforms

All MCP tools and common skills are cross-platform and resolve the target family dynamically at runtime. Supported families:

| Family  | NXP MBDT Toolbox                     |
| ------- | ------------------------------------ |
| `S32K3` | Model-Based Design Toolbox for S32K3 |

The corresponding MBDT toolbox must be installed for the family you intend to use. Toolboxes are detected live via `detect_matlab_toolboxes`; the tools and skills raise a clear error when the matching MBDT product is missing.

---
## License

This software is licensed under the **LA_OPT_Online Code Hosting NXP_Software_License - v1.4 May 2025**, together with an **AI Addendum** that governs the agentic / AI-assisted functionality of this toolkit.

- Full license text: [`LICENSE`](LICENSE)
- AI Addendum: [`LICENSE_ADDENDUM`](LICENSE_ADDENDUM)
- Third-party components and their licenses: [`SBOM-NXP_Agentic_AI_Toolkit.spdx.json`](SBOM-NXP_Agentic_AI_Toolkit.spdx.json)

By downloading, installing or using this software you accept the terms of the license agreement and the addendum. If a separate license agreement for this software has been signed by you and NXP, that agreement governs your use and supersedes the terms above.

---
## Community

Questions, feedback, feature requests and discussions about this toolkit are welcome on the NXP Community:

- [Agentic AI Development - NXP Community](https://community.nxp.com/t5/Agentic-AI-Development/tkb-p/agentic-ai-development)
- [MBDT - NXP Community](https://community.nxp.com/t5/Model-Based-Design-Toolbox-MBDT/bd-p/mbdt)