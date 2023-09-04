// SPDX-License-Identifier: proprietary
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
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import {IContractDeployerInterface} from "@stopelon/contracts-common/contracts/deploy/interface/IContractDeployerInterface.sol";
import {ContractDeployer, NotPartOfDeployer} from "@stopelon/contracts-common/contracts/deploy/base/ContractDeployer.sol";

import {IWETH} from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IRewardsTreasury_v1} from "@stopelon/contracts-common/contracts/reward-distribution/interface/IRewardsTreasury_v1.sol";
import {OwnershipNFTCollection} from "./../ownership/OwnershipNFTCollection.sol";

import {ITokenAsAServiceTemplate_v1} from "./../interface/ITokenAsAServiceTemplate_v1.sol";
import {ITransferTokenomics_v1} from "./../interface/ITransferTokenomics.sol";
import {IInflationTokenomics_v1} from "./../interface/IInflationTokenomics.sol";
import {LiquidityUtils} from "./../lib/LiquidityUtils.sol";
import {Treasury} from "./Treasury.sol";
import {ITreasury} from "./../interface/ITreasury.sol";

    error ProvidedTemplateNotCompatibleForTreasury();
    error ProvidedAddressNotCompatibleWithRequiredInterfaces();
    error RouterNotPartOfWhitelist();
    error RouterAlreadyPartOfWhitelist();
    error TotalTaxProvidedLowerThanExpected();
    error OwnerShareGreaterThanAllowed();
    error InitialSupplyExceedsAllowedValues();
    error SenderDoesNotHaveEnoughFunds();
    error TokenAllowanceIsLessThenRequestedTransfer();
    error OnlyOwnerPermittedOperation();
    error ETHLessThanRequiredMinimumLiquidity();
    error CompensationCalculationFailed();

contract TokenAsAServiceDeployer is Initializable, AccessControlUpgradeable {
    event RefCodeUsed(bytes32 indexed code, address indexed receiver, uint256 ammount);

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");

    enum TokenLevel {
        Basic,
        HardcapSimple,
        HardcapAdvanced,
        InflationAdvanced
    }

    event TokenServiceDeployed(address indexed creator, uint8 indexed typeId, address contractAddress, address tokenomicsAddress, address inflationAddress, address treasuryAddress);

    uint256[50] private __gap;

    bytes32 public constant GROUP_TOKENOMICS = keccak256("Tokenomics");
    bytes32 public constant GROUP_TOKEN = keccak256("Token");
    bytes32 public constant GROUP_TREASURY = keccak256("TREASURY");

    uint256 public constant DEFAULT_MIN_ETH_LIQUIDITY_AMOUNT = 1 * 10 ** 18;
    uint256 public constant DEFAULT_OWNER_REWARD_RELEASE_BLOCKS = 840000; //~30 days on BSC
    uint256 public constant DEFAULT_OWNER_REWARD_CYCLES = 12; //~1 year on BSC

    address public contractDeployer;
    address public rewardsTreasury;

    uint256 public deployTokenDefaultTax;
    uint256 public minEthLiquidityAmount;

    uint256 public ownerRewardsReleaseBlocks;
    uint256 public ownerRewardCycles;

    address public ownershipNFTCollection;
    EnumerableSetUpgradeable.AddressSet internal whitelistedDexRouters;
    mapping(address => address) private wethOverrides;
    mapping(address => address) private tokenTreasury;

    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    struct TokenDeployment {
        address token;
        address tokenomics;
        address inflation;
        address treasury;
    }

    receive() external payable {}

    function initialize(
        address _contractDeployer, address _rewardsTreasury,
        address tokenLibrary, address tokenomicsLibrary, address inflationLibrary,
        address treasuryLibrary, uint256 _tax, uint256 _deployTokenDefaultTax, address nftOwnershipContract
    ) public initializer {
        if (!ERC165CheckerUpgradeable.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces();
        }

        super.__Context_init_unchained();
        super.__ERC165_init_unchained();
        super.__AccessControl_init_unchained();

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        contractDeployer = _contractDeployer;
        rewardsTreasury = _rewardsTreasury;

        initializeTemplates(treasuryLibrary, tokenLibrary, tokenomicsLibrary, inflationLibrary, _tax);

        ownershipNFTCollection = nftOwnershipContract;
        deployTokenDefaultTax = _deployTokenDefaultTax;
        minEthLiquidityAmount = DEFAULT_MIN_ETH_LIQUIDITY_AMOUNT;
        ownerRewardsReleaseBlocks = DEFAULT_OWNER_REWARD_RELEASE_BLOCKS;
        ownerRewardCycles = DEFAULT_OWNER_REWARD_CYCLES;
    }

    // VIEWS
    function weth(address router) public view returns (address) {
        if (wethOverrides[router] != address(0)) {
            return wethOverrides[router];
        }

        return IUniswapV2Router02(router).WETH();
    }

    function treasury(address token) public view returns (address) {
        return tokenTreasury[token];
    }

    function availableDexRouters() external view returns (address[] memory) {
        return whitelistedDexRouters.values();
    }

    // METHODS - MANAGER
    function setLibraries(address _tokenomics, address _inflation, address _token, address _treasury) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (_tokenomics != address(0))
            IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_TOKENOMICS, 0, _tokenomics);
        if (_inflation != address(0))
            IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_TOKENOMICS, 1, _inflation);
        if (_token != address(0))
            IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_TOKEN, 0, _token);
        if (_treasury != address(0))
            IContractDeployerInterface(contractDeployer).upgradeTemplate(GROUP_TREASURY, 0, _treasury);
    }

    function setTokenDeployTax(uint256 taxSize) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeDeployTax(GROUP_TOKEN, 0, taxSize);
    }

    function setMinEthLiquidityAmount(uint256 amount) external onlyRole(LOCAL_MANAGER_ROLE) {
        minEthLiquidityAmount = amount;
    }

    function overrideWethForRouter(address router, address weth) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (!whitelistedDexRouters.contains(router)) {
            revert RouterNotPartOfWhitelist();
        }

        wethOverrides[router] = weth;
    }

    function setOwnerRewardsSettings(uint256 _ownerRewardsReleaseBlocks, uint256 _ownerRewardCycles) external onlyRole(LOCAL_MANAGER_ROLE) {
        ownerRewardsReleaseBlocks = _ownerRewardsReleaseBlocks;
        ownerRewardCycles = _ownerRewardCycles;
    }

    function addDexRouterToWhitelist(address router) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (whitelistedDexRouters.contains(router)) {
            revert RouterAlreadyPartOfWhitelist();
        }

        whitelistedDexRouters.add(router);
    }

    function removeDexRouterFromWhitelist(address router) external onlyRole(LOCAL_MANAGER_ROLE) {
        if (!whitelistedDexRouters.contains(router)) {
            revert RouterNotPartOfWhitelist();
        }

        whitelistedDexRouters.remove(router);
    }

    // METHODS - PUBLIC
    function deployBasicToken(
        string calldata name, string calldata ticker, uint256 supply, bytes32 refCode
    ) payable external returns (address)
    {
        TokenDeployment memory deployment = deployToken(TokenLevel.Basic, refCode);
        ITokenAsAServiceTemplate_v1(deployment.token).initialize(
            name, ticker, deployment.tokenomics, deployment.inflation,
            supply, 100, address(0), 0
        );
        ITransferTokenomics_v1(deployment.tokenomics).initialize(deployment.token, rewardsTreasury, deployTokenDefaultTax);
        ITransferTokenomics_v1(deployment.tokenomics).createTaxableConfig();

        OwnableUpgradeable(deployment.token).transferOwnership(msg.sender);

        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(deployment.token), msg.sender, IERC20Upgradeable(deployment.token).balanceOf(address(this)));

        emit TokenServiceDeployed(msg.sender, uint8(TokenLevel.Basic), deployment.token, deployment.tokenomics, deployment.inflation, deployment.treasury);
        return deployment.token;
    }

    function deployHardCapToken(
        string calldata name, string calldata ticker, uint256 supply, uint256 ownerAmount,
        bool complexTax, string calldata metadataUrl, bytes32 refCode
    ) payable external returns (address)
    {
        if (supply.mul(10).div(100) < ownerAmount) {
            revert OwnerShareGreaterThanAllowed();
        }
        TokenDeployment memory deployment = deployToken(complexTax ? TokenLevel.HardcapAdvanced : TokenLevel.HardcapSimple, refCode);

        initializeTokenAndTokenomics(deployment, name, ticker, supply, 100, metadataUrl);
        for (uint256 i = 0; i < (complexTax ? 3 : 1); i++) {
            ITransferTokenomics_v1(deployment.tokenomics).createTaxableConfig();
        }
        initializeTreasury(deployment, ownerAmount);

        emit TokenServiceDeployed(msg.sender, uint8(complexTax ? TokenLevel.HardcapAdvanced : TokenLevel.HardcapSimple), deployment.token, deployment.tokenomics, deployment.inflation, deployment.treasury);
        return deployment.token;
    }

    function deployInflationaryToken(
        string calldata name, string calldata ticker, uint256 maxSupply,
        uint256 initialSupplyPercent, uint256 rewardRounds, uint256 blockPerCycle,
        uint256 ownerAmount, string calldata metadataUrl, bytes32 refCode
    ) payable external returns (address) {
        if (maxSupply.mul(10).div(100) < ownerAmount) {
            revert OwnerShareGreaterThanAllowed();
        }

        if (initialSupplyPercent < 50 && initialSupplyPercent > 90) {
            revert InitialSupplyExceedsAllowedValues();
        }

        TokenDeployment memory deployment = deployToken(TokenLevel.InflationAdvanced, refCode);
        initializeTokenAndTokenomics(deployment, name, ticker, maxSupply, initialSupplyPercent, metadataUrl);

        uint256 rewardsSupply = maxSupply.sub(maxSupply.mul(initialSupplyPercent).div(100));
        IInflationTokenomics_v1(deployment.inflation).initialize(
            deployment.token, rewardsTreasury, deployTokenDefaultTax,
            rewardsSupply, rewardRounds, blockPerCycle
        );
        for (uint256 i = 0; i < 3; i++) {
            ITransferTokenomics_v1(deployment.tokenomics).createTaxableConfig();
        }
        initializeTreasury(deployment, ownerAmount);

        emit TokenServiceDeployed(msg.sender, uint8(TokenLevel.InflationAdvanced), deployment.token, deployment.tokenomics, deployment.inflation, deployment.treasury);
        return deployment.token;
    }

    function addLiqudityToDexNative(address router, address token, uint256 tokenLiquidityAmount, uint256 ethLiquidityAmount) payable external {
        _addLiquidityNative(router, token, tokenLiquidityAmount, ethLiquidityAmount);
    }

    function addLiqudityToDexNativeFromWallet(address router, address token, uint256 tokenLiquidityAmount, uint256 ethLiquidityAmount) payable external {
        uint256 senderBalance = IERC20Upgradeable(token).balanceOf(msg.sender);

        if (senderBalance < tokenLiquidityAmount) {
            revert SenderDoesNotHaveEnoughFunds();
        }
        if (IERC20Upgradeable(token).allowance(msg.sender, address(this)) < tokenLiquidityAmount) {
            revert TokenAllowanceIsLessThenRequestedTransfer();
        }

        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(token), msg.sender, address(this), tokenLiquidityAmount);

        _addLiquidityNative(router, token, tokenLiquidityAmount, ethLiquidityAmount);
    }

    function upgrade(address token, bool treasury, bool transfer, bool inflation) payable external {
        if (OwnableUpgradeable(token).owner() != msg.sender) {
            revert OnlyOwnerPermittedOperation();
        }

        if (treasury)
            IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(GROUP_TREASURY, tokenTreasury[token]);
        if (transfer)
            IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(
                GROUP_TOKENOMICS, ITokenAsAServiceTemplate_v1(token).tokenomics()
            );
        if (inflation)
            IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(
                GROUP_TOKENOMICS, ITokenAsAServiceTemplate_v1(token).inflation()
            );
    }

    //METHODS - PRIVATE
    function _addLiquidityNative(address router, address token, uint256 tokenLiquidutyAmount, uint256 ethLiquidityAmount) internal {
        if (tokenTreasury[token] == address(0)) {
            revert NotPartOfDeployer();
        }

        if (!whitelistedDexRouters.contains(router)) {
            revert RouterNotPartOfWhitelist();
        }
        if (OwnableUpgradeable(token).owner() != msg.sender) {
            revert OnlyOwnerPermittedOperation();
        }

        bool alreadyListed = ITreasury(tokenTreasury[token]).isTokenListedOnDex(router);
        if (!alreadyListed && ethLiquidityAmount < minEthLiquidityAmount) {
            revert ETHLessThanRequiredMinimumLiquidity();
        }

        address weth = weth(router);
        address pair = LiquidityUtils.getOrCreatePair(token, weth, router);
        if (!alreadyListed) {
            address tokenomicsAddress = ITokenAsAServiceTemplate_v1(token).tokenomics();
            ITransferTokenomics_v1(tokenomicsAddress).addTaxForPath(pair, address(0), 0);
            ITransferTokenomics_v1(tokenomicsAddress).addTaxForPath(address(0), pair, ITransferTokenomics_v1(tokenomicsAddress).availableTaxableConfigurations() == 1 ? 0 : 1);
            ITransferTokenomics_v1(tokenomicsAddress).addToWalletSizeWhitelist(pair);
            ITransferTokenomics_v1(tokenomicsAddress).addToTransactionRestrictionWhitelist(pair);
            ITransferTokenomics_v1(tokenomicsAddress).addToRouterAddressList(router, weth);
            ITransferTokenomics_v1(tokenomicsAddress).addToTaxablePathWhitelist(tokenTreasury[token]);
        }
        ITreasury(tokenTreasury[token]).addLiquidityV2{value: msg.value}(router, weth, tokenLiquidutyAmount, ethLiquidityAmount);
    }

    function mintOwnerToken(string memory metadataUrl) internal returns (uint256) {
        uint256 ownerTokenId = OwnershipNFTCollection(ownershipNFTCollection).nextTokenId();
        OwnershipNFTCollection(ownershipNFTCollection).mint(msg.sender, metadataUrl);
        return ownerTokenId;
    }

    function initializeTemplates(
        address treasuryLibrary, address tokenLibrary,
        address tokenomicsLibrary, address inflationLibrary,
        uint256 _tax
    ) internal {
        bytes4[] memory tokenInterfaces = new bytes4[](1);
        tokenInterfaces[0] = type(IERC20Upgradeable).interfaceId;
        bytes4[] memory transferTokenomicsInterfaces = new bytes4[](1);
        transferTokenomicsInterfaces[0] = type(ITransferTokenomics_v1).interfaceId;
        bytes4[] memory inflationInterfaces = new bytes4[](1);
        inflationInterfaces[0] = type(IInflationTokenomics_v1).interfaceId;
        bytes4[] memory treasuryInterfaces = new bytes4[](1);
        treasuryInterfaces[0] = type(ITreasury).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(GROUP_TREASURY, 0, treasuryInterfaces, treasuryLibrary, 0);
        IContractDeployerInterface(contractDeployer).registerTemplate(GROUP_TOKEN, 0, tokenInterfaces, tokenLibrary, _tax);
        IContractDeployerInterface(contractDeployer).registerTemplate(GROUP_TOKENOMICS, 0, transferTokenomicsInterfaces, tokenomicsLibrary, 0);
        IContractDeployerInterface(contractDeployer).registerTemplate(GROUP_TOKENOMICS, 1, inflationInterfaces, inflationLibrary, 0);
    }

    function deployToken(TokenLevel level, bytes32 refCode) internal returns (TokenDeployment memory) {
        TokenDeployment memory deployment = TokenDeployment(
            IContractDeployerInterface(contractDeployer).deployTemplate{value: msg.value}(msg.sender, GROUP_TOKEN, 0, bytes(''), refCode),
            IContractDeployerInterface(contractDeployer).deployTemplateWithProxy(msg.sender, GROUP_TOKENOMICS, 0, bytes(''), refCode),
            level >= TokenLevel.InflationAdvanced
                ? IContractDeployerInterface(contractDeployer).deployTemplateWithProxy(msg.sender, GROUP_TOKENOMICS, 1, bytes(''), refCode)
                : address(0),
            level > TokenLevel.Basic
                ? IContractDeployerInterface(contractDeployer).deployTemplateWithProxy(msg.sender, GROUP_TREASURY, 0, bytes(''), refCode)
                : address(0)
        );
        return deployment;
    }

    function initializeTreasury(TokenDeployment memory deployment, uint256 ownerAmount) internal {
        ITreasury(deployment.treasury).initialize(
            deployment.token,
            ownerAmount.div(ownerRewardCycles),
            ownerRewardCycles,
            ownerRewardsReleaseBlocks
        );
        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(deployment.token), deployment.treasury, IERC20Upgradeable(deployment.token).balanceOf(address(this)));
    }

    function initializeInflation(
        TokenDeployment memory deployment, uint256 maxSupply,
        uint256 initialSupplyPercent, uint256 blockPerCycle,
        uint256 rewardRounds
    ) internal {

    }

    function initializeTokenAndTokenomics(
        TokenDeployment memory deployment,
        string calldata name, string calldata ticker,
        uint256 maxSupply,
        uint256 initialSupplyPercent, string calldata metadataUrl
    ) internal {
        ITokenAsAServiceTemplate_v1(deployment.token).initialize(
            name, ticker, deployment.tokenomics, deployment.inflation,
            maxSupply, initialSupplyPercent,
            ownershipNFTCollection,
            mintOwnerToken(metadataUrl)
        );
        ITransferTokenomics_v1(deployment.tokenomics).initialize(deployment.token, rewardsTreasury, deployTokenDefaultTax);
    }
}