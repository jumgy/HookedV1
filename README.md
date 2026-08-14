# HookedV1

Uniswap v4 hook for gated MainToken/USDG listings on **Robinhood Chain** (chain id `4663`).

## Deployed

- **Hook:** [`0x46C4455F65Da6d0E8Bb0274E257F99733ddE2544`](https://robinhoodchain.blockscout.com/address/0x46C4455F65Da6d0E8Bb0274E257F99733ddE2544)
- **PoolId:** `0x12d060f5e55b84e5882955278c090ad43ac43b48148401bbb8959d671f40ba75`
- **DexScreener:** https://dexscreener.com/robinhood/0x12d060f5e55b84e5882955278c090ad43ac43b48148401bbb8959d671f40ba75

## Source layout

| Path | Role |
|------|------|
| `src/core/HookedV1.sol` | Hook implementation |
| `src/base/BaseHook.sol` | Uniswap v4 hook base |
| `src/interfaces/*` | Fee collector / jackpot / MainToken interfaces |
| `src/libraries/HookDeployHelper.sol` | CREATE2 flag helper |

Depends on Uniswap v4-core, OpenZeppelin (via Foundry remappings in the parent project).

See `VERIFICATION.md` for Labs form copy and addresses.
