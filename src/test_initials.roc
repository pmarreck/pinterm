import Game
import Scores
import TestKit

main! = |_args| Ok({})

run_frames = TestKit.run_frames

press = TestKit.press

# ---------- high-score initials entry ----------

e : Str, I64 -> Scores.Entry
e = |initials, score| { initials, score }

strong : List(Scores.Entry)
strong = [e("AAA", 9000), e("BBB", 8000), e("CCC", 7000), e("DDD", 6000), e("EEE", 5000)]

## Drain the third ball with `score` on table 0 whose list is `book`, stopping
## on the first frame after the game ends.
finish : List(Scores.Entry), I64 -> Game.State
finish = |book, score| {
	g0 = Game.with_books(TestKit.started, [book, [], [], [], []])
	var $g = { ..TestKit.in_play(g0, 22.0, 80.0, 0.0, 50.0), ball_number: 3, score }
	var $n = 0
	while ($g.mode == Playing or $g.mode == BallOver) and $n < 600 {
		$g = Game.step($g, TestKit.frame, [])
		$n = $n + 1
	}
	$g
}

entering : Game.State
entering = finish([], 1234)

text : Game.State -> Str
text = |g| Str.from_utf8(g.initials.chars.map(|i| Scores.charset.get(i) ?? '?')) ?? ""

presses : Game.State, List(Game.Key) -> Game.State
presses = |g, keys| keys.fold(g, press)

book0 : Game.State -> List(Scores.Entry)
book0 = |g| g.books.first() ?? []

# A qualifying score (1234 plus the end-of-ball bonus) at game over asks for
# initials, starting blank at the first position.
expect entering.mode == Initials and text(entering) == "   " and entering.initials.cursor == 0

# A score that misses the list goes straight to game over and saves nothing.
expect {
	over = finish(strong, 1234)
	over.mode == GameOver and book0(over) == strong
}

# The left flipper cycles the letter: space, A-Z, 0-9, _ - * ! ? then wraps.
expect {
	cycle = |n| text(presses(entering, List.repeat(LeftFlip, n)))
	cycle(1) == "A  " and cycle(26) == "Z  " and cycle(27) == "0  " and cycle(37) == "_  " and cycle(41) == "?  " and cycle(42) == "   "
}

# The right flipper moves the cursor and wraps after the third letter.
expect {
	g = presses(entering, [LeftFlip, RightFlip, LeftFlip, LeftFlip, RightFlip, LeftFlip, LeftFlip, LeftFlip, RightFlip, LeftFlip])
	g.mode == Initials and text(g) == "BBC" and g.initials.cursor == 0
}

# Three cursor moves in a row with no letter change lock the initials in.
expect {
	g = presses(entering, [LeftFlip, RightFlip, RightFlip, RightFlip])
	g.mode == GameOver and book0(g) == [e("A  ", entering.score)]
}

# A letter change resets that count.
expect {
	g = presses(entering, [LeftFlip, RightFlip, LeftFlip, RightFlip, RightFlip])
	locked = press(g, RightFlip)
	g.mode == Initials and locked.mode == GameOver and book0(locked) == [e("AA ", entering.score)]
}

# Ten seconds without input lock the initials in; any input restarts the wait.
expect {
	waited = run_frames(entering, 590)
	timed_out = run_frames(entering, 610)
	poked = run_frames(press(run_frames(entering, 300), LeftFlip), 500)
	waited.mode == Initials and timed_out.mode == GameOver and book0(timed_out) == [e("   ", entering.score)] and poked.mode == Initials
}

# Locking in inserts the entry, raises the table's high score, and asks the
# host to save with an event and a log line.
expect {
	g = finish([e("TOP", 5000), e("LOW", 10)], 1234)
	locked = presses(g, [LeftFlip, RightFlip, RightFlip, RightFlip])
	book0(locked) == [e("TOP", 5000), e("A  ", g.score), e("LOW", 10)] and locked.high == 5000 and locked.fx.contains(ScoresChanged) and locked.log.contains("event initials table=0 text=\"A  \" score=${g.score.to_str()}")
}

# A new best score becomes the table's high score.
expect presses(entering, [RightFlip, RightFlip, RightFlip]).high == entering.score

# While entering, table switching and Start do nothing; New locks the entry
# in, then starts a fresh game.
expect {
	g = press(entering, LeftFlip)
	switched = press(g, NextTable)
	started = press(g, Start)
	fresh = press(g, New)
	switched.mode == Initials and switched.table_index == 0 and started.mode == Initials and fresh.mode == Playing and book0(fresh) == [e("A  ", entering.score)]
}

# Loaded lists set each table's high score, and switching tables keeps them.
expect {
	g = Game.with_books(Game.new(1), [[e("ONE", 100)], [e("TWO", 200)], [], [], []])
	next = press(g, NextTable)
	g.high == 100 and next.high == 200 and next.books == g.books
}
