// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "makerdao/dss/DaiAbstract.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";

import {Test} from "../lib/forge-std/src/Test.sol";
import {Exchange, BuyParams, SellParams, Stablecoin, LiquidityProvider} from "../src/Exchange.sol";
import {IForeignBridge} from "../src/interfaces/IForeignBridge.sol";
import {IBondingCurve} from "../src/interfaces/IBondingCurve.sol";

contract ExchangeTest is Test {
    using SafeTransferLib for ERC20;

    struct TestAccount {
        address addr;
        uint256 key;
    }

    Exchange public exchange;
    SigUtilsDAI public sigUtilsDai;
    SigUtilsEIP2612 public sigUtilsUsdc;

    // --- constants
    TestAccount alice;
    TestAccount owner;

    // --- main contracts
    IBondingCurve bc;
    IForeignBridge bridge;

    // --- token contracts
    ERC20 dai;
    ERC20 usdc;
    ERC20 usdt;
    ERC20 bzz;

    function setUp() public {
        // setup test accounts
        (address alice_, uint256 key) = makeAddrAndKey("alice");
        alice = TestAccount(alice_, key);
        (address owner_, uint256 key_) = makeAddrAndKey("owner");
        owner = TestAccount(owner_, key_);

        // deploy exchange
        exchange = new Exchange(
            owner.addr,
            0x4F32Ab778e85C4aD0CEad54f8f82F5Ee74d46904, // bonding curve
            0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7, // lp curve fi
            0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168, // lp uni3 dai usdc
            0x48DA0965ab2d2cbf1C17C09cFB5Cbe67Ad5B1406, // lp uni3 dai usdt
            0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A, // lp dai psm
            0x88ad09518695c6c3712AC10a214bE5109a655671, // bridge
            100 // max fee
        );

        // setup the bonding curve and bridge
        bc = IBondingCurve(exchange.bc());
        bridge = IForeignBridge(exchange.bridge());

        // setup the tokens
        dai = ERC20(bc.collateralToken());
        bzz = ERC20(bc.bondedToken());
        usdc = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        usdt = ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

        // deploy sigutils
        sigUtilsDai = new SigUtilsDAI(DaiAbstract(address(dai)).DOMAIN_SEPARATOR());
        sigUtilsUsdc = new SigUtilsEIP2612(usdc.DOMAIN_SEPARATOR());

        // give alice 10000 eth
        vm.deal(address(alice.addr), 10000 ether);
        deal(address(dai), address(exchange), 10000e18);
    }

    function testSetFee() public {
        vm.prank(alice.addr);
        vm.expectRevert("UNAUTHORIZED");
        exchange.setFee(50);

        vm.startPrank(owner.addr);

        // file a fee change
        exchange.setFee(50);
        assertEq(exchange.fee(), 50);

        // file a value that is too high
        vm.expectRevert(bytes("fee/too-high"));
        exchange.setFee(101);
        assertEq(exchange.fee(), 50);
    }

    function testSweep() public {
        vm.prank(alice.addr);
        vm.expectRevert("UNAUTHORIZED");
        exchange.sweep(dai, uint256(1000));

        vm.startPrank(owner.addr);

        // test sweeping erc20 tokens
        uint256 owner_balance = dai.balanceOf(owner.addr);
        uint256 exchange_balance = dai.balanceOf(address(exchange));
        exchange.sweep(dai, exchange_balance);

        assertEq(dai.balanceOf(owner.addr), owner_balance + exchange_balance);
        assertEq(dai.balanceOf(address(exchange)), 0);
    }

    function testRejectEth() public {
        vm.prank(alice.addr);
        vm.expectRevert();
        payable(address(exchange)).send(1 ether);
    }

    function testBuyNonPermitCurve3Pool() public {
        vm.startPrank(alice.addr);

        // give alice 10000 USDT
        deal(address(usdt), address(alice.addr), 10000e6);
        usdt.safeApprove(address(exchange), type(uint256).max);

        // test the buy with routing through curve3pool
        BuyParams memory params = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 10000e6,
            inputCoin: Stablecoin.USDT,
            lp: LiquidityProvider.CURVE_FI_3POOL,
            options: 0,
            data: ""
        });

        exchange.buy(params);
    }

    function testBuyNonPermitUniswapV3Pool() public {
        vm.startPrank(alice.addr);

        // give alice 10000 USDC
        deal(address(usdc), address(alice.addr), 10000e6);
        usdc.approve(address(exchange), type(uint256).max);

        // test the buy with routing through curve3pool
        BuyParams memory params = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 10000e6 * 10e12,
            inputCoin: Stablecoin.USDC,
            lp: LiquidityProvider.UNISWAP_V3,
            options: 0,
            data: ""
        });

        exchange.buy(params);
    }

    function testBuyNonPermitDaiPSM() public {
        vm.startPrank(alice.addr);

        // give alice 10000 USDC
        deal(address(usdc), address(alice.addr), 10000e6);
        usdc.approve(address(exchange), type(uint256).max);

        // test the buy with routing through dai psm
        BuyParams memory params = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 10000e6 * 10e12,
            inputCoin: Stablecoin.USDC,
            lp: LiquidityProvider.DAI_PSM,
            options: 0,
            data: ""
        });

        exchange.buy(params);
    }

    function testBuyNonPermit() public {
        vm.startPrank(alice.addr);

        // buy parameters
        BuyParams memory params = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE,
            options: 0,
            data: ""
        });

        // test balance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));

        exchange.buy(params);

        deal(address(dai), address(alice.addr), 10000e18);

        // test allowance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(params);

        dai.approve(address(exchange), type(uint256).max);

        // test the buy
        uint256 pre_alice_balance = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        exchange.buy(params);

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        // assertEq(bzz.balanceOf(alice.addr), pre_alice_balance + net(10 ether));
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testBuyAndBridge() public {
        vm.startPrank(alice.addr);

        // buy parameters
        BuyParams memory params = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE,
            options: 2,
            data: abi.encode(alice.addr)
        });

        deal(address(dai), address(alice.addr), 10000 ether);
        dai.approve(address(exchange), type(uint256).max);

        exchange.buy(params);
    }

    function testBuyAndBridgeToBatch() public {
        vm.startPrank(alice.addr);

        // buy parameters
        BuyParams memory params = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE,
            options: 2,
            data: abi.encode(alice.addr, abi.encode(bytes32("test"), uint256(1)))
        });

        deal(address(dai), address(alice.addr), 10000 ether);
        dai.approve(address(exchange), type(uint256).max);

        exchange.buy(params);
    }

    function testBuyAndBridgeToBatchWithPermit() public {
        vm.startPrank(alice.addr);

        // buy parameters
        BuyParams memory paramsSimple = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.USDC,
            lp: LiquidityProvider.UNISWAP_V3,
            options: 0,
            data: ""
        });

        // test balance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(paramsSimple);

        // give alice 10000 USDC
        deal(address(usdc), address(alice.addr), 10000e6);

        // test allowance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(paramsSimple);

        uint256 pre_alice_balance = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = usdc.balanceOf(address(exchange));

        SigUtilsEIP2612.Permit memory permit = SigUtilsEIP2612.Permit({
            owner: alice.addr,
            spender: address(exchange),
            value: type(uint256).max,
            nonce: 0,
            deadline: type(uint256).max
        });

        bytes32 digest = sigUtilsUsdc.getTypedDataHash(permit);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, digest);

        BuyParams memory paramsInvalidPermit = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.USDC,
            lp: LiquidityProvider.UNISWAP_V3,
            options: 3,
            data: abi.encode(
                abi.encode(type(uint256).max, type(uint256).max, v, s, r),
                abi.encode(alice.addr, abi.encode(bytes32("test"), uint256(1)))
                )
        });

        vm.expectRevert(bytes("ECRecover: invalid signature 's' value"));
        exchange.buy(paramsInvalidPermit);

        BuyParams memory paramsValidPermit = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.USDC,
            lp: LiquidityProvider.UNISWAP_V3,
            options: 3,
            data: abi.encode(
                abi.encode(type(uint256).max, type(uint256).max, v, r, s),
                abi.encode(alice.addr, abi.encode(bytes32("test"), uint256(1)))
                )
        });

        exchange.buy(paramsValidPermit);

        // assertEq(usdc.allowance(alice.addr, address(exchange)), type(uint256).max);
        assertEq(usdc.nonces(alice.addr), 1);
    }

    function testBuyPermit() public {
        vm.startPrank(alice.addr);

        // buy parameters
        BuyParams memory paramsSimple = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE,
            options: 0,
            data: ""
        });

        // test balance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(paramsSimple);

        deal(address(dai), address(alice.addr), 10000e18);

        // test allowance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.buy(paramsSimple);

        uint256 pre_alice_balance = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        SigUtilsDAI.Permit memory permit = SigUtilsDAI.Permit({
            holder: alice.addr,
            spender: address(exchange),
            nonce: 0,
            expiry: type(uint256).max,
            allowed: true
        });

        bytes32 digest = sigUtilsDai.getTypedDataHash(permit);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, digest);

        BuyParams memory paramsInvalidPermit = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE,
            options: 1,
            data: abi.encode(uint256(0), type(uint256).max, v, s, r)
        });

        vm.expectRevert(bytes("Dai/invalid-permit"));
        exchange.buy(paramsInvalidPermit);

        BuyParams memory paramsValidPermit = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: 1000 ether,
            inputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE,
            options: 1,
            data: abi.encode(uint256(0), type(uint256).max, v, r, s)
        });

        exchange.buy(paramsValidPermit);

        assertEq(dai.allowance(alice.addr, address(exchange)), type(uint256).max);
        assertEq(DaiAbstract(address(dai)).nonces(alice.addr), 1);

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        // assertEq(bzz.balanceOf(alice.addr), pre_alice_balance + net(10 ether));
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testSell() public {
        SellParams memory params = SellParams({
            bzzAmount: 1_000e16,
            minStablecoinAmount: 450e18,
            outputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE
        });

        // test approvals and balance checking
        vm.startPrank(alice.addr);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.sell(params);

        deal(address(bzz), address(alice.addr), 1000 ether);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.sell(params);

        bzz.approve(address(exchange), type(uint256).max);

        uint256 pre_alice_balance_dai = dai.balanceOf(alice.addr);
        uint256 pre_alice_balance_bzz = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        exchange.sell(params);

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        assertGt(dai.balanceOf(alice.addr), pre_alice_balance_dai);
        assertLt(bzz.balanceOf(alice.addr), pre_alice_balance_bzz);
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testSellCurveLPUsdt() public {
        SellParams memory params = SellParams({
            bzzAmount: 1_000e16,
            minStablecoinAmount: 450e6,
            outputCoin: Stablecoin.USDT,
            lp: LiquidityProvider.CURVE_FI_3POOL
        });

        vm.startPrank(alice.addr);
        deal(address(bzz), address(alice.addr), 1000 ether);
        bzz.approve(address(exchange), type(uint256).max);

        uint256 pre_alice_balance_usdt = usdt.balanceOf(alice.addr);
        uint256 pre_alice_balance_bzz = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        exchange.sell(params);

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        assertGt(usdt.balanceOf(alice.addr), pre_alice_balance_usdt);
        assertLt(bzz.balanceOf(alice.addr), pre_alice_balance_bzz);
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testSellUniswapUsdc() public {
        SellParams memory params = SellParams({
            bzzAmount: 1_000e16,
            minStablecoinAmount: 450e6,
            outputCoin: Stablecoin.USDC,
            lp: LiquidityProvider.UNISWAP_V3
        });

        vm.startPrank(alice.addr);
        deal(address(bzz), address(alice.addr), 1000 ether);
        bzz.approve(address(exchange), type(uint256).max);

        uint256 pre_alice_balance_usdc = usdc.balanceOf(alice.addr);
        uint256 pre_alice_balance_bzz = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        exchange.sell(params);

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        assertGt(usdc.balanceOf(alice.addr), pre_alice_balance_usdc);
        assertLt(bzz.balanceOf(alice.addr), pre_alice_balance_bzz);
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testSellDaiPSMUsdc() public {
        SellParams memory params = SellParams({
            bzzAmount: 1_000e16,
            minStablecoinAmount: 450e6,
            outputCoin: Stablecoin.USDC,
            lp: LiquidityProvider.DAI_PSM
        });

        vm.startPrank(alice.addr);
        deal(address(bzz), address(alice.addr), 1000 ether);
        bzz.approve(address(exchange), type(uint256).max);

        uint256 pre_alice_balance_usdc = usdc.balanceOf(alice.addr);
        uint256 pre_alice_balance_bzz = bzz.balanceOf(alice.addr);
        uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

        exchange.sell(params);

        /// @dev assert that alice gets the net amount and the exchange gets the fees
        assertGt(usdc.balanceOf(alice.addr), pre_alice_balance_usdc);
        assertLt(bzz.balanceOf(alice.addr), pre_alice_balance_bzz);
        assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
    }

    function testUniswapCallback() public {
        vm.startPrank(alice.addr);
        vm.expectRevert(bytes("exchange/u3-invalid-pool"));
        exchange.uniswapV3SwapCallback(0, 0, "");
    }

    function net(uint256 gross) internal view returns (uint256) {
        return (10000 - exchange.fee()) * gross / 10000;
    }

    function fee(uint256 gross) internal view returns (uint256) {
        return exchange.fee() * gross / 10000;
    }
}

contract SigUtilsEIP2612 {
    bytes32 internal DOMAIN_SEPARATOR;

    constructor(bytes32 _DOMAIN_SEPARATOR) {
        DOMAIN_SEPARATOR = _DOMAIN_SEPARATOR;
    }

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    struct Permit {
        address owner;
        address spender;
        uint256 value;
        uint256 nonce;
        uint256 deadline;
    }

    // computes the hash of a permit
    function getStructHash(Permit memory _permit) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(PERMIT_TYPEHASH, _permit.owner, _permit.spender, _permit.value, _permit.nonce, _permit.deadline)
        );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getTypedDataHash(Permit memory _permit) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, getStructHash(_permit)));
    }
}

contract SigUtilsDAI {
    bytes32 internal DOMAIN_SEPARATOR;

    constructor(bytes32 _DOMAIN_SEPARATOR) {
        DOMAIN_SEPARATOR = _DOMAIN_SEPARATOR;
    }

    // bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");
    bytes32 public constant PERMIT_TYPEHASH = 0xea2aa0a1be11a07ed86d755c93467f4f82362b452371d1ba94d1715123511acb;

    struct Permit {
        address holder;
        address spender;
        uint256 nonce;
        uint256 expiry;
        bool allowed;
    }

    // computes the hash of a permit
    function getStructHash(Permit memory _permit) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(PERMIT_TYPEHASH, _permit.holder, _permit.spender, _permit.nonce, _permit.expiry, _permit.allowed)
        );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getTypedDataHash(Permit memory _permit) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, getStructHash(_permit)));
    }
}
