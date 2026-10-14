# Native build felt laggier than the web build (2026-10-10)

Setup: Linux WezTerm running inside NixOS-WSL, displayed on Windows through
WSLg (Wayland remoted to Windows over RDP), while the web build ran in a
native Windows browser.

Measured game cost: 0.37 ms CPU and about 100 output bytes per frame at
350x90. Frames already use synchronized output; pw-play runs at 40 ms latency.

Likely cause is WSLg window remoting, not the game; unconfirmed. Checks:
Windows-native WezTerm into WSL, or the native Windows build (now available).
