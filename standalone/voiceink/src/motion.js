export function ringRadius(base, layer, energy, pulse = 0) {
  const level = Math.max(0, Math.min(1, energy));
  return base * (1 + pulse + level * (.11 + .16 * Math.sin(layer * Math.PI) ** 2));
}
export function entrancePoint(start, target, elapsed, duration = 280) {
  const t = Math.max(0, Math.min(1, elapsed / duration));
  const ease = 1 - (1 - t) ** 3;
  return start * (1 - ease) + target * ease;
}
