import Game
import Input
import Render
import Audio
import Table

## Pure per-tick application step between the host and the game: decodes the
## host tick packet (clock, terminal size, flags, input bytes), routes UI keys
## (quit, mute, help, suspend, redraw), steps the game, mixes audio and
## renders a diffed frame. The effectful shell in main.roc only moves bytes.
Loop :: [].{
	Config : { cols : U64, rows : U64, color : U8, ascii : Bool, sound : Bool, seed : U64, rate : U64, headless : Bool, fps : U64 }
	State : {
		cfg : Config,
		game : Game.State,
		mixer : Audio.Mixer,
		prev : List(Render.Cell),
		lay : Render.Layout,
		bases : List(List(U32)),
		opts : Render.Opts,
		last_us : U64,
		sound : Bool,
	}
	Out : { state : State, bytes : List(U8), samples : List(I16), log : List(U8), quit : Bool, suspend : Bool }

	config_from : List(I64) -> Config
	config_from = |v| {
		at = |i| v.get(i) ?? 0
		fps0 = at(9)
		{
			cols: clamp_u64(at(0), 20, 1000),
			rows: clamp_u64(at(1), 10, 500),
			color: clamp_u64(at(2), 0, 3).to_u8_wrap(),
			ascii: at(3) != 0,
			sound: at(4) != 0,
			seed: at(5).to_u64_wrap(),
			rate: clamp_u64(at(6), 8000, 96000),
			headless: at(7) != 0,
			fps: if fps0 <= 0 60 else clamp_u64(fps0, 20, 120),
		}
	}

	init : Config -> State
	init = |cfg| {
		lay = Render.layout(cfg.cols, cfg.rows)
		{
			cfg,
			game: Game.new(cfg.seed),
			mixer: Audio.new(cfg.rate),
			prev: [],
			lay,
			bases: List.repeat([], Table.count),
			opts: { color: cfg.color, ascii: cfg.ascii, sound: cfg.sound, help: Bool.False, fps: cfg.fps },
			last_us: 0,
			sound: cfg.sound,
		}
	}

	frame : State, List(U8) -> Out
	frame = |s0, packet| {
		now_us = le_u64(packet, 0)
		cols = le_u16(packet, 8)
		rows = le_u16(packet, 10)
		flags = packet.get(12) ?? 0
		input = packet.drop_first(13)
		quit_flag = flags.bitwise_and(1) != 0
		resized = flags.bitwise_and(2) != 0
		nominal = 1.0 / s0.cfg.fps.to_f64()
		dt = if s0.last_us == 0 or now_us <= s0.last_us nominal else (now_us - s0.last_us).to_f64() / 1000000.0
		s1 =
			if resized and (cols != s0.lay.cols or rows != s0.lay.rows or s0.prev.is_empty()) and cols > 0 and rows > 0 {
				lay = Render.layout(cols, rows)
				{ ..s0, lay, bases: List.repeat([], Table.count), prev: [] }
			} else if resized {
				{ ..s0, prev: [] }
			} else {
				s0
			}
		events = Input.parse(input)
		routed = events.fold({ s: s1, game_events: [], quit: Bool.False, suspend: Bool.False }, route)
		s2 = routed.s
		game = Game.step(s2.game, dt, routed.game_events)
		mixer0 = if s2.sound game.fx.fold(s2.mixer, |m, fx| Audio.trigger_in(m, game.table.sound, fx)) else s2.mixer
		(mixer, pcm) = Audio.render(mixer0, dt)
		samples = if s2.sound pcm else []
		bases0 = ensure_base(s2.bases, s2.lay, game.table_index)
		sliding = Game.transition(game) < 1.0
		bases = if sliding ensure_base(bases0, s2.lay, game.transition_from) else bases0
		base = bases.get(game.table_index) ?? []
		from_base = if sliding bases.get(game.transition_from) ?? [] else []
		cells = Render.compose(game, s2.opts, s2.lay, base, from_base)
		bytes = Render.encode(s2.prev, cells, s2.lay.cols, s2.opts.color)
		log = game.log.fold([], |acc, line| List.concat(acc, Str.to_utf8("f=${game.frame.to_str()} ${line}\n")))
		{
			state: { ..s2, game, mixer, bases, prev: cells, last_us: now_us },
			bytes,
			samples,
			log,
			quit: quit_flag or routed.quit,
			suspend: routed.suspend,
		}
	}

	bool_str : Bool -> Str
	bool_str = |b| if b "on" else "off"
}

Routed : { s : Loop.State, game_events : List(Game.Event), quit : Bool, suspend : Bool }

route : Routed, Input.Ev -> Routed
route = |r, ev| {
	s = r.s
	match ev {
		Press(Quit) => { ..r, quit: Bool.True }
		Press(Mute) => {
			sound = !s.sound
			{ ..r, s: { ..s, sound, opts: { ..s.opts, sound }, mixer: { ..s.mixer, voices: [] } } }
		}
		Press(Help) => { ..r, s: { ..s, opts: { ..s.opts, help: !s.opts.help } } }
		Press(Suspend) => { ..r, suspend: Bool.True, s: { ..s, prev: [] } }
		Press(Redraw) => { ..r, s: { ..s, prev: [] } }
		Press(k) => game_key(r, k, Press)
		Release(k) => game_key(r, k, Release)
	}
}

game_key : Routed, Input.Key, [Press, Release] -> Routed
game_key = |r, k, kind| {
	mapped =
		match k {
			LeftFlip => [LeftFlip]
			RightFlip => [RightFlip]
			Plunger => [Plunger]
			Start => [Start]
			Nudge => [Nudge]
			Pause => [Pause]
			New => [New]
			PrevTable => [PrevTable]
			NextTable => [NextTable]
			_ => []
		}
	evs = mapped.map(
		|gk| {
			match kind {
				Press => Press(gk)
				Release => Release(gk)
			}
		},
	)
	{ ..r, game_events: List.concat(r.game_events, evs) }
}

clamp_u64 : I64, I64, I64 -> U64
clamp_u64 = |v, lo, hi| {
	c = if v < lo lo else if v > hi hi else v
	c.to_u64_wrap()
}

le_u16 : List(U8), U64 -> U64
le_u16 = |b, i| (b.get(i) ?? 0).to_u64() + (b.get(i + 1) ?? 0).to_u64().shl_wrap(8)

le_u64 : List(U8), U64 -> U64
le_u64 = |b, i| {
	var $v = 0
	var $k = 0
	while $k < 8 {
		$v = $v.bitwise_or((b.get(i + $k) ?? 0).to_u64().shl_wrap(($k * 8).to_u8_wrap()))
		$k = $k + 1
	}
	$v
}

## Static rasters are cached per table and built the first time each table is
## shown at the current terminal size (a resize clears the cache).
ensure_base : List(List(U32)), Render.Layout, U64 -> List(List(U32))
ensure_base = |bases, lay, index| {
	have = (bases.get(index) ?? []).len() > 0
	if have or !lay.ok bases else bases.set(index, Render.static_pixels(lay, Table.at(index))) ?? bases
}
