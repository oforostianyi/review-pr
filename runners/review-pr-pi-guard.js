// review-pr Pi tool guard.
//
// The review-pr orchestrator loads this Pi extension with `--extension` for
// tool-enabled Pi phases when `agents.pi.max_tool_calls` is configured. It
// enforces two bounds that a prompt alone cannot guarantee for a local model
// that starts repeating itself after context compaction:
//
//   1. An identical tool call (same tool, same arguments) never executes twice.
//      The model is told that the result already exists in its context.
//   2. After `REVIEW_PR_PI_MAX_TOOL_CALLS` executed calls (0 = unlimited) every
//      further call is blocked and the model is asked to return its final
//      output. If it keeps calling tools regardless, the guard terminates the
//      agent after a small allowance so the attempt fails in minutes instead of
//      running until the wall-clock timeout.
//
// Every decision is appended as one JSON line to `REVIEW_PR_PI_GUARD_LOG` when
// that variable is set, so the orchestrator can summarize the run afterwards.
// The extension uses only Node.js built-ins and never touches the repository.

import { appendFileSync } from "node:fs";

const OVERFLOW_ALLOWANCE = 10;

function parseBudget(raw) {
    const value = Number.parseInt(raw ?? "", 10);
    return Number.isFinite(value) && value > 0 ? value : 0;
}

function stableStringify(value) {
    if (value === null || typeof value !== "object") {
        return JSON.stringify(value);
    }
    if (Array.isArray(value)) {
        return "[" + value.map(stableStringify).join(",") + "]";
    }
    const keys = Object.keys(value).sort();
    return "{" + keys.map((key) => JSON.stringify(key) + ":" + stableStringify(value[key])).join(",") + "}";
}

export default function reviewPrPiGuard(pi) {
    const maxToolCalls = parseBudget(process.env.REVIEW_PR_PI_MAX_TOOL_CALLS);
    const logPath = process.env.REVIEW_PR_PI_GUARD_LOG || "";
    const seen = new Set();
    let executed = 0;
    let blocked = 0;
    let budgetBlocked = 0;
    let terminated = false;

    const log = (event, extra) => {
        if (!logPath) return;
        try {
            appendFileSync(logPath, JSON.stringify({ event, ...extra }) + "\n");
        } catch {
            // Diagnostics must never break the review run.
        }
    };

    pi.on("tool_call", (event) => {
        const tool = String(event.toolName ?? "");
        const key = tool + " " + stableStringify(event.input ?? null);

        if (seen.has(key)) {
            blocked += 1;
            log("duplicate_blocked", { tool, calls: executed, blocked });
            return {
                block: true,
                reason:
                    `review-pr tool guard: this exact ${tool} call was already executed earlier in this session and its result is already in your context. ` +
                    "Do not repeat inspections. Continue the review with the evidence you already have and produce the required final output.",
            };
        }

        if (maxToolCalls > 0 && executed >= maxToolCalls) {
            blocked += 1;
            budgetBlocked += 1;
            const terminate = budgetBlocked > OVERFLOW_ALLOWANCE;
            if (terminate && !terminated) {
                terminated = true;
                log("terminated", { tool, calls: executed, blocked });
            } else {
                log("budget_blocked", { tool, calls: executed, blocked });
            }
            return {
                block: true,
                terminate,
                reason:
                    `review-pr tool guard: the tool-call budget (${maxToolCalls}) is exhausted and no further tool calls will execute. ` +
                    "Return the complete required output now, based on the evidence already collected.",
            };
        }

        seen.add(key);
        executed += 1;
        log("allowed", { tool, calls: executed });
        return undefined;
    });
}
