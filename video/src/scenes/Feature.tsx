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
  type InteractivitySchema,
} from "remotion";
import { Backdrop } from "../Backdrop";
import { mono, sans } from "../theme";

// One category: label + claim on the left, the real screen on the right.
type FeatureProps = {
  readonly badge: string;
  readonly title: string;
  readonly detail: string;
  readonly image: string;
  readonly accent: string;
};

const FeatureInner: React.FC<FeatureProps> = ({ badge, title, detail, image, accent }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <>
      <Backdrop />
      <AbsoluteFill style={{ fontFamily: sans }}>
        <Img
          name="Screen"
          src={staticFile(image)}
          style={{
            position: "absolute",
            left: 640,
            top: 150,
            width: 1220,
            borderRadius: 20,
            border: "1px solid rgba(255,255,255,0.12)",
            boxShadow: "0 50px 140px -30px rgba(0,0,0,0.95)",
            translate: interpolate(frame, [0, 0.6 * fps], ["120px 0px", "0px 0px"], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            scale: interpolate(frame, [0, 2.3 * fps], [1, 1.04], {
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
          name="Copy"
          style={{
            position: "absolute",
            left: 100,
            top: 0,
            bottom: 0,
            width: 500,
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            gap: 28,
            opacity: interpolate(frame, [0.1 * fps, 0.5 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            translate: interpolate(frame, [0.1 * fps, 0.7 * fps], ["-30px 0px", "0px 0px"], {
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
          }}
        >
          <div
            style={{
              alignSelf: "flex-start",
              fontFamily: mono,
              fontSize: 30,
              fontWeight: 700,
              padding: "8px 18px",
              borderRadius: 10,
              color: accent,
              backgroundColor: `${accent}22`,
              boxShadow: `inset 0 0 0 2px ${accent}55`,
            }}
          >
            {badge}
          </div>
          <div style={{ fontSize: 70, fontWeight: 800, letterSpacing: "-0.035em", lineHeight: 1.05, color: "#E6E8EE" }}>
            {title}
          </div>
          <div style={{ fontSize: 40, lineHeight: 1.35, color: "#9AA1B2" }}>{detail}</div>
        </Interactive.Div>
      </AbsoluteFill>
    </>
  );
};

const featureSchema = {
  badge: { type: "string", default: "node_modules", description: "Badge" },
  title: { type: "string", default: "", description: "Title" },
  detail: { type: "string", default: "", description: "Detail" },
  image: { type: "string", default: "npm-node-modules.png", description: "Screenshot in public/" },
  accent: { type: "color", default: "#F05138", description: "Accent color" },
} as const satisfies InteractivitySchema;

export const Feature = Interactive.withSchema({
  Component: FeatureInner,
  componentName: "Feature",
  schema: featureSchema,
  wrapInSequence: true,
  layout: "absolute-fill",
});
