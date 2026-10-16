import { ringRadius, entrancePoint } from "./motion.js";
/** Spherical particle display. Each latitude ring only expands/contracts symmetrically. */
export class Orb {
  private context: CanvasRenderingContext2D;
  private points: {
    x: number;
    y: number;
    z: number;
    layer: number;
    startX: number;
    startY: number;
    radius: number;
    cx: number;
    cy: number;
  }[] = [];
  private phase = "idle";
  private energy = 0;
  private targetEnergy = 0;
  private entered = performance.now();
  private frame = 0;
  private visible = true;
  private reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  constructor(private canvas: HTMLCanvasElement) {
    this.context = canvas.getContext("2d")!;
    for (let ring = 1; ring < 23; ring++) {
      const latitude = (ring / 23) * Math.PI;
      const count = Math.max(8, Math.round(Math.sin(latitude) * 36));
      for (let j = 0; j < count; j++) {
        const angle = (j / count) * Math.PI * 2 + (ring % 2) * 0.055;
        const origin = Math.random() * Math.PI * 2,
          distance = 200 + Math.random() * 140;
        this.points.push({
          x: Math.sin(latitude) * Math.cos(angle),
          y: Math.cos(latitude),
          z: Math.sin(latitude) * Math.sin(angle),
          layer: ring / 23,
          startX: Math.cos(origin) * distance,
          startY: Math.sin(origin) * distance,
          radius: 1,
          cx: 0,
          cy: 0,
        });
      }
    }
    this.draw();
  }
  setPhase(phase: string) {
    if (phase === "listening" && this.phase !== "listening") {
      this.entered = performance.now();
      for (const p of this.points) {
        const angle = Math.random() * Math.PI * 2,
          d = 200 + Math.random() * 140;
        p.startX = Math.cos(angle) * d;
        p.startY = Math.sin(angle) * d;
      }
    }
    this.phase = phase;
    if (phase !== "listening") this.targetEnergy = 0;
  }
  setLevel(level: number) {
    this.targetEnergy = Math.max(0, Math.min(1, level));
  }
  setVisible(visible: boolean) {
    if (this.visible === visible) return;
    this.visible = visible;
    if (visible) this.draw();
    else cancelAnimationFrame(this.frame);
  }
  destroy() {
    cancelAnimationFrame(this.frame);
  }
  private draw = () => {
    if (!this.visible) return;
    this.frame = requestAnimationFrame(this.draw);
    const size = this.canvas.clientWidth || 220,
      ratio = Math.min(devicePixelRatio, 2);
    if (this.canvas.width !== Math.round(size * ratio)) {
      this.canvas.width = Math.round(size * ratio);
      this.canvas.height = Math.round(size * ratio);
    }
    const c = this.context;
    c.setTransform(ratio, 0, 0, ratio, 0, 0);
    c.clearRect(0, 0, size, size);
    const now = performance.now(),
      time = now / 1000;
    this.energy +=
      (this.targetEnergy - this.energy) *
      (this.targetEnergy > this.energy ? 0.28 : 0.13);
    const live = this.phase === "listening",
      busy = ["transcribing", "polishing", "rewriting", "inserting"].includes(
        this.phase,
      );
    const success = ["inserted", "replaced"].includes(this.phase),
      copied = this.phase === "copied",
      error = this.phase === "error";
    const entrance = this.reduced ? 1 : Math.min(1, (now - this.entered) / 280),
      ease = 1 - Math.pow(1 - entrance, 3);
    const scale = size / 220,
      base = 64 * scale,
      center = size / 2;
    const idle = 0.015 * Math.sin(time * 1.3);
    const pulse = busy ? 0.045 * Math.sin(time * 3) : idle;
    const rotation = live || this.reduced ? 0 : time * 0.13;
    c.save();
    c.translate(center, center);
    const glow = c.createRadialGradient(0, 0, base * 0.35, 0, 0, base * 1.65);
    glow.addColorStop(0, `rgba(120,105,248,${0.07 + this.energy * 0.08})`);
    glow.addColorStop(0.65, "rgba(120,105,248,.035)");
    glow.addColorStop(1, "rgba(120,105,248,0)");
    c.fillStyle = glow;
    c.fillRect(-size / 2, -size / 2, size, size);
    const sorted = [...this.points].sort((a, b) => a.z - b.z);
    sorted.forEach((p, i) => {
      const radius = ringRadius(base, p.layer, this.energy, pulse);
      const xr = p.x * Math.cos(rotation) + p.z * Math.sin(rotation),
        zr = -p.x * Math.sin(rotation) + p.z * Math.cos(rotation);
      let x = xr * radius,
        y = -p.y * radius,
        z = zr;
      if (success || error || copied) {
        const n = i / (sorted.length - 1);
        if (success) {
          const bend = 0.34;
          if (n < bend) {
            const t = n / bend;
            x = (-0.62 + t * 0.43) * base;
            y = (0.02 + t * 0.4) * base;
          } else {
            const t = (n - bend) / (1 - bend);
            x = (-0.19 + t * 0.88) * base;
            y = (0.42 - t * 0.99) * base;
          }
        }
        if (error) {
          const branch = i % 2 === 0 ? 1 : -1;
          x = (n * 1.3 - 0.65) * base;
          y = x * branch;
        }
        if (copied) {
          const branch = i % 2,
            t = (n * 4) % 4,
            left = branch ? -0.37 : -0.12,
            top = branch ? -0.47 : -0.22,
            w = 0.68,
            h = 0.85;
          if (t < 1) {
            x = (left + t * w) * base;
            y = top * base;
          } else if (t < 2) {
            x = (left + w) * base;
            y = (top + (t - 1) * h) * base;
          } else if (t < 3) {
            x = (left + w - (t - 2) * w) * base;
            y = (top + h) * base;
          } else {
            x = left * base;
            y = (top + h - (t - 3) * h) * base;
          }
        }
        x += Math.sin(i * 12.1) * 1.6 * scale;
        y += Math.cos(i * 7.3) * 1.6 * scale;
        z = 0.6;
      }
      if (entrance < 1) {
        p.cx = entrancePoint(p.startX * scale, x, now - this.entered);
        p.cy = entrancePoint(p.startY * scale, y, now - this.entered);
      } else {
        p.cx += (x - p.cx) * (this.reduced ? 1 : 0.22);
        p.cy += (y - p.cy) * (this.reduced ? 1 : 0.22);
      }
      const px = p.cx,
        py = p.cy;
      const depth = (z + 1) / 2;
      const desired = (0.6 + depth * 0.9) * (1 + this.energy * 0.85) * scale;
      const dot = 1 * scale * (1 - ease) + desired * ease;
      c.globalAlpha = (0.22 + depth * 0.76) * Math.min(1, entrance * 2);
      c.fillStyle = error
        ? "#f396a4"
        : success
          ? "#9de0cf"
          : copied
            ? "#bdb1ff"
            : `hsl(${242 - depth * 17},${50 + depth * 35}%,${63 + depth * 27}%)`;
      c.beginPath();
      c.arc(px, py, dot, 0, Math.PI * 2);
      c.fill();
    });
    c.restore();
    c.globalAlpha = 1;
  };
}
