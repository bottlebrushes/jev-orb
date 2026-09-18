# @acid: DISPATCH-1, DISPATCH-5, UX-1, UX-2
"""Vision-driven autonomous browser loop with Jev and Quartz event dispatch."""

import os
import sys
import time
import json
import httpx
from pathlib import Path
from segmenter import UISegmenter
from driver import click_at, type_text, press_key

OPENROUTER_KEY = None
# Resolve key from ~/.omp/agent/.env if not in environment
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
        targets[el["id"]] = {
            "element": f"[{el['id']}] {el['role']} \"{el['label']}\"",
            "role": el["role"],
            "coordinates": el["point"]
        }

    operations = {
        "CLICK": "Click an element, button, menu option, or link.",
        "TYPE_TEXT": "Enter or replace text in an editable field or search box.",
        "DONE": "Every requirement is visibly satisfied.",
        "BLOCKED": "No supported operation can progress."
    }

    questions = {
        "operation": {
            "type": "choice",
            "criteria": operations,
            "instructions": {"goal": goal}
        },
        "click_target": {
            "type": "choice",
            "criteria": targets,
            "instructions": {"goal": goal, "operation": "CLICK"}
        },
        "type_text_target": {
            "type": "choice",
            "criteria": targets,
            "instructions": {"goal": goal, "operation": "TYPE_TEXT"}
        }
    }

    payload = {
        "model": "typesafe/jev-1.13",
        "state": {
            "elements": [{"index": el["id"], "role": el["role"], "label": el["label"]} for el in elements],
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
        "For search boxes, infer the search query. Return only: {\"text\": \"query\"}"
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

def detect_target_url(goal: str) -> str:
    """Extracts target URL if goal is or begins with a navigation request."""
    g_lower = goal.lower().strip()
    if "http://" in g_lower or "https://" in g_lower:
        for word in goal.split():
            if word.startswith("http://") or word.startswith("https://"):
                return word
    if "google.com" in g_lower or "go to google" in g_lower or "open google" in g_lower:
        return "https://www.google.com"
    if "youtube.com" in g_lower or ("youtube" in g_lower and any(w in g_lower for w in ["open", "go to"])):
        return "https://www.youtube.com"
    if "wikipedia.org" in g_lower or ("wikipedia" in g_lower and any(w in g_lower for w in ["open", "go to"])):
        return "https://www.wikipedia.org"
    if "reddit.com" in g_lower or ("reddit" in g_lower and any(w in g_lower for w in ["open", "go to"])):
        return "https://www.reddit.com"
    if "github.com" in g_lower or ("github" in g_lower and any(w in g_lower for w in ["open", "go to"])):
        return "https://www.github.com"
    if "hacker news" in g_lower or "ycombinator" in g_lower:
        return "https://news.ycombinator.com"
    return None

def run_visual_task(goal: str):
    print("=" * 60)
    print(f"[Jev Vision] Starting Goal: {goal}")
    print("=" * 60)

    # 1. Handle navigation intent if goal requests opening a website
    target_url = detect_target_url(goal)
    if target_url:
        print(f"[Jev Vision] Navigating browser to: {target_url}")
        try:
            from browser_harness.admin import ensure_daemon
            from browser_harness.helpers import cdp
            ensure_daemon()
            cdp("Page.navigate", url=target_url)
            time.sleep(1.2)
        except Exception as e:
            print(f"[Jev Vision] CDP navigate error: {e}")

        # If the goal was purely a navigation command, we are done
        g_clean = goal.lower().strip()
        nav_keywords = ["go to", "open", "navigate to", "can you go to", "please go to"]
        is_pure_nav = any(g_clean == f"{kw} google" or g_clean == f"{kw} youtube" or g_clean == f"{kw} wikipedia" or g_clean == f"{kw} reddit" or g_clean == f"{kw} github" for kw in nav_keywords) or g_clean in {"go to google", "open google", "can you go to google?", "google.com", "can you open google?"}
        if is_pure_nav:
            print("\n" + "=" * 60)
            print("[Jev Vision] STATUS: DONE - Navigated to requested site!")
            print("=" * 60)
            return True

    segmenter = UISegmenter()
    history = []

    for step in range(1, 15):
        t_start = time.perf_counter()
        print(f"\n[Step {step}] Capturing screen and segmenting UI...")
        
        analysis = segmenter.analyze()
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
            click_at(x, y)
            history.append({"action": "CLICK", "target": target["label"]})
            time.sleep(1.2)  # allow page transition / click response
        elif op == "TYPE_TEXT":
            text = generate_text(goal, target["label"])
            click_at(x, y)
            time.sleep(0.1)
            type_text(text)
            press_key("return")
            history.append({"action": "TYPE_TEXT", "target": target["label"], "text": text})
            time.sleep(0.8)  # allow search submit

    print("[Jev Vision] Step budget reached.")
    return False

if __name__ == "__main__":
    user_goal = sys.argv[1] if len(sys.argv) > 1 else "Search Google for wikipedia and click the Wikipedia link"
    success = run_visual_task(user_goal)
    sys.exit(0 if success else 1)
