## Native sidecar policy over the canonical private Lantern observation.
## Missing endpoint selects an unsupervised game-owned fallback.

import std/[base64, json, math, monotimes, options, os, sets, strutils, tables]
import bitworld/[decision_trajectory, native_http]
import types, orders
from std/unicode import validateUtf8

const
  AnthropicVersion = "2023-06-01"
  SystemPrompt* = """
You are one cog in a 3v3 hide-and-seek match on a dark warehouse floor, 1235 by 659
pixels, x right, y down. Each half has two acts. In the BUILD act (30 s) the hiding
team has the lights on and can shove and bolt down 48x48 crates; the seeking team is
locked in its pen. In the HUNT act (75 s) the lights go out, the pen opens, and the
seekers sweep the dark with flashlights. A hider scores one point per tick it is not
yet found. Held in a beam for half a second, or touched, and you are found. Sides swap
at half time, so you will play both roles - your prompt must cover both.
Every 5 seconds you issue ONE order. A deterministic controller executes it for the
next 5 seconds: it steers you to your target, turns your aim, and holds the lock or pry
button when the order says so. You do not drive motors directly.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"intent":"<one of the legal intents for your role>",
 "target":[x,y],          // a point on the floor; clamped into the map
 "crate":"C0".."C9"|null,  // the crate a push/lock/pry order acts on
 "aim":"sweep|hold|track|target",
 "crawl":true|false,       // crawl: 40% speed, no footsteps, cannot push
 "note":"<=140 chars",     // your reasoning, shown to spectators only
 "say":"<=32 chars"}       // one short line, shown to spectators only
Hider intents: push (shove crate toward target), lock (bolt crate down; 3 locks each
per half, 1 s each), hide (go to target and hold still), flee (move away from the
nearest beam or seen seeker), scout (move to target), wait (hold position).
Seeker intents: sweep (advance to target while the beam sweeps), beeline (straight to
target, beam forward), chase (drive at the last lit hider), pry (breach a locked crate;
3 s, very loud), hold (hold target, beam sweeping), wait (hold position).
A locked crate cannot be pushed by anyone; only a pry breaks it. Crates block light and
line of sight. Pushing and running make noise; crawling does not.
"""


type LlmClient* = ref object
  sidecarEndpoint: string
  model*: string
  maxOutputTokens*: int
  disabled*: bool
  temperature*: float
  lastAttempt*: DecisionAttempt

proc newLlmClient*(): LlmClient =
  result = LlmClient(
    temperature: parseFloat(getEnv("COWORLD_LLM_TEMPERATURE", "0.4")),
    model: getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5"),
    maxOutputTokens: getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900").parseInt())
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(LanternError, "COWORLD_LLM_TEMPERATURE must be finite and in 0..1")
  result.sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip().strip(chars = {'/'}, leading = false)
  result.disabled = result.sidecarEndpoint.len == 0

proc userPrompt*(view: JsonNode, prompt: string, retry: bool): string =
  if prompt.strip().len > 0:
    result.add(clip(prompt, MaxPromptRunes))
    result.add("\n\n")
  result.add($view)
  if retry:
    result.add("\n\nYour previous reply was invalid. Respond with ONLY the " &
      "requested JSON object, beginning with '{' and carrying a legal " &
      "\"intent\" for your role.")


proc call*(client: LlmClient, view: JsonNode, prompt: string,
    retry: bool, deadline: MonoTime, slot: int, attemptId, policy: string,
    beforeCall: proc(attempt: DecisionAttempt) {.closure, gcsafe.}): string =
  client.lastAttempt = newDecisionAttempt(attemptId, policy, aoModel)
  let user = userPrompt(view, prompt, retry)
  let body = %*{"max_tokens": client.maxOutputTokens,
    "temperature": client.temperature, "model": client.model,
    "system": SystemPrompt, "messages": [{"role": "user", "content": user}]}
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  headers["anthropic-version"] = AnthropicVersion
  headers["X-Coworld-Player-Slot"] = $slot
  let url = client.sidecarEndpoint & "/v1/messages"
  client.lastAttempt.prompt = %*[{"role": "system", "content": SystemPrompt},
    {"role": "user", "content": user}]
  client.lastAttempt.request = copy(body)
  client.lastAttempt.model = some(client.model)
  client.lastAttempt.decoder = %*{"temperature": client.temperature,
    "max_tokens": client.maxOutputTokens}
  beforeCall(client.lastAttempt)
  let response = performNativePost(url, headers, $body, deadline)
  client.lastAttempt.latencyMs = response.latencyMs
  client.lastAttempt.responseReaderJoined = response.responseReaderJoined
  let observedResponse = response.httpStatus.isSome or response.headerBytes.len > 0 or response.bodyBytes.len > 0
  if observedResponse:
    client.lastAttempt.responseBodyB64 = some(encode(response.bodyBytes))
    client.lastAttempt.responseHeadersB64 = some(encode(response.headerBytes))
    client.lastAttempt.responseComplete = some(response.transferComplete)
    client.lastAttempt.httpStatus = response.httpStatus
    if validateUtf8(response.bodyBytes) == -1:
      client.lastAttempt.rawResponse = %response.bodyBytes
  if validateUtf8(response.headerBytes) != -1:
    raise newException(LanternError, "received HTTP headers are not valid UTF-8")
  var responseHeaders: HttpHeaders
  var receivedHeaders = initTable[string, string]()
  var identityHeaders = initHashSet[string]()
  for line in response.headerBytes.splitLines():
    if line.startsWith("HTTP/"):
      responseHeaders.setLen(0)
      receivedHeaders.clear()
      identityHeaders.clear()
    elif line.len > 0:
      let colon = line.find(':')
      if colon <= 0:
        raise newException(LanternError, "invalid received HTTP header")
      let name = line[0 ..< colon]
      let value = line[colon + 1 .. ^1].strip()
      let normalized = name.toLowerAscii()
      if normalized in ["request-id", "x-request-id", "x-softmax-llm-call-id",
          "x-coworld-checkpoint-sha256", "x-coworld-tokenizer-sha256",
          "x-coworld-chat-template-sha256"]:
        if normalized in identityHeaders:
          raise newException(LanternError, "duplicate received identity header")
        identityHeaders.incl(normalized)
      responseHeaders.add((name, value))
      receivedHeaders[name] = value
  if observedResponse:
    client.lastAttempt.responseHeaders = some(receivedHeaders)
  if responseHeaders.contains("request-id") and responseHeaders.contains("x-request-id") and
      responseHeaders["request-id"] != responseHeaders["x-request-id"]:
    raise newException(LanternError, "conflicting received request identity headers")
  for key in ["request-id", "x-request-id"]:
    if responseHeaders.contains(key):
      client.lastAttempt.providerRequestId = some(responseHeaders[key])
      break
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    if responseHeaders[header].len > 0:
      case field
      of "call":
        let identity = responseHeaders[header]
        if identity.len != 36:
          raise newException(LanternError, "received platform call identity is not a UUID")
        for index, character in identity:
          if index in [8, 13, 18, 23]:
            if character != '-':
              raise newException(LanternError, "received platform call identity is not a UUID")
          elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            raise newException(LanternError, "received platform call identity is not a UUID")
        client.lastAttempt.platformCallId = some(identity)
      of "model": client.lastAttempt.modelIdentity = some(responseHeaders[header])
      of "tokenizer": client.lastAttempt.tokenizerIdentity = some(responseHeaders[header])
      else: client.lastAttempt.chatTemplateSha256 = some(responseHeaders[header])
  if response.kind != nhComplete:
    raise newException(LanternError, "native transport " & $response.kind)
  let status = response.httpStatus.get()
  if status == 401 or status == 403:
    client.disabled = true
    raise newException(LanternError, "native inference auth failed (" & $status & ")")
  if status == 429:
    raise newException(LanternError, "native inference throttled (429)")
  if status < 200 or status >= 300:
    raise newException(LanternError, "native inference error " & $status)
  let payload = parseJson(response.bodyBytes)
  if payload.kind != JObject or payload["model"].kind != JString or
      payload["content"].kind != JArray:
    raise newException(LanternError, "native response violates the completion schema")
  client.lastAttempt.model = some(payload["model"].getStr())
  case payload["stop_reason"].kind
  of JString: client.lastAttempt.stopReason = some(payload["stop_reason"].getStr())
  of JNull: discard
  else: raise newException(LanternError, "native stop reason must be text or null")
  if payload.hasKey("usage") and payload["usage"].kind != JNull:
    let usage = payload["usage"]
    if usage.kind != JObject or usage["input_tokens"].kind != JInt or
        usage["output_tokens"].kind != JInt or usage["input_tokens"].getInt() < 0 or
        usage["output_tokens"].getInt() < 0:
      raise newException(LanternError, "native usage must contain nonnegative integer counts")
    client.lastAttempt.inputTokens = some(usage["input_tokens"].getInt())
    client.lastAttempt.outputTokens = some(usage["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    if sampling.kind != JObject or sampling["prompt_token_ids"].kind != JArray or
        sampling["completion_token_ids"].kind != JArray or sampling["stop_reason"].kind != JString:
      raise newException(LanternError, "native sampling evidence violates the token schema")
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(LanternError, "native prompt token IDs must be nonnegative integers")
      promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(LanternError, "native sampled token IDs must be nonnegative integers")
      sampledIds.add(token.getInt())
    if sampling["behavior_log_probs"].kind != JNull:
      if sampling["behavior_log_probs"].kind != JArray:
        raise newException(LanternError, "native draw probabilities must be an array or null")
      for probability in sampling["behavior_log_probs"]:
        if probability.kind notin {JInt, JFloat} or
            classify(probability.getFloat()) in {fcNan, fcInf, fcNegInf} or probability.getFloat() > 0:
          raise newException(LanternError, "native draw probabilities must be finite nonpositive numbers")
        probabilities.add(probability.getFloat())
      if probabilities.len != sampledIds.len:
        raise newException(LanternError, "native draw probabilities must match sampled token IDs")
    client.lastAttempt.promptTokenIds = some(promptIds)
    client.lastAttempt.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      client.lastAttempt.behaviorLogprobs = some(probabilities)
    client.lastAttempt.stopReason = some(sampling["stop_reason"].getStr())
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LanternError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock.kind != JObject or contentBlock["type"].kind != JString:
      raise newException(LanternError, "native content block violates the completion schema")
    if contentBlock["type"].getStr() == "text":
      if contentBlock["text"].kind != JString:
        raise newException(LanternError, "native text content must be text")
      result.add(contentBlock["text"].getStr())
  client.lastAttempt.response = %result
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LanternError, "native reply ended before a JSON action")
