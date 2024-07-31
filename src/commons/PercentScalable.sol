// SPDX-License-Identifier: proprietary
pragma solidity ^0.8.7;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract PercentScalable is Initializable {
    uint256 private _percentScalingPrivate;

    function __PercentScalable_init(uint256 _percentScalingInit) internal onlyInitializing {
        _percentScalingPrivate = _percentScalingInit;
    }

    function _percentScaling() internal view returns (uint256) {
        return _percentScalingPrivate;
    }

    function _percentMax() internal view returns (uint256) {
        return 100 * _percentScaling();
    }

    function _getPercentOfValue(uint256 value, uint256 percentScaled) internal view returns (uint256) {
        return value * percentScaled / _percentMax();
    }
}
