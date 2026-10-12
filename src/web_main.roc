app [Model, main] { pf: platform "../web/platform/main.roc" }

import Loop

## Browser entry: the web host keeps the boxed Loop state between animation
## frames and calls the same pure Loop.frame the terminal build uses.
Model : Loop.State

main = {
	init: |config| Loop.init(Loop.config_from(config)),
	load: |model, bytes| {
		(state, scores) = Loop.load_scores(model, bytes)
		status =
			match scores {
				None => 0
				Loaded(_) => 1
				Damaged => 2
			}
		{ model: state, status }
	},
	frame: |model, packet| {
		out = Loop.frame(model, packet)
		{ model: out.state, bytes: out.bytes, samples: out.samples, log: out.log, save: out.save, quit: out.quit }
	},
}
