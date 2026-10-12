// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Launchpad} from "../contracts/Launchpad.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {TokenSale} from "../contracts/TokenSale.sol";
import {CreatorVesting} from "../contracts/CreatorVesting.sol";
import {IUniswapV2Factory} from "../contracts/interfaces/IUniswapV2.sol";
import {MockFactory, MockPair, MockWETH} from "../contracts/test/MockDex.sol";

/// Deploys a launchpad on the exchange doubles and creates launches on it.
abstract contract LaunchpadFixture is Test {
    uint256 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal platform = makeAddr("platform");
    address internal feeWallet = makeAddr("feeWallet");
    address internal creator = makeAddr("creator");

    MockWETH internal weth;
    MockFactory internal dexFactory;
    Launchpad internal launchpad;

    struct Deployed {
        LaunchToken token;
        TokenSale sale;
        CreatorVesting vesting;
    }

    function deployLaunchpad(uint16 feeBps) internal {
        weth = new MockWETH();
        dexFactory = new MockFactory();
        launchpad = new Launchpad(
            platform,
            IUniswapV2Factory(address(dexFactory)),
            address(weth),
            feeWallet,
            feeBps
        );
    }

    function defaultParams() internal view returns (Launchpad.LaunchParams memory) {
        return
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
            });
    }

    function createLaunch(
        Launchpad.LaunchParams memory params
    ) internal returns (Deployed memory deployed) {
        vm.prank(creator);
        (, address token, address sale) = launchpad.createLaunch(params);
        deployed.token = LaunchToken(token);
        deployed.sale = TokenSale(payable(sale));
        deployed.vesting = deployed.sale.vesting();
    }
}

/// Each test runs many times with random inputs.
contract LaunchpadFuzzTest is LaunchpadFixture {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployLaunchpad(50);
    }

    /// Whatever the creator asks for, the supply covers the creator, the sale
    /// and the liquidity reserve, and the creator never gets more than 1%.
    function testFuzz_SupplyAlwaysCoversEveryAllocation(
        uint256 totalSupply,
        uint16 creatorBps,
        uint16 liquidityBps
    ) public {
        Launchpad.LaunchParams memory params = defaultParams();
        params.totalSupply = bound(totalSupply, 1_000e18, 1e33);
        params.creatorAllocationBps = uint16(bound(creatorBps, 0, 100));
        params.liquidityBps = uint16(bound(liquidityBps, 7000, 9950));

        Deployed memory d = createLaunch(params);

        uint256 creatorAllocation = d.sale.creatorAllocation();
        uint256 forSale = d.sale.tokensForSale();
        uint256 liquidityReserve = (forSale * params.liquidityBps) / BPS;
        assertLe(creatorAllocation * 100, params.totalSupply, "creator above 1%");
        assertLe(
            creatorAllocation + forSale + liquidityReserve,
            params.totalSupply,
            "allocations exceed supply"
        );
        assertEq(d.token.balanceOf(address(d.sale)), params.totalSupply);
        assertEq(d.token.totalSupply(), params.totalSupply);
    }

    /// Parameters outside the published limits never produce a launch.
    function testFuzz_LimitsCannotBeSkipped(
        uint16 creatorBps,
        uint16 liquidityBps,
        uint8 tranches
    ) public {
        bool valid = creatorBps <= 100 &&
            liquidityBps >= 7000 &&
            liquidityBps <= 9950 &&
            tranches >= 3 &&
            tranches <= 48;
        vm.assume(!valid);

        Launchpad.LaunchParams memory params = defaultParams();
        params.creatorAllocationBps = creatorBps;
        params.liquidityBps = liquidityBps;
        params.vestingTranches = tranches;

        vm.prank(creator);
        vm.expectRevert();
        launchpad.createLaunch(params);
    }

    /// The fee can never be set above 1%.
    function testFuzz_FeeNeverAboveOnePercent(uint16 feeBps) public {
        vm.prank(platform);
        if (feeBps > 100) {
            vm.expectRevert(Launchpad.FeeTooHigh.selector);
            launchpad.setFee(feeBps);
        } else {
            launchpad.setFee(feeBps);
            assertEq(launchpad.feeBps(), feeBps);
        }
    }

    /// However much is raised and however it is configured, a finalized sale
    /// sends at least 70% to locked liquidity, at most 1% to the platform, and
    /// accounts for every wei and every token.
    function testFuzz_FinalizeAccountsForEverything(
        uint256 raised,
        uint16 liquidityBps,
        uint16 feeBps,
        uint16 creatorBps,
        uint8 tranches
    ) public {
        feeBps = uint16(bound(feeBps, 0, 100));
        vm.prank(platform);
        launchpad.setFee(feeBps);

        Launchpad.LaunchParams memory params = defaultParams();
        params.liquidityBps = uint16(bound(liquidityBps, 7000, BPS - feeBps));
        params.creatorAllocationBps = uint16(bound(creatorBps, 0, 100));
        params.vestingTranches = uint8(bound(tranches, 3, 48));
        raised = bound(raised, params.softCap, params.hardCap);

        Deployed memory d = createLaunch(params);
        vm.warp(params.startTime);
        hoax(alice, raised);
        d.sale.contribute{value: raised}();
        // A sale that sold out can be finalized right away; any other has to
        // reach its end first.
        if (raised < params.hardCap) vm.warp(params.endTime);
        d.sale.finalize();

        address pair = d.sale.pair();
        uint256 liquidityNative = weth.balanceOf(pair);
        uint256 fee = d.sale.feeOwed();
        uint256 creatorNative = address(d.vesting).balance;

        // Every wei raised is in exactly one of three places.
        assertEq(liquidityNative + fee + creatorNative, raised, "native not conserved");
        assertEq(address(d.sale).balance, fee, "sale holds more than the fee");
        // The published rules.
        assertGe(liquidityNative * BPS, raised * 7000 - BPS, "less than 70% to liquidity");
        assertLe(fee * 100, raised, "fee above 1%");
        // The liquidity can never be withdrawn.
        assertEq(MockPair(pair).balanceOf(DEAD), MockPair(pair).totalSupply(), "LP not locked");
        // Every token is in exactly one of four places.
        uint256 sold = d.sale.tokensFor(raised);
        assertEq(d.token.balanceOf(address(d.sale)), sold, "sale cannot cover claims");
        assertEq(d.token.balanceOf(address(d.vesting)), d.sale.creatorAllocation());
        assertEq(
            d.token.balanceOf(pair) +
                d.token.balanceOf(address(d.sale)) +
                d.token.balanceOf(address(d.vesting)) +
                d.token.balanceOf(DEAD),
            params.totalSupply,
            "tokens not conserved"
        );
        // The creator holds nothing yet.
        assertEq(d.token.balanceOf(creator), 0);
        assertEq(creator.balance, 0);
    }

    /// A sale that ends below its soft cap returns every contribution in full
    /// and charges no fee.
    function testFuzz_FailedSaleRefundsEverything(uint256 fromAlice, uint256 fromBob) public {
        Launchpad.LaunchParams memory params = defaultParams();
        fromAlice = bound(fromAlice, 1, params.softCap - 2);
        fromBob = bound(fromBob, 1, params.softCap - 1 - fromAlice);

        Deployed memory d = createLaunch(params);
        vm.warp(params.startTime);
        hoax(alice, fromAlice);
        d.sale.contribute{value: fromAlice}();
        hoax(bob, fromBob);
        d.sale.contribute{value: fromBob}();
        vm.warp(params.endTime);

        assertEq(uint8(d.sale.status()), uint8(TokenSale.Status.Failed));
        vm.prank(alice);
        d.sale.refund();
        vm.prank(bob);
        d.sale.refund();

        assertEq(alice.balance, fromAlice);
        assertEq(bob.balance, fromBob);
        assertEq(address(d.sale).balance, 0);
        assertEq(d.sale.feeOwed(), 0);
        assertEq(feeWallet.balance, 0);
    }

    /// Contributors can always claim exactly what they paid for, in any split.
    function testFuzz_ClaimsMatchContributions(uint256 fromAlice) public {
        Launchpad.LaunchParams memory params = defaultParams();
        fromAlice = bound(fromAlice, 1, params.hardCap - 1);
        uint256 fromBob = params.hardCap - fromAlice;

        Deployed memory d = createLaunch(params);
        vm.warp(params.startTime);
        hoax(alice, fromAlice);
        d.sale.contribute{value: fromAlice}();
        hoax(bob, fromBob);
        d.sale.contribute{value: fromBob}();
        d.sale.finalize();

        vm.prank(alice);
        d.sale.claim();
        vm.prank(bob);
        d.sale.claim();

        assertEq(d.token.balanceOf(alice), d.sale.tokensFor(fromAlice));
        assertEq(d.token.balanceOf(bob), d.sale.tokensFor(fromBob));
        // Rounding down can leave at most one unit per contributor behind.
        assertLt(d.token.balanceOf(address(d.sale)), 2);
    }

    /// At any moment, the creator has received exactly the tranches that are
    /// due, and by the end, everything.
    function testFuzz_VestingPaysOnlyWhatIsDue(
        uint8 tranches,
        uint256 firstWait,
        uint256 secondWait
    ) public {
        Launchpad.LaunchParams memory params = defaultParams();
        params.vestingTranches = uint8(bound(tranches, 3, 48));
        firstWait = bound(firstWait, 0, 60 * 30 days);
        secondWait = bound(secondWait, 0, 60 * 30 days);

        Deployed memory d = createLaunch(params);
        vm.warp(params.startTime);
        hoax(alice, params.hardCap);
        d.sale.contribute{value: params.hardCap}();
        d.sale.finalize();
        uint256 listedAt = block.timestamp;
        uint256 totalNative = d.vesting.totalNative();
        uint256 totalTokens = d.vesting.totalTokens();

        uint256[2] memory waits = [firstWait, secondWait];
        for (uint256 i = 0; i < 2; i++) {
            vm.warp(block.timestamp + waits[i]);
            uint256 due = (block.timestamp - listedAt) / 30 days;
            if (due > params.vestingTranches) due = params.vestingTranches;

            try d.vesting.release() {} catch {}

            assertEq(creator.balance, (totalNative * due) / params.vestingTranches);
            assertEq(d.token.balanceOf(creator), (totalTokens * due) / params.vestingTranches);
        }

        vm.warp(listedAt + uint256(params.vestingTranches) * 30 days);
        try d.vesting.release() {} catch {}
        assertEq(creator.balance, totalNative);
        assertEq(d.token.balanceOf(creator), totalTokens);
        assertEq(address(d.vesting).balance, 0);
    }
}
