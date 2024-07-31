// SPDX-License-Identifier: proprietary
pragma solidity ^0.8.7;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PercentScalable} from "./PercentScalable.sol";
import {AssetTransferLibrary} from "../lib/AssetTransferLibrary.sol";

    error TaxationReceiversAddressAndPercentsLengthDifference(uint256 receiversCount, uint256 percentsCount);

contract TaxableService is Initializable, PercentScalable {
    EnumerableSet.AddressSet private _taxationReceiversList;
    mapping(address => uint256) private _taxationPercentsMap;
    uint256 private totalTaxationPercent;

    using EnumerableSet for EnumerableSet.AddressSet;

    function __TaxableService_init(uint256 _percentScalingInit, address[] calldata taxationReceivers, uint256[] calldata taxationReceiversPercent) internal onlyInitializing {
        __PercentScalable_init(_percentScalingInit);
        __TaxableService_init_unchained(taxationReceivers, taxationReceiversPercent);
    }

    function __TaxableService_init_unchained(address[] calldata taxationReceivers, uint256[] calldata taxationReceiversPercent) internal onlyInitializing {
        if (taxationReceivers.length != taxationReceiversPercent.length) {
            revert TaxationReceiversAddressAndPercentsLengthDifference(taxationReceivers.length, taxationReceiversPercent.length);
        }

        for (uint256 i = 0; i < taxationReceivers.length; i++) {
            _taxationReceiversList.add(taxationReceivers[i]);
            _taxationPercentsMap[taxationReceivers[i]] = taxationReceiversPercent[i];

            totalTaxationPercent += taxationReceiversPercent[i];
        }
    }

    function _applyTaxation(address token, uint256 taxableAmount) internal returns (uint256) {
        uint256 totalTax = totalTaxationPercent;
        uint256 fee = taxableAmount * totalTax / _percentMax();
        uint256 remaining = fee;
        for (uint256 k = 0; k < _taxationReceiversList.length(); k++) {
            address receiver = _taxationReceiversList.at(k);
            uint256 taxationAmount = fee * _taxationPercentsMap[receiver] / totalTax;

            if (taxationAmount > remaining) {
                taxationAmount = remaining;
            }
            remaining -= taxationAmount;

            AssetTransferLibrary.transferAsset(token, receiver, taxationAmount);
        }

        return taxableAmount - fee;
    }

    function _totalTaxationPercentInternal() internal view returns (uint256) {
        return totalTaxationPercent;
    }

    function _taxationReceiversListInternal() internal view returns (EnumerableSet.AddressSet storage) {
        return _taxationReceiversList;
    }

    function _taxationPercentsMapInternal() internal view returns (mapping(address => uint256) storage) {
        return _taxationPercentsMap;
    }

    uint256[50] private __gap;
}