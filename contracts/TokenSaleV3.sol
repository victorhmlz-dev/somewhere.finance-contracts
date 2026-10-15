// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreatorVestingV3} from "./CreatorVestingV3.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IWETH} from "./interfaces/IUniswapV2.sol";

/// @notice What a sale needs from the launchpad that created it.
interface ILaunchpadV3 {
    function feeRecipient() external view returns (address);

    function hasTier(
        address account,
        uint8 requiredTier,
        uint8 tier,
        uint64 expiresAt,
        bytes calldata signature
    ) external view returns (bool);
}

/// @title Fixed-price sale of one token launched on Somewhere, v3
/// @notice Sells a token at a fixed price for one quote asset (a stablecoin, a
/// tokenized stock, another crypto asset, or the native currency through its
/// wrapped token), and lists it paired with that asset. Every rule is fixed
/// when the launch is created; nobody can change it afterwards.
///
/// When a sale succeeds, what was raised is split by the contract itself:
/// liquidity (at least 70%, locked forever), the platform fee, and the rest to
/// the creator through monthly vesting. When it ends below its minimum, or
/// cannot be listed within the grace period, contributors get refunds.
///
/// Some quote assets have an issuer that can pause transfers, block addresses
/// or burn balances. Nothing here can prevent that, so the sale makes sure it
/// never makes things worse: a pause only delays (a listing that cannot happen
/// in time turns into refunds), a blocked contributor only affects their own
/// claim, and if the issuer takes funds from the sale, refunds share the loss
/// in proportion instead of leaving the last contributors with nothing.
///
/// Each sale is a minimal clone of one implementation; the implementation
/// itself can never be initialized.
contract TokenSaleV3 is Initializable, ReentrancyGuard {
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
        /// What the token is sold for and paired with.
        IERC20 quoteAsset;
        /// Beneficiary of the vesting.
        address creator;
        IUniswapV2Factory dexFactory;
        /// Wrapped native currency of the chain. When it is the quote asset,
        /// the sale takes and pays out the native currency itself.
        address weth;
        address vestingImplementation;
        /// Tokens offered to contributors if the hard cap is reached.
        uint256 tokensForSale;
        /// Tokens the creator receives, through vesting, once the token is listed.
        uint256 creatorAllocation;
        /// Minimum to raise, in the smallest unit of the quote asset.
        uint256 softCap;
        /// Maximum to raise. Reaching it ends the sale early.
        uint256 hardCap;
        /// Least a wallet can have contributed. Zero for no minimum.
        uint256 minContribution;
        /// Most a wallet can contribute. Zero for no maximum.
        uint256 maxContribution;
        uint64 startTime;
        uint64 endTime;
        /// Share of what is raised that goes to liquidity, in basis points.
        uint16 liquidityBps;
        /// Share of what is raised kept by the platform, in basis points.
        uint16 feeBps;
        /// Monthly tranches of the creator's vesting.
        uint8 vestingTranches;
        /// Verification tier contributors need. Zero for anyone.
        uint8 requiredTier;
    }

    /// @notice A signed statement of a contributor's verification tier. Empty
    /// for sales that require none.
    struct TierProof {
        uint8 tier;
        uint64 expiresAt;
        bytes signature;
    }

    uint256 private constant BPS = 10_000;

    /// @notice How long anyone has to finalize a successful sale. After that
    /// the sale counts as failed and contributors can get refunds, so funds
    /// are never stuck if the exchange refuses the listing.
    uint64 public constant FINALIZE_GRACE_PERIOD = 7 days;

    /// @notice Where locked pool tokens and unsold tokens go. Nobody holds its key.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Set once, by `initialize`. Clones cannot have immutables of their own.

    /// @notice The launchpad that created this sale. Says who collects the
    /// fee and who signs verification tiers.
    address public launchpad;
    IERC20 public token;
    IERC20 public quoteAsset;
    address public creator;
    /// @notice Holds the creator's proceeds and tokens once the token is listed.
    CreatorVestingV3 public vesting;
    IUniswapV2Factory public dexFactory;
    address public weth;
    uint256 public tokensForSale;
    uint256 public creatorAllocation;
    uint256 public softCap;
    uint256 public hardCap;
    uint256 public minContribution;
    uint256 public maxContribution;
    uint64 public startTime;
    uint64 public endTime;
    uint16 public liquidityBps;
    uint16 public feeBps;
    uint8 public requiredTier;

    /// @notice Total raised so far, in the smallest unit of the quote asset.
    uint256 public totalRaised;
    /// @notice What each address has contributed. Set back to zero when the
    /// address claims its tokens or its refund.
    mapping(address contributor => uint256 amount) public contributions;
    /// @notice Contributions already refunded, counted at what was contributed.
    uint256 public totalRefunded;
    /// @notice When the hard cap was reached. Zero if it has not been.
    uint64 public hardCapReachedAt;
    bool public finalized;
    bool public cancelled;
    /// @notice The exchange pool of the token. Set when the sale is finalized.
    address public pair;
    /// @notice Platform fee waiting to be collected.
    uint256 public feeOwed;

    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);
    event Finalized(
        address indexed pair,
        uint256 liquidityQuote,
        uint256 liquidityTokens,
        uint256 liquidityLocked,
        uint256 creatorQuote,
        uint256 fee,
        uint256 tokensBurned
    );
    event Claimed(address indexed contributor, uint256 tokens);
    /// @notice `amount` is what was paid back; less than `contribution` only
    /// if the issuer of the quote asset took funds from the sale.
    event Refunded(address indexed contributor, uint256 contribution, uint256 amount);
    event FeeCollected(address indexed recipient, uint256 amount);
    event Cancelled(uint256 tokensBurned);

    error SaleNotLive();
    error SaleNotSucceeded();
    error SaleNotFailed();
    error SaleNotFinalized();
    error NothingToContribute();
    error BelowMinContribution();
    error NotVerified();
    error NativeNotAccepted();
    error UnsupportedQuoteAsset();
    error QuoteShortfall();
    error NothingToClaim();
    error NothingToCollect();
    error NativeTransferFailed();
    error NotCreator();
    error SaleNotUpcoming();

    constructor() {
        _disableInitializers();
    }

    /// @notice Only the native currency being unwrapped can be sent here.
    /// Native contributions go through `contributeNative`.
    receive() external payable {
        if (msg.sender != weth) revert NativeNotAccepted();
    }

    /// @notice Sets the sale up. Called once, by the launchpad, in the same
    /// transaction that creates the clone. Returns the vesting contract.
    function initialize(Config calldata config) external initializer returns (address) {
        launchpad = msg.sender;
        token = config.token;
        quoteAsset = config.quoteAsset;
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
        requiredTier = config.requiredTier;

        CreatorVestingV3 vesting_ = CreatorVestingV3(
            payable(Clones.clone(config.vestingImplementation))
        );
        vesting_.initialize(
            config.token,
            config.quoteAsset,
            config.creator,
            config.weth,
            config.vestingTranches
        );
        vesting = vesting_;
        return address(vesting_);
    }

    /// @notice Buys tokens at the price of the sale, paying in the quote
    /// asset, which this sale must be allowed to spend. Only the part that
    /// fits, under the hard cap and under the wallet's maximum, is taken.
    function contribute(uint256 amount, TierProof calldata proof) external nonReentrant {
        _contributeToken(amount, proof);
    }

    /// @notice The same, approving the sale with an EIP-2612 signature in the
    /// same transaction. If the approval was already used, for example by
    /// someone who copied it from the mempool, the contribution still goes
    /// through on the allowance it set.
    function contributeWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        TierProof calldata proof
    ) external nonReentrant {
        try
            IERC20Permit(address(quoteAsset)).permit(
                msg.sender,
                address(this),
                amount,
                deadline,
                v,
                r,
                s
            )
        {} catch {}
        _contributeToken(amount, proof);
    }

    /// @notice Buys tokens with the native currency, when the sale is paired
    /// with it. What does not fit is sent back in the same transaction.
    function contributeNative(TierProof calldata proof) external payable nonReentrant {
        if (address(quoteAsset) != weth) revert NativeNotAccepted();
        uint256 amount = _record(msg.value, proof);
        IWETH(weth).deposit{value: amount}();
        if (msg.value > amount) _sendNative(msg.sender, msg.value - amount);
    }

    /// @notice Lists the token, locks the liquidity and starts the creator's
    /// vesting. Anyone can call it once the sale has succeeded.
    function finalize() external nonReentrant {
        if (status() != Status.Succeeded) revert SaleNotSucceeded();
        uint256 raised = totalRaised;
        // If the issuer of the quote asset took part of it, the sale cannot be
        // listed at its price; once the grace period ends, refunds share the loss.
        if (quoteAsset.balanceOf(address(this)) < raised) revert QuoteShortfall();
        finalized = true;

        uint256 fee = (raised * feeBps) / BPS;
        uint256 liquidityQuote = (raised * liquidityBps) / BPS;
        uint256 creatorQuote = raised - liquidityQuote - fee;
        uint256 tokensSold = tokensFor(raised);
        // Same ratio of tokens to quote asset as in the sale, so the token
        // starts trading at the price contributors paid.
        uint256 liquidityTokens = (tokensSold * liquidityBps) / BPS;

        feeOwed = fee;

        // The pair is funded directly instead of through the exchange router:
        // the router refuses to add liquidity to a pair that somebody created
        // and unbalanced in advance, which would let anyone block this call.
        address pair_ = dexFactory.getPair(address(token), address(quoteAsset));
        if (pair_ == address(0)) pair_ = dexFactory.createPair(address(token), address(quoteAsset));
        pair = pair_;

        token.safeTransfer(pair_, liquidityTokens);
        quoteAsset.safeTransfer(pair_, liquidityQuote);
        uint256 liquidityLocked = IUniswapV2Pair(pair_).mint(DEAD);

        if (creatorAllocation > 0) token.safeTransfer(address(vesting), creatorAllocation);
        if (creatorQuote > 0) quoteAsset.safeTransfer(address(vesting), creatorQuote);
        vesting.start(creatorAllocation, creatorQuote);

        // Whatever is not owed to contributors is taken out of circulation.
        uint256 tokensBurned = token.balanceOf(address(this)) - tokensSold;
        if (tokensBurned > 0) token.safeTransfer(DEAD, tokensBurned);

        emit Finalized(
            pair_,
            liquidityQuote,
            liquidityTokens,
            liquidityLocked,
            creatorQuote,
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

    /// @notice Returns the caller's contribution when the sale failed: all of
    /// it, unless the issuer of the quote asset took funds from the sale, in
    /// which case every contributor gets the same share of what is left.
    function refund() external nonReentrant {
        if (status() != Status.Failed) revert SaleNotFailed();

        uint256 contribution = contributions[msg.sender];
        if (contribution == 0) revert NothingToClaim();
        contributions[msg.sender] = 0;

        uint256 outstanding = totalRaised - totalRefunded;
        uint256 balance = quoteAsset.balanceOf(address(this));
        uint256 amount = balance >= outstanding
            ? contribution
            : (contribution * balance) / outstanding;
        totalRefunded += contribution;

        emit Refunded(msg.sender, contribution, amount);
        if (amount > 0) _pay(msg.sender, amount);
    }

    /// @notice Sends the platform its fee. Anyone can call it; the fee goes to
    /// whoever the launchpad names at that moment. A failure here affects
    /// nothing else: listing, claims and vesting never depend on it.
    function collectFee() external nonReentrant {
        uint256 amount = feeOwed;
        if (amount == 0) revert NothingToCollect();
        feeOwed = 0;

        address recipient = ILaunchpadV3(launchpad).feeRecipient();
        _pay(recipient, amount);
        emit FeeCollected(recipient, amount);
    }

    /// @notice Tokens bought with `amount` of the quote asset.
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

    function _contributeToken(uint256 offered, TierProof calldata proof) private {
        uint256 amount = _record(offered, proof);

        // Tokens that charge a fee on transfers, or otherwise deliver less
        // than was sent, would leave the sale owing more than it holds.
        uint256 balanceBefore = quoteAsset.balanceOf(address(this));
        quoteAsset.safeTransferFrom(msg.sender, address(this), amount);
        if (quoteAsset.balanceOf(address(this)) - balanceBefore != amount) {
            revert UnsupportedQuoteAsset();
        }
    }

    /// Checks and records a contribution of up to `offered`, and returns the
    /// part that fits. The caller then collects exactly that.
    function _record(uint256 offered, TierProof calldata proof) private returns (uint256) {
        if (status() != Status.Live) revert SaleNotLive();
        if (
            requiredTier != 0 &&
            !ILaunchpadV3(launchpad).hasTier(
                msg.sender,
                requiredTier,
                proof.tier,
                proof.expiresAt,
                proof.signature
            )
        ) revert NotVerified();

        uint256 contributed = contributions[msg.sender];
        uint256 room = hardCap - totalRaised;
        if (maxContribution != 0) {
            uint256 walletRoom = maxContribution > contributed ? maxContribution - contributed : 0;
            if (walletRoom < room) room = walletRoom;
        }
        uint256 amount = offered > room ? room : offered;
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
        return amount;
    }

    /// Pays out the quote asset. When it is the wrapped native currency, pays
    /// the native currency instead, or the wrapped token to an address that
    /// cannot receive the native one, so a payment never gets stuck.
    function _pay(address to, uint256 amount) private {
        if (address(quoteAsset) != weth) {
            quoteAsset.safeTransfer(to, amount);
            return;
        }
        IWETH(weth).withdraw(amount);
        (bool sent, ) = to.call{value: amount}("");
        if (!sent) {
            IWETH(weth).deposit{value: amount}();
            quoteAsset.safeTransfer(to, amount);
        }
    }

    function _sendNative(address to, uint256 amount) private {
        (bool sent, ) = to.call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
    }
}
