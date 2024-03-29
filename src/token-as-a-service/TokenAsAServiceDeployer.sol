// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ERC165CheckerUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import {IWETH} from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

import {IContractDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/IContractDeployerInterface.sol";
import {TokenAsAServiceDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/token-as-a-service/TokenAsAServiceDeployerInterface.sol";
import {TokenAsAServiceInterface} from "@unleashed/opendapps-cloud-interfaces/token-as-a-service/TokenAsAServiceInterface.sol";
import {DynamicTokenomicsInterface} from "@unleashed/opendapps-cloud-interfaces/token-as-a-service/DynamicTokenomicsInterface.sol";
import {InflationInterface} from "@unleashed/opendapps-cloud-interfaces/token-as-a-service/InflationInterface.sol";
import {ServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/ServiceDeployableInterface.sol";
import {SecondaryServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/SecondaryServiceDeployableInterface.sol";

import {OwnershipNFTCollection} from "./../ownership/OwnershipNFTCollection.sol";
import {LiquidityUtils} from "./../lib/LiquidityUtils.sol";

    error ProvidedAddressNotCompatibleWithRequiredInterfaces(address target, bytes4 interfaceId);
    error RouterNotPartOfWhitelist(address router);
    error RouterAlreadyPartOfWhitelist(address router);
    error TotalSupplyBelowAllowedValues(uint256 min, uint256 actual);
    error OwnerShareGreaterThanAllowed(uint256 max, uint256 actual);
    error InitialSupplyExceedsAllowedValues(uint256 min, uint256 max, uint256 actual);
    error SenderDoesNotHaveEnoughFunds(uint256 expected, uint256 actual);
    error TokenAllowanceIsLessThenRequestedTransfer(uint256 expected, uint256 actual);
    error OnlyOwnerPermittedOperation(address actual);
    error ETHLessThanRequiredMinimumLiquidity(uint256 expected, uint256 actual);

contract TokenAsAServiceDeployer is TokenAsAServiceDeployerInterface, Initializable, ERC165Upgradeable, AccessControlUpgradeable {
    uint256[50] private __gap;

    enum TokenLevel {
        Basic,
        HardcapSimple,
        HardcapAdvanced,
        InflationAdvanced
    }

    event RefCodeUsed(bytes32 indexed code, address indexed receiver, uint256 ammount);
    event TokenServiceDeployed(address indexed creator, uint8 indexed typeId, address contractAddress, address tokenomicsAddress, address inflationAddress, address treasuryAddress);

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");

    bytes32 public constant GROUP_TOKENOMICS = keccak256("Tokenomics");
    bytes32 public constant GROUP_TOKEN = keccak256("Token");
    bytes32 public constant GROUP_TREASURY = keccak256("TREASURY");

    uint256 public constant DEFAULT_MIN_TOTAL_SUPPLY = 1 ether;
    uint256 public constant DEFAULT_MIN_ETH_LIQUIDITY_AMOUNT = 1 ether;
    uint256 public constant DEFAULT_OWNER_REWARD_RELEASE_BLOCKS = 840000; //~30 days on BSC
    uint256 public constant DEFAULT_OWNER_REWARD_CYCLES = 12; //~1 year on BSC

    address public contractDeployer;
    address public rewardsTreasury;

    uint256 public deployTokenDefaultTax;
    uint256 public deployTokenDefaultInflationTax;
    uint256 public minEthLiquidityAmount;

    uint256 public ownerRewardsReleaseBlocks;
    uint256 public ownerRewardCycles;

    address public ownershipNFTCollection;

    EnumerableSetUpgradeable.AddressSet internal whitelistedDexRouters;
    mapping(address => address) private wethOverrides;

    uint256 public minTotalSupply;

    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    receive() external payable {}

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
        address _contractDeployer, address _rewardsTreasury,
        address tokenLibrary, address tokenomicsLibrary, address inflationLibrary,
        uint256 _tax, uint256 _deployTokenDefaultTax, address nftOwnershipContract
    ) public initializer {
        if (!ERC165CheckerUpgradeable.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(_contractDeployer, type(IContractDeployerInterface).interfaceId);
        }

        super.__Context_init_unchained();
        super.__ERC165_init_unchained();
        super.__AccessControl_init_unchained();

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        contractDeployer = _contractDeployer;
        rewardsTreasury = _rewardsTreasury;

        _initializeTemplates(tokenLibrary, tokenomicsLibrary, inflationLibrary, _tax);

        ownershipNFTCollection = nftOwnershipContract;

        deployTokenDefaultTax = _deployTokenDefaultTax;
        deployTokenDefaultInflationTax = _deployTokenDefaultTax / 10;

        minEthLiquidityAmount = DEFAULT_MIN_ETH_LIQUIDITY_AMOUNT;
        ownerRewardsReleaseBlocks = DEFAULT_OWNER_REWARD_RELEASE_BLOCKS;
        ownerRewardCycles = DEFAULT_OWNER_REWARD_CYCLES;
        minTotalSupply = DEFAULT_MIN_TOTAL_SUPPLY;
    }

    function supportsInterface(bytes4 interfaceId) public override(AccessControlUpgradeable, ERC165Upgradeable) view returns (bool) {
        return interfaceId == type(TokenAsAServiceDeployerInterface).interfaceId
        || AccessControlUpgradeable.supportsInterface(interfaceId)
            || ERC165Upgradeable.supportsInterface(interfaceId);
    }

    // VIEWS
    function weth(address router) public view returns (address) {
        if (wethOverrides[router] != address(0)) {
            return wethOverrides[router];
        }

        return IUniswapV2Router02(router).WETH();
    }

    function availableDexRouters() external view returns (address[] memory) {
        return whitelistedDexRouters.values();
    }

    // METHODS - MANAGER
    function setTokenLibrary(address _token) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_TOKEN, 0, _token);
    }

    function setDynamicTokenomicsLibrary(address _tokenomics) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_TOKENOMICS, 0, _tokenomics);
    }

    function setInflationLibrary(address _inflation) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_TOKENOMICS, 1, _inflation);
    }

    function setTreasuryLibrary(address _treasury) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_TREASURY, 0, _treasury);
    }

    function setTokenDeployTax(uint256 taxSize) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeDeployTax(GROUP_TOKEN, 0, taxSize);
    }

    function setMinEthLiquidityAmount(uint256 amount) external onlyRole(LOCAL_MANAGER_ROLE) {
        minEthLiquidityAmount = amount;
    }

    function setMinTotalSupply(uint256 amount) external onlyRole(LOCAL_MANAGER_ROLE) {
        minTotalSupply = amount;
    }

    function setTokenTreasuryAddress(address _treasury) external onlyRole(LOCAL_MANAGER_ROLE) {
        rewardsTreasury = _treasury;
    }

    function overrideWethForRouter(address router, address _weth) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (!whitelistedDexRouters.contains(router)) {
            revert RouterNotPartOfWhitelist(router);
        }

        wethOverrides[router] = _weth;
    }

    function setOwnerRewardsSettings(uint256 _ownerRewardsReleaseBlocks, uint256 _ownerRewardCycles) external onlyRole(LOCAL_MANAGER_ROLE) {
        ownerRewardsReleaseBlocks = _ownerRewardsReleaseBlocks;
        ownerRewardCycles = _ownerRewardCycles;
    }

    function addDexRouterToWhitelist(address router) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (whitelistedDexRouters.contains(router)) {
            revert RouterAlreadyPartOfWhitelist(router);
        }

        whitelistedDexRouters.add(router);
    }

    function removeDexRouterFromWhitelist(address router) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (!whitelistedDexRouters.contains(router)) {
            revert RouterNotPartOfWhitelist(router);
        }

        whitelistedDexRouters.remove(router);
    }

    // METHODS - PUBLIC
    function deployBasicToken(
        string calldata name, string calldata ticker, uint256 supply, bytes32 refCode
    ) payable external returns (TokenDeployment memory)
    {
        if (minTotalSupply > supply) {
            revert TotalSupplyBelowAllowedValues(minTotalSupply, supply);
        }

        TokenDeployment memory deployment = _deployToken(TokenLevel.Basic, refCode);

        AddressUpgradeable.functionCall(
            deployment.token,
            abi.encodeWithSignature(
                "initialize(string,string,address,address,uint256,uint256,address,uint256)",
                name, ticker, deployment.tokenomics, deployment.inflation,
                supply, 100, address(0), 0
            )
        );
        AddressUpgradeable.functionCall(
            deployment.tokenomics,
            abi.encodeWithSignature("initialize(address,address,uint256)",
                deployment.token, rewardsTreasury, deployTokenDefaultTax
            )
        );
        DynamicTokenomicsInterface(deployment.tokenomics).createTaxableConfig();

        OwnableUpgradeable(deployment.token).transferOwnership(msg.sender);

        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(deployment.token), msg.sender, IERC20Upgradeable(deployment.token).balanceOf(address(this)));

        emit TokenServiceDeployed(msg.sender, uint8(TokenLevel.Basic), deployment.token, deployment.tokenomics, deployment.inflation, deployment.treasury);
        return deployment;
    }

    function deployHardCapToken(
        string calldata name, string calldata ticker, uint256 supply, uint256 ownerAmount,
        bool complexTax, string calldata metadataUrl, bytes32 refCode
    ) payable external returns (TokenDeployment memory)
    {
        if (minTotalSupply > supply) {
            revert TotalSupplyBelowAllowedValues(minTotalSupply, supply);
        }

        if (supply.mul(10).div(100) < ownerAmount) {
            revert OwnerShareGreaterThanAllowed(supply.mul(10).div(100), ownerAmount);
        }

        TokenDeployment memory deployment = _deployToken(complexTax ? TokenLevel.HardcapAdvanced : TokenLevel.HardcapSimple, refCode);

        _initializeTokenAndTokenomics(deployment, name, ticker, supply, 100, metadataUrl);

        for (uint256 i = 0; i < (complexTax ? 3 : 1); i++) {
            DynamicTokenomicsInterface(deployment.tokenomics).createTaxableConfig();
        }

        emit TokenServiceDeployed(msg.sender, uint8(complexTax ? TokenLevel.HardcapAdvanced : TokenLevel.HardcapSimple), deployment.token, deployment.tokenomics, deployment.inflation, deployment.treasury);
        return deployment;
    }

    function deployInflationaryToken(
        string calldata name, string calldata ticker, uint256 maxSupply,
        uint256 initialSupplyPercent, uint256 rewardRounds, uint256 blockPerCycle,
        uint256 ownerAmount, string calldata metadataUrl, bytes32 refCode
    ) payable external returns (TokenDeployment memory) {
        if (minTotalSupply > maxSupply) {
            revert TotalSupplyBelowAllowedValues(minTotalSupply, maxSupply);
        }

        if (maxSupply.mul(10).div(100) < ownerAmount) {
            revert OwnerShareGreaterThanAllowed(maxSupply.mul(10).div(100), ownerAmount);
        }

        if (initialSupplyPercent < 50 && initialSupplyPercent > 90) {
            revert InitialSupplyExceedsAllowedValues(50, 90, initialSupplyPercent);
        }

        TokenDeployment memory deployment = _deployToken(TokenLevel.InflationAdvanced, refCode);
        _initializeTokenAndTokenomics(deployment, name, ticker, maxSupply, initialSupplyPercent, metadataUrl);

        uint256 rewardsSupply = maxSupply.sub(maxSupply.mul(initialSupplyPercent).div(100));
        AddressUpgradeable.functionCall(
            deployment.inflation,
            abi.encodeWithSignature("initialize(address,address,uint256,uint256,uint256,uint256)",
                deployment.token, rewardsTreasury, deployTokenDefaultInflationTax,
                rewardsSupply, rewardRounds, blockPerCycle
            )
        );

        for (uint256 i = 0; i < 3; i++) {
            DynamicTokenomicsInterface(deployment.tokenomics).createTaxableConfig();
        }

        emit TokenServiceDeployed(msg.sender, uint8(TokenLevel.InflationAdvanced), deployment.token, deployment.tokenomics, deployment.inflation, deployment.treasury);
        return deployment;
    }

    function enableTokenomicsForDEX(address router, address token) external
    {
        if (msg.sender != OwnableUpgradeable(token).owner()) {
            revert OnlyOwnerPermittedOperation(msg.sender);
        }

        address _weth = weth(router);
        address pair = LiquidityUtils.getOrCreatePair(token, _weth, router);
        _enableTokenomicsForDEX(router, token, pair, _weth, address(0));
    }

    function enableTokenomicsForDEXWithCustomPair(address router, address token, address pairedWith) external
    {
        if (msg.sender != OwnableUpgradeable(token).owner()) {
            revert OnlyOwnerPermittedOperation(msg.sender);
        }

        address _weth = weth(router);
        address pair = LiquidityUtils.getOrCreatePair(token, pairedWith, router);
        _enableTokenomicsForDEX(router, token, pair, _weth, address(0));
    }

    function upgradeTokenomics(address tokenomics) payable external __requireSecondaryServicePermission(tokenomics, address(0)) {
        IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(GROUP_TOKENOMICS, tokenomics);
    }

    function upgradeInflation(address inflation) payable external __requireSecondaryServicePermission(inflation, address(0)) {
        IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(GROUP_TOKENOMICS, inflation);
    }

    function _enableTokenomicsForDEX(address router, address token, address pair, address _weth, address treasury) internal {
        address tokenomicsAddress = TokenAsAServiceInterface(token).tokenomics();
        DynamicTokenomicsInterface(tokenomicsAddress).addTaxForPath(pair, address(0), 0);
        DynamicTokenomicsInterface(tokenomicsAddress).addTaxForPath(address(0), pair, DynamicTokenomicsInterface(tokenomicsAddress).availableTaxableConfigurations() == 1 ? 0 : 1);
        DynamicTokenomicsInterface(tokenomicsAddress).addToWalletSizeWhitelist(pair);
        DynamicTokenomicsInterface(tokenomicsAddress).addToTransactionRestrictionWhitelist(pair);
        DynamicTokenomicsInterface(tokenomicsAddress).addToRouterAddressList(router, _weth);
        if (treasury != address(0)) {
            DynamicTokenomicsInterface(tokenomicsAddress).addToTaxablePathWhitelist(treasury);
        }
    }

    function _mintOwnerToken(string memory metadataUrl) internal returns (uint256) {
        uint256 ownerTokenId = OwnershipNFTCollection(ownershipNFTCollection).nextTokenId();
        OwnershipNFTCollection(ownershipNFTCollection).mint(msg.sender, metadataUrl);
        return ownerTokenId;
    }

    function _initializeTemplates(
        address tokenLibrary,
        address tokenomicsLibrary, address inflationLibrary,
        uint256 _tax
    ) internal {
        bytes4[] memory tokenInterfaces = new bytes4[](3);
        tokenInterfaces[0] = type(IERC20Upgradeable).interfaceId;
        tokenInterfaces[1] = type(TokenAsAServiceInterface).interfaceId;
        tokenInterfaces[2] = type(ServiceDeployableInterface).interfaceId;
        bytes4[] memory transferTokenomicsInterfaces = new bytes4[](2);
        transferTokenomicsInterfaces[0] = type(DynamicTokenomicsInterface).interfaceId;
        transferTokenomicsInterfaces[1] = type(SecondaryServiceDeployableInterface).interfaceId;
        bytes4[] memory inflationInterfaces = new bytes4[](2);
        inflationInterfaces[0] = type(InflationInterface).interfaceId;
        inflationInterfaces[1] = type(SecondaryServiceDeployableInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(GROUP_TOKEN, 0, tokenInterfaces, tokenLibrary, _tax);
        IContractDeployerInterface(contractDeployer).registerTemplate(GROUP_TOKENOMICS, 0, transferTokenomicsInterfaces, tokenomicsLibrary, 0);
        IContractDeployerInterface(contractDeployer).registerTemplate(GROUP_TOKENOMICS, 1, inflationInterfaces, inflationLibrary, 0);
    }

    function _deployToken(TokenLevel level, bytes32 refCode) internal returns (TokenDeployment memory) {
        return TokenDeployment(
            IContractDeployerInterface(contractDeployer).deployTemplate{value: msg.value}(msg.sender, GROUP_TOKEN, 0, bytes(''), refCode),
            IContractDeployerInterface(contractDeployer).deployTemplateWithProxy(msg.sender, GROUP_TOKENOMICS, 0, bytes(''), refCode),
            level >= TokenLevel.InflationAdvanced
                ? IContractDeployerInterface(contractDeployer).deployTemplateWithProxy(msg.sender, GROUP_TOKENOMICS, 1, bytes(''), refCode)
                : address(0),
            address(0)
        );
    }

    function _initializeTokenAndTokenomics(
        TokenDeployment memory deployment,
        string calldata name, string calldata ticker,
        uint256 maxSupply,
        uint256 initialSupplyPercent, string calldata metadataUrl
    ) internal {
        AddressUpgradeable.functionCall(
            deployment.token,
            abi.encodeWithSignature("initialize(string,string,address,address,uint256,uint256,address,uint256)",
                name, ticker, deployment.tokenomics, deployment.inflation,
                maxSupply, initialSupplyPercent,
                ownershipNFTCollection,
                _mintOwnerToken(metadataUrl)
            )
        );
        AddressUpgradeable.functionCall(
            deployment.tokenomics,
            abi.encodeWithSignature("initialize(address,address,uint256)",
                deployment.token, rewardsTreasury, deployTokenDefaultTax
            )
        );
    }


}