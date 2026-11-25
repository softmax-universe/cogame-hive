## The doctrine: the batched-over-bodies vector one colony plays for one turn,
## its strict parser and validator, and the integer coefficient table the ant
## kernel reads.
##
## Every string that can reach the replay is truncated on RUNE boundaries.
## A byte-truncated multi-byte character is exactly the bug that makes replay
## bytes render in a browser and fail a strict JSON parser.

import std/[json, parsejson, streams, strutils, unicode]
import types, text_safety

const
  DefaultScouts* = 40
  DefaultTrailGain* = 50
  DefaultPoach* = 15
  DefaultSpread* = 40
  DefaultLayFood* = 70
  DefaultLayHome* = 50

  DoctrineKeys = [
    "scouts", "trail_gain", "poach", "spread", "lay_food",
    "lay_home", "recall", "focus", "focus_weight", "note", "say"
  ]
  ReplayMetaKeys = ["turn", "seat", "source", "latency_ms"]

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts on a rune boundary, never a byte boundary.
  let cleaned = text.replace("\n", " ").replace("\r", " ").strip()
  if cleaned.runeLen <= limit:
    return cleaned
  cleaned.runeSubStr(0, limit)

proc defaultDoctrine*(): Doctrine =
  Doctrine(
    scouts: DefaultScouts,
    trailGain: DefaultTrailGain,
    poach: DefaultPoach,
    spread: DefaultSpread,
    layFood: DefaultLayFood,
    layHome: DefaultLayHome,
    recall: false,
    hasFocus: false,
    focusBx: 0,
    focusBy: 0,
    focusWeight: 0,
    note: "",
    say: ""
  )

proc coefficients*(doctrine: Doctrine, antsPerColony: int): Coefficients =
  ## The exact integer table from the design note. Every output is inside its
  ## stated range for every legal doctrine, which `tests/test_baselines.nim`
  ## asserts over 500 random views.
  Coefficients(
    alphaFood: doctrine.trailGain * 4,
    alphaRival: doctrine.poach * 3,
    alphaHome: doctrine.spread * 3,
    alphaFwd: 320 - doctrine.spread * 2,
    alphaNoise: 40 + (100 - doctrine.trailGain) * 4,
    betaHome: 200 + doctrine.trailGain * 2,
    layFood: 40 + doctrine.layFood * 3,
    layHome: 20 + doctrine.layHome * 2,
    scoutCount: min(antsPerColony,
      (doctrine.scouts * antsPerColony + 50) div 100)
  )

# ---- strict JSON object extraction and validation ---------------------------

proc unwrapOuterMarkdownFence(text: string): string =
  ## Accepts either a bare JSON object or a single ordinary outer Markdown
  ## code fence (plain ``` or ```json, case-insensitive). Surrounding prose or
  ## extra blocks are rejected by the caller's strict single-object parser.
  let trimmed = text.strip()
  if not trimmed.startsWith("```"):
    return trimmed
  let firstNl = trimmed.find('\n')
  if firstNl < 0:
    raise newException(HiveError, "unterminated markdown code fence")
  let tag = trimmed[3 ..< firstNl].strip().toLowerAscii()
  if tag.len > 0 and tag != "json":
    raise newException(HiveError, "unsupported markdown code fence tag: " & tag)
  if not trimmed.endsWith("```"):
    raise newException(HiveError, "trailing text after markdown code fence")
  let inner = trimmed[firstNl + 1 ..< trimmed.len - 3]
  if inner.len == 0:
    raise newException(HiveError, "empty markdown code fence")
  let lastNl = inner.rfind('\n')
  if lastNl >= 0:
    let closingIndent = inner[lastNl + 1 .. ^1]
    for ch in closingIndent:
      if ch notin {' ', '\t', '\r'}:
        raise newException(HiveError, "closing markdown fence must sit on its own line")
    return inner[0 ..< lastNl].strip()
  raise newException(HiveError, "closing markdown fence must sit on its own line")

proc parseStrictJsonValue(parser: var JsonParser, depth: int): JsonNode =
  if depth > 16:
    raise newException(HiveError, "JSON nesting depth exceeded")
  case parser.tok
  of tkCurlyLe:
    result = newJObject()
    discard parser.getTok()
    if parser.tok == tkCurlyRi:
      discard parser.getTok()
      return
    while true:
      if parser.tok != tkString:
        raise newException(HiveError, "JSON object key must be a string")
      let key = parser.a
      if result.hasKey(key):
        raise newException(HiveError, "duplicate JSON key: " & key)
      discard parser.getTok()
      parser.eat(tkColon)
      result[key] = parseStrictJsonValue(parser, depth + 1)
      if parser.tok == tkCurlyRi:
        discard parser.getTok()
        break
      parser.eat(tkComma)
  of tkBracketLe:
    result = newJArray()
    discard parser.getTok()
    if parser.tok == tkBracketRi:
      discard parser.getTok()
      return
    while true:
      result.add(parseStrictJsonValue(parser, depth + 1))
      if parser.tok == tkBracketRi:
        discard parser.getTok()
        break
      parser.eat(tkComma)
  of tkString:
    result = %parser.a
    discard parser.getTok()
  of tkInt:
    result = %parseBiggestInt(parser.a)
    discard parser.getTok()
  of tkFloat:
    result = %parseFloat(parser.a)
    discard parser.getTok()
  of tkTrue:
    result = %true
    discard parser.getTok()
  of tkFalse:
    result = %false
    discard parser.getTok()
  of tkNull:
    result = newJNull()
    discard parser.getTok()
  else:
    raise newException(HiveError, "unexpected JSON token")

proc extractJsonObject*(text: string): JsonNode =
  ## Parses exactly one JSON object, bare or inside a single ordinary outer
  ## Markdown code fence (plain or `json`-tagged). Rejects surrounding prose,
  ## extra objects, trailing tokens, non-object JSON, and duplicate keys.
  let source = unwrapOuterMarkdownFence(text)
  if source.len == 0 or source[0] != '{':
    var head = text.strip()
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(HiveError,
      "reply must be a single JSON object: " & head.replace("\n", " "))
  var parser: JsonParser
  parser.open(newStringStream(source), "doctrine")
  defer: parser.close()
  try:
    discard parser.getTok()
    if parser.tok != tkCurlyLe:
      raise newException(HiveError, "reply must be a single JSON object")
    result = parseStrictJsonValue(parser, 0)
    if parser.tok != tkEof:
      raise newException(HiveError, "unexpected trailing content after JSON object")
  except HiveError:
    raise
  except CatchableError as error:
    raise newException(HiveError, "invalid JSON object: " & error.msg)

proc requireIntInRange(node: JsonNode, key: string, lowVal, highVal: int): int =
  if not node.hasKey(key):
    raise newException(HiveError, "missing required field: " & key)
  let value = node[key]
  if value.kind != JInt:
    raise newException(HiveError, key & " must be an integer")
  let parsed = value.getInt()
  if parsed < lowVal or parsed > highVal:
    raise newException(HiveError,
      key & " out of range (" & $lowVal & ".." & $highVal & "): " & $parsed)
  parsed

proc readOptionalIntInRange(node: JsonNode, key: string, defaultVal, lowVal, highVal: int): int =
  if not node.hasKey(key):
    return defaultVal
  requireIntInRange(node, key, lowVal, highVal)

proc readOptionalBool(node: JsonNode, key: string, defaultVal: bool): bool =
  if not node.hasKey(key):
    return defaultVal
  let value = node[key]
  if value.kind != JBool:
    raise newException(HiveError, key & " must be a boolean")
  value.getBool()

proc readOptionalFocus(node: JsonNode, doctrine: var Doctrine) =
  doctrine.hasFocus = false
  doctrine.focusBx = 0
  doctrine.focusBy = 0
  if not node.hasKey("focus") or node["focus"].kind == JNull:
    return
  let value = node["focus"]
  if value.kind != JArray or value.len != 2:
    raise newException(HiveError, "focus must be [bx, by] or null")
  if value[0].kind != JInt or value[1].kind != JInt:
    raise newException(HiveError, "focus coordinates must be integers")
  let bx = value[0].getInt()
  let by = value[1].getInt()
  if bx notin 0 ..< BlockCols or by notin 0 ..< BlockRows:
    raise newException(HiveError,
      "focus out of range (0.." & $(BlockCols - 1) & ", 0.." & $(BlockRows - 1) & ")")
  doctrine.hasFocus = true
  doctrine.focusBx = bx
  doctrine.focusBy = by

proc readOptionalText(node: JsonNode, key: string, limit: int): string =
  if not node.hasKey(key):
    return ""
  let value = node[key]
  if value.kind != JString:
    raise newException(HiveError, key & " must be a string")
  let text = value.getStr()
  if not scalarUtf8(text):
    raise newException(HiveError, "invalid Unicode scalar text in " & key)
  truncateRunes(text, limit)

proc decodeDoctrine(
  node: JsonNode,
  previous: Doctrine,
  hasPrevious: bool,
  allowReplayMeta: bool
): Doctrine =
  if node.isNil or node.kind != JObject:
    raise newException(HiveError, "doctrine must be a JSON object")
  for key, _ in node:
    if key in DoctrineKeys:
      continue
    if allowReplayMeta and key in ReplayMetaKeys:
      continue
    raise newException(HiveError, "unknown doctrine field: " & key)
  result.scouts = requireIntInRange(node, "scouts", 0, 100)
  result.trailGain = requireIntInRange(node, "trail_gain", 0, 100)
  result.poach = requireIntInRange(node, "poach", 0, 100)
  result.spread = requireIntInRange(node, "spread", 0, 100)
  result.layFood = requireIntInRange(node, "lay_food", 0, 100)
  result.layHome = requireIntInRange(node, "lay_home", 0, 100)
  result.recall = readOptionalBool(node, "recall", false)
  ## Recall may not run two turns in a row: it is the reset, not a strategy.
  if hasPrevious and previous.recall:
    result.recall = false
  readOptionalFocus(node, result)
  result.focusWeight = readOptionalIntInRange(node, "focus_weight", 0, 0, 100)
  if not result.hasFocus and result.focusWeight != 0:
    raise newException(HiveError, "focus_weight must be 0 when focus is null")
  result.note = readOptionalText(node, "note", MaxNoteRunes)
  result.say = readOptionalText(node, "say", MaxSayRunes)

proc parseDoctrineNode*(
  node: JsonNode,
  previous: Doctrine,
  hasPrevious: bool
): Doctrine =
  ## Strictly validates one doctrine JSON object with no type coercion,
  ## range clamping, legacy aliases, or carryover from the previous turn.
  decodeDoctrine(node, previous, hasPrevious, allowReplayMeta = false)

proc parseDoctrine*(
  text: string,
  previous: Doctrine,
  hasPrevious: bool
): Doctrine =
  ## Parses exactly one JSON object (bare or in one ordinary outer Markdown
  ## code fence) and strictly validates its doctrine fields.
  let node = extractJsonObject(text)
  decodeDoctrine(node, previous, hasPrevious, allowReplayMeta = false)

proc toJson*(doctrine: Doctrine): JsonNode =
  result = %*{
    "scouts": doctrine.scouts,
    "trail_gain": doctrine.trailGain,
    "poach": doctrine.poach,
    "spread": doctrine.spread,
    "lay_food": doctrine.layFood,
    "lay_home": doctrine.layHome,
    "recall": doctrine.recall,
    "focus_weight": doctrine.focusWeight,
    "note": doctrine.note,
    "say": doctrine.say
  }
  result["focus"] =
    if doctrine.hasFocus: %[doctrine.focusBx, doctrine.focusBy]
    else: newJNull()

proc fromJson*(node: JsonNode): Doctrine =
  ## Reads a recorded doctrine back out of a replay.
  decodeDoctrine(node, defaultDoctrine(), false, allowReplayMeta = true)

proc isLegal*(doctrine: Doctrine): bool =
  ## The schema assertion `tests/test_baselines.nim` runs on every emission.
  if doctrine.scouts notin 0 .. 100: return false
  if doctrine.trailGain notin 0 .. 100: return false
  if doctrine.poach notin 0 .. 100: return false
  if doctrine.spread notin 0 .. 100: return false
  if doctrine.layFood notin 0 .. 100: return false
  if doctrine.layHome notin 0 .. 100: return false
  if doctrine.focusWeight notin 0 .. 100: return false
  if doctrine.hasFocus:
    if doctrine.focusBx notin 0 ..< BlockCols: return false
    if doctrine.focusBy notin 0 ..< BlockRows: return false
  elif doctrine.focusWeight != 0:
    return false
  if doctrine.note.runeLen > MaxNoteRunes: return false
  if doctrine.say.runeLen > MaxSayRunes: return false
  true
