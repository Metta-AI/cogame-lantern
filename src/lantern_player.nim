## Lantern player: a policy is just a prompt.
##
## The whole container does two things. It sends ONE register frame carrying
## its prompt (or its baseline name), and then it receives until the game
## says done. Every decision is made in the game server, which composes this
## seat's view plus this seat's prompt and asks Claude for one order every
## five seconds.
##
## PLAYER_SCRIPTED=warden (or 1/true/yes) registers the seat as the built-in
## warden baseline instead; PLAYER_SCRIPTED=moth as the weaker moth baseline.
## The server plays those deterministically, with no LLM at all.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <lantern-image> --name my-lantern \
##     --run /bin/lantern-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils]
import whisky

const
  DefaultPrompt = """
Play both roles well, because you will play both.
As a hider: spend the build act pushing one crate into the mouth of the
alcove nearest your spawn and bolting it there with intent "lock", then hide
at that alcove and set crawl true the moment the hunt starts - a still cog
behind an opaque crate is invisible, and footsteps are what give a good
hiding place away. Only "flee" when a beam is reported close, and break
contact around a corner rather than down a straight lane.
As a seeker: claim a third of the map on the first hunt order and sweep it
with intent "sweep" and aim "sweep"; read the heartbeat every turn, push
deeper on cold or cool, slow down on warm, and stop advancing and sweep in
place on hot or burning. The instant anything is lit, switch to "chase" with
aim "track" and stay on it - half a second in the beam is a find.
"""
  ConnectAttempts = 12
  ConnectDelayMs = 500

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL").strip()
  if url.len == 0:
    stderr.writeLine("lantern player: COWORLD_PLAYER_WS_URL is not set")
    quit(1)
  var prompt = getEnv("PLAYER_PROMPT")
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  if prompt.strip().len == 0 and scripted.len == 0:
    prompt = DefaultPrompt
  let label = getEnv("PLAYER_POLICY_LABEL").strip()

  proc registerFrame(): string =
    $ %*{"type": "register", "prompt": prompt,
         "scripted": (if scripted.len == 0: newJNull() else: %scripted),
         "policy": label}

  ## A bounded connect retry: the game container and the player containers
  ## start together, so the first dial often lands before the socket is up.
  ## After the last attempt the player exits 0 — a seat that cannot connect
  ## is played by the server's warden baseline, and a non-zero exit here
  ## would fail the episode for a condition the game already handles.
  var socket: WebSocket = nil
  for attempt in 1 .. ConnectAttempts:
    try:
      socket = newWebSocket(url)
      break
    except CatchableError as error:
      if attempt == ConnectAttempts:
        echo "lantern player: could not reach the game after ", attempt,
          " attempts (", error.msg, "); the server will play this seat"
        quit(0)
      sleep(ConnectDelayMs)
  if socket == nil:
    quit(0)

  socket.send(registerFrame())
  echo "lantern player: registered (",
    (if scripted.len > 0: "scripted " & scripted
     else: $prompt.len & " prompt chars"), ")"

  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      echo "lantern player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      if payload{"done"}.getBool():
        echo "lantern player: final scores ", payload{"result"}{"scores"}
        break
      case payload{"type"}.getStr()
      of "welcome":
        echo "lantern player: seated at slot ", payload{"slot"}.getInt(),
          " as ", payload{"alias"}.getStr(),
          " (hides in half ", payload{"hides_in_half"}.getInt(), ")"
        ## Re-deliver in case the first send raced the slot registration.
        socket.send(registerFrame())
      of "turn":
        discard
      else:
        discard
    except CatchableError as error:
      echo "lantern player: ignoring bad frame: ", error.msg
  socket.close()
