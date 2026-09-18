# @acid: DISPATCH-1, DISPATCH-5, UX-1, UX-2
"""Vision-driven autonomous browser loop with Jev and Quartz event dispatch."""

import os
import sys
import time
import json
import httpx
from pathlib import Path
from segmenter import UISegmenter
from driver import click_at, type_text, press_key, replace_text_at

OPENROUTER_KEY = None
if os.environ.get("OPENROUTER_API_KEY"):
    OPENROUTER_KEY = os.environ["OPENROUTER_API_KEY"]
else:
    env_path = Path.home() / ".omp" / "agent" / ".env"
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if line.startswith("OPENROUTER_API_KEY="):
                OPENROUTER_KEY = line.split("=", 1)[1].strip("'\"")
                break

DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"
COMPLETIONS_URL = "https://openrouter.ai/api/v1/chat/completions"

HEADERS = {
    "Authorization": f"Bearer {OPENROUTER_KEY}",
    "Content-Type": "application/json",
    "HTTP-Referer": "https://github.com/bottlebrushes/jev-orb",
    "X-Title": "JevOrb-Vision"
}

def query_jev(elements: list, goal: str, history: list) -> tuple:
    """Asks typesafe/jev-1.13 to select operation and target from the visual action space."""
    targets = {}
    for el in elements:
        app_tag = f"[{el.get('app', 'App')}]"
        targets[el["id"]] = {
            "element": f"[{el['id']}] {app_tag} {el['role']} \"{el['label']}\" at {el['point']}",
            "app": el.get("app", "App"),
            "role": el["role"],
            "coordinates": el["point"]
        }

    operations = {
        "CLICK": "Click an element, button, menu option, tab, or link.",
        "TYPE_TEXT": "Enter text into an editable field, search input, or address bar.",
        "DONE": "Every requirement is visibly satisfied.",
        "BLOCKED": "No supported operation can progress."
    }

    instructions = {
        "goal": goal,
        "context": "Elements are tagged with their owning application (e.g. [Microsoft Edge], [Ghostty]). Choose the element belonging to the application relevant to the goal."
    }

    questions = {
        "operation": {
            "type": "choice",
            "criteria": operations,
            "instructions": instructions
        },
        "click_target": {
            "type": "choice",
            "criteria": targets,
            "instructions": {**instructions, "operation": "CLICK"}
        },
        "type_text_target": {
            "type": "choice",
            "criteria": targets,
            "instructions": {**instructions, "operation": "TYPE_TEXT"}
        }
    }

    payload = {
        "model": "typesafe/jev-1.13",
        "state": {
            "elements": [{"index": el["id"], "app": el.get("app", "App"), "role": el["role"], "label": el["label"]} for el in elements],
            "recent_actions": history[-6:]
        },
        "questions": questions
    }

    resp = httpx.post(DECISIONS_URL, json=payload, headers=HEADERS, timeout=15)
    if not resp.is_success:
        raise RuntimeError(f"Jev API failed: {resp.status_code} {resp.text}")

    data = resp.json()
    answers = data.get("answers", {})
    operation = answers.get("operation", {}).get("choice", "BLOCKED")

    target_id = None
    if operation == "CLICK":
        target_id = answers.get("click_target", {}).get("choice")
    elif operation == "TYPE_TEXT":
        target_id = answers.get("type_text_target", {}).get("choice")

    return operation, target_id

def generate_text(goal: str, field_label: str) -> str:
    """Generates the text string to type into a selected field using gpt-oss-120b:nitro."""
    system_prompt = (
        "Return a JSON object with exactly one key, text: the string to type into the field based on the goal. "
        "For browser address bars or site navigation, return the clean domain name (e.g. 'google.com' or 'wikipedia.org'). Return only: {\"text\": \"query\"}"
    )
    user_content = f"Goal: {goal}\nField: {field_label}"

    payload = {
        "model": "openai/gpt-oss-120b:nitro",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content}
        ],
        "response_format": {"type": "json_object"},
        "reasoning": {"effort": "low"}
    }

    resp = httpx.post(COMPLETIONS_URL, json=payload, headers=HEADERS, timeout=12)
    if resp.is_success:
        try:
            content = resp.json()["choices"][0]["message"]["content"].strip()
            if content.startswith("```"):
                content = content.split("\n", 1)[1].rsplit("```", 1)[0].strip()
            data = json.loads(content)
            return data.get("text", goal)
        except Exception:
            pass
    return goal

def run_visual_task(goal: str):
    print("=" * 60)
    print(f"[Jev Vision] Starting Goal: {goal}")
    print("=" * 60)
    segmenter = UISegmenter()
    history = []

    for step in range(1, 15):
        t_start = time.perf_counter()
        print(f"\n[Step {step}] Capturing screen and segmenting UI...")
        
        analysis = segmenter.analyze("/tmp/jev_screen.png")
        elements = analysis["elements"]
        print(f"  Detected {len(elements)} UI elements (YOLO: {analysis['yolo_ms']}ms, OCR: {analysis['ocr_ms']}ms)")

        if not elements:
            print("  No interactive elements found. Retrying...")
            time.sleep(0.5)
            continue

        op, target_id = query_jev(elements, goal, history)
        elapsed_step = round((time.perf_counter() - t_start) * 1000)
        print(f"  Jev Decision ({elapsed_step}ms): Operation={op}, Target=[{target_id}]")

        if op == "DONE":
            print("\n" + "=" * 60)
            print("[Jev Vision] STATUS: DONE - Goal satisfied!")
            print("=" * 60)
            return True

        if op == "BLOCKED":
            print("[Jev Vision] STATUS: BLOCKED - Jev cannot make further progress.")
            return False

        target = next((el for el in elements if el["id"] == target_id), None)
        if not target:
            print(f"  Target ID {target_id} not found in elements. Retrying...")
            continue

        recent = [h["target"] for h in history[-5:]]
        if len(recent) >= 3 and recent.count(target["label"]) >= 3:
            print(f"  [Jev Vision] Loop detected on '{target['label']}'. Halting.")
            return False

        x, y = target["point"]
        if op == "CLICK":
            print(f"  Action: CLICK {target['role']} \"{target['label']}\" at screen coordinates ({x}, {y})")
            print(f"DISPATCH: {json.dumps({'type': 'click', 'x': x, 'y': y})}", flush=True)
            click_at(x, y)
            history.append({"action": "CLICK", "target": target["label"]})
            time.sleep(1.2)  # allow page transition / click response
        elif op == "TYPE_TEXT":
            text = generate_text(goal, target["label"])
            print(f"  Action: TYPE_TEXT \"{text}\" into {target['role']} \"{target['label']}\" at ({x}, {y})")
            if target["role"] == "addressbar":
                print(f"DISPATCH: {json.dumps({'type': 'replace_text', 'x': x, 'y': y, 'text': text})}", flush=True)
                replace_text_at(x, y, text)
            else:
                print(f"DISPATCH: {json.dumps({'type': 'type_text', 'x': x, 'y': y, 'text': text})}", flush=True)
                click_at(x, y)
                time.sleep(0.1)
                type_text(text)
                press_key("return")
            history.append({"action": "TYPE_TEXT", "target": target["label"], "text": text})
            time.sleep(1.2)  # allow search submit
    print("[Jev Vision] Step budget reached.")
    return False

if __name__ == "__main__":
    user_goal = sys.argv[1] if len(sys.argv) > 1 else "Search for wikipedia"
    success = run_visual_task(user_goal)
    sys.exit(0 if success else 1)
