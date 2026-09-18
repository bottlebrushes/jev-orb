# @acid: VISION-1, VISION-2, VISION-3, VISION-4, FUSION-1, FUSION-2, FUSION-3, FUSION-4
"""On-device UI element segmentation and spatial OCR fusion."""

import os
import subprocess
import time
from pathlib import Path
from PIL import Image
from ultralytics import YOLO
from ocrmac import ocrmac
from huggingface_hub import hf_hub_download

MODEL_REPO = "MacPaw/yolov11l-ui-elements-detection"
MODEL_FILE = "ui-elements-detection.pt"

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
        """Runs YOLO UI detection + Apple Vision OCR on the captured screen."""
        if not os.path.exists(image_path):
            image_path = self.capture_screen(image_path)

        img = Image.open(image_path)
        width, height = img.size

        # Retina scale detection (macOS Retina displays are 2x logical points)
        retina_factor = 2.0 if width > 2000 else 1.0

        t0 = time.perf_counter()
        yolo_res = self.model(img, verbose=False)[0]
        t_yolo = time.perf_counter() - t0

        t0 = time.perf_counter()
        ocr_res = ocrmac.OCR(img, language_preference=['en-US']).recognize(px=True)
        t_ocr = time.perf_counter() - t0

        boxes = yolo_res.boxes
        elements = []

        for i, box in enumerate(boxes):
            cls_id = int(box.cls[0].item())
            role_raw = self.classes.get(cls_id, "AXElement")
            role = role_raw.replace("AX", "").lower()
            conf = float(box.conf[0].item())
            
            bx0, by0, bx1, by1 = [int(v) for v in box.xyxy[0].tolist()]

            matched_words = []
            for text, conf_ocr, (ox, oy, ow, oh) in ocr_res:
                if not (ox + ow < bx0 - 5 or ox > bx1 + 5 or oy + oh < by0 - 5 or oy > by1 + 5):
                    matched_words.append(text.strip())

            label = " ".join(matched_words) if matched_words else ""
            if not label and role == "textarea":
                label = "search/text input"

            # Convert retina image pixels to logical screen coordinates for Quartz mouse clicks
            logical_mid_x = int(((bx0 + bx1) / 2.0) / retina_factor)
            logical_mid_y = int(((by0 + by1) / 2.0) / retina_factor)

            if label or role in {"button", "link", "textarea", "disclosuretriangle"}:
                element_id = str(len(elements) + 1)
                elements.append({
                    "id": element_id,
                    "role": role,
                    "label": label if label else f"({role})",
                    "point": [logical_mid_x, logical_mid_y],
                    "raw_box": [bx0, by0, bx1, by1],
                    "confidence": conf
                })

        return {
            "image_path": image_path,
            "width": width,
            "height": height,
            "yolo_ms": round(t_yolo * 1000),
            "ocr_ms": round(t_ocr * 1000),
            "elements": elements
        }
