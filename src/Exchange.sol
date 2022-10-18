// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "solmate/auth/Owned.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";

import "makerdao/dss/DaiAbstract.sol";
import "makerdao/dss/PsmAbstract.sol";
import "makerdao/dss/GemJoinAbstract.sol";

import "univ3/interfaces/IUniswapV3Pool.sol";
import "univ3/interfaces/callback/IUniswapV3SwapCallback.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

import { I3PoolCurve } from "./interfaces/I3PoolCurve.sol";
import { IBondingCurve } from "./interfaces/IBondingCurve.sol";
import { IForeignBridge } from "./interfaces/IForeignBridge.sol";

enum Stablecoin { DAI, USDC, USDT }
enum LiquidityProvider { NONE, DAI_PSM, CURVE_FI_3POOL, UNISWAP_V3 }

struct BuyParams {
    // the amount of bzz to buy
    uint256 bzzAmount;
    // the maximum amount of stablecoin (in native stablecoin decimals) to pay for `bzzAmount`
    uint256 maxStablecoinAmount;
    // the stablecoin to use for payment
    Stablecoin inputCoin;
    // the liquidity provider to use for payment
    LiquidityProvider lp;
    // options as a byte
    // bit 0: whether to use permit
    // bit 1: whether to use the bridge
    // therefore options = 1 means use permit, options = 2 means use bridge, options = 3 means use both
    uint256 options;
    // the data for the permit and/or bridge
    bytes data;
}

struct SellParams {
    // the amount of bzz to sell
    uint256 bzzAmount;
    // the minimum amount of stablecoin to receive for `bzzAmount`
    uint256 minStablecoinAmount;
    // which stablecoin to sell to
    Stablecoin outputCoin;
    // the liquidity provider to use for payment
    LiquidityProvider lp;
}

contract Exchange is Owned, IUniswapV3SwapCallback {
    using SafeTransferLib for ERC20;

    // --- constants

    // maximum fee is hardcoded at 100 basis points (1%)
    uint256 public constant MAX_FEE = 100;

    /// @notice Uniswap V3 pool constants from TickMath
    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // --- immutables

    // tokens that are processed in this exchange
    ERC20 private immutable dai;
    ERC20 private immutable bzz;
    ERC20 private immutable usdc;
    ERC20 private immutable usdt;

    // the bonding curve we use for exchanging dai <--> bzz
    IBondingCurve public immutable bc;

    // the curve.fi 3pool we use for exchanging dai <--> usdc/usdt
    I3PoolCurve public immutable curveFi3Pool;

    // the uniswap v3 pool we use for exchanging usdc <--> dai
    IUniswapV3Pool public immutable usdcV3Pool;
    IUniswapV3Pool public immutable usdtV3Pool;

    // the foreign bridge we use for relaying tokens
    IForeignBridge public immutable bridge;

    // the dai psm contract (this comes in handy when moving large amounts of usdc)
    PsmAbstract public immutable psm;

    // --- state

    uint256 public fee;

    constructor(
        address owner,
        address _bc,
        address _curveFi3Pool,
        address _usdcUniswapV3Pool,
        address _usdtUniswapV3Pool,
        address _psm,
        address _bridge,
        uint256 _fee
    ) Owned(owner) {
        require(_fee <= MAX_FEE, "fee/too-high");

        // the bonding curve that we are going to use
        bc = IBondingCurve(_bc);
        // the curve.fi 3pool that we are going to use
        curveFi3Pool = I3PoolCurve(_curveFi3Pool);
        // the amb (arbitrary message bridge) for relaying tokens
        bridge = IForeignBridge(_bridge);
        // the dai psm contract
        psm = PsmAbstract(_psm);

        // the uniswap v3 pool that we are going to use
        usdcV3Pool = IUniswapV3Pool(_usdcUniswapV3Pool);
        usdtV3Pool = IUniswapV3Pool(_usdtUniswapV3Pool);

        // these are the tokens that we are exchanging on the bonding curve
        bzz = ERC20(bc.bondedToken());
        dai = ERC20(bc.collateralToken());

        // other tokens that we can exchange on the curve.fi curve
        usdc = ERC20(curveFi3Pool.coins(1));
        require(usdcV3Pool.token0() == address(dai) && usdcV3Pool.token1() == address(usdc), "exchange/v3-pool/invalid");
        usdt = ERC20(curveFi3Pool.coins(2));
        require(usdtV3Pool.token0() == address(dai) && usdtV3Pool.token1() == address(usdt), "exchange/v3-pool/invalid");

        /// @notice pre-approve the bonding curve for unlimited approval of the exchange's bzz and dai
        dai.approve(address(bc), type(uint256).max);
        bzz.approve(address(bc), type(uint256).max);

        /// @notice pre-approve the curve.fi 3pool for unlimited approval of the exchange's dai, usdc and usdt
        dai.approve(address(curveFi3Pool), type(uint256).max);
        usdc.approve(address(curveFi3Pool), type(uint256).max);
        usdt.approve(address(curveFi3Pool), type(uint256).max);

        /// @notice there is no need to pre-approve uniswap v3 pools as these transactions
        //          are done using callbacks
        
        /// @notice pre-approve the bridge for unlimited spending approval of the exchange's bzz tokens
        /// @dev this may be a security risk if the bridge is hacked, and could subsequently drain
        ///      any fees that this contract may have accumulated, though this motivates the owners
        ///      to regularly sweep tokens from the exchange that have accumulated as fees
        bzz.approve(address(bridge), type(uint256).max);

        /// @notice pre-approve the dai psm gemjoiner for unlimited spending approval of the exchange's usdc tokens
        /// @dev this may be a security risk if the psm is hacked, and could subsequently drain
        ///      any fees that this contract may have accumulated, though this motivates the owners
        ///      to regularly sweep tokens from the exchange that have accumulated as fees
        require(address(usdc) == GemJoinAbstract(psm.gemJoin()).gem(), "psm/gem-mismatch");
        dai.approve(address(psm), type(uint256).max);
        usdc.approve(address(psm.gemJoin()), type(uint256).max);

        // what fee we should collect (maximum hardcoded at 100bps, ie. 1%)
        fee = _fee;
    }

    // --- ADMINISTRATION ---

    /// @dev All functions in this section MUST have the onlyOwner modifier

    /// Allow configuration of uint256 variables after contract deployment, respecting maximums.
    /// @param _fee the fee to set for the exchange
    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "fee/too-high");
        fee = _fee;
    }

    /// Sweeper function for any ERC20 tokens accidentally sent to the contract
    /// @notice this function will send the ERC20 tokens to the owner of the contract
    /// @param token the address of the token to sweep
    /// @param wad amount of ERC20 tokens to send to owner
    function sweep(ERC20 token, uint256 wad) external onlyOwner {
        token.safeTransfer(owner, wad);
    }

    // --- EXCHANGE ---

    /// This exchange allows for exchanging a stablecoin for bzz, and vice versa.
    /// The following routes are supported:
    /// 1)      dai <--> bzz via the bonding curve
    /// 2a)     usdc <--> dai <--> bzz via curve fi 3pool and bonding curve
    /// 2b)     usdc <--> dai <--> bzz via uniswap v3 pool and bonding curve
    /// 2c)     usdc <--> dai <--> bzz via dai psm and bonding curve
    /// 3a)     usdt <--> dai <--> bzz via curve fi 3pool and bonding curve
    /// 3b)     usdt <--> dai <--> bzz via uniswap v3 pool and bonding curve

    /// @notice this function will exchange the input stablecoin token for bzz
    function buy(BuyParams calldata _buyParams) public returns (uint256) {
        // 1. If the input token is not dai, we need to exchange it for dai first
    }

    /// Route 1: dai <--> bzz via the bonding curve
    /// @param wad the amount of bzz to buy from the bonding curve
    /// @param max_collateral_spend the maximum amount of collateral to be used when buying (dai)
    /// @param permit the permit for dai to enable single transaction purchase
    /// @param bridge_cd calldata for bridging to gnosis chain
    function buy1(uint256 wad, uint256 max_collateral_spend, bytes calldata permit, bytes calldata bridge_cd) public {
        // 1. calculate the price to buy wad bzz and enforce slippage constraint
        uint256 collateralCost = bc.buyPrice(wad);
        require(collateralCost <= max_collateral_spend, "exchange/slippage");

        // at this point should consider if the length of cd is not zero, in which case we
        // assume that there is a permit signature, and will execute such.
        if (permit.length > 0) {
            // we assume that there is a permit signature here, decode as such
            (uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) =
                abi.decode(permit, (uint256, uint256, uint8, bytes32, bytes32));

            /// @dev dai permit is not eip-2612.
            DaiAbstract(address(dai)).permit(msg.sender, address(this), nonce, expiry, true, v, r, s);
        }
        // 2. transfer the dai from the user to this contract
        _move(dai, msg.sender, address(this), collateralCost);

        // 3. deduct our fees
        (wad, collateralCost) = (net(wad), net(collateralCost));

        // 4. mint and send logic
        if (bridge_cd.length == 0) {
            // no bridging data, therefore we are to just send to the user here on ethereum mainnet
            // use mintTo to save on a transfer
            bc.mintTo(wad, collateralCost, msg.sender);
        } else {
            bc.mint(wad, collateralCost);
            // there are two options here, depending on the calldata length
            // 1. if calldata is just an abi encoded address, then we send to an address on gnosis chain.
            //    this is handy if wanting to send direct to a bee node's wallet
            // 2. if calldata is longer than just an abi encoded address, we will relay tokens and provide
            //    callback data (allows for flexibility when sending to contracts on gnosis chain)
            if (bridge_cd.length == 32) {
                // relay direct to a wallet
                address dest = abi.decode(bridge_cd, (address));
                bridge.relayTokens(address(bzz), dest, wad);
            } else {
                (address dest, bytes memory cd) = abi.decode(bridge_cd, (address, bytes));
                bridge.relayTokensAndCall(address(bzz), dest, wad, cd);
            }
        }
    }

    /// Sell BZZ to the bonding curve in return for rewards (DAI)
    /// @dev This function assumes that the contract has already been authorised to spend msg.sender's bzz
    /// @param wad the amount of bzz to sell to the bonding curve
    /// @param min_collateral_receive the minimum amount of collateral we should get for selling wad (dai)
    function sell(uint256 wad, uint256 min_collateral_receive) public {
        // 1. calculate the reward for selling wad bzz and enforce slippage constraint
        uint256 collateralReward = bc.sellReward(wad);
        require(collateralReward >= min_collateral_receive, "exchange/slippage");

        // 2. transfer the bzz from the user to this contract
        _move(bzz, msg.sender, address(this), wad);

        // 3. redeem
        bc.redeem(wad, collateralReward);

        // 4. send the amount received to msg.sender after deducting any fee
        ERC20(address(dai)).safeTransfer(msg.sender, net(collateralReward));
    }

    /// Calculates the *net* amount that should be paid to msg.sender
    /// @param gross the gross amount in wei for consideration
    /// @return uint256 the gross amount less fees (fees specified in bps)
    function net(uint256 gross) internal view returns (uint256) {
        return (10000 - fee) * gross / 10000;
    }

    // --- helpers

    /// Route from dai <--> usdc/usdt using various liquidity pools
    /// @param lp the liquidity pool to use
    /// @param wad the amount of the stablecoin to exchange
    /// @param toDai if true, we are converting from stablecoin to dai, otherwise we are converting from dai to stablecoin
    /// @param gem the non-dai stablecoin address
    function _daiRouter(LiquidityProvider lp, uint256 wad, bool toDai, address gem) internal returns (uint256) {
        /// 1. route the stablecoin to / from dai using the appropriate router
        if (lp == LiquidityProvider.CURVE_FI_3POOL) {
            // if we are going to dai, move the stablecoin to this contract
            if (toDai) {
                // we are going to dai, so we need to transfer the stablecoin to this contract
                _move(ERC20(gem), msg.sender, address(this), wad);
            }
            return _curveFi3PoolRouter(wad, toDai, gem);
        } else if (lp == LiquidityProvider.UNISWAP_V3) {
            /// @dev we make use of callbacks here to avoid having to transfer the stablecoin to this contract
            return _uniswapV3Router(wad, toDai, gem);
        } else if (lp == LiquidityProvider.DAI_PSM && gem == address(usdc)) {
            // if we are going to dai, move the stablecoin to this contract
            if (toDai) {
                // we are going to dai, so we need to transfer the stablecoin to this contract
                _move(ERC20(gem), msg.sender, address(this), wad);
            }
            return _daiPsmRouter(wad, toDai);
        }
    }

    /// Curve fi 3pool routing
    /// @param wad the amount of the stablecoin to swap
    /// @param toDai whether we are going to dai or from dai
    /// @param gem the address of the stablecoin we are swapping to / from dai
    /// @return uint256 the amount of the destination coin received
    function _curveFi3PoolRouter(uint256 wad, bool toDai, address gem) internal returns (uint256) {
        // a. determine the non-dai coin index in the curve fi 3pool (1 = USDC, 2 = USDT)
        int128 nonDaiCoinIndex = gem == address(usdc) ? int128(1) : int128(2);
        // b. determine the i and j coin indices based on swap direction
        (int128 i, int128 j) = toDai ? (nonDaiCoinIndex, int128(0)) : (int128(0), nonDaiCoinIndex);

        // c. record the toCoin balance before the swap (and locally cache the addr)
        address toCoinAddr = toDai ? address(dai) : gem;
        uint256 toCoinBalanceBefore = _balance(toCoinAddr, address(this));

        // d. do the swap via the curve fi router
        /// @dev this is safe to set the minimum out to 0 as the bonding curve will revert if the
        ///      slippage is too high
        curveFi3Pool.exchange(i, j, wad, 0);

        // e. return the difference in balance
        return _balance(toCoinAddr, address(this)) - toCoinBalanceBefore;
    }

    /// Uniswap V3 routing for dai/usdc and dai/usdt pools
    /// @param wad the amount of the stablecoin to swap
    /// @param toDai true if we are going to dai, false if we are going from dai
    /// @param gem the address of the stablecoin we are swapping to / from dai
    /// @return uint256 the amount of the destination coin received
    function _uniswapV3Router(uint256 wad, bool toDai, address gem) internal returns (uint256) {
        // a. determine which pool we are using
        IUniswapV3Pool pool = gem == address(usdc) ? usdcV3Pool : usdtV3Pool;

        /// @dev we can use the knowledge that the dai is always the token0 in the
        ///      dai/usdc and dai/usdt pools to simplify the logic here

        // b. do the swap via the uniswap v3 router
        /// @dev if we are going to dai, we should be the recipient of the swap
        (int256 daiAmount, int256 usdcOrUsdtAmount) = pool.swap(
            toDai ? address(this) : msg.sender,
            !toDai,
            int256(wad), // amount of input token (dai, usdc/usdt)
            toDai ? MAX_SQRT_RATIO - 1 : MIN_SQRT_RATIO + 1,
            toDai ? abi.encodePacked(msg.sender) : bytes("")
        );

        // c. return the amount of the destination coin received
        return uint256(-(toDai ? daiAmount : usdcOrUsdtAmount));
    }

    /// DAI PSM router
    /// @notice the DAI PSM router only supports dai <--> usdc so no need for the gem param
    /// @dev this function will handle the routing of dai <--> usdc via the dai psm
    /// @param wad the amount of dai or usdc to exchange
    /// @param toDai true if we are going to dai, false if we are going from dai
    /// @return uint256 the amount of the destination coin received
    function _daiPsmRouter(uint256 wad, bool toDai) internal returns (uint256) {
        if (toDai) {
            // usdc --> dai
            psm.sellGem(address(this), wad);
        } else {
            // dai --> usdc
            psm.buyGem(address(this), wad);
        }
        return wad;
    }

    /// Move tokens from an address to another
    /// @param token the token to move
    /// @param from the address to move from
    /// @param to the address to move to
    /// @param amount the amount to move
    function _move(ERC20 token, address from, address to, uint256 amount) internal {
        token.safeTransferFrom(from, to, amount);
    }

    /// Move tokens to an address
    /// @param token the token to move
    /// @param to the address to move to
    /// @param amount the amount to move
    function _move(ERC20 token, address to, uint256 amount) internal {
        token.safeTransfer(to, amount);
    }

    /// Get the balance of a token for an address
    /// @param token the token to get the balance of
    /// @param addr the address to get the balance of
    /// @return uint256 the balance of the token for the address
    function _balance(address token, address addr) internal view returns (uint256) {
        return ERC20(token).balanceOf(addr);
    }

    /// Permit handler for dai and usdc
    /// @param _sc the stablecoin whose permit we are handling
    /// @param _pp the permit parameters
    /// @dev this function is used to handle the permit signatures for dai and usdc
    function _permit(Stablecoin _sc, PermitParams calldata _pp) internal {
        /// @dev we can use the same permit params layout for dai and usdc
        (uint256 nonceOrValue, uint256 expiryOrDeadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(_pp.data, (uint256, uint256, uint8, bytes32, bytes32));

        if (_sc == Stablecoin.DAI) {
            /// @dev dai permit is not eip-2612.
            DaiAbstract(address(dai)).permit(msg.sender, address(this), nonceOrValue, expiryOrDeadline, true, v, r, s);
        } else if (_sc == Stablecoin.USDC) {
            /// @dev usdc permit is eip-2612.            
            usdc.permit(msg.sender, address(this), nonceOrValue, expiryOrDeadline, v, r, s);
        } else {
            revert();
        }
    }

    /// --- callbacks

    /// Uniswap V3 swap callback to transfer tokens.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received
    ///                     (positive) by the pool by the end of the swap. If positive, the 
    ///                     callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received 
    ///                     (positive) by the pool by the end of the swap. If positive, the 
    ///                     callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call.
    ///             In this implementation, assumes that the pool key and a minimum receive amount
    ///             are passed via `data` to save on external calls.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        /// @dev make sure we are actually being called by a canonical pool. This is safe as the pools are immutable.
        require(msg.sender == address(usdcV3Pool) || msg.sender == address(usdtV3Pool), "exchange/u3-invalid-pool");

        /// @dev token transfers below don't need SignedMath as the values are always positive
        if (amount0Delta > 0) {
            // we need to send token0 to the pool (which is dai, and held by this contract)
            dai.safeTransfer(msg.sender, uint256(amount0Delta));
        } else {
            // we need to send token1 to the pool (which is usdc/usdt, and held by the caller, _who_)
            (address who) = abi.decode(data, (address));
            ERC20 token = ERC20(msg.sender == address(usdcV3Pool) ? address(usdc) : address(usdt));
            token.safeTransferFrom(who, msg.sender, uint256(amount1Delta));
        }
    }
}
