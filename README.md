# UHI

Implementation of the **Orbital** N-asset stableswap ([Paradigm, 2025](https://www.paradigm.xyz/2025/06/orbital)) as a Uniswap v4 hook, plus a frontend.

This is a monorepo with two top-level workspaces:

```
UHI/
├── orbitalHook/   Solidity: the v4 hook + math libraries + tests
└── frontend/      (placeholder — UI work hasn't started yet)
```

## Status

- **orbitalHook** — v1 working end-to-end in tests (82 passing). LP add/remove, fee collection, v4 swap interception with full tick-crossing solver. **Not deployment-ready** — see [orbitalHook/README.md](orbitalHook/README.md) for what's missing.
- **frontend** — not started.

## Getting started

```bash
# Hook tests
cd orbitalHook
forge test
```

The hook uses Foundry with `via_ir = true` (required by the Orbital math libraries). Submodules: clone with `--recurse-submodules` or run `git submodule update --init --recursive` after cloning.

## Reference

- Standalone Orbital AMM that the hook ports from: [`contracts/`](../contracts/) in the parent project.
- Paper: <https://www.paradigm.xyz/2025/06/orbital>
- Uniswap v4: <https://docs.uniswap.org/contracts/v4/overview>
