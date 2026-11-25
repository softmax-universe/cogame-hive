"""Hive doctrines through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture
from policy import ScriptedPolicy, parse_json_object, prompt_for
from prompts import PromptSelection


class RefusalError(RuntimeError):
    """Model returned an explicit refusal stop_reason."""


def classify_player_error(exc: BaseException) -> tuple[str, str]:
    """Distinguish infrastructure/provider failures from invalid model output."""
    if isinstance(exc, RefusalError):
        return "refusal", str(exc) or "provider refusal"
    if isinstance(exc, KeyError):
        return "no_credentials", f"missing credential env: {exc}"
    if isinstance(exc, urllib.error.HTTPError):
        if exc.code in (401, 403):
            return "no_credentials", f"provider auth failed (http {exc.code})"
        if exc.code == 429:
            return "throttled", "provider throttled (http 429)"
        return "provider_error", f"provider http {exc.code}"
    if isinstance(exc, TimeoutError):
        return "timeout", str(exc) or "provider request timed out"
    if isinstance(exc, (urllib.error.URLError, OSError)):
        return "transport_error", str(exc)
    return "parse_error", str(exc)


def choose(
    turn: dict, generator, marcher: ScriptedPolicy, driftling: ScriptedPolicy, strategy: str, scripted: str
) -> tuple[dict, str, str, str]:
    view = turn["view"]
    selection = PromptSelection.model_validate(turn["prompt_selection"])
    system, user = prompt_for(view, strategy, selection)
    if scripted:
        kind = scripted.strip().lower()
        if kind == "marcher":
            return marcher.decide(view), "scripted", system, user
        if kind == "driftling":
            return driftling.decide(view), "scripted", system, user
        raise ValueError(f"unknown PLAYER_SCRIPTED baseline: {scripted}")
    if generator:
        completion = generator(
            [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ]
        )
        action = parse_json_object(completion)
        return action, "trained", system, user
    if strategy:
        endpoint = os.environ.get("COWORLD_LLM_ENDPOINT", "").rstrip("/")
        model = (
            os.environ.get("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
            if endpoint
            else os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5-20251001")
        )
        body = json.dumps(
            {"model": model, "max_tokens": 500, "system": system, "messages": [{"role": "user", "content": user}]}
        ).encode()
        request = urllib.request.Request(
            (f"{endpoint}/v1/messages" if endpoint else "https://api.anthropic.com/v1/messages"),
            body,
            {
                "Content-Type": "application/json",
                "anthropic-version": "2023-06-01",
                "x-api-key": ("sidecar" if endpoint else os.environ["ANTHROPIC_API_KEY"]),
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.load(response)
            if payload.get("stop_reason") == "refusal":
                raise RefusalError("anthropic refusal")
            text = "".join(
                block.get("text", "")
                for block in payload.get("content", [])
                if isinstance(block, dict) and block.get("type") == "text"
            )
            action = parse_json_object(text)
        return action, "llm", system, user
    raise ValueError("ordinary player requires PLAYER_SCRIPTED, PLAYER_PROMPT, or HIVE_ADAPTER_DIR")


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("HIVE_ADAPTER_DIR")
    generator = None
    if adapter:
        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    strategy = os.environ.get("PLAYER_PROMPT", "")
    scripted = os.environ.get("PLAYER_SCRIPTED", "")
    backend = "trained" if adapter else "llm" if strategy else "scripted"
    if backend == "scripted" and not scripted:
        scripted = "marcher"
    marcher = ScriptedPolicy()
    driftling = ScriptedPolicy("driftling")
    artifact = Capture(slot, backend) if os.environ.get("HIVE_CAPTURE_TRAINING") == "1" else None
    registration = json.dumps(
        {
            "type": "register",
            "scripted": scripted,
            "policy": os.environ.get("PLAYER_POLICY_LABEL", backend)[:128],
        }
    )
    deadline = time.monotonic() + 90
    while True:
        try:
            socket = websocket.create_connection(url, timeout=10)
            break
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.25)
    socket.settimeout(120)
    socket.send(registration)
    pending: dict[int, tuple[str, str, dict | None, str, str, str]] = {}
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise RuntimeError("Hive closed before the final frame")
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        if "done" in frame:
            if pending and frame.get("result", {}).get("reason") != "fault":
                raise RuntimeError("Hive ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["result"]["scores"], frame["result"]["reason"])
            break
        kind = frame["type"]
        if kind == "welcome":
            selection = PromptSelection.model_validate(frame["prompt_selection"])
            socket.send(registration)
        elif kind == "decision_request":
            if frame["turn"] not in pending or frame.get("retry"):
                try:
                    action, source, system, user = choose(frame, generator, marcher, driftling, strategy, scripted)
                    pending[frame["turn"]] = (system, user, action, source, "", "")
                except (ValueError, json.JSONDecodeError, OSError, KeyError, RefusalError) as exc:
                    if backend == "scripted":
                        raise
                    cause, detail = classify_player_error(exc)
                    print(f"Hive ordinary player failed on turn {frame['turn']} ({cause}): {detail}", flush=True)
                    pending[frame["turn"]] = ("", "", None, backend, cause, detail)
            _, _, action, source, cause, detail = pending[frame["turn"]]
            reply: dict[str, object] = {"type": "decision", "turn": frame["turn"], "action": action, "source": source}
            if action is None and cause:
                reply["cause"] = cause
                reply["detail"] = detail[:200]
            socket.send(json.dumps(reply))
        elif kind == "decision_result":
            system, user, action, source, _, _ = pending.pop(frame["turn"])
            if artifact and frame["accepted"] and action is not None:
                artifact.record(system, user, action, source, frame["turn"], selection.metadata(system, user))
    socket.close()
    print(f"Hive ordinary player finished: slot={slot} backend={backend}", flush=True)


if __name__ == "__main__":
    main()
