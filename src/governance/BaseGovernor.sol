// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {IERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/IERC165Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {StringsUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";

import {GovernorInterface} from "@unleashed/opendapps-cloud-interfaces/governance/GovernorInterface.sol";

    error InsufficientBalance(uint256 expected, uint256 available);
    error InsufficientTransferValue(uint256 expected, uint256 available);

abstract contract BaseGovernor is GovernorInterface, Initializable, IERC165Upgradeable {
    bytes4 private constant _INTERFACE_ID_INVALID = 0xffffffff;

    using SafeMathUpgradeable for uint256;

    function __BaseGovernor_init() internal onlyInitializing {
        __BaseGovernor_init_unchained();
    }

    function __BaseGovernor_init_unchained() internal onlyInitializing {
    }

    function _executeCallInternal(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal virtual returns (bytes[] memory returnData)
    {
        string memory errorMessage = "Governor: call reverted without message";
        returnData = new bytes[](targets.length);
        uint256 valuesSum = 0;
        for (uint256 i = 0; i < targets.length; ++i) {
            valuesSum = valuesSum.add(values[i]);
            if (address(this).balance < values[i]) {
                revert InsufficientBalance(values[i], address(this).balance);
            }
            if (valuesSum > msg.value) {
                revert InsufficientTransferValue(valuesSum, msg.value);
            }

            (bool success, bytes memory returndata) = targets[i].call{value: values[i]}(calldatas[i]);
            AddressUpgradeable.verifyCallResult(success, returndata, errorMessage);
            returnData[i] = returndata;
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            (type(GovernorInterface).interfaceId == interfaceId || type(IERC165Upgradeable).interfaceId == interfaceId)
            && _INTERFACE_ID_INVALID != interfaceId;
    }
}