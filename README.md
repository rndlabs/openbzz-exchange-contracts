# OpenBZZ 🌐🐝 exchange contracts

A front-end contract for interacting with the Ethereum [Swarm](https://ethswarm.org) [bonding curve](https://etherscan.io/address/0x4f32ab778e85c4ad0cead54f8f82f5ee74d46904) for buying and selling BZZ.

**Please note that contracts within this repository are experimental and unaudited.**

## Features

* Gasless approve for DAI -> BZZ exchange (uses DAI permit function).
* Bridging to [Gnosis Chain](https://gnosischain.com)

    * Send direct to a `bee` node's wallet
    * Direct top-up of a postage batch

* Fee collection for maintenance / development (see deployed site for more information).

## Tests

This a [foundry forge](https://github.com/foundry-rs/foundry) project. You can run tests:

```bash
forge test -f http://url.to.archive.node:8545 -vvv
```

To also generate coverage information use `forge coverage` instead.

## Linting

This repo currently uses `forge` as the linter. It can be called through `forge`:

```bash
forge fmt
```

## Typechain

To generate typechain bindings use:

```bash
npx typechain --target ethers-v5 --out-dir ./typechain './out/**/*.json'
```

This will generate the typechain bindings in the `typechain/` directory. This requires `typechain` to be installed and is actually best done in the consuming package (web app).


## Deployments

Swap is deployed on the following networks:

| Network | Name | Contract |
| ------- | ---- | -------- |
| Mainnet | Exchange | [0x1330391b40741a06abaeb5484b55e2458d3097b1](https://etherscan.io/address/0x1330391b40741a06abaeb5484b55e2458d3097b1) |
| Gnosis  | BzzCrossChainRouter | [0xb6aC157Ab9c4c3F2A8CbE0856a5603e730B00116](https://blockscout.com/xdai/mainnet/address/0xb6aC157Ab9c4c3F2A8CbE0856a5603e730B00116)| 

## Overview

### Exchange

`Exchange` is a simple contract that interacts with the bonding curve, allowing buying or selling of BZZ from/to the curve.

#### Approvals

The `Exchange` contract interacts with `DAI` and `BZZ`. Therefore the following approve methods are available:

* DAI: `approve()` and `permit()`
* BZZ: `approve()`

Therefore, when transacting from `DAI` to `BZZ`, it is possible to do single transactions without requiring an approval.

**NOTE: It may _appear_ similar to there being two transactions, but the first is actually a _signing_ request for signing the DAI permit, with the second pop-up being the *actual* transaction**.

#### Bridging

As Swarm mainnet's incentive contracts / accounting layer runs on the Gnosis Chain blockchain, and the bonding curve presides on Ethereum mainnet, there is a potential need for bridging between mainnet and Gnosis Chain.

For example, if a user wanted to purchase BZZ from the Bonding Curve to top-up a stamp, they would have to:

1. Approve DAI for use on the bonding curve to purchase BZZ.
2. Exchange DAI for BZZ on the bonding curve.
3. Approve the Gnosis Chain omnibridge for spending BZZ for bridging.
4. Bridge BZZ from mainnet to Gnosis Chain using the omnibridge.
5. Transfer the BZZ to their node's wallet.
6. Execute the top up transaction from their node.

This exchange contract drastically streamlines the user experience, allowing a _single_ transaction to complete all of the above.

Depending on the `bridge_cd` parameter passed to the `buy` function, a user may:

1. Purchase BZZ tokens and send them directly to an address on Gnosis Chain.
2. Purchase BZZ tokens, send them to Gnosis Chain and directly top-up a stamp.

### BZZ Cross Chain Router

`BzzCrossChainRouter` is a small utility contract that resides on Gnosis Chain and is responsible for redirecting `BZZ`. This router will:

1. Redirect `BZZ` that has been bridged, using the `onTokenBridged` callback from `HomeBridge`.
2. Redirect `BZZ` that has been transferred, using the `onTokenTransfer` callback for `ERC677` transfers.

No fees are deducted by this utility contract.