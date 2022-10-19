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
        // deal(address(dai), address(exchange), 10000e18);
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

    function helperBuy(Stablecoin inputCoin, LiquidityProvider lp, uint256 options, bytes memory cd) internal {
        // Snapshot the current state of the evm.
        uint256 snapshotId = vm.snapshot();

        vm.startPrank(alice.addr);

        // give alice 10000 of the input coin
        address inputCoinAddr;
        if (inputCoin == Stablecoin.DAI) {
            inputCoinAddr = address(dai);
        } else if (inputCoin == Stablecoin.USDC) {
            inputCoinAddr = address(usdc);
        } else if (inputCoin == Stablecoin.USDT) {
            inputCoinAddr = address(usdt);
        }
        uint256 inputCoinAmount = inputCoin != Stablecoin.DAI ? 10000e6 : 10000e18;

        // build the buy params
        BuyParams memory params = BuyParams({
            bzzAmount: 10 ether,
            maxStablecoinAmount: inputCoinAmount,
            inputCoin: inputCoin,
            lp: lp,
            options: options,
            data: cd
        });

        bytes memory permitData;

        // split out all the optional data
        if (options == 1) {
            permitData = cd;
        } else if (options == 3) {
            (permitData, ) = abi.decode(cd, (bytes, bytes));
        }

        // test balance requirements
        if (inputCoin == Stablecoin.USDT && permitData.length > 0) {
            vm.expectRevert();
            exchange.buy(params);
        } else if (inputCoin == Stablecoin.USDT && lp == LiquidityProvider.DAI_PSM) {
            vm.expectRevert(bytes("exchange/psm-usdc-only"));
            exchange.buy(params);
        } else if (inputCoin != Stablecoin.DAI && lp == LiquidityProvider.NONE) {
            vm.expectRevert(bytes("exchange/invalid-lp"));
            exchange.buy(params);
        } else {
            vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));

            exchange.buy(params);

            deal(address(inputCoinAddr), address(alice.addr), inputCoinAmount);

            // allowance testing (permit and no permit)
            if (permitData.length == 0) {
                // test allowance requirements (only if no permit)
                vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
                exchange.buy(params);
    
                // give allowance to the exchange (if no permitData is specified)
                ERC20(inputCoinAddr).safeApprove(address(exchange), type(uint256).max);
            } else {
                // test the transaction without a permit
                BuyParams memory paramsNoPermit = BuyParams({
                    bzzAmount: 10 ether,
                    maxStablecoinAmount: inputCoinAmount,
                    inputCoin: inputCoin,
                    lp: lp,
                    options: 1,
                    data: bytes("rubbish permit")
                });
                vm.expectRevert(bytes(""));
                exchange.buy(paramsNoPermit);
            }

            // test the buy
            uint256 pre_alice_balance = bzz.balanceOf(alice.addr);
            uint256 pre_exchange_balance = ERC20(inputCoinAddr).balanceOf(address(exchange));

            exchange.buy(params);

            /// @dev assert that alice gets the net amount and the exchange gets the fees
            // assertEq(bzz.balanceOf(alice.addr), pre_alice_balance + net(10 ether));
            assertGt(dai.balanceOf(address(exchange)), pre_exchange_balance);
        }

        vm.stopPrank();

        // revert to the snapshot
        vm.revertTo(snapshotId);
    }

    function testBuyNonPermitPermutations() public {
        // iterate through stablecoins
        for (uint256 i = 0; i < 3; i++) {
            // iterate through liquidity providers except NONE
            for (uint256 j = 0; j < 4; j++) {
                // first test simple buying
                helperBuy(Stablecoin(i), LiquidityProvider(j), 0, bytes(""));
            }
        }
    }

    function testBuyNonPermitBridgePermutations() public {
        // iterate through stablecoins
        for (uint256 i = 0; i < 3; i++) {
            // iterate through liquidity providers
            for (uint256 j = 0; j < 4; j++) {
                // next test with just bridging (a. EOA only)
                helperBuy(Stablecoin(i), LiquidityProvider(j), 2, abi.encode(alice.addr));
                // next test with just bridging (to a destination contract)
                bytes memory other = bytes("this is just some data");
                helperBuy(Stablecoin(i), LiquidityProvider(j), 2, abi.encode(alice.addr, other));
            }
        }
    }

    function testBuyPermitPermutations() public {
        // iterate through stablecoins
        for (uint256 i = 0; i < 3; i++) {
            // iterate through liquidity providers
            for (uint256 j = 0; j < 4; j++) {
                bytes memory permitData;
                if (i == 0) {
                    SigUtilsDAI.Permit memory permit = SigUtilsDAI.Permit({
                        holder: alice.addr,
                        spender: address(exchange),
                        nonce: 0,
                        expiry: type(uint256).max,
                        allowed: true
                    });

                    bytes32 digest = sigUtilsDai.getTypedDataHash(permit);

                    (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, digest);

                    permitData = abi.encode(uint256(0), type(uint256).max, v, r, s);
                } else if (i == 1) {
                    SigUtilsEIP2612.Permit memory permit = SigUtilsEIP2612.Permit({
                        owner: alice.addr,
                        spender: address(exchange),
                        value: type(uint256).max,
                        nonce: 0,
                        deadline: type(uint256).max
                    });

                    bytes32 digest = sigUtilsUsdc.getTypedDataHash(permit);

                    (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, digest);
                    permitData = abi.encode(type(uint256).max, type(uint256).max, v, r, s);
                } else if (i == 2) {
                    permitData = abi.encode(string("this is random data"));
                }

                // first test with just permit
                helperBuy(Stablecoin(i), LiquidityProvider(j), 1, permitData);
                // next test with permit and bridging to an EOA
                helperBuy(Stablecoin(i), LiquidityProvider(j), 3, abi.encode(permitData, abi.encode(alice.addr)));
                // next test with permit and bridging to a contract
                helperBuy(Stablecoin(i), LiquidityProvider(j), 3, abi.encode(permitData, abi.encode(alice.addr, bytes("test"))));
            }
        }
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
