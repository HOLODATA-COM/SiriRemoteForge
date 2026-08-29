#!/usr/bin/env python3
"""Render a repository's GitHub star history as light and dark SVG charts."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request


GRAPHQL_ENDPOINT = "https://api.github.com/graphql"
GRAPHQL_QUERY = """
query StarHistory($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    stargazers(
      first: 100
      after: $cursor
      orderBy: {field: STARRED_AT, direction: ASC}
    ) {
      totalCount
      edges { starredAt }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"""


THEMES = {
    "light": {
        "background": "#ffffff",
        "border": "#d0d7de",
        "grid": "#d8dee4",
        "text": "#1f2328",
        "muted": "#656d76",
        "line": "#ff6b57",
        "area_top": "#ff806b",
        "area_bottom": "#ffddd7",
        "badge": "#fff1ef",
    },
    "dark": {
        "background": "#0d1117",
        "border": "#30363d",
        "grid": "#30363d",
        "text": "#f0f6fc",
        "muted": "#8b949e",
        "line": "#ff7b68",
        "area_top": "#c94f43",
        "area_bottom": "#351b1a",
        "badge": "#2d1b1a",
    },
}


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="GitHub repository in owner/name form")
    parser.add_argument("--output-light", required=True, type=Path)
    parser.add_argument("--output-dark", required=True, type=Path)
    return parser.parse_args()


def parse_repository(repository: str) -> tuple[str, str]:
    parts = repository.strip().split("/")
    if len(parts) != 2 or not all(parts):
        raise ValueError("--repo must use the owner/name format")
    return parts[0], parts[1]


def fetch_star_timestamps(owner: str, name: str, token: str) -> tuple[list[dt.datetime], int]:
    timestamps: list[dt.datetime] = []
    cursor: str | None = None
    total_count = 0

    while True:
        payload = json.dumps(
            {
                "query": GRAPHQL_QUERY,
                "variables": {"owner": owner, "name": name, "cursor": cursor},
            }
        ).encode("utf-8")
        request = urllib.request.Request(
            GRAPHQL_ENDPOINT,
            data=payload,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "User-Agent": "HyperVibe-Star-History",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GitHub GraphQL request failed ({error.code}): {detail}") from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"GitHub GraphQL request failed: {error.reason}") from error

        if result.get("errors"):
            messages = "; ".join(item.get("message", "Unknown GraphQL error") for item in result["errors"])
            raise RuntimeError(f"GitHub GraphQL error: {messages}")

        repository = result.get("data", {}).get("repository")
        if repository is None:
            raise RuntimeError(f"Repository {owner}/{name} was not found or is inaccessible")

        stargazers = repository["stargazers"]
        total_count = int(stargazers["totalCount"])
        for edge in stargazers["edges"]:
            value = edge.get("starredAt")
            if value:
                timestamps.append(dt.datetime.fromisoformat(value.replace("Z", "+00:00")))

        page_info = stargazers["pageInfo"]
        if not page_info["hasNextPage"]:
            break
        next_cursor = page_info.get("endCursor")
        if not next_cursor or next_cursor == cursor:
            raise RuntimeError("GitHub returned an invalid pagination cursor")
        cursor = next_cursor

    if len(timestamps) != total_count:
        raise RuntimeError(
            f"Incomplete star history: GitHub reports {total_count} stars, but {len(timestamps)} timestamps were fetched"
        )
    timestamps.sort()
    return timestamps, total_count


def xml_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def nice_axis_max(value: int) -> int:
    if value <= 5:
        return 5
    magnitude = 10 ** math.floor(math.log10(value))
    normalized = value / magnitude
    step = 1 if normalized <= 1 else 2 if normalized <= 2 else 5 if normalized <= 5 else 10
    return int(step * magnitude)


def format_date(value: dt.date, span_days: int) -> str:
    if span_days > 550:
        return value.strftime("%b %Y")
    if span_days > 90:
        return value.strftime("%b %-d")
    return value.strftime("%-d %b")


def chart_points(timestamps: list[dt.datetime], today: dt.date) -> tuple[list[tuple[dt.date, int]], dt.date]:
    if not timestamps:
        start = today - dt.timedelta(days=30)
        return [(start, 0), (today, 0)], start

    first = timestamps[0].date()
    start = min(first - dt.timedelta(days=1), today - dt.timedelta(days=1))
    cumulative = 0
    points: list[tuple[dt.date, int]] = [(start, 0)]
    grouped: dict[dt.date, int] = {}
    for timestamp in timestamps:
        grouped[timestamp.date()] = grouped.get(timestamp.date(), 0) + 1
    for day in sorted(grouped):
        cumulative += grouped[day]
        points.append((day, cumulative))
    if points[-1][0] < today:
        points.append((today, cumulative))
    return points, start


def render_svg(repository: str, timestamps: list[dt.datetime], total_count: int, theme_name: str) -> str:
    theme = THEMES[theme_name]
    width, height = 960, 500
    left, right, top, bottom = 76, 42, 156, 64
    plot_width = width - left - right
    plot_height = height - top - bottom
    today = dt.datetime.now(dt.timezone.utc).date()
    points, start = chart_points(timestamps, today)
    span_days = max((today - start).days, 1)
    y_max = nice_axis_max(max(total_count, 1))

    def x_position(day: dt.date) -> float:
        return left + ((day - start).days / span_days) * plot_width

    def y_position(stars: int) -> float:
        return top + plot_height - (stars / y_max) * plot_height

    coordinates = [(x_position(day), y_position(stars)) for day, stars in points]
    line_path = "M " + " L ".join(f"{x:.2f} {y:.2f}" for x, y in coordinates)
    baseline = top + plot_height
    area_path = f"{line_path} L {coordinates[-1][0]:.2f} {baseline:.2f} L {coordinates[0][0]:.2f} {baseline:.2f} Z"

    y_ticks = []
    for index in range(6):
        value = round(y_max * index / 5)
        y = y_position(value)
        y_ticks.append(
            f'<line x1="{left}" y1="{y:.2f}" x2="{width - right}" y2="{y:.2f}" class="grid"/>'
            f'<text x="{left - 16}" y="{y + 4:.2f}" text-anchor="end" class="tick">{value}</text>'
        )

    x_ticks = []
    for index in range(6):
        offset = round(span_days * index / 5)
        day = start + dt.timedelta(days=offset)
        x = x_position(day)
        anchor = "start" if index == 0 else "end" if index == 5 else "middle"
        x_ticks.append(
            f'<text x="{x:.2f}" y="{height - 30}" text-anchor="{anchor}" class="tick">'
            f'{xml_escape(format_date(day, span_days))}</text>'
        )

    endpoint_x, endpoint_y = coordinates[-1]
    star_label = "star" if total_count == 1 else "stars"
    repository_label = xml_escape(repository)
    updated_label = today.strftime("Updated %b %-d, %Y · UTC")
    gradient_id = f"star-area-{theme_name}"

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title description">
  <title id="title">Star history for {repository_label}</title>
  <desc id="description">{total_count} GitHub {star_label} as of {today.isoformat()}.</desc>
  <defs>
    <linearGradient id="{gradient_id}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{theme['area_top']}" stop-opacity="0.42"/>
      <stop offset="100%" stop-color="{theme['area_bottom']}" stop-opacity="0.04"/>
    </linearGradient>
    <filter id="line-glow" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="3" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <style>
    .title {{ font: 700 26px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: {theme['text']}; }}
    .subtitle {{ font: 500 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: {theme['muted']}; }}
    .count {{ font: 700 18px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: {theme['line']}; }}
    .tick {{ font: 500 12px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: {theme['muted']}; }}
    .grid {{ stroke: {theme['grid']}; stroke-width: 1; stroke-dasharray: 3 6; opacity: 0.72; }}
  </style>
  <rect x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="18" fill="{theme['background']}" stroke="{theme['border']}"/>
  <text x="{left}" y="55" class="title">Star history</text>
  <text x="{left}" y="82" class="subtitle">{repository_label}</text>
  <rect x="{width - right - 128}" y="36" width="128" height="38" rx="19" fill="{theme['badge']}"/>
  <text x="{width - right - 64}" y="61" text-anchor="middle" dominant-baseline="middle" class="count">{total_count} {star_label}</text>
  <text x="{width - right}" y="104" text-anchor="end" class="subtitle">{xml_escape(updated_label)}</text>
  {''.join(y_ticks)}
  <path d="{area_path}" fill="url(#{gradient_id})"/>
  <path d="{line_path}" fill="none" stroke="{theme['line']}" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round" filter="url(#line-glow)"/>
  <circle cx="{endpoint_x:.2f}" cy="{endpoint_y:.2f}" r="6" fill="{theme['background']}" stroke="{theme['line']}" stroke-width="3"/>
  {''.join(x_ticks)}
</svg>
'''


def write_output(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    arguments = parse_arguments()
    try:
        owner, name = parse_repository(arguments.repo)
        token = os.environ.get("GITHUB_TOKEN", "").strip()
        if not token:
            raise RuntimeError("GITHUB_TOKEN is required")
        timestamps, total_count = fetch_star_timestamps(owner, name, token)
        write_output(
            arguments.output_light,
            render_svg(arguments.repo, timestamps, total_count, "light"),
        )
        write_output(
            arguments.output_dark,
            render_svg(arguments.repo, timestamps, total_count, "dark"),
        )
        print(f"Rendered {total_count} stars for {arguments.repo}")
        return 0
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
