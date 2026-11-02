import React from "react";
import { Composition, Folder } from "remotion";
import { YokoiDemo } from "./YokoiDemo";
import { YokoiDemoAudio } from "./YokoiDemoAudio";
import { Hook } from "./scenes/Hook";
import { Logo } from "./scenes/Logo";
import { Scan } from "./scenes/Scan";
import { Feature } from "./scenes/Feature";
import { Clean } from "./scenes/Clean";
import { Outro } from "./scenes/Outro";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition id="YokoiDemo" component={YokoiDemo} durationInFrames={900} fps={30} width={1920} height={1080} />
      <Composition id="YokoiDemoAudio" component={YokoiDemoAudio} durationInFrames={900} fps={30} width={1920} height={1080} />
      <Folder name="Scenes">
        <Composition id="Hook" component={Hook} durationInFrames={120} fps={30} width={1920} height={1080} />
        <Composition id="Logo" component={Logo} durationInFrames={105} fps={30} width={1920} height={1080} />
        <Composition id="Scan" component={Scan} durationInFrames={165} fps={30} width={1920} height={1080} />
        <Composition
          id="Feature"
          component={Feature}
          durationInFrames={90}
          fps={30}
          width={1920}
          height={1080}
          defaultProps={{
            badge: "node_modules",
            title: "Stale node_modules, preselected",
            detail: "npm · pnpm · Yarn · Bun, with active projects left alone",
            image: "npm-node-modules.png",
            accent: "#F05138",
          }}
        />
        <Composition id="Clean" component={Clean} durationInFrames={135} fps={30} width={1920} height={1080} />
        <Composition id="Outro" component={Outro} durationInFrames={135} fps={30} width={1920} height={1080} />
      </Folder>
    </>
  );
};
