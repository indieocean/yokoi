import React from "react";
import { AbsoluteFill, random, useCurrentFrame, useVideoConfig } from "remotion";

// The site/header background: faint grid, violet + cyan glows, drifting pixels.
const PIXELS = new Array(60).fill(true).map((_, i) => ({
  x: random(`x${i}`),
  y: random(`y${i}`),
  size: 3 + random(`s${i}`) * 5,
  speed: 0.4 + random(`v${i}`) * 1.2,
  alpha: 0.2 + random(`a${i}`) * 0.5,
  phase: random(`p${i}`) * Math.PI * 2,
  color: ["124,92,255", "34,211,238", "167,139,250"][Math.floor(random(`c${i}`) * 3)],
}));

export const Backdrop: React.FC = () => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();

  return (
    <AbsoluteFill style={{ backgroundColor: "#0E1016", overflow: "hidden" }}>
      <AbsoluteFill
        style={{
          backgroundImage:
            "radial-gradient(1100px 700px at 12% -10%, rgba(124,92,255,0.28), transparent 60%), radial-gradient(900px 600px at 100% 10%, rgba(34,211,238,0.14), transparent 60%), radial-gradient(900px 500px at 50% 120%, rgba(124,92,255,0.18), transparent 60%)",
        }}
      />
      <AbsoluteFill
        style={{
          backgroundImage:
            "linear-gradient(rgba(255,255,255,0.03) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.03) 1px, transparent 1px)",
          backgroundSize: "64px 64px",
          backgroundPosition: `0px ${-frame * 0.3}px`,
        }}
      />
      {PIXELS.map((p, i) => {
        const y = (((p.y * height - frame * p.speed) % height) + height) % height;
        const a = p.alpha * (0.6 + 0.4 * Math.sin(frame / 20 + p.phase));
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: p.x * width,
              top: y,
              width: p.size,
              height: p.size,
              backgroundColor: `rgba(${p.color},${a})`,
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};
