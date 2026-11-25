## Strict doctrine parsing, optional-field defaults, and RUNE-boundary
## truncation. A byte-truncated multi-byte character renders fine in a browser
## and fails a strict JSON parser, which is exactly the bug that loses a replay.

import std/[json, strutils, unicode]
import support/helpers
import hive/llm

const BaseRequired =
  "\"scouts\": 20, \"trail_gain\": 80, \"poach\": 5, \"spread\": 30, " &
  "\"lay_food\": 90, \"lay_home\": 60"

proc parsed(text: string, previous = defaultDoctrine(),
    hasPrevious = false): Doctrine =
  parseDoctrine(text, previous, hasPrevious)

proc checkRejected(text: string, label: string,
    previous = defaultDoctrine(), hasPrevious = false) =
  var raised = false
  try:
    discard parsed(text, previous, hasPrevious)
  except HiveError:
    raised = true
  check(raised, label)

proc main() =
  block bareAndOuterFencedObjects:
    let bare = parsed("{" & BaseRequired &
      ", \"recall\": false, \"focus\": [3, 4], \"focus_weight\": 70, " &
      "\"note\": \"go\", \"say\": \"go\"}")
    checkEqual(bare.scouts, 20, "bare JSON scouts")
    checkEqual(bare.trailGain, 80, "bare JSON trail_gain")
    checkEqual(bare.focusBx, 3, "bare JSON focus bx")
    checkEqual(bare.focusBy, 4, "bare JSON focus by")
    checkEqual(bare.focusWeight, 70, "bare JSON focus_weight")

    let jsonFenced = parsed("```json\n{" & BaseRequired & "}\n```")
    checkEqual(jsonFenced.scouts, 20, "json-fenced object parses")
    checkEqual(jsonFenced.trailGain, 80, "json-fenced trail_gain")

    let upperFenced = parsed("```JSON\n{" & BaseRequired & "}\n```")
    checkEqual(upperFenced.scouts, 20, "case-insensitive json fence parses")

    let plainFenced = parsed("```\n{" & BaseRequired & "}\n```")
    checkEqual(plainFenced.scouts, 20, "plain-fenced object parses")
    report("bare JSON and single outer Markdown code fences (json or plain) parse")

  block surroundingProseAndAmbiguousRepliesRejected:
    let validObj = "{" & BaseRequired & "}"
    checkRejected("Sure! Here is my plan:\n" & validObj,
      "leading prose before bare JSON is rejected")
    checkRejected(validObj & "\nHope that helps!",
      "trailing prose after bare JSON is rejected")
    checkRejected("Plan:\n```json\n" & validObj & "\n```",
      "leading prose before markdown fence is rejected")
    checkRejected("```json\n" & validObj & "\n```\nDone.",
      "trailing prose after markdown fence is rejected")
    checkRejected("```python\n" & validObj & "\n```",
      "non-json markdown fence tag is rejected")
    checkRejected(validObj & " " & validObj,
      "multiple bare JSON objects are rejected")
    checkRejected("```json\n" & validObj & "\n```\n```json\n" & validObj & "\n```",
      "multiple fenced JSON objects are rejected")
    checkRejected("{" & BaseRequired & ", \"scouts\": 21}",
      "duplicate JSON keys are rejected")
    checkRejected("[" & validObj & "]",
      "non-object JSON array is rejected")
    report("surrounding prose, extra objects, wrong fences and duplicate keys are rejected")

  block compatibilityShimsRejected:
    checkRejected("{\"scouts\": \"70%\", \"trail_gain\": 50, \"poach\": 10, " &
      "\"spread\": 30, \"lay_food\": 70, \"lay_home\": 50}",
      "percentage string is rejected")
    checkRejected("{\"scouts\": \"12\", \"trail_gain\": 50, \"poach\": 10, " &
      "\"spread\": 30, \"lay_food\": 70, \"lay_home\": 50}",
      "numeric string is rejected")
    checkRejected("{\"scouts\": 8.9, \"trail_gain\": 50, \"poach\": 10, " &
      "\"spread\": 30, \"lay_food\": 70, \"lay_home\": 50}",
      "float is rejected for integer field")
    checkRejected("{\"scouts\": true, \"trail_gain\": 50, \"poach\": 10, " &
      "\"spread\": 30, \"lay_food\": 70, \"lay_home\": 50}",
      "boolean is rejected for integer field")
    checkRejected("{" & BaseRequired & ", \"focus\": {\"bx\": 9, \"by\": 5}, \"focus_weight\": 50}",
      "legacy focus object shape is rejected")
    checkRejected("{" & BaseRequired & ", \"focus\": [99, 99], \"focus_weight\": 50}",
      "out-of-range focus is rejected rather than clamped")
    checkRejected("{" & BaseRequired & ", \"focus\": [1, 2, 3], \"focus_weight\": 50}",
      "wrong-arity focus is rejected rather than nulled")
    checkRejected("{" & BaseRequired & ", \"focus\": \"middle\", \"focus_weight\": 50}",
      "string focus is rejected")
    checkRejected("{" & BaseRequired & ", \"focus\": null, \"focus_weight\": 50}",
      "non-zero focus_weight with null focus is rejected")
    checkRejected("{\"scouts\": -1, \"trail_gain\": 50, \"poach\": 10, " &
      "\"spread\": 30, \"lay_food\": 70, \"lay_home\": 50}",
      "negative integer is rejected rather than clamped")
    checkRejected("{\"scouts\": 101, \"trail_gain\": 50, \"poach\": 10, " &
      "\"spread\": 30, \"lay_food\": 70, \"lay_home\": 50}",
      "over-100 integer is rejected rather than clamped")
    checkRejected("{" & BaseRequired & ", \"recall\": \"true\"}",
      "string recall is rejected")
    checkRejected("{" & BaseRequired & ", \"recall\": 1}",
      "integer recall is rejected")
    checkRejected("{" & BaseRequired & ", \"unknown\": 1}",
      "unknown extra field is rejected")
    report("legacy compatibility shims, type coercions, clamping and unknown fields are rejected")

  block requiredAndOptionalFields:
    checkRejected("{\"note\": \"nothing else\"}",
      "missing required fields are rejected")
    checkRejected("{\"poach\": 5}",
      "partial doctrine does not silently carry over previous turn")

    var previous = defaultDoctrine()
    previous.hasFocus = true
    previous.focusBx = 4
    previous.focusBy = 6
    previous.focusWeight = 80
    let minimal = parsed("{" & BaseRequired & "}", previous, true)
    checkEqual(minimal.recall, false, "omitted recall defaults to false")
    check(not minimal.hasFocus, "omitted focus defaults to null")
    checkEqual(minimal.focusWeight, 0, "omitted focus_weight defaults to 0 (no silent carryover)")
    checkEqual(minimal.note, "", "omitted note defaults to empty")
    checkEqual(minimal.say, "", "omitted say defaults to empty")

    previous.recall = true
    check(not parsed("{" & BaseRequired & ", \"recall\": true}", previous, true).recall,
      "recall may not run two turns in a row")
    report("required fields are enforced and genuine optional fields use clean defaults")

  block runeTruncation:
    let long = repeat("x", 400)
    let note = parsed("{" & BaseRequired & ", \"note\": \"" & long & "\"}").note
    checkEqual(note.runeLen, MaxNoteRunes, "a 400-character note cuts to 140")

    let say = repeat("a", 31) & "\u{1F41C}\u{1F41C}" & "tail"
    checkEqual(say.runeLen, 37, "the fixture is 37 runes")
    let cut = parsed("{" & BaseRequired & ", \"say\": \"" & say & "\"}").say
    checkEqual(cut.runeLen, MaxSayRunes, "say cuts to exactly 32 runes")
    checkEqual(cut, repeat("a", 31) & "\u{1F41C}",
      "the cut lands on the rune boundary, keeping the whole emoji")
    checkEqual(validateUtf8(cut), -1, "the truncated say is valid UTF-8")
    var doctrine = defaultDoctrine()
    doctrine.say = cut
    doctrine.note = note
    let round = parseJson($doctrine.toJson())
    checkEqual(round["say"].getStr(), cut, "the truncated say round-trips")
    checkEqual(validateUtf8($doctrine.toJson()), -1,
      "the encoded doctrine is valid UTF-8")

    let detail = repeat("\u{00E9}", MaxDetailRunes - 1) & "\u{1F41C}" &
      repeat("z", 40)
    check(detail.runeLen > MaxDetailRunes, "the fixture is over the cap")
    let cutDetail = truncateRunes(detail, MaxDetailRunes)
    checkEqual(cutDetail.runeLen, MaxDetailRunes,
      "fallback.detail cuts to exactly 200 runes")
    checkEqual(cutDetail,
      repeat("\u{00E9}", MaxDetailRunes - 1) & "\u{1F41C}",
      "the cut keeps the whole 4-byte rune sitting on the cap")
    checkEqual(validateUtf8(cutDetail), -1,
      "the truncated detail is valid UTF-8")
    let event = %*{"detail": cutDetail}
    checkEqual(parseJson($event)["detail"].getStr(), cutDetail,
      "and it round-trips through the event encoder")
    report("truncation lands on rune boundaries and round-trips as UTF-8")

  block noFabricatedHoldFallback:
    let llmSrc = readRepoFile("src/hive/llm.nim")
    let serverSrc = readRepoFile("src/hive/server.nim")
    check("holdFallbackDoctrine" notin llmSrc and "holdFallbackDoctrine" notin serverSrc,
      "no neutral hold fallback is fabricated in llm.nim or server.nim")
    report("no neutral hold fallback doctrine exists in the decision pipeline")

main()
echo "test_doctrine: all checks passed"
