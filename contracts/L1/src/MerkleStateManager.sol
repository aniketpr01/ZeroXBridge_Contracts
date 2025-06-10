// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MerkleStateManager
 * @dev Manages deposit commitments and synced withdrawal roots for ZeroXBridge protocol
 * @notice Compatible with Alexandria Merkle Trees using deterministic leaf ordering and proper tree construction
 */
contract MerkleStateManager is Ownable, Pausable, ReentrancyGuard {
    // Debug events
    event DebugProofVerification(uint256 leafIndex, bytes32 computedHash, bytes32 expectedRoot, bool isValid);

    using MerkleProof for bytes32[];

    bytes32 public depositRoot;
    bytes32 public withdrawalRoot;
    uint256 public depositRootIndex;
    uint256 public withdrawalRootIndex;

    // Storage for intermediate tree nodes to optimize proof generation
    // Indexed by [level][position] for efficient retrieval
    mapping(uint256 => mapping(uint256 => bytes32)) public treeNodes;
    uint256 public depositTreeDepth;
    uint256 public depositLeafCount;

    mapping(uint256 => bytes32) public depositRootHistory;
    mapping(uint256 => bytes32) public withdrawalRootHistory;
    mapping(uint256 => uint256) public depositRootTimestamps;
    mapping(uint256 => uint256) public withdrawalRootTimestamps;
    mapping(address => bool) public approvedRelayers;
    mapping(bytes32 => bool) public processedCommitments;
    mapping(bytes32 => uint256) public commitmentToLeafIndex;
    bytes32[] public leaves;
    mapping(uint256 => bytes32) public merkleTree;
    mapping(address => uint256) public lastOperationTime;
    mapping(address => uint256) public operationCount;
    uint256 private constant RATE_LIMIT_WINDOW = 15 seconds;
    uint256 private constant MAX_OPERATIONS_PER_WINDOW = 10;
    uint256 public constant MAX_TREE_DEPTH = 32;
    uint256 public constant MAX_LEAF_COUNT = 2 ** 32 - 1;

    event DepositRootUpdated(
        uint256 indexed index,
        bytes32 newRoot,
        bytes32 indexed commitment,
        uint256 leafIndex,
        uint256 timestamp,
        uint256 blockNumber
    );

    event WithdrawalRootSynced(
        uint256 indexed index, bytes32 newRoot, address indexed relayer, uint256 timestamp, uint256 blockNumber
    );

    event RelayerStatusChanged(address indexed relayer, bool status);
    event CommitmentProcessed(bytes32 indexed commitment, uint256 leafIndex);
    event EmergencyPause(address indexed admin, string reason);
    event EmergencyUnpause(address indexed admin);

    /**
     * @dev Constructor initializes the contract with genesis roots
     * @param initialOwner The initial owner of the contract
     * @param genesisDepositRoot The initial deposit root
     * @param genesisWithdrawalRoot The initial withdrawal root
     */
    constructor(address initialOwner, bytes32 genesisDepositRoot, bytes32 genesisWithdrawalRoot)
        Ownable(initialOwner)
    {
        require(initialOwner != address(0), "MerkleStateManager: Invalid owner");
        require(genesisDepositRoot != bytes32(0), "MerkleStateManager: Invalid genesis deposit root");
        require(genesisWithdrawalRoot != bytes32(0), "MerkleStateManager: Invalid genesis withdrawal root");

        depositRoot = genesisDepositRoot;
        withdrawalRoot = genesisWithdrawalRoot;
        depositRootHistory[0] = genesisDepositRoot;
        withdrawalRootHistory[0] = genesisWithdrawalRoot;
        depositRootTimestamps[0] = block.timestamp;
        withdrawalRootTimestamps[0] = block.timestamp;
    }

    // Using OpenZeppelin's built-in whenNotPaused modifier instead of custom implementation

    /**
     * @dev Modifier to check rate limiting
     */
    modifier rateLimited() {
        _checkRateLimit();
        _;
        _updateRateLimit();
    }

    /**
     * @dev Modifier to ensure only approved relayers can call certain functions
     */
    modifier onlyRelayer() {
        require(approvedRelayers[msg.sender], "MerkleStateManager: Only approved relayers");
        _;
    }

    /**
     * @dev Updates deposit root from a new commitment using Alexandria tree structure
     * @param commitment The commitment hash to add to the tree
     */
    function updateDepositRootFromCommitment(bytes32 commitment) external whenNotPaused nonReentrant rateLimited {
        require(commitment != bytes32(0), "MerkleStateManager: Invalid commitment");
        require(!processedCommitments[commitment], "MerkleStateManager: Commitment already processed");
        require(depositLeafCount < MAX_LEAF_COUNT, "MerkleStateManager: Tree capacity exceeded");

        processedCommitments[commitment] = true;
        uint256 leafIndex = depositLeafCount;
        commitmentToLeafIndex[commitment] = leafIndex;
        leaves.push(commitment);
        bytes32 newRoot = _calculateNewDepositRoot(commitment);
        depositRoot = newRoot;
        depositRootIndex++;
        depositLeafCount++;
        uint256 newDepth = _calculateTreeDepth(depositLeafCount);
        if (newDepth > depositTreeDepth) {
            depositTreeDepth = newDepth;
        }
        depositRootHistory[depositRootIndex] = newRoot;
        depositRootTimestamps[depositRootIndex] = block.timestamp;

        emit CommitmentProcessed(commitment, leafIndex);
        emit DepositRootUpdated(depositRootIndex, newRoot, commitment, leafIndex, block.timestamp, block.number);
    }

    /**
     * @dev Batch update deposit roots for efficiency
     * @param commitments Array of commitments to process
     */
    function batchUpdateDepositRoots(bytes32[] calldata commitments) external whenNotPaused nonReentrant rateLimited {
        require(commitments.length > 0 && commitments.length <= 100, "MerkleStateManager: Invalid batch size");
        require(depositLeafCount + commitments.length <= MAX_LEAF_COUNT, "MerkleStateManager: Batch exceeds capacity");
        uint256 startLeafIndex = depositLeafCount;
        for (uint256 i = 0; i < commitments.length; i++) {
            bytes32 commitment = commitments[i];
            require(commitment != bytes32(0), "MerkleStateManager: Invalid commitment in batch");
            require(!processedCommitments[commitment], "MerkleStateManager: Duplicate commitment in batch");
            processedCommitments[commitment] = true;
            commitmentToLeafIndex[commitment] = startLeafIndex + i;
            leaves.push(commitment);
            emit CommitmentProcessed(commitment, startLeafIndex + i);
        }

        // Update leaf count
        depositLeafCount += commitments.length;

        // Calculate new root for the entire batch
        bytes32 newRoot = _recalculateDepositRoot();

        depositRoot = newRoot;
        depositRootIndex++;
        uint256 newDepth = _calculateTreeDepth(depositLeafCount);
        if (newDepth > depositTreeDepth) {
            depositTreeDepth = newDepth;
        }
        depositRootHistory[depositRootIndex] = newRoot;
        depositRootTimestamps[depositRootIndex] = block.timestamp;
        emit DepositRootUpdated(
            depositRootIndex,
            newRoot,
            commitments[0], // First commitment as reference
            startLeafIndex,
            block.timestamp,
            block.number
        );
    }

    /**
     * @dev Syncs withdrawal root from L2
     * @param newRoot The new withdrawal root from L2
     */
    function syncWithdrawalRootFromL2(bytes32 newRoot) external whenNotPaused nonReentrant onlyRelayer rateLimited {
        require(newRoot != bytes32(0), "MerkleStateManager: Invalid root");
        require(newRoot != withdrawalRoot, "MerkleStateManager: Root unchanged");
        withdrawalRoot = newRoot;
        withdrawalRootIndex++;
        withdrawalRootHistory[withdrawalRootIndex] = newRoot;
        withdrawalRootTimestamps[withdrawalRootIndex] = block.timestamp;

        emit WithdrawalRootSynced(withdrawalRootIndex, newRoot, msg.sender, block.timestamp, block.number);
    }

    /**
     * @dev Manages relayer approval status
     * @param relayer The relayer address
     * @param status The approval status
     */
    function setRelayerStatus(address relayer, bool status) external onlyOwner {
        require(relayer != address(0), "MerkleStateManager: Invalid relayer address");
        approvedRelayers[relayer] = status;
        emit RelayerStatusChanged(relayer, status);
    }

    /**
     * @dev Emergency pause function
     * @param reason The reason for pausing
     */
    function emergencyPause(string calldata reason) external onlyOwner {
        _pause();
        emit EmergencyPause(msg.sender, reason);
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpause(msg.sender);
    }

    /**
     * @dev Verifies a withdrawal proof against the current withdrawal root
     * @param leaf The leaf to verify
     * @param proof The Merkle proof
     * @return True if the proof is valid
     */
    function verifyWithdrawalProof(bytes32 leaf, bytes32[] calldata proof) external view returns (bool) {
        return MerkleProof.verify(proof, withdrawalRoot, leaf);
    }

    /**
     * @dev Verifies a deposit proof
     * @param leaf The leaf to verify
     * @param leafIndex The index of the leaf
     * @param proof The Merkle proof
     * @return Whether the proof is valid
     */
    function verifyDepositProof(bytes32 leaf, uint256 leafIndex, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        if (leafIndex >= depositLeafCount) {
            return false;
        }

        bytes32 computedHash = leaf;
        uint256 currentIndex = leafIndex;
        uint256 currentLevelNodes = depositLeafCount;

        for (uint256 i = 0; i < proof.length; i++) {
            // Check if this is the last node at this level and it's odd
            bool isLastNodeInOddLevel = (currentIndex == currentLevelNodes - 1) && (currentLevelNodes % 2 == 1);

            if (isLastNodeInOddLevel) {
                // For the last node in an odd level, it's duplicated
                // The node is just passed up to the next level without hashing
                // No need to use the proof element for this level
            } else {
                // Normal case - use the provided proof element
                bytes32 proofElement = proof[i];
                if (currentIndex % 2 == 0) {
                    // Current node is a left child
                    computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
                } else {
                    // Current node is a right child
                    computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
                }
            }

            // Update for next level
            currentIndex = currentIndex / 2;
            currentLevelNodes = (currentLevelNodes + 1) / 2; // Calculate nodes at next level
        }

        return computedHash == depositRoot;
    }

    /**
     * @dev Gets the Merkle proof for a deposit at a specific index
     * @param leafIndex The index of the leaf
     * @return The Merkle proof
     */
    function getDepositProof(uint256 leafIndex) external view returns (bytes32[] memory) {
        require(leafIndex < depositLeafCount, "MerkleStateManager: Invalid leaf index");

        return _generateMerkleProof(leafIndex);
    }

    /**
     * @dev Gets deposit tree information
     * @return depth The current tree depth
     * @return leafCount The current leaf count
     * @return root The current deposit root
     */
    function getDepositTreeInfo() external view returns (uint256 depth, uint256 leafCount, bytes32 root) {
        return (depositTreeDepth, depositLeafCount, depositRoot);
    }

    /**
     * @dev Gets withdrawal tree information
     * @return index The current withdrawal root index
     * @return root The current withdrawal root
     */
    function getWithdrawalTreeInfo() external view returns (uint256 index, bytes32 root) {
        return (withdrawalRootIndex, withdrawalRoot);
    }

    /**
     * @dev Calculates new deposit root using Alexandria tree construction
     * @param newCommitment The new commitment to add
     * @return The new Merkle root
     */
    function _calculateNewDepositRoot(bytes32 newCommitment) internal returns (bytes32) {
        uint256 newLeafCount = depositLeafCount + 1;
        bytes32[] memory updatedLeaves = new bytes32[](newLeafCount);

        // Copy existing leaves
        for (uint256 i = 0; i < depositLeafCount; i++) {
            updatedLeaves[i] = leaves[i];
        }

        // Add new leaf
        updatedLeaves[depositLeafCount] = newCommitment;

        // Calculate new root and store intermediate nodes
        return _calculateMerkleRoot(updatedLeaves);
    }

    /**
     * @dev Recalculates the entire deposit root from current leaves
     * @return The calculated Merkle root
     */
    function _recalculateDepositRoot() internal returns (bytes32) {
        return _calculateMerkleRoot(leaves);
    }

    /**
     * @dev Optimized Merkle root calculation using Alexandria-style approach
     * @param leafArray The array of leaves
     * @return The calculated Merkle root
     */
    function _calculateMerkleRoot(bytes32[] memory leafArray) internal returns (bytes32) {
        uint256 n = leafArray.length;
        if (n == 0) return bytes32(0);
        if (n == 1) return leafArray[0];

        // Create a working array that we'll use to build the tree
        uint256 maxSize = 2 * n; // Allocate enough space for all levels
        bytes32[] memory nodes = new bytes32[](maxSize);

        // Copy leaves to the nodes array and store in treeNodes
        for (uint256 i = 0; i < n; i++) {
            nodes[i] = leafArray[i];
            treeNodes[0][i] = leafArray[i];
        }

        // Start building the tree level by level
        uint256 levelSize = n;
        uint256 level = 0;

        while (levelSize > 1) {
            uint256 nextLevelSize = (levelSize + 1) / 2; // Ceiling division for odd numbers

            // Process pairs of nodes
            for (uint256 i = 0; i < levelSize / 2; i++) {
                bytes32 left = nodes[i * 2];
                bytes32 right = nodes[i * 2 + 1];
                nodes[n + i] = keccak256(abi.encodePacked(left, right));
                treeNodes[level + 1][i] = nodes[n + i]; // Store intermediate nodes
            }

            // Handle odd node at the end if present
            if (levelSize % 2 == 1) {
                // Duplicate the last node
                nodes[n + levelSize / 2] = nodes[levelSize - 1];
                treeNodes[level + 1][levelSize / 2] = nodes[levelSize - 1];
            }

            // Copy the next level back to the beginning of our working array
            for (uint256 i = 0; i < nextLevelSize; i++) {
                nodes[i] = nodes[n + i];
            }

            levelSize = nextLevelSize;
            level++;
        }

        return nodes[0]; // Root is at index 0 after the final iteration
    }

    /**
     * @dev Calculate next power of 2 for deterministic tree structure
     */
    function _nextPowerOfTwo(uint256 n) internal pure returns (uint256) {
        if (n <= 1) return 1;
        uint256 power = 1;
        while (power < n) {
            power <<= 1;
        }
        return power;
    }

    /**
     * @dev Optimized proof generation using stored intermediate nodes
     * @param leafIndex The index of the leaf
     * @return The Merkle proof
     */
    function _generateMerkleProof(uint256 leafIndex) internal view returns (bytes32[] memory) {
        if (depositLeafCount <= 1) {
            return new bytes32[](0);
        }

        uint256 treeDepth = _getTreeDepth(depositLeafCount);
        bytes32[] memory proof = new bytes32[](treeDepth);
        uint256 currentIndex = leafIndex;
        uint256 currentLevelNodes = depositLeafCount;

        for (uint256 level = 0; level < treeDepth; level++) {
            // Check if this is the last node at an odd-numbered level
            bool isLastNodeInOddLevel = (currentIndex == currentLevelNodes - 1) && (currentLevelNodes % 2 == 1);

            if (isLastNodeInOddLevel) {
                // For the last node in an odd level, we should use the node itself as the proof element
                // This is because when verifying, we'll pair the node with itself
                bytes32 nodeValue;
                if (level == 0) {
                    // At level 0, use the leaf directly
                    nodeValue = leaves[currentIndex];
                } else if (treeNodes[level][currentIndex] != bytes32(0)) {
                    nodeValue = treeNodes[level][currentIndex];
                } else {
                    nodeValue = _calculateNodeHash(level, currentIndex);
                }
                proof[level] = nodeValue;
            } else {
                // Normal case: get the sibling node
                uint256 siblingIndex = currentIndex ^ 1; // XOR with 1 to get sibling index
                bytes32 siblingNode;
                if (level == 0) {
                    // At level 0, use the leaf directly
                    siblingNode = leaves[siblingIndex];
                } else if (treeNodes[level][siblingIndex] != bytes32(0)) {
                    siblingNode = treeNodes[level][siblingIndex];
                } else {
                    siblingNode = _calculateNodeHash(level, siblingIndex);
                }
                proof[level] = siblingNode;
            }

            // Move to parent index for next level
            currentIndex = currentIndex / 2;
            currentLevelNodes = (currentLevelNodes + 1) / 2; // Calculate nodes at next level
        }

        return proof;
    }

    /**
     * @dev Calculate log2 of a number
     */
    function _log2(uint256 n) internal pure returns (uint256) {
        uint256 result = 0;
        while (n > 1) {
            n >>= 1;
            result++;
        }
        return result;
    }

    /**
     * @dev Calculate the tree depth based on the number of leaves
     */
    function _getTreeDepth(uint256 leafCount) internal pure returns (uint256) {
        if (leafCount <= 1) return 0;
        return _log2(_nextPowerOfTwo(leafCount));
    }

    /**
     * @dev Calculate a node hash recursively if not stored
     * @param level The tree level of the node
     * @param index The index of the node at that level
     * @return The hash of the node
     */
    function _calculateNodeHash(uint256 level, uint256 index) internal view returns (bytes32) {
        // If we're at leaf level (level 0), return the leaf or zero if out of bounds
        if (level == 0) {
            if (index < depositLeafCount) {
                return leaves[index];
            } else {
                return bytes32(0);
            }
        }

        // Calculate the number of nodes at the child level
        uint256 childLevel = level - 1;
        uint256 nodesAtChildLevel;

        if (childLevel == 0) {
            // At leaf level, it's the number of leaves
            nodesAtChildLevel = depositLeafCount;
        } else {
            // For higher levels, calculate based on the number of nodes at the level below
            uint256 leavesNeeded = depositLeafCount;
            for (uint256 i = 0; i < childLevel; i++) {
                leavesNeeded = (leavesNeeded + 1) / 2;
            }
            nodesAtChildLevel = leavesNeeded;
        }

        // Calculate child indices
        uint256 leftChildIndex = index * 2;
        uint256 rightChildIndex = leftChildIndex + 1;

        // Get left child (from storage or calculate)
        bytes32 leftChild;
        if (leftChildIndex < nodesAtChildLevel) {
            if (treeNodes[childLevel][leftChildIndex] != bytes32(0)) {
                leftChild = treeNodes[childLevel][leftChildIndex];
            } else {
                leftChild = _calculateNodeHash(childLevel, leftChildIndex);
            }
        } else {
            return bytes32(0); // Out of bounds
        }

        // Handle odd number of nodes at child level
        if (rightChildIndex >= nodesAtChildLevel) {
            // If this is the last node at this level and there are odd nodes below,
            // duplicate the left child
            return leftChild;
        }

        // Get right child (from storage or calculate)
        bytes32 rightChild;
        if (treeNodes[childLevel][rightChildIndex] != bytes32(0)) {
            rightChild = treeNodes[childLevel][rightChildIndex];
        } else {
            rightChild = _calculateNodeHash(childLevel, rightChildIndex);
        }

        // Hash the children together to get the parent
        return keccak256(abi.encodePacked(leftChild, rightChild));
    }

    /**
     * @dev Calculates the depth needed for a tree with given leaf count
     * @param leafCount The number of leaves
     * @return The required tree depth
     */
    function _calculateTreeDepth(uint256 leafCount) internal pure returns (uint256) {
        if (leafCount <= 1) return leafCount;
        uint256 depth = 0;
        uint256 temp = leafCount - 1;
        while (temp > 0) {
            temp >>= 1;
            depth++;
        }
        return depth;
    }

    /**
     * @dev Checks rate limiting for the caller
     */
    function _checkRateLimit() internal view {
        uint256 currentTime = block.timestamp;
        uint256 lastTime = lastOperationTime[msg.sender];
        if (currentTime < lastTime + RATE_LIMIT_WINDOW) {
            require(operationCount[msg.sender] < MAX_OPERATIONS_PER_WINDOW, "MerkleStateManager: Rate limit exceeded");
        }
    }

    /**
     * @dev Updates rate limiting state for the caller
     */
    function _updateRateLimit() internal {
        uint256 currentTime = block.timestamp;
        uint256 lastTime = lastOperationTime[msg.sender];
        if (currentTime >= lastTime + RATE_LIMIT_WINDOW) {
            operationCount[msg.sender] = 1;
            lastOperationTime[msg.sender] = currentTime;
        } else {
            operationCount[msg.sender]++;
        }
    }
}
