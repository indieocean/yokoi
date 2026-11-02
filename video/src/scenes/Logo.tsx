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
import { gradientText, sans } from "../theme";

const LogoInner: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <>
      <Backdrop />
      <AbsoluteFill
        style={{ flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 80, fontFamily: sans }}
      >
        <Img
          name="App icon"
          src={staticFile("icon.png")}
          style={{
            width: 420,
            height: 420,
            filter: "drop-shadow(0 30px 80px rgba(124,92,255,0.55))",
            scale: interpolate(frame, [0, 0.8 * fps], [0.6, 1], {
              easing: Easing.spring({ damping: 14 }),
              output: "perceptual-scale",
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            rotate: interpolate(frame, [0, 0.8 * fps], ["-8deg", "0deg"], {
              easing: Easing.spring({ damping: 14 }),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            opacity: interpolate(frame, [0, 0.3 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        />
        <div>
          <Interactive.Div
            name="Wordmark"
            style={{
              fontSize: 260,
              fontWeight: 800,
              letterSpacing: "-0.05em",
              lineHeight: 1,
              paddingBottom: 20,
              ...gradientText,
              opacity: interpolate(frame, [0.3 * fps, 0.8 * fps], [0, 1], {
                extrapolateLeft: "clamp",
                extrapolateRight: "clamp",
              }),
              translate: interpolate(frame, [0.3 * fps, 1.0 * fps], ["40px 0px", "0px 0px"], {
                easing: Easing.bezier(0.16, 1, 0.3, 1),
                extrapolateLeft: "clamp",
                extrapolateRight: "clamp",
              }),
            }}
          >
            Yokoi
          </Interactive.Div>
          <Interactive.Div
            name="Tagline"
            style={{
              fontSize: 64,
              fontWeight: 500,
              color: "#C9CEDA",
              letterSpacing: "-0.02em",
              opacity: interpolate(frame, [0.8 * fps, 1.3 * fps], [0, 1], {
                extrapolateLeft: "clamp",
                extrapolateRight: "clamp",
              }),
              translate: interpolate(frame, [0.8 * fps, 1.5 * fps], ["0px 20px", "0px 0px"], {
                easing: Easing.bezier(0.16, 1, 0.3, 1),
                extrapolateLeft: "clamp",
                extrapolateRight: "clamp",
              }),
            }}
          >
            Your Mac, <span style={{ ...gradientText }}>garbage collected</span>
          </Interactive.Div>
        </div>
      </AbsoluteFill>
    </>
  );
};

export const Logo = Interactive.withSchema({
  Component: LogoInner,
  componentName: "Logo",
  schema: {},
  wrapInSequence: true,
  layout: "absolute-fill",
});
