import Game
import Physics

## Pure chiptune synthesizer: maps gameplay effects to short voices (square,
## triangle, sawtooth and pitched sample-and-hold noise with linear pitch
## sweeps and decaying envelopes) and mixes them into 16-bit mono PCM with a
## soft clipper. Deterministic: same effects and frame times give same samples.
Audio :: [].{
	Voice : { wave : U8, f0 : F64, f1 : F64, dur : F64, vol : F64, t : F64, delay : F64, phase : F64, hold : F64 }
	Mixer : { voices : List(Voice), rate : F64, carry : F64, noise : U32 }

	max_voices : U64
	max_voices = 16

	new : U64 -> Mixer
	new = |rate| { voices: [], rate: rate.to_f64(), carry: 0.0, noise: 0x1234567 }

	## Queue the voices for one gameplay effect, dropping the oldest when full.
	trigger : Mixer, Game.Fx -> Mixer
	trigger = |m, fx| {
		added = List.concat(m.voices, voices_for(fx))
		excess = if added.len() > Audio.max_voices added.len() - Audio.max_voices else 0
		{ ..m, voices: added.drop_first(excess) }
	}

	## Produce the samples covering `dt` seconds (fractional samples carry over).
	render : Mixer, F64 -> (Mixer, List(I16))
	render = |m, dt| {
		want = m.carry + m.rate * dt
		n = if want <= 0.0 0 else want.floor_to_u64_try() ?? 0
		count = if n > 8192 8192 else n
		step = 1.0 / m.rate
		var $voices = m.voices
		var $noise = m.noise
		var $out = List.with_capacity(count)
		var $i = 0
		while $i < count {
			var $acc = 0.0
			var $next = List.with_capacity($voices.len())
			for v in $voices {
				(sample, v2, noise2) = voice_sample(v, step, $noise)
				$noise = noise2
				$acc = $acc + sample
				if v2.t < v2.delay + v2.dur {
					$next = $next.append(v2)
				}
			}
			$voices = $next
			$out = $out.append(to_i16(soft_clip($acc * 0.55)))
			$i = $i + 1
		}
		({ ..m, voices: $voices, noise: $noise, carry: want - count.to_f64() }, $out)
	}
}

square : U8
square = 0

triangle : U8
triangle = 1

noise_wave : U8
noise_wave = 2

saw : U8
saw = 3

tone : U8, F64, F64, F64, F64, F64 -> Audio.Voice
tone = |wave, f0, f1, dur, vol, delay| { wave, f0, f1, dur, vol, t: 0.0, delay, phase: 0.0, hold: 0.0 }

## A short arpeggio of equal-length notes.
arp : U8, List(F64), F64, F64, F64 -> List(Audio.Voice)
arp = |wave, notes, len, vol, start| notes.map_with_index(|f, i| tone(wave, f, f, len * 1.3, vol, start + len * i.to_f64()))

voices_for : Game.Fx -> List(Audio.Voice)
voices_for = |fx| {
	match fx {
		Bumper(combo) => {
			c = if combo > 12 12.0 else combo.to_f64()
			f = 520.0 + 45.0 * c
			[tone(square, f, f * 0.5, 0.09, 0.30, 0.0), tone(noise_wave, 3000.0, 800.0, 0.04, 0.22, 0.0)]
		}
		Sling => [tone(square, 330.0, 700.0, 0.06, 0.26, 0.0), tone(noise_wave, 2000.0, 2000.0, 0.02, 0.15, 0.0)]
		Flip => [tone(triangle, 120.0, 60.0, 0.05, 0.40, 0.0), tone(noise_wave, 1500.0, 400.0, 0.03, 0.16, 0.0)]
		Launch(p) => [tone(noise_wave, 400.0, 4000.0, 0.28, 0.10 + 0.14 * p, 0.0), tone(triangle, 180.0, 520.0 + 300.0 * p, 0.22, 0.30, 0.0)]
		Drain => [tone(triangle, 440.0, 50.0, 0.75, 0.40, 0.0), tone(square, 220.0, 40.0, 0.75, 0.10, 0.0)]
		Rollover => [tone(triangle, 1320.0, 1320.0, 0.05, 0.28, 0.0), tone(triangle, 1760.0, 1760.0, 0.06, 0.28, 0.05)]
		LanesDone => arp(square, [523.0, 659.0, 784.0, 1047.0, 1319.0], 0.07, 0.22, 0.0)
		Target => [tone(square, 880.0, 880.0, 0.04, 0.22, 0.0), tone(square, 1175.0, 1175.0, 0.06, 0.22, 0.04)]
		TargetsDone => arp(saw, [392.0, 523.0, 659.0, 784.0, 1047.0], 0.08, 0.20, 0.0)
		Saucer => [tone(triangle, 200.0, 90.0, 0.16, 0.35, 0.0), tone(noise_wave, 600.0, 200.0, 0.10, 0.12, 0.0)]
		Multiball =>
			List.concat(
				arp(square, [523.0, 659.0, 784.0, 1047.0, 784.0, 1047.0, 1319.0, 1568.0], 0.09, 0.20, 0.0),
				[tone(triangle, 131.0, 131.0, 0.8, 0.30, 0.0)],
			)
		Jackpot =>
			List.concat(
				arp(saw, [784.0, 988.0, 1175.0, 1568.0, 1175.0, 1568.0, 1976.0], 0.07, 0.20, 0.0),
				[tone(noise_wave, 5000.0, 1000.0, 0.4, 0.12, 0.0)],
			)
		Saved => [tone(triangle, 660.0, 990.0, 0.15, 0.30, 0.0), tone(triangle, 660.0, 990.0, 0.15, 0.30, 0.18)]
		Warn => [tone(square, 150.0, 140.0, 0.16, 0.30, 0.0)]
		Tilt => [tone(saw, 95.0, 80.0, 0.7, 0.32, 0.0), tone(square, 97.0, 82.0, 0.7, 0.18, 0.0)]
		Skill => arp(square, [1047.0, 1319.0, 1568.0, 2093.0], 0.05, 0.22, 0.0)
		GameOver => arp(triangle, [784.0, 659.0, 523.0, 392.0, 262.0], 0.22, 0.34, 0.0)
		Begin => arp(square, [262.0, 392.0, 523.0, 784.0], 0.08, 0.22, 0.0)
		Wall(impact) => if impact > 45.0 [tone(noise_wave, 900.0, 300.0, 0.025, Physics.clamp(impact / 400.0, 0.0, 0.22), 0.0)] else []
	}
}

## One output sample of a voice, plus its advanced state and the noise LFSR.
voice_sample : Audio.Voice, F64, U32 -> (F64, Audio.Voice, U32)
voice_sample = |v, step, noise| {
	t = v.t + step
	if v.t < v.delay {
		(0.0, { ..v, t }, noise)
	} else {
		local = v.t - v.delay
		frac = Physics.clamp(local / v.dur, 0.0, 1.0)
		freq = v.f0 + (v.f1 - v.f0) * frac
		raw_phase = v.phase + freq * step
		wrapped = raw_phase >= 1.0
		phase = if wrapped raw_phase - 1.0 else raw_phase
		noise2 = if v.wave == noise_wave and wrapped noise.times_wrap(1664525).plus_wrap(1013904223) else noise
		hold = if v.wave == noise_wave and wrapped noise2.shr_zf_wrap(16).to_f64() / 32768.0 - 1.0 else v.hold
		wave =
			if v.wave == square {
				if phase < 0.5 1.0 else -1.0
			} else if v.wave == triangle {
				if phase < 0.5 4.0 * phase - 1.0 else 3.0 - 4.0 * phase
			} else if v.wave == saw {
				2.0 * phase - 1.0
			} else {
				hold
			}
		attack = Physics.clamp(local / 0.004, 0.0, 1.0)
		decay = (1.0 - frac) * (1.0 - frac)
		(wave * v.vol * attack * decay, { ..v, t, phase, hold }, noise2)
	}
}

soft_clip : F64 -> F64
soft_clip = |x| {
	# Rational tanh approximation: transparent near zero, saturates at +-1.
	c = Physics.clamp(x, -3.0, 3.0)
	c * (27.0 + c * c) / (27.0 + 9.0 * c * c)
}

to_i16 : F64 -> I16
to_i16 = |x| {
	v = Physics.clamp(x, -1.0, 1.0) * 32000.0
	v.round_to_i16_try() ?? 0
}
