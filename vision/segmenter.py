# @acid: VISION-1, VISION-2, VISION-3, VISION-4, FUSION-1, FUSION-2, FUSION-3, FUSION-4
"""On-device UI element segmentation, spatial OCR fusion, and window ownership tagging."""

import os
import subprocess
import time
from pathlib import Path
from PIL import Image
from ultralytics import YOLO
from ocrmac import ocrmac
from huggingface_hub import hf_hub_download
import Quartz.CoreGraphics as CG

MODEL_REPO = "MacPaw/yolov11l-ui-elements-detection"
MODEL_FILE = "ui-elements-detection.pt"

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
        model_path = hf_hub_download(repo_id=MODEL_REPO, filename=MODEL_FILE)
        self.model = YOLO(model_path)
        self.classes = self.model.names

    def capture_screen(self, output_path: str = "/tmp/jev_screen.png") -> str:
        """Capture the current screen if not already provided."""
        if not os.path.exists(output_path) or (time.time() - os.path.getmtime(output_path) > 2.0):
            subprocess.run(["screencapture", "-x", output_path], check=True)
        return output_path

    def analyze(self, image_path: str = "/tmp/jev_screen.png") -> dict:
        """Runs YOLO UI detection + Apple Vision OCR and tags each element with its owning app."""
        if not os.path.exists(image_path):
            image_path = self.capture_screen(image_path)

        img = Image.open(image_path)
        width, height = img.size

        # Retina scale factor (Retina display images are 2x logical points)
        retina_factor = 2.0 if width > 2000 else 1.0

        # Query on-screen window boundaries
        windows = get_on_screen_windows()

        t0 = time.perf_counter()
        yolo_res = self.model(img, verbose=False)[0]
        t_yolo = time.perf_counter() - t0

        t0 = time.perf_counter()
        ocr_res = ocrmac.OCR(img, language_preference=['en-US']).recognize(px=True)
        t_ocr = time.perf_counter() - t0

        boxes = yolo_res.boxes
        elements = []
        covered_ocr = set()

        for i, box in enumerate(boxes):
            cls_id = int(box.cls[0].item())
            role_raw = self.classes.get(cls_id, "AXElement")
            role = role_raw.replace("AX", "").lower()
            conf = float(box.conf[0].item())
            
            bx0, by0, bx1, by1 = [int(v) for v in box.xyxy[0].tolist()]

            matched_words = []
            for idx, (text, conf_ocr, (ox, oy, ow, oh)) in enumerate(ocr_res):
                ix0, iy0 = max(bx0, ox), max(by0, oy)
                ix1, iy1 = min(bx1, ox + ow), min(by1, oy + oh)
                iw, ih = max(0, ix1 - ix0), max(0, iy1 - iy0)
                area = iw * ih
                if (ow * oh) > 0 and (area / float(ow * oh)) > 0.4:
                    matched_words.append(text.strip())
                    covered_ocr.add(idx)
            logical_mid_x = int(((bx0 + bx1) / 2.0) / retina_factor)
            logical_mid_y = int(((by0 + by1) / 2.0) / retina_factor)
            app_name = resolve_app(logical_mid_x, logical_mid_y, windows)

            label = " ".join(matched_words) if matched_words else ""
            if "http" in label or "www." in label or ".co" in label or ".com" in label or ".org" in label:
                role = "addressbar"

            if not label and role == "textarea":
                label = "input field"

            if label or role in {"button", "link", "textarea", "addressbar", "disclosuretriangle"}:
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

        # Include standalone OCR elements not captured by YOLO (tagged with owning app)
        for idx, (text, conf_ocr, (ox, oy, ow, oh)) in enumerate(ocr_res):
            clean = text.strip()
            if idx not in covered_ocr and len(clean) > 1:
                logical_mid_x = int((ox + ow / 2.0) / retina_factor)
                logical_mid_y = int((oy + oh / 2.0) / retina_factor)
                app_name = resolve_app(logical_mid_x, logical_mid_y, windows)
                
                is_url = ("http" in clean or "www." in clean or ".co" in clean or ".com" in clean or ".org" in clean)
                role = "addressbar" if is_url else "link"
                element_id = str(len(elements) + 1)
                elements.append({
                    "id": element_id,
                    "app": app_name,
                    "role": role,
                    "label": clean,
                    "point": [logical_mid_x, logical_mid_y],
                    "raw_box": [int(ox), int(oy), int(ox + ow), int(oy + oh)],
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
