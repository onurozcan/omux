import React from 'react';
import {AbsoluteFill, Easing, interpolate, useCurrentFrame} from 'remotion';
import {colors} from './theme';
import {Background} from './hype/Background';
import {Caption, Kinetic, c01, hypeFont, monoFont, slam} from './hype/Kinetic';
import {Logo} from './Logo';

// 11 s celebration for the first 100 GitHub stars.
// 0–1.3 s  a star outline draws itself, the counter shows 0
// 1.3–5 s  one hundred small stars fly in from the edges; each landing fills the star a little more and ticks the counter
// 5–7 s    100 slams in, the star bursts, "stars on github"
// 7–11 s   thank you, logo, links
export const STARS_DURATION = 330;

const clamp = {extrapolateLeft: 'clamp' as const, extrapolateRight: 'clamp' as const};

// Deterministic pseudo-random in [0, 1) so every render is identical.
const rnd = (i: number, salt = 0) => {
  const x = Math.sin(i * 12.9898 + salt * 78.233 + 1.7) * 43758.5453;
  return x - Math.floor(x);
};

const easeInOut = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

const starPoints = (cx: number, cy: number, R: number, r: number) => {
  const pts: string[] = [];
  for (let k = 0; k < 10; k++) {
    const rad = k % 2 === 0 ? R : r;
    const a = -Math.PI / 2 + (k * Math.PI) / 5;
    pts.push(`${(cx + Math.cos(a) * rad).toFixed(2)},${(cy + Math.sin(a) * rad).toFixed(2)}`);
  }
  return pts.join(' ');
};

const N = 100;
const COUNT_START = 40;
const LAST_ARRIVAL = 152;
const FLIGHT = 24;
const BURST = LAST_ARRIVAL + 1;
const SCENE2 = 218;

const STAR_CX = 960;
const STAR_CY = 330;
const STAR_R = 150;
const STAR_r = 64;

const arrival = (i: number) => Math.round(COUNT_START + 12 + (LAST_ARRIVAL - COUNT_START - 12) * easeInOut(i / (N - 1)));

const palette = [colors.amber, colors.amber, colors.amber, colors.cyan, colors.violet, colors.green, '#FDE68A'];

// Small stars that fly from the edges of the frame into the big one.
const FlyingStars: React.FC<{frame: number}> = ({frame}) => {
  const items: React.ReactNode[] = [];
  for (let i = 0; i < N; i++) {
    const arr = arrival(i);
    const begin = arr - FLIGHT;
    if (frame < begin || frame >= arr) continue;
    const t = (frame - begin) / FLIGHT;
    const e = t * t * t; // accelerate into the centre
    const a = rnd(i, 2) * Math.PI * 2;
    const dist = 1050 + rnd(i, 5) * 250;
    const sx = STAR_CX + Math.cos(a) * dist;
    const sy = STAR_CY + Math.sin(a) * dist * 0.72;
    // slight curve so the paths are not all straight lines
    const curve = (rnd(i, 6) - 0.5) * 260 * Math.sin(Math.PI * t);
    const x = sx + (STAR_CX - sx) * e + Math.cos(a + Math.PI / 2) * curve;
    const y = sy + (STAR_CY - sy) * e + Math.sin(a + Math.PI / 2) * curve;
    const size = 22 + rnd(i, 3) * 20;
    const scale = interpolate(e, [0, 1], [1.1, 0.25]);
    const rot = (rnd(i, 4) - 0.5) * 540 * t;
    const col = palette[Math.floor(rnd(i, 7) * palette.length)];
    const op = c01(t * 4) * (1 - e * 0.35);
    items.push(
      <polygon
        key={i}
        points={starPoints(0, 0, size, size * 0.42)}
        fill={col}
        opacity={op}
        transform={`translate(${x.toFixed(1)} ${y.toFixed(1)}) rotate(${rot.toFixed(1)}) scale(${scale.toFixed(3)})`}
        style={{filter: `drop-shadow(0 0 ${(size * 0.5).toFixed(0)}px ${col})`}}
      />,
    );
  }
  return (
    <svg width="1920" height="1080" style={{position: 'absolute', inset: 0}}>
      {items}
    </svg>
  );
};

// Particles thrown out when the counter reaches 100.
const Burst: React.FC<{frame: number}> = ({frame}) => {
  const t = frame - BURST;
  if (t < 0 || t > 80) return null;
  const items: React.ReactNode[] = [];
  for (let k = 0; k < 90; k++) {
    const a = rnd(k, 11) * Math.PI * 2;
    const speed = 16 + rnd(k, 12) * 26;
    const vx = Math.cos(a) * speed;
    const vy = Math.sin(a) * speed - 7;
    const x = STAR_CX + vx * t * 0.92;
    const y = STAR_CY + vy * t * 0.92 + 0.55 * t * t;
    const size = 10 + rnd(k, 13) * 20;
    const col = palette[Math.floor(rnd(k, 14) * palette.length)];
    const rot = t * (rnd(k, 15) - 0.5) * 40;
    const op = (1 - c01((t - 42) / 32)) * c01(t / 2);
    items.push(
      <polygon
        key={k}
        points={starPoints(0, 0, size, size * 0.42)}
        fill={col}
        opacity={op}
        transform={`translate(${x.toFixed(1)} ${y.toFixed(1)}) rotate(${rot.toFixed(1)})`}
      />,
    );
  }
  const ring = (delay: number, max: number) => {
    const p = interpolate(t, [delay, delay + 42], [0, 1], {...clamp, easing: Easing.out(Easing.cubic)});
    return (
      <circle
        cx={STAR_CX}
        cy={STAR_CY}
        r={p * max}
        fill="none"
        stroke={colors.amber}
        strokeWidth={(1 - p) * 10 + 0.5}
        opacity={(1 - p) * 0.9}
      />
    );
  };
  return (
    <svg width="1920" height="1080" style={{position: 'absolute', inset: 0}}>
      {ring(0, 980)}
      {ring(5, 760)}
      {items}
    </svg>
  );
};

// The big star: outline draws in, then fills from the bottom as stars land.
const BigStar: React.FC<{frame: number; count: number; lastArrival: number}> = ({frame, count, lastArrival}) => {
  const draw = interpolate(frame, [6, 40], [0, 1], {...clamp, easing: Easing.inOut(Easing.cubic)});
  const fill = count / N;
  const pulse = lastArrival >= 0 ? 1 + 0.05 * (1 - c01((frame - lastArrival) / 7)) : 1;
  const done = frame >= BURST;
  const slamP = done ? slam(frame, BURST, {damping: 8, stiffness: 190, mass: 0.9}) : 0;
  const scale = done ? (1.32 - 0.32 * slamP) : pulse;
  const glow = done ? c01((frame - BURST) / 6) : fill * 0.5;
  const top = STAR_CY - STAR_R;
  const h = STAR_R * 2;
  const pts = starPoints(STAR_CX, STAR_CY, STAR_R, STAR_r);
  return (
    <svg width="1920" height="1080" style={{position: 'absolute', inset: 0, overflow: 'visible'}}>
      <defs>
        <linearGradient id="stars-fill" x1="0" y1="1" x2="0" y2="0">
          <stop offset="0" stopColor="#F59E0B" />
          <stop offset="1" stopColor="#FDE68A" />
        </linearGradient>
        <clipPath id="stars-clip">
          <rect x={STAR_CX - STAR_R - 10} y={top + h * (1 - fill)} width={STAR_R * 2 + 20} height={h * fill + 12} />
        </clipPath>
        <filter id="stars-glow" x="-80%" y="-80%" width="260%" height="260%">
          <feGaussianBlur stdDeviation="26" />
        </filter>
      </defs>
      <g transform={`translate(${STAR_CX} ${STAR_CY}) scale(${scale.toFixed(4)}) translate(${-STAR_CX} ${-STAR_CY})`}>
        <polygon points={pts} fill={colors.amber} opacity={0.55 * glow} filter="url(#stars-glow)" />
        <polygon points={pts} fill="url(#stars-fill)" clipPath="url(#stars-clip)" opacity={0.95} />
        <polygon
          points={pts}
          fill="none"
          stroke={colors.amber}
          strokeWidth={9}
          strokeLinejoin="round"
          pathLength={1}
          strokeDasharray={1}
          strokeDashoffset={1 - draw}
        />
      </g>
    </svg>
  );
};

// Faint twinkling dots behind everything.
const Twinkle: React.FC<{frame: number}> = ({frame}) => (
  <svg width="1920" height="1080" style={{position: 'absolute', inset: 0}}>
    {Array.from({length: 70}).map((_, i) => {
      const x = rnd(i, 21) * 1920;
      const y = rnd(i, 22) * 1080;
      const r = 1.2 + rnd(i, 23) * 2.2;
      const op = 0.15 + 0.4 * (0.5 + 0.5 * Math.sin(frame * (0.05 + rnd(i, 24) * 0.09) + rnd(i, 25) * 6.3));
      return <circle key={i} cx={x} cy={y} r={r} fill={i % 3 === 0 ? colors.amber : '#FFFFFF'} opacity={op} />;
    })}
  </svg>
);

const CountScene: React.FC<{frame: number}> = ({frame}) => {
  let count = 0;
  let last = -1;
  for (let i = 0; i < N; i++) {
    const a = arrival(i);
    if (frame >= a) {
      count++;
      last = Math.max(last, a);
    }
  }
  const numIn = slam(frame, COUNT_START - 4, {damping: 13, stiffness: 180});
  const done = frame >= BURST;
  const slamP = done ? slam(frame, BURST, {damping: 8, stiffness: 190, mass: 0.9}) : 0;
  const numScale = done ? 1.22 - 0.22 * slamP : 1 + (last >= 0 ? 0.03 * (1 - c01((frame - last) / 6)) : 0);
  const numColor = done ? colors.amber : colors.text;
  return (
    <AbsoluteFill>
      <Twinkle frame={frame} />
      <BigStar frame={frame} count={count} lastArrival={last} />
      <FlyingStars frame={frame} />
      <Burst frame={frame} />
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: 520,
          textAlign: 'center',
          fontFamily: hypeFont,
          fontWeight: 800,
          fontSize: 300,
          lineHeight: 1,
          letterSpacing: '-0.05em',
          fontVariantNumeric: 'tabular-nums',
          color: numColor,
          opacity: c01(numIn * 1.5),
          transform: `translateY(${(1 - numIn) * 60}px) scale(${numScale.toFixed(4)})`,
          textShadow: done ? `0 0 60px rgba(251,191,36,${(0.6 * c01((frame - BURST) / 8)).toFixed(2)})` : undefined,
        }}
      >
        {count}
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 850}}>
        <Caption text="stars on github" frame={frame} start={BURST + 10} size={54} color={colors.secondary} />
      </div>
    </AbsoluteFill>
  );
};

const ThanksScene: React.FC<{frame: number}> = ({frame}) => {
  const logoP = slam(frame, 44, {damping: 12, stiffness: 170, mass: 0.9});
  const ring = interpolate(frame, [48, 76], [0, 1], {...clamp, easing: Easing.out(Easing.cubic)});
  return (
    <AbsoluteFill>
      <Twinkle frame={frame + SCENE2} />
      <div style={{position: 'absolute', left: 0, right: 0, top: 230, display: 'flex', justifyContent: 'center'}}>
        <Kinetic
          text="thank you"
          frame={frame}
          start={2}
          size={230}
          split="letters"
          stagger={2}
          from="pop"
          weight={800}
          tracking={-0.045}
          unitColors={[colors.text]}
          damping={11}
          stiffness={210}
        />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 500}}>
        <Caption
          text="to everyone who starred, opened issues and sent pull requests"
          frame={frame}
          start={28}
          size={42}
          color={colors.secondary}
        />
      </div>
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: 660,
          display: 'flex',
          justifyContent: 'center',
          alignItems: 'center',
          gap: 32,
        }}
      >
        <div style={{transform: `scale(${Math.max(0, logoP)})`, opacity: c01(logoP * 1.5)}}>
          <Logo size={130} progress={ring} id="stars-logo" />
        </div>
        <Kinetic text="omux" frame={frame} start={48} size={120} split="letters" stagger={2} from="up" dist={70} weight={700} tracking={-0.04} align="left" damping={12} stiffness={220} />
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 850}}>
        <Caption text="omux.app  ·  github.com/onurozcan/omux" frame={frame} start={66} size={36} color={colors.secondary} mono />
      </div>
    </AbsoluteFill>
  );
};

export const OmuxStars: React.FC = () => {
  const frame = useCurrentFrame();
  const flash = interpolate(frame, [SCENE2 - 3, SCENE2, SCENE2 + 16], [0, 1, 0], clamp);
  return (
    <AbsoluteFill style={{background: colors.bg, fontFamily: hypeFont, overflow: 'hidden'}}>
      <Background frame={frame} />
      {frame < SCENE2 ? <CountScene frame={frame} /> : <ThanksScene frame={frame - SCENE2} />}
      {flash > 0 ? <AbsoluteFill style={{background: '#FFF3C4', opacity: flash}} /> : null}
    </AbsoluteFill>
  );
};
