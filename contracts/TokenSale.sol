// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreatorVesting} from "./CreatorVesting.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IWETH} from "./interfaces/IUniswapV2.sol";

/// @notice What a sale needs from the launchpad that created it.
interface ILaunchpadFees {
    function feeRecipient() external view returns (address);
}

/// @title Fixed-price sale of one token launched on Somewhere
/// @notice Sells a token at a fixed price for the native currency of the
/// chain. It holds the whole supply from the start, and every rule below is
/// fixed when the launch is created; nobody can change it afterwards.
///
/// When a sale succeeds, what was raised is split by the contract itself:
///
/// - Liquidity, at least 70%: goes straight to the exchange, paired with
///   tokens at the price of the sale. The pool tokens are sent to an address
///   nobody controls, so the liquidity can never be withdrawn.
/// - Platform fee: set aside for the platform to collect.
/// - The rest: goes to the creator through a vesting contract, in monthly
///   tranches, together with the creator's token allocation.
///
/// When a sale ends below its minimum, or cannot be listed within the grace
/// period, nothing is listed, no fee is charged and every contributor gets a
/// full refund.
///
/// Before the sale starts, and only then, the creator can cancel it. Nobody
/// can have contributed yet, so nobody loses anything; the whole supply is
/// burned and the token never trades.
contract TokenSale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        /// Before `startTime`.
        Upcoming,
        /// Accepting contributions.
        Live,
        /// The sale is over and reached its minimum; anyone can finalize it.
        Succeeded,
        /// Contributors can get refunds: the sale ended below its minimum, or
        /// it succeeded but was not finalized within the grace period.
        Failed,
        /// Listed on the exchange; contributors can claim their tokens.
        Finalized,
        /// Cancelled by the creator before it started. Nothing can happen anymore.
        Cancelled
    }

    struct Config {
        IERC20 token;
        /// Beneficiary of the vesting.
        address creator;
        IUniswapV2Factory dexFactory;
        /// Wrapped native currency the token is paired with.
        address weth;
        /// Tokens offered to contributors if the hard cap is reached.
        uint256 tokensForSale;
        /// Tokens the creator receives, through vesting, once the token is listed.
        uint256 creatorAllocation;
        /// Minimum to raise, in wei, for the sale to succeed.
        uint256 softCap;
        /// Maximum to raise, in wei. Reaching it ends the sale early.
        uint256 hardCap;
        /// Least a wallet can have contributed, in wei. Zero for no minimum.
        uint256 minContribution;
        /// Most a wallet can contribute, in wei. Zero for no maximum.
        uint256 maxContribution;
        uint64 startTime;
        uint64 endTime;
        /// Share of what is raised that goes to liquidity, in basis points.
        uint16 liquidityBps;
        /// Share of what is raised kept by the platform, in basis points.
        uint16 feeBps;
        /// Monthly tranches of the creator's vesting.
        uint8 vestingTranches;
    }

    uint256 private constant BPS = 10_000;

    /// @notice How long anyone has to finalize a successful sale. After that
    /// the sale counts as failed and contributors can get refunds, so funds
    /// are never stuck if the exchange refuses the listing.
    uint64 public constant FINALIZE_GRACE_PERIOD = 7 days;

    /// @notice Where locked pool tokens and unsold tokens go. Nobody holds its key.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice The launchpad that created this sale. Says who collects the fee.
    address public immutable launchpad;
    IERC20 public immutable token;
    address public immutable creator;
    /// @notice Holds the creator's proceeds and tokens once the token is listed.
    CreatorVesting public immutable vesting;
    IUniswapV2Factory public immutable dexFactory;
    address public immutable weth;
    uint256 public immutable tokensForSale;
    uint256 public immutable creatorAllocation;
    uint256 public immutable softCap;
    uint256 public immutable hardCap;
    uint256 public immutable minContribution;
    uint256 public immutable maxContribution;
    uint64 public immutable startTime;
    uint64 public immutable endTime;
    uint16 public immutable liquidityBps;
    uint16 public immutable feeBps;

    /// @notice Total raised so far, in wei.
    uint256 public totalRaised;
    /// @notice What each address has contributed, in wei. Set back to zero
    /// when the address claims its tokens or its refund.
    mapping(address contributor => uint256 amount) public contributions;
    /// @notice When the hard cap was reached. Zero if it has not been.
    uint64 public hardCapReachedAt;
    bool public finalized;
    bool public cancelled;
    /// @notice The exchange pool of the token. Set when the sale is finalized.
    address public pair;
    /// @notice Platform fee waiting to be collected, in wei.
    uint256 public feeOwed;

    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);
    event Finalized(
        address indexed pair,
        uint256 liquidityNative,
        uint256 liquidityTokens,
        uint256 liquidityLocked,
        uint256 creatorNative,
        uint256 fee,
        uint256 tokensBurned
    );
    event Claimed(address indexed contributor, uint256 tokens);
    event Refunded(address indexed contributor, uint256 amount);
    event FeeCollected(address indexed recipient, uint256 amount);
    event Cancelled(uint256 tokensBurned);

    error SaleNotLive();
    error SaleNotSucceeded();
    error SaleNotFailed();
    error SaleNotFinalized();
    error NothingToContribute();
    error BelowMinContribution();
    error NothingToClaim();
    error NothingToCollect();
    error NativeTransferFailed();
    error NotCreator();
    error SaleNotUpcoming();

    constructor(Config memory config) {
        launchpad = msg.sender;
        token = config.token;
        creator = config.creator;
        dexFactory = config.dexFactory;
        weth = config.weth;
        tokensForSale = config.tokensForSale;
        creatorAllocation = config.creatorAllocation;
        softCap = config.softCap;
        hardCap = config.hardCap;
        minContribution = config.minContribution;
        maxContribution = config.maxContribution;
        startTime = config.startTime;
        endTime = config.endTime;
        liquidityBps = config.liquidityBps;
        feeBps = config.feeBps;
        vesting = new CreatorVesting(config.token, config.creator, config.vestingTranches);
    }

    /// @notice Sending native currency to the sale is contributing to it.
    receive() external payable {
        _contribute();
    }

    /// @notice Buys tokens at the price of the sale. The part of the payment
    /// that does not fit, under the hard cap or under the wallet's maximum,
    /// is sent back in the same transaction.
    function contribute() external payable {
        _contribute();
    }

    /// @notice Lists the token, locks the liquidity and starts the creator's
    /// vesting. Anyone can call it once the sale has succeeded.
    function finalize() external nonReentrant {
        if (status() != Status.Succeeded) revert SaleNotSucceeded();
        finalized = true;

        uint256 raised = totalRaised;
        uint256 fee = (raised * feeBps) / BPS;
        uint256 liquidityNative = (raised * liquidityBps) / BPS;
        uint256 creatorNative = raised - liquidityNative - fee;
        uint256 tokensSold = tokensFor(raised);
        // Same ratio of tokens to native currency as in the sale, so the token
        // starts trading at the price contributors paid.
        uint256 liquidityTokens = (tokensSold * liquidityBps) / BPS;

        feeOwed = fee;

        // The pair is funded directly instead of through the exchange router:
        // the router refuses to add liquidity to a pair that somebody created
        // and unbalanced in advance, which would let anyone block this call.
        address pair_ = dexFactory.getPair(address(token), weth);
        if (pair_ == address(0)) pair_ = dexFactory.createPair(address(token), weth);
        pair = pair_;

        token.safeTransfer(pair_, liquidityTokens);
        IWETH(weth).deposit{value: liquidityNative}();
        if (!IWETH(weth).transfer(pair_, liquidityNative)) revert NativeTransferFailed();
        uint256 liquidityLocked = IUniswapV2Pair(pair_).mint(DEAD);

        if (creatorAllocation > 0) token.safeTransfer(address(vesting), creatorAllocation);
        vesting.start{value: creatorNative}(creatorAllocation);

        // Whatever is not owed to contributors is taken out of circulation.
        uint256 tokensBurned = token.balanceOf(address(this)) - tokensSold;
        if (tokensBurned > 0) token.safeTransfer(DEAD, tokensBurned);

        emit Finalized(
            pair_,
            liquidityNative,
            liquidityTokens,
            liquidityLocked,
            creatorNative,
            fee,
            tokensBurned
        );
    }

    /// @notice Calls the launch off, for its creator, while the sale has not
    /// started. The whole supply is burned, the creator's share included.
    function cancel() external nonReentrant {
        if (msg.sender != creator) revert NotCreator();
        if (status() != Status.Upcoming) revert SaleNotUpcoming();
        cancelled = true;

        uint256 tokensBurned = token.balanceOf(address(this));
        token.safeTransfer(DEAD, tokensBurned);
        emit Cancelled(tokensBurned);
    }

    /// @notice Sends the caller the tokens bought, once the token is listed.
    function claim() external nonReentrant {
        if (!finalized) revert SaleNotFinalized();

        uint256 contribution = contributions[msg.sender];
        if (contribution == 0) revert NothingToClaim();
        contributions[msg.sender] = 0;

        uint256 tokens = tokensFor(contribution);
        token.safeTransfer(msg.sender, tokens);
        emit Claimed(msg.sender, tokens);
    }

    /// @notice Returns the caller's whole contribution when the sale failed.
    function refund() external nonReentrant {
        if (status() != Status.Failed) revert SaleNotFailed();

        uint256 contribution = contributions[msg.sender];
        if (contribution == 0) revert NothingToClaim();
        contributions[msg.sender] = 0;

        _sendNative(msg.sender, contribution);
        emit Refunded(msg.sender, contribution);
    }

    /// @notice Sends the platform its fee. Anyone can call it; the fee goes to
    /// whoever the launchpad names at that moment. A failure here affects
    /// nothing else: listing, claims and vesting never depend on it.
    function collectFee() external nonReentrant {
        uint256 amount = feeOwed;
        if (amount == 0) revert NothingToCollect();
        feeOwed = 0;

        address recipient = ILaunchpadFees(launchpad).feeRecipient();
        _sendNative(recipient, amount);
        emit FeeCollected(recipient, amount);
    }

    /// @notice Tokens bought with `amount` wei.
    function tokensFor(uint256 amount) public view returns (uint256) {
        return (amount * tokensForSale) / hardCap;
    }

    function status() public view returns (Status) {
        if (cancelled) return Status.Cancelled;
        if (finalized) return Status.Finalized;
        if (block.timestamp < startTime) return Status.Upcoming;

        uint256 succeededAt;
        if (hardCapReachedAt != 0) {
            succeededAt = hardCapReachedAt;
        } else if (block.timestamp < endTime) {
            return Status.Live;
        } else if (totalRaised >= softCap) {
            succeededAt = endTime;
        } else {
            return Status.Failed;
        }

        return
            block.timestamp < succeededAt + FINALIZE_GRACE_PERIOD
                ? Status.Succeeded
                : Status.Failed;
    }

    function _contribute() private nonReentrant {
        if (status() != Status.Live) revert SaleNotLive();

        uint256 contributed = contributions[msg.sender];
        uint256 room = hardCap - totalRaised;
        if (maxContribution != 0) {
            uint256 walletRoom = maxContribution > contributed ? maxContribution - contributed : 0;
            if (walletRoom < room) room = walletRoom;
        }
        uint256 amount = msg.value > room ? room : msg.value;
        if (amount == 0) revert NothingToContribute();

        contributed += amount;
        totalRaised += amount;
        // The contribution that fills the sale may be smaller than the minimum.
        if (contributed < minContribution && totalRaised < hardCap) {
            revert BelowMinContribution();
        }
        contributions[msg.sender] = contributed;
        if (totalRaised == hardCap) hardCapReachedAt = uint64(block.timestamp);
        emit Contributed(msg.sender, amount, totalRaised);

        if (msg.value > amount) _sendNative(msg.sender, msg.value - amount);
    }

    function _sendNative(address to, uint256 amount) private {
        (bool sent, ) = to.call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
    }
}
