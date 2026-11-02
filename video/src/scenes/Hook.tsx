import React from "react";
import {
  AbsoluteFill,
  Easing,
  Interactive,
  interpolate,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { Backdrop } from "../Backdrop";
import { mono, sans } from "../theme";

// A terminal lists what's eating the disk, then the hook line lands.
const COMMAND = "du -sh ~/* | sort -h";
const LINES = [
  { size: "14G", path: "~/dev/**/target", color: "#F97316" },
  { size: "19G", path: "~/Library/Caches", color: "#22D3EE" },
  { size: "27G", path: "~/Library/Developer/Xcode/DerivedData", color: "#60A5FA" },
  { size: "38G", path: "~/dev/**/node_modules", color: "#F05138" },
];

const HookInner: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const typed = Math.floor(interpolate(frame, [8, 8 + 0.8 * fps], [0, COMMAND.length], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  }));

  return (
    <>
      <Backdrop />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", fontFamily: sans }}>
        <Interactive.Div
          name="Terminal"
          style={{
            width: 1180,
            borderRadius: 18,
            overflow: "hidden",
            border: "1px solid rgba(255,255,255,0.12)",
            backgroundImage: "linear-gradient(180deg, #161925, #10121A)",
            boxShadow: "0 40px 120px -30px rgba(0,0,0,0.9), 0 0 80px -20px rgba(124,92,255,0.35)",
            scale: interpolate(frame, [0, 0.6 * fps], [0.94, 1], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            opacity: interpolate(frame, [0, 0.4 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            translate: interpolate(frame, [2.6 * fps, 3.2 * fps], ["0px 0px", "0px 120px"], {
              easing: Easing.bezier(0.65, 0, 0.35, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          <div style={{ display: "flex", gap: 12, padding: "20px 24px", borderBottom: "1px solid rgba(255,255,255,0.07)" }}>
            <div style={{ width: 16, height: 16, borderRadius: 8, backgroundColor: "#FF5F57" }} />
            <div style={{ width: 16, height: 16, borderRadius: 8, backgroundColor: "#FEBC2E" }} />
            <div style={{ width: 16, height: 16, borderRadius: 8, backgroundColor: "#28C840" }} />
          </div>
          <div style={{ padding: "32px 44px 40px", fontFamily: mono, fontSize: 38, lineHeight: 1.75, color: "#E6E8EE" }}>
            <div>
              <span style={{ color: "#22D3EE" }}>$ </span>
              {COMMAND.slice(0, typed)}
              <span
                style={{
                  display: "inline-block",
                  width: 18,
                  height: 40,
                  marginLeft: 4,
                  verticalAlign: "middle",
                  backgroundColor: "#22D3EE",
                  opacity: Math.floor(frame / 8) % 2 === 0 ? 1 : 0,
                }}
              />
            </div>
            {LINES.map((line, i) => {
              const start = 1.0 * fps + i * 7;
              return (
                <div
                  key={line.path}
                  style={{
                    display: "flex",
                    gap: 36,
                    opacity: interpolate(frame, [start, start + 5], [0, 1], {
                      extrapolateLeft: "clamp",
                      extrapolateRight: "clamp",
                    }),
                  }}
                >
                  <span style={{ width: 90, textAlign: "right", fontWeight: 700, color: line.color }}>{line.size}</span>
                  <span style={{ color: "#9AA1B2" }}>{line.path}</span>
                </div>
              );
            })}
          </div>
        </Interactive.Div>
      </AbsoluteFill>

      <AbsoluteFill style={{ alignItems: "center", fontFamily: sans }}>
        <Interactive.Div
          name="Hook line"
          style={{
            marginTop: 110,
            fontSize: 96,
            fontWeight: 800,
            letterSpacing: "-0.04em",
            color: "#E6E8EE",
            opacity: interpolate(frame, [2.7 * fps, 3.2 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            translate: interpolate(frame, [2.7 * fps, 3.3 * fps], ["0px 30px", "0px 0px"], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          Your Mac is full. <span style={{ color: "#F0565E" }}>Again.</span>
        </Interactive.Div>
      </AbsoluteFill>
    </>
  );
};

export const Hook = Interactive.withSchema({
  Component: HookInner,
  componentName: "Hook",
  schema: {},
  wrapInSequence: true,
  layout: "absolute-fill",
});
