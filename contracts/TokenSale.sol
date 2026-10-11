// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IWETH} from "./interfaces/IUniswapV2.sol";

/// @title Sale of one token launched on Somewhere
/// @notice Sells a token at a fixed price for the native currency of the
/// chain. It holds the whole supply from the start and enforces the three
/// rules of the launchpad itself:
///
/// 1. The contract handles the liquidity, never the team. What is raised goes
///    straight from here to the exchange.
/// 2. The liquidity is locked. The pool tokens are sent to an address nobody
///    controls, so the liquidity can never be withdrawn.
/// 3. The creator receives a fixed share of the supply, capped at 1% when the
///    launch is created (see `Launchpad`).
///
/// The token is listed at the price it was sold for. If the sale ends below
/// its minimum, nothing is listed and every contributor gets a full refund.
contract TokenSale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        /// Before `startTime`.
        Upcoming,
        /// Accepting contributions.
        Live,
        /// The sale is over and reached its minimum; anyone can finalize it.
        Succeeded,
        /// The sale is over below its minimum; contributors can get refunds.
        Failed,
        /// Listed on the exchange; contributors can claim their tokens.
        Finalized
    }

    struct Config {
        IERC20 token;
        /// Receives the creator allocation.
        address creator;
        /// Receives the platform fee.
        address feeRecipient;
        IUniswapV2Factory dexFactory;
        /// Wrapped native currency the token is paired with.
        address weth;
        /// Tokens offered to contributors if the hard cap is reached.
        uint256 tokensForSale;
        /// Tokens the creator receives when the sale is finalized.
        uint256 creatorAllocation;
        /// Minimum to raise, in wei, for the sale to succeed.
        uint256 softCap;
        /// Maximum to raise, in wei. Reaching it ends the sale early.
        uint256 hardCap;
        uint64 startTime;
        uint64 endTime;
        /// Share of what is raised kept by the platform, in basis points.
        uint16 feeBps;
    }

    uint256 private constant BPS = 10_000;

    /// @notice Where locked pool tokens and unsold tokens go. Nobody holds its key.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable token;
    address public immutable creator;
    address public immutable feeRecipient;
    IUniswapV2Factory public immutable dexFactory;
    address public immutable weth;
    uint256 public immutable tokensForSale;
    uint256 public immutable creatorAllocation;
    uint256 public immutable softCap;
    uint256 public immutable hardCap;
    uint64 public immutable startTime;
    uint64 public immutable endTime;
    uint16 public immutable feeBps;

    /// @notice Total raised so far, in wei.
    uint256 public totalRaised;
    /// @notice What each address has contributed, in wei. Set back to zero
    /// when the address claims its tokens or its refund.
    mapping(address contributor => uint256 amount) public contributions;
    bool public finalized;
    /// @notice The exchange pool of the token. Set when the sale is finalized.
    address public pair;

    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);
    event Finalized(
        address indexed pair,
        uint256 liquidityNative,
        uint256 liquidityTokens,
        uint256 liquidityLocked,
        uint256 fee,
        uint256 tokensBurned
    );
    event Claimed(address indexed contributor, uint256 tokens);
    event Refunded(address indexed contributor, uint256 amount);

    error SaleNotLive();
    error SaleNotSucceeded();
    error SaleNotFailed();
    error SaleNotFinalized();
    error NothingToContribute();
    error NothingToClaim();
    error NativeTransferFailed();

    constructor(Config memory config) {
        token = config.token;
        creator = config.creator;
        feeRecipient = config.feeRecipient;
        dexFactory = config.dexFactory;
        weth = config.weth;
        tokensForSale = config.tokensForSale;
        creatorAllocation = config.creatorAllocation;
        softCap = config.softCap;
        hardCap = config.hardCap;
        startTime = config.startTime;
        endTime = config.endTime;
        feeBps = config.feeBps;
    }

    /// @notice Sending native currency to the sale is contributing to it.
    receive() external payable {
        _contribute();
    }

    /// @notice Buys tokens at the price of the sale. If the contribution
    /// passes the hard cap, the part that does not fit is sent back.
    function contribute() external payable {
        _contribute();
    }

    /// @notice Lists the token and locks the liquidity. Anyone can call it
    /// once the sale has succeeded; nobody can choose not to.
    function finalize() external nonReentrant {
        if (status() != Status.Succeeded) revert SaleNotSucceeded();
        finalized = true;

        uint256 raised = totalRaised;
        uint256 fee = (raised * feeBps) / BPS;
        uint256 liquidityNative = raised - fee;
        uint256 tokensSold = tokensFor(raised);
        // Same ratio of tokens to native currency as in the sale, so the token
        // starts trading at the price contributors paid.
        uint256 liquidityTokens = (tokensSold * liquidityNative) / raised;

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

        if (creatorAllocation > 0) token.safeTransfer(creator, creatorAllocation);

        // Whatever is not owed to contributors is taken out of circulation.
        uint256 tokensBurned = token.balanceOf(address(this)) - tokensSold;
        if (tokensBurned > 0) token.safeTransfer(DEAD, tokensBurned);

        if (fee > 0) _sendNative(feeRecipient, fee);

        emit Finalized(pair_, liquidityNative, liquidityTokens, liquidityLocked, fee, tokensBurned);
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

    /// @notice Tokens bought with `amount` wei.
    function tokensFor(uint256 amount) public view returns (uint256) {
        return (amount * tokensForSale) / hardCap;
    }

    function status() public view returns (Status) {
        if (finalized) return Status.Finalized;
        if (block.timestamp < startTime) return Status.Upcoming;
        if (totalRaised == hardCap) return Status.Succeeded;
        if (block.timestamp < endTime) return Status.Live;
        return totalRaised >= softCap ? Status.Succeeded : Status.Failed;
    }

    function _contribute() private nonReentrant {
        if (status() != Status.Live) revert SaleNotLive();

        uint256 remaining = hardCap - totalRaised;
        uint256 amount = msg.value > remaining ? remaining : msg.value;
        if (amount == 0) revert NothingToContribute();

        contributions[msg.sender] += amount;
        totalRaised += amount;
        emit Contributed(msg.sender, amount, totalRaised);

        if (msg.value > amount) _sendNative(msg.sender, msg.value - amount);
    }

    function _sendNative(address to, uint256 amount) private {
        (bool sent, ) = to.call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
    }
}
