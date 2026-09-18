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
        # Load cached model or download if first run
        model_path = hf_hub_download(repo_id=MODEL_REPO, filename=MODEL_FILE)
        self.model = YOLO(model_path)
        self.classes = self.model.names

    def capture_screen(self, output_path: str = "/tmp/jev_screen.png") -> str:
        """Capture the current active screen using screencapture."""
        subprocess.run(["screencapture", "-x", output_path], check=True)
        return output_path

    def analyze(self, image_path: str = None) -> dict:
        """Runs YOLO UI detection + Apple Vision OCR and fuses them into an indexed action space."""
        if not image_path:
            image_path = self.capture_screen()

        img = Image.open(image_path)
        width, height = img.size

        # Retina scale detection (standard Mac displays are 2x)
        # We need logical desktop coordinates for mouse clicks
        scale_x = width / 1440.0 if width > 2000 else 1.0
        scale_y = height / 900.0 if height > 1400 else 1.0
        # If scale is close to 2.0 (Retina display), normalize to logical points
        retina_factor = 2.0 if width > 2000 else 1.0

        t0 = time.perf_counter()
        yolo_res = self.model(img, verbose=False)[0]
        t_yolo = time.perf_counter() - t0

        t0 = time.perf_counter()
        # ocrmac runs native macOS Apple Vision VNRecognizeTextRequest
        ocr_res = ocrmac.OCR(img, language_preference=['en-US']).recognize(px=True)
        t_ocr = time.perf_counter() - t0

        boxes = yolo_res.boxes
        elements = []

        for i, box in enumerate(boxes):
            cls_id = int(box.cls[0].item())
            role_raw = self.classes.get(cls_id, "AXElement")
            role = role_raw.replace("AX", "").lower()
            conf = float(box.conf[0].item())
            
            # Pixel bounding box in image coordinates [x0, y0, x1, y1]
            bx0, by0, bx1, by1 = [int(v) for v in box.xyxy[0].tolist()]

            # Find all OCR texts that fall within or intersect this bounding box
            matched_words = []
            for text, conf_ocr, (ox, oy, ow, oh) in ocr_res:
                # check overlap
                if not (ox + ow < bx0 - 5 or ox > bx1 + 5 or oy + oh < by0 - 5 or oy > by1 + 5):
                    matched_words.append(text.strip())

            label = " ".join(matched_words) if matched_words else ""
            if not label and role == "textarea":
                label = "input field"

            # Logical screen coordinates for click dispatch
            logical_mid_x = int(((bx0 + bx1) / 2.0) / retina_factor)
            logical_mid_y = int(((by0 + by1) / 2.0) / retina_factor)

            # Only include elements with valid labels or interactive roles
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
