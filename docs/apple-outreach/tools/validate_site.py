#!/usr/bin/env python3
"""Static integrity checks for the public HyperVibe pages.

This deliberately has no third-party dependencies so the outreach package can be
checked before it is sent or published.
"""

from __future__ import annotations

import sys
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[3]
PAGES = (ROOT / "website" / "index.html", ROOT / "website" / "apple" / "index.html")
VIDEO_FLAGS = {"autoplay", "loop", "muted", "playsinline", "data-native-loop"}


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: list[str] = []
        self.refs: list[tuple[str, str, int]] = []
        self.images: list[tuple[dict[str, str | None], int]] = []
        self.videos: list[tuple[dict[str, str | None], int]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        line, _ = self.getpos()
        if identifier := values.get("id"):
            self.ids.append(identifier)
        if tag in {"a", "link"} and (href := values.get("href")):
            self.refs.append((tag, href, line))
        if tag in {"img", "script", "source"} and (src := values.get("src")):
            self.refs.append((tag, src, line))
        if tag == "img":
            self.images.append((values, line))
        if tag == "video":
            self.videos.append((values, line))


def local_path(page: Path, reference: str) -> Path | None:
    parts = urlsplit(reference)
    if parts.scheme or parts.netloc or reference.startswith(("mailto:", "tel:")):
        return None
    if not parts.path:
        return None
    return (page.parent / unquote(parts.path)).resolve()


def validate(page: Path) -> list[str]:
    parser = PageParser()
    parser.feed(page.read_text(encoding="utf-8"))
    failures: list[str] = []

    duplicates = [identifier for identifier, count in Counter(parser.ids).items() if count > 1]
    if duplicates:
        failures.append(f"{page}: duplicate IDs: {', '.join(sorted(duplicates))}")

    known_ids = set(parser.ids)
    for tag, reference, line in parser.refs:
        parts = urlsplit(reference)
        if parts.path in {"", page.name} and parts.fragment and parts.fragment not in known_ids:
            failures.append(f"{page}:{line}: missing fragment target #{parts.fragment}")
        target = local_path(page, reference)
        if target is not None and not target.exists():
            failures.append(f"{page}:{line}: missing local {tag} target: {reference}")

    for attrs, line in parser.images:
        if "alt" not in attrs:
            failures.append(f"{page}:{line}: image is missing alt text")
        if not attrs.get("width") or not attrs.get("height"):
            failures.append(f"{page}:{line}: image is missing intrinsic width/height")

    for attrs, line in parser.videos:
        missing = sorted(flag for flag in VIDEO_FLAGS if flag not in attrs)
        if missing:
            failures.append(f"{page}:{line}: looping video is missing {', '.join(missing)}")
        if attrs.get("preload") != "auto":
            failures.append(f"{page}:{line}: looping video must preload automatically")

    return failures


def main() -> int:
    failures: list[str] = []
    for page in PAGES:
        if not page.exists():
            failures.append(f"missing page: {page}")
            continue
        failures.extend(validate(page))

    if failures:
        print("Site validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"Validated {len(PAGES)} pages: unique IDs, fragments, assets, images, and looped video attributes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
