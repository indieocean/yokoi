// Fonts and colors shared by every scene. Tokens follow docs/DESIGN.md.
import { loadFont as loadInter } from "@remotion/google-fonts/Inter";
import { loadFont as loadMono } from "@remotion/google-fonts/JetBrainsMono";

export const { fontFamily: sans } = loadInter("normal", {
  weights: ["400", "500", "600", "700", "800"],
  subsets: ["latin"],
});

export const { fontFamily: mono } = loadMono("normal", {
  weights: ["400", "500", "700"],
  subsets: ["latin"],
});

export const gradientText = {
  backgroundImage:
    "linear-gradient(90deg, #F4F1FF 0%, #B79CFF 30%, #8B6CFF 55%, #22D3EE 100%)",
  WebkitBackgroundClip: "text",
  backgroundClip: "text",
  color: "transparent",
} as const;
