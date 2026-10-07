app [Model, main] { pf: platform "../web/platform/main.roc" }

import Loop

## Browser entry: the web host keeps the boxed Loop state between animation
## frames and calls the same pure Loop.frame the terminal build uses.
Model : Loop.State

main = {
	init: |config| Loop.init(Loop.config_from(config)),
	frame: |model, packet| {
		out = Loop.frame(model, packet)
		{ model: out.state, bytes: out.bytes, samples: out.samples, log: out.log, quit: out.quit }
	},
}
