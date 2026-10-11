// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// The parts of a Uniswap V2 exchange that a sale needs to list its token.
// PancakeSwap V2 and the other V2 forks expose the same functions.

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    /// @notice Mints liquidity tokens for whatever was sent to the pair since
    /// its reserves were last recorded.
    function mint(address to) external returns (uint256 liquidity);
}

interface IWETH {
    function deposit() external payable;

    function transfer(address to, uint256 value) external returns (bool);
}
