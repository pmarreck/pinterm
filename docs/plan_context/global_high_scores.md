# Global high scores (idea, not requested)

Needs a server. A game is deterministic from its seed and inputs, and the
Linux, macOS and Windows builds reproduce each other's replays byte for byte,
so a submission could be the seed plus the input log, and the server could
replay it through the same WebAssembly core to verify the score before
accepting it. Hosting options and abuse limits are undecided.
