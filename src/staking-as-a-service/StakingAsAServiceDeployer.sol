// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {ERC165CheckerUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {IContractDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/IContractDeployerInterface.sol";
import {ServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/ServiceDeployableInterface.sol";
import {SecondaryServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/SecondaryServiceDeployableInterface.sol";
import {StakingAsAServiceInterface} from "@unleashed/opendapps-cloud-interfaces/staking-as-a-service/StakingAsAServiceInterface.sol";
import {StakingAsAServiceDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/staking-as-a-service/StakingAsAServiceDeployerInterface.sol";
import {TokenAsAServiceInterface} from "@unleashed/opendapps-cloud-interfaces/token-as-a-service/TokenAsAServiceInterface.sol";
import {IPersonalVault} from "@unleashed/opendapps-cloud-interfaces/staking-as-a-service/PersonalVaultInterface.sol";

    error TokenAlreadyHasStaking();
    error TokenHasNoStakingDeployed();
    error PermittedForOwnerOnly();
    error ProvidedAddressNotCompatibleWithRequiredInterfaces(address target, bytes4 interfaceId);
    error OnlyOwnerPermittedOperation(address sender);

contract StakingAsAServiceDeployer is StakingAsAServiceDeployerInterface, Initializable, ERC165Upgradeable, AccessControlUpgradeable {
    uint256[150] private __gap;

    event StakingServiceDeployed(address indexed creator, address indexed token, address contractAddress);

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");

    bytes32 public constant GROUP_PERSONAL_VAULT = keccak256("Vault");
    bytes32 public constant GROUP_STAKING = keccak256("Staking");

    address public contractDeployer;

    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;

    modifier __requireSecondaryServicePermission(address service, address expectedOwner) {
        if (!ERC165CheckerUpgradeable.supportsInterface(service, type(SecondaryServiceDeployableInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(service, type(SecondaryServiceDeployableInterface).interfaceId);
        }

        address masterDeployable = SecondaryServiceDeployableInterface(service).masterDeployable();
        if (!ServiceDeployableInterface(masterDeployable).canAccessFromDeployer(msg.sender) || (expectedOwner != address(0) && expectedOwner != msg.sender)) {
            revert OnlyOwnerPermittedOperation(msg.sender);
        }
        _;
    }

    function initialize(
        address _contractDeployer, address stakingLibrary,
        address vaultTemplate, uint256 _tax
    ) public initializer {
        if (!ERC165CheckerUpgradeable.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(_contractDeployer, type(IContractDeployerInterface).interfaceId);
        }

        super.__Context_init_unchained();
        super.__ERC165_init_unchained();
        super.__AccessControl_init_unchained();

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        contractDeployer = _contractDeployer;

        bytes4[] memory vaultInterfaces = new bytes4[](1);
        vaultInterfaces[0] = type(IPersonalVault).interfaceId;
        bytes4[] memory stakingInterfaces = new bytes4[](1);
        stakingInterfaces[0] = type(StakingAsAServiceInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_PERSONAL_VAULT, 0,
            vaultInterfaces, vaultTemplate, 0
        );
        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_STAKING, 0,
            stakingInterfaces, stakingLibrary, _tax
        );
    }

    function supportsInterface(bytes4 interfaceId) public override(AccessControlUpgradeable, ERC165Upgradeable) view returns (bool) {
        return interfaceId == type(StakingAsAServiceDeployerInterface).interfaceId
        || AccessControlUpgradeable.supportsInterface(interfaceId)
            || ERC165Upgradeable.supportsInterface(interfaceId);
    }

    // METHODS - MANAGER
    function setVaultLibraryAddress(address _libraryAddress) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(
            GROUP_PERSONAL_VAULT,
            0,
            _libraryAddress
        );
    }

    function refreshVaultLibraryInterfaces() external onlyRole(LOCAL_MANAGER_ROLE) {
        bytes4[] memory vaultInterfaces = new bytes4[](1);
        vaultInterfaces[0] = type(IPersonalVault).interfaceId;

        IContractDeployerInterface(contractDeployer).upgradeTemplateInterfaceList(GROUP_PERSONAL_VAULT, 0, vaultInterfaces);
    }

    function setStakingLibraryAddress(address _libraryAddress) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(
            GROUP_STAKING,
            0,
            _libraryAddress
        );
    }

    function refreshStakingLibraryInterfaces() external onlyRole(LOCAL_MANAGER_ROLE) {
        bytes4[] memory stakingInterfaces = new bytes4[](1);
        stakingInterfaces[0] = type(StakingAsAServiceInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).upgradeTemplateInterfaceList(
            GROUP_STAKING,
            0,
            stakingInterfaces);
    }

    function setDeployTax(uint256 taxSize) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeDeployTax(
            GROUP_STAKING,
            0,
            taxSize
        );
    }

    // METHODS - PUBLIC
    function deploy(address erc20Token, bytes32 refCode) payable external returns (address) {
        if (!ERC165CheckerUpgradeable.supportsInterface(erc20Token, type(IERC20Upgradeable).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(erc20Token, type(IERC20Upgradeable).interfaceId);
        }

        address staking = IContractDeployerInterface(contractDeployer).deployTemplateWithProxy{value: msg.value}(
            msg.sender, GROUP_STAKING, 0,
            bytes(""),
            refCode
        );

        AddressUpgradeable.functionCall(
            staking,
            abi.encodeWithSignature(
                "initialize(address,address)",
                IContractDeployerInterface(contractDeployer).currentTemplate(GROUP_PERSONAL_VAULT, 0),
                erc20Token
            )
        );

        if (!ERC165CheckerUpgradeable.supportsInterface(erc20Token, type(ServiceDeployableInterface).interfaceId)) {
            OwnableUpgradeable(staking).transferOwnership(msg.sender);
        }

        emit StakingServiceDeployed(msg.sender, erc20Token, staking);

        return staking;
    }

    function upgrade(address staking) external __requireSecondaryServicePermission(staking, address(0)) {
        IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(
            GROUP_STAKING,
            staking
        );
    }
}