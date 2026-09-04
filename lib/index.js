// capability-access-cleaner — DeepSeek Harness plugin.
//
// Registers one agent tool: `clean_capability_access`.
// The heavy lifting stays in cleanup.ps1 (deterministic fixed logic taken from the
// proven runbook: takeown/icacls -> stop camsvc -> TRUNCATE -> start camsvc -> verify).
//
// Descriptor follows the REAL dsh defineTool contract (verified against dsh-tools source):
//   - execution function is `execute(args, exec)`  (not `run`)
//   - `output: { schema, render }` is REQUIRED  (missing it crashes boot with
//     "Cannot read properties of undefined (reading 'render')")
// IMPORTANT: `@deepseek-ai/dsh-tools` MUST be a peerDependency, NOT a regular
// dependency. A regular dependency installs a SECOND copy of dsh-tools, whose
// `TOOL_RUNTIME_SCHEDULER` Symbol differs from the host runtime's, so every tool
// call then fails with "Cannot read properties of undefined (reading 'prepare')".
// Shape: export { apply, inject, name }   (cordis-style plugin descriptor)

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
        "Fix an abnormally large CapabilityAccessManager.db-wal under C:\\ProgramData\\Microsoft\\Windows\\CapabilityAccessManager (camsvc WAL filling the disk; abnormal when > 1 GB). Runs the bundled cleanup.ps1, which mirrors the proven runbook: takeown + icacls to take ownership, stop the camsvc service, TRUNCATE the wal file (never delete it - deletion corrupts the capability-access SQLite database), restart camsvc, then verify the file is ~0 KB. Use dryRun first: detection only, modifies nothing. If the session is not elevated, the fix automatically relaunches elevated via a UAC prompt (the user clicks Yes) and completes on its own. selfTest fabricates fake files under TEMP and runs the whole flow safely (no admin, no real system change) for demos.",
      parameters: {
        dryRun: {
          type: "boolean",
          description: "Only detect and report the wal file size; do not modify anything. Recommended first call."
        },
        selfTest: {
          type: "boolean",
          description: "Demo mode: fabricate fake files under TEMP and run detect -> fix (truncate) -> verify. No admin needed, never touches the real system."
        }
      },
      output: {
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            ok: { type: "boolean", required: true },
            exitCode: { type: "number", required: true },
            output: { type: "string", required: true }
          }
        },
        render: (_args, value) => [{
          type: "text",
          text: JSON.stringify(value)
        }]
      },
      async execute(args) {
        const flags = [];
        if (args?.dryRun) flags.push("-DryRun");
        if (args?.selfTest) flags.push("-SelfTest");
        const { code, stdout, stderr } = await runScript(flags);
        // `code` is null when the child is killed by a signal; coerce so the
        // value always satisfies the `exitCode: number` output schema.
        const exitCode = typeof code === "number" ? code : 1;
        return {
          ok: exitCode === 0,
          exitCode,
          output: (stdout || stderr || "").trim().slice(-4000)
        };
      }
    })
  );
}

export { apply, inject, name };
