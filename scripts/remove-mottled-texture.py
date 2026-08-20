#!/usr/bin/env python3
"""Reduce low-contrast AI texture while preserving anime line art."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


def box_blur(values: np.ndarray, radius: int) -> np.ndarray:
    if radius <= 0:
        return values.astype(np.float32, copy=True)
    diameter = radius * 2 + 1
    padded = np.pad(values, ((radius, radius), (radius, radius)), mode="reflect")
    integral = np.pad(padded, ((1, 0), (1, 0)), mode="constant")
    integral = np.cumsum(np.cumsum(integral, axis=0, dtype=np.float64), axis=1, dtype=np.float64)
    total = (
        integral[diameter:, diameter:]
        - integral[:-diameter, diameter:]
        - integral[diameter:, :-diameter]
        + integral[:-diameter, :-diameter]
    )
    return np.asarray(total / float(diameter * diameter), dtype=np.float32)


def guided_filter(guide: np.ndarray, source: np.ndarray, radius: int, epsilon: float) -> np.ndarray:
    mean_guide = box_blur(guide, radius)
    mean_source = box_blur(source, radius)
    correlation = box_blur(guide * source, radius)
    variance = box_blur(guide * guide, radius) - mean_guide * mean_guide
    covariance = correlation - mean_guide * mean_source

    coefficient = covariance / (variance + epsilon)
    intercept = mean_source - coefficient * mean_guide
    return box_blur(coefficient, radius) * guide + box_blur(intercept, radius)


def luminance(rgb: np.ndarray) -> np.ndarray:
    return 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]


def gaussian_blur(values: np.ndarray, radius: float) -> np.ndarray:
    image = Image.fromarray(np.uint8(np.clip(values * 255.0 + 0.5, 0, 255)), mode="L")
    return np.asarray(image.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255.0


def edge_protection(guide: np.ndarray) -> np.ndarray:
    edge_image = Image.fromarray(np.uint8(np.clip(guide * 255.0, 0, 255)), mode="L")
    edges = np.asarray(
        edge_image.filter(ImageFilter.FIND_EDGES).filter(ImageFilter.GaussianBlur(0.7)),
        dtype=np.float32,
    ) / 255.0
    return np.clip((edges - 0.025) / 0.16, 0.0, 1.0)


def flatten_neutral_background(cleaned: np.ndarray) -> None:
    minimum = cleaned.min(axis=2)
    chroma = cleaned.max(axis=2) - minimum
    neutral_white = (minimum > 0.972) & (chroma < 0.018)
    cleaned[neutral_white] = 1.0


def restore_source_alpha(source: Image.Image, cleaned: Image.Image) -> Image.Image:
    """Keep transparent sprite edges unchanged while filtering only RGB texture."""
    if "A" not in source.getbands():
        return cleaned
    result = cleaned.convert("RGBA")
    result.putalpha(source.getchannel("A"))
    return result


def clean_legacy(source: Image.Image, radius: int, epsilon: float, strength: float) -> Image.Image:
    rgb = np.asarray(source.convert("RGB"), dtype=np.float32) / 255.0
    guide = luminance(rgb)

    filtered = np.empty_like(rgb)
    for channel in range(3):
        filtered[..., channel] = guided_filter(guide, rgb[..., channel], radius, epsilon)

    # Protect strong ink lines and tiny facial details from the smoothing blend.
    blend = strength * (1.0 - 0.88 * edge_protection(guide))
    cleaned = rgb * (1.0 - blend[..., None]) + filtered * blend[..., None]

    flatten_neutral_background(cleaned)

    return Image.fromarray(np.uint8(np.clip(cleaned * 255.0 + 0.5, 0, 255)), mode="RGB")


def clean_highlight_safe(
    source: Image.Image,
    radius: int,
    epsilon: float,
    strength: float,
    highlight_radius: float,
) -> Image.Image:
    """Suppress mottling while retaining coherent glossy highlight bands."""
    rgb = np.asarray(source.convert("RGB"), dtype=np.float32) / 255.0
    guide = luminance(rgb)

    # Two smoothing scales: the small scale removes speckles, while a restrained
    # amount of the medium scale reduces patchiness without flattening volumes.
    micro = np.empty_like(rgb)
    medium = np.empty_like(rgb)
    for channel in range(3):
        micro[..., channel] = guided_filter(guide, rgb[..., channel], max(2, radius // 2), epsilon * 0.55)
        medium[..., channel] = guided_filter(guide, rgb[..., channel], radius, epsilon)
    filtered = 0.72 * micro + 0.28 * medium

    # A glossy highlight is brighter than its broad neighbourhood and remains
    # coherent after a small blur. Isolated texture does not survive this test.
    broad_tone = gaussian_blur(guide, highlight_radius)
    positive_salience = np.maximum(guide - broad_tone, 0.0)
    coherent_highlight = gaussian_blur(positive_salience, 2.2)
    highlight_protection = np.clip((coherent_highlight - 0.004) / 0.028, 0.0, 1.0)
    highlight_protection = gaussian_blur(highlight_protection, 1.2)

    ink_protection = edge_protection(guide)
    protection = np.maximum(0.92 * ink_protection, 0.96 * highlight_protection)
    blend = strength * (1.0 - protection)
    cleaned = rgb * (1.0 - blend[..., None]) + filtered * blend[..., None]

    flatten_neutral_background(cleaned)

    return Image.fromarray(np.uint8(np.clip(cleaned * 255.0 + 0.5, 0, 255)), mode="RGB")


def clean_then_restore_highlights(
    source: Image.Image,
    radius: int,
    epsilon: float,
    strength: float,
    highlight_radius: float,
    restore_strength: float,
) -> Image.Image:
    """Use the strong legacy cleanup, then restore only coherent highlight bands."""
    base_image = clean_legacy(source, radius, epsilon, strength)
    original = np.asarray(source.convert("RGB"), dtype=np.float32) / 255.0
    cleaned = np.asarray(base_image, dtype=np.float32) / 255.0
    original_luma = luminance(original)
    cleaned_luma = luminance(cleaned)

    # Compare medium-scale luminance bands. Fine texture disappears in the
    # initial blur, while the long glossy streaks remain measurable.
    original_band = gaussian_blur(original_luma, 3.0) - gaussian_blur(original_luma, highlight_radius)
    cleaned_band = gaussian_blur(cleaned_luma, 3.0) - gaussian_blur(cleaned_luma, highlight_radius)
    lost_highlight = np.maximum(original_band - cleaned_band, 0.0)

    coherent = gaussian_blur(np.maximum(original_band, 0.0), 2.5)
    coherence_mask = np.clip((coherent - 0.003) / 0.025, 0.0, 1.0)

    # Limit restoration to dark, low-chroma materials such as tights, the
    # glossy suit, ears, and shoes. Skin and the white background stay clean.
    chroma = original.max(axis=2) - original.min(axis=2)
    dark_material = np.clip((0.72 - original_luma) / 0.16, 0.0, 1.0)
    neutral_material = np.clip((0.20 - chroma) / 0.10, 0.0, 1.0)
    material_mask = gaussian_blur(dark_material * neutral_material, 1.2)

    restored_luma = lost_highlight * coherence_mask * material_mask * restore_strength
    restored = cleaned + restored_luma[..., None]
    flatten_neutral_background(restored)
    return Image.fromarray(np.uint8(np.clip(restored * 255.0 + 0.5, 0, 255)), mode="RGB")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--mode",
        choices=("restore-highlights", "highlight-safe", "legacy"),
        default="restore-highlights",
    )
    parser.add_argument("--radius", type=int, default=5)
    parser.add_argument("--epsilon", type=float, default=0.0018)
    parser.add_argument("--strength", type=float, default=0.82)
    parser.add_argument("--highlight-radius", type=float, default=18.0)
    parser.add_argument("--restore-strength", type=float, default=1.0)
    args = parser.parse_args()

    source = Image.open(args.input)
    if args.mode == "legacy":
        result = clean_legacy(source, args.radius, args.epsilon, args.strength)
    elif args.mode == "highlight-safe":
        result = clean_highlight_safe(
            source,
            args.radius,
            args.epsilon,
            args.strength,
            args.highlight_radius,
        )
    else:
        result = clean_then_restore_highlights(
            source,
            args.radius,
            args.epsilon,
            args.strength,
            args.highlight_radius,
            args.restore_strength,
        )
    result = restore_source_alpha(source, result)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    result.save(args.output, optimize=True)
    print(args.output)


if __name__ == "__main__":
    main()
