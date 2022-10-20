// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "makerdao/dss/DaiAbstract.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";

import {Test} from "../lib/forge-std/src/Test.sol";
import {Exchange, BuyParams, SellParams, Stablecoin, LiquidityProvider} from "../src/Exchange.sol";
import {IForeignBridge} from "../src/interfaces/IForeignBridge.sol";
import {IBondingCurve} from "../src/interfaces/IBondingCurve.sol";

uint256 constant BZZ_AMOUNT = 1_000e16; // 1000 BZZ
uint256 constant FEE_BPS = 100;

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
    TestAccount bob;
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
        (address bob_, uint256 bobkey) = makeAddrAndKey("bob");
        bob = TestAccount(bob_, bobkey);
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
            FEE_BPS // max fee
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

    // --- owner function tests (all must test auth)

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

    // --- save users from accidentally sending eth to the exchange

    function testRejectEth() public {
        vm.prank(alice.addr);
        vm.expectRevert();
        payable(address(exchange)).send(1 ether);
    }

    // --- protect uniswap callback to avoid abuse (only allow authorized pools)

    function testUniswapCallback() public {
        vm.startPrank(alice.addr);
        vm.expectRevert(bytes("exchange/u3-invalid-pool"));
        exchange.uniswapV3SwapCallback(0, 0, "");
    }

    // --- slippage tests

    function testSlippageBuy() public {
        BuyParams memory bobParams = BuyParams({
            bzzAmount: 200_000e16,
            maxStablecoinAmount: 500_000e18,
            inputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE,
            options: 0,
            data: ""
        });
        
        BuyParams memory aliceParams = BuyParams({
            bzzAmount: 19_000e16,
            maxStablecoinAmount: 10_000e18,
            inputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE,
            options: 0,
            data: ""
        });

        // alice and bob approve the exchange for their dai tokens
        vm.prank(alice.addr);
        dai.approve(address(exchange), type(uint256).max);
        vm.prank(bob.addr);
        dai.approve(address(exchange), type(uint256).max);

        // give alice and bob a million dai
        deal(address(dai), address(alice.addr), 1_000_000e18);
        deal(address(dai), address(bob.addr), 1_000_000e18);

        uint256 snapshotId = vm.snapshot();

        // make sure that alice can normally buy (in case of change of rate from when the test was written)
        vm.prank(alice.addr);
        exchange.buy(aliceParams);

        // revert to previous snapshot
        vm.revertTo(snapshotId);

        // bob buys to sandwich alice
        vm.prank(bob.addr);
        exchange.buy(bobParams);

        // alice buys
        vm.prank(alice.addr);
        vm.expectRevert(bytes("exchange/slippage"));
        exchange.buy(aliceParams);
    }

    function testSlippageSell() public {
        
        SellParams memory bobParams = SellParams({
            bzzAmount: 200_000e16,
            minStablecoinAmount: 1e18,
            outputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE
        });
        
        SellParams memory aliceParams = SellParams({
            bzzAmount: 19_000e16,
            minStablecoinAmount: 9_000e18,
            outputCoin: Stablecoin.DAI,
            lp: LiquidityProvider.NONE
        });

        // alice and bob approve the exchange for their bzz tokens
        vm.prank(alice.addr);
        bzz.approve(address(exchange), type(uint256).max);
        vm.prank(bob.addr);
        bzz.approve(address(exchange), type(uint256).max);

        // give alice and bob a million bzz
        deal(address(bzz), address(alice.addr), 1_000_000e16);
        deal(address(bzz), address(bob.addr), 1_000_000e16);

        uint256 snapshotId = vm.snapshot();

        // make sure that alice can normally sell (in case of change of rate from when the test was written)
        vm.prank(alice.addr);
        exchange.sell(aliceParams);

        // revert to previous snapshot
        vm.revertTo(snapshotId);

        // bob sells to sandwich alice
        vm.prank(bob.addr);
        exchange.sell(bobParams);

        // alice sells
        vm.prank(alice.addr);
        vm.expectRevert(bytes("exchange/slippage"));
        exchange.sell(aliceParams);
    }

    // --- buying tests

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

        // calculate the fee amount
        uint256 feeAmount = bc.buyPrice(BZZ_AMOUNT) * FEE_BPS / 10000;
        uint256 feeAmountDelta = feeAmount * 10002 / 10000;

        // calculate the maximum amount of the stablecoin that should be taken
        uint256 maxInputCoinAmount = (bc.buyPrice(BZZ_AMOUNT) * 10002 / 10000 / (inputCoin != Stablecoin.DAI ? 1e12 : 1)) 
            + feeAmount;

        // build the buy params
        BuyParams memory params = BuyParams({
            bzzAmount: BZZ_AMOUNT,
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
            (permitData,) = abi.decode(cd, (bytes, bytes));
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
                    bzzAmount: BZZ_AMOUNT,
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
            address destAddress = (options < 2 ? address(alice.addr) : address(bridge));
            uint256 pre_dest_balance = bzz.balanceOf(destAddress);
            uint256 exchange_balance_dai = dai.balanceOf(address(exchange));
            uint256 pre_alice_balance_sc = ERC20(inputCoinAddr).balanceOf(address(alice.addr));

            exchange.buy(params);

            // make sure that the exchange retains the fee
            assertApproxEqAbs(
                dai.balanceOf(address(exchange)) - exchange_balance_dai,
                feeAmount,
                feeAmountDelta
            );

            // make sure that the user / bridge received the correct amount of bzz
            assertEq(bzz.balanceOf(destAddress), pre_dest_balance + BZZ_AMOUNT);

            // make sure that the exchange never receives any usdt or usdc
            assertEq(usdt.balanceOf(address(exchange)), 0);
            assertEq(usdc.balanceOf(address(exchange)), 0);

            // make sure that the cost is less than the max
            assertLe(
                pre_alice_balance_sc - ERC20(inputCoinAddr).balanceOf(address(alice.addr)),
                maxInputCoinAmount
            );
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
                helperBuy(
                    Stablecoin(i),
                    LiquidityProvider(j),
                    3,
                    abi.encode(permitData, abi.encode(alice.addr, bytes("test")))
                );
            }
        }
    }

    // --- selling tests

    function helperSell(Stablecoin outputCoin, LiquidityProvider lp) internal {
        // take a snapshot
        uint256 snapshotId = vm.snapshot();

        // calculate the fee amount
        uint256 feeAmount = bc.sellReward(BZZ_AMOUNT) * FEE_BPS / 10000;
        uint256 feeAmountDelta = feeAmount * 10002 / 10000;

        // calculate the minimum amount of output coin that the user should receive
        uint256 minOutputCoinAmount = (bc.sellReward(BZZ_AMOUNT) - feeAmount) * 9998 / 10000 / (outputCoin != Stablecoin.DAI ? 10e12 : 1);

        vm.startPrank(alice.addr);

        // configure the output parameters
        address outputCoinAddr;
        if (outputCoin == Stablecoin.DAI) {
            outputCoinAddr = address(dai);
        } else if (outputCoin == Stablecoin.USDC) {
            outputCoinAddr = address(usdc);
        } else if (outputCoin == Stablecoin.USDT) {
            outputCoinAddr = address(usdt);
        }
        uint256 outputCoinAmount = outputCoin != Stablecoin.DAI ? 450e6 : 450e18;

        // set up the params
        SellParams memory params = SellParams({
            bzzAmount: BZZ_AMOUNT,
            minStablecoinAmount: outputCoinAmount,
            outputCoin: outputCoin,
            lp: lp
        });

        // test balance requirements
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.sell(params);

        // give alice some bzz
        deal(address(bzz), address(alice.addr), BZZ_AMOUNT);

        // should fail because no allowance set for the exchange
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        exchange.sell(params);

        // give allowance to the exchange (if no permitData is specified)
        bzz.safeApprove(address(exchange), type(uint256).max);

        if (outputCoin == Stablecoin.USDT && lp == LiquidityProvider.DAI_PSM) {
            vm.expectRevert(bytes("exchange/psm-usdc-only"));
            exchange.sell(params);
        } else if (outputCoin != Stablecoin.DAI && lp == LiquidityProvider.NONE) {
            vm.expectRevert(bytes("exchange/invalid-lp"));
            exchange.sell(params);
        } else {
            // test the sell
            uint256 pre_alice_balance = bzz.balanceOf(alice.addr);
            uint256 pre_alice_balance_sc = ERC20(outputCoinAddr).balanceOf(alice.addr);
            uint256 pre_exchange_balance = dai.balanceOf(address(exchange));

            exchange.sell(params);

            // make sure that the exchange has received the fee
            assertApproxEqAbs(
                dai.balanceOf(address(exchange)), 
                pre_exchange_balance + feeAmount,
                feeAmountDelta
            );

            // alice's bzz balance should reduce by the traded amount
            assertEq(bzz.balanceOf(alice.addr), pre_alice_balance - BZZ_AMOUNT);

            // alice should have received a minimum
            assertGe(ERC20(outputCoinAddr).balanceOf(alice.addr), pre_alice_balance_sc + minOutputCoinAmount);
        }

        // make sure that the exchange never receives any usdt or usdc
        assertEq(usdt.balanceOf(address(exchange)), 0);
        assertEq(usdc.balanceOf(address(exchange)), 0);

        vm.stopPrank();

        // revert to the snapshot
        vm.revertTo(snapshotId);
    }

    function testSell() public {
        // iterate through stablecoins
        for (uint256 i = 0; i < 3; i++) {
            // iterate through liquidity providers except NONE
            for (uint256 j = 0; j < 4; j++) {
                // test simple selling
                helperSell(Stablecoin(i), LiquidityProvider(j));
            }
        }
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
