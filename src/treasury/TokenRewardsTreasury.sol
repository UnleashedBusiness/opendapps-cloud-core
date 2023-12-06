// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ITokenRewardsTreasury} from "@unleashed/opendapps-cloud-interfaces/treasury/ITokenRewardsTreasury.sol";
import {SecondaryServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/SecondaryServiceDeployableInterface.sol";

    error InvalidSharesValueError();
    error AccountIsZeroAddressError();
    error OperationsOnControllerNotPermitted();
    error AccountAlreadyHasShares(address account);
    error AccountDoesNotHaveShares(address account);
    error TokenAlreadyAddedAsRewardsError(address token);
    error TokenNotAddedAsRewardsError(address token);
    error InsufficientBalanceOfContract(address token, uint256 expected, uint256 actual);

contract TokenRewardsTreasury is ITokenRewardsTreasury, SecondaryServiceDeployableInterface,
Initializable, ERC165Upgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    uint256[50] private _gap;

    mapping(address => uint256) private availableMap;
    mapping(address => uint256) private percents;
    mapping(address => mapping(address => uint256)) private released;
    mapping(address => mapping(address => uint256)) private pending;

    address public controller;
    EnumerableSetUpgradeable.AddressSet private payees;
    EnumerableSetUpgradeable.AddressSet private rewardTokensCache;
    mapping(address => uint256) public lastTokenHolding;

    constructor() {
        _disableInitializers();
    }

    receive() payable virtual external {
        //TODO: CHECK
        addToAvailable(address(0));
    }

    modifier onlyValidShares(address account, uint256 shares) {
        if (shares <= 0 || percents[controller].add(percents[account]) < shares) {
            revert InvalidSharesValueError();
        }
        _;
    }

    function initialize(address _controller) external initializer {
        __ReentrancyGuard_init_unchained();
        __Ownable_init_unchained();

        controller = _controller;
        percents[_controller] = 100_0;
        //100.0 %
        payees.add(_controller);

        rewardTokensCache.add(address(0));
    }

    function masterDeployable() external view returns (address) {
        return controller;
    }

    function supportsInterface(bytes4 interfaceId) public virtual override(ERC165Upgradeable) view returns (bool) {
        return
        interfaceId == type(ITokenRewardsTreasury).interfaceId ||
        interfaceId == type(SecondaryServiceDeployableInterface).interfaceId ||
        ERC165Upgradeable.supportsInterface(interfaceId);
    }

    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokensCache.values();
    }

    function getPayees() external view returns (address[] memory) {
        return payees.values();
    }

    function payeePercent(address account) external view returns (uint256) {
        return percents[account];
    }

    function getController() external view returns (address) {
        return controller;
    }

    function available(address token) external view returns (uint256){
        uint256 diff = token == address(0)
        ? payable(address(this)).balance.sub(lastTokenHolding[token])
        : IERC20Upgradeable(token).balanceOf(address(this)).sub(lastTokenHolding[token]);

        return availableMap[token].add(diff);
    }

    function totalPendingPayment(address account, address token) external view returns (uint256) {
        return pendingPayment(account, token);
    }

    function addRewardToken(address token) external onlyOwner {
        if (rewardTokensCache.contains(token)) {
            revert TokenAlreadyAddedAsRewardsError(token);
        }
        addToAvailable(token);

        rewardTokensCache.add(token);
    }

    function removeRewardToken(address token) external onlyOwner {
        if (!rewardTokensCache.contains(token)) {
            revert TokenNotAddedAsRewardsError(token);
        }
        addToAvailable(token);

        rewardTokensCache.remove(token);
    }

    function addPayee(address account, uint256 shares) external onlyValidShares(account, shares) onlyOwner {
        if (account == address(0)) {
            revert AccountIsZeroAddressError();
        }
        if (percents[account] != 0) {
            revert AccountAlreadyHasShares(account);
        }

        resetShareValues();

        payees.add(account);
        percents[account] = shares;
        percents[controller] = percents[controller].sub(shares);
    }

    function changePayeeShare(address account, uint256 shares) external onlyValidShares(account, shares) onlyOwner {
        if (account == address(0)) {
            revert AccountIsZeroAddressError();
        }
        if (percents[account] == 0) {
            revert AccountDoesNotHaveShares(account);
        }
        if (account == controller) {
            revert OperationsOnControllerNotPermitted();
        }

        resetShareValues();

        percents[controller] = percents[controller].add(percents[account]).sub(shares);
        percents[account] = shares;
    }

    function removePayee(address account) external onlyOwner {
        if (account == address(0)) {
            revert AccountIsZeroAddressError();
        }
        if (percents[account] == 0) {
            revert AccountDoesNotHaveShares(account);
        }
        if (account == controller) {
            revert OperationsOnControllerNotPermitted();
        }

        resetShareValues();

        percents[controller] = percents[controller].add(percents[account]);
        payees.remove(account);
        percents[account] = 0;
    }

    function release(address token) external {
        if (!rewardTokensCache.contains(token)) {
            revert TokenNotAddedAsRewardsError(token);
        }
        addToAvailable(token);

        uint256 payment = pendingPayment(msg.sender, token);
        if (payment == 0) return;

        addFundsToReleased(msg.sender, token, payment);

        if (token == address(0)) {
            if (address(this).balance < payment) {
                revert InsufficientBalanceOfContract(token, payment, address(this).balance);
            }
            payable(msg.sender).transfer(payment);
        } else {
            if (IERC20Upgradeable(token).balanceOf(address(this)) < payment) {
                revert InsufficientBalanceOfContract(token, payment, address(this).balance);
            }
            SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(token), msg.sender, payment);
        }
    }

    function resetShareValues() internal {
        for (uint256 k = 0; k < rewardTokensCache.length(); k++) {
            address token = rewardTokensCache.at(k);
            addToAvailable(token);

            for (uint256 j = 0; j < payees.length(); j++) {
                address payeeAddr = payees.at(j);
                pending[payeeAddr][token] = pendingPayment(payeeAddr, token);
                released[payeeAddr][token] = 0;
            }

            availableMap[token] = 0;
        }
    }

    function addFundsToReleased(address account, address token, uint256 amount) private {
        uint256 nonPendingPayment = amount.sub(pending[account][token]);
        released[account][token] += nonPendingPayment;
        pending[account][token] = 0;
    }

    function pendingPayment(address account, address token) internal view returns (uint256) {
        if (percents[account] == 0 || availableMap[token] == 0)
            return pending[account][token];
        return availableMap[token].mul(percents[account]).div(100_0).sub(released[account][token]).add(pending[account][token]);
    }

    function addToAvailable(address token) internal {
        uint256 diff = token == address(0)
            ? payable(address(this)).balance.sub(lastTokenHolding[token])
            : IERC20Upgradeable(token).balanceOf(address(this)).sub(lastTokenHolding[token]);
        availableMap[token] = availableMap[token].add(diff);
        lastTokenHolding[token] = lastTokenHolding[token].add(diff);
    }

    uint256[50] private __gap;
}
