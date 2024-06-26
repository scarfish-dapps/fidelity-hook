// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {FidelityHook} from "../src/FidelityHook.sol";
import {FidelityTokenFactory} from "../src/FidelityHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SwapFeeLibrary} from "v4-core/src/libraries/SwapFeeLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ERC1155Holder} from "openzeppelin-contracts/token/ERC1155/utils/ERC1155Holder.sol";


contract FidelityHookTest is Test, Deployers, ERC1155Holder {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FidelityHook fidelityHook;
    PoolId poolId;
    address liqProvider = makeAddr("LP");

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(FidelityHook).creationCode,
            abi.encode(manager)
        );

        fidelityHook = new FidelityHook{salt: salt}(manager);

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            fidelityHook,
            SwapFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_RATIO_1_1,
            abi.encode(7 days, 2 ether, 1 ether, 10000, 2000)
        );

        IERC20Minimal(Currency.unwrap(currency0)).transfer(liqProvider, 0.6 ether);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(liqProvider, 0.3 ether);
        // Add some liquidity
        
        vm.startPrank(liqProvider);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(fidelityHook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(fidelityHook), type(uint256).max);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(manager), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(manager), type(uint256).max);

        fidelityHook.addLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether
            })
        );

        vm.stopPrank();
    }

    function test_PoolConfigInitialization() public {
        (
            uint256 interval,
            FidelityHook.Bound memory volThreshold,
            FidelityHook.Bound memory feeLimits,
            ,
        ) = fidelityHook.poolConfig(key.toId());

        assertEq(interval, 7 days);
        assertEq(volThreshold.upper, 2 ether);
        assertEq(volThreshold.lower, 1 ether);
        assertEq(feeLimits.upper, 10000);
        assertEq(feeLimits.lower, 2000);
    }

    function test_RemoveLiquidityWithFees() public {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolSwapTest.TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            }),
            abi.encode(address(this))
        );

        skip(7 days + 1);

        vm.startPrank(liqProvider);

        fidelityHook.removeLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -100 ether
            }),
            0
        );

        vm.stopPrank();

        uint128 liquidity = manager.getLiquidity(key.toId());

        assertEq(liquidity, 0);
    }

    function test_FidelityTokenMinting() public {
        (
            uint256 timeInterval,
            ,
            ,
            FidelityTokenFactory factory,
        ) = fidelityHook.poolConfig(key.toId());
       
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolSwapTest.TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            }),
            abi.encode(address(this))
        );

        
        assertEq(factory.balanceOf(address(this), 0), 0.001 ether);

        skip(timeInterval);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolSwapTest.TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            }),
            abi.encode(address(this))
        );

        assertEq(factory.balanceOf(address(this), 1), 0.1 ether);
    }

    function test_RecenterPosition() public {
        int24 tick;
         (, tick,,) = manager.getSlot0(key.toId());

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolSwapTest.TestSettings({
                withdrawTokens: true,
                settleUsingTransfer: true,
                currencyAlreadySent: false
            }),
            abi.encode(address(this))
        );

        (, tick,,) = manager.getSlot0(key.toId());

        vm.startPrank(liqProvider);

        fidelityHook.recenterPosition(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -100 ether
            }),
            0,
            0,
            120
        );

        vm.stopPrank();

        skip(7 days + 1);

        vm.startPrank(liqProvider);

        fidelityHook.removeLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: 0,
                tickUpper: 120,
                liquidityDelta: -100 ether
            }),
            0
        );

        vm.stopPrank();

        uint128 liquidity = manager.getLiquidity(key.toId());

        assertEq(liquidity, 0);
    }
}