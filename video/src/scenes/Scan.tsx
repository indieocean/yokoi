import React from "react";
import {
  AbsoluteFill,
  Easing,
  Img,
  Interactive,
  interpolate,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { Backdrop } from "../Backdrop";
import { mono, sans } from "../theme";

// Dashboard push-in with a reclaimable-space counter.
const ScanInner: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const gb = interpolate(frame, [0.6 * fps, 2.6 * fps], [0, 203], {
    easing: Easing.bezier(0.16, 1, 0.3, 1),
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <>
      <Backdrop />
      <AbsoluteFill style={{ alignItems: "center", fontFamily: sans }}>
        <Interactive.Div
          name="Headline"
          style={{
            marginTop: 70,
            fontSize: 84,
            fontWeight: 800,
            letterSpacing: "-0.04em",
            color: "#E6E8EE",
            opacity: interpolate(frame, [0, 0.4 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          One scan. Every gigabyte, explained.
        </Interactive.Div>
      </AbsoluteFill>

      <AbsoluteFill style={{ alignItems: "center", justifyContent: "flex-end" }}>
        <Img
          name="Dashboard screenshot"
          src={staticFile("dashboard.png")}
          style={{
            width: 1460,
            marginBottom: -150,
            borderRadius: 22,
            border: "1px solid rgba(255,255,255,0.12)",
            boxShadow: "0 50px 140px -30px rgba(0,0,0,0.95), 0 0 120px -30px rgba(124,92,255,0.5)",
            translate: interpolate(frame, [0, 1.0 * fps], ["0px 160px", "0px 0px"], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            scale: interpolate(frame, [1.0 * fps, 5.5 * fps], [1, 1.06], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        />
      </AbsoluteFill>

      <Interactive.Div
        name="Reclaimable counter"
        style={{
          position: "absolute",
          right: 120,
          top: 250,
          padding: "26px 36px",
          borderRadius: 20,
          backgroundColor: "rgba(20,22,32,0.82)",
          border: "1px solid rgba(124,92,255,0.45)",
          boxShadow: "0 30px 80px -20px rgba(0,0,0,0.9), 0 0 60px -10px rgba(124,92,255,0.6)",
          backdropFilter: "blur(20px)",
          fontFamily: sans,
          opacity: interpolate(frame, [0.6 * fps, 1.0 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          scale: interpolate(frame, [0.6 * fps, 1.2 * fps], [0.85, 1], {
            easing: Easing.spring({ damping: 14 }),
            output: "perceptual-scale",
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      >
        <div style={{ fontSize: 30, color: "#7D8597" }}>Reclaimable</div>
        <div style={{ fontFamily: mono, fontSize: 92, fontWeight: 700, color: "#E6E8EE", letterSpacing: "-0.02em" }}>
          {gb.toFixed(1)} GB
        </div>
        <div style={{ fontSize: 28, color: "#34D399" }}>across 7 categories</div>
      </Interactive.Div>
    </>
  );
};

export const Scan = Interactive.withSchema({
  Component: ScanInner,
  componentName: "Scan",
  schema: {},
  wrapInSequence: true,
  layout: "absolute-fill",
});
