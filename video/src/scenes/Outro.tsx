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
import { gradientText, mono, sans } from "../theme";

const OutroInner: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <>
      <Backdrop />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", fontFamily: sans, gap: 36 }}>
        <Img
          name="App icon"
          src={staticFile("icon.png")}
          style={{
            width: 260,
            height: 260,
            filter: "drop-shadow(0 24px 70px rgba(124,92,255,0.6))",
            scale: interpolate(frame, [0, 0.7 * fps], [0.7, 1], {
              easing: Easing.spring({ damping: 14 }),
              output: "perceptual-scale",
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            opacity: interpolate(frame, [0, 0.3 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        />
        <Interactive.Div
          name="Call to action"
          style={{
            fontSize: 110,
            fontWeight: 800,
            letterSpacing: "-0.045em",
            color: "#E6E8EE",
            textAlign: "center",
            lineHeight: 1.05,
            opacity: interpolate(frame, [0.3 * fps, 0.8 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            translate: interpolate(frame, [0.3 * fps, 1.0 * fps], ["0px 30px", "0px 0px"], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          Get your <span style={{ ...gradientText }}>gigabytes</span> back.
        </Interactive.Div>
        <Interactive.Div
          name="Subline"
          style={{
            fontSize: 46,
            color: "#9AA1B2",
            opacity: interpolate(frame, [0.8 * fps, 1.2 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          Free and open source · macOS 14+
        </Interactive.Div>
        <Interactive.Div
          name="URL pill"
          style={{
            marginTop: 10,
            padding: "20px 40px",
            borderRadius: 16,
            fontFamily: mono,
            fontSize: 46,
            fontWeight: 500,
            color: "#FFFFFF",
            backgroundImage: "linear-gradient(180deg, #8B6CFF, #6D4CF5)",
            boxShadow: "0 0 0 1px rgba(255,255,255,0.1) inset, 0 20px 60px -10px rgba(124,92,255,0.8)",
            opacity: interpolate(frame, [1.2 * fps, 1.6 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            scale: interpolate(frame, [1.2 * fps, 1.8 * fps], [0.9, 1], {
              easing: Easing.spring({ damping: 12 }),
              output: "perceptual-scale",
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          indieocean.github.io/yokoi
        </Interactive.Div>
      </AbsoluteFill>
    </>
  );
};

export const Outro = Interactive.withSchema({
  Component: OutroInner,
  componentName: "Outro",
  schema: {},
  wrapInSequence: true,
  layout: "absolute-fill",
});
