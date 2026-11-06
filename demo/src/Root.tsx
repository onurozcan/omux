import React from 'react';
import {Composition} from 'remotion';
import {OmuxIntro} from './OmuxIntro';
import {HYPE_DURATION, OmuxHype} from './OmuxHype';
import {STORY_DURATION, OmuxStory} from './OmuxStory';
import {STARS_DURATION, OmuxStars} from './OmuxStars';
import {FPS, T} from './theme';

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="OmuxIntro"
      component={OmuxIntro}
      durationInFrames={T.end}
      fps={FPS}
      width={1920}
      height={1080}
    />
    <Composition
      id="OmuxHype"
      component={OmuxHype}
      durationInFrames={HYPE_DURATION}
      fps={FPS}
      width={1920}
      height={1080}
    />
    <Composition
      id="OmuxStory"
      component={OmuxStory}
      durationInFrames={STORY_DURATION}
      fps={FPS}
      width={1920}
      height={1080}
    />
    <Composition
      id="OmuxStars"
      component={OmuxStars}
      durationInFrames={STARS_DURATION}
      fps={FPS}
      width={1920}
      height={1080}
    />
  </>
);
