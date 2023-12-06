// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IWETH} from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";

    error AmountRequestedIsMoreThanAvailable();
    error TaxSizeOverflow();

library LiquidityUtils {
    using SafeMathUpgradeable for uint256;

    function getOrCreatePair(address token, address weth, address router) public returns (address pair) {
        address factoryAddr = IUniswapV2Router02(router).factory();

        pair = IUniswapV2Factory(factoryAddr).getPair(token, weth);
        if (pair != address(0)) {
            return pair;
        }
        IUniswapV2Factory(factoryAddr).createPair(token, weth);
        return IUniswapV2Factory(factoryAddr).getPair(token, weth);
    }

    function addToLiquidity(address token, address wethAddress, uint256 tokenAmount,
        uint256 nativeAmount, address router, address owner, uint256 expectedTax) public {
        if (tokenAmount == 0 || nativeAmount == 0)
            return;

        if (nativeAmount > address(this).balance) {
            revert AmountRequestedIsMoreThanAvailable();
        }

        if (expectedTax > 100) {
            revert TaxSizeOverflow();
        }

        getOrCreatePair(token, wethAddress, router);
        IWETH(wethAddress).deposit{value: nativeAmount}();
        IERC20Upgradeable(token).approve(router, tokenAmount);
        IERC20Upgradeable(wethAddress).approve(router, nativeAmount);

        uint256 tokenSlippage = 100 - expectedTax;
        if (tokenSlippage > 2) {
            tokenSlippage = tokenSlippage.sub(2); // 2% slippage
        }

        uint256 expectedMinToken = tokenAmount.mul(tokenSlippage).div(100);
        uint256 expectedNative = nativeAmount.mul(98).div(100);

        IUniswapV2Router02(router).addLiquidity(
            wethAddress,
            token,
            nativeAmount,
            tokenAmount,
            expectedNative,
            expectedMinToken,
            owner,
            block.timestamp
        );
    }

    function removeLiquidity(address token, address wethAddress, uint256 liquidityAmount,
        address router, address owner, uint256 expectedTax
    ) public {
        if (liquidityAmount == 0)
            return;
        if (expectedTax > 100) {
            revert TaxSizeOverflow();
        }

        address pair = getOrCreatePair(token, wethAddress, router);
        if (liquidityAmount > IERC20Upgradeable(pair).balanceOf(address(this))) {
            revert AmountRequestedIsMoreThanAvailable();
        }

        IERC20Upgradeable(pair).approve(router, liquidityAmount);
        uint256 removeRation = liquidityAmount
            .div(IERC20Upgradeable(pair).totalSupply());

        uint256 tokenSlippage = 100 - expectedTax;
        if (tokenSlippage > 2) {
            tokenSlippage = tokenSlippage.sub(2); // 2% slippage
        }

        uint256 expectedMinToken = IERC20Upgradeable(token).balanceOf(pair)
            .mul(removeRation)
            .mul(tokenSlippage)
            .div(10000);
        uint256 expectedNative = IERC20Upgradeable(wethAddress).balanceOf(pair)
            .mul(removeRation)
            .mul(98) // 2% slippage
            .div(10000);

        uint256 amountETH = 0;
        (, amountETH) = IUniswapV2Router02(router).removeLiquidity(
            wethAddress,
            token,
            liquidityAmount,
            expectedNative,
            expectedMinToken,
            owner,
            block.timestamp
        );
        IWETH(wethAddress).withdraw(amountETH);
    }
}
