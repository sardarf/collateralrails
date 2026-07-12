// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ReceiptLib
/// @notice EIP-712 typed data for dual delivery attestations.
///
/// @dev CollateralRails V2 replaces the single seller-signed "receipt" with a
///      DUAL ATTESTATION: both the seller and the buyer independently sign a
///      commitment to the same delivered response bytes. Delivery is confirmed
///      only when `sellerResponseHash == buyerResponseHash` and both signatures
///      are valid and anchored on time.
///
///      Note there is NO self-reported `deliveredAt` field. The old model let a
///      signer backdate delivery and produce a receipt retroactively during a
///      defense window. V2 uses the ON-CHAIN ANCHOR TIME (block.timestamp when
///      the attestation is submitted) as the authoritative timestamp, so an
///      attestation cannot be fabricated after the fact — see ClaimManager.attest
///      and ClaimManager.defend.
///
///      Matching hashes prove buyer and seller agree on the delivered response
///      bytes. They do NOT prove the semantic correctness, quality or external
///      truth of the service — that is intentionally out of scope.
library ReceiptLib {
    /// @param paymentId    SettlementRouter payment id being attested.
    /// @param requestHash  commitment to the request the buyer paid for.
    /// @param responseHash commitment to the response bytes that were delivered.
    struct Attestation {
        uint256 paymentId;
        bytes32 requestHash;
        bytes32 responseHash;
    }

    bytes32 internal constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(uint256 paymentId,bytes32 requestHash,bytes32 responseHash)");

    function hashStruct(Attestation memory a) internal pure returns (bytes32) {
        return keccak256(abi.encode(ATTESTATION_TYPEHASH, a.paymentId, a.requestHash, a.responseHash));
    }
}