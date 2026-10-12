// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Launchpad} from "../contracts/Launchpad.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {TokenSale} from "../contracts/TokenSale.sol";
import {IUniswapV2Factory} from "../contracts/interfaces/IUniswapV2.sol";

interface IRealRouter {
    function factory() external view returns (address);

    function WETH() external view returns (address);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IRealPair {
    function token0() external view returns (address);

    function getReserves() external view returns (uint112, uint112, uint32);

    function balanceOf(address owner) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function sync() external;
}

interface IRealWETH {
    function deposit() external payable;

    function transfer(address to, uint256 value) external returns (bool);
}

/// Runs a launch against the real Uniswap V2 deployed on Sepolia, on a local
/// copy of that chain. Nothing is sent to the network.
///
/// Needs a Sepolia node: set the SEPOLIA_FORK_URL environment variable to its
/// URL. Without it these tests are skipped.
contract LaunchpadForkTest is Test {
    // Uniswap V2 on Ethereum Sepolia, from the official deployments page:
    // https://developers.uniswap.org/docs/protocols/v2/deployments
    address internal constant UNISWAP_V2_FACTORY = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;
    address internal constant UNISWAP_V2_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    address internal platform = makeAddr("platform");
    address internal feeWallet = makeAddr("feeWallet");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal trader = makeAddr("trader");

    IRealRouter internal router = IRealRouter(UNISWAP_V2_ROUTER);
    address internal weth;
    Launchpad internal launchpad;
    LaunchToken internal token;
    TokenSale internal sale;

    function setUp() public {
        string memory forkUrl = vm.envOr("SEPOLIA_FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(forkUrl);

        // The documented router and factory belong together on this chain.
        assertEq(router.factory(), UNISWAP_V2_FACTORY, "router and factory do not match");
        weth = router.WETH();

        launchpad = new Launchpad(
            platform,
            IUniswapV2Factory(UNISWAP_V2_FACTORY),
            weth,
            feeWallet,
            50
        );
        vm.prank(creator);
        (, address token_, address sale_) = launchpad.createLaunch(
            Launchpad.LaunchParams({
                name: "Void Token",
                symbol: "VOID",
                totalSupply: 1_000_000e18,
                softCap: 2 ether,
                hardCap: 10 ether,
                minContribution: 0,
                maxContribution: 0,
                startTime: uint64(block.timestamp + 1 hours),
                endTime: uint64(block.timestamp + 1 hours + 7 days),
                creatorAllocationBps: 100,
                liquidityBps: 7000,
                vestingTranches: 3
            })
        );
        token = LaunchToken(token_);
        sale = TokenSale(payable(sale_));

        vm.warp(sale.startTime());
        hoax(alice, 10 ether);
        sale.contribute{value: 10 ether}();
    }

    function test_ListsOnRealUniswapWithLockedLiquidity() public {
        sale.finalize();

        IRealPair pair = IRealPair(sale.pair());
        assertEq(
            IUniswapV2Factory(UNISWAP_V2_FACTORY).getPair(address(token), weth),
            address(pair),
            "not the pair the factory knows"
        );

        // 70% of the raise and the matching tokens are the pool's reserves.
        uint256 liquidityTokens = (sale.tokensForSale() * 7000) / 10_000;
        (uint256 tokenReserve, uint256 wethReserve) = _reserves(pair);
        assertEq(wethReserve, 7 ether);
        assertEq(tokenReserve, liquidityTokens);
        assertEq(IERC20(weth).balanceOf(address(pair)), 7 ether);

        // Uniswap burns the first 1,000 units of liquidity itself; all the
        // rest belongs to the dead address. Nobody can withdraw any of it.
        assertEq(pair.balanceOf(DEAD) + MINIMUM_LIQUIDITY, pair.totalSupply());
        assertEq(pair.balanceOf(address(0)), MINIMUM_LIQUIDITY);
        assertEq(pair.balanceOf(creator), 0);
        assertEq(pair.balanceOf(address(sale)), 0);
        assertEq(pair.balanceOf(address(launchpad)), 0);
    }

    function test_TokenTradesOnRealUniswapAtTheSalePrice() public {
        sale.finalize();
        vm.prank(alice);
        sale.claim();

        // Buying: a small purchase gets close to the sale price, minus the
        // 0.3% exchange fee and its own price impact.
        address[] memory buyPath = new address[](2);
        buyPath[0] = weth;
        buyPath[1] = address(token);
        hoax(trader, 0.01 ether);
        router.swapExactETHForTokens{value: 0.01 ether}(0, buyPath, trader, block.timestamp);
        uint256 bought = token.balanceOf(trader);
        uint256 atSalePrice = sale.tokensFor(0.01 ether);
        assertLt(bought, atSalePrice);
        assertGt(bought, (atSalePrice * 99) / 100);

        // Selling: a contributor can sell what they claimed.
        address[] memory sellPath = new address[](2);
        sellPath[0] = address(token);
        sellPath[1] = weth;
        uint256 toSell = token.balanceOf(alice) / 100;
        vm.startPrank(alice);
        token.approve(address(router), toSell);
        router.swapExactTokensForETH(toSell, 0, sellPath, alice, block.timestamp);
        vm.stopPrank();
        assertGt(alice.balance, 0);
    }

    function test_ListsEvenIfThePairWasCreatedAndUnbalancedFirst() public {
        // The attack: create the pair early, donate WETH and record it as a
        // reserve. A launch that adds liquidity through the router reverts.
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        address pairAddress = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(
            address(token),
            weth
        );
        vm.deal(attacker, 1 ether);
        IRealWETH(weth).deposit{value: 1 ether}();
        IRealWETH(weth).transfer(pairAddress, 1 ether);
        IRealPair(pairAddress).sync();
        vm.stopPrank();

        sale.finalize();

        IRealPair pair = IRealPair(pairAddress);
        assertEq(sale.pair(), pairAddress);
        (, uint256 wethReserve) = _reserves(pair);
        // The attacker's ether ends up locked with everybody else's.
        assertEq(wethReserve, 8 ether);
        assertEq(pair.balanceOf(attacker), 0);
        assertEq(pair.balanceOf(DEAD) + MINIMUM_LIQUIDITY, pair.totalSupply());
    }

    function _reserves(
        IRealPair pair
    ) private view returns (uint256 tokenReserve, uint256 wethReserve) {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        (tokenReserve, wethReserve) = pair.token0() == address(token)
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
    }
}
