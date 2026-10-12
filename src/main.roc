app [run!] { pf: platform "../platform/main.roc" }

import pf.Host
import Loop

## Effectful shell around the pure core: each tick reads the host's clock,
## size and input bytes, advances the game, then presents the diffed frame,
## synthesized audio and structured event lines.
run! : () => U8
run! = || {
	cfg = Loop.config_from(Host.config!())
	var $state = Loop.init(cfg)
	var $running = Bool.True
	_ = Host.log!(Str.to_utf8("event boot cols=${cfg.cols.to_str()} rows=${cfg.rows.to_str()} sound=${Loop.bool_str(cfg.sound)}\n"))
	(loaded, scores) = Loop.load_scores($state, Host.load_scores!())
	$state = loaded
	if scores == Damaged {
		Host.control!(2)
	}
	_ = Host.log!(Str.to_utf8("${Loop.scores_event(scores)}\n"))
	while $running {
		packet = Host.tick!()
		out = Loop.frame($state, packet)
		$state = out.state
		if out.suspend {
			Host.control!(1)
		}
		if !out.samples.is_empty() {
			_ = Host.audio!(out.samples)
		}
		if !out.save.is_empty() {
			_ = Host.save_scores!(out.save)
		}
		if !out.log.is_empty() {
			_ = Host.log!(out.log)
		}
		_ = Host.present!(out.bytes)
		if out.quit {
			$running = Bool.False
		}
	}
	g = $state.game
	_ = Host.log!(Str.to_utf8("event exit frames=${g.frame.to_str()} score=${g.score.to_str()} high=${g.high.to_str()} ball=${g.ball_number.to_str()}\n"))
	0
}
