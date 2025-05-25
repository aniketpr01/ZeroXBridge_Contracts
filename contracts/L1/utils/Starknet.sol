// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ElipticCurve.sol";

abstract contract Starknet {
    //Starknet curve constants
    uint256 private constant K_BETA = 3141592653589793238462643383279502884197169399375105820974944592307816406665;
    uint256 private constant K_MODULUS = 0x800000000000011000000000000000000000000000000000000000000000001;
    // Full Stark Curve parameters
    uint256 private constant STARK_ALPHA = 1;
    uint256 private constant STARK_N = 0x800000000000010fffffffffffffffffffffffffffffffffffffffffffffffb;
    uint256 private constant STARK_GX = 0x1ef15c18599971b7beced415a40f0c7deacfd9b0d1819e03d723d8bc943cfca;
    uint256 private constant STARK_GY = 0x5668060aa49730b7be4801df46ec62de53ecd11abe43a32873000c36e8dc1f;
    uint256 constant EC_ORDER = 3618502788666131213697322783095070105526743751716087489154079457884512865583;
    uint256 constant N_ELEMENT_BITS_ECDSA = 251;

    /**
     * @notice Checks if a Starknet public key belongs to the Starknet elliptic curve.
     * @param starkPubKey user starknet public key
     * @return isValid True if the key is valid.
     */
    function isValidStarknetPublicKey(uint256 starkPubKey) internal view returns (bool) {
        // y^2 ≡ x^3 + α*x + β  (mod P)
        uint256 fieldElement = calcFieldElement(starkPubKey);
        return isQuadraticResidue(fieldElement);
    }

    function calcFieldElement(uint256 starkPubKey) internal pure returns (uint256) {
        uint256 xCubed = mulmod(mulmod(starkPubKey, starkPubKey, K_MODULUS), starkPubKey, K_MODULUS);
        return addmod(addmod(xCubed, starkPubKey, K_MODULUS), K_BETA, K_MODULUS);
    }

    function isQuadraticResidue(uint256 fieldElement) private view returns (bool) {
        return 1 == fieldPow(fieldElement, ((K_MODULUS - 1) / 2));
    }

    function fieldPow(uint256 base, uint256 exponent) internal view returns (uint256) {
        (bool success, bytes memory returndata) =
            address(5).staticcall(abi.encode(0x20, 0x20, 0x20, base, exponent, K_MODULUS));
        require(success, string(returndata));
        return abi.decode(returndata, (uint256));
    }

    /**
     * @dev Recovers the signer's address from a signature.
     * @param ethAddress The Ethereum address of the user.
     * @param signature The user's signature.
     * @param starkPubKey The Starknet public key.
     * @return recoveredAddress The recovered Ethereum address.
     */
    function recoverSigner(address ethAddress, bytes calldata signature, uint256 starkPubKey)
        internal
        pure
        returns (address recoveredAddress)
    {
        require(ethAddress != address(0), "Invalid ethAddress");
        require(signature.length == 65, "Invalid signature length");

        bytes32 messageHash = keccak256(abi.encodePacked("UserRegistration", ethAddress, starkPubKey));

        bytes memory sig = signature;
        bytes32 r;
        bytes32 s;
        uint8 v = uint8(sig[64]);
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
        }

        recoveredAddress = ecrecover(messageHash, v, r, s);
    }

    /**
     * @notice Computes the modular inverse of a modulo m using exponentiation
     * @param a Number to invert
     * @param m Modulus (must be prime)
     * @return Inverse of a modulo m
     */
    function modInverse(uint256 a, uint256 m) internal pure returns (uint256) {
        require(a != 0, "Inverse does not exist");
        return powMod(a, m - 2, m);
    }

    /**
     * @notice Computes base^exponent mod modulus
     * @param base Base number
     * @param exponent Exponent
     * @param modulus Modulus
     * @return Result of base^exponent mod modulus
     */
    function powMod(uint256 base, uint256 exponent, uint256 modulus) internal pure returns (uint256) {
        uint256 result = 1;
        base = base % modulus;
        while (exponent > 0) {
            if (exponent & 1 == 1) {
                result = mulmod(result, base, modulus);
            }
            base = mulmod(base, base, modulus);
            exponent >>= 1;
        }
        return result;
    }

    /**
     * @notice Adds two points on the Stark Curve
     * @param x1 X-coordinate of first point
     * @param y1 Y-coordinate of first point
     * @param x2 X-coordinate of second point
     * @param y2 Y-coordinate of second point
     * @return x3 Resulting X-coordinate
     * @return y3 Resulting Y-coordinate
     */
    function ecAdd(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal pure returns (uint256 x3, uint256 y3) {
        if (x1 == 0 && y1 == 0) return (x2, y2);
        if (x2 == 0 && y2 == 0) return (x1, y1);
        if (x1 == x2 && addmod(y1, y2, K_MODULUS) == 0) return (0, 0);

        uint256 x1Mod = x1 % K_MODULUS;
        uint256 x2Mod = x2 % K_MODULUS;
        uint256 y1Mod = y1 % K_MODULUS;
        uint256 y2Mod = y2 % K_MODULUS;

        uint256 dx = addmod(x2Mod, K_MODULUS - x1Mod, K_MODULUS);
        uint256 dy = addmod(y2Mod, K_MODULUS - y1Mod, K_MODULUS);
        uint256 lambda = mulmod(dy, modInverse(dx, K_MODULUS), K_MODULUS);
        x3 = addmod(
            mulmod(lambda, lambda, K_MODULUS), addmod(K_MODULUS - x1Mod, K_MODULUS - x2Mod, K_MODULUS), K_MODULUS
        );
        y3 = addmod(mulmod(lambda, addmod(x1Mod, K_MODULUS - x3, K_MODULUS), K_MODULUS), K_MODULUS - y1Mod, K_MODULUS);
    }

    /**
     * @notice Doubles a point on the Stark Curve
     * @param x X-coordinate
     * @param y Y-coordinate
     * @return x2 Resulting X-coordinate
     * @return y2 Resulting Y-coordinate
     */
    function ecDouble(uint256 x, uint256 y) internal pure returns (uint256 x2, uint256 y2) {
        if (y == 0) return (0, 0);
        uint256 xMod = x % K_MODULUS;
        uint256 yMod = y % K_MODULUS;
        uint256 lambda = mulmod(
            addmod(mulmod(3, mulmod(xMod, xMod, K_MODULUS), K_MODULUS), STARK_ALPHA, K_MODULUS),
            modInverse(mulmod(2, yMod, K_MODULUS), K_MODULUS),
            K_MODULUS
        );
        x2 = addmod(mulmod(lambda, lambda, K_MODULUS), K_MODULUS - addmod(xMod, xMod, K_MODULUS), K_MODULUS);
        y2 = addmod(mulmod(lambda, addmod(xMod, K_MODULUS - x2, K_MODULUS), K_MODULUS), K_MODULUS - yMod, K_MODULUS);
    }

    /**
     * @notice Multiplies a point on the Stark Curve by a scalar
     * @param scalar Scalar value
     * @param x X-coordinate
     * @param y Y-coordinate
     * @return xR Resulting X-coordinate
     * @return yR Resulting Y-coordinate
     */
    function ecMul(uint256 scalar, uint256 x, uint256 y) internal pure returns (uint256 xR, uint256 yR) {
        xR = 0;
        yR = 0;
        uint256 scalarMod = scalar % STARK_N;
        uint256 px = x % K_MODULUS;
        uint256 py = y % K_MODULUS;
        while (scalarMod > 0) {
            if (scalarMod & 1 == 1) {
                (xR, yR) = ecAdd(xR, yR, px, py);
            }
            (px, py) = ecDouble(px, py);
            scalarMod >>= 1;
        }
    }

    function getStarkPubkeyY(uint256 fieldElement) internal view returns (uint256) {
        uint256 y0 = modSqrt(fieldElement);
        uint256 y1 = K_MODULUS - y0;
        return y1;
    }

    function modSqrt(uint256 a) internal view returns (uint256) {
        require(isQuadraticResidue(a), "Not a square");

        uint256 p = K_MODULUS;
        uint256 Q = p - 1;
        uint256 S = 0;
        while (Q & 1 == 0) {
            Q >>= 1;
            S++;
        }

        uint256 z = 2;
        while (fieldPow(z, (p - 1) / 2) != p - 1) {
            z++;
        }

        uint256 c = fieldPow(z, Q);
        uint256 R = fieldPow(a, (Q + 1) / 2);
        uint256 t = fieldPow(a, Q);
        uint256 M = S;

        while (t != 1) {
            uint256 t2i = t;
            uint256 i = 0;
            for (i = 1; i < M; i++) {
                t2i = mulmod(t2i, t2i, p);
                if (t2i == 1) break;
            }
            uint256 b = fieldPow(c, uint256(1) << (M - i - 1));

            R = mulmod(R, b, p);
            c = mulmod(b, b, p);
            t = mulmod(t, c, p);
            M = i;
        }

        return R;
    }

    /**
     * @notice Verifies a Starknet signature
     * @param messageHash Hash of the message signed
     * @param starknetSig Signature as bytes (r, s concatenated)
     * @param starkPubKey Starknet public key
     * @return isValid True if the signature is valid
     */
    function verifyStarknetSignature(uint256 messageHash, bytes calldata starknetSig, uint256 starkPubKey)
        public
        view
        returns (bool isValid)
    {
        require(starknetSig.length == 64, "Invalid signature length");

        bytes memory sig = starknetSig;

        (uint256 r, uint256 s) = abi.decode(sig, (uint256, uint256));

        require(messageHash % EC_ORDER == messageHash, "msgHash out of range");
        require(s >= 1 && s < EC_ORDER, "s out of range");
        uint256 w = EllipticCurve.invMod(s, EC_ORDER);
        require(r >= 1 && r < (1 << N_ELEMENT_BITS_ECDSA), "r out of range");
        require(w >= 1 && w < (1 << N_ELEMENT_BITS_ECDSA), "w out of range");

        require(isValidStarknetPublicKey(starkPubKey), "ZeroXBridge: Invalid Starknet public key");

        uint256 fieldElement = calcFieldElement(starkPubKey);

        uint256 starkPubKeyY = getStarkPubkeyY(fieldElement);

        uint256 y2 = mulmod(starkPubKeyY, starkPubKeyY, K_MODULUS);

        require(y2 == fieldElement, "Curve mismatch");

        // Compute signature verification
        (uint256 zG_x, uint256 zG_y) = EllipticCurve.ecMul(messageHash, STARK_GX, STARK_GY, STARK_ALPHA, K_MODULUS);
        (uint256 rQ_x, uint256 rQ_y) = EllipticCurve.ecMul(r, starkPubKey, starkPubKeyY, STARK_ALPHA, K_MODULUS);
        (uint256 b_x, uint256 b_y) = EllipticCurve.ecAdd(zG_x, zG_y, rQ_x, rQ_y, STARK_ALPHA, K_MODULUS);
        (uint256 res_x,) = EllipticCurve.ecMul(w, b_x, b_y, STARK_ALPHA, K_MODULUS);

        isValid = res_x == r;
    }
}
