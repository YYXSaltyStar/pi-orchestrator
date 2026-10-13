/**
 * Failure detector for Pi orchestrator runs.
 *
 * What this is for
 * ----------------
 * Some provider/model combinations intermittently fail to deliver the tool set to the
 * model. Observed failure modes:
 *
 *   A. The model emits a tool call as PLAIN TEXT instead of a structured tool call:
 *        <tool_calls>
 *        <invoke name="read"><parameter name="path">...</parameter></invoke>
 *        </tool_calls>
 *      Pi sees no tool call, the loop exits, nothing executes, exit code is still 0.
 *
 *   B. The model has NO tools at all and says so, e.g.
 *        "我没有可用的文件读取工具" / "I don't have a file reading tool"
 *      Verified with `pi.getActiveTools()` returning [] in those runs.
 *
 * Both look like a successful run from the outside. That is the danger: an orchestrator
 * reports "done" having done nothing.
 *
 * What this extension does
 * ------------------------
 * DETECT ONLY. It writes a machine-readable marker to stderr and does not try to repair
 * anything in-process.
 *
 * In-process repair does not work for these failures: in mode B the tools are genuinely
 * absent for that process, so re-prompting the same process cannot help. The fix is an
 * outer retry with a FRESH process, which is what the launcher (orchestrate.ps1) does.
 *
 * Output contract (parsed by the launcher)
 * ----------------------------------------
 *   pi-guard: FAIL leak          -> leaked tool-call text in the final answer
 *   pi-guard: FAIL no-tools      -> model reported having no tool interface
 *   pi-guard: OK tools=<n> calls=<n>   -> run looked healthy
 *
 * Enable with PI_LEAK_GUARD=1. Unset or "0" disables the extension entirely.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const MARK = "pi-guard:";

/** Tool call written as prose. Narrow shapes that do not occur in legitimate answers. */
const LEAK_PATTERNS: RegExp[] = [
    /<tool_calls>/i,
    /<\/tool_calls>/i,
    /<invoke\s+name=/i,
    /<parameter\s+name=/i,
    /<\|[^|]*\|>\s*tool_calls/i,
    /DSML/i,
];

/** The model stating it has no tools. Only counts while tools are demonstrably active. */
const NO_TOOL_CLAIM_PATTERNS: RegExp[] = [
    /没有可用[的]?(文件|工具|读取)/,
    /无法(读取|访问).{0,12}(缺少|没有|不存在).{0,6}工具/,
    /no (available )?(file |tool )?(reading )?tool/i,
    /don'?t have (a )?(file |tool )?(reading )?tool/i,
    /tools? (are|is) not available/i,
    /没有(任何)?工具/,
];

function enabled(): boolean {
    const raw = (process.env.PI_LEAK_GUARD ?? "").trim().toLowerCase();
    return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

function textOf(message: any): string {
    if (!message || typeof message !== "object") return "";
    const content = message.content;
    if (typeof content === "string") return content;
    if (!Array.isArray(content)) return "";
    return content
        .filter((p: any) => p && p.type === "text" && typeof p.text === "string")
        .map((p: any) => p.text)
        .join("\n");
}

function toolCallNames(message: any): string[] {
    if (!message || !Array.isArray(message.content)) return [];
    return message.content
        .filter((p: any) => p && (p.type === "toolCall" || p.type === "tool_call"))
        .map((p: any) => String(p.name ?? p.toolName ?? ""))
        .filter(Boolean);
}

function matchesAny(text: string, patterns: RegExp[]): RegExp | null {
    for (const re of patterns) if (re.test(text)) return re;
    return null;
}

export default function (pi: ExtensionAPI) {
    if (!enabled()) return;

    let toolCallsInRun = 0;

    pi.on("agent_start", () => {
        toolCallsInRun = 0;
    });

    pi.on("tool_call", () => {
        toolCallsInRun += 1;
    });

    pi.on("agent_before_settle", async (event: any) => {
        if (event?.outcome && event.outcome !== "completed") return;

        // Payload lives under `context`. `context.contextMessages` is the AgentMessage
        // projection and is empty here; `context.llmMessages` is the LLM transcript.
        const ctx = event?.context ?? {};
        const messages: any[] = Array.isArray(ctx.llmMessages) ? ctx.llmMessages : [];
        if (messages.length === 0) return;

        let knownTools: string[] = [];
        try {
            knownTools = pi.getActiveTools?.() ?? [];
        } catch {
            knownTools = [];
        }

        let assistantCount = 0;
        let anyToolCall = false;
        let lastAssistantText = "";
        for (const m of messages) {
            const names = toolCallNames(m);
            if (names.length > 0) anyToolCall = true;
            if (m?.role === "assistant") {
                assistantCount += 1;
                const t = textOf(m);
                if (t) lastAssistantText = t;
            }
        }
        if (assistantCount === 0) return;

        // Failure A: leaked tool-call text in the final answer.
        const leak = matchesAny(lastAssistantText, LEAK_PATTERNS);
        if (leak) {
            process.stderr.write(`${MARK} FAIL leak pattern=${leak}\n`);
            return;
        }

        // Failure B: the model claims to have no tools.
        // Only meaningful when the session was SUPPOSED to have tools; a run over an
        // empty tool set is not evidence of a fault.
        const claim = matchesAny(lastAssistantText, NO_TOOL_CLAIM_PATTERNS);
        if (claim && knownTools.length > 0) {
            process.stderr.write(`${MARK} FAIL no-tools claim="${claim}"\n`);
            return;
        }

        process.stderr.write(
            `${MARK} OK tools=${knownTools.length} calls=${toolCallsInRun} anyCall=${anyToolCall}\n`,
        );
    });
}
