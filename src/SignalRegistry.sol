// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SignalRegistry
/// @notice Trust-minimised, on-chain attestation for Puls "Creator Signals" —
///         premium prediction-market forecasts published by humans (and agents)
///         and sold per-read via x402 USDC nanopayments off-chain.
///
///         Publishing a signal writes an immutable record binding:
///           • a deterministic content hash (keccak256 of the canonical thesis),
///           • the creator's payout address,
///           • the per-read price (USDC, 6 decimals),
///           • the block timestamp.
///
///         This lets anyone independently verify, on Arc, that a given piece of
///         alpha existed at a point in time and who authored it — the same
///         tamper-evidence Polymarket-style resolution gives to outcomes, here
///         applied to the *content economy* on top of the markets.
///
///         The registry is intentionally minimal: it stores attestations, not
///         the content itself (which lives off-chain in Supabase + IPFS-style
///         hashes). Payments settle off-chain through the creator's SCA wallet;
///         this contract is the public, verifiable provenance layer.
contract SignalRegistry {
    struct Attestation {
        address creator;     // creator payout / identity address
        bytes32 contentHash; // keccak256 of the canonical signal content
        uint256 priceUsdc;   // per-read price, 6-decimal USDC units
        uint64  publishedAt; // block timestamp at publish
        uint64  revokedAt;   // 0 while live; set when the creator revokes
    }

    /// @dev signalId (an off-chain UUID hashed to bytes32) → attestation.
    mapping(bytes32 => Attestation) public attestations;

    /// @dev creator address → list of their signalIds (cheap enumeration).
    mapping(address => bytes32[]) private _creatorSignals;

    /// @dev total published (including revoked) — handy for explorers/stats.
    uint256 public totalPublished;

    event SignalPublished(
        bytes32 indexed signalId,
        address indexed creator,
        bytes32 contentHash,
        uint256 priceUsdc,
        uint64  publishedAt
    );

    event SignalRevoked(bytes32 indexed signalId, address indexed creator, uint64 revokedAt);

    error AlreadyPublished();
    error NotPublished();
    error NotCreator();
    error AlreadyRevoked();

    /// @notice Publish (attest) a signal. The caller is recorded as the creator,
    ///         so signals are self-sovereign — no admin gatekeeper.
    /// @param signalId    off-chain id hashed to bytes32 (keccak256 of the UUID)
    /// @param contentHash keccak256 of the canonical signal content
    /// @param priceUsdc   per-read price in 6-decimal USDC units
    function publish(bytes32 signalId, bytes32 contentHash, uint256 priceUsdc) external {
        Attestation storage a = attestations[signalId];
        if (a.publishedAt != 0) revert AlreadyPublished();

        a.creator = msg.sender;
        a.contentHash = contentHash;
        a.priceUsdc = priceUsdc;
        a.publishedAt = uint64(block.timestamp);

        _creatorSignals[msg.sender].push(signalId);
        unchecked { totalPublished++; }

        emit SignalPublished(signalId, msg.sender, contentHash, priceUsdc, uint64(block.timestamp));
    }

    /// @notice Revoke a previously published signal (only the original creator).
    ///         Keeps the record for provenance but marks it withdrawn.
    function revoke(bytes32 signalId) external {
        Attestation storage a = attestations[signalId];
        if (a.publishedAt == 0) revert NotPublished();
        if (a.creator != msg.sender) revert NotCreator();
        if (a.revokedAt != 0) revert AlreadyRevoked();

        a.revokedAt = uint64(block.timestamp);
        emit SignalRevoked(signalId, msg.sender, uint64(block.timestamp));
    }

    /// @notice Verify a content hash matches what was attested (and is live).
    function verify(bytes32 signalId, bytes32 contentHash) external view returns (bool) {
        Attestation storage a = attestations[signalId];
        return a.publishedAt != 0 && a.revokedAt == 0 && a.contentHash == contentHash;
    }

    /// @notice Full attestation for a signal.
    function getAttestation(bytes32 signalId)
        external
        view
        returns (address creator, bytes32 contentHash, uint256 priceUsdc, uint64 publishedAt, uint64 revokedAt)
    {
        Attestation storage a = attestations[signalId];
        return (a.creator, a.contentHash, a.priceUsdc, a.publishedAt, a.revokedAt);
    }

    /// @notice All signalIds published by a creator.
    function creatorSignals(address creator) external view returns (bytes32[] memory) {
        return _creatorSignals[creator];
    }

    /// @notice Count of signals published by a creator.
    function creatorSignalCount(address creator) external view returns (uint256) {
        return _creatorSignals[creator].length;
    }
}
