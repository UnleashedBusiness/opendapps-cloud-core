// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {TreasuryInterface} from "@unleashed/opendapps-cloud-interfaces/treasury/TreasuryInterface.sol";
import {ServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/ServiceDeployableInterface.sol";
import {TreasuryPocketInterface} from "@unleashed/opendapps-cloud-interfaces/treasury/TreasuryPocketInterface.sol";

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

contract Treasury is TreasuryInterface, ServiceDeployableInterface,
Initializable, ERC165Upgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
    using SafeMath for uint256;
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256[50] private _gap;

    mapping(address => uint256) private availableMap; //unused
    mapping(address => uint256) private percents;
    mapping(address => mapping(address => uint256)) private released; //unused
    mapping(address => mapping(address => uint256)) private pending; //unused

    address public controller;
    EnumerableSet.AddressSet private payees;
    EnumerableSet.AddressSet private rewardTokensCache;
    mapping(address => uint256) public lastTokenHolding; //unused

    address private _pocketTemplate;
    mapping(address => address) public pockets;
    address public deployer;

    constructor() {
        _disableInitializers();
    }

    receive() payable virtual external {}

    modifier onlyValidShares(address account, uint256 shares) {
        if (shares <= 0 || percents[controller].add(percents[account]) < shares) {
            revert InvalidSharesValueError();
        }
        _;
    }

    modifier requirePocket(address wallet) {
        if (pockets[wallet] == address(0)) {
            _deployPocket(wallet);
        }
        _;
    }

    function initialize(address _deployer, address pocketTemplate, address _controller) external reinitializer(2) {
        if (_getInitializedVersion() > 0) {
            revert InvalidInitializedState();
        }

        if (pocketTemplate == address(0)) {
            revert EmptyTemplateError();
        }

        __ReentrancyGuard_init_unchained();
        __Ownable_init_unchained();

        _pocketTemplate = pocketTemplate;
        controller = _controller;
        percents[_controller] = 100_0;
        //100.0 %
        payees.add(_controller);

        rewardTokensCache.add(address(0));
        deployer = _deployer;
    }

    function initializePockets(address _deployer, address pocketTemplate) external reinitializer(2) {
        uint256 currentState = _getInitializedVersion();
        if (currentState != 1) {
            revert InvalidInitializedState(currentState);
        }

        if (pocketTemplate == address(0)) {
            revert EmptyTemplateError();
        }

        _pocketTemplate = pocketTemplate;
        deployer = _deployer;
    }

    function canAccessFromDeployer(address walletOrContract) external view returns (bool) {
        return walletOrContract == owner();
    }

    function supportsInterface(bytes4 interfaceId) public virtual override(ERC165Upgradeable) view returns (bool) {
        return
            interfaceId == type(TreasuryInterface).interfaceId ||
            interfaceId == type(ServiceDeployableInterface).interfaceId ||
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

    function available(address token) public view returns (uint256){
        return token == address(0)
            ? payable(address(this)).balance
            : IERC20(token).balanceOf(address(this));
    }

    function totalPendingPayment(address account, address token) external view returns (uint256) {
        return percents[account] > 0
            ? available(token)
            .mul(percents[account])
            .div(100_0)
            : 0;
    }

    function payeePocket(address account) external view returns (address) {
        return pockets[account];
    }

    function balanceOf(address account, address token) external view returns (uint256) {
        return _walletBalance(account, token);
    }

    function changeController(address _controller) external onlyOwner {
        _payout();

        percents[_controller] = percents[controller];
        percents[controller] = 0;

        for (uint256 k = 0; k < rewardTokensCache.length(); k++) {
            address token = rewardTokensCache.at(k);

            pending[_controller][token] = pending[controller][token];
            pending[controller][token] = 0;
        }

        controller = _controller;
    }

    function addRewardToken(address token) external onlyOwner {
        if (rewardTokensCache.contains(token)) {
            revert TokenAlreadyAddedAsRewardsError(token);
        }

        rewardTokensCache.add(token);
    }

    function removeRewardToken(address token) external onlyOwner {
        if (!rewardTokensCache.contains(token)) {
            revert TokenNotAddedAsRewardsError(token);
        }

        rewardTokensCache.remove(token);
    }

    function addPayee(address account, uint256 shares) external onlyValidShares(account, shares) onlyOwner {
        if (account == address(0)) {
            revert AccountIsZeroAddressError();
        }
        if (percents[account] != 0) {
            revert AccountAlreadyHasShares(account);
        }

        _payout();

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

        _payout();

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

        _payout();

        percents[controller] = percents[controller].add(percents[account]);
        payees.remove(account);
        percents[account] = 0;
    }

    function claim(address token) external {
        _payoutToken(token);
    }

    function _payout() internal {
        for (uint256 k = 0; k < rewardTokensCache.length(); k++) {
            address token = rewardTokensCache.at(k);

            _payoutToken(token);
        }
    }

    function _payoutToken(address token) internal {
        uint256[] memory amounts = new uint256[](payees.length());
        address[] memory wallets = new address[](payees.length());
        for (uint256 j = 0; j < payees.length(); j++) {
            wallets[j] = payees.at(j);

            if (pockets[wallets[j]] == address(0)) {
                _deployPocket(wallets[j]);
            }

            amounts[j] = _walletBalance(wallets[j], token);
        }

        _payoutTokenToWallets(token, wallets, amounts);
    }

    function _payoutTokenToWallets(address token, address[] memory wallets, uint256[] memory amounts) internal {
        if (token == address(0)) {
            for (uint256 i = 0; i < wallets.length; i++) {
                Address.sendValue(payable(wallets[i]), amounts[i]);
            }
        } else {
            for (uint256 i = 0; i < wallets.length; i++) {
                SafeERC20.safeTransfer(IERC20(token), wallets[i], amounts[i]);
            }
        }
    }

    function _walletBalance(address account, address token) internal view returns (uint256) {
        uint256 pocketBalance = _pocketBalance(account, token);
        uint256 availableForToken = this.available(token);

        if (percents[account] == 0 || availableForToken == 0)
            return pocketBalance;

        return availableForToken
        .mul(percents[account])
        .div(100_0)
        .add(pocketBalance);
    }

    function _pocketBalance(address wallet, address token) internal view returns (uint256) {
        return pockets[wallet] == address(0)
            ? 0
            : TreasuryPocketInterface(pockets[wallet]).available(token);
    }

    function _deployPocket(address wallet) internal returns (TreasuryPocketInterface) {
        TreasuryPocketInterface c = TreasuryPocketInterface(Clones.clone(_pocketTemplate));

        Address.functionCall(
            address(c),
            abi.encodeWithSignature(
                "initialize(address,address)",
                deployer,
                wallet
            )
        );

        pockets[wallet] = address(c);
        return c;
    }

    uint256[50] private __gap;
}
