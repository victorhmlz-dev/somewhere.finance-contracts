// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchpadV3} from "../contracts/LaunchpadV3.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {TokenSaleV3} from "../contracts/TokenSaleV3.sol";
import {CreatorVestingV3} from "../contracts/CreatorVestingV3.sol";
import {IUniswapV2Factory} from "../contracts/interfaces/IUniswapV2.sol";
import {MockFactory, MockPair, MockWETH} from "../contracts/test/MockDex.sol";
import {MockIssuerToken} from "../contracts/test/MockAssets.sol";

/// The actions anyone can take on a v3 launch paired with an asset whose
/// issuer can pause it and burn balances, the issuer's own actions included.
/// The invariant test calls them in random order with random arguments; a call
/// that reverts is simply an action that was not allowed at that moment.
contract LaunchV3Handler is Test {
    LaunchpadV3 public immutable launchpad;
    TokenSaleV3 public immutable sale;
    CreatorVestingV3 public immutable vesting;
    MockIssuerToken public immutable quote;
    address public immutable creator;
    address[] public actors;

    // What the handler has seen happen, to compare against the contracts.
    mapping(address actor => uint256) public paidIn;
    mapping(address actor => uint256) public refunded;
    mapping(address actor => bool) public claimed;
    uint256 public totalRefundedPaid;
    uint256 public burnedFromSale;
    bool public sawFinalized;
    bool public sawFailed;
    bool public sawCancelled;
    bool public leftFinalState;
    /// Whether someone other than the creator, or after the start, managed to cancel.
    bool public cancelledWrongly;
    /// Whether the ticker was freed while the launch was neither cancelled nor failed.
    bool public tickerReleasedWrongly;

    constructor(LaunchpadV3 launchpad_, address creator_, address[] memory actors_) {
        launchpad = launchpad_;
        sale = TokenSaleV3(payable(launchpad_.getLaunch(0).sale));
        vesting = sale.vesting();
        quote = MockIssuerToken(address(sale.quoteAsset()));
        creator = creator_;
        actors = actors_;
    }

    function contribute(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0, 6 ether);
        uint256 before = sale.contributions(actor);
        vm.prank(actor);
        try sale.contribute(amount, TokenSaleV3.TierProof(0, 0, "")) {
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
        uint256 before = quote.balanceOf(actor);
        vm.prank(actor);
        try sale.refund() {
            uint256 paid = quote.balanceOf(actor) - before;
            refunded[actor] += paid;
            totalRefundedPaid += paid;
        } catch {}
        _observe();
    }

    /// Rarely the creator, so most sequences still get to the sale itself;
    /// otherwise somebody who must not be able to.
    function cancel(uint256 callerSeed) external {
        address caller = callerSeed % 8 == 0 ? creator : actors[callerSeed % actors.length];
        bool wasUpcoming = sale.status() == TokenSaleV3.Status.Upcoming;
        vm.prank(caller);
        try sale.cancel() {
            if (caller != creator || !wasUpcoming) cancelledWrongly = true;
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

    function releaseTicker() external {
        TokenSaleV3.Status status = sale.status();
        try launchpad.releaseTicker(0) {
            if (status != TokenSaleV3.Status.Cancelled && status != TokenSaleV3.Status.Failed) {
                tickerReleasedWrongly = true;
            }
        } catch {}
        _observe();
    }

    /// The issuer pauses or resumes its token. Rare, so most sequences run unpaused.
    function issuerTogglePause(uint256 seed) external {
        if (seed % 6 != 0) return;
        quote.setPaused(!quote.paused());
        _observe();
    }

    /// The issuer burns part of what the sale holds, before the token is
    /// listed (afterwards the sale only holds the platform's fee).
    function issuerBurn(uint256 seed, uint256 amount) external {
        if (seed % 6 != 0 || sale.finalized()) return;
        amount = bound(amount, 0, quote.balanceOf(address(sale)));
        quote.adminBurn(address(sale), amount);
        burnedFromSale += amount;
        _observe();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// Records the final states reached and whether one was ever left.
    function _observe() private {
        TokenSaleV3.Status status = sale.status();
        if (sawFinalized && status != TokenSaleV3.Status.Finalized) leftFinalState = true;
        if (sawFailed && status != TokenSaleV3.Status.Failed) leftFinalState = true;
        if (sawCancelled && status != TokenSaleV3.Status.Cancelled) leftFinalState = true;
        if (status == TokenSaleV3.Status.Finalized) sawFinalized = true;
        if (status == TokenSaleV3.Status.Failed) sawFailed = true;
        if (status == TokenSaleV3.Status.Cancelled) sawCancelled = true;
    }
}

/// Properties that must hold after any sequence of actions on a v3 launch,
/// whatever the issuer of its quote asset does.
contract LaunchpadV3InvariantTest is Test {
    uint256 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchV3Handler internal handler;
    LaunchpadV3 internal launchpad;
    TokenSaleV3 internal sale;
    CreatorVestingV3 internal vesting;
    LaunchToken internal token;
    MockIssuerToken internal quote;
    LaunchpadV3.LaunchParams internal params;
    address internal creator = makeAddr("creator");
    address internal feeWallet = makeAddr("feeWallet");

    function setUp() public {
        MockWETH weth = new MockWETH();
        MockFactory dexFactory = new MockFactory();
        launchpad = new LaunchpadV3(
            address(this),
            IUniswapV2Factory(address(dexFactory)),
            address(weth),
            address(new TokenSaleV3()),
            address(new CreatorVestingV3()),
            feeWallet,
            50
        );
        quote = new MockIssuerToken();
        launchpad.setQuoteAsset(address(quote), true, 1 ether);

        params = LaunchpadV3.LaunchParams({
            name: "Void Token",
            symbol: "VOID",
            totalSupply: 1_000_000 ether,
            quoteAsset: address(quote),
            softCap: 2 ether,
            hardCap: 10 ether,
            minContribution: 0,
            maxContribution: 5 ether,
            // Starts before the sale opens, so the sequences include cancelling it
            startTime: uint64(block.timestamp + 1 hours),
            endTime: uint64(block.timestamp + 1 hours + 7 days),
            creatorAllocationBps: 100,
            liquidityBps: 7000,
            vestingTranches: 3,
            requiredTier: 0
        });
        vm.prank(creator);
        launchpad.createLaunch(params);
        LaunchpadV3.Launch memory launch = launchpad.getLaunch(0);
        sale = TokenSaleV3(payable(launch.sale));
        vesting = CreatorVestingV3(payable(launch.vesting));
        token = LaunchToken(launch.token);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        actors[3] = makeAddr("dave");
        for (uint256 i = 0; i < actors.length; i++) {
            quote.mint(actors[i], 100 ether);
            vm.prank(actors[i]);
            quote.approve(address(sale), type(uint256).max);
        }
        handler = new LaunchV3Handler(launchpad, creator, actors);
        targetContract(address(handler));
    }

    /// The supply never changes.
    function invariant_SupplyIsFixed() public view {
        assertEq(token.totalSupply(), params.totalSupply);
    }

    /// The sale never raises more than its hard cap, nor a wallet more than its maximum.
    function invariant_CapsAreRespected() public view {
        assertLe(sale.totalRaised(), params.hardCap);
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            assertLe(sale.contributions(handler.actors(i)), params.maxContribution);
        }
    }

    /// Until listing, every unit raised is either still in the sale, paid back
    /// in a refund, or burned by the issuer. With no burn, the sale holds
    /// exactly what contributors are owed back. After listing, it holds
    /// exactly the uncollected fee.
    function invariant_SaleIsSolvent() public view {
        uint256 balance = quote.balanceOf(address(sale));
        if (sale.finalized()) {
            assertEq(balance, sale.feeOwed());
            return;
        }
        assertEq(
            balance + handler.totalRefundedPaid() + handler.burnedFromSale(),
            sale.totalRaised()
        );
        if (handler.burnedFromSale() == 0) {
            uint256 owed;
            for (uint256 i = 0; i < handler.actorCount(); i++) {
                owed += sale.contributions(handler.actors(i));
            }
            assertEq(balance, owed);
        }
    }

    /// After listing, the sale always holds enough tokens for every pending claim.
    function invariant_ClaimsAreCovered() public view {
        if (!sale.finalized()) return;
        uint256 pending;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            pending += sale.tokensFor(sale.contributions(handler.actors(i)));
        }
        assertGe(token.balanceOf(address(sale)), pending);
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

    /// A finalized, failed or cancelled sale never becomes anything else.
    function invariant_FinalStatesAreFinal() public view {
        assertFalse(handler.leftFinalState());
        assertFalse(handler.sawFinalized() && handler.sawFailed());
        assertFalse(handler.sawCancelled() && (handler.sawFinalized() || handler.sawFailed()));
    }

    /// Only the creator can cancel, only before the start, and a cancelled
    /// sale took no money and burned every token.
    function invariant_CancelOnlyBeforeAnyMoney() public view {
        assertFalse(handler.cancelledWrongly());
        if (!sale.cancelled()) return;
        assertEq(sale.totalRaised(), 0);
        assertEq(quote.balanceOf(address(sale)), 0);
        assertEq(token.balanceOf(address(sale)), 0);
        assertEq(token.balanceOf(DEAD), params.totalSupply);
    }

    /// The ticker stays taken unless the launch was cancelled or failed.
    function invariant_TickerHeldWhileTheLaunchCounts() public view {
        assertFalse(handler.tickerReleasedWrongly());
        TokenSaleV3.Status status = sale.status();
        if (status != TokenSaleV3.Status.Cancelled && status != TokenSaleV3.Status.Failed) {
            assertFalse(launchpad.isTickerAvailable("VOID"));
        }
    }

    /// Once listed, the liquidity belongs to nobody and at least 70% of the
    /// raise is in the pool.
    function invariant_LiquidityIsLocked() public view {
        if (!sale.finalized()) return;
        MockPair pair = MockPair(sale.pair());
        assertEq(pair.balanceOf(DEAD), pair.totalSupply());
        assertGe(quote.balanceOf(address(pair)) * BPS, sale.totalRaised() * 7000 - BPS);
    }

    /// The creator never holds more than the tranches that are due.
    function invariant_VestingNeverOverpays() public view {
        uint256 tranches = vesting.trancheCount();
        uint256 due = vesting.tranchesVested();
        assertLe(vesting.releasedQuote(), (vesting.totalQuote() * due) / tranches);
        assertLe(vesting.releasedTokens(), (vesting.totalTokens() * due) / tranches);
        assertEq(quote.balanceOf(creator), vesting.releasedQuote());
        assertEq(token.balanceOf(creator), vesting.releasedTokens());
        assertLe(token.balanceOf(creator) * 100, params.totalSupply);
    }

    /// The platform never receives more than 1% of what was raised, and
    /// nothing from a sale that was not listed.
    function invariant_FeeIsBounded() public view {
        uint256 fees = quote.balanceOf(feeWallet) + sale.feeOwed();
        assertLe(fees * 100, sale.totalRaised());
        if (!sale.finalized()) assertEq(fees, 0);
    }
}
