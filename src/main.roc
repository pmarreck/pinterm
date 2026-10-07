app [run!] { pf: platform "../platform/main.roc" }

import pf.Host

run! : () => U8
run! = || {
	cfg = Host.config!()
	_ = Host.present!(Str.to_utf8("hello ${cfg.len().to_str()}\n"))
	_ = Host.log!(Str.to_utf8("event start\n"))
	_ = Host.audio!([1, 2, 3])
	packet = Host.tick!()
	_ = Host.log!(Str.to_utf8("tick ${packet.len().to_str()}\n"))
	0
}
