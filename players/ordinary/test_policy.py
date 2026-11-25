"""Private-view scripted player behavior and strict JSON reply parsing."""

from __future__ import annotations

import json
import unittest
import urllib.error

from player import RefusalError, choose, classify_player_error
from policy import ScriptedPolicy, parse_json_object

VIEW = {
    "turn": 3,
    "you": {"delivered_last_turn": 5, "last_doctrine": None, "nest_block": [2, 1]},
    "field": {"blocks": [20, 11]},
    "sources": [{"block": [9, 5], "amount_seen": 41}],
}

SELECTION = {
    "bank": "hive-rules-v3",
    "variant": "canonical",
    "selection": "canonical",
    "seed": 0,
}

VALID_DOCTRINE = {
    "scouts": 20,
    "trail_gain": 75,
    "poach": 10,
    "spread": 30,
    "lay_food": 85,
    "lay_home": 50,
    "recall": False,
    "focus": [9, 5],
    "focus_weight": 70,
    "note": "pump",
    "say": "go",
}


class PlayerPolicyTest(unittest.TestCase):
    def test_scripted_choice_uses_private_view(self) -> None:
        action, source, _, user = choose(
            {"view": VIEW, "prompt_selection": SELECTION},
            None,
            ScriptedPolicy(),
            ScriptedPolicy("driftling"),
            "",
            "marcher",
        )
        self.assertEqual(source, "scripted")
        self.assertEqual(action["focus"], [9, 5])
        self.assertEqual(action["note"], "marcher: pump")
        self.assertIn('"amount_seen": 41', user)

    def test_unknown_scripted_baseline_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            choose(
                {"view": VIEW, "prompt_selection": SELECTION},
                None,
                ScriptedPolicy(),
                ScriptedPolicy("driftling"),
                "",
                "true",
            )

    def test_parse_json_object_accepts_bare_and_outer_fences(self) -> None:
        raw = json.dumps(VALID_DOCTRINE)
        self.assertEqual(parse_json_object(raw), VALID_DOCTRINE)
        self.assertEqual(parse_json_object(f"```json\n{raw}\n```"), VALID_DOCTRINE)
        self.assertEqual(parse_json_object(f"```JSON\n{raw}\n```"), VALID_DOCTRINE)
        self.assertEqual(parse_json_object(f"```\n{raw}\n```"), VALID_DOCTRINE)

    def test_parse_json_object_rejects_prose_extra_objects_and_bad_fences(self) -> None:
        raw = json.dumps(VALID_DOCTRINE)
        for bad in (
            f"Sure! Here is my move:\n{raw}",
            f"{raw}\nHope this helps!",
            f"Plan:\n```json\n{raw}\n```",
            f"```json\n{raw}\n```\nDone.",
            f"```python\n{raw}\n```",
            f"{raw} {raw}",
            f"```json\n{raw}\n```\n```json\n{raw}\n```",
            '{"scouts": 10, "scouts": 20}',
            f"[{raw}]",
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    parse_json_object(bad)

    def test_trained_generator_accepts_fenced_json(self) -> None:
        raw = json.dumps(VALID_DOCTRINE)
        action, source, _, _ = choose(
            {"view": VIEW, "prompt_selection": SELECTION},
            lambda _messages: f"```json\n{raw}\n```",
            ScriptedPolicy(),
            ScriptedPolicy("driftling"),
            "",
            "",
        )
        self.assertEqual(source, "trained")
        self.assertEqual(action, VALID_DOCTRINE)

    def test_classify_player_error_distinguishes_infra_from_parse(self) -> None:
        self.assertEqual(classify_player_error(KeyError("ANTHROPIC_API_KEY"))[0], "no_credentials")
        self.assertEqual(
            classify_player_error(urllib.error.HTTPError("http://x", 401, "unauth", {}, None))[0],
            "no_credentials",
        )
        self.assertEqual(
            classify_player_error(urllib.error.HTTPError("http://x", 429, "limit", {}, None))[0],
            "throttled",
        )
        self.assertEqual(
            classify_player_error(urllib.error.HTTPError("http://x", 503, "down", {}, None))[0],
            "provider_error",
        )
        self.assertEqual(classify_player_error(urllib.error.URLError("refused"))[0], "transport_error")
        self.assertEqual(classify_player_error(TimeoutError("timed out"))[0], "timeout")
        self.assertEqual(classify_player_error(RefusalError("refusal"))[0], "refusal")
        self.assertEqual(classify_player_error(ValueError("bad json"))[0], "parse_error")


if __name__ == "__main__":
    unittest.main()
