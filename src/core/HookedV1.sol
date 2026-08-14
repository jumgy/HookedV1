// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {IMainToken} from "../interfaces/IMainToken.sol";
import {IFeeCollector, BuyRecord} from "../interfaces/IFeeCollector.sol";
import {IJackpot, JackpotRecord} from "../interfaces/IJackpot.sol";

/// @title HookedV1 — shared Uniswap v4 hook for MainToken/USDG listings
/// @dev Buy: 10% of Main out — 6.5% Main to rewards, 3.5% converted to USDG (2% jackpot / 1.5% ops).
///      Sell: 3.5% of USDG out — 2% jackpot / 1.5% ops. Fees taken via afterSwapReturnDelta.
contract HookedV1 is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    uint128 public constant TOTAL_BIPS = 10_000;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint128 public constant BUY_FEE_BPS = 1000;
    uint128 public constant BUY_REWARDS_BPS = 650;
    uint128 public constant BUY_JACKPOT_BPS = 200;
    uint128 public constant BUY_OPS_BPS = 150;

    uint128 public constant SELL_FEE_BPS = 350;
    uint128 public constant SELL_JACKPOT_BPS = 200;
    uint128 public constant SELL_OPS_BPS = 150;

    struct ListingConfig {
        address mainToken;
        address feeCollector;
        address jackpot;
        address opsWallet;
        bool active;
    }

    struct PoolConfig {
        address mainToken;
        uint256 listingId;
        bool active;
    }

    uint24 public poolFee = 3000;
    int24 public tickSpacing = 60;

    address public immutable usdg;
    address public positionManager;

    mapping(uint256 => ListingConfig) public listings;
    mapping(address => uint256) public listingIdByMainToken;
    mapping(PoolId => PoolConfig) public pools;
    mapping(uint256 => uint256) public poolCountByListing;
    uint256 public poolCount;
    uint256 public buyCount;

    mapping(address => bool) public feeExemptSwappers;

    event ListingConfigured(
        uint256 indexed listingId,
        address indexed mainToken,
        address feeCollector,
        address jackpot,
        address opsWallet
    );
    event ListingDeactivated(uint256 indexed listingId);
    event PoolRegistered(bytes32 indexed poolId, uint256 indexed listingId, address mainToken);
    event FeeExemptSet(address indexed account, bool exempt);
    event PositionManagerUpdated(address indexed positionManager);
    event PoolParamsUpdated(uint24 poolFee, int24 tickSpacing);
    event BuyFeeRecorded(
        uint256 indexed listingId,
        uint256 indexed buyId,
        address mainToken,
        uint256 quoteAmountIn,
        uint256 mainAmountOut,
        uint256 feeMainTaken,
        uint256 feeMainToCollector,
        uint256 feeQuoteToJackpot,
        uint256 feeQuoteToOps,
        uint64 timestamp,
        uint64 blockNumber
    );
    event SellFeeCollected(
        bytes32 indexed poolId,
        uint256 indexed listingId,
        uint256 feeQuoteTaken,
        uint256 feeQuoteToJackpot,
        uint256 feeQuoteToOps
    );
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event EthRescued(address indexed to, uint256 amount);

    error PoolAlreadyRegistered();
    error NotOwner();
    error ExactOutputNotAllowed();
    error ZeroAddress();
    error InvalidPoolKey();
    error UnauthorizedLiquidity();
    error InvalidFeeParams();
    error InvalidListingId();
    error ListingNotConfigured();
    error MainTokenAlreadyAssigned();
    error ListingHasLivePools();
    error MainMustBeToken1();
    error InvalidQuote();
    error EthTransferFailed();

    constructor(IPoolManager _poolManager, address _owner, address _usdg, address _positionManager)
        BaseHook(_poolManager)
        Ownable(_owner)
    {
        if (_usdg == address(0) || _positionManager == address(0)) revert ZeroAddress();
        usdg = _usdg;
        positionManager = _positionManager;
        feeExemptSwappers[address(this)] = true;
    }

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function isPoolActive(PoolId id) public view returns (bool) {
        return pools[id].active;
    }

    function mainTokenOf(PoolId id) public view returns (address) {
        return pools[id].mainToken;
    }

    function listingOf(PoolId id) public view returns (uint256) {
        return pools[id].listingId;
    }

    function setListing(
        uint256 listingId,
        address mainToken,
        address feeCollector_,
        address jackpot_,
        address opsWallet_
    ) external onlyOwner {
        if (listingId == 0) revert InvalidListingId();
        if (mainToken == address(0) || feeCollector_ == address(0) || jackpot_ == address(0) || opsWallet_ == address(0)) {
            revert ZeroAddress();
        }
        if (mainToken <= usdg) revert MainMustBeToken1();

        ListingConfig storage cfg = listings[listingId];
        bool firstTime = cfg.mainToken == address(0);

        if (!firstTime && cfg.mainToken != mainToken) {
            if (poolCountByListing[listingId] > 0) revert ListingHasLivePools();
            delete listingIdByMainToken[cfg.mainToken];
        }

        uint256 existingId = listingIdByMainToken[mainToken];
        if (existingId != 0 && existingId != listingId) revert MainTokenAlreadyAssigned();

        cfg.mainToken = mainToken;
        cfg.feeCollector = feeCollector_;
        cfg.jackpot = jackpot_;
        cfg.opsWallet = opsWallet_;
        cfg.active = true;
        listingIdByMainToken[mainToken] = listingId;

        emit ListingConfigured(listingId, mainToken, feeCollector_, jackpot_, opsWallet_);
    }

    function setListingFeeCollector(uint256 listingId, address feeCollector_) external onlyOwner {
        ListingConfig storage cfg = listings[listingId];
        if (cfg.mainToken == address(0)) revert ListingNotConfigured();
        if (feeCollector_ == address(0)) revert ZeroAddress();
        cfg.feeCollector = feeCollector_;
        emit ListingConfigured(listingId, cfg.mainToken, feeCollector_, cfg.jackpot, cfg.opsWallet);
    }

    function setListingJackpot(uint256 listingId, address jackpot_) external onlyOwner {
        ListingConfig storage cfg = listings[listingId];
        if (cfg.mainToken == address(0)) revert ListingNotConfigured();
        if (jackpot_ == address(0)) revert ZeroAddress();
        cfg.jackpot = jackpot_;
        emit ListingConfigured(listingId, cfg.mainToken, cfg.feeCollector, jackpot_, cfg.opsWallet);
    }

    function setListingOpsWallet(uint256 listingId, address opsWallet_) external onlyOwner {
        ListingConfig storage cfg = listings[listingId];
        if (cfg.mainToken == address(0)) revert ListingNotConfigured();
        if (opsWallet_ == address(0)) revert ZeroAddress();
        cfg.opsWallet = opsWallet_;
        emit ListingConfigured(listingId, cfg.mainToken, cfg.feeCollector, cfg.jackpot, opsWallet_);
    }

    function deactivateListing(uint256 listingId) external onlyOwner {
        if (listings[listingId].mainToken == address(0)) revert ListingNotConfigured();
        listings[listingId].active = false;
        emit ListingDeactivated(listingId);
    }

    function setPositionManager(address manager) external onlyOwner {
        if (manager == address(0)) revert ZeroAddress();
        positionManager = manager;
        emit PositionManagerUpdated(manager);
    }

    function setFeeExemptSwapper(address account, bool exempt) external onlyOwner {
        feeExemptSwappers[account] = exempt;
        emit FeeExemptSet(account, exempt);
    }

    function setPoolParams(uint24 poolFee_, int24 tickSpacing_) external onlyOwner {
        if (tickSpacing_ == 0) revert InvalidFeeParams();
        poolFee = poolFee_;
        tickSpacing = tickSpacing_;
        emit PoolParamsUpdated(poolFee_, tickSpacing_);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    function rescueETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthRescued(to, amount);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != owner()) revert NotOwner();
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();
        if (key.fee != poolFee || key.tickSpacing != tickSpacing) revert InvalidPoolKey();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (token0 != usdg) revert InvalidQuote();
        if (token1 == address(0)) revert MainMustBeToken1();

        uint256 listingId = listingIdByMainToken[token1];
        ListingConfig memory cfg = listings[listingId];
        if (listingId == 0 || !cfg.active || cfg.mainToken != token1) revert ListingNotConfigured();
        if (token1 <= token0) revert MainMustBeToken1();

        PoolId id = key.toId();
        if (pools[id].active) revert PoolAlreadyRegistered();

        pools[id] = PoolConfig({mainToken: token1, listingId: listingId, active: true});
        poolCount++;
        poolCountByListing[listingId]++;
        emit PoolRegistered(PoolId.unwrap(id), listingId, token1);
        return IHooks.beforeInitialize.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        PoolConfig memory cfg = pools[id];
        if (!cfg.active) {
            return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
        }
        if (sender != positionManager && sender != owner()) revert UnauthorizedLiquidity();
        _grantMainTransferAllowance(cfg.mainToken, id, delta);
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        PoolConfig memory cfg = pools[id];
        if (!cfg.active) {
            return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
        }
        if (sender != positionManager && sender != owner()) revert UnauthorizedLiquidity();
        _grantMainTransferAllowance(cfg.mainToken, id, delta);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolConfig memory cfg = pools[id];
        if (!cfg.active) {
            return (IHooks.afterSwap.selector, 0);
        }
        if (params.amountSpecified > 0) revert ExactOutputNotAllowed();

        ListingConfig memory listing = listings[cfg.listingId];
        if (listing.feeCollector == address(0) || listing.jackpot == address(0) || listing.opsWallet == address(0)) {
            revert ListingNotConfigured();
        }

        bytes32 idRaw = PoolId.unwrap(id);
        uint256 mainAbs = _absAmount1(delta);
        if (mainAbs > 0) {
            IMainToken(cfg.mainToken).increaseTransferAllowance(idRaw, mainAbs);
        }

        if (feeExemptSwappers[sender]) {
            return (IHooks.afterSwap.selector, 0);
        }

        // Main is always currency1; buy = USDG(token0) → main(token1).
        bool isBuy = params.zeroForOne;
        uint128 feeBps = isBuy ? BUY_FEE_BPS : SELL_FEE_BPS;

        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency feeCurrency, int128 swapAmount) =
            specifiedTokenIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (swapAmount < 0) swapAmount = -swapAmount;

        uint256 totalFeeAmount = (uint256(uint128(swapAmount)) * feeBps) / TOTAL_BIPS;
        if (totalFeeAmount == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        if (Currency.unwrap(feeCurrency) == cfg.mainToken) {
            IMainToken(cfg.mainToken).increaseTransferAllowance(idRaw, totalFeeAmount);
        }

        poolManager.take(feeCurrency, address(this), totalFeeAmount);

        if (isBuy) {
            _handleBuyFee(key, cfg, listing, delta, totalFeeAmount);
        } else {
            _handleSellFee(idRaw, cfg.listingId, listing, cfg.mainToken, totalFeeAmount);
        }

        return (IHooks.afterSwap.selector, totalFeeAmount.toInt128());
    }

    function _handleBuyFee(
        PoolKey memory key,
        PoolConfig memory cfg,
        ListingConfig memory listing,
        BalanceDelta delta,
        uint256 totalFeeAmount
    ) internal {
        uint256 quoteAmountIn = _abs(delta.amount0());
        uint256 mainAmountOut = _abs(delta.amount1());

        uint256 toCollector = (mainAmountOut * BUY_REWARDS_BPS) / TOTAL_BIPS;
        uint256 toConvert = totalFeeAmount - toCollector;

        uint256 quoteReceived;
        if (toConvert > 0) {
            quoteReceived = _swapMainToQuote(key, toConvert);
        }

        uint256 convertBps = BUY_JACKPOT_BPS + BUY_OPS_BPS;
        uint256 jackpotUsdg = (quoteReceived * BUY_JACKPOT_BPS) / convertBps;
        uint256 opsUsdg = quoteReceived - jackpotUsdg;

        if (toCollector > 0) {
            IERC20(cfg.mainToken).safeTransfer(listing.feeCollector, toCollector);
        }
        if (jackpotUsdg > 0) {
            IERC20(usdg).safeTransfer(listing.jackpot, jackpotUsdg);
        }
        if (opsUsdg > 0) {
            IERC20(usdg).safeTransfer(listing.opsWallet, opsUsdg);
        }

        uint256 buyId = ++buyCount;
        uint64 ts = uint64(block.timestamp);
        uint64 bn = uint64(block.number);

        BuyRecord memory record = BuyRecord({
            listingId: cfg.listingId,
            buyId: buyId,
            quoteToken: usdg,
            mainToken: cfg.mainToken,
            quoteAmountIn: quoteAmountIn,
            mainAmountOut: mainAmountOut,
            feeMainTaken: totalFeeAmount,
            feeMainToCollector: toCollector,
            feeQuoteToJackpot: jackpotUsdg,
            feeQuoteToOps: opsUsdg,
            timestamp: ts,
            blockNumber: bn
        });

        IFeeCollector(listing.feeCollector).receiveBuyFee(record);

        if (jackpotUsdg > 0) {
            IJackpot(listing.jackpot).receiveJackpotFee(
                JackpotRecord({
                    listingId: cfg.listingId,
                    buyId: buyId,
                    isBuy: true,
                    mainToken: cfg.mainToken,
                    usdgAmount: jackpotUsdg,
                    mainAmountConverted: toConvert,
                    timestamp: ts,
                    blockNumber: bn
                })
            );
        }

        emit BuyFeeRecorded(
            record.listingId,
            record.buyId,
            record.mainToken,
            record.quoteAmountIn,
            record.mainAmountOut,
            record.feeMainTaken,
            record.feeMainToCollector,
            record.feeQuoteToJackpot,
            record.feeQuoteToOps,
            record.timestamp,
            record.blockNumber
        );
    }

    function _handleSellFee(
        bytes32 poolId,
        uint256 listingId,
        ListingConfig memory listing,
        address mainToken,
        uint256 totalFeeAmount
    ) internal {
        uint256 jackpotUsdg = (totalFeeAmount * SELL_JACKPOT_BPS) / SELL_FEE_BPS;
        uint256 opsUsdg = totalFeeAmount - jackpotUsdg;

        if (jackpotUsdg > 0) {
            IERC20(usdg).safeTransfer(listing.jackpot, jackpotUsdg);
        }
        if (opsUsdg > 0) {
            IERC20(usdg).safeTransfer(listing.opsWallet, opsUsdg);
        }

        if (jackpotUsdg > 0) {
            IJackpot(listing.jackpot).receiveJackpotFee(
                JackpotRecord({
                    listingId: listingId,
                    buyId: 0,
                    isBuy: false,
                    mainToken: mainToken,
                    usdgAmount: jackpotUsdg,
                    mainAmountConverted: 0,
                    timestamp: uint64(block.timestamp),
                    blockNumber: uint64(block.number)
                })
            );
        }

        emit SellFeeCollected(poolId, listingId, totalFeeAmount, jackpotUsdg, opsUsdg);
    }

    function _swapMainToQuote(PoolKey memory key, uint256 mainAmount) internal returns (uint256 quoteReceived) {
        uint256 quoteBefore = IERC20(usdg).balanceOf(address(this));

        BalanceDelta swapDelta = poolManager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(mainAmount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            bytes("")
        );

        key.currency1.settle(poolManager, address(this), uint256(int256(-swapDelta.amount1())), false);
        key.currency0.take(poolManager, address(this), uint256(int256(swapDelta.amount0())), false);

        quoteReceived = IERC20(usdg).balanceOf(address(this)) - quoteBefore;
    }

    function _grantMainTransferAllowance(address mainToken, PoolId id, BalanceDelta delta) internal {
        uint256 amount = _absAmount1(delta);
        if (amount > 0) {
            IMainToken(mainToken).increaseTransferAllowance(PoolId.unwrap(id), amount);
        }
    }

    function _absAmount1(BalanceDelta delta) internal pure returns (uint256) {
        return _abs(delta.amount1());
    }

    function _abs(int128 amount) internal pure returns (uint256) {
        return amount < 0 ? uint256(uint128(-amount)) : uint256(uint128(amount));
    }
}
