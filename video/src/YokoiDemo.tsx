import React from "react";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { slide } from "@remotion/transitions/slide";
import { useVideoConfig } from "remotion";
import { Hook } from "./scenes/Hook";
import { Logo } from "./scenes/Logo";
import { Scan } from "./scenes/Scan";
import { Feature } from "./scenes/Feature";
import { Clean } from "./scenes/Clean";
import { Outro } from "./scenes/Outro";

// 30 s at 30 fps: 1020 frames of scenes minus 8 transitions of 15 frames = 900.
export const YokoiDemo: React.FC = () => {
  const { fps } = useVideoConfig();

  return (
    <TransitionSeries name="Yokoi demo">
      <TransitionSeries.Sequence name="Hook" durationInFrames={120} premountFor={fps}>
        <Hook />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 15 })} />
      <TransitionSeries.Sequence name="Logo" durationInFrames={105} premountFor={fps}>
        <Logo />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 15 })} />
      <TransitionSeries.Sequence name="Scan" durationInFrames={165} premountFor={fps}>
        <Scan />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 15 })} />
      <TransitionSeries.Sequence name="node_modules" durationInFrames={90} premountFor={fps}>
        <Feature
          badge="node_modules"
          title="Stale node_modules, preselected"
          detail="npm · pnpm · Yarn · Bun, with active projects left alone"
          image="npm-node-modules.png"
          accent="#F05138"
        />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={slide({ direction: "from-right" })} timing={linearTiming({ durationInFrames: 15 })} />
      <TransitionSeries.Sequence name="Build artifacts" durationInFrames={90} premountFor={fps}>
        <Feature
          badge="target/ · DerivedData"
          title="Build output from every toolchain"
          detail="Rust, Xcode, Gradle, Unity, Unreal, matched by marker files"
          image="build-artifacts.png"
          accent="#F97316"
        />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={slide({ direction: "from-right" })} timing={linearTiming({ durationInFrames: 15 })} />
      <TransitionSeries.Sequence name="Caches" durationInFrames={90} premountFor={fps}>
        <Feature
          badge="~/Library/Caches"
          title="Caches, tagged before you touch them"
          detail="Safe, Re-download or Review, for npm, brew, Xcode, Docker and more"
          image="caches.png"
          accent="#22D3EE"
        />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={slide({ direction: "from-right" })} timing={linearTiming({ durationInFrames: 15 })} />
      <TransitionSeries.Sequence name="Packages" durationInFrames={90} premountFor={fps}>
        <Feature
          badge="brew · cargo · pip"
          title="Global packages across 17 managers"
          detail="Outdated and unused, with the exact command shown first"
          image="package-managers.png"
          accent="#A78BFA"
        />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 15 })} />
      <TransitionSeries.Sequence name="Clean" durationInFrames={135} premountFor={fps}>
        <Clean />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 15 })} />
      <TransitionSeries.Sequence name="Outro" durationInFrames={135} premountFor={fps}>
        <Outro />
      </TransitionSeries.Sequence>
    </TransitionSeries>
  );
};
