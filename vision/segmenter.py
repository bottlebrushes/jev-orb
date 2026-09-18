# @acid: VISION-1, VISION-2, VISION-3, VISION-4, FUSION-1, FUSION-2, FUSION-3, FUSION-4
"""Dual-model on-device UI element + group segmentation and spatial OCR fusion."""

import os
import subprocess
import time
from pathlib import Path
from PIL import Image
from ultralytics import YOLO
from ocrmac import ocrmac
from huggingface_hub import hf_hub_download
import Quartz.CoreGraphics as CG

ELEMENTS_REPO = "MacPaw/yolov11l-ui-elements-detection"
ELEMENTS_FILE = "ui-elements-detection.pt"

GROUPS_REPO = "MacPaw/yolov11l-ui-groups-detection"
GROUPS_FILE = "ui-groups-detection.pt"

def get_on_screen_windows():
    """Retrieve on-screen application windows and their bounding rectangles."""
    windows = []
    try:
        raw = CG.CGWindowListCopyWindowInfo(CG.kCGWindowListOptionOnScreenOnly, CG.kCGNullWindowID)
        for w in raw:
            layer = w.get("kCGWindowLayer", 0)
            b = w.get("kCGWindowBounds", {})
            width = b.get("Width", 0)
            height = b.get("Height", 0)
            owner = w.get("kCGWindowOwnerName", "")
            if layer == 0 and width > 120 and height > 120:
                windows.append({
                    "app": owner,
                    "rect": (b.get("X", 0), b.get("Y", 0), width, height)
                })
    except Exception:
        pass
    return windows

def resolve_app(x: int, y: int, windows: list) -> str:
    """Find which application window owns the coordinate (x, y)."""
    for w in windows:
        wx, wy, ww, wh = w["rect"]
        if wx <= x <= wx + ww and wy <= y <= wy + wh:
            return w["app"]
    return "Desktop"

class UISegmenter:
    def __init__(self):
        # Load both Screen2AX models: elements (icons/buttons) and groups (containers/address bars)
        elements_path = hf_hub_download(repo_id=ELEMENTS_REPO, filename=ELEMENTS_FILE)
        groups_path = hf_hub_download(repo_id=GROUPS_REPO, filename=GROUPS_FILE)
        
        self.elements_model = YOLO(elements_path)
        self.groups_model = YOLO(groups_path)

    def analyze(self, image_path: str = "/tmp/jev_screen.png") -> dict:
        """Runs dual YOLO detection + Apple Vision OCR on the captured screen."""
        if not os.path.exists(image_path):
            return {"image_path": image_path, "width": 0, "height": 0, "yolo_ms": 0, "ocr_ms": 0, "elements": []}
        img = Image.open(image_path)
        width, height = img.size
        retina_factor = 2.0 if width > 2000 else 1.0
        windows = get_on_screen_windows()

        t0 = time.perf_counter()
        # 1. Detect UI elements (icons, buttons, links, textareas)
        el_boxes = self.elements_model(img, verbose=False)[0].boxes
        # 2. Detect UI groups & containers (address bars, cards, input groups)
        grp_boxes = self.groups_model(img, verbose=False)[0].boxes
        t_yolo = time.perf_counter() - t0

        t0 = time.perf_counter()
        # 3. Apple Vision on-device OCR
        ocr_res = ocrmac.OCR(img, language_preference=['en-US']).recognize(px=True)
        t_ocr = time.perf_counter() - t0

        # Combine detected boxes
        all_detected = []
        for b in el_boxes:
            cls_name = self.elements_model.names[int(b.cls[0].item())].replace("AX", "").lower()
            all_detected.append((cls_name, float(b.conf[0].item()), [int(v) for v in b.xyxy[0].tolist()]))

        for b in grp_boxes:
            cls_name = self.groups_model.names[int(b.cls[0].item())].replace("AX", "").lower()
            all_detected.append((f"container/{cls_name}", float(b.conf[0].item()), [int(v) for v in b.xyxy[0].tolist()]))

        elements = []
        covered_ocr = set()

        for role_raw, conf, (bx0, by0, bx1, by1) in all_detected:
            # Match OCR text overlapping this detected boundary
            matched_words = []
            for idx, (text, conf_ocr, (ox1, oy1, ox2, oy2)) in enumerate(ocr_res):
                ix0, iy0 = max(bx0, ox1), max(by0, oy1)
                ix1, iy1 = min(bx1, ox2), min(by1, oy2)
                iw, ih = max(0, ix1 - ix0), max(0, iy1 - iy0)
                area = iw * ih
                text_area = max(1.0, (ox2 - ox1) * (oy2 - oy1))
                if (area / text_area) > 0.35:
                    matched_words.append(text.strip())
                    covered_ocr.add(idx)

            label = " ".join(matched_words)
            logical_mid_x = int(((bx0 + bx1) / 2.0) / retina_factor)
            logical_mid_y = int(((by0 + by1) / 2.0) / retina_factor)
            app_name = resolve_app(logical_mid_x, logical_mid_y, windows)
            role = role_raw

            if not label and "container" in role:
                continue

            if not label and role == "textarea":
                label = "input field"

            if label or role in {"button", "link", "textarea"}:
                element_id = str(len(elements) + 1)
                elements.append({
                    "id": element_id,
                    "app": app_name,
                    "role": role,
                    "label": label if label else f"({role})",
                    "point": [logical_mid_x, logical_mid_y],
                    "raw_box": [bx0, by0, bx1, by1],
                    "confidence": conf
                })

        # Standalone OCR text not captured by any model
        for idx, (text, conf_ocr, (ox1, oy1, ox2, oy2)) in enumerate(ocr_res):
            clean = text.strip()
            if idx not in covered_ocr and len(clean) > 1:
                logical_mid_x = int(((ox1 + ox2) / 2.0) / retina_factor)
                logical_mid_y = int(((oy1 + oy2) / 2.0) / retina_factor)
                app_name = resolve_app(logical_mid_x, logical_mid_y, windows)
                
                element_id = str(len(elements) + 1)
                elements.append({
                    "id": element_id,
                    "app": app_name,
                    "role": "text/link",
                    "label": clean,
                    "point": [logical_mid_x, logical_mid_y],
                    "raw_box": [int(ox1), int(oy1), int(ox2), int(oy2)],
                    "confidence": float(conf_ocr)
                })

        return {
            "image_path": image_path,
            "width": width,
            "height": height,
            "yolo_ms": round(t_yolo * 1000),
            "ocr_ms": round(t_ocr * 1000),
            "elements": elements
        }
