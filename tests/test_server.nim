## The websocket and HTTP contract. The test re-execs ITSELF with
## HIVE_TEST_SERVER set, so the server runs in its own process (it calls
## quit(0) after the shutdown grace) while the parent does the assertions.

import std/[json, options, os, osproc, strtabs, strutils, times]
import curly
import mummy except WebSocket
import mummy/routers
import webby/httpheaders
import whisky
import support/helpers
import bitworld/runtime
import hive/[roster, replay, server]

const
  LivePort = 18731
  ReplayPort = 18732
  NoShowPort = 18733
  ArtifactBarrierPort = 18734
  ExternalRejectPort = 18735
  LlmOkGamePort = 18736
  LlmOkSidecarPort = 18737
  LlmFailGamePort = 18738
  LlmFailSidecarPort = 18739

proc waitForHealth(curl: Curly, port: int, seconds = 20.0): bool =
  let deadline = epochTime() + seconds
  while epochTime() < deadline:
    try:
      let response = curl.get("http://127.0.0.1:" & $port & "/healthz", emptyHttpHeaders(), 2)
      if response.code == 200:
        return true
    except CatchableError:
      discard
    sleep(150)
  false

proc runLiveServer() =
  let work = getEnv("HIVE_TEST_WORK")
  var config = defaultGameConfig()
  config.seed = 42
  config.episodeTicks = 480
  config.turnTicks = 240
  ## Long enough that the parent can finish every HTTP assertion while the
  ## server is still waiting for players.
  config.playerConnectTimeoutSeconds = 25.0
  config.bonanzaTicks = @[]
  config.players = @[
    PlayerConfig(name: "daveey"), PlayerConfig(name: "daveey-1"),
    PlayerConfig(name: "Baseline (1)"), PlayerConfig(name: "Baseline (2)")
  ]
  config.tokens = @["token-0", "token-1", "token-2", "token-3"]
  putEnv("COGAME_RESULTS_URI", "file://" & work / "results.json")
  putEnv("COGAME_SAVE_REPLAY_URI", "file://" & work / "replay.json")
  putEnv("COGAME_EVENTS_URI", "file://" & work / "events.jsonl")
  putEnv("COGAME_METRICS_URI", "file://" & work / "metrics.json")
  var runtime = RuntimeConfig(host: "127.0.0.1", port: LivePort, config: "{}")
  runtime.resultsUri = getEnv("COGAME_RESULTS_URI")
  runtime.replayUri = getEnv("COGAME_SAVE_REPLAY_URI")
  runGameServer(config, runtime)

proc runNoShowServer() =
  ## Nobody connects. The episode must still play to full time on the
  ## marcher, and the LOWEST offending slot must be reported to
  ## COGAME_PLAYER_FAILURE_URI.
  ##
  ## The wall-clock budget is squeezed to 40 s so the SHIPPED budget guard in
  ## server.nim - `elapsed + 2 * turnBudgetSeconds > wallBudget`, 2 x 22 = 44
  ## - engages on the first turn. It must settle the episode on the scripted
  ## layer and still end complete/full_time, not deadline.
  let work = getEnv("HIVE_TEST_WORK")
  var config = defaultGameConfig()
  config.seed = 42
  config.episodeTicks = 480
  config.turnTicks = 240
  config.playerConnectTimeoutSeconds = 2.0
  config.wallClockBudgetSeconds = 40.0
  config.bonanzaTicks = @[]
  config.players = @[
    PlayerConfig(name: "P1"), PlayerConfig(name: "P2"),
    PlayerConfig(name: "P3"), PlayerConfig(name: "P4")
  ]
  config.tokens = @["token-0", "token-1", "token-2", "token-3"]
  putEnv("COGAME_RESULTS_URI", "file://" & work / "noshow-results.json")
  putEnv("COGAME_SAVE_REPLAY_URI", "file://" & work / "noshow-replay.json")
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & work / "player_failure.json")
  putEnv("COGAME_EVENTS_URI", "file://" & work / "noshow-events.jsonl")
  var runtime = RuntimeConfig(host: "127.0.0.1", port: NoShowPort, config: "{}")
  runtime.resultsUri = getEnv("COGAME_RESULTS_URI")
  runtime.replayUri = getEnv("COGAME_SAVE_REPLAY_URI")
  runGameServer(config, runtime)

proc runArtifactBarrierServer() =
  let work = getEnv("HIVE_TEST_WORK")
  var config = defaultGameConfig()
  config.seed = 42
  config.episodeTicks = 480
  config.playerConnectTimeoutSeconds = 1.0
  config.wallClockBudgetSeconds = 40.0
  config.bonanzaTicks = @[]
  config.players = @[PlayerConfig(name: "P1"), PlayerConfig(name: "P2"),
    PlayerConfig(name: "P3"), PlayerConfig(name: "P4")]
  config.tokens = @["t0", "t1", "t2", "t3"]
  putEnv("COGAME_RESULTS_URI", "file://" & work / "barrier-results.json")
  putEnv("COGAME_SAVE_REPLAY_URI", "file://" & work / "barrier-replay.json")
  putEnv("COGAME_EVENTS_URI", "file://" & work / "barrier-events.jsonl")
  putEnv("COGAME_METRICS_URI", "file://" & work / "barrier-metrics.fifo")
  var runtime = RuntimeConfig(host: "127.0.0.1", port: ArtifactBarrierPort, config: "{}")
  runtime.resultsUri = getEnv("COGAME_RESULTS_URI")
  runtime.replayUri = getEnv("COGAME_SAVE_REPLAY_URI")
  runGameServer(config, runtime)

proc runExternalRejectServer() =
  let work = getEnv("HIVE_TEST_WORK")
  var config = defaultGameConfig()
  config.seed = 42
  config.episodeTicks = 240
  config.turnTicks = 240
  config.playerConnectTimeoutSeconds = 15.0
  config.bonanzaTicks = @[]
  config.players = @[PlayerConfig(name: "ExtBad"), PlayerConfig(name: "P2"),
    PlayerConfig(name: "P3"), PlayerConfig(name: "P4")]
  config.tokens = @["t0", "t1", "t2", "t3"]
  putEnv("COGAME_RESULTS_URI", "file://" & work / "ext-results.json")
  putEnv("COGAME_SAVE_REPLAY_URI", "file://" & work / "ext-replay.json")
  putEnv("COGAME_EVENTS_URI", "file://" & work / "ext-events.jsonl")
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & work / "ext-player-failure.json")
  var runtime = RuntimeConfig(host: "127.0.0.1", port: ExternalRejectPort, config: "{}")
  runtime.resultsUri = getEnv("COGAME_RESULTS_URI")
  runtime.replayUri = getEnv("COGAME_SAVE_REPLAY_URI")
  runGameServer(config, runtime)

proc runLlmRoundTripServer(port, sidecarPort: int, prefix: string, ticks: int) =
  let work = getEnv("HIVE_TEST_WORK")
  var config = defaultGameConfig()
  config.seed = 42
  config.episodeTicks = ticks
  config.turnTicks = 240
  config.turnBudgetSeconds = 8.0
  config.playerConnectTimeoutSeconds = 15.0
  config.bonanzaTicks = @[]
  config.players = @[PlayerConfig(name: "ModelSeat"), PlayerConfig(name: "P2"),
    PlayerConfig(name: "P3"), PlayerConfig(name: "P4")]
  config.tokens = @["t0", "t1", "t2", "t3"]
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:" & $sidecarPort)
  putEnv("COWORLD_LLM_MODEL", "test-model")
  putEnv("COGAME_RESULTS_URI", "file://" & work / (prefix & "-results.json"))
  putEnv("COGAME_SAVE_REPLAY_URI", "file://" & work / (prefix & "-replay.json"))
  putEnv("COGAME_EVENTS_URI", "file://" & work / (prefix & "-events.jsonl"))
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & work / (prefix & "-player-failure.json"))
  var runtime = RuntimeConfig(host: "127.0.0.1", port: port, config: "{}")
  runtime.resultsUri = getEnv("COGAME_RESULTS_URI")
  runtime.replayUri = getEnv("COGAME_SAVE_REPLAY_URI")
  runGameServer(config, runtime)

proc runFakeLlmSidecar(port: int, failProvider: bool) =
  var router: Router
  router.get("/healthz", proc(request: Request) {.gcsafe.} =
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    request.respond(200, headers, """{"ok": true}""")
  )
  router.post("/v1/messages", proc(request: Request) {.gcsafe.} =
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    if failProvider:
      request.respond(503, headers, """{"message":"LLM provider is unavailable"}""")
      return
    let rawAction =
      """{"scouts":20,"trail_gain":75,"poach":10,"spread":30,""" &
      """"lay_food":85,"lay_home":50,"recall":false,"focus":[9,5],""" &
      """"focus_weight":70,"note":"roundtrip","say":"go"}"""
    let fenced = "\"turn\": 1" in request.body or "\"turn\":1" in request.body
    let replyText = if fenced: "```json\n" & rawAction & "\n```" else: rawAction
    request.respond(200, headers, $ %*{
      "stop_reason": "end_turn",
      "content": [{"type": "text", "text": replyText}]
    })
  )
  let sidecar = newServer(router, workerThreads = 2)
  sidecar.serve(Port(port), "127.0.0.1")

proc runReplayServer() =
  var runtime = RuntimeConfig(host: "127.0.0.1", port: ReplayPort)
  runtime.replay = readRepoFile("tests/fixtures/sample_replay.json")
  runtime.replayMode = true
  server.runReplayServer(runtime)

proc main() =
  let curl = newCurly()
  let work = getTempDir() / ("hive-server-test-" & $getCurrentProcessId())
  createDir(work)
  let self = getAppFilename()

  ## ---- replay mode -------------------------------------------------------
  block replayMode:
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "replay", "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, ReplayPort), "the replay server answers /healthz")
    let base = "http://127.0.0.1:" & $ReplayPort
    let data = curl.get(base & "/replay-data", emptyHttpHeaders(), 5)
    checkEqual(data.code, 200, "/replay-data answers in replay mode")
    let parsed = parseJson(data.body)
    checkEqual(parsed["protocol"].getStr(), "hive.replay.v1",
      "/replay-data serves the recorded replay")
    let page = curl.get(base & "/client/replay", emptyHttpHeaders(), 5)
    checkEqual(page.code, 200, "/client/replay serves a page")
    check("id=\"board\"" in page.body, "the replay page carries the chrome")
    check("wire_constants.js" in page.body,
      "the served page is spliced, not raw")
    check("chrome_common.js" in page.body, "chrome_common is spliced in")
    check("hive_replay.js" in page.body,
      "the wasm module is spliced in - static_replay.js calls the " &
      "HiveReplayModule factory it defines")
    check("static_replay.js" in page.body, "and so is the shell")
    check(page.body.find("hive_replay.js") < page.body.find("static_replay.js"),
      "in the same order as the static bundle: module before shell")
    child.terminate()
    discard child.waitForExit()
    report("replay mode serves /replay-data and a spliced /client/replay")

  ## ---- live mode ---------------------------------------------------------
  block liveMode:
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "live", "HIVE_TEST_WORK": work,
             "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, LivePort), "the live server answers /healthz")
    let base = "http://127.0.0.1:" & $LivePort

    let health = curl.get(base & "/healthz", emptyHttpHeaders(), 5)
    checkEqual(health.code, 200, "/healthz is 200")
    checkEqual(parseJson(health.body)["ok"].getBool(), true, "and says ok")

    ## The episode runner probes BOTH client routes before starting player
    ## pods. A 404 here is a game_contract_violation.
    let playerPage = curl.get(base & "/client/player?slot=0&token=token-0", emptyHttpHeaders(), 5)
    checkEqual(playerPage.code, 200, "GET /client/player returns a real page")
    check(playerPage.body.len > 400, "and it is a real page, not a stub")
    check("new WebSocket" notin playerPage.body and
      "/player?" notin playerPage.body,
      "the player page never opens the player socket")
    let globalPage = curl.get(base & "/client/global", emptyHttpHeaders(), 5)
    checkEqual(globalPage.code, 200, "GET /client/global returns a real page")
    check(globalPage.body.len > 400, "and it is a real page")
    check("/player?" notin globalPage.body,
      "the global page never opens the player socket")
    check("/global" in globalPage.body,
      "the global page reads the spectator channel instead")

    checkEqual(curl.get(base & "/client/chrome_common.js", emptyHttpHeaders(), 5).code, 200,
      "chrome assets are served")
    checkEqual(curl.get(base & "/client/art/ant.png", emptyHttpHeaders(), 5).code, 200,
      "art is served")
    checkEqual(curl.get(base & "/client/../etc/passwd", emptyHttpHeaders(), 5).code, 404,
      "the asset route refuses traversal")

    ## A bad slot or token is 403.
    checkEqual(curl.get(base & "/player?slot=0&token=wrong", emptyHttpHeaders(), 5).code, 403,
      "a bad token is 403")
    checkEqual(curl.get(base & "/player?slot=9&token=token-0", emptyHttpHeaders(), 5).code, 403,
      "a bad slot is 403")

    ## A real seat connects, registers, and a second connection on the same
    ## slot is 409.
    var live = newWebSocket("ws://127.0.0.1:" & $LivePort &
      "/player?slot=0&token=token-0")
    live.send($ %*{"type": "register", "prompt": "",
      "scripted": "marcher", "policy": "test"})
    let welcome = live.receiveMessage()
    check(welcome.isSome, "the seat receives a welcome frame")
    let hello = parseJson(welcome.get().data)
    checkEqual(hello["type"].getStr(), "welcome", "the frame is a welcome")
    checkEqual(hello["protocol"].getStr(), "hive.player.v1", "released prompt protocol")
    checkEqual(hello["supported_protocols"][1].getStr(), "hive.player.v2",
      "ordinary decision protocol remains supported")
    checkEqual(hello["slot"].getInt(), 0, "the slot is echoed")
    check(hello["colony"].getStr() in ["Amber", "Teal", "Lime", "Magenta"],
      "the welcome names a colony ALIAS, never a player")
    checkEqual(curl.get(base & "/player?slot=0&token=token-0", emptyHttpHeaders(), 5).code, 409,
      "a duplicate connection on a live slot is 409")
    report("healthz, both client pages, 403, 409 and the register frame")

    ## /global streams a snapshot.
    var spectator = newWebSocket("ws://127.0.0.1:" & $LivePort & "/global")
    let snapshot = spectator.receiveMessage()
    check(snapshot.isSome, "/global sends a snapshot on connect")
    let state = parseJson(snapshot.get().data)
    checkEqual(state["protocol"].getStr(), "hive.global.v1", "global protocol")
    checkEqual(state["colonies"].len, Colonies, "four colonies")
    check(state.hasKey("ants") and state["ants"].len == 96, "96 ants")
    report("/global streams a complete snapshot")

    ## Seat the remaining three so the episode plays out, then assert the
    ## artifacts and the shutdown grace.
    var others: seq[WebSocket]
    for slot in 1 .. 3:
      var socket = newWebSocket("ws://127.0.0.1:" & $LivePort &
        "/player?slot=" & $slot & "&token=token-" & $slot)
      socket.send($ %*{"type": "register", "prompt": "",
        "scripted": "marcher", "policy": ""})
      others.add(socket)

    ## The episode is 480 ticks of scripted play: fast. Wait for the results
    ## file, then check /global is STILL answering during the grace.
    let deadline = epochTime() + 60.0
    while epochTime() < deadline and not fileExists(work / "results.json"):
      sleep(200)
    check(fileExists(work / "results.json"),
      "results.json lands on the file:// URI")
    check(fileExists(work / "replay.json"), "the replay lands too")
    check(fileExists(work / "events.jsonl"),
      "COGAME_EVENTS_URI is honoured for a file:// URI")
    check(fileExists(work / "metrics.json"), "metrics land before the results marker")
    checkEqual(parseFile(work / "metrics.json")["final_tick"].getInt(), 480,
      "complete metrics are readable at the results boundary")

    let stillUp = curl.get(base & "/healthz", emptyHttpHeaders(), 2)
    checkEqual(stillUp.code, 200,
      "/healthz keeps answering during the shutdown grace")
    var graceSocket = newWebSocket("ws://127.0.0.1:" & $LivePort & "/global")
    check(graceSocket.receiveMessage().isSome,
      "/global keeps answering during the shutdown grace")
    graceSocket.close()

    let results = parseJson(readFile(work / "results.json"))
    checkEqual(results["names"].len, Colonies, "results carry four names")
    checkEqual(results["scores"].len, Colonies, "and four scores")
    check(results["reason"].getStr() in ["complete", "deadline", "fault"],
      "a legal reason")
    discard parseReplayBytes(readFile(work / "replay.json"))
    check(not fileExists(work / "player_failure.json"),
      "no player failure is reported when every seat connects")
    let events = readFile(work / "events.jsonl").strip().splitLines()
    check(events.len > 2, "the events file has one JSON object a line")
    for line in events:
      let event = parseJson(line)
      check(event{"type"}.getStr() != "fallback",
        "registered hosted scripted seats never wait for external replies")
    report("artifacts land on file:// URIs and the grace keeps the pod alive")

    live.close()
    for socket in others:
      socket.close()
    spectator.close()
    child.terminate()
    discard child.waitForExit()

  ## ---- nobody connects ---------------------------------------------------
  block noShow:
    ## A seat that never connects reports the lowest offending slot to
    ## COGAME_PLAYER_FAILURE_URI and terminates the unfinished episode unscored
    ## (fault/host_error, null scores, null winner) with zero fabricated moves.
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "noshow", "HIVE_TEST_WORK": work,
             "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, NoShowPort), "the no-show server answers /healthz")
    let deadline = epochTime() + 90.0
    while epochTime() < deadline and
        not fileExists(work / "noshow-results.json"):
      sleep(200)
    check(fileExists(work / "player_failure.json"),
      "a seat that never connects is reported to COGAME_PLAYER_FAILURE_URI")
    let failure = parseJson(readFile(work / "player_failure.json"))
    checkEqual(failure["slot"].getInt(), 0,
      "the LOWEST offending slot only")
    check(failure["reason"].getStr().len > 0, "with a reason")
    check(fileExists(work / "noshow-results.json"),
      "the episode still writes results as the completion marker")
    let results = parseJson(readFile(work / "noshow-results.json"))
    checkEqual(results["reason"].getStr(), "fault",
      "a no-show terminates the episode as fault")
    checkEqual(results["end_rule"].getStr(), "host_error",
      "end_rule is host_error")
    checkEqual(results["winner"].kind, JNull, "no invented winner")
    checkEqual(results["scores"].len, Colonies, "four score slots")
    for seat in 0 ..< Colonies:
      checkEqual(results["scores"][seat].kind, JNull,
        "no numeric score on no-show fault")
      checkEqual(results["win"][seat].getBool(), false,
        "no invented win flag")
    let replay = parseJson(readFile(work / "noshow-replay.json"))
    checkEqual(replay["doctrines"].len, 0,
      "no fabricated doctrines are installed on a no-show")
    check(fileExists(work / "noshow-events.jsonl"),
      "the no-show episode writes its events")

    child.terminate()
    discard child.waitForExit()
    report("a no-show is reported and terminates unscored with zero fabricated moves")

  block diagnosticsPrecedeTheCompletionMarker:
    # A FIFO blocks the final metric write until the parent deliberately
    # drains it. This deterministically exposes publishing results too early.
    let fifo = work / "barrier-metrics.fifo"
    checkEqual(execCmdEx("mkfifo " & quoteShell(fifo)).exitCode, 0, "create the owned diagnostic barrier")
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "artifact-barrier", "HIVE_TEST_WORK": work,
             "PATH": getEnv("PATH")}.newStringTable)
    proc guardedCheck(condition: bool, message: string) =
      if not condition:
        child.terminate()
        discard child.waitForExit()
      check(condition, message)
    guardedCheck(waitForHealth(curl, ArtifactBarrierPort), "artifact barrier server answers health")
    let deadline = epochTime() + 20.0
    while epochTime() < deadline and not fileExists(work / "barrier-events.jsonl"):
      sleep(50)
    guardedCheck(fileExists(work / "barrier-replay.json"), "the replay precedes the diagnostic barrier")
    guardedCheck(fileExists(work / "barrier-events.jsonl"), "events precede the blocked final metric")
    sleep(100)
    guardedCheck(not fileExists(work / "barrier-results.json"),
      "no completion marker while the diagnostic write is blocked")
    let metrics = parseJson(readFile(fifo))
    guardedCheck(metrics.hasKey("final_tick"), "the complete final metric survives the barrier")
    while epochTime() < deadline and not fileExists(work / "barrier-results.json"):
      sleep(50)
    guardedCheck(fileExists(work / "barrier-results.json"), "results publish only after diagnostics finish")
    child.terminate()
    discard child.waitForExit()
    report("a blocked diagnostic sink prevents an early results completion marker")

  block roundTripInvalidAndAmbiguousObject:
    ## An external player sending an invalid/ambiguous action must be rejected
    ## with `accepted: false` + `cause: "parse_error"`, retried once, and then
    ## terminate the unfinished episode unscored with zero fabricated moves.
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "ext-reject", "HIVE_TEST_WORK": work,
             "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, ExternalRejectPort),
      "external-reject server answers /healthz")
    var bad = newWebSocket("ws://127.0.0.1:" & $ExternalRejectPort &
      "/player?slot=0&token=t0")
    bad.send($ %*{"type": "register", "scripted": newJNull(), "policy": "bad-ext"})
    var others: seq[WebSocket]
    for slot in 1 .. 3:
      var socket = newWebSocket("ws://127.0.0.1:" & $ExternalRejectPort &
        "/player?slot=" & $slot & "&token=t" & $slot)
      socket.send($ %*{"type": "register", "prompt": "",
        "scripted": "marcher", "policy": "m"})
      others.add(socket)
    var sawResult = false
    var sawRejectCause = ""
    let deadline = epochTime() + 30.0
    while epochTime() < deadline and not sawResult:
      let msg = bad.receiveMessage(500)
      if msg.isNone: continue
      let frame = parseJson(msg.get().data)
      case frame{"type"}.getStr()
      of "decision_request":
        # Send legacy focus object + missing required fields: must be rejected.
        bad.send($ %*{"type": "decision", "turn": frame["turn"].getInt(),
          "action": {"scouts": "70%", "focus": {"bx": 1, "by": 2}},
          "source": "external"})
      of "decision_result":
        checkEqual(frame["accepted"].getBool(), false,
          "invalid external action is rejected")
        sawRejectCause = frame{"cause"}.getStr()
        sawResult = true
      else: discard
    check(sawResult, "external player received decision_result")
    checkEqual(sawRejectCause, "parse_error", "rejection reports parse_error")
    while epochTime() < deadline and not fileExists(work / "ext-results.json"):
      sleep(100)
    check(fileExists(work / "ext-results.json"), "ext-results.json written")
    check(fileExists(work / "ext-player-failure.json"),
      "COGAME_PLAYER_FAILURE_URI written for invalid action")
    let failure = parseJson(readFile(work / "ext-player-failure.json"))
    checkEqual(failure["slot"].getInt(), 0, "failure reports offending slot 0")
    check("parse_error" in failure["reason"].getStr(),
      "failure reason names parse_error")
    let results = parseJson(readFile(work / "ext-results.json"))
    checkEqual(results["reason"].getStr(), "fault",
      "invalid action terminates episode as fault")
    checkEqual(results["end_rule"].getStr(), "host_error",
      "end_rule is host_error")
    checkEqual(results["winner"].kind, JNull, "no invented winner")
    for seat in 0 ..< Colonies:
      checkEqual(results["scores"][seat].kind, JNull,
        "no numeric scores on invalid-action failure")
      checkEqual(results["win"][seat].getBool(), false, "no win flag")
    checkEqual(results["fallback_turns"][0].getInt(), 1,
      "rejected external turn counted in fallback_turns")
    checkEqual(results["fallback_causes"][0]["parse_error"].getInt(), 1,
      "parse_error counted in fallback_causes")
    let replay = parseJson(readFile(work / "ext-replay.json"))
    checkEqual(replay["doctrines"].len, 0,
      "zero fabricated doctrines installed on rejected turn")
    bad.close()
    for socket in others: socket.close()
    child.terminate()
    discard child.waitForExit()
    report("invalid external action reports parse_error and terminates unscored")

  block roundTripRegularAndFencedJson:
    ## Public host + player round-trip with regular JSON on turn 0 and
    ## markdown-fenced ```json``` on turn 1 completes with real numeric scores.
    let sidecar = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "fake-llm-ok", "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, LlmOkSidecarPort), "fake-llm-ok sidecar answers /healthz")
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "llm-ok", "HIVE_TEST_WORK": work,
             "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, LlmOkGamePort), "llm-ok game answers /healthz")
    var sockets: seq[WebSocket]
    var modelWs = newWebSocket("ws://127.0.0.1:" & $LlmOkGamePort &
      "/player?slot=0&token=t0")
    modelWs.send($ %*{"type": "register", "scripted": newJNull(),
      "prompt": "play well", "policy": "model-seat"})
    sockets.add(modelWs)
    for slot in 1 .. 3:
      var ws = newWebSocket("ws://127.0.0.1:" & $LlmOkGamePort &
        "/player?slot=" & $slot & "&token=t" & $slot)
      ws.send($ %*{"type": "register", "prompt": "",
        "scripted": "marcher", "policy": "m"})
      sockets.add(ws)
    let deadline = epochTime() + 30.0
    while epochTime() < deadline and not fileExists(work / "llm-ok-results.json"):
      sleep(100)
    check(fileExists(work / "llm-ok-results.json"), "llm-ok-results.json written")
    check(not fileExists(work / "llm-ok-player-failure.json"),
      "no player failure on valid regular/fenced JSON round-trip")
    let results = parseJson(readFile(work / "llm-ok-results.json"))
    checkEqual(results["reason"].getStr(), "complete", "completed normally")
    checkEqual(results["end_rule"].getStr(), "full_time", "full_time")
    checkEqual(results["turns_llm"][0].getInt(), 2,
      "both bare JSON and fenced JSON turns resolved as llm")
    checkEqual(results["fallback_turns"][0].getInt(), 0, "zero fallbacks")
    var sum = 0.0
    for seat in 0 ..< Colonies:
      check(results["scores"][seat].kind in {JFloat, JInt},
        "completed game emits real numeric scores")
      sum += results["scores"][seat].getFloat()
    check(abs(sum - 1.0) < 1e-6, "completed game scores sum to 1.0")
    for ws in sockets: ws.close()
    child.terminate()
    discard child.waitForExit()
    sidecar.terminate()
    discard sidecar.waitForExit()
    report("host+player round-trip accepts bare and fenced JSON with real scoring")

  block roundTripProviderFailure:
    ## Public host + player round-trip when the LLM provider returns HTTP 503:
    ## terminates unscored (null scores, null winner), records provider_error,
    ## writes COGAME_PLAYER_FAILURE_URI, and installs zero fabricated moves.
    let sidecar = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "fake-llm-503", "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, LlmFailSidecarPort), "fake-llm-503 sidecar answers /healthz")
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "llm-fail", "HIVE_TEST_WORK": work,
             "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, LlmFailGamePort), "llm-fail game answers /healthz")
    var sockets: seq[WebSocket]
    var modelWs = newWebSocket("ws://127.0.0.1:" & $LlmFailGamePort &
      "/player?slot=0&token=t0")
    modelWs.send($ %*{"type": "register", "scripted": newJNull(),
      "prompt": "play well", "policy": "model-seat"})
    sockets.add(modelWs)
    for slot in 1 .. 3:
      var ws = newWebSocket("ws://127.0.0.1:" & $LlmFailGamePort &
        "/player?slot=" & $slot & "&token=t" & $slot)
      ws.send($ %*{"type": "register", "prompt": "",
        "scripted": "marcher", "policy": "m"})
      sockets.add(ws)
    let deadline = epochTime() + 30.0
    while epochTime() < deadline and not fileExists(work / "llm-fail-results.json"):
      sleep(100)
    check(fileExists(work / "llm-fail-results.json"), "llm-fail-results.json written")
    check(fileExists(work / "llm-fail-player-failure.json"),
      "COGAME_PLAYER_FAILURE_URI written on provider failure")
    let failure = parseJson(readFile(work / "llm-fail-player-failure.json"))
    checkEqual(failure["slot"].getInt(), 0, "failure reports slot 0")
    check("provider_error" in failure["reason"].getStr(),
      "failure reason distinguishes provider_error")
    let results = parseJson(readFile(work / "llm-fail-results.json"))
    checkEqual(results["reason"].getStr(), "fault",
      "provider failure terminates episode as fault")
    checkEqual(results["end_rule"].getStr(), "host_error", "end_rule host_error")
    checkEqual(results["winner"].kind, JNull, "no invented winner")
    for seat in 0 ..< Colonies:
      checkEqual(results["scores"][seat].kind, JNull,
        "no numeric scores on provider failure")
      checkEqual(results["win"][seat].getBool(), false, "no win flag")
    checkEqual(results["fallback_causes"][0]["provider_error"].getInt(), 1,
      "provider_error recorded in fallback_causes")
    checkEqual(results["fallback_causes"][0]["parse_error"].getInt(), 0,
      "provider failure is not misclassified as parse_error")
    let replay = parseJson(readFile(work / "llm-fail-replay.json"))
    checkEqual(replay["doctrines"].len, 0,
      "zero fabricated doctrines installed on provider failure")
    for ws in sockets: ws.close()
    child.terminate()
    discard child.waitForExit()
    sidecar.terminate()
    discard sidecar.waitForExit()
    report("host+player round-trip terminates unscored on provider failure with no numeric scores")

  ## ---- URI scheme rejection ----------------------------------------------
  block uriSchemes:
    for name in ["COGAME_EVENTS_URI", "COGAME_METRICS_URI"]:
      putEnv(name, "https://example.com/events")
      var raised = false
      try:
        discard requireFileUri(name)
      except HiveError as error:
        raised = "file://" in error.msg
      check(raised, name & " rejects a non-file scheme loudly")
      putEnv(name, "")
      checkEqual(requireFileUri(name), "", name & " may be unset")
    report("COGAME_EVENTS_URI and COGAME_METRICS_URI are file:// only")

  removeDir(work)

when isMainModule:
  case getEnv("HIVE_TEST_SERVER")
  of "live": runLiveServer()
  of "replay": runReplayServer()
  of "noshow": runNoShowServer()
  of "artifact-barrier": runArtifactBarrierServer()
  of "ext-reject": runExternalRejectServer()
  of "llm-ok": runLlmRoundTripServer(LlmOkGamePort, LlmOkSidecarPort, "llm-ok", 480)
  of "llm-fail": runLlmRoundTripServer(LlmFailGamePort, LlmFailSidecarPort, "llm-fail", 240)
  of "fake-llm-ok": runFakeLlmSidecar(LlmOkSidecarPort, failProvider = false)
  of "fake-llm-503": runFakeLlmSidecar(LlmFailSidecarPort, failProvider = true)
  else:
    main()
    echo "test_server: all checks passed"
