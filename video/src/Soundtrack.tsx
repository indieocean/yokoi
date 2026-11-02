import React from "react";
import { Audio } from "@remotion/media";
import { interpolate, staticFile, useVideoConfig } from "remotion";

// Music bed + sound effects for YokoiDemoAudio.
// Scene starts in YokoiDemo (after 15-frame transitions): Hook 0, Logo 105, Scan 195,
// node_modules 345, Build 420, Caches 495, Packages 570, Clean 645, Outro 765.
export const Soundtrack: React.FC = () => {
  const { fps, durationInFrames } = useVideoConfig();

  return (
    <>
      <Audio
        name="Music"
        src={staticFile("music.mp3")}
        premountFor={fps}
        durationInFrames={durationInFrames}
        volume={(f) =>
          interpolate(f, [0, 10, durationInFrames - 30, durationInFrames], [0, 0.55, 0.55, 0], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          })
        }
      />

      {/* Hook: typing the du command, then the punchline */}
      <Audio name="Key 1" src={staticFile("sfx/mouse-click.wav")} from={9} premountFor={fps} volume={0.35} />
      <Audio name="Key 2" src={staticFile("sfx/mouse-click.wav")} from={15} premountFor={fps} volume={0.3} />
      <Audio name="Key 3" src={staticFile("sfx/mouse-click.wav")} from={21} premountFor={fps} volume={0.35} />
      <Audio name="Key 4" src={staticFile("sfx/mouse-click.wav")} from={27} premountFor={fps} volume={0.3} />
      <Audio name="Enter" src={staticFile("sfx/switch.wav")} from={31} premountFor={fps} volume={0.45} />
      <Audio name="Again" src={staticFile("sfx/switch.wav")} from={84} premountFor={fps} volume={0.6} />

      {/* Transitions */}
      <Audio name="Whoosh to Logo" src={staticFile("sfx/whoosh.wav")} from={103} premountFor={fps} volume={0.7} />
      <Audio name="Whoosh to Scan" src={staticFile("sfx/whoosh.wav")} from={193} premountFor={fps} volume={0.6} />
      <Audio name="Counter lands" src={staticFile("sfx/ding.wav")} from={272} premountFor={fps} volume={0.35} />
      <Audio name="Whoosh to node_modules" src={staticFile("sfx/whoosh.wav")} from={343} premountFor={fps} volume={0.6} />
      <Audio name="Whoosh to Build" src={staticFile("sfx/whoosh.wav")} from={418} premountFor={fps} volume={0.5} />
      <Audio name="Whoosh to Caches" src={staticFile("sfx/whoosh.wav")} from={493} premountFor={fps} volume={0.5} />
      <Audio name="Whoosh to Packages" src={staticFile("sfx/whoosh.wav")} from={568} premountFor={fps} volume={0.5} />
      <Audio name="Whoosh to Clean" src={staticFile("sfx/whoosh.wav")} from={643} premountFor={fps} volume={0.6} />

      {/* Clean: one tick per safety bullet */}
      <Audio name="Bullet 1" src={staticFile("sfx/switch.wav")} from={672} premountFor={fps} volume={0.4} />
      <Audio name="Bullet 2" src={staticFile("sfx/switch.wav")} from={690} premountFor={fps} volume={0.4} />
      <Audio name="Bullet 3" src={staticFile("sfx/switch.wav")} from={708} premountFor={fps} volume={0.4} />

      {/* Outro */}
      <Audio name="Whoosh to Outro" src={staticFile("sfx/whoosh.wav")} from={763} premountFor={fps} volume={0.6} />
      <Audio name="URL ding" src={staticFile("sfx/ding.wav")} from={801} premountFor={fps} volume={0.45} />
    </>
  );
};
