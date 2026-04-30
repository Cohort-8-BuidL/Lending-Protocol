# Price Oracle (Chainlink Integration)

## Overview

This project implements a multi-asset price oracle using Chainlink Data Feeds. It enables smart contracts, such as lending protocols, to fetch reliable and up-to-date price data for various assets.

The contract is designed with safety checks to prevent the use of invalid or stale data and provides utility functions for calculating asset values in USD.

---

## Purpose

Accurate pricing is a core requirement in decentralized finance systems. This oracle is intended to support:

* Collateral valuation
* Borrowing capacity calculations
* Liquidation logic

It serves as a foundational component for building DeFi protocols.

---

## Features

* Multi-asset support (ETH, BTC, USDC, USDT, LINK, DAI, AUD)
* Integration with Chainlink decentralized price feeds
* Stale price protection using timestamp validation
* Validation to ensure returned prices are positive
* Owner-controlled feed configuration
* Utility function to compute USD value of asset amounts

---

## Contract Structure

### State Variables

* `owner`: Address of the contract owner
* `priceFeeds`: Mapping from asset identifier to Chainlink price feed
* `PRECISION`: Constant used for 18-decimal normalization
* `FEED_PRECISION`: Default Chainlink precision (1e8)

---

## Core Functions

### `getPrice(address asset) -> uint256`

Fetches the latest price for a given asset.

Includes:

* Verification that a feed is configured
* Validation that the price is greater than zero
* Staleness check to ensure the data is recent

---

### `getUsdValue(address asset, uint256 amount) -> uint256`

Returns the USD value of a specified asset amount.

Formula:
USD Value = (price × amount × precision) / feedPrecision

---

### `setPriceFeed(address asset, address feed)`

Allows the contract owner to assign or update the price feed for an asset.

---

## Supported Assets (Sepolia)

| Asset | Identifier | Price Feed |
| ----- | ---------- | ---------- |
| ETH   | address(1) | ETH/USD    |
| BTC   | address(2) | BTC/USD    |
| USDC  | address(3) | USDC/USD   |
| USDT  | address(4) | USDT/USD   |
| LINK  | address(5) | LINK/USD   |
| DAI   | address(6) | DAI/USD    |
| AUD   | address(7) | AUD/USD    |

Note: `address(1)`, `address(2)`, etc. are placeholder identifiers used for testing and mapping purposes.

---

## Network

* Tested on Sepolia testnet
* Uses Chainlink price feed contracts deployed on Sepolia

---

## Usage (Remix)

1. Deploy the contract using Injected Provider (MetaMask)
2. Ensure MetaMask is connected to the Sepolia network
3. Call functions directly from the deployed contract interface

Example:

```solidity
getPrice(0x0000000000000000000000000000000000000001)
```

This returns the ETH/USD price.

---

## Price Format

Chainlink price feeds return values with 8 decimals.

Example:

* `220843000000` represents 2208.43 USD

Solidity does not support floating-point numbers, so all values are handled as integers with scaling.

---

## License

MIT
