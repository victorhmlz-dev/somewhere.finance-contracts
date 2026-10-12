// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Stand-ins for a Uniswap V2 exchange, for the tests only. They follow the
// real contracts in what a sale depends on: how a pair is created, how `mint`
// works out the liquidity from what was sent to the pair, and `sync`. They
// leave out swaps, fees and removing liquidity.

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockPair is ERC20 {
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    address public immutable token0;
    address public immutable token1;
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(address token0_, address token1_) ERC20("Mock LP", "MOCK-LP") {
        token0 = token0_;
        token1 = token1_;
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            // The real pair locks this first bit of liquidity forever.
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min((amount0 * supply) / reserve0, (amount1 * supply) / reserve1);
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        reserve0 = balance0;
        reserve1 = balance1;
    }

    function sync() external {
        reserve0 = IERC20(token0).balanceOf(address(this));
        reserve1 = IERC20(token1).balanceOf(address(this));
    }
}

contract MockFactory {
    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
        require(getPair[tokenA][tokenB] == address(0), "PAIR_EXISTS");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        pair = address(new MockPair(token0, token1));
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
    }
}

/// A contract that refuses to receive native currency.
contract RejectsNative {
    function contribute(address sale) external payable {
        (bool sent, ) = sale.call{value: msg.value}(abi.encodeWithSignature("contribute()"));
        require(sent, "contribute failed");
    }
}

/// An exchange that refuses every new pair, to test a listing that cannot happen.
contract RefusingFactory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }

    function createPair(address, address) external pure returns (address) {
        revert("PAIR_CREATION_DISABLED");
    }
}
