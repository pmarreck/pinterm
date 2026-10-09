import Audio
import Table

main! = |_args| Ok({})

themes = [Arcade, Space, Steam, Haunt, Clock]

all_fx = [Bumper(1), Sling, Flip, Launch(0.5), Drain, Rollover, LanesDone, Target, TargetsDone, Saucer, Multiball, Jackpot, Saved, Warn, Tilt, Skill, GameOver, Begin, Drop, DropsDone, Ramp(2), TableSwitch, Wall(120.0)]

pcm = |theme, fx| Audio.render(Audio.trigger_in(Audio.new(22050), theme, fx), 0.6).1

peak = |samples| samples.fold(
	0,
	|m, s| {
		v = if s < 0 0 - s.to_i64() else s.to_i64()
		if v > m v else m
	},
)

# The arcade theme is exactly the original sound (Classic stays unchanged).
expect all_fx.all(|fx| pcm(Arcade, fx) == Audio.render(Audio.trigger(Audio.new(22050), fx), 0.6).1)

# Each table theme sounds different for the start jingle, a drain and a bumper.
expect {
	distinct = |fx| {
		sounds = themes.map(|t| pcm(t, fx))
		sounds.map_with_index(|a, i| sounds.map_with_index(|b, j| i == j or a != b).all(|ok| ok)).all(|ok| ok)
	}
	distinct(Begin) and distinct(Drain) and distinct(Bumper(1))
}

# Every theme keeps every effect audible, unclipped and within the voice cap.
expect {
	themes.all(
		|t| all_fx.all(
			|fx| {
				p = peak(pcm(t, fx))
				m = Audio.trigger_in(Audio.new(22050), t, fx)
				p > 1500 and p < 32001 and m.voices.len() <= Audio.max_voices
			},
		),
	)
}

# Each table has its own theme; Classic keeps the arcade sound.
expect {
	sounds = Table.all.map(|t| t.sound)
	(Table.at(0)).sound == Arcade and sounds.map_with_index(|a, i| sounds.map_with_index(|b, j| i == j or a != b).all(|ok| ok)).all(|ok| ok)
}
