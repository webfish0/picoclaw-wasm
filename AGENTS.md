# PicoClaw-WASI agent instructions

Use `gpt-5.6-luna` at high effort by default for documentation, bounded source
inspection, small Go adapters, tests, examples and build scripts. Escalate to
Terra for interacting components or repeated Luna failure. Escalate to Sol for
architecture, capability/security model, public contracts, infrastructure or
difficult root-cause analysis. Record material escalations in the GitHub board.

Before each phase, inspect the `wasm-claw` project board, read the phase item,
state files in scope, acceptance criteria and verification commands. Update
`PORT_STATUS.md` after meaningful progress. Keep phase work small and avoid
changing the all-features CLI unless required by a measured dependency.

Never grant ambient host filesystem, shell, subprocess, PTY, Unix socket or
unrestricted network authority. Secrets are runtime-injected only. Unsupported
capabilities must fail explicitly. Use `rtk` for shell commands and
`apply_patch` for edits. Do not claim tests or measurements passed unless run.
