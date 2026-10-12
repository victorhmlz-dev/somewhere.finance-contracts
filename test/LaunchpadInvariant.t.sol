// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Launchpad} from "../contracts/Launchpad.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {TokenSale} from "../contracts/TokenSale.sol";
import {CreatorVesting} from "../contracts/CreatorVesting.sol";
import {MockPair} from "../contracts/test/MockDex.sol";
import {LaunchpadFixture} from "./LaunchpadFuzz.t.sol";

/// The actions anyone can take on a launch. The invariant test calls them in
/// random order with random arguments; a call that reverts is simply an
/// action that was not allowed at that moment.
contract LaunchHandler is Test {
    TokenSale public immutable sale;
    CreatorVesting public immutable vesting;
    address[] public actors;

    // What the handler has seen happen, to compare against the contracts.
    mapping(address actor => uint256) public paidIn;
    mapping(address actor => uint256) public refunded;
    mapping(address actor => bool) public claimed;
    bool public sawFinalized;
    bool public sawFailed;
    bool public leftFinalState;

    constructor(TokenSale sale_, address[] memory actors_) {
        sale = sale_;
        vesting = sale_.vesting();
        actors = actors_;
    }

    function contribute(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0, 6 ether);
        uint256 before = sale.contributions(actor);
        hoax(actor, amount);
        try sale.contribute{value: amount}() {
            paidIn[actor] += sale.contributions(actor) - before;
        } catch {}
        _observe();
    }

    function wait(uint256 time) external {
        vm.warp(block.timestamp + bound(time, 0, 5 days));
        _observe();
    }

    function finalize() external {
        try sale.finalize() {} catch {}
        _observe();
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try sale.claim() {
            claimed[actor] = true;
        } catch {}
        _observe();
    }

    function refund(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 before = actor.balance;
        vm.prank(actor);
        try sale.refund() {
            refunded[actor] += actor.balance - before;
        } catch {}
        _observe();
    }

    function collectFee() external {
        try sale.collectFee() {} catch {}
        _observe();
    }

    function release() external {
        try vesting.release() {} catch {}
        _observe();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// Records the final states reached and whether one was ever left.
    function _observe() private {
        TokenSale.Status status = sale.status();
        if (sawFinalized && status != TokenSale.Status.Finalized) leftFinalState = true;
        if (sawFailed && status != TokenSale.Status.Failed) leftFinalState = true;
        if (status == TokenSale.Status.Finalized) sawFinalized = true;
        if (status == TokenSale.Status.Failed) sawFailed = true;
    }
}

/// Properties that must hold after any sequence of actions on a launch.
contract LaunchpadInvariantTest is LaunchpadFixture {
    LaunchHandler internal handler;
    Deployed internal d;
    Launchpad.LaunchParams internal params;
    uint256 internal totalSupply;

    function setUp() public {
        deployLaunchpad(50);
        params = defaultParams();
        params.maxContribution = 5 ether;
        d = createLaunch(params);
        totalSupply = params.totalSupply;
        vm.warp(params.startTime);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        actors[3] = makeAddr("dave");
        handler = new LaunchHandler(d.sale, actors);
        targetContract(address(handler));
    }

    /// The supply never changes.
    function invariant_SupplyIsFixed() public view {
        assertEq(d.token.totalSupply(), totalSupply);
    }

    /// The sale never raises more than its hard cap, nor a wallet more than its maximum.
    function invariant_CapsAreRespected() public view {
        assertLe(d.sale.totalRaised(), params.hardCap);
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            assertLe(d.sale.contributions(handler.actors(i)), params.maxContribution);
        }
    }

    /// Until the sale is finalized, it holds exactly what contributors are
    /// owed back. After, it holds exactly the uncollected fee.
    function invariant_SaleIsSolvent() public view {
        if (d.sale.finalized()) {
            assertEq(address(d.sale).balance, d.sale.feeOwed());
        } else {
            uint256 owed;
            for (uint256 i = 0; i < handler.actorCount(); i++) {
                owed += d.sale.contributions(handler.actors(i));
            }
            assertEq(address(d.sale).balance, owed);
        }
    }

    /// After listing, the sale always holds enough tokens for every pending claim.
    function invariant_ClaimsAreCovered() public view {
        if (!d.sale.finalized()) return;
        uint256 pending;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            pending += d.sale.tokensFor(d.sale.contributions(handler.actors(i)));
        }
        assertGe(d.token.balanceOf(address(d.sale)), pending);
    }

    /// Nobody gets back more than they put in, and nobody gets both a refund
    /// and tokens.
    function invariant_NoDoubleSpending() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            assertLe(handler.refunded(actor), handler.paidIn(actor));
            assertFalse(handler.claimed(actor) && handler.refunded(actor) > 0);
        }
    }

    /// A finalized or failed sale never becomes anything else.
    function invariant_FinalStatesAreFinal() public view {
        assertFalse(handler.leftFinalState());
        assertFalse(handler.sawFinalized() && handler.sawFailed());
    }

    /// Once listed, the liquidity belongs to nobody and at least 70% of the
    /// raise is in the pool.
    function invariant_LiquidityIsLocked() public view {
        if (!d.sale.finalized()) return;
        MockPair pair = MockPair(d.sale.pair());
        assertEq(pair.balanceOf(DEAD), pair.totalSupply());
        assertGe(weth.balanceOf(address(pair)) * BPS, d.sale.totalRaised() * 7000 - BPS);
    }

    /// The creator never holds more than the tranches that are due.
    function invariant_VestingNeverOverpays() public view {
        uint256 tranches = d.vesting.trancheCount();
        uint256 due = d.vesting.tranchesVested();
        assertLe(d.vesting.releasedNative(), (d.vesting.totalNative() * due) / tranches);
        assertLe(d.vesting.releasedTokens(), (d.vesting.totalTokens() * due) / tranches);
        assertEq(creator.balance, d.vesting.releasedNative());
        assertEq(d.token.balanceOf(creator), d.vesting.releasedTokens());
        assertLe(d.token.balanceOf(creator) * 100, totalSupply);
    }

    /// The platform never receives more than 1% of what was raised, and
    /// nothing from a sale that was not listed.
    function invariant_FeeIsBounded() public view {
        assertLe((feeWallet.balance + d.sale.feeOwed()) * 100, d.sale.totalRaised());
        if (!d.sale.finalized()) assertEq(feeWallet.balance + d.sale.feeOwed(), 0);
    }
}
