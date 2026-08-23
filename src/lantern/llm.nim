## Claude-backed decisions for Lantern. A policy is just a prompt: the game
## server composes the seat's view (role, clock, what that seat can actually
## see) plus that seat's PLAYER_PROMPT and asks Claude for ONE order.
##
## Lantern is a simultaneous-decision game, so every open seat's request goes
## out as ONE PARALLEL BATCH per turn (`curly.makeRequests`) — never a
## sequential walk over the seats. A hunt turn batches six requests, a build
## turn three (the seekers are frozen in the pen and are not asked for an
## order they could not act on).
##
## Every wait is bounded: attempt 1 gets `attempt1Ms`, the single retry gets
## `attempt2Ms`, and the two together fit inside the per-turn budget. Anything
## still unanswered falls back to the `warden` scripted order, which costs
## microseconds, and writes a `fallback` event naming the cause.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials at all the client disables itself on first discovery
## and every turn falls back instantly with no network wait, so offline
## certification and the docker smoke still complete. That fallback is
## load-bearing, not a nicety.

import std/[json, os, strutils, times, unicode]
import bitworld/runtime
import curly
import types, sim, orders, baselines, render, labels

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

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

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmRequest* = object
    seat*: int
    system*, user*: string

  LlmReply* = object
    text*: string
    error*: string
    startMs*, endMs*: int   ## the in-flight window, for the batching test

  LlmClient* = ref object
    curl: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    sender*: proc (client: LlmClient, requests: seq[LlmRequest],
                   timeoutSeconds: int): seq[LlmReply] {.gcsafe.}
      ## Swappable so tests can drive the turn loop with a fake batch
      ## transport and assert the one-parallel-batch-per-turn contract.

  FallbackNote* = object
    attempt*: int
    cause*: FallbackCause
    detail*: string

  Decision* = object
    order*: Order
    source*: OrderSource
    latencyMs*: int
    notes*: seq[FallbackNote]

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "lantern llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "lantern llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": 0.4,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string): string =
  if error.len > 0:
    raise newException(LanternError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LanternError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LanternError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(LanternError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LanternError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LanternError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LanternError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc curlySender(client: LlmClient, requests: seq[LlmRequest],
                 timeoutSeconds: int): seq[LlmReply] {.gcsafe.} =
  ## ONE parallel batch. Every open seat's request is in flight at the same
  ## time; `makeRequests` returns when the slowest has answered or the
  ## timeout has fired, whichever comes first.
  result = newSeq[LlmReply](requests.len)
  var batch: RequestBatch
  for index, request in requests:
    let built = client.requestFor(request.system, request.user)
    batch.post(built.url, built.headers, built.body, $index)
  let started = int(epochTime() * 1000.0)
  let responses = client.curl.makeRequests(batch, timeoutSeconds)
  let ended = int(epochTime() * 1000.0)
  for index in 0 ..< requests.len:
    result[index].startMs = started
    result[index].endMs = ended
    try:
      result[index].text = client.textOf(responses[index].response,
                                         responses[index].error,
                                         batch[index].url)
    except CatchableError as error:
      result[index].error = error.msg

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(model: config.model,
                     maxOutputTokens: config.maxOutputTokens,
                     sender: curlySender)
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "lantern llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "lantern llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "lantern llm: no LLM credentials; using scripted fallback"

proc userPrompt*(sim: Sim, slot: int, prompt: string, retry: bool): string =
  ## The seat's PLAYER_PROMPT, then a blank line, then the seat's view JSON.
  ## The prompt text itself is never echoed into the replay; only the
  ## policy KIND is recorded.
  if prompt.strip().len > 0:
    result.add(prompt.strip())
    result.add("\n\n")
  result.add($seatView(sim, slot))
  if retry:
    result.add("\n\nYour previous reply was invalid. Respond with ONLY the " &
      "requested JSON object, beginning with '{' and carrying a legal " &
      "\"intent\" for your role.")

proc decideAll*(client: LlmClient, sim: Sim, half: int, openSeats: seq[int],
                prompts: seq[string], scripted: seq[ScriptKind],
                forceScripted: bool): seq[Decision] =
  ## One decision per seat in `openSeats`, in order. NEVER raises: any
  ## failure ends at the scripted baseline so the episode always advances.
  result = newSeq[Decision](openSeats.len)
  var pending: seq[int]      ## indexes into `openSeats` still undecided
  for index, seat in openSeats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled or forceScripted:
      result[index].order = scriptedOrder(sim, seat, half, kind)
      result[index].source = osScripted
      if kind == skNone and (client.disabled or forceScripted):
        result[index].source = osFallback
        result[index].notes.add(FallbackNote(
          attempt: 0,
          cause: (if forceScripted: fcBudgetGuard else: fcNoCredentials),
          detail: (if forceScripted: "budget guard engaged"
                   else: "no LLM credentials")))
    else:
      pending.add(index)

  for attempt in 1 .. 2:
    if pending.len == 0 or client.disabled:
      break
    var requests: seq[LlmRequest]
    for index in pending:
      let seat = openSeats[index]
      requests.add(LlmRequest(
        seat: seat, system: SystemPrompt,
        user: userPrompt(sim, seat, prompts[seat], attempt > 1)))
    let budget =
      if attempt == 1: (sim.config.attempt1Ms + 999) div 1000
      else: (sim.config.attempt2Ms + 999) div 1000
    let replies = client.sender(client, requests, max(1, budget))
    var stillPending: seq[int]
    for position, index in pending:
      let seat = openSeats[index]
      let reply = replies[position]
      let latency = max(0, reply.endMs - reply.startMs)
      if reply.error.len > 0:
        result[index].notes.add(FallbackNote(
          attempt: attempt,
          cause: (if "timeout" in reply.error.toLowerAscii() or
                     "timed out" in reply.error.toLowerAscii(): fcTimeout
                  else: fcTransportError),
          detail: reply.error))
        stillPending.add(index)
        continue
      try:
        let cog = sim.cogs[seat]
        let order = parseOrderText(reply.text, roleOfSlot(seat, half),
                                   Point(x: cog.px, y: cog.py), sim.crates)
        result[index].order = order
        result[index].source = osLlm
        result[index].latencyMs = latency
      except CatchableError as error:
        result[index].notes.add(FallbackNote(attempt: attempt,
                                             cause: fcParseError,
                                             detail: error.msg))
        stillPending.add(index)
    pending = stillPending

  for index in pending:
    let seat = openSeats[index]
    echo "lantern llm: seat ", seat, " falling back to the scripted order"
    result[index].order = scriptedOrder(sim, seat, half, skWarden)
    result[index].source = osFallback

proc clipPrompt*(prompt: string): string =
  ## The transport cap on a registered prompt: over-long is truncated on a
  ## rune boundary, never rejected.
  if prompt.runeLen <= MaxPromptRunes: prompt
  else: prompt.runeSubStr(0, MaxPromptRunes)
