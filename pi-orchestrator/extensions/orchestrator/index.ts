/**
 * Orchestrator mode for Pi.
 *
 * WHAT THIS DOES
 * --------------
 * When PI_ORCHESTRATOR=1, this extension turns the running Pi session into a
 * planning-only "orchestrator":
 *
 *   1. It appends `prompts/orchestrator.md` to the system prompt, so the session adopts
 *      the orchestrator identity (plan, delegate, verify, report -- never execute).
 *   2. It removes the execution tools (`write`, `edit`, `bash`, `powershell`) from the
 *      active set, so the parent can only read, search, and delegate.
 *
 * WHY THE TOOL REMOVAL HAPPENS HERE AND NOT VIA --tools
 * ----------------------------------------------------
 * The lecture notes make the point that revoking a capability at ASSEMBLY time is the
 * only reliable place: a tool the model never sees in its context cannot be attempted.
 * Pi's recommended form of that is launching with `--tools read,grep,find,ls,subagent`.
 *
 * This extension exists for the case where Pi was launched normally (no `--tools`) and
 * orchestrator mode is entered afterwards. That is a WEAKER guarantee: the tool
 * definitions may already have entered the context for the current run, so this is
 * soft revocation, not hard revocation. Prefer the launcher (`orchestrate.ps1`), which
 * passes `--tools` at startup and gives the strong form.
 *
 * The prompt file is located relative to this extension, so the package stays
 * self-contained and relocatable.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Tools that give the parent the ability to actually change things. */
const REVOKED_TOOLS = ["write", "edit", "bash", "powershell"];

function enabled(): boolean {
    const raw = (process.env.PI_ORCHESTRATOR ?? "").trim().toLowerCase();
    return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

/**
 * Locate the orchestrator prompt shipped next to this extension.
 * Walks up from the extension directory looking for `prompts/orchestrator.md`.
 */
function findPrompt(): string | null {
    const candidates: string[] = [];
    try {
        const here = path.dirname(fileURLToPath(import.meta.url));
        candidates.push(
            path.join(here, "..", "..", "prompts", "orchestrator.md"),
            path.join(here, "prompts", "orchestrator.md"),
        );
    } catch {
        /* not an ESM module context; fall through to cwd-relative candidates */
    }
    candidates.push(path.join(process.cwd(), "prompts", "orchestrator.md"));

    for (const c of candidates) {
        try {
            if (fs.existsSync(c)) return fs.readFileSync(c, "utf-8");
        } catch {
            /* keep looking */
        }
    }
    return null;
}

export default function (pi: ExtensionAPI) {
    if (!enabled()) return;

    const promptText = findPrompt();
    let revoked = false;

    pi.on("before_agent_start", async (event: any) => {
        // Append the orchestrator identity to the default system prompt.
        if (promptText && event?.systemPromptOptions) {
            const existing = event.systemPromptOptions.appendSystemPrompt ?? "";
            event.systemPromptOptions.appendSystemPrompt =
                `${existing}\n\n${promptText}`.trim();
        }

        // Remove execution tools from the active set, once.
        if (!revoked) {
            revoked = true;
            try {
                const active: string[] = pi.getActiveTools?.() ?? [];
                if (active.length > 0) {
                    const keep = active.filter((t) => !REVOKED_TOOLS.includes(t));
                    if (keep.length !== active.length) {
                        pi.setActiveTools(keep);
                        process.stderr.write(
                            `pi-orchestrator: revoked [${REVOKED_TOOLS.join(",")}], active now [${keep.join(",")}]\n`,
                        );
                    }
                }
            } catch (err) {
                process.stderr.write(
                    `pi-orchestrator: could not revoke tools: ${err instanceof Error ? err.message : String(err)}\n`,
                );
            }
        }
    });
}
