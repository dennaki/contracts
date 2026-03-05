# enni-contracts

core smart contracts for the ENNI protocol. immutable multi-currency CDP on ethereum.
borrow stablecoins against WETH at 0% interest. no governance. no admin keys.

currently live: **enUSD** (USD) and **enCHF** (CHF). more currencies can be deployed by anyone. same contracts, new constructor args.

## contracts

| contract | description |
|---|---|
| EnniToken | ERC20 with dual minter slots and hard supply cap. reused for ENNI (21M fixed), enUSD, enCHF, and all future tokens. |
| EnniCDP | CDP. deposit WETH, borrow stablecoins at 0% interest. one instance per currency. |
| EnniOracle | dual-feed ETH/USD oracle (chainlink + chronicle) with optional translator for non-USD currencies. one instance per currency. |
| EnniDirectMint | 1:1 USDC/USDT ↔ enUSD minting and redemption. enUSD only. |
| EnniMasterChef | 30-year ENNI emission schedule. up to 8 pools. |
| EnniVault | staking vault. protocol revenue donated directly to ENNI stakers. |

## license

unlicensed.

## links

- site + docs: [enni.ch](https://enni.ch)
- testnet: [testnet.enni.ch](https://testnet.enni.ch)
- telegram: [t.me/enni_community](https://t.me/enni_community)
