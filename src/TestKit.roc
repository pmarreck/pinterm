import Game
import Table

## Shared helpers for the Roc expectation suites: fixed-frame stepping,
## key presses and a started game with a ball placed in play.
TestKit :: [].{
	frame : F64
	frame = 1.0 / 60.0

	run_frames : Game.State, U64 -> Game.State
	run_frames = |g, n| {
		var $g = g
		var $i = 0
		while $i < n {
			$g = Game.step($g, TestKit.frame, [])
			$i = $i + 1
		}
		$g
	}

	press : Game.State, Game.Key -> Game.State
	press = |g, key| Game.step(g, TestKit.frame, [Press(key)])

	started : Game.State
	started = Game.step(Game.new(42), TestKit.frame, [Press(Start)])

	## Put one ball in play at a position with a velocity, nothing on the plunger.
	in_play : Game.State, F64, F64, F64, F64 -> Game.State
	in_play = |g, x, y, vx, vy| {
		..g,
		balls: [{ pos: { x, y }, vel: { x: vx, y: vy }, r: Table.ball_radius }],
		on_plunger: Bool.False,
		save_until: 0.0,
	}

	## Run frames with no input, collecting every frame's event log lines.
	run_logged : Game.State, U64 -> (Game.State, List(Str))
	run_logged = |g, n| {
		var $g = g
		var $lines = []
		var $i = 0
		while $i < n {
			$g = Game.step($g, TestKit.frame, [])
			$lines = List.concat($lines, $g.log)
			$i = $i + 1
		}
		($g, $lines)
	}
}
