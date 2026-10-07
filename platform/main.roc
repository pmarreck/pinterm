platform ""
	requires {
		run! : () => U8
	}
	exposes [Host]
	packages {}
	provides { "pinterm_owned_bytes": fresh_bytes, "pinterm_owned_i64": fresh_i64, "pinterm_run": run_for_host! }
	hosted {
		"pinterm_host_audio": Host.audio!,
		"pinterm_host_config": Host.config!,
		"pinterm_host_control": Host.control!,
		"pinterm_host_log": Host.log!,
		"pinterm_host_present": Host.present!,
		"pinterm_host_tick": Host.tick!,
	}
	targets: {
		inputs_dir: "targets/",
		x64v1glibc: {
			inputs: ["libhost.a", app],
			output: Archive,
		},
		arm64glibc: {
			inputs: ["libhost.a", app],
			output: Archive,
		},
	}

import Host

run_for_host! : () => U8
run_for_host! = || run!()

fresh_bytes : U64 -> List(U8)
fresh_bytes = |count| List.repeat(0.U8, count)

fresh_i64 : U64 -> List(I64)
fresh_i64 = |count| List.repeat(0.I64, count)
