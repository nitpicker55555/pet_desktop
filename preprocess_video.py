"""
Preprocess video: flood-fill remove white background from edges only.
Outputs PNG sequence with alpha, then FFmpeg assembles to ProRes 4444.
"""

import cv2
import numpy as np
import subprocess
import os
import sys
from collections import deque

INPUT_VIDEO = "/Users/puzhen/Downloads/jimeng-2026-02-27-6473-小猫咪跑去偷小鱼干吃，吃完以后回来站在原地.mp4"
OUTPUT_VIDEO = "/Users/puzhen/Documents/cat_desktop/cat_desktop/Resources/cat_animation.mov"
TEMP_DIR = "/tmp/cat_frames"

WHITENESS_THRESHOLD = 0.75
ALPHA_UPPER = 0.95
ALPHA_RANGE = 0.20


def is_whiteish(r, g, b):
    brightness = (r + g + b) / 3.0
    saturation = max(r, g, b) - min(r, g, b)
    return (brightness - saturation * 0.3) > WHITENESS_THRESHOLD * 255


def flood_fill_remove_white(frame_bgr):
    h, w = frame_bgr.shape[:2]
    b, g, r = frame_bgr[:, :, 0], frame_bgr[:, :, 1], frame_bgr[:, :, 2]

    # Compute whiteness mask (vectorized)
    brightness = (r.astype(np.float32) + g.astype(np.float32) + b.astype(np.float32)) / 3.0
    sat = np.maximum(r, np.maximum(g, b)).astype(np.float32) - np.minimum(r, np.minimum(g, b)).astype(np.float32)
    whiteness = brightness - sat * 0.3
    white_mask = whiteness > (WHITENESS_THRESHOLD * 255)

    # BFS flood fill from edges
    is_bg = np.zeros((h, w), dtype=bool)
    queue = deque()

    # Seed border pixels
    for x in range(w):
        if white_mask[0, x]:
            is_bg[0, x] = True
            queue.append((0, x))
        if white_mask[h - 1, x]:
            is_bg[h - 1, x] = True
            queue.append((h - 1, x))
    for y in range(1, h - 1):
        if white_mask[y, 0]:
            is_bg[y, 0] = True
            queue.append((y, 0))
        if white_mask[y, w - 1]:
            is_bg[y, w - 1] = True
            queue.append((y, w - 1))

    # BFS
    while queue:
        cy, cx = queue.popleft()
        for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            ny, nx = cy + dy, cx + dx
            if 0 <= ny < h and 0 <= nx < w and not is_bg[ny, nx] and white_mask[ny, nx]:
                is_bg[ny, nx] = True
                queue.append((ny, nx))

    # Build alpha channel
    alpha = np.full((h, w), 255, dtype=np.uint8)
    bg_whiteness = whiteness[is_bg]
    alpha_float = np.clip((ALPHA_UPPER * 255 - bg_whiteness) / (ALPHA_RANGE * 255), 0.0, 1.0)
    alpha[is_bg] = (alpha_float * 255).astype(np.uint8)

    # Premultiply RGB by alpha
    result = np.zeros((h, w, 4), dtype=np.uint8)
    alpha_norm = alpha.astype(np.float32) / 255.0
    result[:, :, 0] = (b * alpha_norm).astype(np.uint8)
    result[:, :, 1] = (g * alpha_norm).astype(np.uint8)
    result[:, :, 2] = (r * alpha_norm).astype(np.uint8)
    result[:, :, 3] = alpha

    return result


def main():
    os.makedirs(TEMP_DIR, exist_ok=True)

    cap = cv2.VideoCapture(INPUT_VIDEO)
    fps = cap.get(cv2.CAP_PROP_FPS)
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    print(f"Input: {total} frames @ {fps:.2f} fps")

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        result = flood_fill_remove_white(frame)
        # OpenCV expects BGRA for PNG with alpha
        bgra = result.copy()
        bgra[:, :, 0], bgra[:, :, 2] = result[:, :, 2], result[:, :, 0]  # swap R and B back to BGR
        # Actually result is already B,G,R,A from the processing, but let's be explicit
        out_bgra = np.zeros_like(result)
        out_bgra[:, :, 0] = result[:, :, 0]  # B
        out_bgra[:, :, 1] = result[:, :, 1]  # G
        out_bgra[:, :, 2] = result[:, :, 2]  # R -> need as B for cv2
        out_bgra[:, :, 3] = result[:, :, 3]  # A

        # result is [B_premul, G_premul, R_premul, A] - but cv2 imwrite expects BGRA
        # Our result: [0]=B, [1]=G, [2]=R, [3]=A  -> need BGRA: [0]=B, [1]=G, [2]=R, [3]=A
        # Actually cv2.imwrite with PNG saves BGRA correctly when 4-channel
        cv2.imwrite(f"{TEMP_DIR}/frame_{frame_idx:05d}.png", result)
        frame_idx += 1
        if frame_idx % 10 == 0:
            print(f"  Processed {frame_idx}/{total} frames")

    cap.release()
    print(f"Processed {frame_idx} frames total")

    # Assemble to ProRes 4444 with alpha using FFmpeg
    print("Assembling ProRes 4444 video...")
    cmd = [
        "ffmpeg", "-y",
        "-framerate", str(fps),
        "-i", f"{TEMP_DIR}/frame_%05d.png",
        "-c:v", "prores_ks", "-profile:v", "4444",
        "-pix_fmt", "yuva444p10le",
        "-an",
        OUTPUT_VIDEO,
    ]
    subprocess.run(cmd, check=True)

    # Cleanup temp frames
    for f in os.listdir(TEMP_DIR):
        os.remove(os.path.join(TEMP_DIR, f))
    os.rmdir(TEMP_DIR)

    size_mb = os.path.getsize(OUTPUT_VIDEO) / (1024 * 1024)
    print(f"Done! Output: {OUTPUT_VIDEO} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
