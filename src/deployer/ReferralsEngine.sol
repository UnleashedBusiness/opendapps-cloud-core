// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";

import {IReferralsEngine} from "@unleashed/opendapps-cloud-interfaces/deployer/IReferralsEngine.sol";

    error RefCodeAlreadyExistError(bytes32 refCode);
    error RefCodeOperationNotPermitted(bytes32 refCode, address sender);
    error EmptyAddressError();
    error EmptyRefCodeError();
    error InvalidCompensationPercent(uint256 percent);

contract ReferralsEngine is IReferralsEngine, Initializable, ERC165Upgradeable, AccessControlUpgradeable {

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");

    uint256 public defaultPercent;

    mapping(bytes32 => address) internal receivers;
    mapping(bytes32 => uint256) internal compensations;
    mapping(bytes32 => bool) internal blacklist;

    using SafeMathUpgradeable for uint256;

    constructor() {}

    function initialize(uint256 _defaultPercent) external initializer {
        if (_defaultPercent <= 0 || _defaultPercent > 100) {
            revert InvalidCompensationPercent(_defaultPercent);
        }

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        defaultPercent = _defaultPercent;
    }

    function supportsInterface(bytes4 interfaceId) public override(AccessControlUpgradeable, ERC165Upgradeable) view returns (bool) {
        return interfaceId == type(IReferralsEngine).interfaceId
            || AccessControlUpgradeable.supportsInterface(interfaceId)
            || ERC165Upgradeable.supportsInterface(interfaceId);
    }

    function getCompensationPercent(bytes32 refCode) public view returns (uint256 percent, address receiver) {
        receiver = receivers[refCode];
        percent = 0;

        if (receiver != address(0)) {
            percent = _getPercentInternal(refCode);
        }
    }

    function calculateCompensationSize(bytes32 refCode, uint256 amount) external view returns (uint256 compensationValue, uint256 remaining) {
        uint256 percent = 0;
        (percent,) = getCompensationPercent(refCode);

        if (percent == 0) {
            compensationValue = 0;
            remaining = amount;
        } else {
            compensationValue = amount.mul(percent).div(100);
            remaining = amount - compensationValue;
        }
    }

    function assignRefCodeToSelf(bytes32 refCode) external {
        if (refCode == bytes32('')) {
            revert EmptyRefCodeError();
        }
        if (receivers[refCode] != address(0)) {
            revert RefCodeAlreadyExistError(refCode);
        }

        _enableCustomRefCodeForAddress(refCode, msg.sender, 0);
    }

    function assignRefCodeToAddress(bytes32 refCode, address receiver) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (refCode == bytes32('')) {
            revert EmptyRefCodeError();
        }
        if (receiver == address(0)) {
            revert EmptyAddressError();
        }
        if (receivers[refCode] != address(0)) {
            revert RefCodeAlreadyExistError(refCode);
        }

        _enableCustomRefCodeForAddress(refCode, receiver, 0);
    }

    function assignRefCodeToAddressWithCustomSize(bytes32 refCode, address receiver, uint256 customSize) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (refCode == bytes32('')) {
            revert EmptyRefCodeError();
        }
        if (receiver == address(0)) {
            revert EmptyAddressError();
        }
        if (receivers[refCode] != address(0) && receiver != receivers[refCode]) {
            revert RefCodeAlreadyExistError(refCode);
        }
        if (customSize < 0 || customSize > 100) {
            revert InvalidCompensationPercent(customSize);
        }

        _enableCustomRefCodeForAddress(refCode, receiver, customSize);
    }

    function disableRefCode(bytes32 refCode) external {
        if (refCode == bytes32('')) {
            revert EmptyRefCodeError();
        }
        if (!hasRole(LOCAL_MANAGER_ROLE, msg.sender) && receivers[refCode] != msg.sender) {
            revert RefCodeOperationNotPermitted(refCode, msg.sender);
        }

        _disableRefCode(refCode);
    }

    function _getPercentInternal(bytes32 refCode) internal view returns (uint256) {
        uint256 percent = compensations[refCode];
        if (percent == 0) {
            percent = defaultPercent;
        }

        return percent;
    }

    function _enableCustomRefCodeForAddress(bytes32 refCode, address receiver, uint256 percent) internal {
        receivers[refCode] = receiver;
        compensations[refCode] = percent;
    }

    function _disableRefCode(bytes32 refCode) internal {
        receivers[refCode] = address(0);
        compensations[refCode] = 0;
    }
}
