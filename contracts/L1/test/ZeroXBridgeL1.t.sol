// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ZeroXBridgeL1} from "../src/ZeroXBridgeL1.sol";
import {MockProofRegistry} from "./mocks/MockProofRegistry.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

// // Test contract for bridge
contract ZeroXBridgeL1Test is Test {
    using ECDSA for bytes32;

    ZeroXBridgeL1 public bridge;
    MockERC20 public dai;
    MockERC20 public usdc;
    address public ethPriceFeed;
    address public daiPriceFeed;
    address public usdcPriceFeed;

    address public owner = address(0x1);
    address public relayer = address(0x4);
    address public nonRelayer = address(0x5);
    address public admin;

    // Proof Generation
    MockProofRegistry public proofRegistry;
    address public user;
    uint256 public amount;
    uint256 public starknetPubKey;
    uint256 public commitmentHash;
    uint256 public ethAccountPrivateKey;
    uint256 public blockHash;

    event RelayerStatusChanged(address indexed relayer, bool status);

    event DepositEvent(
        address indexed token,
        ZeroXBridgeL1.AssetType assetType,
        uint256 amount,
        address indexed user,
        uint256 commitmentHash
    );

    error OwnableUnauthorizedAccount(address account);

    function setUp() public {
        admin = address(0x123);
        proofRegistry = new MockProofRegistry();

        vm.startPrank(owner);
        // Deploy the bridge contract
        bridge = new ZeroXBridgeL1(admin, owner, address(proofRegistry));

        // Setup approved relayer
        bridge.setRelayerStatus(relayer, true);

        vm.stopPrank();

        // Create a dummy commitment hash for tests involving unlock_funds_with_proof
        user = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        amount = 100 ether;
        starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;
        blockHash = 0x0123456;
        commitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, amount, blockHash)));

        // Deploy mock ERC20 tokens
        dai = new MockERC20(18); // DAI with 18 decimals
        usdc = new MockERC20(6); // USDC with 6 decimals

        // Assign mock price feed addresses
        ethPriceFeed = address(1);
        daiPriceFeed = address(2);
        usdcPriceFeed = address(3);

        vm.startPrank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ETH, address(0), ethPriceFeed, 18);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(usdc), usdcPriceFeed, 6);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(dai), daiPriceFeed, 18);

        vm.stopPrank();
    }

    /**
     * Test Case 1: Happy Path - Calculate TVL with ETH and ERC20 tokens
     */
    function testUpdateAssetPricingHappyPath() public {
        // Fund the contract with ETH
        vm.deal(address(bridge), 1 ether); // 1 ETH = 1e18 wei

        // Mint DAI and USDC to the contract
        dai.mint(address(bridge), 1000 * 10 ** 18); // 1000 DAI
        usdc.mint(address(bridge), 500 * 10 ** 6); // 500 USDC

        // Mock Chainlink price feeds (prices in USD with 8 decimals)
        // ETH price: $2000 = 2000 * 10^8
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        // DAI price: $1 = 1 * 10^8
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        // USDC price: $1 = 1 * 10^8
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // Call updateTvl
        bridge.updateTvl();

        // Calculate expected TVL (in USD with 18 decimals)
        // ETH: 1 ETH * $2000 = $2000 = 2000e18
        // DAI: 1000 DAI * $1 = $1000 = 1000e18
        // USDC: 500 USDC * $1 = $500 = 500e18
        // Total TVL = 2000e18 + 1000e18 + 500e18 = 3500e18
        uint256 expectedTvl = 3500 * 10 ** 18;
        assertEq(bridge.tvl(), expectedTvl, "TVL should match expected value");
    }

    /**
     * Test Case 2: Zero Balance - Tokens with zero balance contribute nothing to TVL
     */
    function testUpdateAssetPricingZeroBalance() public {
        // Fund the contract with ETH
        vm.deal(address(bridge), 1 ether); // 1 ETH

        // Mint DAI but not USDC (USDC balance = 0)
        dai.mint(address(bridge), 1000 * 10 ** 18); // 1000 DAI

        // Mock price feeds
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // Call updateTvl
        bridge.updateTvl();

        // Expected TVL: 2000e18 (ETH) + 1000e18 (DAI) + 0 (USDC) = 3000e18
        uint256 expectedTvl = 3000 * 10 ** 18;
        assertEq(bridge.tvl(), expectedTvl, "TVL should exclude zero-balance tokens");
    }

    /**
     * Test Case 3: Missing Price Feed - Reverts if a token lacks a price feed
     */
    function testUpdateAssetPricingMissingPriceFeed() public {
        // Add a token without a price feed
        address tokenWithoutFeed = address(4);

        vm.startPrank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, tokenWithoutFeed, address(0), 18);
        vm.stopPrank();

        // Mock price feeds for existing tokens (ETH, DAI, USDC)
        vm.mockCall(
            address(1), // ethPriceFeed
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            address(2), // daiPriceFeed
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            address(3), // usdcPriceFeed
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // Expect revert with the specific message
        vm.expectRevert("No price feed for token");
        bridge.updateTvl();
    }

    /**
     * Test Case 4: Invalid Price - Reverts if a price feed returns zero or negative
     */
    function testUpdateAssetPricingInvalidPrice() public {
        // Fund the contract to ensure it processes the price feed
        vm.deal(address(bridge), 1 ether);

        // Mock ETH price feed to return 0
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), uint256(0), uint256(0), uint80(0))
        );

        // Expect revert
        vm.expectRevert("Invalid price from feed");
        bridge.updateTvl();
    }

    /**
     * Test Case 5: Empty Supported Tokens - TVL is zero when no tokens are supported
     */
    function testUpdateAssetPricingEmptySupportedTokens() public {
        // Deploy a new bridge with no supported tokens

        vm.startPrank(owner);
        // Deploy the bridge contract
        ZeroXBridgeL1 newbridge = new ZeroXBridgeL1(admin, owner, address(proofRegistry));
        vm.stopPrank();

        // Call updateTvl
        newbridge.updateTvl();

        // TVL should be 0
        assertEq(newbridge.tvl(), 0, "TVL should be zero with no supported tokens");
    }

    function testRegisterToken() public {
        address tokenPriceFeed = address(5);
        MockERC20 token = new MockERC20(18); // 18 decimals

        vm.prank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token), tokenPriceFeed, 18);

        ZeroXBridgeL1.TokenAssetData memory assetData =
            bridge.getTokenData(ZeroXBridgeL1.AssetType.ERC20, address(token));

        assertEq(uint256(assetData.assetType), uint256(ZeroXBridgeL1.AssetType.ERC20));
        assertEq(assetData.tokenAddress, address(token));
        assertTrue(assetData.isRegistered);
    }

    function testDuplicateAssetPrevention() public {
        address tokenPriceFeed = address(5);
        MockERC20 token = new MockERC20(18); // 18 decimal

        vm.prank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token), tokenPriceFeed, 18);

        // Try to register same token again
        vm.prank(admin);
        vm.expectRevert("Token already registered");
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token), tokenPriceFeed, 18);
    }

    function registerUser(address _user, uint256 _starknetPubKey, uint256 _ethAccountPrivateKey) internal {
        bytes32 digest = keccak256(abi.encodePacked("UserRegistration", _user, starknetPubKey));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_ethAccountPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bridge.registerUser(signature, _starknetPubKey);
    }

    function testRegisterUser() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);
    }

    // Test depositAsset functionality
    function testSuccessfulETHDeposit() public {
        uint256 depositAmount = 1 ether;

        vm.deal(user, depositAmount);

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        uint256 ethPrice = 2000; // 2000 USD

        // Mock price feeds
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(ethPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        uint256 usdValue = depositAmount * ethPrice * 1e18 / 1e18;

        uint256 expectedCommitmentHash = uint256(
            keccak256(
                abi.encodePacked(
                    starknetPubKey,
                    usdValue,
                    uint256(0), // nonce is 0 for first deposit
                    block.timestamp
                )
            )
        );

        // Make the deposit as user1
        vm.prank(user);
        uint256 returnedHash =
            bridge.depositAsset{value: depositAmount}(ZeroXBridgeL1.AssetType.ETH, address(0), depositAmount, user);

        // Verify the correct hash was returned
        assertEq(returnedHash, expectedCommitmentHash, "Commitment hash should match expected");

        // Verify token transfer happened correctly
        assertEq(address(bridge).balance, depositAmount);

        // Verify deposit tracking
        assertEq(bridge.userDeposits(address(0), user), depositAmount, "User deposit should be tracked");

        // Verify nonce was incremented
        assertEq(bridge.nextDepositNonce(user), 1, "Nonce should be incremented");
    }

    function testSuccessfulERC20Deposit() public {
        uint256 depositAmount = 100 * 10 ** 18; // 100 tokens with 18 decimals

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Mint tokens to user1
        dai.mint(user, depositAmount);

        vm.prank(user);
        dai.approve(address(bridge), depositAmount);

        uint256 daiPrice = 1; // 1 USD

        // Mock price feeds
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(daiPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        uint256 usdValue = depositAmount * daiPrice * 1e18 / 1e18;

        uint256 expectedCommitmentHash = uint256(
            keccak256(
                abi.encodePacked(
                    starknetPubKey,
                    usdValue,
                    uint256(0), // nonce is 0 for first deposit
                    block.timestamp
                )
            )
        );

        vm.prank(user);
        uint256 commitmentHash_ = bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(dai), depositAmount, user);

        assertEq(commitmentHash_, expectedCommitmentHash);
        assertEq(bridge.userDeposits(address(dai), user), depositAmount);
        assertEq(bridge.nextDepositNonce(user), 1);
    }

    function testMultipleDepositsIncrementNonce() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        uint256 depositAmount = 100 * 10 ** 18;

        // Mint some tokens to user1
        usdc.mint(user, depositAmount * 2);

        // Approve the bridge to spend user1's tokens
        vm.prank(user);
        usdc.approve(address(bridge), depositAmount * 2);

        uint256 usdcPrice = 1; // 1 USD

        // Mock price feeds
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(usdcPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // First deposit
        vm.prank(user);
        uint256 hash1 = bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(usdc), depositAmount, user);

        // Mock price feeds
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(usdcPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // Second deposit
        vm.prank(user);
        uint256 hash2 = bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(usdc), depositAmount, user);

        // Verify hashes are different due to different nonces
        assertTrue(hash1 != hash2, "Commitment hashes should be different");

        // Verify nonce was incremented twice
        assertEq(bridge.nextDepositNonce(user), 2, "Nonce should be incremented twice");

        // Verify deposit tracking accumulates
        assertEq(bridge.userDeposits(address(usdc), user), depositAmount * 2, "User deposits should accumulate");
    }

    function testCannotDepositZeroAmount() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Attempt deposit with zero amount should fail
        vm.prank(user);
        vm.expectRevert("ZeroXBridge: Amount must be greater than zero");
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(usdc), 0, user);
    }

    function testCannotDepositToZeroAddress() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        uint256 depositAmount = 100 * 10 ** 18;

        // Mint some tokens to user1
        usdc.mint(user, depositAmount);

        // Approve the bridge to spend user1's tokens
        vm.prank(user);
        usdc.approve(address(bridge), depositAmount);

        // Attempt deposit to zero address should fail
        vm.prank(user);
        vm.expectRevert("ZeroXBridge: Invalid user address");
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(usdc), depositAmount, address(0));
    }

    function testETHDepositEvent() public {
        uint256 depositAmount = 1 ether;
        vm.deal(user, depositAmount);

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        uint256 ethPrice = 2000; // 2000 USD

        // Mock price feeds
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(ethPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        uint256 usdValue = depositAmount * ethPrice * 1e18 / 1e18;

        uint256 expectedCommitmentHash = uint256(
            keccak256(
                abi.encodePacked(
                    starknetPubKey,
                    usdValue,
                    uint256(0), // nonce is 0 for first deposit
                    block.timestamp
                )
            )
        );

        vm.expectEmit(true, true, true, true);
        emit DepositEvent(address(0), ZeroXBridgeL1.AssetType.ETH, usdValue, user, expectedCommitmentHash);

        vm.prank(user);
        bridge.depositAsset{value: depositAmount}(ZeroXBridgeL1.AssetType.ETH, address(0), depositAmount, user);
    }

    function testERC20DepositEvent() public {
        uint256 depositAmount = 100 * 10 ** 18;
        dai.mint(user, depositAmount);

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        vm.prank(user);
        dai.approve(address(bridge), depositAmount);

        uint256 daiPrice = 1; // 2000 USD

        // Mock price feeds
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(daiPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        uint256 usdValue = depositAmount * daiPrice * 1e18 / 1e18;

        uint256 expectedCommitmentHash = uint256(
            keccak256(
                abi.encodePacked(
                    starknetPubKey,
                    usdValue,
                    uint256(0), // nonce is 0 for first deposit
                    block.timestamp
                )
            )
        );

        vm.expectEmit(true, true, true, true);
        emit DepositEvent(address(dai), ZeroXBridgeL1.AssetType.ERC20, usdValue, user, expectedCommitmentHash);

        vm.prank(user);
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(dai), depositAmount, user);
    }

    // tests for verifyStarknetSignature
    function testVerifyValidSignature() public view {
        uint256 messageHash = 0x026b4b17ca6a97b0d61f441e828472022c7bec1258d488482a0a1b412c214e86;
        uint256 r = 0x0293aba5e527bd515cca1175f2b7ed1b1ad5244db2fe780dd278561f9492ac19;
        uint256 s = 0x075dd20d8743e6b359ef71ace06dab5934e56dac865fc586c2227b9304a273cb;
        bytes memory sig = abi.encodePacked(bytes32(r), bytes32(s));
        uint256 pubKeyX = 0x03f25ebd3224d52135bfb04a12713f3e3103cc25e82f0dc583177289f45a39cf;
        // uint256 pubKeyY = 0x017d8924fe415ba698958688fc37f5c60a28067ceb4dbe76107be46c871b3397;

        // Call the function
        bool isValid = bridge.verifyStarknetSignature(messageHash, sig, pubKeyX);
        assertTrue(isValid, "Valid signature should pass");
    }

    function testInvalidSignature() public view {
        uint256 messageHash = 0x033af3ab8b38079b8ebb228c3eb9e88ac65de29a2ae64bc90886baefeaa6b5ff;
        // Invalid r (altered from valid)
        uint256 r = 0x0534db24ad670b37d5bf34e583ea1c729fcf5c5928cb19bc707ee5994ffba230;
        uint256 s = 0x07cfdcd06bc17ca67dc0b8d48c1065d0e746dcfb06fdbd96f2ea7473930617a7;
        bytes memory sig = abi.encodePacked(bytes32(r), bytes32(s));
        uint256 pubKeyX = 0x03f25ebd3224d52135bfb04a12713f3e3103cc25e82f0dc583177289f45a39cf;
        // uint256 pubKeyY = 0x017d8924fe415ba698958688fc37f5c60a28067ceb4dbe76107be46c871b3397;

        bool isValid = bridge.verifyStarknetSignature(messageHash, sig, pubKeyX);
        assertFalse(isValid, "Invalid signature should fail");
    }

    function testInvalidPublicKey() public {
        uint256 messageHash = 0x033af3ab8b38079b8ebb228c3eb9e88ac65de29a2ae64bc90886baefeaa6b5ff;
        uint256 r = 0x0504db24ad670b37d5bf34e583ea1c729fcf5c5928cb19bc707ee5994ffba229;
        uint256 s = 0x07cfdcd06bc17ca67dc0b8d48c1065d0e746dcfb06fdbd96f2ea7473930617a7;
        bytes memory sig = abi.encodePacked(bytes32(r), bytes32(s));
        // Invalid public key (not on curve)
        uint256 pubKeyX = 0;

        vm.expectRevert("ZeroXBridge: Invalid Starknet public key");
        bridge.verifyStarknetSignature(messageHash, sig, pubKeyX);
    }

    function testSetRelayerStatus() public {
        vm.startPrank(owner);

        // Test adding a relayer
        vm.expectEmit(true, true, true, true);
        emit RelayerStatusChanged(user, true);
        bridge.setRelayerStatus(user, true);
        assertTrue(bridge.approvedRelayers(user));

        // Test removing a relayer
        vm.expectEmit(true, true, true, true);
        emit RelayerStatusChanged(user, false);
        bridge.setRelayerStatus(user, false);
        assertFalse(bridge.approvedRelayers(user));

        vm.stopPrank();
    }

    function testOwnership() public view {
        assertEq(bridge.owner(), owner);
    }

    function test_RevertWhen_NonOwnerCallsRestrictedFunctions() public {
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        bridge.setRelayerStatus(relayer, false);

        vm.stopPrank();
    }
}
