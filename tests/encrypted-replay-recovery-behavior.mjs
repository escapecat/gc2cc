import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const bundlePath = process.argv[2];
if (!bundlePath) throw new Error("Usage: node encrypted-replay-recovery-behavior.mjs <patched-bundle>");
const source = fs.readFileSync(bundlePath, "utf8");

function between(start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex);
  if (startIndex < 0 || endIndex < 0) throw new Error(`Unable to extract patched block: ${start}`);
  return source.slice(startIndex, endIndex + end.length);
}

function until(start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex);
  if (startIndex < 0 || endIndex < 0) throw new Error(`Unable to extract patched block: ${start}`);
  return source.slice(startIndex, endIndex);
}

const httpBlock = until(
  "// gc2cc encrypted replay recovery v2:",
  "const prepareResponsesWebSocketRequest",
);
const webSocketBlock = between(
  "const createRawPooledResponsesWebSocketStream",
  "const createPooledResponsesWebSocketStream = (request) => createResponsesSafeStream(createRecoveringPooledResponsesWebSocketStream(request));",
);

const fetchResponses = [];
const fetchPayloads = [];
const webSocketStreams = [];
const webSocketPayloads = [];
const warnings = [];

class TestHTTPError extends Error {
  constructor(message, response) {
    super(message);
    this.response = response;
  }
}

const context = vm.createContext({
  Response,
  HTTPError: TestHTTPError,
  state: {},
  copilotBaseUrl: () => "https://example.invalid",
  logCopilotRateLimits: () => {},
  events: (response) => response,
  consola: {
    error: () => {},
    warn: (message) => warnings.push(message),
  },
  fetch: async (_url, options) => {
    fetchPayloads.push(JSON.parse(options.body));
    const response = fetchResponses.shift();
    if (!response) throw new Error("Unexpected HTTP request");
    return response;
  },
  createPooledWebSocketStream: async function* (request) {
    webSocketPayloads.push(request.payload);
    const chunks = webSocketStreams.shift();
    if (!chunks) throw new Error("Unexpected WebSocket request");
    yield* chunks;
  },
  createResponsesWebSocketStreamChunk: () => {},
  isTerminalResponsesStreamChunk: () => false,
});

vm.runInContext(`
const createResponsesSafeStream = async function* (source) {
  try { yield* source; } catch (error) { throw error; }
};
${httpBlock}
${webSocketBlock}
globalThis.recovery = { createHttpResponses, createPooledResponsesWebSocketStream };
`, context);

const encryptedError = () => new Response(JSON.stringify({
  error: {
    message: JSON.stringify({
      error: {
        message: "The encrypted content gAAA-test could not be verified. Reason: Encrypted content could not be decrypted or parsed.",
        code: "invalid_request_body",
      },
    }),
  },
}), { status: 400, headers: { "content-type": "application/json" } });
const success = () => new Response(JSON.stringify({ ok: true }), {
  status: 200,
  headers: { "content-type": "application/json" },
});
const encryptedChunk = {
  data: JSON.stringify({ error: { message: "Encrypted content could not be verified or decrypted" } }),
};
const completedChunk = { data: JSON.stringify({ type: "response.completed" }) };

const originalPayload = {
  stream: true,
  input: [
    { type: "reasoning", encrypted_content: "bad-oldest" },
    { role: "user", content: "continue" },
  ],
};
fetchResponses.push(encryptedError(), success());
assert.equal((await context.recovery.createHttpResponses(originalPayload, {})).status, 200);
assert.equal(fetchPayloads.length, 2);
assert.equal(fetchPayloads[0].input.length, 2);
assert.equal(fetchPayloads[1].input.length, 1);
assert.equal(originalPayload.input.length, 2, "HTTP recovery must not mutate the persisted request payload");

fetchResponses.push(new Response(JSON.stringify({ error: { message: "ordinary failure" } }), { status: 400 }));
await assert.rejects(
  context.recovery.createHttpResponses(originalPayload, {}),
  (error) => error instanceof TestHTTPError,
);
assert.equal(fetchPayloads.length, 3, "an unrelated HTTP 400 must not retry");

const webSocketRequest = { payload: originalPayload };
webSocketStreams.push([encryptedChunk], [completedChunk]);
assert.deepEqual(
  await Array.fromAsync(context.recovery.createPooledResponsesWebSocketStream(webSocketRequest)),
  [completedChunk],
);
assert.equal(webSocketPayloads.length, 2);
assert.equal(webSocketPayloads[1].input.length, 1);
assert.equal(originalPayload.input.length, 2, "WebSocket recovery must not mutate the persisted request payload");

webSocketStreams.push([completedChunk, encryptedChunk]);
assert.deepEqual(
  await Array.fromAsync(context.recovery.createPooledResponsesWebSocketStream(webSocketRequest)),
  [completedChunk, encryptedChunk],
  "WebSocket recovery must not retry after substantive output",
);
assert.equal(webSocketPayloads.length, 3);

assert.equal(warnings.length, 2);
console.log("encrypted replay recovery behavior test passed");
