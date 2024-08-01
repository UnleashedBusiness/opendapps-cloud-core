// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {TaxableService} from "../commons/TaxableService.sol";
import {TreasuryBase} from "./TreasuryBase.sol";

    error InvalidInitializedState(uint256 state);
    error InvalidSharesValueError();
    error AccountIsZeroAddressError();
    error OperationsOnControllerNotPermitted();
    error AccountAlreadyHasShares(address account);
    error AccountDoesNotHaveShares(address account);
    error TokenAlreadyAddedAsRewardsError(address token);
    error TokenNotAddedAsRewardsError(address token);
    error InsufficientBalanceOfContract(address token, uint256 expected, uint256 actual);
    error EmptyTemplateError();

contract Treasury is TreasuryBase, TaxableService
{
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor() {
        _disableInitializers();
    }

    receive() payable virtual external {}

    function initialize(
        address _deployer, address pocketTemplate, address _controller, uint256 percentScaling,
        address[] calldata taxationReceivers, uint256[] calldata taxationReceiversPercent
    ) external initializer {
        __TaxableService_init(percentScaling, taxationReceivers, taxationReceiversPercent);

        __TreasuryBase__init(_deployer, pocketTemplate, _controller);
    }

    function PERCENT_SCALING() external view returns (uint256) {
        return _percentScaling() > 0 ? _percentScaling() : LEGACY_PERCENT_SCALING;
    }

    function totalTax() external view returns (uint256) {
        return _totalTaxLocal();
    }

    function taxation() external view returns (address[] memory, uint256[] memory) {
        address[] memory receivers = _taxationReceiversListInternal().values();
        uint256[] memory amounts = new uint256[](receivers.length);

        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = _taxationPercentsMapInternal()[receivers[i]];
        }

        return (receivers, amounts);
    }

    function _totalTaxLocal() internal override virtual view returns (uint256) {
        return _totalTaxationPercentInternal();
    }

    function _percentMaxLocal() internal override virtual view returns (uint256) {
        return _percentMax();
    }

    function _applyTaxationLocal(address token, uint256 amount) internal override virtual returns(uint256){
        return _applyTaxation(token, amount);
    }
}
