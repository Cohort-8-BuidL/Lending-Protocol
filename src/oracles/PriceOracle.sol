// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from '@chainlink/contracts@1.5.0/src/v0.8/shared/interfaces/AggregatorV3Interface.sol';

contract PriceOracle {
  address public owner;

  // token => price feed
  mapping(address => AggregatorV3Interface) public priceFeeds;

  uint256 public constant PRECISION = 1e18;
  uint256 public constant FEED_PRECISION = 1e8;

  modifier onlyOwner() {
    require(msg.sender == owner, 'Not owner');
    _;
  }

  constructor() {
    owner = msg.sender;

    // ==============================
    //  DUMMY TOKEN IDENTIFIERS
    // ==============================
    // Since Sepolia test tokens vary, we use identifiers

    address ETH = address(1);
    address BTC = address(2);
    address USDC = address(3);
    address USDT = address(4);
    address LINK = address(5);
    address DAI = address(6);
    address AUD = address(7);

    // ==============================
    //  CHAINLINK FEEDS (SEPOLIA)
    // ==============================

    priceFeeds[ETH] = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306); // ETH/USD

    priceFeeds[BTC] = AggregatorV3Interface(0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43); // BTC/USD

    priceFeeds[USDC] = AggregatorV3Interface(0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E); // USDC/USD

    priceFeeds[USDT] = AggregatorV3Interface(0x92C09849638959196E976289418e5973CC96d645); // USDT/USD

    priceFeeds[LINK] = AggregatorV3Interface(0xc59E3633BAAC79493d908e63626716e204A45EdF); // LINK/USD

    priceFeeds[DAI] = AggregatorV3Interface(0x14866185B1962B63C3Ea9E03Bc1da838bab34C19); // DAI/USD

    priceFeeds[AUD] = AggregatorV3Interface(0xB0C712f98daE15264c8E26132BCC91C40aD4d5F9); // AUD/USD
  }

  // ==============================
  //  GET RAW PRICE
  // ==============================
  function getPrice(address asset) public view returns (uint256) {
    AggregatorV3Interface feed = priceFeeds[asset];
    require(address(feed) != address(0), 'Feed not set');

    (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();

    require(price > 0, 'Invalid price');
    require(updatedAt > block.timestamp - 1 hours, 'Stale price');

    return uint256(price);
  }

  // ==============================
  //  GET USD VALUE (IMPORTANT)
  // ==============================
  function getUsdValue(address asset, uint256 amount) external view returns (uint256) {
    uint256 price = getPrice(asset);

    // normalize to 18 decimals
    return (price * amount * PRECISION) / FEED_PRECISION;
  }

  // ==============================
  //  ADMIN: UPDATE FEEDS
  // ==============================
  function setPriceFeed(address asset, address feed) external onlyOwner {
    priceFeeds[asset] = AggregatorV3Interface(feed);
  }
}
