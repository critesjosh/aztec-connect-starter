// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity >=0.6.6 <0.8.0;
pragma experimental ABIEncoderV2;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { GebProxyActions } from "./GebProxyActions.sol";
import { GebSafeManager } from "./GebSafeManager.sol";
import { GebProxyRegistry } from "./GebProxyRegistry.sol";

import { IDefiBridge } from "./interfaces/IDefiBridge.sol";
import { Types } from "./Types.sol";

// import 'hardhat/console.sol';

contract ReflexerBridge is IDefiBridge {
  using SafeMath for uint256;

  address public immutable rollupProcessor;
  address public taxCollector;
  address public ethJoin;
  address public coinJoin;
  bytes32 public collateralType;

  address public RAI_ADDRESS;
  address public SAFE_ENGINE;

  address public gebProxyRegistry;
  address public gebSafeManager;
  mapping (uint256 => Safe) safes;

  struct Safe {
    uint256 safeId;
    GebProxyActions gebProxy;
  }

// https://docs.reflexer.finance/currently-deployed-systems
// proxy factory : 0xA26e15C895EFc0616177B7c1e7270A4C7D51C997
// proxy registry: 0x4678f0a6958e4D2Bc4F1BAF7Bc52E8F3564f3fE4
// tax collector: 0xcDB05aEda142a1B0D6044C09C64e4226c1a281EB
// eth_join: 0x2D3cD7b81c93f188F3CB8aD87c8Acc73d6226e3A
// RAI_ADDRESS: 0x03ab458634910aad20ef5f1c8ee96f1d6ac54919
// SAFE_ENGONE: 0xCC88a9d330da1133Df3A7bD823B95e52511A6962

  constructor(
        address _rollupProcessor,
        address _gebSafeManager, 
        address _proxyRegistry, 
        address _taxCollector,
        address _ethJoin,
        address _coinJoin,
        bytes32 _collateralType,
        address _safeEngine
    ) 
    public {
        rollupProcessor = _rollupProcessor;
        gebSafeManager = _gebSafeManager;
        gebProxyRegistry = _proxyRegistry;
        taxCollector = _taxCollector;
        ethJoin = _ethJoin;
        coinJoin = _coinJoin;
        collateralType = _collateralType;
        SAFE_ENGINE = _safeEngine;
  }

  receive() external payable {}

  /// @notice Opens Safe, locks Eth, generates debt and sends COIN amount (deltaWad) to msg.sender
  /// @param inputAssetA is the amount of ETH sent to the Safe
  /// @param outputAssetA is the amount of RAI sent to the rollup processor
  /// @param outputAssetB is a VIRTUAL asset representing the depositors collateral amount in the Safe
  /// @param inputValue is the amount of ETH collateral sent to the Safe
  /// @param auxData is the deltaWad (RAI amount issued)
  function convert(
    Types.AztecAsset calldata inputAssetA,
    Types.AztecAsset calldata inputAssetB,
    Types.AztecAsset calldata outputAssetA,
    Types.AztecAsset calldata outputAssetB,
    uint256 inputValue,
    uint256 interactionNonce,
    uint64 auxData
  )
    external
    payable
    override
    returns (
      uint256 outputValueA,
      uint256 outputValueB,
      bool isAsync
    )
  {
    require(msg.sender == rollupProcessor, "ReflexerBridge: INVALID_CALLER");

    require(inputAssetA.assetType == Types.AztecAssetType.ETH, "ReflexerBridge: must input ETH");
    require(outputAssetA.assetType == Types.AztecAssetType.ERC20, "ReflexerBridge: must output RAI");
    require(outputAssetB.assetType == Types.AztecAssetType.VIRTUAL, "ReflexerBridge: must output VIRTUAL");

    isAsync = false;

    GebProxyActions gebProxy = GebProxyActions(GebProxyRegistry(gebProxyRegistry).build());
    uint256 safe = gebProxy.openLockETHAndGenerateDebt(gebSafeManager, taxCollector, ethJoin, coinJoin, collateralType, auxData);
    safes[interactionNonce] = Safe({safeId: safe, gebProxy: gebProxy});
    outputValueA = auxData;
    outputValueB = inputValue;
  }

  /// @notice locks Eth and sends VIRTUAL tokens to depositor
  /// @param inputAssetA is ETH locked into the Safe
  /// @param outputAssetA is more VIRTUAL assets representing locked collateral in the Safe
  function lockETH(
    Types.AztecAsset calldata inputAssetA,
    Types.AztecAsset calldata,
    Types.AztecAsset calldata outputAssetA,
    Types.AztecAsset calldata,
    uint256 interactionNonce,
    uint64 auxData
  ) 
    external 
    payable 
  {
    Safe memory safe = safes[interactionNonce];
    safe.gebProxy.lockETH(gebSafeManager, ethJoin, safe.safeId);
    outputAssetA = inputAssetA;
  }

  function canFinalise(
    uint256 /*interactionNonce*/
  ) external view override returns (bool) {
    return true;
  }
  
// DO NOT USE THIS FUNCTION, REFACTOR REQUIRED

  /// @notice accepts RAI and virtual position tokens in return for underlying ETH collateral
  /// @param inputAssetA is RAI sent
  /// @param inputAssetB is the VIRTUAL asset representing the depositors collateral amount in the Safe
  /// @param outputAssetA is the amount of ETH returned from the Safe
  function finalise(
    Types.AztecAsset calldata inputAssetA,
    Types.AztecAsset calldata inputAssetB,
    Types.AztecAsset calldata outputAssetA,
    Types.AztecAsset calldata,
    uint256 interactionNonce,
    uint64
  ) external payable override returns (uint256 outputValueA, uint256) {
    require(msg.sender == rollupProcessor, "ReflexerBridge: INVALID_CALLER"); 
    require(inputAssetA.erc20Address == RAI_ADDRESS, "ReflexerBridge: must input RAI"); 
    require(inputAssetB.id == interactionNonce, "ReflexerBridge: must input correct VIRTUAL assets");
    require(outputAssetA.assetType == Types.AztecAssetType.ETH, "ReflexerBridge: must output ETH");
    
    Safe memory safe = safes[interactionNonce];

    // EngineSafe engineSafe = SafeEngineLike(SAFE_ENGINE).safes[bytes32(safe.safeId)][rollupProcessor];

    // check that the amount of RAI being sent is the correct amount for the amount of ETH being returned
    // will fail if not enough RAI is being sent
    // sender can't request more ETH than they have claim to with the VIRTUAL tokens.
    safe.gebProxy.repayDebtAndFreeETH(gebSafeManager, ethJoin, coinJoin, safe.safeId, inputAssetB.amount, inputAssetA.amount);

    outputValueA = inputAssetB;
  }
}
