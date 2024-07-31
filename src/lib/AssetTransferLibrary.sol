// SPDX-License-Identifier: proprietary
pragma solidity ^0.8.7;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

    error InsufficientBalanceError(address token, uint256 expected, uint256 actual);
    error InsufficientAmountError(address token, uint256 expected, uint256 actual);

library AssetTransferLibrary {
    function transferAsset(address token, address receipt, uint256 amount) public {
        if (token == address(0)) {
            if (address(this).balance < amount) {
                revert InsufficientBalanceError(address(0), amount, address(this).balance);
            }

            Address.sendValue(payable(receipt), amount);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < amount) {
                revert InsufficientBalanceError(token, amount, balance);
            }

            SafeERC20.safeTransfer(IERC20(token), receipt, amount);
        }
    }

    function depositAsset(address token, address from, uint256 amount) public {
        if (token == address(0)) {
            if (amount != msg.value) {
                revert InsufficientAmountError(address(0), amount, msg.value);
            }
        } else {
            uint256 allowance = IERC20(token).allowance(from, address(this));
            if (allowance < amount) {
                revert InsufficientAmountError(token, amount, allowance);
            }

            SafeERC20.safeTransferFrom(IERC20(token), from, address(this), amount);
        }
    }
}
