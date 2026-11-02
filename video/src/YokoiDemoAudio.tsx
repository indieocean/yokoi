import React from "react";
import { AbsoluteFill } from "remotion";
import { YokoiDemo } from "./YokoiDemo";
import { Soundtrack } from "./Soundtrack";

// Same picture as YokoiDemo, with the music bed and sound effects.
export const YokoiDemoAudio: React.FC = () => {
  return (
    <AbsoluteFill>
      <YokoiDemo />
      <Soundtrack />
    </AbsoluteFill>
  );
};
