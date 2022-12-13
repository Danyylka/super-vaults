// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router} from "../interfaces/IUniswapV2Router.sol";
import {UniswapV2Library} from "../utils/UniswapV2Library.sol";

import {DexSwap} from "../utils/swapUtils.sol";

import "forge-std/console.sol";

/// @notice WIP: ERC4626 UniswapV2 Adapter - Allows exit & join to UniswapV2 LP Pools from ERC4626 interface
/// Uses virtual price to calculate exit/entry amounts (slippage is yet not considered, TODO: invariant)
/// Example Pool: https://v2.info.uniswap.org/pair/0xae461ca67b15dc8dc81ce7615e0320da1a9ab8d5 (DAI-USDC LP/PAIR on ETH)
contract UniswapV2ERC4626Swap is ERC4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    address public immutable manager;

    uint256 public slippage;
    uint256 public immutable slippageFloat = 10000;

    IUniswapV2Pair public immutable pair;
    IUniswapV2Router public immutable router;

    ERC20 public token0;
    ERC20 public token1;

    constructor(
        ERC20 asset_,
        string memory name_,
        string memory symbol_,
        IUniswapV2Router router_,
        IUniswapV2Pair pair_,
        uint256 slippage_
    ) ERC4626(asset_, name_, symbol_) {
        manager = msg.sender;

        pair = pair_;
        router = router_;

        address token0_ = pair.token0();
        address token1_ = pair.token1();

        if (address(asset) == token0_) {
            token0 = asset;
            token1 = ERC20(token1_);
        } else {
            token0 = ERC20(token0_);
            token1 = asset;
        }

        slippage = slippage_;

        /// TODO: Approve management
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        ERC20(address(pair)).approve(address(router), type(uint256).max);
    }

    function liquidityRemove(uint256 assets, uint256 shares)
        internal
        returns (uint256 assets0, uint256 assets1)
    {
        /// now we have asset (t0 || t1) virtual amount passed as arg
        /// TODO: use this amount for allowed slippage checks (for simulated output vs real removeLiquidity t0/t1)

        /// @dev Values are sorted because we sort if t0/t1 == asset at runtime
        (assets0, assets1) = getAssetsAmounts(shares);

        console.log("totalAssets", totalAssets());
        console.log("withdraw shares", shares);
        console.log("withdraw a0", assets0, "a1", assets1);

        /// temp implementation, we should call directly on a pair
        (assets0, assets1) = router.removeLiquidity(
            address(token0),
            address(token1),
            shares,
            assets0 - getSlippage(assets0),
            assets1 - getSlippage(assets1),
            address(this),
            block.timestamp + 100
        );

        console.log("aA", assets0, "aB", assets1);
    }

    function liquidityAdd() internal returns (uint256 li) {
        (uint256 assets0, uint256 assets1) = getAssetBalance();

        /// temp implementation, we should call directly on a pair
        (, , li) = router.addLiquidity(
            address(token0),
            address(token1),
            assets0,
            assets1,
            assets0 - getSlippage(assets0),
            assets1 - getSlippage(assets1),
            address(this),
            block.timestamp + 100
        );
    }

    /// @notice receives tokenX of UniV2 pair and mints shares of this vault for deposited tokenX/Y into UniV2 pair
    function deposit(uint256 assets, address receiver)
        public
        override
        returns (uint256 shares)
    {
        asset.safeTransferFrom(msg.sender, address(this), assets);

        swapJoin(assets);

        /// @dev totalAssets holds sum of all UniLP,
        /// UniLP is non-rebasing, yield accrues on Uniswap pool (you can redeem more t0/t1 for same amount of LP)
        /// NOTE: If we want it as Strategy, e.g do something with this LP, then we need to calculate shares, 1:1 won't work
        require((shares = liquidityAdd()) != 0, "ZERO_SHARES");

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        returns (uint256 assets)
    {
        /// TODO To implement previewMint calculations
        assets = previewMint(shares);

        asset.safeTransferFrom(msg.sender, address(this), assets);

        swapJoin(assets);

        shares = liquidityAdd();

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice burns shares from owner and sends exactly assets of underlying tokens to receiver.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 shares) {
        /// how many shares of this wrapper LP we need to burn to get this amount of token0 assets
        /// If user joined with 100 DAI, he owns a claim to 50token0/50token1
        /// this will output required shares to burn for only token0
        shares = previewWithdraw(assets);

        console.log("shares to burn for asset", shares);

        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }

        (uint256 assets0, uint256 assets1) = liquidityRemove(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        console.log("assets safeTransfer", assets);
        console.log("assets0 swapJoin", assets0);
        console.log("assets1 swapJoin", assets1);

        /// @dev ideally contract for token0/1 should know what assets amount to use without conditional checks, gas overhead
        uint256 amount = asset == token0
            ? swapExit(assets1) + assets0
            : swapExit(assets0) + assets1;

        console.log("assetsSwapped safeTransfer", amount);
        console.log("assetsSwapped safeTransfer (sum)", amount);
        console.log(
            "assets available to withdraw:",
            asset.balanceOf(address(this))
        );
        asset.safeTransfer(receiver, amount);

        /// NOTE: User "virtually" redeemed a value of assets, as two tokens equal to the virtual assets value
        /// NOTE: Add function for that variant of withdraw
        // token0.safeTransfer(receiver, assets0);
        // token1.safeTransfer(receiver, assets1);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        console.log("redeem assets", assets);

        (uint256 assets0, uint256 assets1) = liquidityRemove(assets, shares);

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        /// TODO: Explore this exit swap
        uint256 amount = asset == token0
            ? swapExit(assets1) + assets0
            : swapExit(assets0) + assets1;

        console.log("assetsSwapped safeTransfer", amount);
        console.log("assetsSwapped safeTransfer (sum)", amount);

        asset.safeTransfer(receiver, amount);

        /// NOTE: User "virtually" redeemed a value of assets, as two tokens equal to the virtual assets value
        /// NOTE: Add function for that variant of withdraw
        // token0.safeTransfer(receiver, assets0);
        // token1.safeTransfer(receiver, assets1);
    }

    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////// ACCOUNTING //////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////

    /// @notice totalAssets virtualAssets should grow with fees accrued to lp tokens held by this vault
    function totalAssets() public view override returns (uint256) {
        return pairBalance();
    }

    function pairBalance() public view returns (uint256) {
        return pair.balanceOf(address(this));
    }

    /// @notice calculate value of shares of this vault as the sum of t0/t1 of UniV2 pair simulated as t0 or t1 total amount after swap
    function virtualAssets(uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        (uint256 a0, uint256 a1) = getAssetsAmounts(shares);

        if (a1 == 0 || a0 == 0) return 0;

        (uint256 resA, uint256 resB) = UniswapV2Library.getReserves(
            address(pair),
            address(token0),
            address(token1)
        );

        // NOTE: Why getAmountOut here? Why not quote?
        return a0 + UniswapV2Library.getAmountOut(a1, resB, resA);
    }

    /// @notice for this many DAI (assets) we get this many shares
    function previewDeposit(uint256 assets)
        public
        view
        override
        returns (uint256 shares)
    {
        uint256 reserve = _getReserves();

        uint256 swapAmt = UniswapV2Library.getSwapAmount(reserve, assets);

        shares = getLiquidityAmountOutFor(assets, swapAmt);
    }

    /// @notice TODO: Currently unused, only to simulate value. Adding slipage makes this usefull.
    function previewMint(uint256 shares)
        public
        view
        override
        returns (uint256 assets)
    {
        assets = virtualAssets(shares);
    }

    /// we need only assets umount up to the 50% LP amount
    /// how many shares of this wrapper LP we need to burn to get this amount of token0 assets
    function previewWithdraw(uint256 assets)
        public
        view
        override
        returns (uint256 shares)
    {
        return getSharesFromAssets(assets);
    }

    /// @notice TODO: Currently unused, only to simulate value. Adding slipage makes this usefull.
    function previewRedeem(uint256 shares)
        public
        view
        override
        returns (uint256 assets)
    {
        return convertToAssets(shares);
    }

    /// I am burning SHARES, how much of (virtual) ASSETS (tokenX) do I get (in sum of both tokens)
    function convertToAssets(uint256 shares)
        public
        view
        override
        returns (uint256 assets)
    {
        assets = virtualAssets(shares);
    }

    ////////////////////////////////////////////////////////////////////////////
    /////////////////////////// UNISWAP CALLS //////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////

    /// @notice directional swap from asset to opposite token (asset != tokenX) TODO: consolidate Join/Exit
    /// calculates optimal (for current block) amount of token0/token1 to deposit to Uni Pool and splits provided assets according to formula
    function swapJoin(uint256 assets) internal returns (uint256 amount) {
        uint256 reserve = _getReserves();

        /// NOTE:
        /// resA if asset == token0
        /// resB if asset == token1
        amount = UniswapV2Library.getSwapAmount(reserve, assets);

        _swap(amount, true);
    }

    /// @notice directional swap from asset to opposite token (asset != tokenX) TODO: consolidate Join/Exit
    /// exit is in opposite direction to Join but we don't need to calculate splitting, just swap provided assets, check happen in withdraw/redeem
    function swapExit(uint256 assets) internal returns (uint256) {
        return _swap(assets, false);
    }

    /// @notice low level swap to either get tokenY opposite to asset (tokenX) or to get asset (tokenX) from removed liquidity tokenY
    function _swap(uint256 amount, bool join)
        internal
        returns (uint256 amounts)
    {
        if (join) {
            (address fromToken, address toToken) = _getJoinToken();
            amounts = DexSwap.swap(
                /// amt to swap
                amount,
                /// from asset
                fromToken,
                /// to asset
                toToken,
                /// pair address
                address(pair)
            );
        } else {
            (address fromToken, address toToken) = _getExitToken();
            amounts = DexSwap.swap(
                /// amt to swap
                amount,
                /// from asset
                fromToken,
                /// to asset
                toToken,
                /// pair address
                address(pair)
            );
        }
    }

    /// @notice Sort function for this Vault Uniswap pair exit operation
    function _getExitToken() internal view returns (address t0, address t1) {
        if (token0 == asset) {
            t0 = address(token1);
            t1 = address(token0);
        } else {
            t0 = address(token0);
            t1 = address(token1);
        }
    }

    /// @notice Sort function for this Vault Uniswap pair join operation
    function _getJoinToken() internal view returns (address t0, address t1) {
        if (token0 == asset) {
            t0 = address(token0);
            t1 = address(token1);
        } else {
            t0 = address(token1);
            t1 = address(token0);
        }
    }

    /// @notice Selector for reseve of underlying asset
    function _getReserves() internal view returns (uint256 assetReserves) {
        if (token0 == asset) {
            (assetReserves, ) = UniswapV2Library.getReserves(
                address(pair),
                address(token0),
                address(token1)
            );
        } else {
            (, assetReserves) = UniswapV2Library.getReserves(
                address(pair),
                address(token0),
                address(token1)
            );
        }
    }

    /// @notice transfer assets from this contract balance to the pair contract TODO: security review, used in deposit
    function getAssetBalance() internal view returns (uint256 a0, uint256 a1) {
        a0 = token0.balanceOf(address(this));
        a1 = token1.balanceOf(address(this));
    }

    /// @notice for requested 100 UniLp tokens, how much tok0/1 we need to give?
    function getAssetsAmounts(uint256 poolLpAmount)
        public
        view
        returns (uint256 assets0, uint256 assets1)
    {
        /// get xy=k here, where x=ra0,y=ra1
        (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(
            address(pair),
            address(token0),
            address(token1)
        );
        /// shares of uni pair contract
        uint256 pairSupply = pair.totalSupply();
        /// amount of token0 to provide to receive poolLpAmount
        assets0 = (reserveA * poolLpAmount) / pairSupply;
        /// amount of token1 to provide to receive poolLpAmount
        assets1 = (reserveB * poolLpAmount) / pairSupply;
    }

    function getLiquidityAmountOutFor(uint256 assets0, uint256 assets1)
        public
        view
        returns (uint256 poolLpAmount)
    {
        uint256 pairSupply = pair.totalSupply();

        (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(
            address(pair),
            address(token0),
            address(token1)
        );
        poolLpAmount = min(
            ((assets0 * pairSupply) / reserveA),
            (assets1 * pairSupply) / reserveB
        );
    }

    /// @notice Take amount of token0 > split to token0/token1 amounts > calculate how much shares to burn
    function getSharesFromAssets(uint256 assets)
        public
        view
        returns (uint256 poolLpAmount)
    {

        (uint256 assets0, uint256 assets1) = getSplitAssetAmounts(assets);

        console.log("amountOfDaiToSwapToUSDC", assets0);
        console.log("amountOfUSDCfromDAI", assets1);

        poolLpAmount = getLiquidityAmountOutFor(assets0, assets1);
    }

    /// @notice Take amount of token0 (underlying) > split to token0/token1 (virtual) amounts
    function getSplitAssetAmounts(uint256 assets)
        public
        view
        returns (uint256 assets0, uint256 assets1)
    {
        (uint256 resA, uint256 resB) = UniswapV2Library.getReserves(
            address(pair),
            address(token0),
            address(token1)
        );

        uint256 toSwapForUnderlying = UniswapV2Library.getSwapAmount(
            _getReserves(), /// either resA or resB
            assets
        );

        if (token0 == asset) {
            uint256 resultOfSwap = UniswapV2Library.quote(
                toSwapForUnderlying,
                resA,
                resB
            );

            assets0 = toSwapForUnderlying;
            assets1 = resultOfSwap;
        } else {
            uint256 resultOfSwap = UniswapV2Library.quote(
                toSwapForUnderlying,
                resB,
                resA
            );

            assets0 = resultOfSwap;
            assets1 = toSwapForUnderlying;
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    /////////////////////////// SLIPPAGE MGMT //////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////

    function setSlippage(uint256 amount) external {
        require(msg.sender == manager, "owner");
        require(amount < 10000 && amount > 9000); /// 10% max slippage
        slippage = amount;
    }

    function getSlippage(uint256 amount) internal view returns (uint256) {
        return (amount * slippage) / slippageFloat;
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }
}
