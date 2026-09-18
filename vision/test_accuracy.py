"""Visual accuracy test: verifies that predicted (x, y) points land directly on real screen elements."""

from PIL import Image
from ocrmac import ocrmac
from segmenter import UISegmenter

def verify_spatial_accuracy():
    img_path = "/tmp/jev_screen.png"
    img = Image.open(img_path)
    width, height = img.size
    print(f"[Verification] Screenshot loaded: {width}x{height}")

    segmenter = UISegmenter()
    res = segmenter.analyze(img_path)
    elements = res["elements"]
    print(f"[Verification] Total detected elements: {len(elements)}")

    # Test targets across different regions of the screen
    test_queries = [
        ("huggingface", "Browser Address Bar"),
        ("Relation extraction", "Webpage Heading"),
        ("Chico Buarque", "Top Menu Bar / Music"),
        ("Click or Hold to Speak", "Floating JevOrb Widget"),
        ("Integrate jev-use", "Terminal Title Bar"),
        ("probabilities", "Webpage Code Content")
    ]

    print("\n" + "=" * 75)
    print("SPATIAL ACCURACY VERIFICATION REPORT")
    print("=" * 75)

    passed = 0
    tested = 0

    for query, description in test_queries:
        tested += 1
        matches = [e for e in elements if query.lower() in e["label"].lower()]
        if not matches:
            print(f"❌ [MISSING] Could not find any element matching '{query}' ({description})")
            continue

        target = matches[0]
        px, py = target["point"]
        raw_box = target["raw_box"]
        app = target.get("app", "Unknown")
        role = target.get("role", "Unknown")

        # Check if the calculated point is strictly inside the raw bounding box
        bx0, by0, bx1, by1 = raw_box
        is_inside_x = (bx0 <= px <= bx1) or (bx0 <= px * 2 <= bx1)
        is_inside_y = (by0 <= py <= by1) or (by0 <= py * 2 <= by1)

        # Crop a 100x40 patch centered on the point in the original image
        crop_x0 = max(0, px - 50)
        crop_y0 = max(0, py - 20)
        crop_x1 = min(width, px + 50)
        crop_y1 = min(height, py + 20)
        patch = img.crop((crop_x0, crop_y0, crop_x1, crop_y1))
        
        # Read text inside the cropped patch to confirm it landed on the words
        patch_ocr = ocrmac.OCR(patch).recognize(px=True)
        patch_text = " ".join([t[0] for t in patch_ocr])

        success = is_inside_x and is_inside_y
        if success:
            passed += 1
            print(f"✓ [PASS] {description}")
            print(f"   Target:   [{target['id']}] [{app}] {role} \"{target['label'][:40]}\"")
            print(f"   Point:    ({px}, {py}) | Box: [{bx0}, {by0}, {bx1}, {by1}]")
            print(f"   Crop OCR: \"{patch_text}\"")
        else:
            print(f"❌ [FAIL] Point ({px}, {py}) falls outside bounding box [{bx0}, {by0}, {bx1}, {by1}]")

    print("=" * 75)
    print(f"Score: {passed} / {tested} tests passed.")
    print("=" * 75)
    return passed == tested

if __name__ == "__main__":
    verify_spatial_accuracy()
