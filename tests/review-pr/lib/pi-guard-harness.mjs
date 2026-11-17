// Test harness: loads the review-pr Pi guard extension with a fake `pi`
// object and replays a scripted sequence of tool calls.
// Usage: node pi-guard-harness.mjs <extension-path> '<json-array-of-{tool,input}>'
import { pathToFileURL } from "node:url";

const [extensionPath, scriptJson] = process.argv.slice(2);
const calls = JSON.parse(scriptJson);
const handlers = {};
const fakePi = {
    on(eventName, handler) {
        (handlers[eventName] ||= []).push(handler);
    },
};
const module = await import(pathToFileURL(extensionPath).href);
const factory = module.default;
await factory(fakePi);

const results = [];
let index = 0;
for (const call of calls) {
    index += 1;
    const event = { toolName: call.tool, toolCallId: `call-${index}`, input: call.input };
    let outcome;
    for (const handler of handlers.tool_call || []) {
        outcome = await handler(event, {});
        if (outcome && outcome.block) break;
    }
    results.push(outcome ?? null);
}
process.stdout.write(JSON.stringify({ registered: Object.keys(handlers), results }) + "\n");
