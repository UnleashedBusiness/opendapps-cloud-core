// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from  "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ERC165CheckerUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";

import {IPersonalVault} from "@unleashed/opendapps-cloud-interfaces/staking-as-a-service/PersonalVaultInterface.sol";

    error InterfaceNotSupportedError(address target, bytes4 interfaceId);
    error AmountOutsideExpectedValues(uint256 min, uint256 max, uint256 actual);
    error AllowanceOutsideExpectedValues(uint256 expected, uint256 actual);
    error UnexpectedFeesOccurredError();
    error LockAlreadyExistsError();
    error LockDoesNotExistsError();
    error BlockValueInvalidError();

contract PersonalVault is IPersonalVault, Initializable, ERC165Upgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event Deposit(uint256 amount);
    event Withdrawn(uint256 amount);
    event Locked(uint256 amount, uint256 untilBlock);

    address public token;

    address private _owner;
    address private _deployer;

    uint256 public lockedAmount;
    uint256 private _lockedUntilBlock;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _token, address vaultOwner) external initializer {
        if (!ERC165CheckerUpgradeable.supportsInterface(_token, type(IERC20Upgradeable).interfaceId)) {
            revert InterfaceNotSupportedError(_token, type(IERC20Upgradeable).interfaceId);
        }
        _owner = vaultOwner;
        _deployer = msg.sender;

        token = _token;
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyDeployer() {
        _checkDeployer();
        _;
    }

    function deployer() public view virtual returns (address) {
        return _deployer;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function balance() external view returns (uint256) {
        return _tokenContract().balanceOf(address(this));
    }

    function lockedBalance() external view returns (uint256) {
        if (_lockedUntilBlock >= block.number) {
            return lockedAmount;
        } else {
            return 0;
        }
    }

    function unlockedBalance() external view returns (uint256) {
        if (_lockedUntilBlock >= block.number) {
            return _tokenContract().balanceOf(address(this)).sub(lockedAmount);
        } else {
            return _tokenContract().balanceOf(address(this));
        }
    }

    function lockedUntilBlock() external view returns (uint256) {
        return _lockedUntilBlock;
    }

    function lockInProgress() external view returns (bool) {
        return _lockedUntilBlock >= block.number;
    }

    function deposit(uint256 amount) external onlyDeployer {
        uint256 ownerBalance = _tokenContract().balanceOf(owner());
        if (amount <= 0 || ownerBalance < amount) {
            revert AmountOutsideExpectedValues(1, ownerBalance, amount);
        }
        uint256 allowance = _tokenContract().allowance(owner(), address(this));
        if (allowance < amount) {
            revert AllowanceOutsideExpectedValues(amount, allowance);
        }

        uint256 expectedBalance = ownerBalance.sub(amount);
        uint256 expectedSupply = _tokenContract().balanceOf(address(this)).add(amount);

        _tokenContract().safeTransferFrom(owner(), address(this), amount);
        if (_tokenContract().balanceOf(address(this)) != expectedSupply) {
            revert UnexpectedFeesOccurredError();
        }
        if (_tokenContract().balanceOf(owner()) != expectedBalance) {
            revert UnexpectedFeesOccurredError();
        }

        emit Deposit(amount);
    }

    function withdraw(uint256 amount) external onlyDeployer {
        if (amount <= 0 || this.unlockedBalance() < amount) {
            revert AmountOutsideExpectedValues(1, this.unlockedBalance(), amount);
        }

        uint256 ownerBalance = _tokenContract().balanceOf(owner());
        uint256 expectedBalance = ownerBalance.add(amount);

        _tokenContract().safeTransfer(owner(), amount);
        if (_tokenContract().balanceOf(owner()) != expectedBalance) {
            revert UnexpectedFeesOccurredError();
        }

        emit Withdrawn(amount);
    }

    function lock(uint256 amount, uint256 blockCount) external onlyDeployer {
        if (_lockedUntilBlock >= block.number) {
            revert LockAlreadyExistsError();
        }
        if (amount <= 0 || _tokenContract().balanceOf(address(this)) < amount) {
            revert AmountOutsideExpectedValues(1, _tokenContract().balanceOf(address(this)), amount);
        }
        if (blockCount <= 0) {
            revert BlockValueInvalidError();
        }

        lockedAmount = amount;
        _lockedUntilBlock = block.number + blockCount;

        emit Locked(lockedAmount, _lockedUntilBlock);
    }

    function extendLockTime(uint256 extraBlocksCount) external onlyDeployer {
        if (_lockedUntilBlock < block.number) {
            revert LockDoesNotExistsError();
        }
        if (extraBlocksCount <= 0) {
            revert BlockValueInvalidError();
        }

        _lockedUntilBlock = _lockedUntilBlock.add(extraBlocksCount);
        emit Locked(lockedAmount, _lockedUntilBlock);
    }

    function addToLockAmount(uint256 amount) external onlyDeployer {
        if (_lockedUntilBlock < block.number) {
            revert LockDoesNotExistsError();
        }
        if (amount <= 0 || this.unlockedBalance() < amount) {
            revert AmountOutsideExpectedValues(1, this.unlockedBalance(), amount);
        }

        lockedAmount = lockedAmount.add(amount);
        emit Locked(lockedAmount, _lockedUntilBlock);
    }

    function supportsInterface(bytes4 interfaceId) public override view returns (bool) {
        return
            interfaceId == type(IPersonalVault).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _tokenContract() internal view returns (IERC20Upgradeable) {
        return IERC20Upgradeable(token);
    }

    function _checkDeployer() internal view virtual {
        require(deployer() == msg.sender, "Ownable: caller is not the deployer");
    }

    function _checkOwner() internal view virtual {
        require(owner() == msg.sender, "Ownable: caller is not the owner");
    }
}