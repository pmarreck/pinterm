platform ""
	requires {
		[Model : model] for main : {
			init : List(I64) -> model,
			frame : model, List(U8) -> { model : model, bytes : List(U8), samples : List(I16), log : List(U8), quit : Bool },
		}
	}
	exposes []
	packages {}
	provides {
		"pinterm_web_init": init_for_host,
		"pinterm_web_frame": frame_for_host,
		"pinterm_web_release": release_for_host,
		"pinterm_web_bytes": fresh_bytes,
		"pinterm_web_i64s": fresh_i64,
	}
	hosted {}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			exports: ["web_input", "web_init", "web_frame", "web_bytes_ptr", "web_bytes_len", "web_samples_ptr", "web_samples_len", "web_log_ptr", "web_log_len", "web_quit"],
		},
	}

init_for_host : List(I64) -> Box(Model)
init_for_host = |config| Box.box((main.init)(config))

frame_for_host : Box(Model), List(U8) -> { model : Box(Model), bytes : List(U8), samples : List(I16), log : List(U8), quit : Bool }
frame_for_host = |boxed, packet| {
	out = (main.frame)(Box.unbox(boxed), packet)
	{ model: Box.box(out.model), bytes: out.bytes, samples: out.samples, log: out.log, quit: out.quit }
}

## The host returns each frame's output lists here once JavaScript has copied
## them out; Roc owns the reference counts, so dropping them here frees them.
release_for_host : List(U8), List(I16), List(U8) -> U8
release_for_host = |_bytes, _samples, _log| 0

fresh_bytes : U64 -> List(U8)
fresh_bytes = |count| List.repeat(0.U8, count)

fresh_i64 : U64 -> List(I64)
fresh_i64 = |count| List.repeat(0.I64, count)
