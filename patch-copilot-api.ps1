[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackageRoot,
    [string] $ExpectedVersion = '1.14.14'
)

$ErrorActionPreference = 'Stop'
$marker = 'gc2cc encrypted replay recovery v2'
$legacyMarker = '// gc2cc encrypted replay recovery:'
$packageJsonPath = Join-Path $PackageRoot 'package.json'
$distPath = Join-Path $PackageRoot 'dist'
if (-not (Test-Path -LiteralPath $packageJsonPath)) { throw "copilot-api package.json not found: $packageJsonPath" }
$package = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
if ($package.version -ne $ExpectedVersion) { throw "Unsupported copilot-api version '$($package.version)'; expected '$ExpectedVersion'. Refusing to patch an unknown bundle." }
$bundles = @(Get-ChildItem -LiteralPath $distPath -Filter 'server-*.js' -File)
if ($bundles.Count -ne 1) { throw "Expected exactly one copilot-api server bundle under $distPath; found $($bundles.Count)." }
$bundle = $bundles[0]
$source = Get-Content -LiteralPath $bundle.FullName -Raw
if ($source.Contains($marker)) {
    Write-Host "copilot-api encrypted replay recovery already applied: $($bundle.Name)"
    return
}

$oldWebSocket = @'
const createPooledResponsesWebSocketStream = (request) => createResponsesSafeStream(createPooledWebSocketStream(request, {
	createChunk: createResponsesWebSocketStreamChunk,
	isTerminalChunk: isTerminalResponsesStreamChunk,
	openErrorMessage: "Failed to create responses websocket",
	streamErrorMessage: "Responses websocket stream error",
	terminalChunkMissingMessage: "Responses websocket ended without a terminal response"
}));
'@
$legacyWebSocketEnd = 'const createPooledResponsesWebSocketStream = (request) => createResponsesSafeStream(createRecoveringPooledResponsesWebSocketStream(request));'
if ($source.Contains($legacyMarker)) {
    $legacyStart = $source.IndexOf($legacyMarker)
    $legacyEnd = $source.IndexOf($legacyWebSocketEnd, $legacyStart)
    if ($legacyEnd -lt 0) { throw 'Installed encrypted replay recovery block is incomplete.' }
    $legacyEnd += $legacyWebSocketEnd.Length
    $source = $source.Substring(0, $legacyStart) + $oldWebSocket + $source.Substring($legacyEnd)
}

$oldHttp = @'
const createHttpResponses = async (payload, headers) => {
	const response = await fetch(`${copilotBaseUrl(state)}/responses`, {
		method: "POST",
		headers,
		body: JSON.stringify(payload)
	});
	logCopilotRateLimits(response.headers);
	if (!response.ok) {
		consola.error("Failed to create responses", response);
		throw new HTTPError("Failed to create responses", response);
	}
	if (payload.stream) return events(response);
	return await response.json();
};
'@
$newHttp = @'
// gc2cc encrypted replay recovery v2: retry only a pre-output encrypted-content rejection.
const GC2CC_MAX_ENCRYPTED_REPLAY_RETRIES = 32;
const gc2ccEncryptedReplayErrorText = (value) => {
	if (typeof value === "string") return value;
	if (!value || typeof value !== "object") return "";
	return [value.message, value.error, value.detail].map(gc2ccEncryptedReplayErrorText).join(" ");
};
const isGc2ccEncryptedReplayErrorMessage = (message) => /encrypted content/i.test(message) && /could not be (verified|decrypted|parsed)|decrypt|verif/i.test(message);
const isGc2ccEncryptedReplayItem = (item) => item && typeof item === "object" && ["reasoning", "compaction", "context_compaction"].includes(item.type) && typeof item.encrypted_content === "string" && item.encrypted_content.length > 0;
const removeOldestGc2ccEncryptedReplayPayload = (payload) => {
	const input = payload?.input;
	if (!Array.isArray(input)) return null;
	const index = input.findIndex(isGc2ccEncryptedReplayItem);
	if (index < 0) return null;
	return { ...payload, input: [...input.slice(0, index), ...input.slice(index + 1)] };
};
const isGc2ccEncryptedReplayHttpResponse = async (response) => {
	try {
		return isGc2ccEncryptedReplayErrorMessage(gc2ccEncryptedReplayErrorText(await response.clone().json()));
	} catch {
		try {
			return isGc2ccEncryptedReplayErrorMessage(await response.clone().text());
		} catch { return false; }
	}
};
const createHttpResponses = async (initialPayload, headers) => {
	let payload = initialPayload;
	let removedCount = 0;
	while (true) {
		const response = await fetch(`${copilotBaseUrl(state)}/responses`, {
			method: "POST",
			headers,
			body: JSON.stringify(payload)
		});
		logCopilotRateLimits(response.headers);
		if (!response.ok) {
			if (removedCount < GC2CC_MAX_ENCRYPTED_REPLAY_RETRIES && await isGc2ccEncryptedReplayHttpResponse(response)) {
				const retryPayload = removeOldestGc2ccEncryptedReplayPayload(payload);
				if (retryPayload) {
					removedCount++;
					consola.warn(`gc2cc encrypted replay recovery: retrying HTTP after removing ${removedCount} oldest encrypted item(s)`);
					payload = retryPayload;
					continue;
				}
			}
			consola.error("Failed to create responses", response);
			throw new HTTPError("Failed to create responses", response);
		}
		if (payload.stream) return events(response);
		return await response.json();
	}
};
'@
$newWebSocket = @'
const createRawPooledResponsesWebSocketStream = (request) => createPooledWebSocketStream(request, {
	createChunk: createResponsesWebSocketStreamChunk,
	isTerminalChunk: isTerminalResponsesStreamChunk,
	openErrorMessage: "Failed to create responses websocket",
	streamErrorMessage: "Responses websocket stream error",
	terminalChunkMissingMessage: "Responses websocket ended without a terminal response"
});
const isGc2ccEncryptedReplayError = (chunk) => {
	if (!chunk?.data || chunk.data === "[DONE]") return false;
	try {
		const parsed = JSON.parse(chunk.data);
		return isGc2ccEncryptedReplayErrorMessage(gc2ccEncryptedReplayErrorText(parsed));
	} catch { return false; }
};
const isGc2ccNonSubstantiveResponseChunk = (chunk) => {
	if (!chunk?.data || chunk.data === "[DONE]") return true;
	try {
		const type = JSON.parse(chunk.data).type;
		return type === "response.created" || type === "response.queued" || type === "response.in_progress";
	} catch { return false; }
};
const removeOldestGc2ccEncryptedReplayItem = (request) => {
	const payload = removeOldestGc2ccEncryptedReplayPayload(request.payload);
	return payload ? { ...request, payload } : null;
};
const createRecoveringPooledResponsesWebSocketStream = async function* (initialRequest) {
	let request = initialRequest;
	let removedCount = 0;
	while (true) {
		const buffered = [];
		let retryRequest = null;
		let outputStarted = false;
		for await (const chunk of createRawPooledResponsesWebSocketStream(request)) {
			if (!outputStarted && isGc2ccEncryptedReplayError(chunk) && removedCount < GC2CC_MAX_ENCRYPTED_REPLAY_RETRIES) {
				retryRequest = removeOldestGc2ccEncryptedReplayItem(request);
				if (retryRequest) break;
			}
			buffered.push(chunk);
			if (!isGc2ccNonSubstantiveResponseChunk(chunk)) {
				outputStarted = true;
				for (const pending of buffered) yield pending;
				buffered.length = 0;
			}
		}
		if (!retryRequest) {
			for (const pending of buffered) yield pending;
			return;
		}
		removedCount++;
		consola.warn(`gc2cc encrypted replay recovery: retrying after removing ${removedCount} oldest encrypted item(s)`);
		request = retryRequest;
	}
};
const createPooledResponsesWebSocketStream = (request) => createResponsesSafeStream(createRecoveringPooledResponsesWebSocketStream(request));
'@
$httpOccurrences = ([regex]::Matches($source, [regex]::Escape($oldHttp))).Count
if ($httpOccurrences -ne 1) { throw "copilot-api bundle structure is unsupported: expected one HTTP Responses anchor, found $httpOccurrences." }
$webSocketOccurrences = ([regex]::Matches($source, [regex]::Escape($oldWebSocket))).Count
if ($webSocketOccurrences -ne 1) { throw "copilot-api bundle structure is unsupported: expected one WebSocket stream anchor, found $webSocketOccurrences." }
$patched = $source.Replace($oldHttp, $newHttp).Replace($oldWebSocket, $newWebSocket)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($bundle.FullName, $patched, $utf8NoBom)
Write-Host "Applied copilot-api encrypted replay recovery: $($bundle.Name)"
