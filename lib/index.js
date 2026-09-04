// capability-access-cleaner — DeepSeek Harness plugin.
//
// Registers one agent tool: `clean_capability_access`.
// The heavy lifting stays in cleanup.ps1 (deterministic fixed logic taken from the
// proven runbook: takeown/icacls -> stop camsvc -> TRUNCATE -> start camsvc -> verify).
// This plugin is only the "entry layer" that lets the agent call it as a tool.
//
// Shape mirrors real dsh tool packages:
//   export { apply, inject, name }   (cordis-style plugin descriptor)

import { fileURLToPath } from "node:url";
import path from "node:path";
import { spawn } from "node:child_process";
import { defineTool } from "@deepseek-ai/dsh-tools";

const name = "capability-access-cleaner";
const inject = ["tools"];

const SCRIPT_PATH = fileURLToPath(new URL("../cleanup.ps1", import.meta.url));

function runScript(args) {
  return new Promise((resolve) => {
    const child = spawn(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT_PATH, ...args],
      { windowsHide: true }
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

function apply(ctx) {
  ctx.tools.register(
    defineTool({
      name: "clean_capability_access",
      description:
        "Fix an abnormally large CapabilityAccessManager.db-wal under C:\\ProgramData\\Microsoft\\Windows\\CapabilityAccessManager (camsvc WAL filling the disk; abnormal when > 1 GB). Runs the bundled cleanup.ps1, which mirrors the proven runbook: takeown + icacls to take ownership, stop the camsvc service, TRUNCATE the wal file (never delete it - deletion corrupts the capability-access SQLite database), restart camsvc, then verify the file is ~0 KB. Use dryRun first: detection only, modifies nothing. Fixing requires an Administrator PowerShell session. selfTest fabricates fake files under TEMP and runs the whole flow safely (no admin, no real system change) for demos.",
      parameters: {
        dryRun: {
          type: "boolean",
          description: "Only detect and report the wal file size; do not modify anything. Recommended first call.",
          required: false
        },
        selfTest: {
          type: "boolean",
          description: "Demo mode: fabricate fake files under TEMP and run detect -> fix (truncate) -> verify. No admin needed, never touches the real system.",
          required: false
        }
      },
      async run(args) {
        const flags = [];
        if (args?.dryRun) flags.push("-DryRun");
        if (args?.selfTest) flags.push("-SelfTest");
        const { code, stdout, stderr } = await runScript(flags);
        return {
          ok: code === 0,
          exitCode: code,
          output: (stdout || stderr || "").trim().slice(-4000)
        };
      }
    })
  );
}

export { apply, inject, name };
