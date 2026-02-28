# enni-contracts

core smart contracts for the ENNI protocol. immutable CDP on ethereum. 
borrow enUSD against WETH at 0% interest. no governance. no admin keys.

## contracts

| contract | description |
|---|---|
| EnniToken | ENNI ERC20. 21M fixed supply. 30-year emission. |
| EnniCDP | CDP. deposit WETH, borrow enUSD at 0% interest. |
| EnniOracle | dual-feed ETH/USD oracle. chainlink + chronicle. |
| EnniDirectMint | 1:1 USDC/USDT ↔ enUSD minting and redemption. |
| EnniMasterChef | 30-year ENNI emission schedule. up to 8 pools. |
| EnniVault | staking vault. protocol revenue donated directly to ENNI stakers.|

## license

unlicensed. all contracts are public. the code is the agreement.

## links

- site + docs: [enni.ch](https://enni.ch)
- testnet: [testnet.enni.ch](https://testnet.enni.ch)
- telegram: [t.me/enni_community](https://t.me/enni_community)
