pragma solidity ^0.8.7;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {StringsUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";

import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ERC165CheckerUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {TokenAsAServiceInterface} from "@unleashed/opendapps-cloud-interfaces/token-as-a-service/TokenAsAServiceInterface.sol";
import {InflationInterface} from "@unleashed/opendapps-cloud-interfaces/token-as-a-service/InflationInterface.sol";
import {DynamicTokenomicsInterface} from "@unleashed/opendapps-cloud-interfaces/token-as-a-service/DynamicTokenomicsInterface.sol";
import {ServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/ServiceDeployableInterface.sol";

import {OwnershipNFTCollection} from "./../ownership/OwnershipNFTCollection.sol";

    error InterfaceNotSupportedError(address target, bytes4 interfaceId);
    error InitialSupplyPercentInvalidError(uint256 min, uint256 max, uint256 actual);
    error TransactionInvalidError(address from, address to, uint256 size);

contract TokenAsAService is TokenAsAServiceInterface, ServiceDeployableInterface,
Initializable, ERC165Upgradeable, ERC20Upgradeable, OwnableUpgradeable {

    event Burn(uint256 amount);

    uint256 constant public MAX_TAX_TOKENOMICS = 10;
    uint256 constant public AUTOVALID_WALLET_SIZE_PERCENT = 1;
    uint256 constant public AUTOVALID_TRANSACTION_SIZE_PERCENT = 1;

    uint256 public maxSupply;
    uint256 public initialSupply;

    address public tokenomics;
    address public inflation;

    address public ownershipCollection;
    uint256 public ownershipTokenId;
    bool public isOwnedByNFT;

    using SafeMathUpgradeable for uint256;

    constructor() {
        _disableInitializers();
    }

    function supportsInterface(bytes4 interfaceId) public override view returns (bool) {
        return interfaceId == type(TokenAsAServiceInterface).interfaceId
        || interfaceId == type(IERC20Upgradeable).interfaceId
        || interfaceId == type(ServiceDeployableInterface).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function totalSupply() public view virtual override returns (uint256) {
        if (inflation == address(0))
            return super.totalSupply();

        uint256 supply = initialSupply.add(InflationInterface(inflation).totalUnlocked());
        if (supply > maxSupply)
            return maxSupply;
        return supply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        if (inflation == address(0))
            return super.balanceOf(account);

        return super.balanceOf(account).add(InflationInterface(inflation).availableFor(account));
    }

    function owner() public view override(TokenAsAServiceInterface, OwnableUpgradeable) returns (address) {
        return ownershipCollection != address(0)
            ? OwnershipNFTCollection(ownershipCollection).ownerOf(ownershipTokenId)
            : OwnableUpgradeable.owner();
    }

    function metadataUrl() external view returns (string memory) {
        return OwnershipNFTCollection(ownershipCollection).tokenURI(ownershipTokenId);
    }

    function canAccessFromDeployer(address walletOrContract) external view returns (bool){
        return owner() == walletOrContract;
    }

    function initialize(
        string memory name_, string memory symbol_, address dynamicTokenomics,
        address inflationTokenomics, uint256 _maxSupply, uint256 initialSupplyPercent,
        address ownershipNftCollection, uint256 _ownershipTokenId
    ) external initializer
    {
        if (!ERC165CheckerUpgradeable.supportsInterface(dynamicTokenomics, type(DynamicTokenomicsInterface).interfaceId)) {
            revert InterfaceNotSupportedError(dynamicTokenomics, type(DynamicTokenomicsInterface).interfaceId);
        }

        if (inflationTokenomics != address(0)) {
            if (!ERC165CheckerUpgradeable.supportsInterface(inflationTokenomics, type(InflationInterface).interfaceId)) {
                revert InterfaceNotSupportedError(inflationTokenomics, type(InflationInterface).interfaceId);
            }
            if (initialSupplyPercent > 90 || initialSupplyPercent < 50) {
                revert InitialSupplyPercentInvalidError(50, 90, initialSupplyPercent);
            }
        } else {
            if (initialSupplyPercent != 100) {
                revert InitialSupplyPercentInvalidError(100, 100, initialSupplyPercent);
            }
        }
        initialSupply = _maxSupply.mul(initialSupplyPercent).div(100);

        tokenomics = dynamicTokenomics;
        inflation = inflationTokenomics;
        maxSupply = _maxSupply;

        if (ownershipNftCollection != address(0)) {
            ownershipCollection = ownershipNftCollection;
            ownershipTokenId = _ownershipTokenId;
            isOwnedByNFT = true;
        } else {
            super.__Ownable_init_unchained();
            isOwnedByNFT = false;
        }

        super.__ERC20_init(name_, symbol_);
        _mint(msg.sender, initialSupply);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        // Inflation mints according to inflation implementation algorithm
        if (inflation != address(0)) {
            uint256 availableRewards = InflationInterface(inflation).availableFor(sender);

            if (availableRewards > 0) {
                InflationInterface(inflation).releaseFor(sender);
                uint256 afterMintAvailableRewards = InflationInterface(inflation).availableFor(sender);

                if (afterMintAvailableRewards <= 0) {
                    _mint(sender, availableRewards);
                }
            }
        }

        bool isValidTransaction = (amount < totalSupply().mul(AUTOVALID_TRANSACTION_SIZE_PERCENT).div(100)
            && balanceOf(recipient).add(amount) < totalSupply().mul(AUTOVALID_WALLET_SIZE_PERCENT).div(100))
            || DynamicTokenomicsInterface(tokenomics).isTransactionValid(sender, recipient, amount);
        if (!isValidTransaction) {
            revert TransactionInvalidError(sender, recipient, amount);
        }

        // Dynamic tokenomics trigger
        if (sender != tokenomics && recipient != tokenomics) {
            uint256 taxAmount = amount.mul(_getTax(sender, recipient)).div(100);

            if (taxAmount > 0) {
                amount = amount.sub(taxAmount);
                super._transfer(sender, tokenomics, taxAmount);

                DynamicTokenomicsInterface(tokenomics).applyTokenomics(sender, recipient, taxAmount);
            }
        }

        super._transfer(sender, recipient, amount);
    }

    function burn(uint256 amount) external {
        super._burn(msg.sender, amount);
        emit Burn(amount);
    }

    function _getTax(address from, address to) internal view returns (uint256) {
        uint256 taxScaling = DynamicTokenomicsInterface(tokenomics).taxScaling();
        uint256 maxTax = MAX_TAX_TOKENOMICS.mul(taxScaling);
        uint256 taxU = DynamicTokenomicsInterface(tokenomics).totalTax(from, to);
        return taxU > maxTax ? maxTax : taxU;
    }
}