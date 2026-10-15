// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {TokenSaleV3} from "./TokenSaleV3.sol";

/// @title Somewhere Launchpad v3: fixed-price launches paired with any allowed asset
/// @notice Creates token launches like the v2 launchpad, with what v3 adds:
///
/// - Each launch is sold for, and paired on the exchange with, an asset the
///   creator picks from the ones this launchpad allows: a stablecoin, a
///   tokenized stock, another crypto asset, or the native currency through its
///   wrapped token (WETH on Ethereum). Each allowed asset has its own minimum
///   raise, since 0.01 ETH and 0.01 USDC are not comparable.
/// - A ticker can only be used by one live launch of this launchpad. It is
///   freed when that launch is cancelled or fails.
/// - Anyone can check on-chain whether a token came from this launchpad
///   (`isOfficial`, `saleOf`), so a copy with the same name cannot pass for it.
/// - A launch can require its buyers to be verified to a given tier. The
///   verification is done by a third party; what reaches the chain is only a
///   signed statement of the tier, from the attestor this launchpad names.
/// - Each sale and vesting is a minimal clone (EIP-1167) of one implementation,
///   deployed separately, which keeps this contract small.
///
/// The owner (the platform) can change, for future launches only, the fee
/// (never above 1%) and the allowed assets; and, for every launch, who collects
/// fees and who signs verifications. Removing an asset never affects launches
/// already created with it. There is no upgrade mechanism.
contract LaunchpadV3 is Ownable2Step, EIP712 {
    struct LaunchParams {
        string name;
        /// 1 to 10 characters, only A–Z and 0–9.
        string symbol;
        /// Whole supply of the token, with 18 decimals.
        uint256 totalSupply;
        /// What the token is sold for and paired with. Must be allowed.
        address quoteAsset;
        /// Minimum to raise, in the smallest unit of the quote asset.
        uint256 softCap;
        /// Maximum to raise, in the smallest unit of the quote asset.
        uint256 hardCap;
        /// Least a wallet can have contributed. Zero for no minimum.
        uint256 minContribution;
        /// Most a wallet can contribute. Zero for no maximum.
        uint256 maxContribution;
        uint64 startTime;
        uint64 endTime;
        /// Share of the supply for the creator, in basis points (100 = 1%).
        uint16 creatorAllocationBps;
        /// Share of the raise that goes to locked liquidity, in basis points.
        uint16 liquidityBps;
        /// Monthly tranches in which the creator receives the rest.
        uint8 vestingTranches;
        /// Verification tier buyers need. Zero for anyone.
        uint8 requiredTier;
    }

    struct Launch {
        address token;
        address sale;
        address vesting;
        address creator;
        address quoteAsset;
    }

    struct QuoteAsset {
        bool allowed;
        /// Smallest soft cap a launch paired with this asset can have.
        uint256 minSoftCap;
    }

    uint256 private constant BPS = 10_000;
    bytes32 private constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(address account,uint8 tier,uint64 expiresAt)");

    /// @notice No creator can keep more than 1% of the supply.
    uint16 public constant MAX_CREATOR_ALLOCATION_BPS = 100;
    /// @notice The platform fee can never be set above 1% of what is raised.
    uint16 public constant MAX_FEE_BPS = 100;
    /// @notice At least 70% of what is raised goes to locked liquidity.
    uint16 public constant MIN_LIQUIDITY_BPS = 7000;
    /// @notice The creator is paid in at least three monthly tranches.
    uint8 public constant MIN_VESTING_TRANCHES = 3;
    uint8 public constant MAX_VESTING_TRANCHES = 48;
    uint64 public constant MAX_SALE_DURATION = 30 days;
    /// @notice A sale cannot be scheduled further ahead than this.
    uint64 public constant MAX_START_DELAY = 90 days;
    /// @notice 1,000 whole tokens.
    uint256 public constant MIN_TOTAL_SUPPLY = 1_000e18;
    /// @notice Keeps every amount far from overflowing: 10^15 whole tokens.
    uint256 public constant MAX_TOTAL_SUPPLY = 1e33;
    uint256 public constant MAX_SYMBOL_LENGTH = 10;

    IUniswapV2Factory public immutable dexFactory;
    /// @notice Wrapped native currency. A launch paired with it takes and pays
    /// out the native currency itself.
    address public immutable weth;
    address public immutable saleImplementation;
    address public immutable vestingImplementation;

    /// @notice Fee applied to launches created from now on.
    uint16 public feeBps;
    /// @notice Who collects the fees of every launch, past and future.
    address public feeRecipient;
    /// @notice Who signs verification tiers. Zero while there is none.
    address public attestor;

    mapping(address asset => QuoteAsset) public quoteAssets;

    Launch[] private _launches;
    /// launchId + 1 of the launch that holds each ticker; zero when free.
    mapping(bytes32 ticker => uint256 launchIdPlusOne) private _tickerHolders;
    /// launchId + 1 of the launch that created each token; zero for any other token.
    mapping(address token => uint256 launchIdPlusOne) private _launchOfToken;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed creator,
        address indexed token,
        address sale,
        address vesting,
        LaunchParams params,
        uint256 tokensForSale,
        uint256 creatorAllocation,
        uint16 feeBps
    );
    event QuoteAssetUpdated(address indexed asset, bool allowed, uint256 minSoftCap);
    event TickerReleased(uint256 indexed launchId, string symbol);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address feeRecipient);
    event AttestorUpdated(address attestor);

    error ZeroAddress();
    error EmptyName();
    error InvalidSymbol();
    error TickerTaken();
    error TickerInUse();
    error QuoteAssetNotAllowed();
    error InvalidQuoteAsset();
    error InvalidTotalSupply();
    error CreatorAllocationTooHigh();
    error InvalidCaps();
    error InvalidContributionLimits();
    error InvalidSchedule();
    error InvalidLiquidityShare();
    error InvalidVesting();
    error NoAttestor();
    error FeeTooHigh();

    constructor(
        address owner_,
        IUniswapV2Factory dexFactory_,
        address weth_,
        address saleImplementation_,
        address vestingImplementation_,
        address feeRecipient_,
        uint16 feeBps_
    ) Ownable(owner_) EIP712("Somewhere Launchpad", "3") {
        if (
            address(dexFactory_) == address(0) ||
            weth_ == address(0) ||
            saleImplementation_ == address(0) ||
            vestingImplementation_ == address(0)
        ) revert ZeroAddress();
        dexFactory = dexFactory_;
        weth = weth_;
        saleImplementation = saleImplementation_;
        vestingImplementation = vestingImplementation_;
        _setFeeRecipient(feeRecipient_);
        _setFee(feeBps_);
    }

    /// @notice Creates a token, its sale and its vesting. The caller becomes
    /// the creator and the ticker is reserved for this launch.
    function createLaunch(
        LaunchParams calldata params
    ) external returns (uint256 launchId, address token, address sale) {
        uint16 fee = feeBps;
        _validate(params, fee);

        launchId = _launches.length;
        bytes32 ticker = keccak256(bytes(params.symbol));
        if (_tickerHolders[ticker] != 0) revert TickerTaken();
        _tickerHolders[ticker] = launchId + 1;

        uint256 creatorAllocation = (params.totalSupply * params.creatorAllocationBps) / BPS;
        // For every token sold, `liquidityBps` of a token is paired on the
        // exchange, so the sale takes 1 part and the liquidity reserve
        // `liquidityBps` parts of what is left after the creator allocation.
        uint256 tokensForSale = ((params.totalSupply - creatorAllocation) * BPS) /
            (BPS + params.liquidityBps);
        // Every unit of the quote asset has to buy at least one unit of the token.
        if (tokensForSale < params.hardCap) revert InvalidTotalSupply();

        // The supply is minted here and handed over to the sale in the same
        // transaction; this contract never holds tokens outside of this call.
        token = address(
            new LaunchToken(params.name, params.symbol, params.totalSupply, address(this))
        );
        sale = Clones.clone(saleImplementation);
        address vesting = TokenSaleV3(payable(sale)).initialize(
            TokenSaleV3.Config({
                token: IERC20(token),
                quoteAsset: IERC20(params.quoteAsset),
                creator: msg.sender,
                dexFactory: dexFactory,
                weth: weth,
                vestingImplementation: vestingImplementation,
                tokensForSale: tokensForSale,
                creatorAllocation: creatorAllocation,
                softCap: params.softCap,
                hardCap: params.hardCap,
                minContribution: params.minContribution,
                maxContribution: params.maxContribution,
                startTime: params.startTime,
                endTime: params.endTime,
                liquidityBps: params.liquidityBps,
                feeBps: fee,
                vestingTranches: params.vestingTranches,
                requiredTier: params.requiredTier
            })
        );
        // LaunchToken is a standard OpenZeppelin ERC-20: it reverts on failure.
        IERC20(token).transfer(sale, params.totalSupply);

        _launches.push(
            Launch({
                token: token,
                sale: sale,
                vesting: vesting,
                creator: msg.sender,
                quoteAsset: params.quoteAsset
            })
        );
        _launchOfToken[token] = launchId + 1;

        emit LaunchCreated(
            launchId,
            msg.sender,
            token,
            sale,
            vesting,
            params,
            tokensForSale,
            creatorAllocation,
            fee
        );
    }

    /// @notice Frees the ticker of a launch that was cancelled or failed, so a
    /// new launch can use it. Anyone can call it.
    function releaseTicker(uint256 launchId) external {
        Launch storage launch = _launches[launchId];
        TokenSaleV3.Status status = TokenSaleV3(payable(launch.sale)).status();
        if (status != TokenSaleV3.Status.Cancelled && status != TokenSaleV3.Status.Failed) {
            revert TickerInUse();
        }
        string memory symbol = LaunchToken(launch.token).symbol();
        bytes32 ticker = keccak256(bytes(symbol));
        if (_tickerHolders[ticker] != launchId + 1) revert TickerInUse();

        delete _tickerHolders[ticker];
        emit TickerReleased(launchId, symbol);
    }

    /// @notice Allows an asset for future launches, or stops allowing it.
    /// Launches already created with it keep it.
    function setQuoteAsset(address asset, bool allowed, uint256 minSoftCap) external onlyOwner {
        if (asset.code.length == 0) revert InvalidQuoteAsset();
        if (allowed && minSoftCap == 0) revert InvalidQuoteAsset();
        quoteAssets[asset] = QuoteAsset({allowed: allowed, minSoftCap: minSoftCap});
        emit QuoteAssetUpdated(asset, allowed, minSoftCap);
    }

    function setFee(uint16 feeBps_) external onlyOwner {
        _setFee(feeBps_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        _setFeeRecipient(feeRecipient_);
    }

    /// @notice Names who signs verification tiers. Zero stops every launch
    /// that requires a tier from taking contributions until one is named
    /// again; its sale then fails and contributors get their refunds.
    function setAttestor(address attestor_) external onlyOwner {
        attestor = attestor_;
        emit AttestorUpdated(attestor_);
    }

    function launchCount() external view returns (uint256) {
        return _launches.length;
    }

    function getLaunch(uint256 launchId) external view returns (Launch memory) {
        return _launches[launchId];
    }

    /// @notice Whether `token` was created by this launchpad.
    function isOfficial(address token) external view returns (bool) {
        return _launchOfToken[token] != 0;
    }

    /// @notice The sale of a token created by this launchpad; zero for any other token.
    function saleOf(address token) external view returns (address) {
        uint256 launchIdPlusOne = _launchOfToken[token];
        return launchIdPlusOne == 0 ? address(0) : _launches[launchIdPlusOne - 1].sale;
    }

    /// @notice Whether a new launch could use `symbol` right now.
    function isTickerAvailable(string calldata symbol) external view returns (bool) {
        return _isValidSymbol(bytes(symbol)) && _tickerHolders[keccak256(bytes(symbol))] == 0;
    }

    /// @notice Whether the attestor signed that `account` holds `tier`, at
    /// least `requiredTier`, and the statement has not expired.
    function hasTier(
        address account,
        uint8 requiredTier,
        uint8 tier,
        uint64 expiresAt,
        bytes calldata signature
    ) external view returns (bool) {
        address signer = attestor;
        if (signer == address(0) || tier < requiredTier || expiresAt < block.timestamp) {
            return false;
        }
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(ATTESTATION_TYPEHASH, account, tier, expiresAt))
        );
        return SignatureChecker.isValidSignatureNow(signer, digest, signature);
    }

    function _validate(LaunchParams calldata params, uint16 fee) private view {
        if (bytes(params.name).length == 0) revert EmptyName();
        if (!_isValidSymbol(bytes(params.symbol))) revert InvalidSymbol();
        QuoteAsset memory quote = quoteAssets[params.quoteAsset];
        if (!quote.allowed) revert QuoteAssetNotAllowed();
        if (params.totalSupply < MIN_TOTAL_SUPPLY || params.totalSupply > MAX_TOTAL_SUPPLY) {
            revert InvalidTotalSupply();
        }
        if (params.creatorAllocationBps > MAX_CREATOR_ALLOCATION_BPS) {
            revert CreatorAllocationTooHigh();
        }
        if (params.softCap < quote.minSoftCap || params.softCap > params.hardCap) {
            revert InvalidCaps();
        }
        if (
            params.minContribution > params.hardCap ||
            (params.maxContribution != 0 && params.maxContribution < params.minContribution)
        ) revert InvalidContributionLimits();
        if (
            params.startTime < block.timestamp ||
            params.startTime > block.timestamp + MAX_START_DELAY ||
            params.endTime <= params.startTime ||
            params.endTime - params.startTime > MAX_SALE_DURATION
        ) revert InvalidSchedule();
        // Liquidity and fee together cannot take more than what is raised.
        if (params.liquidityBps < MIN_LIQUIDITY_BPS || params.liquidityBps + fee > BPS) {
            revert InvalidLiquidityShare();
        }
        if (
            params.vestingTranches < MIN_VESTING_TRANCHES ||
            params.vestingTranches > MAX_VESTING_TRANCHES
        ) revert InvalidVesting();
        // Nobody could buy until someone can sign the tier.
        if (params.requiredTier != 0 && attestor == address(0)) revert NoAttestor();
    }

    /// 1 to 10 characters, each A–Z or 0–9. A ticker has one spelling only:
    /// no lowercase twin of "VOID", no look-alike letters from other alphabets.
    function _isValidSymbol(bytes memory symbol) private pure returns (bool) {
        if (symbol.length == 0 || symbol.length > MAX_SYMBOL_LENGTH) return false;
        for (uint256 i = 0; i < symbol.length; i++) {
            bytes1 char = symbol[i];
            bool isLetter = char >= "A" && char <= "Z";
            bool isDigit = char >= "0" && char <= "9";
            if (!isLetter && !isDigit) return false;
        }
        return true;
    }

    function _setFee(uint16 feeBps_) private {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeUpdated(feeBps_);
    }

    function _setFeeRecipient(address feeRecipient_) private {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }
}
