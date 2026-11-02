import React from "react";
import { Video } from "@remotion/media";
import {
  AbsoluteFill,
  Easing,
  Interactive,
  interpolate,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { Backdrop } from "../Backdrop";
import { mono, sans } from "../theme";

// The real cleaning animation, with the safety promises beside it.
const CleanInner: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <>
      <Backdrop />
      <AbsoluteFill style={{ fontFamily: sans }}>
        <Interactive.Div
          name="Cleaning clip"
          style={{
            position: "absolute",
            left: 150,
            top: 110,
            width: 760,
            height: 860,
            borderRadius: 26,
            overflow: "hidden",
            border: "1px solid rgba(255,255,255,0.12)",
            backgroundColor: "#0B0C11",
            boxShadow: "0 40px 120px -30px rgba(124,92,255,0.55)",
            opacity: interpolate(frame, [0, 0.4 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            scale: interpolate(frame, [0, 0.7 * fps], [0.94, 1], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          <Video
            name="Cleaning animation"
            src={staticFile("cleaning.mp4")}
            premountFor={fps}
            muted
            objectFit="cover"
            style={{ width: "100%", height: "100%" }}
          />
        </Interactive.Div>

        <Interactive.Div
          name="Headline"
          style={{
            position: "absolute",
            left: 1010,
            top: 190,
            fontSize: 88,
            fontWeight: 800,
            letterSpacing: "-0.04em",
            lineHeight: 1.05,
            color: "#E6E8EE",
            opacity: interpolate(frame, [0.2 * fps, 0.6 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          Cleans like it's
          <br />
          <span style={{ color: "#34D399" }}>paranoid.</span>
        </Interactive.Div>

        <Interactive.Div
          name="Trash first"
          style={{
            position: "absolute",
            left: 1010,
            top: 480,
            display: "flex",
            alignItems: "center",
            gap: 26,
            fontSize: 46,
            fontWeight: 600,
            color: "#E6E8EE",
            opacity: interpolate(frame, [0.9 * fps, 1.3 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            translate: interpolate(frame, [0.9 * fps, 1.5 * fps], ["30px 0px", "0px 0px"], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          <div style={{ width: 20, height: 20, borderRadius: 10, backgroundColor: "#34D399", boxShadow: "0 0 24px #34D399" }} />
          <span>
            Trash first, never <span style={{ fontFamily: mono, color: "#F0565E" }}>rm -rf</span>
          </span>
        </Interactive.Div>

        <Interactive.Div
          name="Put Back"
          style={{
            position: "absolute",
            left: 1010,
            top: 580,
            display: "flex",
            alignItems: "center",
            gap: 26,
            fontSize: 46,
            fontWeight: 600,
            color: "#E6E8EE",
            opacity: interpolate(frame, [1.5 * fps, 1.9 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            translate: interpolate(frame, [1.5 * fps, 2.1 * fps], ["30px 0px", "0px 0px"], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          <div style={{ width: 20, height: 20, borderRadius: 10, backgroundColor: "#7C5CFF", boxShadow: "0 0 24px #7C5CFF" }} />
          Put Back any cleanup
        </Interactive.Div>

        <Interactive.Div
          name="No sudo"
          style={{
            position: "absolute",
            left: 1010,
            top: 680,
            display: "flex",
            alignItems: "center",
            gap: 26,
            fontSize: 46,
            fontWeight: 600,
            color: "#E6E8EE",
            opacity: interpolate(frame, [2.1 * fps, 2.5 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            translate: interpolate(frame, [2.1 * fps, 2.7 * fps], ["30px 0px", "0px 0px"], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          <div style={{ width: 20, height: 20, borderRadius: 10, backgroundColor: "#22D3EE", boxShadow: "0 0 24px #22D3EE" }} />
          <span>
            No <span style={{ fontFamily: mono }}>sudo</span>, no telemetry, 100% local
          </span>
        </Interactive.Div>
      </AbsoluteFill>
    </>
  );
};

export const Clean = Interactive.withSchema({
  Component: CleanInner,
  componentName: "Clean",
  schema: {},
  wrapInSequence: true,
  layout: "absolute-fill",
});
