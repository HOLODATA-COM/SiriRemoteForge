#!/usr/bin/env python3
"""Build the single-page HyperVibe overview used for Apple outreach."""

from pathlib import Path

from reportlab.lib.colors import Color, HexColor, white
from reportlab.lib.pagesizes import letter
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "output" / "pdf" / "HyperVibe-Apple-Overview.pdf"
ICON = ROOT / "website" / "media" / "hypervibe-icon.png"
REMOTE = ROOT / "website" / "media" / "current-remote.png"

INK = HexColor("#15171B")
MUTED = HexColor("#62666D")
PAPER = HexColor("#F4F4EF")
PANEL = HexColor("#FFFFFF")
LINE = HexColor("#DCDDD8")
BLUE = HexColor("#2F75FF")
CYAN = HexColor("#53C8E8")
ORANGE = HexColor("#FF8A42")
GREEN = HexColor("#50B96A")
PURPLE = HexColor("#8268E8")
RED = HexColor("#E94D5D")
DARK = HexColor("#15181E")


def wrapped_lines(text: str, font: str, size: float, width: float) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = word if not current else f"{current} {word}"
        if stringWidth(candidate, font, size) <= width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def draw_wrapped(
    pdf: canvas.Canvas,
    text: str,
    x: float,
    y: float,
    width: float,
    font: str = "Helvetica",
    size: float = 9,
    leading: float = 12,
    color=INK,
    max_lines: int | None = None,
) -> float:
    lines = wrapped_lines(text, font, size, width)
    if max_lines is not None:
        lines = lines[:max_lines]
    pdf.setFont(font, size)
    pdf.setFillColor(color)
    for line in lines:
        pdf.drawString(x, y, line)
        y -= leading
    return y


def overline(pdf: canvas.Canvas, text: str, x: float, y: float, color=BLUE) -> None:
    pdf.setFillColor(color)
    pdf.setFont("Helvetica-Bold", 6.7)
    pdf.drawString(x, y, text.upper())


def capability_card(
    pdf: canvas.Canvas,
    x: float,
    y: float,
    width: float,
    height: float,
    number: str,
    title: str,
    description: str,
    accent,
) -> None:
    pdf.setFillColor(PANEL)
    pdf.setStrokeColor(LINE)
    pdf.roundRect(x, y, width, height, 8, fill=1, stroke=1)
    pdf.setFillColor(accent)
    pdf.roundRect(x + 10, y + height - 19, 21, 10, 5, fill=1, stroke=0)
    pdf.setFillColor(white)
    pdf.setFont("Helvetica-Bold", 5.8)
    pdf.drawCentredString(x + 20.5, y + height - 15.8, number)
    pdf.setFillColor(INK)
    pdf.setFont("Helvetica-Bold", 8.5)
    pdf.drawString(x + 39, y + height - 17, title)
    draw_wrapped(pdf, description, x + 10, y + height - 32, width - 20, size=6.9, leading=8.7, color=MUTED, max_lines=3)


def scenario(pdf: canvas.Canvas, x: float, y: float, width: float, label: str, title: str, accent) -> None:
    pdf.setFillColor(Color(accent.red, accent.green, accent.blue, alpha=0.07))
    pdf.setStrokeColor(Color(accent.red, accent.green, accent.blue, alpha=0.25))
    pdf.roundRect(x, y, width, 47, 8, fill=1, stroke=1)
    pdf.setFillAlpha(1)
    pdf.setStrokeAlpha(1)
    overline(pdf, label, x + 11, y + 32, accent)
    draw_wrapped(pdf, title, x + 11, y + 18, width - 22, font="Helvetica-Bold", size=7.7, leading=9.1, color=INK, max_lines=2)


def draw_curve(pdf: canvas.Canvas, x: float, y: float, width: float, height: float) -> None:
    pdf.setFillColor(PANEL)
    pdf.setStrokeColor(LINE)
    pdf.roundRect(x, y, width, height, 9, fill=1, stroke=1)
    overline(pdf, "TWO INDEPENDENT CURVES", x + 10, y + height - 15, ORANGE)
    pdf.setStrokeColor(HexColor("#E7E8E5"))
    pdf.setLineWidth(0.5)
    for offset in (18, 35, 52):
        pdf.line(x + 10, y + offset, x + width - 10, y + offset)
    pdf.setStrokeColor(BLUE)
    pdf.setLineWidth(2.0)
    path = pdf.beginPath()
    path.moveTo(x + 12, y + 14)
    path.curveTo(x + 35, y + 14, x + 41, y + 42, x + 67, y + 48)
    path.curveTo(x + 83, y + 52, x + 94, y + 52, x + width - 12, y + 52)
    pdf.drawPath(path, stroke=1, fill=0)
    pdf.setStrokeColor(ORANGE)
    path = pdf.beginPath()
    path.moveTo(x + 12, y + 12)
    path.curveTo(x + 33, y + 12, x + 43, y + 34, x + 64, y + 41)
    path.curveTo(x + 80, y + 47, x + 95, y + 47, x + width - 12, y + 47)
    pdf.drawPath(path, stroke=1, fill=0)


def build() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    pdf = canvas.Canvas(str(OUTPUT), pagesize=letter, pageCompression=1)
    page_width, page_height = letter
    pdf.setTitle("HyperVibe - Apple Overview")
    pdf.setAuthor("Wenqian Zhang")
    pdf.setSubject("Public macOS proof of concept for complete one-handed control using Siri Remote")

    pdf.setFillColor(PAPER)
    pdf.rect(0, 0, page_width, page_height, fill=1, stroke=0)

    # Header
    pdf.drawImage(ImageReader(str(ICON)), 36, 738, 34, 34, preserveAspectRatio=True, mask="auto")
    pdf.setFillColor(INK)
    pdf.setFont("Helvetica-Bold", 12)
    pdf.drawString(80, 758, "HyperVibe")
    pdf.setFillColor(MUTED)
    pdf.setFont("Helvetica", 6.8)
    pdf.drawString(80, 746, "SiriRemoteForge / public macOS research build")
    pdf.setFillColor(HexColor("#E8EEF9"))
    pdf.roundRect(445, 746, 131, 20, 10, fill=1, stroke=0)
    pdf.setFillColor(HexColor("#315B9A"))
    pdf.setFont("Helvetica-Bold", 6.4)
    pdf.drawCentredString(510.5, 753.2, "PUBLIC PROOF OF CONCEPT")
    pdf.setStrokeColor(LINE)
    pdf.line(36, 728, 576, 728)

    # Hero
    overline(pdf, "COMPLETE ONE-HANDED MAC CONTROL", 36, 705, BLUE)
    pdf.setFillColor(INK)
    pdf.setFont("Helvetica-Bold", 23)
    pdf.drawString(36, 675, "Point. Scroll. Click. Drag.")
    pdf.drawString(36, 649, "Speak. Stay in the flow.")
    draw_wrapped(
        pdf,
        "HyperVibe turns a paired third-generation Siri Remote into a configurable macOS input surface, with every action visible and every mapping shared by the GUI, scripts, and coding agents.",
        36,
        624,
        382,
        size=8.8,
        leading=12.2,
        color=MUTED,
        max_lines=4,
    )

    # Remote product visual
    pdf.setFillColor(Color(BLUE.red, BLUE.green, BLUE.blue, alpha=0.07))
    pdf.circle(507, 536, 88, fill=1, stroke=0)
    pdf.setFillAlpha(1)
    pdf.setFillColor(PANEL)
    pdf.setStrokeColor(LINE)
    pdf.roundRect(448, 390, 126, 300, 14, fill=1, stroke=1)
    pdf.drawImage(ImageReader(str(REMOTE)), 455, 394, 112, 287, preserveAspectRatio=True, mask="auto")
    pdf.setFillColor(INK)
    pdf.setFont("Helvetica-Bold", 6.5)
    pdf.drawCentredString(511, 382, "THIRD-GENERATION USB-C SIRI REMOTE")

    # Problem panel
    pdf.setFillColor(DARK)
    pdf.roundRect(36, 527, 382, 67, 10, fill=1, stroke=0)
    overline(pdf, "THE GAP", 49, 575, CYAN)
    draw_wrapped(
        pdf,
        "Voice can create a prompt, but the workflow still returns to a mouse for navigation, selection, and verification. A presenter also loses presence whenever the demo pulls them back to the desk.",
        49,
        559,
        354,
        size=8,
        leading=10.5,
        color=HexColor("#D7DADF"),
        max_lines=3,
    )

    # Capability grid
    overline(pdf, "WHAT WORKS TODAY", 36, 508, GREEN)
    card_width = 184
    card_height = 62
    gap = 14
    cards = [
        ("01", "Touch pointer", "Dead zone, click freeze, and a direct acceleration curve.", BLUE),
        ("02", "Ring scrolling", "Velocity gain with vertical or horizontal context.", ORANGE),
        ("03", "Gesture grammar", "Tap, Double, Triple, and three timed Hold stages.", PURPLE),
        ("04", "App x Layer", "Task-aware mappings across as many as ten named layers.", GREEN),
        ("05", "Visible state", "Layer, action, progress, connection, and voice feedback.", CYAN),
        ("06", "Voice + agents", "Experimental remote voice, mic fallback, and hot-reloaded JSONC.", RED),
    ]
    positions = [(36, 432), (36 + card_width + gap, 432), (36, 360), (36 + card_width + gap, 360), (36, 288), (36 + card_width + gap, 288)]
    for (number, title, description, accent), (x, y) in zip(cards, positions):
        capability_card(pdf, x, y, card_width, card_height, number, title, description, accent)

    draw_curve(pdf, 436, 288, 140, 82)

    # Use cases
    overline(pdf, "WHY IT MATTERS", 36, 267, BLUE)
    scenario(pdf, 36, 207, 168, "VOICE-ASSISTED CODING", "Speak, navigate, inspect, and approve without changing devices.", BLUE)
    scenario(pdf, 222, 207, 168, "STANDING PRESENTATION", "Operate a live Mac while remaining present as the speaker.", ORANGE)
    scenario(pdf, 408, 207, 168, "ALTERNATIVE INPUT", "Concentrate common Mac actions in one small one-handed surface.", GREEN)

    # Concrete platform request
    pdf.setFillColor(DARK)
    pdf.roundRect(36, 72, 540, 118, 12, fill=1, stroke=0)
    overline(pdf, "THE CONCRETE PLATFORM REQUEST", 51, 171, CYAN)
    pdf.setFillColor(white)
    pdf.setFont("Helvetica-Bold", 12)
    pdf.drawString(51, 151, "The interaction works. The complete supported macOS path is still missing.")
    pdf.setStrokeColor(HexColor("#363A42"))
    pdf.line(306, 90, 306, 139)
    pdf.setFillColor(CYAN)
    pdf.circle(55, 123, 3, fill=1, stroke=0)
    pdf.setFillColor(white)
    pdf.setFont("Helvetica-Bold", 8.3)
    pdf.drawString(65, 120, "INPUT")
    draw_wrapped(pdf, "Public, timestamped Siri Remote button, ring, and touch data with a sandbox-compatible routing model.", 65, 106, 218, size=7.1, leading=9.2, color=HexColor("#C7CBD2"), max_lines=3)
    pdf.setFillColor(RED)
    pdf.circle(324, 123, 3, fill=1, stroke=0)
    pdf.setFillColor(white)
    pdf.setFont("Helvetica-Bold", 8.3)
    pdf.drawString(334, 120, "AUDIO")
    draw_wrapped(pdf, "A permissioned CoreAudio input or documented accessory stream with push-to-talk and fallback state.", 334, 106, 220, size=7.1, leading=9.2, color=HexColor("#C7CBD2"), max_lines=3)

    # Footer and live links
    pdf.setFillColor(MUTED)
    pdf.setFont("Helvetica", 6.6)
    pdf.drawString(36, 50, "macOS 13+ / Apple silicon / public beta / native installer / current tree: 130/130 core tests")
    repo_text = "github.com/HOLODATA-COM/SiriRemoteForge"
    pdf.setFillColor(BLUE)
    pdf.setFont("Helvetica-Bold", 7)
    pdf.drawRightString(576, 50, repo_text)
    repo_width = stringWidth(repo_text, "Helvetica-Bold", 7)
    pdf.linkURL("https://github.com/HOLODATA-COM/SiriRemoteForge", (576 - repo_width, 47, 576, 58), relative=0)
    pdf.setFillColor(MUTED)
    pdf.setFont("Helvetica", 5.8)
    disclaimer = "Existing public, non-confidential research project. Experimental remote voice uses undocumented system behavior."
    pdf.drawString(36, 34, disclaimer)
    pdf.setFillColor(INK)
    pdf.setFont("Helvetica-Bold", 6.2)
    pdf.drawString(36, 20, "Independent project; not affiliated with Apple.")
    pdf.drawRightString(576, 20, "Wenqian Zhang / zhangwenqian6915@gmail.com")

    pdf.showPage()
    pdf.save()


if __name__ == "__main__":
    build()
